// Polish — polish → assemble → summary (first run and re-polish share it); guards in PolishGuards. Mirrors Polish/Polish.swift.
using System.Text;
using System.Text.RegularExpressions;

namespace Hearby.Core;

public static class Polish
{
    static readonly Regex StampRe = new(@"\s*\[(?:\d{1,2}:)?\d{1,3}:[0-5]\d\]", RegexOptions.CultureInvariant);

    /// Deterministic rebuild of the 「會前重點對照」 section
    public static string NormalizeBriefLedger(string notesMD, List<string> brief, string? extraRows = null)
    {
        var modelRows = extraRows != null ? Str.Lines(extraRows).ToList() : [];
        var body = notesMD;
        int start = notesMD.Find("## 會前重點對照");
        if (start >= 0)
        {
            int afterStart = start + "## 會前重點對照".Length;
            var after = notesMD[afterStart..];
            int end = after.Find("\n## ");
            if (end >= 0)
            {
                modelRows.AddRange(Str.Lines(after[..end]));
                body = notesMD[..start] + after[end..];
            }
            else
            {
                modelRows.AddRange(Str.Lines(after));
                body = notesMD[..start];
            }
        }
        string? Outcome(string item)
        {
            var prefix = Str.Prefix(item, 8);
            foreach (var raw in modelRows)
            {
                var t = Str.TrimWS(raw);
                if (t.Starts("-")) t = Str.TrimWS(t[1..]);
                if (!t.Starts(prefix)) continue;
                foreach (var sep in new[] { " → ", "→", "｜" })
                {
                    int r = t.Find(sep);
                    if (r >= 0) { var o = Str.TrimWS(t[(r + sep.Length)..]); return o.Length == 0 ? null : o; }
                }
            }
            return null;
        }
        var rows = brief.Select(b => $"- {b} → {Outcome(b) ?? "（模型未交代此條，重整理可再問）"}");
        return Str.TrimWSNL(body) + "\n\n## 會前重點對照\n" + string.Join("\n", rows);
    }

    public sealed class Input
    {
        public string Transcript, Title, Attendees, DateStr, DurStr, AudioLine;
        public List<string> Warnings;
        public List<string> Links = [];
        public string? Corrections;
        public bool Onsite;
        public MeetingScenario? Scenario;
        public int? OnsiteCount;
        public List<string> Brief = [];
        public string? Baseline;
        public List<string> History = [];
        public RecordScene Scene = RecordScene.Meeting;
        /// Mid-pause note (PauseSpan.Note); null = no pause
        public string? PauseNote;
        /// Roster and memory (PolishContext.Load); null = no roster, polish exactly as before
        public PolishContext? Context;
        public bool IsNote => Scene == RecordScene.Note;

        public Input(string transcript, string title, string attendees, string dateStr, string durStr, List<string> warnings, string audioLine)
        {
            Transcript = transcript; Title = title; Attendees = attendees; DateStr = dateStr; DurStr = durStr; Warnings = warnings; AudioLine = audioLine;
        }
    }

    /// provider null = transcript-only version
    public static (string Md, string Summary, string? PolishErr) BuildNotes(Input i, IProvider? provider)
    {
        var extras = "";
        if (i.Links.Count > 0) extras += "\n參考連結（會後補充，不必臆測內容）：\n" + string.Join("\n", i.Links.Select(l => $"- {l}"));
        var correctionSection = "";
        if (i.Corrections is { } cRaw && Str.TrimWSNL(cRaw) is { Length: > 0 } c)
            correctionSection = $"\n\n使用者對前一版的更正（最高優先，凌駕逐字稿裡的原始寫法）：\n{c}\n套用規則：這些是使用者確認的正確寫法／內容，務必在這一版的每個段落——摘要、與會者、重點、決議、待辦——全部一致套用，同一個名稱在整份紀錄裡只能有一種寫法，不得只改部分段落。期限只能是逐字稿明說的；修正沒提到期限就留空。";
        var baselineSection = "";
        if (i.Baseline is { } bRaw && Str.TrimWSNL(bRaw) is { Length: > 0 } b)
        {
            var historyBlock = i.History.Count == 0 ? "" : "\n\n這份紀錄過去被要求修正過（全部仍然有效，不要退回修正前的說法）：\n" + string.Join("\n", i.History.Select(h => $"- {h}"));
            baselineSection = $"\n\n前一版的整理結果（**這是基準**）：\n{b}{historyBlock}\n套用規則：以上是已經確認過的判斷。除了下方「更正」明確要求改的地方，其餘一律沿用原判斷——不要重新詮釋、不要因為換句話說而改變事實、不要把已經寫明「尚未定案」的事寫成已定案。逐字稿仍是事實來源，但當你的新解讀與基準衝突而更正沒提到這點時，以基準為準。";
        }
        var briefItems = i.Brief.Select(Str.TrimWSNL).Where(x => x.Length > 0).ToList();
        var briefRules = ""; var briefLedger = "";
        if (briefItems.Count > 0)
        {
            var list = string.Join("\n", briefItems.Select((x, k) => $"{k + 1}. {x}"));
            briefRules = $"\n\n會前重點（使用者開會前寫下這場要處理的事）：\n{list}\n會前重點規則：\n- 整理「## 重點」時，與會前重點相關的討論優先保留具體細節與數字。\n- 會前重點不是事實來源——它只是使用者的待辦清單，嚴禁把其中字句當成會中講過的話；逐字稿沒出現的內容一律不寫。\n- 會前重點與與會者判斷無關——不要因為重點提到某人就把他列為與會者。";
            briefLedger = $"\n\n另外在「## 待辦」之後加最後一節「## 會前重點對照」，恰好 {briefItems.Count} 行、每行對應會前重點清單的一條、順序照清單：行首「- 」接該條原文（逐字照抄清單，一個字不改），接「 → 」，接下落。下落三選一：會中有結論→一到兩句具體結論（含數字）；有討論但沒結論→「討論中」＋一句現況；逐字稿完全沒提到→只寫「本場未討論」。嚴禁編造，禁止出現清單以外的行。";
        }
        var llmTranscript = Transcriber.MergedForLLM(i.Transcript);
        // the roster is for meetings polished in the cloud only: small local models have little context and cannot follow the extra rules
        var memory = i.Scene == RecordScene.Meeting && provider?.Id != "endpoint" ? i.Context : null;
        var pauseRule = i.PauseNote is { } pn ? $"\n暫停：{pn}。逐字稿裡「（⏸ …）」那一行只是暫停的位置，不是任何人說的話；暫停那段沒有錄音，不要推測那段談了什麼。" : "";
        var metaBlock =
            $"會議日期：{i.DateStr}\n" +
            $"使用者提供的標題：{(i.Title.Length == 0 ? "（未提供）" : i.Title)}\n" +
            $"使用者提供的與會者名單（人名以此為權威寫法）：{(i.Attendees.Length == 0 ? "（未提供，請自行判斷）" : i.Attendees)}\n" +
            $"時長：{i.DurStr}{pauseRule}\n" +
            $"{(i.Warnings.Count == 0 ? "" : "備註：" + string.Join("；", i.Warnings))}{extras}{correctionSection}";
        // Sound-alike matching: stretches of the transcript that sound like a roster name go to the AI as candidates (see SoundAlike)
        var sounds = new List<SoundAlike.Hit>();
        if (memory != null)
        {
            var (targets, heard) = SoundAlike.Targets(memory.Roster);
            sounds = SoundAlike.Scan(llmTranscript, targets, heard);
        }
        var userMsg = metaBlock + baselineSection + (memory != null ? Prompt.MemoryBlock(memory, sounds) : "") + "\n\n逐字稿：\n" + llmTranscript;

        string? notes = null;
        string? polishErr = null;
        var fixes = new List<NameFixes.Fix>();
        if (provider is { } p && p.Id != "none")
        {
            var sys = i.Scene switch
            {
                RecordScene.Note => Prompt.Note(),
                RecordScene.Interview => Prompt.Interview(),
                _ => Prompt.System(i.Scenario, i.OnsiteCount, i.Onsite) + briefRules + briefLedger + (memory == null ? "" : Prompt.MemoryRules),
            };
            var (raw, err) = p.Complete(p.Id == "endpoint" ? sys + Prompt.LocalModelRules : sys, userMsg);
            // output without any `## ` section (just an opener) does not count: a failure, the existing record is not replaced
            var out0 = raw is null ? null : PolishGuards.SanitizeModelOutput(raw);
            string? shapeErr = (raw is { Length: > 0 } && out0 == null) ? "AI 回的內容不是一份紀錄（沒有任何小節），這次沒有採用——可以按「重新整理全篇」再跑一次" : null;
            if (out0 is { } o && Str.TrimWSNL(o).Length > 0)
            {
                var outMd = o;
                if (memory != null) (outMd, fixes) = NameFixes.Extract(outMd);
                if (i.Scene == RecordScene.Meeting) outMd = PolishGuards.FilterAttendees(outMd, i.Attendees);
                outMd = PolishGuards.SanitizeTodoOwners(outMd, i.Attendees);
                if (p.Id == "endpoint") outMd = PolishGuards.ClearPlaceholderOwners(outMd);
                outMd = PolishGuards.SanitizeTodoDues(outMd, llmTranscript + (i.Corrections ?? ""));
                if (memory != null) outMd = NameFixes.DropRepeatedTodos(outMd, memory.OpenTodos);
                outMd = PolishGuards.StripExampleTodos(outMd);
                outMd = PolishGuards.StripExampleNames(outMd);
                outMd = PolishGuards.NormalizeEmptyMarkers(outMd);
                outMd = PolishGuards.TidyTodoRendering(outMd);
                var (verified, ghosts) = PolishGuards.VerifyCitations(outMd, llmTranscript);
                if (ghosts > 0) HearbyLog.Write($"polish: {ghosts} ghost citations removed");
                // 「之前的事」: a line without a timestamp is not kept (the transcript never said it); empty = section removed
                notes = memory == null ? verified : FollowUps.Prune(verified);
            }
            else polishErr = err ?? shapeErr ?? "模型回了空白內容（可按「重新整理全篇」再跑）";
        }
        bool sharedMic = i.Scenario is MeetingScenario.Onsite or MeetingScenario.PhoneSpeaker || (i.Scenario == null && i.Onsite);
        if (sharedMic && notes is { } n1) notes = PolishGuards.InsertOnsiteNote(n1, i.Scenario, i.OnsiteCount);
        if (briefItems.Count > 0 && notes is { } n2) notes = NormalizeBriefLedger(n2, briefItems);
        // name fixes: fix those transcript lines; the ones not changed get [[?]] in the record; one header line says what changed
        var transcript = i.Transcript;
        string? fixLine = null;
        if (memory != null && notes is { } n3 && fixes.Count > 0)
        {
            var attendeeNames = i.Attendees.Split(['、', ',', '，']).Select(Str.TrimWS).Where(x => x.Length > 0).ToList();
            var fx = NameFixes.Apply(fixes, i.Transcript, memory.Names.Concat(attendeeNames).ToList());
            transcript = fx.Transcript;
            var done = new HashSet<string>(fx.Applied.Select(a => a.Fix.Name));
            var unsure = fx.Skipped.Where(f => !done.Contains(f.Name)).ToList();
            notes = NameFixes.MarkUnsure(n3, unsure, i.Transcript);
            fixLine = NameFixes.HeaderLine(fx.Applied, unsure);
        }

        // assemble (format unchanged)
        var md = new StringBuilder();
        md.Append($"# {i.Scene.MdTitle()} {i.DateStr}\n\n");
        var headline = $"> Hearby 錄音｜時長 {i.DurStr}";
        // Swift components(separatedBy: .newlines) splits on every newline character (\r\n gives two separators)
        var oneLineTitle = Str.TrimWS(string.Join(" ", i.Title.Split(['\n', '\r', '\u000B', '\u000C', '\u0085', (char)0x2028, (char)0x2029])));
        if (oneLineTitle.Length > 0) headline += $"｜{oneLineTitle}";
        md.Append(headline + "\n");
        md.Append($"> 音檔：{i.AudioLine}\n");
        if (i.Attendees.Length > 0 && i.Scene != RecordScene.Note) md.Append($"> 與會者（你填的）：{i.Attendees}\n");
        if (i.Scenario is { } sc && i.Scene == RecordScene.Meeting)
            md.Append($"> 本場情境：{sc.DisplayName()}（依聲音訊號自動判定）" + (i.OnsiteCount is { } oc ? $"｜現場人數 {(oc >= 5 ? "5+" : oc.ToString())}" : "") + "\n");
        if (i.PauseNote is { } pnote) md.Append($"> ⏸ {pnote}\n");
        if (notes != null && provider?.Id == "endpoint")
            md.Append($"> 本機模型整理（{LocalEndpoint.Model ?? "本機模型"}）：比雲端整理簡略，決議與待辦請對照逐字稿再看一次\n");
        if (briefItems.Count > 0) md.Append($"> 會前重點：{briefItems.Count} 條（下落見文末「會前重點對照」）\n");
        if (fixLine != null) md.Append(fixLine + "\n");
        foreach (var w in i.Warnings) md.Append($"> ⚠ {w}\n");
        md.Append('\n');
        if (notes != null) md.Append(Str.TrimWSNL(notes) + "\n");
        else if (polishErr != null) md.Append($"## {SummaryHeading(i.Scene)}\n（AI 整理失敗：{polishErr}；逐字稿完整保留於下，可稍後用「重新整理全篇」重跑）\n");
        else md.Append($"## {SummaryHeading(i.Scene)}\n（只有逐字稿：這場沒有接 AI 整理。逐字稿完整保留於下；到設定選「用我的訂閱」後，可用「重新整理全篇」補整理）\n");
        if (notes == null && briefItems.Count > 0)
            md.Append("\n## 會前重點對照\n" + string.Join("\n", briefItems.Select(x => $"- {x} → （AI 整理未執行，重整理時會對照）")) + "\n");
        if (i.Links.Count > 0) md.Append("\n## 參考連結\n" + string.Join("\n", i.Links.Select(l => $"- {l}")) + "\n");
        md.Append("\n---\n\n## 逐字稿\n" + transcript + "\n");

        var summary = "已存檔。";
        if (notes != null && notes.Find("## " + SummaryHeading(i.Scene)) is var r && r >= 0)
        {
            var after = notes[(r + ("## " + SummaryHeading(i.Scene)).Length)..];
            int e = after.Find("\n## ");
            summary = Str.TrimWSNL(e >= 0 ? after[..e] : after);
        }
        else if (polishErr != null) summary = $"逐字稿已存檔，但 AI 整理失敗（{polishErr}）。";
        else if (notes == null) summary = "逐字稿已存檔（未整理）。";
        return (md.ToString(), summary, polishErr);
    }

    internal static string SummaryHeading(RecordScene s) => s switch { RecordScene.Interview => "摘要", RecordScene.Note => "一句話", _ => "AI 會議摘要" };

    /// Three highlight lines (done page): first three sentences of the summary, or first three key points
    public static List<string> ThreeLines(string md)
    {
        var rec = RecordMD.Parse(md);
        List<string> Sentences(string s) => s.Split('。').Where(x => x.Length > 0).Take(3).Select(x => x + "。").ToList();
        if (md.Starts("# 訪談"))
        {
            var q = (rec.Section("引言") ?? []).Where(x => x != "無").ToList();
            if (q.Count > 0) return q.Take(3).Select(x => StampRe.Replace(x, "")).ToList();
            var s = rec.SummaryText;
            return s.Length == 0 ? [] : Sentences(s);
        }
        if (md.Starts("# 筆記"))
        {
            var heads = (rec.Section("內容") ?? []).Where(x => x.Starts("**")).Select(x => x.Rep("**", "")).ToList();
            if (heads.Count > 0) return heads.Take(3).ToList();
            var one = string.Join(" ", rec.Section("一句話") ?? []);
            return one.Length == 0 ? [] : [one];
        }
        var hi = (rec.Section("重點") ?? []).Where(x => !x.Starts("**")).ToList();
        if (hi.Count >= 2) return hi.Take(3).Select(x => StampRe.Replace(x, "")).ToList();
        var sum = rec.SummaryText;
        if (sum.Length > 0) return Sentences(sum);
        return [];
    }
}
