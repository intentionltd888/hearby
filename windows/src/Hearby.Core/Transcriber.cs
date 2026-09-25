// Transcriber — whisper transcription (slices, loop repair, degenerate-slice retry, resume). Mirrors Speech/Transcript.swift.
//
// One wav is cut into ~15-minute temporary slices (5 minutes when running on the CPU): cut points sit on silence,
// silent slices are skipped, each slice's JSON is kept (= resume), a failed slice is retried alone.
// The engine is behind IWhisperEngine: on Windows it is a child process of Hearby.exe (--transcribe-worker) using
// Whisper.net (Vulkan GPU when available, else CPU); tests plug in a fake that returns canned JSON.
using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Hearby.Core;

public sealed record WhisperRun(int Status, string Stderr, bool UsedGpu, bool TimedOut = false);

public interface IWhisperEngine
{
    /// Is the engine present at all (the macOS check was "is whisper-cli there")
    bool Available { get; }
    /// Transcribe wav → writes jsonBase + ".json" in whisper-cli -oj format. maxContext: -1 = default, 16 = the "-mc 16" retry
    WhisperRun Run(string model, string wav, string jsonBase, int maxContext, double timeoutSeconds, bool allowGpu);
}

public sealed class Transcriber
{
    public Action<string>? OnStage;
    void Stage(string s) => OnStage?.Invoke(s);

    public const int SliceTargetMs = 15 * 60_000;
    public const int SliceSearchMs = 30_000;
    public const float SliceSilence = 0.015f;
    /// Below this = truly no sound (the system track without an online meeting is digital silence)
    public const float QuietFloor = 0.0005f;
    public const float QuietGainMax = 1000f;
    public const int LoopMinRepeats = 6;
    public const int LoopMinSpanMs = 15_000;
    public const string Prompt = "以下是台灣繁體中文的會議對話逐字稿。";

    public List<string> Notes { get; } = [];
    /// null = not known yet; false = running on the CPU
    public bool? UsedGpu { get; private set; }

    public static IWhisperEngine? Engine { get; set; }

    /// Quiet slice (peak 0.1 s level below SliceSilence): boost it and transcribe instead of dropping it; null = skip as before.
    /// Reasoning and measurements: see Transcriber.quietBoost in the macOS source.
    public static float? QuietBoost(float[] lv, short[] pcm)
    {
        float peak = lv.Length == 0 ? 0 : lv.Max();
        if (!(peak > QuietFloor) || !(peak < SliceSilence)) return null;
        var sorted = (float[])lv.Clone();
        Array.Sort(sorted);
        float p25 = sorted[sorted.Length / 4];
        float p95 = sorted[Math.Min(sorted.Length - 1, sorted.Length * 95 / 100)];
        if (p25 > 0 && p95 < p25 * 2.5f) return null;
        int maxAbs = 0;
        foreach (var v in pcm) { int m = Math.Abs((int)v); if (m > maxAbs) maxAbs = m; }
        if (maxAbs <= 0) return null;
        return MathF.Min(QuietGainMax, 0.7f * 32767f / maxAbs);
    }

    public static List<(int, int)> PlanSlices(string wav, int totalMs, int targetMs = SliceTargetMs, IReadOnlyList<int>? forcedCuts = null) =>
        Split(SilenceSlices(wav, totalMs, targetMs), forcedCuts ?? []);

    internal static List<(int, int)> Split(List<(int, int)> slices, IReadOnlyList<int> cuts, int minMs = 2000)
    {
        if (cuts.Count == 0) return slices;
        var sortedCuts = cuts.OrderBy(c => c).ToList();
        var outList = new List<(int, int)>();
        foreach (var (a, b) in slices)
        {
            int start = a;
            foreach (var c in sortedCuts)
                if (c - start >= minMs && b - c >= minMs) { outList.Add((start, c)); start = c; }
            outList.Add((start, b));
        }
        return outList;
    }

    internal static List<(int, int)> SilenceSlices(string wav, int totalMs, int targetMs)
    {
        if (totalMs <= targetMs * 135 / 100) return [(0, totalMs)];
        var cuts = new List<int> { 0 };
        int mark = targetMs;
        while (totalMs - mark > targetMs * 35 / 100)
        {
            int a = Math.Max(cuts[^1] + 60_000, mark - SliceSearchMs);
            int b = Math.Min(totalMs, mark + SliceSearchMs);
            int best = mark;
            var lv = WavIO.BlockLevels(WavIO.ReadPcm(wav, a, b));
            if (lv.Length >= 5)
            {
                float sum = lv[0] + lv[1] + lv[2] + lv[3] + lv[4];
                float bestSum = sum; int bestI = 0;
                for (int i = 1; i + 5 <= lv.Length; i++)
                {
                    sum += lv[i + 4] - lv[i - 1];
                    if (sum < bestSum) { bestSum = sum; bestI = i; }
                }
                best = a + (bestI + 2) * 100 + 50;
            }
            cuts.Add(best);
            mark = best + targetMs;
        }
        cuts.Add(totalMs);
        var outList = new List<(int, int)>();
        for (int i = 0; i + 1 < cuts.Count; i++) outList.Add((cuts[i], cuts[i + 1]));
        return outList;
    }

    public sealed record Parsed(List<Segment> Segs, List<(int, int)> Loops, double RawRepeat);

    /// Parse whisper -oj JSON → segments, loop spans, raw repeat ratio. Bad UTF-8 bytes become U+FFFD instead of losing the slice
    public static Parsed ParseWhisperJson(string path, int offsetMs, string who)
    {
        var text = Encoding.UTF8.GetString(File.ReadAllBytes(path));
        JsonDocument doc;
        try { doc = JsonDocument.Parse(text); } catch { throw new HearbyError("whisper JSON 解析失敗"); }
        using var _ = doc;
        if (doc.RootElement.ValueKind != JsonValueKind.Object || !doc.RootElement.TryGetProperty("transcription", out var trans) || trans.ValueKind != JsonValueKind.Array)
            throw new HearbyError("whisper JSON 解析失敗");
        var segs = new List<Segment>();
        var loops = new List<(int, int)>();
        int lastTo = 0;
        string runText = ""; int runStart = 0, runEnd = 0, runCount = 0;
        int rawTotal = 0, rawDup = 0;
        void CloseRun() { if (runCount >= LoopMinRepeats && runEnd - runStart >= LoopMinSpanMs) loops.Add((runStart + offsetMs, runEnd + offsetMs)); }
        foreach (var t in trans.EnumerateArray())
        {
            if (t.ValueKind != JsonValueKind.Object || !t.TryGetProperty("text", out var te) || te.ValueKind != JsonValueKind.String) continue;
            var raw = te.GetString()!;
            int? fromN = null, toN = null;
            if (t.TryGetProperty("offsets", out var off) && off.ValueKind == JsonValueKind.Object)
            {
                if (off.TryGetProperty("from", out var f) && f.ValueKind == JsonValueKind.Number && f.TryGetInt32(out var fi)) fromN = fi;
                if (off.TryGetProperty("to", out var tt) && tt.ValueKind == JsonValueKind.Number && tt.TryGetInt32(out var ti)) toN = ti;
            }
            int from = fromN ?? lastTo;
            int to = toN ?? from;
            lastTo = Math.Max(lastTo, to);
            var rawTrim = Str.TrimWSNL(raw);
            rawTotal++;
            if (rawTrim == runText && rawTrim.Length > 0) { rawDup++; runCount++; runEnd = to; }
            else { CloseRun(); runText = rawTrim; runStart = from; runEnd = to; runCount = 1; }
            var clean = Clean.ToTraditional(Clean.NormalizePunct(rawTrim));
            double? nsp = t.TryGetProperty("no_speech_prob", out var ns) && ns.ValueKind == JsonValueKind.Number ? ns.GetDouble() : null;
            if (clean.Length == 0 || Hallucination.IsJunk(clean, new Hallucination.Signals(nsp, to - from))) continue;
            if (segs.Count > 0 && segs[^1].Text == clean) continue;
            segs.Add(new Segment(from + offsetMs, to + offsetMs, clean, who));
        }
        CloseRun();
        return new Parsed(segs, loops, rawTotal > 0 ? (double)rawDup / rawTotal : 0);
    }

    /// Whole-slice quality: repetition, missing punctuation, "某某:" prefix latch
    public static (bool Bad, double Score) Degeneracy(List<Segment> segs, double rawRepeatRatio = 0)
    {
        if (segs.Count < 8) return (false, 1);
        var texts = segs.Select(s => s.Text).ToList();
        var all = string.Concat(texts);
        int allCount = Str.Count(all);
        if (allCount <= 200) return (false, 1);
        int punct = Str.Chars(all).Count(c => "，。？！、,.?!".Contains(c, StringComparison.Ordinal) && c.Length == 1);
        double punctRatio = (double)punct / allCount;
        var prefixes = new Dictionary<string, int>();
        foreach (var t in texts)
        {
            var chars = Str.Chars(t);
            int idx = chars.FindIndex(c => c == ":" || c == "：");
            if (idx < 0) continue;
            var p = string.Concat(chars.Take(idx));
            int pc = Str.Count(p);
            if (pc >= 1 && pc <= 8) prefixes[p] = prefixes.GetValueOrDefault(p) + 1;
        }
        double latchRatio = (double)(prefixes.Count == 0 ? 0 : prefixes.Values.Max()) / texts.Count;
        bool bad = rawRepeatRatio > 0.25 || punctRatio < 0.02 || latchRatio > 0.3;
        return (bad, punctRatio - rawRepeatRatio - latchRatio);
    }

    WhisperRun RunWhisper(string model, string wav, string jsonBase, int maxContext, double timeout)
    {
        var engine = Engine ?? throw new HearbyError("聽打引擎沒有接上");
        return engine.Run(model, wav, jsonBase, maxContext, timeout, allowGpu: ConfigStore.Shared.Current.UseGPUOn && UsedGpu != false);
    }

    (List<Segment>, int) RepairLoops(List<Segment> segs, List<(int, int)> loops, int sliceFrom, int sliceTo, string wav, string who,
        string name, string label, string workDir, string sliceDir, string model)
    {
        var outList = new List<Segment>(segs);
        int fixedN = 0;
        var giveUps = new List<(int, int)>();
        var merged = new List<(int, int)>();
        foreach (var l in loops.OrderBy(x => x.Item1))
        {
            if (merged.Count > 0 && l.Item1 - merged[^1].Item2 < 10_000) merged[^1] = (merged[^1].Item1, Math.Max(merged[^1].Item2, l.Item2));
            else merged.Add(l);
        }
        for (int k = 0; k < merged.Count; k++)
        {
            var (ls, le) = merged[k];
            if (k >= 4) { giveUps.Add((ls, le)); continue; }
            int a = Math.Max(sliceFrom, ls - 3000);
            int b = Math.Min(sliceTo, le + 3000);
            var overlapping = outList.Where(s => s.ToMs > a && s.FromMs < b).ToList();
            if (overlapping.Count > 0) a = Math.Max(sliceFrom, Math.Min(a, overlapping.Min(s => s.FromMs)));
            if (overlapping.Count > 0) b = Math.Min(sliceTo, Math.Max(b, overlapping.Max(s => s.ToMs)));
            if (b - a < 5000) continue;
            var winLv = WavIO.BlockLevels(WavIO.ReadPcm(wav, a, b));
            if ((winLv.Length == 0 ? 0 : winLv.Max()) < SliceSilence)
            {
                outList.RemoveAll(s => s.ToMs > a && s.FromMs < b);
                fixedN++;
                continue;
            }
            var fixName = $"{name}-fix{k}";
            var fixJson = Path.Combine(workDir, fixName + ".json");
            Parsed? result = File.Exists(fixJson) ? TryParse(fixJson, a, who) : null;
            if (result == null)
            {
                var fixWav = Path.Combine(sliceDir, fixName + ".wav");
                if (!WavIO.WriteSlice(wav, a, b, fixWav)) { giveUps.Add((ls, le)); continue; }
                Parsed? best = null;
                int bestResidue = int.MaxValue;
                for (int pass = 0; pass < 2; pass++)
                {
                    RunWhisper(model, fixWav, Path.Combine(workDir, fixName), pass == 1 ? 16 : -1, Math.Max(120, (b - a) / 1000.0 * 4));
                    var r = TryParse(fixJson, a, who);
                    if (r == null) break;
                    int residue = r.Loops.Sum(x => x.Item2 - x.Item1);
                    if (residue < bestResidue) { bestResidue = residue; best = r; }
                    if (residue < 8000) break;
                    TryDelete(fixJson);
                }
                result = best;
                if (bestResidue >= 8000) giveUps.Add((ls, le));
                if (best == null) TryDelete(fixJson);
                TryDelete(fixWav);
            }
            if (result == null || result.Segs.Count == 0) { giveUps.Add((ls, le)); continue; }
            outList.RemoveAll(s => s.ToMs > a && s.FromMs < b);
            outList.AddRange(result.Segs);
            fixedN++;
        }
        if (giveUps.Count > 0)
        {
            var spans = string.Join("、", giveUps.Take(3).Select(x => $"{Fmt.Ts(x.Item1)}–{Fmt.Ts(x.Item2)}"));
            var more = giveUps.Count > 3 ? $"等 {giveUps.Count} 處" : "";
            Notes.Add($"{label}音軌 {spans}{more} 語音辨識出現重複迴圈、自動重轉未能完全修復，這幾段可能不完整");
        }
        outList.Sort((x, y) => x.FromMs.CompareTo(y.FromMs));
        return (outList, fixedN);
    }

    static Parsed? TryParse(string json, int offset, string who) { try { return File.Exists(json) ? ParseWhisperJson(json, offset, who) : null; } catch { return null; } }
    static void TryDelete(string p) { try { if (File.Exists(p)) File.Delete(p); } catch { } }

    /// Transcribe one track. Empty/unreadable file = empty list + a note (does not throw).
    /// cuts = positions (ms) that must be cut (mid pauses), see PlanSlices
    public List<Segment> Transcribe(string wav, string who, string label, string workDir, string track, IReadOnlyList<int>? cuts = null, Action<List<Segment>>? onPartial = null)
    {
        cuts ??= [];
        if (Engine is not { Available: true }) throw new HearbyError("找不到聽打引擎（請重新安裝 Hearby）");
        var model = ModelCatalog.InstalledModel() ?? throw new HearbyError($"找不到聽打模型（{ModelCatalog.Default.File}）");
        if (WavIO.DurationMs(wav) is not { } totalMs || totalMs <= 0)
        {
            Notes.Add($"{label}音軌沒有錄到任何內容（檔案是空的），這份紀錄不含這一軌");
            return [];
        }
        HearbyLog.Write($"transcribe start {track} {totalMs / 60000}min");
        int target = UsedGpu == false ? 5 * 60_000 : SliceTargetMs;
        var slices = PlanSlices(wav, totalMs, target, cuts);
        var sliceDir = Path.Combine(workDir, "slices");
        Directory.CreateDirectory(sliceDir);
        var segs = new List<Segment>();
        var failed = new List<(int, int)>();
        int skipped = 0;
        var quietSpans = new List<(int, int)>();
        var boostedSpans = new List<(int, int)>();
        int loopFixes = 0, degenFixes = 0;
        var degenLeft = new List<(int, int)>();
        long ranMs = 0;
        double ranSecs = 0;
        var partial = Path.Combine(workDir, $"transcript.partial-{track}.md");

        for (int i = 0; i < slices.Count; i++)
        {
            var (a, b) = slices[i];
            var name = $"{track}-w{Str.D2(i)}" + (cuts.Count == 0 ? "" : $"-{a / 1000}s");
            var jsonUrl = Path.Combine(workDir, name + ".json");
            double speed = (ranMs > 0 && ranSecs > 0) ? ranMs / ranSecs : (UsedGpu == false ? 700.0 : 15000.0);
            long remainMs = slices.Skip(i).Sum(x => (long)(x.Item2 - x.Item1));
            var eta = $"・約剩 {Fmt.Dur(remainMs / speed)}";
            var cpuNote = UsedGpu == false ? "（本機以 CPU 轉寫，較慢）" : "";
            Stage(slices.Count > 1 ? $"聽打{label} {i + 1}/{slices.Count}{eta}{cpuNote}" : $"聽打{label}…{cpuNote}");

            Parsed? parsed = File.Exists(jsonUrl) ? TryParse(jsonUrl, a, who) : null;
            var silentFlag = Path.Combine(workDir, name + ".silent");
            if (parsed == null && File.Exists(silentFlag)) { skipped++; continue; }
            var boostFlag = Path.Combine(workDir, name + ".boosted");
            if (parsed == null)
            {
                var pcm = WavIO.ReadPcm(wav, a, b);
                var lv = WavIO.BlockLevels(pcm);
                float peak = lv.Length == 0 ? 0 : lv.Max();
                float? gain = null;
                if (peak < SliceSilence)
                {
                    gain = QuietBoost(lv, pcm);
                    if (gain == null)
                    {
                        skipped++;
                        if (peak > QuietFloor) quietSpans.Add((a, b));
                        File.WriteAllText(silentFlag, "silent");
                        continue;
                    }
                }
                var sliceUrl = Path.Combine(sliceDir, name + ".wav");
                if (gain is { } g)
                {
                    if (!WavIO.WritePcm(pcm, g, sliceUrl)) { failed.Add((a, b)); continue; }
                    File.WriteAllText(boostFlag, "boosted");
                    HearbyLog.Write($"quiet boost {name} level={Fmt.Inv(peak, "0.0000")} gain={Fmt.Inv(g, "0")}x");
                }
                else if (!WavIO.WriteSlice(wav, a, b, sliceUrl)) { failed.Add((a, b)); continue; }
                var sw = Stopwatch.StartNew();
                for (int attempt = 1; attempt <= 2; attempt++)
                {
                    var r = RunWhisper(model, sliceUrl, Path.Combine(workDir, name), -1, Math.Max(600, (b - a) / 1000.0 * 4));
                    if (UsedGpu == null) { UsedGpu = r.UsedGpu; HearbyLog.Write($"whisper gpu={UsedGpu == true}"); }
                    if (File.Exists(jsonUrl) && TryParse(jsonUrl, a, who) is { } p) { parsed = p; break; }
                    TryDelete(jsonUrl);
                    HearbyLog.Write($"whisper {name} attempt {attempt} fail ({r.Status}): {Tail(r.Stderr, 200)}");
                    // GPU trouble (driver lost the device, out of VRAM): the retry of this slice runs on the CPU
                    if (r.UsedGpu) UsedGpu = false;
                }
                TryDelete(sliceUrl);
                ranSecs += sw.Elapsed.TotalSeconds;
                ranMs += b - a;
                if (parsed == null) { failed.Add((a, b)); continue; }
            }
            bool boosted = File.Exists(boostFlag);
            if (boosted)
            {
                if (parsed == null || parsed.Segs.Count == 0) { skipped++; quietSpans.Add((a, b)); continue; }
                boostedSpans.Add((a, b));
            }
            var sliceSegs = parsed?.Segs ?? [];
            var deg = Degeneracy(sliceSegs, parsed?.RawRepeat ?? 0);
            if (deg.Bad && sliceSegs.Count > 0)
            {
                var retryJson = Path.Combine(workDir, name + "-r.json");
                Parsed? retry = File.Exists(retryJson) ? TryParse(retryJson, a, who) : null;
                if (retry == null)
                {
                    var sliceUrl = Path.Combine(sliceDir, name + "-r.wav");
                    bool wrote = false;
                    if (boosted)
                    {
                        var pcm = WavIO.ReadPcm(wav, a, b);
                        if (QuietBoost(WavIO.BlockLevels(pcm), pcm) is { } g2) wrote = WavIO.WritePcm(pcm, g2, sliceUrl);
                    }
                    else wrote = WavIO.WriteSlice(wav, a, b, sliceUrl);
                    if (wrote)
                    {
                        HearbyLog.Write($"degen retry {name} score={Fmt.Inv(deg.Score, "0.000")}");
                        RunWhisper(model, sliceUrl, Path.Combine(workDir, name + "-r"), 16, Math.Max(600, (b - a) / 1000.0 * 4));
                        retry = TryParse(retryJson, a, who);
                        TryDelete(sliceUrl);
                    }
                }
                if (retry != null && retry.Segs.Count > 0 && Degeneracy(retry.Segs, retry.RawRepeat).Score > deg.Score)
                {
                    parsed = retry; sliceSegs = retry.Segs; degenFixes++;
                }
                else degenLeft.Add((a, b));
            }
            if (parsed != null && parsed.Loops.Count > 0)
            {
                var (fixedSegs, n) = RepairLoops(sliceSegs, parsed.Loops, a, b, wav, who, name, label, workDir, sliceDir, model);
                sliceSegs = fixedSegs;
                loopFixes += n;
            }
            foreach (var s in sliceSegs)
            {
                if (segs.Count > 0 && segs[^1].Text == s.Text) continue;
                segs.Add(s);
            }
            try { File.WriteAllText(partial, string.Join("\n", segs.Select(s => $"- [{Fmt.Ts(s.FromMs)}] {s.Text}")), new UTF8Encoding(false)); } catch { }
            onPartial?.Invoke(segs);
        }
        try { if (Directory.Exists(sliceDir) && !Directory.EnumerateFileSystemEntries(sliceDir).Any()) Directory.Delete(sliceDir); } catch { }

        int attempted = slices.Count - skipped;
        if (attempted > 0 && failed.Count == attempted) throw new HearbyError($"聽打失敗（{label} {attempted} 片全部失敗，請重試）");
        if (failed.Count > 0)
        {
            var spans = string.Join("、", failed.Take(3).Select(x => $"{Fmt.Ts(x.Item1)}–{Fmt.Ts(x.Item2)}"));
            Notes.Add($"{label}音軌 {spans}{(failed.Count > 3 ? $"等 {failed.Count} 段" : "")} 聽打失敗、內容缺（原始錄音仍在，可以按「補整理」重跑）");
        }
        if (quietSpans.Count > 0)
        {
            var spans = string.Join("、", quietSpans.Take(3).Select(x => $"{Fmt.Ts(x.Item1)}–{Fmt.Ts(x.Item2)}"));
            Notes.Add($"{label}音軌 {spans}{(quietSpans.Count > 3 ? $"等 {quietSpans.Count} 段" : "")} 音量太小，未聽打");
        }
        if (boostedSpans.Count > 0)
        {
            var spans = string.Join("、", boostedSpans.Take(3).Select(x => $"{Fmt.Ts(x.Item1)}–{Fmt.Ts(x.Item2)}"));
            Notes.Add($"{label}音軌 {spans}{(boostedSpans.Count > 3 ? $"等 {boostedSpans.Count} 段" : "")} 音量很小，已放大後聽打，這幾段可能比較不準");
        }
        if (degenLeft.Count > 0)
        {
            var spans = string.Join("、", degenLeft.Take(2).Select(x => $"{Fmt.Ts(x.Item1)}–{Fmt.Ts(x.Item2)}"));
            Notes.Add($"{label}音軌 {spans} 附近語音辨識品質異常（重複或缺標點），內容可能不完整");
        }
        if (UsedGpu == false && !Notes.Any(n => n.Has("CPU"))) Notes.Add("本機聽打未使用 GPU 加速（以 CPU 進行，時間較長）");
        HearbyLog.Write($"transcribe done {track} {slices.Count}片 skip={skipped} fail={failed.Count} loopfix={loopFixes} degen={degenFixes} ran={(int)ranSecs}s/{ranMs / 1000}s gpu={UsedGpu == true}");
        return segs;
    }

    static string Tail(string s, int n) => s.Length <= n ? s : s[^n..];

    // ── Echo removal (speakerphone: every remote sentence comes back through the mic) ──

    public static HashSet<string> Bigrams(string s)
    {
        var c = Str.Chars(s).Where(Str.IsLetterOrNumber).ToList();
        if (c.Count < 2) return c.Count == 0 ? [] : [string.Concat(c)];
        var g = new HashSet<string>();
        for (int i = 0; i < c.Count - 1; i++) g.Add(c[i] + c[i + 1]);
        return g;
    }

    public static double BigramContainment(string a, string b)
    {
        var ga = Bigrams(a); var gb = Bigrams(b);
        if (ga.Count == 0 || gb.Count == 0) return 0;
        return (double)ga.Count(x => gb.Contains(x)) / ga.Count;
    }

    public static string RemoteTextAround(List<Segment> sysSegs, Segment s) =>
        string.Concat(sysSegs.Where(x => x.ToMs >= s.FromMs - 8000 && x.FromMs <= s.ToMs + 8000).Select(x => x.Text));

    /// Before the model: merge consecutive lines of the same speaker into ~220-character chunks
    public static string MergedForLLM(string transcript)
    {
        var chunks = new List<(string Ts, string Who, string Text, bool Marker)>();
        foreach (var line in Str.Lines(transcript))
        {
            var l = Str.TrimWS(line);
            // pause markers stay where they are (not merged into speech)
            if (PauseSpan.IsMarker(l)) { chunks.Add(("", "", l, true)); continue; }
            if (!l.Starts("- [")) continue;
            int tsEnd = l.Find("][");
            if (tsEnd < 0) continue;
            int whoEnd = l.Find("] ", tsEnd + 2);
            if (whoEnd < 0) continue;
            var ts = l[3..tsEnd];
            var who = l[(tsEnd + 2)..whoEnd];
            var text = Str.TrimWS(l[(whoEnd + 2)..]);
            if (text.Length == 0) continue;
            if (chunks.Count > 0 && !chunks[^1].Marker && chunks[^1].Who == who && Str.Count(chunks[^1].Text) + Str.Count(text) <= 220)
                chunks[^1] = chunks[^1] with { Text = chunks[^1].Text + " " + text };
            else chunks.Add((ts, who, text, false));
        }
        if (!chunks.Any(c => !c.Marker)) return transcript;
        return string.Join("\n", chunks.Select(c => c.Marker ? c.Text : $"- [{c.Ts}][{c.Who}] {c.Text}"));
    }
}
