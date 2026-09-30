// AppState — the shell's state machine: idle / recording / processing / done / error; real recording, the real pipeline,
// recovery, import, the model download. Mirrors HearbyApp/AppState.swift. Everything here runs on the UI thread; slow work
// goes to the thread pool and comes back through Gui.OnUi.
using System.Globalization;
using System.Windows.Threading;
using Hearby.Core;
using Microsoft.Win32;

namespace Hearby.App;

/// What the panel shows (the shell writes, the views read). Changed = rebuild; Ticked = timer, levels, progress only.
public sealed class PanelModel
{
    public Phase Phase = Phase.Idle;
    public int Scene;                        // 0 meeting / 1 interview / 2 note
    public bool Online;
    public string Brief = "";
    public string ElapsedText = "00:00";
    public bool Paused;
    public string PausedText = "";
    public string MicName = "";
    public List<float> MicHistory = [];
    public List<float> SysHistory = [];
    public bool SysActive;
    public List<string> Alerts = [];
    public string? NoticeLine;
    public string StageText = "";
    public string Partial = "";
    public string DoneTitle = "";
    public List<string> DoneLines = [];
    public string? DoneMD;
    public string DoneNote = "";
    public string ErrorText = "";
    public MeetingItem? LastMeeting;
    public bool ModelReady = true;
    public double? DownloadFraction;
    public string DownloadNote = "";
    public List<Pipeline.RecoveryItem> PendingRecoveries = [];
    public List<string> SuggestedBrief = [];
    public bool ClaudeReady;
    public string? UpdateReady;
    public const int WaveSlots = 40;

    public event Action? Changed;
    public event Action? Ticked;
    public void RaiseChanged() => Changed?.Invoke();
    public void RaiseTicked() => Ticked?.Invoke();
}

public sealed class AppState
{
    public static readonly AppState Shared = new();
    public readonly PanelModel Panel = new();
    public Phase Phase { get; private set; } = Phase.Idle;

    DualRecorder? recorder;
    DispatcherTimer? timer;
    MeetingMeta meta = new();
    int recTicks;
    MicWatch micWatch = new(DateTimeOffset.Now);
    double nextPauseReminder = 600;
    public const string MicSilentAlertPrefix = "麥克風兩分鐘沒收到聲音";
    IDisposable? recordAwake;
    ModelDownload? download;
    DispatcherTimer? downloadTimer;
    bool importing, stopping, starting;
    bool processingActive;
    DateTime? processSleptAt;
    double processSleptSecs;

    // wired by the shell
    public Action<int> OpenWindowTab = _ => { };
    public Action<string> OpenRecord = _ => { };
    public Action ShowPanel = () => { };
    public Action ShowWizard = () => { };
    public Action<Phase> OnPhase = _ => { };
    public Action<string, string> Notify = (_, _) => { };
    public Action<string> PresentExport = _ => { };

    public static string ModelSizeText => (ModelCatalog.Default.Bytes / 1_000_000_000.0).ToString("0.0", CultureInfo.InvariantCulture) + " GB";

    AppState()
    {
        var cfg = ConfigStore.Shared.Current;
        Panel.Scene = Math.Max(0, Array.FindIndex(RecordSceneExt.All, s => s.Raw() == cfg.Scene));
        Panel.Online = cfg.Online;
        Panel.Brief = cfg.LastBrief ?? "";
        SystemEvents.PowerModeChanged += (_, e) => Gui.OnUi(() => PowerChanged(e.Mode));
    }

    // ── state machine ──

    public bool Go(Phase next, string reason = "")
    {
        if (!Phase.CanGo(next)) { HearbyLog.Write($"state: {Phase.Label()} → {next.Label()} 不合法，忽略 {reason}"); return false; }
        HearbyLog.Write($"state: {Phase} → {next} {reason}");
        Phase = next;
        Panel.Phase = next;
        OnPhase(next);
        if (next == Phase.Idle) RefreshIdle();
        Panel.RaiseChanged();
        if (next is Phase.Done or Phase.Error) ShowPanel();
        if (next is Phase.Done or Phase.Error && Environment.GetEnvironmentVariable("HEARBY_AUTOQUIT") == "1")
        {
            HearbyLog.Write($"autoquit phase={next}");
            var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
            t.Tick += (_, _) => { t.Stop(); Gui.Quit(next == Phase.Done ? 0 : 1); };
            t.Start();
        }
        return true;
    }

    public void Fail(string msg) { Panel.ErrorText = msg; Go(Phase.Error, msg); }

    /// A meeting was renamed in the list: the done page still pointing at it follows, so "open this record" still finds it
    public void Renamed(string oldDir, MeetingRename.Report r)
    {
        if (Panel.DoneMD is { } md && r.MdPath is { } n && string.Equals(Path.GetDirectoryName(md), oldDir, StringComparison.OrdinalIgnoreCase))
        {
            Panel.DoneMD = n;
            Panel.DoneTitle = r.NewId;
        }
    }
    public void Dismiss() => Go(Phase.Idle, "dismiss");

    /// What the idle page shows
    public void RefreshIdle()
    {
        Panel.ModelReady = ModelCatalog.InstalledModel() != null;
        Task.Run(() =>
        {
            var last = MeetingIndex.Scan().FirstOrDefault();
            var rec = Pipeline.PendingRecoveries();
            var sug = ConfigStore.Shared.Current.MemoryEnabled ? MemoryStore.OpenItems() : [];
            bool claude = ClaudeCli.Available && ClaudeCli.AuthStatus()?.LoggedIn == true;
            Gui.OnUi(() =>
            {
                Panel.LastMeeting = last; Panel.PendingRecoveries = rec; Panel.SuggestedBrief = sug; Panel.ClaudeReady = claude;
                Panel.RaiseChanged();
            });
        });
    }

    AudioSource Source => Panel.Online ? AudioSource.Online : AudioSource.Room;

    // ── start ──

    public void Start()
    {
        if (recorder != null || starting || !(Phase is Phase.Idle or Phase.Done)) return;
        if (Transcriber.Engine is not { Available: true }) { Fail("語音辨識元件遺失，請重新安裝 Hearby"); return; }
        if (ModelCatalog.InstalledModel() == null)
        {
            DownloadWhisper();
            Panel.DownloadNote = $"聽打模型還沒好：先下載（約 {ModelSizeText}），好了就能錄";
            Panel.RaiseChanged();
            return;
        }
        var scene = RecordSceneExt.All[Math.Clamp(Panel.Scene, 0, RecordSceneExt.All.Length - 1)];
        ConfigStore.Shared.Update(c => { c.Scene = scene.Raw(); c.Online = Panel.Online; c.LastBrief = Panel.Brief; });
        string dir, stamp;
        try { (dir, stamp) = Pipeline.NewWorkDir(); } catch { Fail("建不了錄音工作夾，請確認磁碟還有空間"); return; }
        var rec = new DualRecorder(dir, Source);
        var briefLines = Panel.Brief.Split('\n').Select(l => Str.TrimWS(l)).Where(l => l.Length > 0).ToList();
        meta = new MeetingMeta
        {
            Id = stamp, Started = DateTimeOffset.Now, Scene = scene.Raw(), Source = Source.Raw(),
            Brief = briefLines.Count == 0 ? null : briefLines,
            Title = briefLines.Count > 0 ? Str.Prefix(briefLines[0], 40) : "",
        };
        Panel.Alerts = []; Panel.MicHistory = []; Panel.SysHistory = [];
        Panel.ElapsedText = "00:00"; Panel.Paused = false; Panel.PausedText = ""; Panel.MicName = "";
        starting = true;
        Task.Run(() =>
        {
            try
            {
                var warns = rec.Start();
                Gui.OnUi(() => Started(rec, warns));
            }
            catch (Exception e) { Gui.OnUi(() => { starting = false; Fail(e.Message); }); }
        });
    }

    void Started(DualRecorder rec, List<string> warns)
    {
        starting = false;
        recorder = rec;
        meta.Started = rec.StartedAt;
        meta.Warnings = warns;
        Panel.Alerts = [.. warns];
        Panel.MicName = rec.MicDeviceName;
        micWatch = new MicWatch(DateTimeOffset.Now);
        nextPauseReminder = 600;
        if (DualRecorder.AvailableDiskBytes(Pipeline.RecordingsDir) is { } free && free < 2_000_000_000)
            Panel.Alerts.Add($"磁碟只剩約 {(free / 1_000_000_000.0).ToString("0.0", CultureInfo.InvariantCulture)} GB，長會議可能中途存不進去");
        Panel.SysActive = rec.SystemAudioActive;
        Go(Phase.Recording, "start");
        recordAwake = Platform.KeepAwake?.Invoke("會議錄音中");
        Panel.NoticeLine = "錄音中不要闔上筆電，闔上就沒有聲音了";
        var fade = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
        fade.Tick += (_, _) => { fade.Stop(); Panel.NoticeLine = null; Panel.RaiseChanged(); };
        fade.Start();
        StartTimer();
        MeetingMeta.Save(meta, rec.Dir);
        Panel.RaiseChanged();
    }

    void PowerChanged(PowerModes mode)
    {
        if (mode == PowerModes.Suspend)
        {
            recorder?.NoteSleep();
            if (processingActive && processSleptAt == null) { processSleptAt = DateTime.Now; HearbyLog.Write("processing: system sleep（聽打／整理暫停，醒來才會繼續）"); }
        }
        else if (mode == PowerModes.Resume)
        {
            if (recorder is { } rec && rec.NoteWake()) { Panel.Alerts.Add("電腦剛才睡著了，睡眠期間沒有聲音（時長已扣除）"); Panel.RaiseChanged(); }
            if (processingActive && processSleptAt is { } t)
            {
                processSleptSecs += (DateTime.Now - t).TotalSeconds; processSleptAt = null;
                HearbyLog.Write($"processing: wake，整理期間累計睡了 {(int)processSleptSecs}s");
                Panel.StageText = $"電腦剛睡著了約 {Math.Max(1, (int)(processSleptSecs / 60))} 分鐘，整理暫停過，現在繼續…";
                Panel.RaiseChanged();
            }
        }
    }

    void StartTimer()
    {
        recTicks = 0;
        timer?.Stop();
        timer = new DispatcherTimer(DispatcherPriority.Normal) { Interval = TimeSpan.FromMilliseconds(100) };
        timer.Tick += (_, _) => Tick();
        timer.Start();
    }

    void Tick()
    {
        if (recorder is not { } rec || Phase != Phase.Recording) return;
        bool structural = false;
        var now = DateTimeOffset.Now;
        var elapsed = rec.RecordedSeconds;
        Panel.ElapsedText = ClockText(elapsed);
        bool paused = rec.IsPaused;
        if (Panel.Paused != paused) { Panel.Paused = paused; structural = true; }
        if (paused)
        {
            var p = rec.CurrentPauseSeconds;
            Panel.PausedText = ClockText(p);
            if (p >= nextPauseReminder)
            {
                nextPauseReminder += 1800;
                HearbyLog.Write($"rec pause reminder {(int)p}s");
                Notify("Hearby 還在暫停中", $"已經暫停 {PauseSpan.DurText(p)}，這段沒有在錄。要繼續就按工作列的 Hearby 圖示 → 繼續錄。");
            }
        }
        else
        {
            switch (micWatch.Update(rec.MicLevel, now))
            {
                case MicWatch.Event.Silent:
                    HearbyLog.Write($"rec mic silent 120s dev={rec.MicDeviceName}");
                    Panel.Alerts.Add($"{MicSilentAlertPrefix}：是不是選錯麥克風，或被靜音了？");
                    structural = true;
                    break;
                case MicWatch.Event.Recovered:
                    Panel.Alerts.RemoveAll(a => a.StartsWith(MicSilentAlertPrefix, StringComparison.Ordinal));
                    structural = true;
                    break;
            }
        }
        if (Panel.MicName != rec.MicDeviceName) { Panel.MicName = rec.MicDeviceName; structural = true; }
        Panel.MicHistory.Add(rec.MicLevel);
        Panel.SysHistory.Add(rec.SysLevel);
        if (Panel.MicHistory.Count > PanelModel.WaveSlots) Panel.MicHistory.RemoveAt(0);
        if (Panel.SysHistory.Count > PanelModel.WaveSlots) Panel.SysHistory.RemoveAt(0);
        if (Panel.SysActive != rec.SystemAudioActive) { Panel.SysActive = rec.SystemAudioActive; structural = true; }
        if (rec.WriteFailures > 30 && !Panel.Alerts.Any(a => a.Contains("存不進磁碟")))
        { Panel.Alerts.Add("錄音存不進磁碟（可能已滿），請立刻清出空間"); System.Media.SystemSounds.Hand.Play(); structural = true; }
        if (rec.MicDead && !Panel.Alerts.Any(a => a.Contains("麥克風已中斷")))
        { Panel.Alerts.Add("麥克風已中斷（裝置切換後接不回來）——請按停止、確認麥克風後重新開始；已錄的部分都在"); System.Media.SystemSounds.Hand.Play(); structural = true; }
        if (rec.MicRecovered) { rec.MicRecovered = false; Panel.Alerts.RemoveAll(a => a.Contains("麥克風已中斷")); structural = true; }
        if (rec.SystemAudioActive && elapsed > 60 && rec.SysMax < 0.015f && !Panel.Alerts.Any(a => a.Contains("電腦裡")))
        { Panel.Alerts.Add("電腦裡那條一直沒動：線上另一端的聲音沒進來（同一個房間開會就正常）"); structural = true; }
        recTicks++;
        if (recTicks % 300 == 0) { meta.Seconds = elapsed; MeetingMeta.Save(meta, rec.Dir); }
        if (structural) Panel.RaiseChanged(); else Panel.RaiseTicked();
    }

    /// 00:00 or 1:02:03
    public static string ClockText(double seconds)
    {
        int s = (int)Fmt.ClampSeconds(seconds);
        return s >= 3600 ? $"{s / 3600}:{s % 3600 / 60:00}:{s % 60:00}" : $"{s / 60:00}:{s % 60:00}";
    }

    // ── pause / resume (phase stays recording; devices stay open, samples are not written) ──

    public void Pause()
    {
        if (Phase != Phase.Recording || recorder is not { } rec || !rec.Pause()) return;
        nextPauseReminder = 600;
        Panel.Paused = true; Panel.PausedText = "00:00";
        meta.Pauses = rec.Pauses;
        meta.Seconds = rec.RecordedSeconds;
        MeetingMeta.Save(meta, rec.Dir);
        HearbyLog.Write($"rec pause at {(int)rec.RecordedSeconds}s");
        Panel.RaiseChanged();
    }

    public void Resume()
    {
        if (Phase != Phase.Recording || recorder is not { } rec || !rec.Resume()) return;
        Panel.Paused = false; Panel.PausedText = "";
        micWatch.Reset(DateTimeOffset.Now);
        meta.Pauses = rec.Pauses;
        MeetingMeta.Save(meta, rec.Dir);
        HearbyLog.Write($"rec resume after {(int)(rec.Pauses.LastOrDefault()?.Seconds ?? 0)}s");
        Panel.RaiseChanged();
    }

    // ── stop → organise ──

    public void Stop()
    {
        if (recorder is not { } rec || stopping) return;
        stopping = true;
        timer?.Stop(); timer = null;
        recordAwake?.Dispose(); recordAwake = null;
        Task.Run(() =>
        {
            var secs = rec.Stop();
            Gui.OnUi(() => Stopped(rec, secs));
        });
    }

    void Stopped(DualRecorder rec, double secs)
    {
        stopping = false;
        Panel.Paused = false; Panel.PausedText = "";
        meta.Seconds = secs;
        meta.MicMax = rec.MicMax;
        meta.SysMax = rec.SysMax;
        meta.Pauses = rec.Pauses.Count == 0 ? null : rec.Pauses;
        var warnings = new List<string>(meta.Warnings);
        if (rec.Source == AudioSource.Online && !rec.SystemAudioActive && !warnings.Any(w => w.Contains("系統聲音"))) warnings.Add("系統聲音軌中途中斷或未啟用");
        if (rec.SystemAudioActive && rec.SysBufferCount == 0) warnings.Add("系統聲音串流已啟動，但整場沒有收到任何聲音資料");
        if (rec.SysStopError is { } e) warnings.Add($"系統聲音串流中途被系統中止：{e}");
        if (rec.MicInterrupted) warnings.Add("錄音中麥克風裝置曾被切換，已自動接續，交界處可能缺幾秒");
        if (rec.SleptWhileRecording) warnings.Add($"錄音中電腦曾睡眠約 {Math.Max(1, (int)(rec.SleepSeconds / 60))} 分鐘，睡眠期間收不到聲音，時長已扣除");
        if (WavIO.Seconds(Path.Combine(rec.Dir, "mic.wav")) is { } wavSecs && secs > 120 && wavSecs < secs * 0.9)
            warnings.Add($"音檔比計時短約 {(int)((secs - wavSecs) / 60) + 1} 分鐘，中途可能磁碟滿或裝置中斷");
        if (rec.WriteFailures > 0) warnings.Add($"錄音期間發生 {rec.WriteFailures} 次寫入失敗（磁碟滿？），內容可能不完整");
        meta.Warnings = warnings;
        MeetingMeta.Save(meta, rec.Dir);
        recorder = null;
        if (secs < 3)
        {
            // too short = pressed by mistake: not organised, straight back to idle
            try { File.WriteAllText(Path.Combine(rec.Dir, ".ignored"), ""); } catch { }
            Go(Phase.Idle, "too short");
            return;
        }
        Process(rec.Dir, meta);
    }

    void Process(string dir, MeetingMeta m)
    {
        if (!Go(Phase.Processing, "process")) return;
        Panel.StageText = "準備聽打…";
        Panel.Partial = "";
        Panel.RaiseChanged();
        processingActive = true; processSleptSecs = 0; processSleptAt = null;
        var provider = Providers.Current();
        Task.Run(() =>
        {
            var p = new Pipeline
            {
                OnStage = s => Gui.OnUi(() => { Panel.StageText = s; Panel.RaiseChanged(); }),
                OnPartialTranscript = t => Gui.OnUi(() => { Panel.Partial = t; Panel.RaiseChanged(); }),
            };
            try
            {
                var o = p.Process(dir, m, provider);
                string md = ""; try { md = RecordMD.Read(o.MdPath); } catch { }
                Gui.OnUi(() =>
                {
                    double slept = EndProcessActivity();
                    Panel.DoneTitle = Path.GetFileNameWithoutExtension(o.MdPath);
                    // a transcript-only record has no key lines: its summary is the note about how to get one, said plainly below
                    Panel.DoneLines = Polish.ThreeLines(md).Where(l => !l.StartsWith('（') && !l.Contains("---") && !l.Contains("只有逐字稿")).ToList();
                    Panel.DoneMD = o.MdPath;
                    var note = o.PolishErr is { } pe ? $"整理沒成功：{pe}。逐字稿已經存好了，之後打開這份紀錄按「重新整理全篇」就能補。"
                        : provider.Id == "none" ? "這場先存成逐字稿。要有摘要、重點、待辦：設定 → 紀錄要誰寫 → 交給我的 Claude 整理，再打開這份紀錄按「重新整理全篇」。" : "";
                    if (slept >= 30) note += (note.Length == 0 ? "" : "\n") + $"這次比較久，是因為整理期間電腦睡了約 {Math.Max(1, (int)(slept / 60))} 分鐘：闔上筆電就會暫停，打開才繼續。";
                    Panel.DoneNote = note;
                    Go(Phase.Done, "pipeline done");
                    Notify("紀錄整理好了", o.Summary);
                    Panel.Brief = "";
                    ConfigStore.Shared.Update(c => c.LastBrief = null);
                    Exporters.AutoPdf(o.MdPath);
                });
            }
            catch (Exception e)
            {
                Gui.OnUi(() => { EndProcessActivity(); Fail(e.Message); });
            }
        });
    }

    double EndProcessActivity()
    {
        processingActive = false;
        if (processSleptAt is { } t) { processSleptSecs += (DateTime.Now - t).TotalSeconds; processSleptAt = null; }
        return processSleptSecs;
    }

    // ── recovery / import ──

    public void Recover(Pipeline.RecoveryItem item)
    {
        if (Phase != Phase.Idle) return;
        WavIO.RepairHeader(Path.Combine(item.Dir, "mic.wav"));
        WavIO.RepairHeader(Path.Combine(item.Dir, "system.wav"));
        var m = MeetingMeta.Load(item.Dir) ?? new MeetingMeta();
        if (item.Started is { } s) m.Started = new DateTimeOffset(s);
        if (m.Seconds <= 0 || m.Imported == true) m.Seconds = item.Seconds;
        m.MicMax = 1; m.SysMax = 1;
        if (!m.Warnings.Any(w => w.Contains("救援"))) m.Warnings.Add("此紀錄由中斷救援補整理，錄音可能不完整");
        Process(item.Dir, m);
    }

    public void IgnoreRecovery(Pipeline.RecoveryItem item)
    {
        try { File.WriteAllText(Path.Combine(item.Dir, ".ignored"), ""); } catch { }
        RefreshIdle();
    }

    public void PickImport()
    {
        var dlg = new Microsoft.Win32.OpenFileDialog { Filter = MediaImport.FileDialogFilter, Title = "選一個音檔或影片，Hearby 會聽打並整理", Multiselect = false };
        if (dlg.ShowDialog() == true) ImportMedia(dlg.FileName);
    }

    public void ImportMedia(string path)
    {
        if (recorder != null || importing || !(Phase is Phase.Idle or Phase.Done)) return;
        if (ModelCatalog.InstalledModel() == null) { DownloadWhisper(); return; }
        MediaImport.Probe probe;
        try { probe = MediaImport.Check(path); } catch (Exception e) { Fail(e.Message); return; }
        if (!Go(Phase.Processing, "import")) return;
        Panel.StageText = "讀取檔案…";
        Panel.RaiseChanged();
        string dir, stamp;
        try { (dir, stamp) = Pipeline.NewWorkDir(); } catch { Fail("建不了工作夾，請確認磁碟還有空間"); return; }
        importing = true;
        processingActive = true; processSleptSecs = 0; processSleptAt = null;
        Task.Run(() =>
        {
            try
            {
                var m = new MeetingMeta
                {
                    Id = stamp, Started = DateTimeOffset.Now, Imported = true, SourceFile = path,
                    Title = Path.GetFileNameWithoutExtension(path), Seconds = probe.Seconds,
                };
                MeetingMeta.Save(m, dir);
                var secs = MediaImport.Transcode(probe, Path.Combine(dir, "mic.wav"), f => Gui.OnUi(() => { Panel.StageText = $"轉檔中 {f * 100:0}%"; Panel.RaiseTicked(); }));
                m.Seconds = secs; m.MicMax = 1; m.SysMax = 0;
                MeetingMeta.Save(m, dir);
                Gui.OnUi(() =>
                {
                    importing = false;
                    Phase = Phase.Idle; Panel.Phase = Phase.Idle;   // let Process() through its state gate
                    Process(dir, m);
                });
            }
            catch (Exception e)
            {
                // a failed import must not show up as "a recording not organised yet": the source file is still there
                try { File.WriteAllText(Path.Combine(dir, ".ignored"), "import-failed"); } catch { }
                Gui.OnUi(() => { importing = false; EndProcessActivity(); Fail(e.Message); });
            }
        });
    }

    // ── model download ──

    public void DownloadWhisper()
    {
        if (download != null) return;
        Panel.DownloadFraction = 0;
        Panel.DownloadNote = "";
        Panel.RaiseChanged();
        var d = ModelDownload.Start(ModelCatalog.Default, (path, err) => Gui.OnUi(() =>
        {
            downloadTimer?.Stop(); downloadTimer = null;
            download = null;
            Panel.DownloadFraction = null;
            if (path != null) { Panel.ModelReady = true; Panel.DownloadNote = ""; }
            else Panel.DownloadNote = err ?? "下載失敗";
            Panel.RaiseChanged();
        }));
        download = d;
        downloadTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        downloadTimer.Tick += (_, _) => { Panel.DownloadFraction = d.Fraction; Panel.RaiseTicked(); };
        downloadTimer.Start();
    }

    public bool Busy => Phase is Phase.Recording or Phase.Processing || starting || stopping || importing;

    /// Quitting while recording: stop cleanly so the recording can be organised next time (「補整理」)
    public void Shutdown()
    {
        HearbyLog.Write($"terminate phase={Phase}");
        try
        {
            if (recorder is { } rec)
            {
                meta.Seconds = rec.Stop();
                meta.MicMax = rec.MicMax; meta.SysMax = rec.SysMax;
                meta.Pauses = rec.Pauses.Count == 0 ? null : rec.Pauses;
                MeetingMeta.Save(meta, rec.Dir);
                recorder = null;
            }
        }
        catch { }
        recordAwake?.Dispose();
        download?.Cancel();
        RunningChildren.TerminateAll();
    }
}
