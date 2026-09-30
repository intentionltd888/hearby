// Cli — command-line use (checked before any window exists). Mirrors HearbyApp/Cli.swift.
//   --doctor [--deep]            seven checks
//   --version / --selftest / --help
//   --download-model             download the speech model (progress in the terminal)
//   --import <file> [--title T] [--provider none|claude|endpoint]   transcribe and organise an audio or video file
//   --process <work folder>      organise an existing recording work folder (mic.wav / system.wav)
//   --repolish <md> "<corrections>"
//   --memory-rebuild [<md>]      sync memory (MEETINGS / OPEN / PEOPLE / index.json) to what the record says now; no file = every meeting
//   --rename <md or folder> "<new title>"   rename a meeting: folder, file names, record header, meta.json, memory ids, mirror together
//   --export-word <md> [--company X --recorder Y --units Z]
//   --record <seconds> [--source room|online] [--pause-at s --resume-at s] [--no-process] [--title T]   real recording (development)
// Hearby.exe is a windowed program: typed into cmd or PowerShell, Windows does not wait for it. Its output goes to the
// console it was started from; in PowerShell use `Hearby.exe --doctor | Out-Host` to wait for it (see TESTING.md).
using System.Runtime.InteropServices;
using System.Text;
using Hearby.Core;

namespace Hearby.App;

static partial class Cli
{
    static readonly HashSet<string> Known =
    [
        "--help", "-h", "--version", "--selftest", "--doctor", "--deep", "--download-model", "--import", "--process", "--repolish",
        "--provider", "--title", "--scene", "--export-word", "--export-pdf", "--company", "--recorder", "--units", "--record", "--source",
        "--no-process", "--pause-at", "--resume-at", "--convert", "--memory-rebuild", "--rename",
    ];
    static readonly HashSet<string> TakesValue =
    [
        "--import", "--process", "--repolish", "--provider", "--title", "--scene", "--export-word", "--export-pdf", "--company", "--recorder",
        "--units", "--record", "--source", "--pause-at", "--resume-at", "--convert", "--rename",
    ];

    static string Usage => $"""
        Hearby {HearbyVersion.Version} (build {HearbyVersion.Build})
        不帶參數＝打開 app。命令列：
          --doctor [--deep]            七項狀態體檢
          --download-model             下載聽打模型
          --import <檔> [--title 標題] [--provider none|claude|endpoint]   聽打並整理一個音檔或影片
          --process <工作夾>           對既有錄音工作夾跑整理
          --repolish <md> "<修正>"     重新整理全篇
          --memory-rebuild [<md>]      記憶同步成紀錄現在的樣子（改過紀錄之後跑；不給檔＝每一場）
          --rename <md 或資料夾> "<新標題>"   改一場的標題（資料夾、檔名、紀錄表頭、記憶、副本一起換；不要自己改資料夾名）
          --export-word <md> / --export-pdf <md> [--company X --recorder Y --units Z]
          --record <秒> [--source room|online] [--pause-at 秒 --resume-at 秒] [--no-process]
          --convert <檔>               只把音檔／影片轉成 16 kHz 的 wav（檢查某個檔讀不讀得了）
          --version / --help
        """;

    [LibraryImport("kernel32.dll")]
    private static partial IntPtr GetStdHandle(int nStdHandle);

    /// Output to the terminal: inherited handles (pipes, redirects) work as they are; typed into a console, attach to it
    static void SetUpConsole()
    {
        if (GetStdHandle(-11) == IntPtr.Zero) Native.AttachConsole(-1);
        try { Console.OutputEncoding = new UTF8Encoding(false); } catch { }
    }

    static void Out(string s) => Console.WriteLine(s);

    /// null = not a command-line call (open the app)
    public static int? Dispatch(string[] a)
    {
        if (a.Length == 0) return null;
        SetUpConsole();
        var set = new HashSet<string>(a);
        string? Value(string flag) { int i = Array.IndexOf(a, flag); return i >= 0 && i + 1 < a.Length ? a[i + 1] : null; }
        if (set.Contains("--help") || set.Contains("-h")) { Out(Usage); return 0; }

        int skip = 0;
        var flags = new List<string>();
        for (int i = 0; i < a.Length; i++)
        {
            var x = a[i];
            if (skip > 0) { skip--; continue; }
            skip = TakesValue.Contains(x) ? 1 : 0;
            if (x == "--repolish" && a.Length > i + 2 && !Known.Contains(a[i + 2])) skip = 2;
            // --memory-rebuild takes a file or nothing
            if (x == "--memory-rebuild" && a.Length > i + 1 && !Known.Contains(a[i + 1])) skip = 1;
            // --rename takes two values (the meeting, the new title); a title that looks like a flag ("--Q1") is still the title
            if (x == "--rename" && a.Length > i + 2 && !Known.Contains(a[i + 2])) skip = 2;
            flags.Add(x);
        }
        if (flags.FirstOrDefault(f => f.StartsWith("--", StringComparison.Ordinal) && !Known.Contains(f)) is { } bad)
        {
            Console.Error.WriteLine($"不認得的參數：{bad}\n\n{Usage}");
            return 2;
        }
        for (int i = 0; i < a.Length; i++)
            if (TakesValue.Contains(a[i]) && (i + 1 >= a.Length || Known.Contains(a[i + 1])))
            {
                Console.Error.WriteLine($"{a[i]} 後面要接一個值\n\n{Usage}");
                return 2;
            }

        if (set.Contains("--version")) { Out($"Hearby {HearbyVersion.Version} (build {HearbyVersion.Build})"); return 0; }
        if (set.Contains("--doctor"))
        {
            var r = Doctor.Run(set.Contains("--deep"));
            Console.Write(r.Text);
            return r.AllOK ? 0 : 1;
        }
        if (set.Contains("--selftest"))
        {
            try
            {
                var made = Paths.Ensure();
                ConfigStore.Shared.Update(c => c.Scene = "meeting");
                ConfigStore.Shared.Reset();
                if (ConfigStore.Shared.Current.Scene != "meeting") { Out("✗ config 往返失敗"); return 1; }
                Out($"ok  資料夾：{Paths.Root}（新建 {made.Count} 個）");
                Out($"ok  config：{ConfigStore.Shared.Url}");
                Out($"ok  log：{HearbyLog.File}");
                Out($"ok  繁體轉換：{Clean.ToTraditional("会议记录")}");
                return 0;
            }
            catch (Exception e) { Out($"✗ {e.Message}"); return 1; }
        }
        if (set.Contains("--download-model")) return DownloadModel();

        var providerOverride = Value("--provider");
        IProvider Provider() => providerOverride != null ? Providers.Make(providerOverride) : Providers.Current();

        if (Value("--process") is { } dir)
        {
            if (!Directory.Exists(dir)) { Out($"✗ 找不到工作夾：{dir}"); return 1; }
            var m = MeetingMeta.Load(dir) ?? new MeetingMeta();
            if (m.Seconds <= 0) m.Seconds = (WavIO.DurationMs(Path.Combine(dir, "mic.wav")) ?? 0) / 1000.0;
            m.MicMax = 1; m.SysMax = 1;
            if (Value("--title") is { } t) m.Title = t;
            if (Value("--scene") is { } sc) m.Scene = sc;
            return RunPipeline(dir, m, Provider());
        }
        if (Value("--import") is { } file)
        {
            if (ModelCatalog.InstalledModel() == null)
            {
                Out($"✗ 還沒有聽打模型（{ModelCatalog.Default.File}）。先跑 Hearby.exe --download-model，或打開 Hearby 一次讓它下載。");
                return 1;
            }
            MediaImport.Probe probe;
            try { probe = MediaImport.Check(file); } catch (Exception e) { Out($"✗ {e.Message}"); return 1; }
            string work;
            try { work = Pipeline.NewWorkDir().Dir; } catch { Out($"✗ 建不了工作夾（{Pipeline.RecordingsDir} 寫不進去）"); return 1; }
            try
            {
                Out($"轉檔中…（{Fmt.Dur(probe.Seconds)}）");
                var secs = MediaImport.Transcode(probe, Path.Combine(work, "mic.wav"));
                var m = new MeetingMeta
                {
                    Started = DateTimeOffset.Now, Imported = true, SourceFile = Path.GetFullPath(file),
                    Title = Value("--title") ?? Path.GetFileNameWithoutExtension(file), Seconds = secs, MicMax = 1, SysMax = 0,
                };
                MeetingMeta.Save(m, work);
                return RunPipeline(work, m, Provider());
            }
            catch (Exception e)
            {
                Out($"✗ {e.Message}");
                try { File.WriteAllText(Path.Combine(work, ".ignored"), "import-failed"); } catch { }
                return 1;
            }
        }
        if (Value("--convert") is { } cf)
        {
            try
            {
                var probe = MediaImport.Check(cf);
                var outWav = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(cf))!, Path.GetFileNameWithoutExtension(cf) + ".16k.wav");
                var secs = MediaImport.Transcode(probe, outWav);
                var pcm = WavIO.ReadPcm(outWav, 0, (int)(secs * 1000));
                Out($"ok  {outWav}  {secs:0.00} 秒（容器標示 {probe.Seconds:0.00} 秒），最大音量 {WavIO.Level(pcm):0.000}");
                return 0;
            }
            catch (Exception e) { Out($"✗ {e.Message}"); return 1; }
        }
        if (Value("--repolish") is { } md)
        {
            int i = Array.IndexOf(a, "--repolish");
            var next = a.Length > i + 2 ? a[i + 2] : "";
            var corr = Known.Contains(next) ? "" : next;
            try
            {
                var (path, summary) = Repolish.Whole(md, corr, Provider(), s => Out("  " + s));
                Out($"ok  {path}\n{summary}");
                return 0;
            }
            catch (Exception e) { Out($"✗ {e.Message}"); return 1; }
        }
        foreach (var (flag, pdf) in new[] { ("--export-word", false), ("--export-pdf", true) })
        {
            if (Value(flag) is not { } mdw) continue;
            try
            {
                var h = DocHeader.Prefill(RecordMD.Read(mdw), DocLabels.LanguageOf(mdw));
                if (Value("--company") is { } c) h.Company = c;
                if (Value("--recorder") is { } r) h.Recorder = r;
                if (Value("--units") is { } u) h.Units = u;
                var outPath = pdf ? Exporters.Pdf(mdw, h) : Exporters.Word(mdw, h);
                Out($"ok  {outPath}");
                return 0;
            }
            catch (Exception e) { Out($"✗ {e.Message}"); return 1; }
        }
        if (Value("--record") is { } secsText && double.TryParse(secsText, System.Globalization.CultureInfo.InvariantCulture, out var seconds))
            return Record(seconds, Value("--source"), Value("--pause-at"), Value("--resume-at"), set.Contains("--no-process"), Value("--title"), Provider);
        if (set.Contains("--memory-rebuild")) return MemoryRebuild(Value("--memory-rebuild") is { } t && !Known.Contains(t) ? t : null);
        if (Value("--rename") is { } target)
        {
            int i = Array.IndexOf(a, "--rename");
            if (a.Length <= i + 2 || Known.Contains(a[i + 2])) { Console.Error.WriteLine($"--rename 後面要接兩個值：那一場的 md（或資料夾）、新標題\n\n{Usage}"); return 2; }
            return Rename(target, a[i + 2]);
        }
        Out(Usage);
        return 2;
    }

    /// --rename <md or folder> "<new title>": rename a meeting. Folder, files starting with the old name, record header, meta.json,
    /// memory ids and mirror copies change together
    static int Rename(string target, string title)
    {
        var dir = Path.GetFullPath(target);
        if (File.Exists(dir)) dir = Path.GetDirectoryName(dir)!;
        else if (!Directory.Exists(dir)) { Out($"✗ 找不到：{target}"); return 1; }
        dir = Path.TrimEndingDirectorySeparator(dir);
        if (!string.Equals(Path.GetDirectoryName(dir), Path.TrimEndingDirectorySeparator(Path.GetFullPath(Paths.Meetings)), StringComparison.OrdinalIgnoreCase))
        {
            Out($"✗ {dir} 不在 {Paths.Meetings} 底下：只改 Hearby 的會議");
            return 1;
        }
        try
        {
            var r = MeetingRename.Rename(dir, title);
            if (r.Unchanged) { Out("（標題一樣，沒有要改的）"); return 0; }
            Out($"ok  會議/{r.NewId}/（原本：{r.OldId}）");
            if (r.Renamed.Count > 0) Out($"  夾裡改名：{r.Renamed.Count} 個檔");
            if (!ConfigStore.Shared.Current.MemoryEnabled) Out("  記憶是關的，沒有動");
            else if (r.Memory.Count > 0) Out($"  記憶：{string.Join("、", r.Memory)}" + (r.Backups.Count == 0 ? "" : $"（改之前留了 {string.Join("、", r.Backups.Select(Path.GetFileName))}）"));
            if (r.Mirror.Count > 0) Out($"  副本：{string.Join("、", r.Mirror.Select(Path.GetFileName))}");
            foreach (var w in r.Warnings) Out($"⚠ {w}");
            return r.Warnings.Count == 0 ? 0 : 1;
        }
        catch (Exception e) { Out($"✗ {e.Message}"); return 1; }
    }

    /// --memory-rebuild [<md>]: memory follows the record. Hearby's untouched lines become the new version, the user's stay; <name>.bak-<date> before an existing line changes
    static int MemoryRebuild(string? target)
    {
        if (!ConfigStore.Shared.Current.MemoryEnabled) { Out("✗ 記憶是關的，這次沒有寫。到設定打開「記憶」再跑。"); return 1; }
        List<string> paths;
        if (target != null)
        {
            if (!File.Exists(target)) { Out($"✗ 找不到：{target}"); return 1; }
            if (!MemoryStore.IsMainRecord(target)) { Out($"✗ {Path.GetFileName(target)} 不是一場的主紀錄（翻譯檔、_舊版 備份不進記憶）"); return 1; }
            paths = [Path.GetFullPath(target)];
        }
        else
        {
            paths = MemoryStore.AllRecords();
            if (paths.Count == 0) { Out($"（{Paths.Meetings} 裡還沒有紀錄）"); return 0; }
        }
        bool failed = false;
        // one meeting, changed by another program: diff against what Hearby last wrote, changed names go into the name ledger (memory/NAMES.md)
        if (target != null)
        {
            if (NameLedger.LearnFromEdit(paths[0]) is { } learned) foreach (var e in learned) Out($"記住名字：{e.Heard} → {e.Name}（{e.How}）");
            else Out("（這份跟 Hearby 上次寫的不一樣，但找不到上次那一版的備份，改過的名字沒學到；下次改之前先留 .bak）");
        }
        foreach (var (p, rep, err) in MemoryStore.Sync(paths))
        {
            var id = Path.GetFileNameWithoutExtension(p);
            if (err != null) { Out($"✗ {id}：{err}"); failed = true; continue; }
            if (rep == null) { Out($"—  {id}：略過"); continue; }
            var line = $"ok  {id}：" + (rep.Changed.Count == 0 ? "已經是最新" : rep.IsNew ? "第一次寫進記憶" : "更新 " + string.Join("、", rep.Changed));
            if (rep.Kept > 0) line += $"；你改過或加的 {rep.Kept} 行照舊";
            Out(line);
            foreach (var b in rep.Backups) Out($"    備份：{Path.GetFileName(b)}");
        }
        return failed ? 1 : 0;
    }

    static int DownloadModel()
    {
        if (ModelCatalog.InstalledModel() is { } have) { Out($"ok  已經有了：{have}"); return 0; }
        var spec = ModelCatalog.Default;
        Out($"下載 {spec.File}（{spec.Bytes / 1_000_000} MB）…");
        var done = new ManualResetEventSlim();
        string? path = null, err = null;
        var d = ModelDownload.Start(spec, (p, e) => { path = p; err = e; done.Set(); });
        int last = -1;
        while (!done.Wait(2000))
        {
            int pct = (int)(d.Fraction * 100);
            if (pct != last) { last = pct; Out($"  {pct}%{(d.Phase == ModelDownload.Phases.Verifying ? "（校驗中）" : "")}"); }
        }
        if (path != null) { Out($"ok  {path}"); return 0; }
        Out($"✗ {err}");
        return 1;
    }

    static int Record(double secs, string? sourceText, string? pauseAtText, string? resumeAtText, bool noProcess, string? title, Func<IProvider> provider)
    {
        var src = sourceText == "online" ? AudioSource.Online : AudioSource.Room;
        string dir;
        try { dir = Pipeline.NewWorkDir().Dir; } catch { Out($"✗ 建不了工作夾（{Pipeline.RecordingsDir} 寫不進去）"); return 1; }
        var rec = new DualRecorder(dir, src);
        List<string> warns;
        try { warns = rec.Start(); } catch (Exception e) { Out($"✗ {e.Message}"); return 1; }
        Out($"錄音中 {(int)secs} 秒（{src.Label()}，麥克風：{rec.MicDeviceName}，系統聲：{(rec.SystemAudioActive ? rec.OutputDeviceName : "無")}）…");
        foreach (var w in warns) Out($"⚠ {w}");
        double? pauseAt = double.TryParse(pauseAtText, System.Globalization.CultureInfo.InvariantCulture, out var pa) ? pa : null;
        double? resumeAt = double.TryParse(resumeAtText, System.Globalization.CultureInfo.InvariantCulture, out var ra) ? ra : null;
        var t0 = DateTimeOffset.Now;
        using (Platform.KeepAwake?.Invoke("錄音中"))
        {
            while ((DateTimeOffset.Now - t0).TotalSeconds < secs)
            {
                Thread.Sleep(500);
                var t = (DateTimeOffset.Now - t0).TotalSeconds;
                if (pauseAt is { } p && t >= p && rec.Pauses.Count == 0 && rec.Pause()) Out($"  ⏸ 暫停（第 {t:0.0} 秒，已錄 {rec.RecordedSeconds:0.0} 秒）");
                if (resumeAt is { } r && t >= r && rec.IsPaused && rec.Resume()) Out($"  ▶ 繼續（第 {t:0.0} 秒）");
                Out($"  mic {rec.MicLevel:0.000}  sys {rec.SysLevel:0.000}{(rec.IsPaused ? "  （暫停中）" : "")}");
            }
        }
        var got = rec.Stop();
        var m = new MeetingMeta
        {
            Started = t0, Seconds = got, MicMax = rec.MicMax, SysMax = rec.SysMax, Source = src.Raw(), Warnings = warns,
            Pauses = rec.Pauses.Count == 0 ? null : rec.Pauses, Title = title ?? "錄音測試",
        };
        MeetingMeta.Save(m, dir);
        Out($"錄了 {Fmt.Dur(got)}：mic max {rec.MicMax:0.000} sys max {rec.SysMax:0.000} sysBuffers {rec.SysBufferCount} writeFailures {rec.WriteFailures} → {dir}");
        foreach (var p in rec.Pauses) Out($"  暫停：在第 {p.AtSeconds:0.0} 秒（錄到的時間），停了 {p.Seconds ?? -1:0.0} 秒");
        if (noProcess) return 0;
        return RunPipeline(dir, m, provider());
    }

    static int RunPipeline(string dir, MeetingMeta meta, IProvider provider)
    {
        var p = new Pipeline { OnStage = s => Out("  " + s) };
        try
        {
            var o = p.Process(dir, meta, provider);
            Out($"ok  {o.MdPath}");
            Out(o.Summary);
            if (o.PolishErr != null) Out($"⚠ 整理：{o.PolishErr}");
            return 0;
        }
        catch (Exception e) { Out($"✗ {e.Message}"); return 1; }
    }
}
