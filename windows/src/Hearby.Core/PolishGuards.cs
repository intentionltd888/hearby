// PolishGuards — deterministic guards on the model's output: citation check, attendee filter, owner/due guards,
// example stripping. Mirrors Polish/PolishGuards.swift (reasons for each guard are documented there).
using System.Text.RegularExpressions;

namespace Hearby.Core;

public static class PolishGuards
{
    static readonly Regex Ansi = new("\u001B\\[[0-9;?]*[ -/]*[@-~]", RegexOptions.CultureInvariant);
    static readonly Regex FirstSection = new("(?m)^## ", RegexOptions.CultureInvariant);
    static readonly Regex Stamp = new(@"\[((?:\d{1,2}:)?\d{1,3}:[0-5]\d)\]", RegexOptions.CultureInvariant);
    static readonly Regex TrailingSpace = new(@"[ \t]+$", RegexOptions.CultureInvariant);
    static readonly Regex Correction = new(@"「([^「」]{1,40})」\s*(?:應為|应为|是|改成|改為)\s*「([^「」]{1,40})」", RegexOptions.CultureInvariant);
    static readonly Regex DueIsStamp = new(@"^\[?(\d{1,2}:)?\d{1,3}:[0-5]\d\]?$", RegexOptions.CultureInvariant);
    static readonly Regex PlaceholderOwner = new("^(現場|遠端|我方|電話端|受訪者|訪談者)[A-Za-zＡ-Ｚ0-9０-９]?$", RegexOptions.CultureInvariant);

    /// First cleanup of model output. null = unusable (no `## ` section at all).
    /// ANSI colour codes and ``` fences removed; anything before the first `## ` removed;
    /// a `## 逐字稿` in the output is cut off (Hearby appends the real transcript itself — a forged one must never be kept)
    public static string? SanitizeModelOutput(string raw)
    {
        var s = Ansi.Replace(raw, "");
        s = string.Join("\n", Str.Lines(s).Where(l => !Str.TrimWS(l).Starts("```")));
        int cut = s.Find("## 逐字稿");
        if (cut >= 0)
        {
            s = s[..cut];
            while (s.Ends("\n") || s.Ends("-") || s.Ends(" ")) s = s[..^1];
        }
        var m = FirstSection.Match(s);
        if (!m.Success) return null;
        s = Str.TrimWSNL(s[m.Index..]);
        return s.Length == 0 ? null : s;
    }

    static List<string> Stamps(string s) => Stamp.Matches(s).Select(m => m.Value).ToList();

    /// Citation check: every [mm:ss] must exist in the transcript; ghosts are removed (the line stays)
    public static (string Md, int Removed) VerifyCitations(string notesMD, string transcript)
    {
        var real = new HashSet<string>(Str.Lines(transcript).SelectMany(Stamps));
        if (real.Count == 0) return (notesMD, 0);
        int bad = 0;
        var cleaned = Str.Lines(notesMD).Select(line =>
        {
            var ghosts = Stamps(line).Where(x => !real.Contains(x)).ToList();
            if (ghosts.Count == 0) return line;
            bad += ghosts.Count;
            var o = line;
            foreach (var g in ghosts) o = o.Rep(g, "");
            return TrailingSpace.Replace(o, "");
        });
        return (string.Join("\n", cleaned), bad);
    }

    /// 「X」應為「Y」 corrections applied mechanically before the model sees the transcript; returns (transcript, semantic rest)
    public static (string Transcript, string Semantic) ApplyMechanicalCorrections(string transcript, string corrections)
    {
        var t = transcript;
        var semantic = new List<string>();
        foreach (var line in corrections.Split(['\n', ';', '；']))
        {
            var l = Str.TrimWS(line);
            if (l.Length == 0) continue;
            var residual = l;
            foreach (Match m in Correction.Matches(l))
            {
                var wrong = m.Groups[1].Value; var right = m.Groups[2].Value;
                // single-character fixes (他→她) would sweep the whole text: leave them to the model
                if (Str.Count(wrong) < 2 || wrong == right || !t.Has(wrong)) continue;
                t = t.Rep(wrong, right);
                residual = residual.Rep(m.Value, "");
            }
            // trim whitespace ∪ ",，。、；;" together (Swift CharacterSet union)
            int a = 0, b = residual.Length;
            static bool Junk(char c) => Str.IsWS(c) || ",，。、；;".Contains(c);
            while (a < b && Junk(residual[a])) a++;
            while (b > a && Junk(residual[b - 1])) b--;
            if (b > a) semantic.Add(l);
        }
        return (t, string.Join("；", semantic));
    }

    static List<string> Names(string attendeeList) =>
        Str.SplitAny(attendeeList, "、,，").Select(Str.TrimWS).Where(x => x.Length > 0).ToList();

    static (string Base, string? Inner) SplitName(string n)
    {
        int l = n.IndexOfAny(['（', '(']);
        if (l < 0) return (n, null);
        var b = Str.TrimWS(n[..l]);
        var iv = n[(l + 1)..].Trim('）', ')', ' ');
        return (b, iv.Length == 0 ? null : iv);
    }

    /// Attendee section with a given list: only people on the list, once each; anything else is dropped
    public static string FilterAttendees(string notesMD, string attendeeList)
    {
        var names = Names(attendeeList);
        if (names.Count == 0) return notesMD;
        var parsed = names.Select(SplitName).ToList();
        var innerCount = new Dictionary<string, int>();
        foreach (var p in parsed) if (p.Inner is { } iv) innerCount[iv] = innerCount.GetValueOrDefault(iv) + 1;
        var aliasSets = new List<List<string>>();
        for (int i = 0; i < names.Count; i++)
        {
            var aliases = new List<string> { names[i] };
            if (parsed[i].Base.Length > 0 && parsed[i].Base != names[i]) aliases.Add(parsed[i].Base);
            if (parsed[i].Inner is { } iv && innerCount[iv] == 1) aliases.Add(iv);
            aliasSets.Add(aliases);
        }
        var outList = new List<string>();
        var seen = new HashSet<int>();
        bool inSection = false;
        foreach (var line in Str.Lines(notesMD))
        {
            if (line.Starts("## ")) { inSection = line.Has("與會者"); outList.Add(line); continue; }
            if (!inSection || !Str.TrimWS(line).Starts("-")) { outList.Add(line); continue; }
            int hit = aliasSets.FindIndex(a => a.Any(x => line.Has(x)));
            if (hit >= 0 && seen.Add(hit)) outList.Add(line);
        }
        return string.Join("\n", outList);
    }

    static bool EditDistance1(string a, string b)
    {
        var x = Str.Chars(a); var y = Str.Chars(b);
        if (Math.Abs(x.Count - y.Count) > 1) return false;
        int diff = 0;
        if (x.Count == y.Count)
        {
            for (int i = 0; i < x.Count; i++) if (x[i] != y[i]) diff++;
            return diff == 1;
        }
        var (s, l) = x.Count < y.Count ? (x, y) : (y, x);
        int si = 0, lj = 0;
        while (si < s.Count && lj < l.Count)
        {
            if (s[si] == l[lj]) si++; else { diff++; if (diff > 1) return false; }
            lj++;
        }
        return true;
    }

    /// To-do owner guard: owners not on the list are cleared (one-character typos snap back to the list spelling)
    public static string SanitizeTodoOwners(string notesMD, string attendeeList)
    {
        var names = Names(attendeeList);
        if (names.Count == 0) return notesMD;
        var parsed = names.Select(n => (Full: n, P: SplitName(n))).ToList();
        var innerCount = new Dictionary<string, int>();
        foreach (var p in parsed) if (p.P.Inner is { } iv) innerCount[iv] = innerCount.GetValueOrDefault(iv) + 1;
        var aliases = new List<string>();
        foreach (var p in parsed)
        {
            aliases.Add(p.Full);
            if (p.P.Base.Length > 0 && p.P.Base != p.Full) aliases.Add(p.P.Base);
            if (p.P.Inner is { } iv && innerCount[iv] == 1) aliases.Add(iv);
        }
        string FixOwner(string owner)
        {
            var o = Str.TrimWS(owner);
            if (o.Length == 0) return "";
            var parts = Str.SplitAny(o, "、,，").Select(Str.TrimWS).Where(x => x.Length > 0);
            var fixedList = new List<string>();
            foreach (var p in parts)
            {
                if (aliases.Any(a => p.Has(a) || a.Has(p))) fixedList.Add(p);
                else if (aliases.FirstOrDefault(a => EditDistance1(p, a)) is { } snap) fixedList.Add(snap);
            }
            return string.Join("、", fixedList);
        }
        var outList = new List<string>();
        bool inTodo = false;
        foreach (var line in Str.Lines(notesMD))
        {
            if (line.Starts("## ")) inTodo = line.Has("待辦");
            if (!inTodo || !line.Has("- [ ]") || !line.Has("｜")) { outList.Add(line); continue; }
            var cols = line.Split('｜').ToList();
            if (cols.Count >= 2)
            {
                cols[1] = FixOwner(cols[1]);
                while (cols.Count < 3) cols.Add("");
                outList.Add(string.Join("｜", cols.Take(3)));
            }
            else outList.Add(line);
        }
        return string.Join("\n", outList);
    }

    /// The prompt's format example 「範例事項」 copied as a real to-do → removed; an emptied section gets 「- 無」
    public static string StripExampleTodos(string notesMD)
    {
        var outList = new List<string>();
        bool inTodo = false; int? header = null; int count = 0;
        foreach (var line in Str.Lines(notesMD))
        {
            if (line.Starts("## ")) { inTodo = line.Has("待辦"); if (inTodo) header = outList.Count; }
            if (inTodo && line.Has("- [ ]"))
            {
                var item = Str.TrimWS(line.Split('｜')[0].Rep("- [ ]", ""));
                if (item == "範例事項") continue;
                count++;
            }
            outList.Add(line);
        }
        if (header is { } h && count == 0 && !outList.Skip(h).Any(x => Str.TrimWS(x) == "- 無")) outList.Insert(h + 1, "- 無");
        return string.Join("\n", outList);
    }

    /// 「- - 無明確決議」 → 「- 無明確決議」
    public static string NormalizeEmptyMarkers(string notesMD) =>
        string.Join("\n", Str.Lines(notesMD).Select(line => { var t = Str.TrimWS(line); return t.Starts("- - 無") ? t[2..] : line; }));

    /// To-dos with neither owner nor due lose the bare 「｜｜」 tail
    public static string TidyTodoRendering(string notesMD)
    {
        var outList = new List<string>();
        bool inTodo = false;
        foreach (var line in Str.Lines(notesMD))
        {
            if (line.Starts("## ")) inTodo = line.Has("待辦");
            if (inTodo && line.Has("- [ ]") && line.Has("｜"))
            {
                var cols = line.Split('｜').Select(Str.TrimWS).ToList();
                if (cols.Count >= 2 && cols.Skip(1).All(c => c.Length == 0)) { outList.Add(cols[0]); continue; }
            }
            outList.Add(line);
        }
        return string.Join("\n", outList);
    }

    /// The prompt's fictional example names copied by small models → removed everywhere
    public static string StripExampleNames(string notesMD)
    {
        var s = notesMD;
        foreach (var token in new[] { "示例甲（Alpha）", "示例甲(Alpha)", "示例乙（單位甲）", "示例乙(單位甲)", "示例甲", "示例乙", "單位甲" }) s = s.Rep(token, "");
        foreach (var (bad, good) in new[] { ("、、", "、"), ("（、", "（"), ("、）", "）"), ("、。", "。"), ("：、", "：") }) s = s.Rep(bad, good);
        return s;
    }

    /// Shared-mic note under the attendee heading (inserted by the program, so the attendee filter cannot remove it)
    public static string InsertOnsiteNote(string notesMD, MeetingScenario? scenario = null, int? onsiteCount = null)
    {
        var countText = onsiteCount is { } n ? (n >= 5 ? "現場 5 人以上，" : $"現場 {n} 人，") : "";
        var note = scenario switch
        {
            MeetingScenario.PhoneSpeaker => $"> 電話擴音錄音：{countText}單支麥克風同時收現場與電話那頭，發言歸屬僅供參考",
            MeetingScenario.Onsite => $"> 現場錄音：{countText}全場單支麥克風收音，發言歸屬僅供參考",
            _ => "> 現場錄音：全場單支麥克風收音，發言歸屬僅供參考",
        };
        var outList = new List<string>();
        bool inserted = false;
        foreach (var line in Str.Lines(notesMD))
        {
            outList.Add(line);
            if (!inserted && line.Starts("## ") && line.Has("與會者")) { outList.Add(note); inserted = true; }
        }
        return string.Join("\n", outList);
    }

    /// Due guard: the due text must appear in the transcript (+ corrections), and a timestamp is never a due date
    public static string SanitizeTodoDues(string notesMD, string sourceText)
    {
        var outList = new List<string>();
        bool inTodo = false;
        foreach (var line in Str.Lines(notesMD))
        {
            if (line.Starts("## ")) inTodo = line.Has("待辦");
            if (!inTodo || !line.Has("- [ ]") || !line.Has("｜")) { outList.Add(line); continue; }
            var cols = line.Split('｜');
            if (cols.Length >= 3)
            {
                var due = Str.TrimWS(cols[2]);
                bool isStamp = DueIsStamp.IsMatch(due);
                if (due.Length > 0 && (isStamp || !sourceText.Has(due)))
                {
                    cols[2] = "";
                    outList.Add(string.Join("｜", cols));
                    continue;
                }
            }
            outList.Add(line);
        }
        return string.Join("\n", outList);
    }

    /// Owners that are only voice labels (現場A, 遠端B, 我方…) are cleared; real names stay. For small local models
    public static string ClearPlaceholderOwners(string notesMD)
    {
        bool inTodo = false;
        return string.Join("\n", Str.Lines(notesMD).Select(line =>
        {
            if (line.Starts("## ")) inTodo = line.Has("待辦");
            if (!inTodo || !line.Has("- [") || !line.Has("｜")) return line;
            var cols = line.Split('｜');
            if (cols.Length < 2) return line;
            var owner = Str.TrimWS(cols[1]);
            if (PlaceholderOwner.IsMatch(owner)) { cols[1] = ""; return string.Join("｜", cols); }
            return line;
        }));
    }
}
