// Pipeline — one recording from wav to record: repair headers → transcribe both tracks → scenario + echo removal → alias feedback →
// transcript version saved first → m4a → provider polish → final version → memory. Output lands in ~/Hearby/會議/<name>/.
// Mirrors Pipeline.swift. Platform pieces (m4a encoding, keeping the PC awake, recycle bin) come in through Platform.
using System.Globalization;
using System.Text;

namespace Hearby.Core;

public interface IM4aEncoder
{
    /// Mix mic.wav + system.wav in dir into dest (.m4a). false = could not (the WAV tracks stay in the work folder)
    bool Mix(string dir, string dest, double seconds);
    /// Duration of an existing m4a (null = unreadable)
    double? DurationSeconds(string path);
}

public static class Platform
{
    public static IM4aEncoder? M4a { get; set; }
    /// Keep the computer from idle-sleeping while this handle lives
    public static Func<string, IDisposable>? KeepAwake { get; set; }
    /// Move a file or folder to the recycle bin (recoverable). null = leave it
    public static Action<string>? Trash { get; set; }
}

public sealed class Pipeline
{
    public Action<string>? OnStage;
    public Action<string>? OnPartialTranscript;
    void Stage(string s) => OnStage?.Invoke(s);

    public const float Silence = 0.015f;

    /// Recording work folders (app data, not the user's folder)
    public static string RecordingsDir => Path.Combine(Paths.Support, "recordings");

    public sealed record Output(string MdPath, string MeetingDir, string Summary, string? PolishErr);

    public Output Process(string dir, MeetingMeta rawMeta, IProvider provider)
    {
        var meta = rawMeta;
        var micWav = Path.Combine(dir, "mic.wav");
        var sysWav = Path.Combine(dir, "system.wav");
        if (meta.MicMax == 0 && meta.SysMax == 0) { meta.MicMax = 1; meta.SysMax = 1; }
        meta.Seconds = Fmt.ClampSeconds(meta.Seconds);
        if (meta.Seconds <= 0) meta.Seconds = Math.Max(WavIO.DurationMs(micWav) ?? 0, WavIO.DurationMs(sysWav) ?? 0) / 1000.0;
        var warnings = new List<string>(meta.Warnings);
        var segs = new List<Segment>();
        var attendeeNames = Str.TrimWSNL(meta.Attendees);
        var scenario = MeetingScenarioExt.FromRaw(meta.Scenario);
        var micWho = scenario?.MicWho() ?? "我方";
        using var awake = Platform.KeepAwake?.Invoke("會議紀錄整理中");
        HearbyLog.Write($"pipeline start {(int)meta.Seconds}s provider={provider.Id}");
        WavIO.RepairHeader(micWav);
        WavIO.RepairHeader(sysWav);

        var tr = new Transcriber { OnStage = s => Stage(s) };
        var aliasTable = Clean.AliasTable();
        void Partial(List<Segment> s) => OnPartialTranscript?.Invoke(string.Join("\n", s.TakeLast(6).Select(x => $"[{Fmt.Ts(x.FromMs)}] {x.Text}")));
        var trackErrors = new List<string>();
        var pauses = meta.Pauses ?? [];
        var pauseCuts = PauseSpan.MidPauses(pauses, meta.Seconds).Select(p => p.AtMs).ToList();
        if (File.Exists(micWav) && meta.MicMax >= Silence)
        {
            try { segs.AddRange(tr.Transcribe(micWav, micWho, "房間裡（麥克風）", dir, "mic", pauseCuts, Partial)); }
            catch (Exception e) { trackErrors.Add(e.Message); warnings.Add($"麥克風軌聽打失敗（{e.Message}）"); }
        }
        else warnings.Add("麥克風軌無聲，未聽打");
        if (File.Exists(sysWav) && meta.SysMax >= Silence)
        {
            try { segs.AddRange(tr.Transcribe(sysWav, "遠端", "電腦裡（系統聲音）", dir, "sys", pauseCuts, Partial)); }
            catch (Exception e) { trackErrors.Add(e.Message); warnings.Add($"系統聲音軌聽打失敗（{e.Message}）"); }
        }
        else if (meta.SysMax < Silence && File.Exists(sysWav)) warnings.Add("系統聲音軌全程無聲（會議可能沒有遠端聲音）");
        warnings.AddRange(tr.Notes);
        if (segs.Count == 0)
        {
            var why = trackErrors.FirstOrDefault() ?? (meta.Imported == true ? "這個檔案裡沒有偵測到語音內容" : "兩軌都沒有偵測到語音內容");
            if (!Directory.Exists(dir)) why = $"找不到這個工作夾：{Path.GetFileName(dir)}";
            else if (!File.Exists(micWav) && !File.Exists(sysWav)) why = "這個工作夾裡沒有錄音檔（mic.wav／system.wav）";
            else if (trackErrors.Count == 0 && tr.Notes.FirstOrDefault(n => n.Has("音量太小") || n.Has("空的")) is { } note) why += $"（{note}）";
            // nothing to transcribe will not change on a rerun: mark it so the panel stops offering 「補整理」
            if (trackErrors.Count == 0 && Directory.Exists(dir)) { try { File.WriteAllText(Path.Combine(dir, ".ignored"), "no-speech"); } catch { } }
            throw new HearbyError(why);
        }

        // alias feedback (gets better with use)
        if (aliasTable.Count > 0)
        {
            int n = 0;
            segs = segs.Select(s => { var (t, k) = Clean.ApplyAliases(s.Text, aliasTable); n += k; return s with { Text = t }; }).ToList();
            if (n > 0) HearbyLog.Write($"alias applied {n}");
        }

        // scenario: both tracks present and ≥15% of mic lines repeat the remote side = speakerphone echo
        if (scenario == null)
        {
            var sysSegs = segs.Where(s => s.Who == "遠端").ToList();
            var micSegs = segs.Where(s => s.Who != "遠端").ToList();
            if (sysSegs.Count > 0 && micSegs.Count > 0)
            {
                int dup = micSegs.Count(s => Transcriber.BigramContainment(s.Text, Transcriber.RemoteTextAround(sysSegs, s)) >= 0.6);
                if ((double)dup / micSegs.Count >= 0.15) scenario = MeetingScenario.OnlineSpeaker;
            }
        }
        if (scenario == MeetingScenario.OnlineSpeaker)
        {
            var sysSegs = segs.Where(s => s.Who == "遠端").ToList();
            if (sysSegs.Count > 0)
            {
                int before = segs.Count;
                segs.RemoveAll(s => s.Who == micWho && Transcriber.Bigrams(s.Text).Count > 0 && Transcriber.BigramContainment(s.Text, Transcriber.RemoteTextAround(sysSegs, s)) >= 0.75);
                int removed = before - segs.Count;
                if (removed > 0) warnings.Add($"迴聲去重：移除 {removed} 句與遠端重複的迴聲");
            }
        }
        segs = segs.OrderBy(s => s.FromMs).ToList();   // stable, like Swift's sort on these keys
        if (scenario == MeetingScenario.OnlineHeadphones && !segs.Any(s => s.Who == "遠端")) scenario = null;
        bool onsiteFallback = scenario == null && !segs.Any(s => s.Who == "遠端");
        var lines = segs.Select(s => (s.FromMs, $"- [{Fmt.Ts(s.FromMs)}][{(onsiteFallback && s.Who == "我方" ? "現場" : s.Who)}] {s.Text}")).ToList();
        var transcript = string.Join("\n", PauseSpan.Weave(lines, pauses, meta.Seconds));
        try { File.WriteAllText(Path.Combine(dir, "transcript.md"), transcript, new UTF8Encoding(false)); } catch { }
        meta.Scenario = scenario?.Raw();

        // names and places
        var dateStr = HearbyTime.Local(meta.Started).ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
        var durStr = Fmt.Dur(meta.Seconds);
        var scene = RecordSceneExt.FromRaw(meta.Scene ?? "meeting") ?? RecordScene.Meeting;
        var baseName = Paths.MeetingFolderName(meta.Started, meta.Title.Length == 0 ? scene.MdTitle() : meta.Title);
        var name = baseName;
        if (meta.OutName is { Length: > 0 } prev && System.Text.RegularExpressions.Regex.Replace(prev, @"-\d+$", "") == baseName) name = prev;
        else
        {
            int k = 2;
            while (Directory.Exists(Path.Combine(Paths.Meetings, name))) { name = baseName + $"-{k}"; k++; }
            meta.OutName = name;
        }
        var meetingDir = Path.Combine(Paths.Meetings, name);
        Directory.CreateDirectory(meetingDir);
        // once the transcript version is on disk the meeting is in the list; the final version is written at the end: no renaming meanwhile
        using var busy = MeetingBusy.Scope(meetingDir);
        var mdPath = Path.Combine(meetingDir, name + ".md");
        var m4aDest = Path.Combine(meetingDir, name + ".m4a");
        MeetingMeta.Save(meta, dir);

        // transcript version first (whatever happens next, this much is on disk)
        Stage("先存逐字稿版…");
        var input = new Polish.Input(Transcriber.MergedForLLM(transcript), meta.Title, attendeeNames, dateStr, durStr, warnings, dir)
        {
            Onsite = onsiteFallback, Scenario = scenario, OnsiteCount = meta.OnsiteCount, Brief = meta.Brief ?? [], Scene = scene,
            PauseNote = PauseSpan.Note(pauses, meta.Seconds),
        };
        var (interim0, _, _) = Polish.BuildNotes(input, null);
        var interim = Clean.ToTraditional(interim0.Rep(
            "（只有逐字稿：這場沒有接 AI 整理。逐字稿完整保留於下；到設定選「用我的訂閱」後，可用「重新整理全篇」補整理）",
            "（AI 整理進行中——若這一行一直在，代表整理沒跑完：打開這場紀錄按「重新整理全篇」即可補整理；逐字稿已完整保留於下）"));
        RecordMD.BackupIfExists(mdPath);
        RecordMD.Write(mdPath, interim);

        Stage("壓製音檔（m4a）…");
        bool m4aOK = M4aLooksComplete(m4aDest, dir) || (Platform.M4a?.Mix(dir, m4aDest, meta.Seconds) ?? false);
        if (!m4aOK) warnings.Add($"音檔混音未完成，原始分軌錄音仍在工作資料夾：{dir}");

        Stage(provider.Id == "none" ? "整理逐字稿…" : meta.Scene == "note" ? "AI 整理成筆記…" : meta.Scene == "interview" ? "AI 整理成訪談稿…" : "AI 整理中…（判斷與會者、整理摘要與待辦）");
        input.Warnings = warnings;
        input.AudioLine = m4aOK ? m4aDest : dir;
        input.Context = PolishContext.Load(name);   // only when memory has a roster (none = as before)
        var (md0, summary0, polishErr) = Polish.BuildNotes(input, provider);
        var keep = input.Context?.Names ?? [];   // roster names are not converted (涂 is not 塗)
        var md = Clean.ToTraditional(md0, keep);
        var summary = Clean.ToTraditional(summary0, keep);
        meta.Provider = provider.Id;
        MeetingMeta.Save(meta, dir);

        Stage("存檔中…");
        try { if (RecordMD.Read(mdPath) != interim) RecordMD.BackupIfExists(mdPath); } catch { }
        RecordMD.Write(mdPath, md);
        try { File.WriteAllText(Path.Combine(dir, "notes.md"), md, new UTF8Encoding(false)); } catch { }
        MeetingMeta.Save(meta, meetingDir);
        try { Mirror.Copy(mdPath); } catch { }
        EntryFiles.Ensure();
        try { MemoryStore.Sync(mdPath); } catch (Exception e) { HearbyLog.Write($"memory sync fail: {e.Message}"); }
        HearbyLog.Write($"pipeline done → {Path.GetFileName(mdPath)} err={polishErr ?? "-"}");
        return new Output(mdPath, meetingDir, summary, polishErr);
    }

    public static bool M4aLooksComplete(string dest, string dir)
    {
        if (!File.Exists(dest)) return false;
        int wavMs = Math.Max(WavIO.DurationMs(Path.Combine(dir, "mic.wav")) ?? 0, WavIO.DurationMs(Path.Combine(dir, "system.wav")) ?? 0);
        if (wavMs <= 0) return false;
        double want = wavMs / 1000.0;
        var d = Platform.M4a?.DurationSeconds(dest);
        return d is { } x && double.IsFinite(x) && x > 0 && Math.Abs(x - want) <= Math.Max(3, want * 0.05);
    }

    // ── Recovery: recordings that were never organised ──

    public sealed record RecoveryItem(string Dir, DateTime? Started, double Seconds, string Title)
    {
        public bool LooksLikeTest => Seconds < 60;
    }

    /// Work folder names: yyyyMMdd_HHmmss (Gregorian, invariant digits whatever the system calendar)
    public static string Stamp(DateTime local) => local.ToString("yyyyMMdd_HHmmss", CultureInfo.InvariantCulture);

    /// New work folder, created right away. Same second taken = -2, -3… (two imports in one second must not share a folder)
    public static (string Dir, string Stamp) NewWorkDir(DateTime? now = null)
    {
        Directory.CreateDirectory(RecordingsDir);
        var b = Stamp(now ?? DateTime.Now);
        var name = b;
        for (int k = 2; ; k++)
        {
            var d = Path.Combine(RecordingsDir, name);
            if (!Directory.Exists(d) && !File.Exists(d)) { Directory.CreateDirectory(d); return (d, name); }
            name = $"{b}-{k}";
            if (k > 200) throw new HearbyError("建不了工作夾");
        }
    }

    public static List<RecoveryItem> PendingRecoveries()
    {
        var items = new List<RecoveryItem>();
        if (!Directory.Exists(RecordingsDir)) return items;
        foreach (var d in Directory.EnumerateDirectories(RecordingsDir))
        {
            var mic = Path.Combine(d, "mic.wav"); var sys = Path.Combine(d, "system.wav");
            if (!(File.Exists(mic) || File.Exists(sys)) || File.Exists(Path.Combine(d, "notes.md")) || File.Exists(Path.Combine(d, ".ignored"))) continue;
            var secs = Math.Max(WavIO.Seconds(mic) ?? 0, WavIO.Seconds(sys) ?? 0);
            if (secs < 5) continue;
            var n = Path.GetFileName(d);
            DateTime? started = n.Length >= 15 && DateTime.TryParseExact(n[..15], "yyyyMMdd_HHmmss", CultureInfo.InvariantCulture, DateTimeStyles.None, out var st) ? st : null;
            items.Add(new RecoveryItem(d, started, secs, MeetingMeta.Load(d)?.Title ?? ""));
        }
        return items.OrderByDescending(i => i.Started ?? DateTime.MinValue).ToList();
    }

    /// After 30 days, organised work folders go to the recycle bin (recoverable). Folders whose record still points at them stay.
    public static void RetentionSweep(int days = 30)
    {
        if (Platform.Trash is not { } trash || !Directory.Exists(RecordingsDir)) return;
        var cutoff = DateTime.Now.AddDays(-days);
        foreach (var d in Directory.EnumerateDirectories(RecordingsDir))
        {
            bool ignored = File.Exists(Path.Combine(d, ".ignored"));
            var notes = Path.Combine(d, "notes.md");
            if (!ignored && !File.Exists(notes)) continue;
            try { if (File.Exists(notes) && File.ReadAllText(notes, Encoding.UTF8).Has($"> 音檔：{d}")) continue; } catch { continue; }
            DateTime mod; try { mod = Directory.GetLastWriteTime(d); } catch { continue; }
            if (mod < cutoff) { try { trash(d); } catch { } }
        }
    }
}
