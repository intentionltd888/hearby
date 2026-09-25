// DualRecorder — two-track recording on Windows (mirrors Audio/Recorder.swift in behaviour):
//   track 1 (the room): default microphone (WASAPI shared capture) → mic.wav
//   track 2 (the computer): what the default output plays (WASAPI loopback) → system.wav, only for online meetings.
//     Loopback delivers nothing while nothing plays, so a silent stream is kept playing on the same output (keep-alive):
//     both tracks keep the same timeline.
// Both tracks are 16 kHz mono s16 (resampled with NAudio's WDL resampler), written crash-safe.
// Pause = devices stay open, samples are simply not written (resume is instant; both tracks stop and resume together).
// The default microphone / output changing (headset plugged in) is followed; a track that goes silent for a few seconds
// (device unplugged, audio service restarted) is reopened. Opening waits at most 3 s, stopping at most 2 s.
// Streams use the default (non-communications) category, so Windows does not duck other sounds while recording.
using Hearby.Core;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

#pragma warning disable CS0618 // WasapiCapture / WasapiLoopbackCapture are marked obsolete in NAudio 3 in favour of a new builder; they still work and are well-proven

namespace Hearby.App;

public enum AudioSource { Room, Online }

public static class AudioSourceExt
{
    public static string Raw(this AudioSource s) => s == AudioSource.Online ? "online" : "room";
    public static string Label(this AudioSource s) => s == AudioSource.Online ? "線上會議" : "同一個房間";
}

/// Any capture format → 16 kHz mono s16
sealed class To16kMono
{
    readonly BufferedWaveProvider buffered;
    readonly ISampleProvider resampled;
    readonly float[] fbuf = new float[16000];

    public To16kMono(WaveFormat input)
    {
        buffered = new BufferedWaveProvider(input, TimeSpan.FromSeconds(20)) { DiscardOnBufferOverflow = true, ReadFully = false };
        ISampleProvider sp = buffered.ToSampleProvider();
        if (sp.WaveFormat.Channels > 1) sp = new DownmixToMono(sp);
        resampled = sp.WaveFormat.SampleRate == 16000 ? sp : new WdlResamplingSampleProvider(sp, 16000);
    }

    public short[] Convert(byte[] data, int count)
    {
        if (count <= 0) return [];
        buffered.AddSamples(data, 0, count);
        var outList = new List<short>(count / 4);
        while (true)
        {
            int n = resampled.Read(fbuf.AsSpan());
            if (n <= 0) break;
            for (int i = 0; i < n; i++) outList.Add((short)(Math.Clamp(fbuf[i], -1f, 1f) * 32767));
            if (n < fbuf.Length) break;
        }
        return [.. outList];
    }

}

/// Average of all channels → one channel
sealed class DownmixToMono(ISampleProvider src) : ISampleProvider
{
    readonly int ch = src.WaveFormat.Channels;
    float[] tmp = [];
    public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(src.WaveFormat.SampleRate, 1);
    public int Read(Span<float> buffer)
    {
        int need = buffer.Length * ch;
        if (tmp.Length < need) tmp = new float[need];
        int got = src.Read(tmp.AsSpan(0, need));
        int frames = got / ch;
        for (int f = 0; f < frames; f++)
        {
            float s = 0;
            for (int c = 0; c < ch; c++) s += tmp[f * ch + c];
            buffer[f] = s / ch;
        }
        return frames;
    }
}

public sealed class DualRecorder
{
    public string Dir { get; }
    public AudioSource Source { get; }
    public const double MicStartTimeout = 3, StopTimeout = 2, MicStallSeconds = 3;

    readonly object gate = new();
    RecordingClock clock = new(DateTimeOffset.Now);
    bool stopping;
    CrashSafeWavWriter? micFile, sysFile;
    readonly object micWrite = new(), sysWrite = new();

    WasapiCapture? mic; To16kMono? micConv; int micGen;
    WasapiLoopbackCapture? loop; To16kMono? sysConv; WasapiOut? keepAlive; int sysGen;
    MMDeviceEnumerator? enumerator;
    MMDeviceNotificationClient? notifier;
    Timer? watch;
    DateTime lastMic = DateTime.UtcNow, lastSys = DateTime.UtcNow, stallCheckAfter = DateTime.MinValue;
    int stallReopens, reopenInFlight;

    float micLevel, sysLevel, micMax, sysMax;
    int micWriteFailures, sysWriteFailures;
    public int SysBufferCount { get; private set; }
    public string? SysStopError { get; private set; }
    public bool SystemAudioActive { get; private set; }
    public bool MicInterrupted { get; private set; }
    public bool MicDead { get; private set; }
    public bool MicRecovered { get; set; }
    public string MicDeviceName { get; private set; } = "";
    public string OutputDeviceName { get; private set; } = "";

    public float MicLevel { get { lock (gate) return micLevel; } }
    public float SysLevel { get { lock (gate) return sysLevel; } }
    public float MicMax { get { lock (gate) return micMax; } }
    public float SysMax { get { lock (gate) return sysMax; } }
    public int WriteFailures { get { lock (gate) return micWriteFailures + sysWriteFailures; } }
    public DateTimeOffset StartedAt { get { lock (gate) return clock.StartedAt; } }
    public double SleepSeconds { get { lock (gate) return clock.SleepSeconds; } }
    public bool SleptWhileRecording { get { lock (gate) return clock.SleptWhileRecording; } }
    public bool IsPaused { get { lock (gate) return clock.IsPaused; } }
    public List<PauseSpan> Pauses { get { lock (gate) return clock.Pauses.Select(p => new PauseSpan(p.AtSeconds, p.Began, p.Ended)).ToList(); } }
    public double RecordedSeconds { get { lock (gate) return clock.Recorded(DateTimeOffset.Now); } }
    public double CurrentPauseSeconds { get { lock (gate) return clock.CurrentPause(DateTimeOffset.Now); } }

    public DualRecorder(string dir, AudioSource source) { Dir = dir; Source = source; }

    void SetMic(float l) { lock (gate) { micLevel = l; if (l > micMax) micMax = l; } }
    void SetSys(float l) { lock (gate) { sysLevel = l; if (l > sysMax) sysMax = l; } }

    public void NoteSleep() { lock (gate) { clock.NoteSleep(DateTimeOffset.Now); stallCheckAfter = DateTime.MaxValue; } }
    /// true = slept while recording (sleeping while paused does not count)
    public bool NoteWake() { lock (gate) { stallCheckAfter = DateTime.UtcNow.AddSeconds(5); return clock.NoteWake(DateTimeOffset.Now); } }

    public bool Pause() { lock (gate) { if (stopping || !clock.Pause(DateTimeOffset.Now)) return false; micLevel = 0; sysLevel = 0; return true; } }
    public bool Resume() { lock (gate) { return !stopping && clock.Resume(DateTimeOffset.Now); } }

    bool ShouldWrite(bool isMic)
    {
        lock (gate)
        {
            if (stopping) return false;
            if (clock.IsPaused) { if (isMic) micLevel = 0; else sysLevel = 0; return false; }
            return true;
        }
    }

    /// Warnings (list); a microphone that cannot be opened throws with a plain sentence
    public List<string> Start()
    {
        Directory.CreateDirectory(Dir);
        var warnings = new List<string>();
        if (DoctorChecks.MicAllowed() == false)
        {
            HearbyLog.Write("rec mic start fail: Windows 隱私權設定關閉麥克風");
            throw new HearbyError("麥克風被 Windows 隱私權設定關掉了：設定 › 隱私權與安全性 › 麥克風，打開「麥克風存取」與「讓傳統型應用程式存取您的麥克風」");
        }
        enumerator = new MMDeviceEnumerator();
        micFile = new CrashSafeWavWriter(Path.Combine(Dir, "mic.wav"));
        OpenMicBounded();
        lock (gate) clock = new RecordingClock(DateTimeOffset.Now);  // mic.wav starts here
        if (Source == AudioSource.Online)
        {
            try { StartSystem(); SystemAudioActive = true; }
            catch (Exception e)
            {
                HearbyLog.Write($"sysaudio start fail: {e.Message}");
                warnings.Add($"系統聲音沒錄到（線上另一端的聲音會缺）：{e.Message}。這場先用麥克風錄，內容照樣完整。");
            }
        }
        try
        {
            notifier = enumerator.CreateNotificationClient(useSynchronizationContext: false);
            notifier.DefaultDeviceChanged += (_, e) => OnDefaultDeviceChanged(e.Flow, e.Role);
        }
        catch (Exception e) { HearbyLog.Write($"device notifications unavailable: {e.Message}"); }
        watch = new Timer(_ => Check(), null, 1000, 1000);
        return warnings;
    }

    void OpenMicBounded()
    {
        var t0 = DateTime.UtcNow;
        var task = Task.Run(OpenMic);
        if (!task.Wait(TimeSpan.FromSeconds(MicStartTimeout)))
        {
            HearbyLog.Write($"rec mic start timeout {MicStartTimeout}s（音訊服務沒回應）");
            throw new HearbyError($"麥克風 {MicStartTimeout} 秒沒有回應：這台電腦的音訊服務卡住了，重新開機通常就好。");
        }
        if (task.Exception?.GetBaseException() is { } e)
        {
            HearbyLog.Write($"rec mic start fail {(DateTime.UtcNow - t0).TotalSeconds:0.0}s: {e.Message}");
            throw e is HearbyError ? e : new HearbyError(MicErrorText(e));
        }
    }

    static string MicErrorText(Exception e)
    {
        var m = e.Message;
        if (m.Contains("0x80070005", StringComparison.OrdinalIgnoreCase) || e is UnauthorizedAccessException)
            return "Windows 不讓 Hearby 用麥克風：設定 › 隱私權與安全性 › 麥克風，打開「讓傳統型應用程式存取您的麥克風」";
        if (m.Contains("0x88890004", StringComparison.OrdinalIgnoreCase)) return "麥克風剛被拔掉或停用了：接好後再按一次開始";
        return "麥克風開不起來：" + m;
    }

    void OpenMic()
    {
        var en = enumerator ?? new MMDeviceEnumerator();
        if (!en.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Console)) throw new HearbyError("找不到麥克風：接上麥克風或耳機後再試一次");
        var dev = en.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
        var cap = new WasapiCapture(dev, true, 100);
        var conv = new To16kMono(cap.WaveFormat);
        int gen = Interlocked.Increment(ref micGen);
        cap.DataAvailable += (_, e) => OnMic(gen, e.Buffer, e.BytesRecorded);
        cap.RecordingStopped += (_, e) => { if (e.Exception != null) HearbyLog.Write($"rec mic stopped: {e.Exception.Message}"); };
        cap.StartRecording();
        lock (gate) { mic = cap; micConv = conv; MicDeviceName = dev.FriendlyName; lastMic = DateTime.UtcNow; }
        HearbyLog.Write($"rec mic open dev={dev.FriendlyName} fmt={cap.WaveFormat}");
    }

    void OnMic(int gen, byte[] buf, int count)
    {
        To16kMono? conv;
        lock (gate) { if (gen != micGen) return; lastMic = DateTime.UtcNow; conv = micConv; }
        if (conv == null) return;
        var pcm = conv.Convert(buf, count);
        if (!ShouldWrite(true) || pcm.Length == 0) return;
        SetMic(WavIO.Level(pcm));
        lock (micWrite) { if (micFile != null && !micFile.Write(pcm)) lock (gate) micWriteFailures++; }
    }

    void StartSystem()
    {
        var en = enumerator ?? new MMDeviceEnumerator();
        if (!en.HasDefaultAudioEndpoint(DataFlow.Render, Role.Console)) throw new HearbyError("找不到聲音輸出裝置");
        var dev = en.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console);
        sysFile ??= new CrashSafeWavWriter(Path.Combine(Dir, "system.wav"));
        OpenSystemOn(dev);
    }

    void OpenSystemOn(MMDevice dev)
    {
        // keep-alive: a silent stream on the same output, so loopback keeps delivering (and both timelines stay aligned)
        var ka = new WasapiOut(dev, AudioClientShareMode.Shared, true, 200);
        ka.Init(new SilenceProvider(WaveFormat.CreateIeeeFloatWaveFormat(48000, 2)));
        ka.Play();
        var cap = new WasapiLoopbackCapture(dev);
        var conv = new To16kMono(cap.WaveFormat);
        int gen = Interlocked.Increment(ref sysGen);
        cap.DataAvailable += (_, e) => OnSys(gen, e.Buffer, e.BytesRecorded);
        cap.RecordingStopped += (_, e) => { if (e.Exception != null) { SysStopError = e.Exception.Message; HearbyLog.Write($"sysaudio stopped: {e.Exception.Message}"); } };
        cap.StartRecording();
        lock (gate) { keepAlive = ka; loop = cap; sysConv = conv; OutputDeviceName = dev.FriendlyName; lastSys = DateTime.UtcNow; }
        HearbyLog.Write($"sysaudio loopback dev={dev.FriendlyName} fmt={cap.WaveFormat}");
    }

    void OnSys(int gen, byte[] buf, int count)
    {
        To16kMono? conv;
        lock (gate) { if (gen != sysGen) return; lastSys = DateTime.UtcNow; conv = sysConv; }
        if (conv == null) return;
        var pcm = conv.Convert(buf, count);
        if (!ShouldWrite(false) || pcm.Length == 0) return;
        SysBufferCount++;
        SetSys(WavIO.Level(pcm));
        lock (sysWrite) { if (sysFile != null && !sysFile.Write(pcm)) lock (gate) sysWriteFailures++; }
    }

    // ── device changes and stalls (checked every second, never on the UI thread) ──

    void Check()
    {
        bool isStopping; DateTime lm, ls, after;
        lock (gate) { isStopping = stopping; lm = lastMic; ls = lastSys; after = stallCheckAfter; }
        if (isStopping || Volatile.Read(ref reopenInFlight) != 0) return;
        var now = DateTime.UtcNow;
        double silent = (now - lm).TotalSeconds;
        if (silent > 1) SetMic(0);
        double stallAfter = MicStallSeconds * Math.Pow(2, Math.Min(stallReopens, 4));
        if (silent > stallAfter && now > after)
        {
            stallReopens++;
            if (stallReopens >= 3) MicDead = true;
            ReopenMic($"stalled {silent:0}s");
        }
        else if (silent < 1 && stallReopens > 0)
        {
            stallReopens = 0;
            if (MicDead) { MicDead = false; MicRecovered = true; }
        }
        if (SystemAudioActive && (now - ls).TotalSeconds > 5 && now > after) ReopenSystem("stalled");
    }

    void ReopenMic(string why)
    {
        if (Interlocked.Exchange(ref reopenInFlight, 1) != 0) return;
        MicInterrupted = true;
        HearbyLog.Write($"rec mic {why}");
        Task.Run(() =>
        {
            try
            {
                WasapiCapture? old;
                lock (gate) { old = mic; mic = null; micConv = null; Interlocked.Increment(ref micGen); }
                SetMic(0);
                if (old != null) Task.Run(() => { try { old.StopRecording(); old.Dispose(); } catch { } });
                for (int attempt = 1; attempt <= 10; attempt++)
                {
                    lock (gate) if (stopping) return;
                    var t = Task.Run(OpenMic);
                    if (t.Wait(TimeSpan.FromSeconds(MicStartTimeout)) && t.Exception == null)
                    {
                        HearbyLog.Write($"rec mic reopened (attempt {attempt}) dev={MicDeviceName}");
                        if (MicDead && stallReopens == 0) { MicDead = false; MicRecovered = true; }
                        return;
                    }
                    HearbyLog.Write($"rec mic reopen fail #{attempt}: {t.Exception?.GetBaseException().Message ?? "timeout"}");
                    Thread.Sleep(1000);
                }
                MicDead = true;
                HearbyLog.Write("rec mic dead after 10 retries");
            }
            finally { Volatile.Write(ref reopenInFlight, 0); }
        });
    }

    void ReopenSystem(string why)
    {
        HearbyLog.Write($"sysaudio reopen: {why}");
        Task.Run(() =>
        {
            WasapiLoopbackCapture? oldLoop; WasapiOut? oldKa;
            lock (gate) { if (stopping) return; oldLoop = loop; oldKa = keepAlive; loop = null; keepAlive = null; sysConv = null; Interlocked.Increment(ref sysGen); lastSys = DateTime.UtcNow; }
            try { oldLoop?.StopRecording(); oldLoop?.Dispose(); } catch { }
            try { oldKa?.Stop(); oldKa?.Dispose(); } catch { }
            try
            {
                var en = enumerator ?? new MMDeviceEnumerator();
                OpenSystemOn(en.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console));
            }
            catch (Exception e) { HearbyLog.Write($"sysaudio reopen fail: {e.Message}"); }
        });
    }

    // Default device changed (called on a system thread: hand off, never block)
    void OnDefaultDeviceChanged(DataFlow flow, Role role)
    {
        if (role != Role.Console) return;
        lock (gate) if (stopping) return;
        if (flow == DataFlow.Capture) ReopenMic("default input change");
        else if (flow == DataFlow.Render && SystemAudioActive) ReopenSystem("default output change");
    }

    /// Stop and finalise; returns recorded seconds (sleep and pauses excluded; up to the moment stop was pressed)
    public double Stop()
    {
        var now = DateTimeOffset.Now;
        lock (gate) { stopping = true; clock.Close(now); }
        watch?.Dispose();
        try { notifier?.Dispose(); } catch { }
        WasapiCapture? m; WasapiLoopbackCapture? l; WasapiOut? k;
        lock (gate) { m = mic; l = loop; k = keepAlive; }
        var closeMic = Task.Run(() => { try { m?.StopRecording(); m?.Dispose(); } catch { } });
        var closeSys = Task.Run(() => { try { l?.StopRecording(); l?.Dispose(); } catch { } try { k?.Stop(); k?.Dispose(); } catch { } });
        if (!Task.WaitAll([closeMic, closeSys], TimeSpan.FromSeconds(StopTimeout))) HearbyLog.Write($"rec stop timeout {StopTimeout}s");
        lock (micWrite) { micFile?.Close(); micFile = null; }
        lock (sysWrite) { sysFile?.Close(); sysFile = null; }
        SetMic(0); SetSys(0);
        lock (gate) return clock.Recorded(now);
    }

    public static long? AvailableDiskBytes(string path)
    {
        try { return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(path))!).AvailableFreeSpace; } catch { return null; }
    }
}
