// WinPlatform — Windows implementations of the core's platform hooks: Chinese conversion, keep-awake, recycle bin,
// AAC (Media Foundation), doctor checks, and the transcription child process.
using System.Diagnostics;
using System.Runtime.InteropServices;
using Hearby.Core;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using NAudio.MediaFoundation;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Hearby.App;

static class WinPlatform
{
    public static void Install()
    {
        Clean.Converter = new LcMapConverter();
        Platform.KeepAwake = reason => new KeepAwakeHandle(reason);
        Platform.Trash = TrashPath;
        Platform.M4a = new M4aEncoder();
        Doctor.PlatformChecks = new DoctorChecks();
        Transcriber.Engine = new WorkerEngine();
    }

    static bool mfStarted;
    static readonly object MfGate = new();
    /// Media Foundation (AAC encoding, audio/video decoding): started once per process
    public static void StartMediaFoundation()
    {
        lock (MfGate) { if (mfStarted) return; MediaFoundationApi.Startup(); mfStarted = true; }
    }

    public static void TrashPath(string path)
    {
        var op = new Native.SHFILEOPSTRUCT
        {
            wFunc = Native.FO_DELETE,
            pFrom = path + "\0\0",
            fFlags = (ushort)(Native.FOF_ALLOWUNDO | Native.FOF_NOCONFIRMATION | Native.FOF_SILENT | Native.FOF_NOERRORUI),
        };
        int r = Native.SHFileOperation(ref op);
        if (r != 0) HearbyLog.Write($"recycle bin failed ({r}): {Path.GetFileName(path)}");
    }

    /// Transcription threads from the core count (i5-1235U: 2 P + 8 E cores → 5). Falls back to half the logical CPUs
    public static int PerfCores()
    {
        try
        {
            uint len = 0;
            Native.GetLogicalProcessorInformationEx(0, IntPtr.Zero, ref len);
            if (len == 0) throw new Exception();
            var buf = Marshal.AllocHGlobal((int)len);
            try
            {
                if (!Native.GetLogicalProcessorInformationEx(0, buf, ref len)) throw new Exception();
                var classes = new List<byte>();
                int off = 0;
                while (off < len)
                {
                    int size = Marshal.ReadInt32(buf, off + 4);
                    byte efficiency = Marshal.ReadByte(buf, off + 8 + 1); // PROCESSOR_RELATIONSHIP: Flags, EfficiencyClass
                    classes.Add(efficiency);
                    off += size;
                }
                if (classes.Count == 0) throw new Exception();
                // Half the physical cores (hybrid chips: P + E together), at least 4, at most 8 and never more than logical CPUs.
                // The child runs below normal priority, so the meeting app and the desktop stay responsive.
                int threads = Math.Clamp((classes.Count + 1) / 2, 4, 8);
                return Math.Min(threads, Environment.ProcessorCount);
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
        catch { return Math.Clamp(Environment.ProcessorCount / 2, 2, 8); }
    }
}

sealed class LcMapConverter : IChineseConverter
{
    public string ToTraditional(string s)
    {
        try
        {
            int n = Native.LCMapStringEx("zh-TW", Native.LCMAP_TRADITIONAL_CHINESE, s, s.Length, null, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (n <= 0) return s;
            var buf = new char[n];
            n = Native.LCMapStringEx("zh-TW", Native.LCMAP_TRADITIONAL_CHINESE, s, s.Length, buf, n, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            return n <= 0 ? s : new string(buf, 0, n);
        }
        catch { return s; }
    }
}

/// Keeps the PC from idle-sleeping while alive (SetThreadExecutionState is per thread, so it owns one)
sealed class KeepAwakeHandle : IDisposable
{
    readonly ManualResetEventSlim release = new();
    public KeepAwakeHandle(string reason)
    {
        var t = new Thread(() =>
        {
            Native.SetThreadExecutionState(Native.ES_CONTINUOUS | Native.ES_SYSTEM_REQUIRED);
            release.Wait();
            Native.SetThreadExecutionState(Native.ES_CONTINUOUS);
        }) { IsBackground = true, Name = "keep-awake: " + reason };
        t.Start();
    }
    public void Dispose() => release.Set();
}

/// mic.wav + system.wav (16 kHz mono) → one AAC .m4a. Media Foundation's AAC encoder only takes 44.1/48 kHz, so the mix is
/// streamed through a resampler to 48 kHz. Windows "N" editions without the Media Feature Pack cannot encode: then the WAVs stay.
sealed class M4aEncoder : IM4aEncoder
{
    static void Start() => WinPlatform.StartMediaFoundation();

    public bool Mix(string dir, string dest, double seconds)
    {
        var tmp = Path.Combine(Path.GetDirectoryName(dest)!, Path.GetFileNameWithoutExtension(dest) + ".mixing.m4a");
        try
        {
            Start();
            var files = new[] { "mic.wav", "system.wav" }.Select(n => Path.Combine(dir, n)).Where(f => WavIO.DurationMs(f) is > 0).ToList();
            if (files.Count == 0) return false;
            using var mix = new WavMixProvider(files);
            var resampled = new WdlResamplingSampleProvider(mix.ToSampleProvider(), 48000);
            var pcm16 = new SampleToWaveProvider16(resampled);
            if (File.Exists(tmp)) File.Delete(tmp);
            MediaFoundationEncoder.EncodeToAac(pcm16, tmp, 96000);
            if (!File.Exists(tmp) || new FileInfo(tmp).Length == 0) return false;
            if (File.Exists(dest)) { try { WinPlatform.TrashPath(dest); } catch { } }
            File.Move(tmp, dest, overwrite: true);
            return true;
        }
        catch (Exception e)
        {
            HearbyLog.Write($"m4a fail: {e.GetType().Name} {e.Message}");
            try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
            return false;
        }
    }

    public double? DurationSeconds(string path)
    {
        try { Start(); using var r = new MediaFoundationReader(path); return r.TotalTime.TotalSeconds; }
        catch { return null; }
    }
}

/// Streams two (or one) 16 kHz mono s16 WAV files as their sum (clipped), chunk by chunk — hours of audio never sit in memory
sealed class WavMixProvider : IWaveProvider, IDisposable
{
    readonly List<(FileStream Fs, long End)> inputs = [];
    public WaveFormat WaveFormat { get; } = new(16000, 16, 1);
    byte[] scratch = [];

    public WavMixProvider(IEnumerable<string> files)
    {
        foreach (var f in files)
        {
            if (WavIO.PcmRange(f) is not { } r) continue;
            var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            fs.Seek(r.Start, SeekOrigin.Begin);
            inputs.Add((fs, r.Start + r.Bytes));
        }
    }

    public int Read(Span<byte> buffer)
    {
        int count = buffer.Length & ~1;
        var acc = new int[count / 2];
        int produced = 0;
        if (scratch.Length < count) scratch = new byte[count];
        foreach (var (fs, end) in inputs)
        {
            int want = (int)Math.Min(count, Math.Max(0, end - fs.Position));
            int got = 0;
            while (got < want) { int k = fs.Read(scratch, got, want - got); if (k <= 0) break; got += k; }
            for (int i = 0; i < got / 2; i++) acc[i] += BitConverter.ToInt16(scratch, i * 2);
            produced = Math.Max(produced, got & ~1);
        }
        for (int i = 0; i < produced / 2; i++)
        {
            short s = (short)Math.Clamp(acc[i], short.MinValue + 1, short.MaxValue);
            buffer[i * 2] = (byte)(s & 0xFF);
            buffer[i * 2 + 1] = (byte)((s >> 8) & 0xFF);
        }
        return produced;
    }

    public void Dispose() { foreach (var (fs, _) in inputs) fs.Dispose(); }
}

/// Transcription runs in a child process (Hearby.exe --transcribe-worker): a crash in a GPU driver or the native engine
/// takes down that slice, never the app. Below-normal priority so the laptop stays responsive while it works.
sealed class WorkerEngine : IWhisperEngine
{
    static string Exe => Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Hearby.exe");
    /// The engine needs its native files and the Microsoft C++ runtime (shipped next to Hearby.exe; an installed copy also works)
    public bool Available => File.Exists(Exe) && Directory.Exists(Path.Combine(AppContext.BaseDirectory, "runtimes"))
        && new[] { "vcruntime140.dll", "msvcp140.dll", "vcomp140.dll" }.All(d => File.Exists(Path.Combine(AppContext.BaseDirectory, d)) || File.Exists(Path.Combine(Environment.SystemDirectory, d)));
    static readonly int Threads = WinPlatform.PerfCores();

    /// Set when the only "GPU" turned out to be a software renderer: the rest of this session runs on the CPU
    static volatile bool noUsableGpu;
    static string lastBackend = "";

    public WhisperRun Run(string model, string wav, string jsonBase, int maxContext, double timeoutSeconds, bool allowGpu)
    {
        bool gpu = allowGpu && !noUsableGpu && ConfigStore.Shared.Current.UseGPUOn;
        var (r, backend) = RunOnce(model, wav, jsonBase, maxContext, timeoutSeconds, gpu);
        if (r.Status == WhisperWorker.SoftwareGpuExit && gpu)
        {
            noUsableGpu = true;
            HearbyLog.Write($"worker: software GPU ({backend}) → CPU from now on");
            (r, backend) = RunOnce(model, wav, jsonBase, maxContext, timeoutSeconds, false);
        }
        bool usedGpu = backend.Contains("gpu=1", StringComparison.Ordinal);
        if (r.Status != 0) HearbyLog.Write($"worker exit={r.Status} backend={backend} {Tail(r.Stderr)}");
        else if (backend.Length > 0 && backend != lastBackend) { lastBackend = backend; HearbyLog.Write($"whisper backend: {backend}（{Threads} 執行緒）"); }
        return new WhisperRun(r.Status, r.Stderr, usedGpu, r.TimedOut);
    }

    static (RunResult, string) RunOnce(string model, string wav, string jsonBase, int maxContext, double timeoutSeconds, bool gpu)
    {
        var args = new List<string> { "--transcribe-worker", "--model", model, "--wav", wav, "--out", jsonBase + ".json",
            "--threads", Threads.ToString(), "--prompt", Transcriber.Prompt, "--gpu", gpu ? "1" : "0" };
        if (maxContext >= 0) args.AddRange(["--max-context", maxContext.ToString()]);
        var r = ProcessRunner.Run(Exe, args, timeoutSeconds: timeoutSeconds, cwd: Path.GetDirectoryName(wav), priority: ProcessPriorityClass.BelowNormal);
        var backend = r.Stderr.Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.StartsWith("hearby-backend: ", StringComparison.Ordinal))?["hearby-backend: ".Length..] ?? "";
        return (r, backend);
    }

    static string Tail(string s) => s.Length <= 300 ? s.Replace('\n', ' ') : s[^300..].Replace('\n', ' ');
}

/// Doctor: system, microphone, system audio — Windows specifics
sealed class DoctorChecks : IDoctorPlatform
{
    public DoctorItem System()
    {
        var v = Environment.OSVersion.Version;
        string arch = RuntimeInformation.OSArchitecture.ToString();
        string name = v.Build >= 22000 ? "Windows 11" : "Windows 10";
        string ver = $"{name}（組建 {v.Build}）";
        if (v.Major < 10 || v.Build < 19045)
            return new("系統", DoctorItem.Status.Missing, $"{ver}——需要 Windows 10 22H2（組建 19045）或 Windows 11");
        if (RuntimeInformation.OSArchitecture == Architecture.Arm64)
            return new("系統", DoctorItem.Status.Warn, $"{ver}，ARM 處理器：以相容模式執行，聽打會比較慢");
        return new("系統", DoctorItem.Status.Ok, $"{ver}，{arch}");
    }

    /// Windows privacy: Settings → Privacy & security → Microphone (overall switch + "let desktop apps access your microphone")
    public static bool? MicAllowed()
    {
        try
        {
            string? Val(RegistryKey root, string sub) => root.OpenSubKey(sub)?.GetValue("Value") as string;
            const string key = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";
            var machine = Val(Registry.LocalMachine, key);
            var user = Val(Registry.CurrentUser, key);
            var desktop = Val(Registry.CurrentUser, key + @"\NonPackaged");
            if (machine == "Deny" || user == "Deny" || desktop == "Deny") return false;
            return true;
        }
        catch { return null; }
    }

    public DoctorItem Microphone()
    {
        if (MicAllowed() == false)
            return new("麥克風", DoctorItem.Status.Missing, "被 Windows 隱私權設定關掉了——設定 › 隱私權與安全性 › 麥克風：打開「麥克風存取」與「讓傳統型應用程式存取您的麥克風」");
        try
        {
            using var en = new MMDeviceEnumerator();
            if (!en.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Console)) return new("麥克風", DoctorItem.Status.Missing, "找不到麥克風（沒有錄音裝置）");
            using var d = en.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
            return new("麥克風", DoctorItem.Status.Ok, $"可用：{d.FriendlyName}");
        }
        catch (Exception e) { return new("麥克風", DoctorItem.Status.Unknown, e.Message); }
    }

    public DoctorItem SystemAudio()
    {
        try
        {
            using var en = new MMDeviceEnumerator();
            if (!en.HasDefaultAudioEndpoint(DataFlow.Render, Role.Console)) return new("系統聲", DoctorItem.Status.Warn, "找不到喇叭或耳機（線上會議錄不到對方的聲音；同一個房間開會不影響）");
            using var d = en.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console);
            return new("系統聲", DoctorItem.Status.Ok, $"可用（{d.FriendlyName}）；只在「線上會議」才會錄，不需要額外權限");
        }
        catch (Exception e) { return new("系統聲", DoctorItem.Status.Unknown, e.Message); }
    }
}
