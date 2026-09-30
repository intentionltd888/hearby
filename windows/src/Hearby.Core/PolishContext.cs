// PolishContext — what a meeting polish also carries: the roster (memory/ROSTER.md), what is already decided (THREADS.md),
// to-dos still open (OPEN.md). Only when memory is on and memory/ROSTER.md exists; without a roster the polish is exactly
// as before. Mirrors Polish/PolishContext.swift (the roster format and the reasons are documented there).
using System.Text.RegularExpressions;

namespace Hearby.Core;

public sealed record PolishContext(string Roster, List<string> Decided, List<string> OpenTodos, List<string> Names)
{
    public const int RosterLimit = 12_000;
    public const int DecidedLimit = 3_000;
    public const int OpenLimit = 3_000;
    public const int ProjectLimit = 3_000;
    public const int UndecidedLimit = 2_000;

    /// STATE.md project status (as recorded before the meeting)
    public List<string> Projects { get; init; } = [];
    /// STATE.md things not decided yet
    public List<string> Undecided { get; init; } = [];

    public PolishContext(string roster) : this(roster, [], [], []) { }

    static readonly Regex Paren = new("（[^）]*）", RegexOptions.CultureInvariant);
    static readonly string[] DecidedWords = ["定案", "決定", "決議", "確定", "結論", "上線", "同意"];
    static readonly string[] UndecidedWords = ["待決定", "待定", "還沒", "未定", "不確定", "等你", "待確認", "要不要", "再定", "[[?]]"];

    /// From the memory folder; memory off, or no roster (or a roster without a single entry) = null.
    /// meetingID = this meeting (its own to-dos are not "earlier" ones)
    public static PolishContext? Load(string? meetingID = null)
    {
        if (!ConfigStore.Shared.Current.MemoryEnabled) return null;
        static string? Read(string n) { try { var p = Path.Combine(Paths.Memory, n); return File.Exists(p) ? File.ReadAllText(p) : null; } catch { return null; } }
        var roster = Read("ROSTER.md");
        var names = Read(NameLedger.FileName);
        var state = Read("STATE.md");
        return roster == null && names == null && state == null ? null : Make(roster ?? "", Read("THREADS.md"), Read("OPEN.md"), meetingID, RosterLimit, names, state);
    }

    /// Pure (contract fixtures); limit = how many characters of roster to carry
    public static PolishContext? Make(string raw, string? threads, string? open, string? meetingID, int limit = RosterLimit, string? names = null, string? state = null)
    {
        var ledger = names == null ? ([], []) : NameLedger.Parse(names);
        var lines = (names == null ? [] : NameLedger.ContextLines(ledger.Entries, ledger.Questions))
            .Concat(Str.Lines(Clean.StripHTMLComments(raw)).Select(Str.TrimWS)).Where(l => l.Starts("## ") || l.Starts("- ")).ToList();
        var st = StateSections(state ?? "");
        bool hasState = st.Values.Any(v => v.Count > 0);
        if (!lines.Any(l => l.Starts("- ")) && !hasState) return null;
        var kept = new List<string>();
        int used = 0, cut = 0;
        for (int i = 0; i < lines.Count; i++)
        {
            var l = lines[i];
            if (used + Str.Count(l) + 1 > limit) { cut = lines.Skip(i).Count(x => x.Starts("- ")); break; }
            kept.Add(l);
            used += Str.Count(l) + 1;
        }
        while (kept.Count > 0 && kept[^1].Starts("## ")) kept.RemoveAt(kept.Count - 1);   // cut right after a heading = that section carried nothing
        if (cut > 0) kept.Add($"- …（名冊太長，後面 {cut} 行沒帶）");
        if (!hasState) return new PolishContext(string.Join("\n", kept), DecidedLines(threads ?? ""), OpenLines(open ?? "", meetingID), RosterNames(kept));
        var decided = st["定案"].Count == 0 ? DecidedLines(threads ?? "") : Capped(st["定案"], DecidedLimit);
        return new PolishContext(string.Join("\n", kept), decided, Capped(st["待辦"], OpenLimit), RosterNames(kept))
        {
            Projects = Capped(st["案子"], ProjectLimit), Undecided = Capped(st["還沒定"], UndecidedLimit),
        };
    }

    /// STATE.md's four sections (a heading containing 案子／待辦／定案／還沒定; 還沒定 is checked first): each section's 「- 」 lines
    internal static Dictionary<string, List<string>> StateSections(string text)
    {
        var outD = new Dictionary<string, List<string>> { ["案子"] = [], ["待辦"] = [], ["定案"] = [], ["還沒定"] = [] };
        string? cur = null;
        foreach (var raw in Str.Lines(Clean.StripHTMLComments(text)))
        {
            var l = Str.TrimWS(raw);
            if (l.Starts("## ")) { cur = new[] { "還沒定", "案子", "待辦", "定案" }.FirstOrDefault(k => l.Has(k)); continue; }
            if (cur == null || !l.Starts("- ")) continue;
            var t = Str.TrimWS(Str.DropFirst(l, 2));
            if (t.Length > 0) outD[cur].Add(t);
        }
        return outD;
    }

    /// As many lines from the top as fit (whoever writes it puts the important ones first)
    internal static List<string> Capped(List<string> lines, int limit)
    {
        var outL = new List<string>();
        int used = 0;
        foreach (var l in lines)
        {
            if (used + Str.Count(l) + 1 > limit) break;
            outL.Add(l); used += Str.Count(l) + 1;
        }
        return outL;
    }

    /// The right spellings: column 1 (name) and column 2 (other names) of lines that have a 「｜」, bracketed notes removed;
    /// column 3 on (misheard spellings, description) does not count; a column 2 with 「：」 is a description, not names
    internal static List<string> RosterNames(List<string> lines)
    {
        var outList = new List<string>();
        void Add(string s)
        {
            var t = Str.TrimWS(Paren.Replace(s, ""));
            if (t.Length > 0 && !outList.Contains(t)) outList.Add(t);
        }
        foreach (var l in lines.Where(l => l.Starts("- ") && l.Has("｜")))
        {
            var cols = Str.DropFirst(l, 2).Split('｜');
            Add(cols[0]);
            if (cols.Length > 1 && !cols[1].Has("：")) Clean.SplitTerms(cols[1]).ForEach(Add);
        }
        return outList;
    }

    /// THREADS.md: lines under a 「## topic」 with a decision word and no 「still open」 word, the last 3 per topic;
    /// over the total limit, the oldest topics (top of the file) go first
    internal static List<string> DecidedLines(string text)
    {
        var groups = new List<List<string>>();
        string title = "";
        var cur = new List<string>();
        void Flush()
        {
            if (cur.Count > 0) groups.Add(cur.Skip(Math.Max(0, cur.Count - 3)).Select(x => $"【{Clip(title, 20)}】{x}").ToList());
            cur = [];
        }
        foreach (var raw in Str.Lines(Clean.StripHTMLComments(text)))
        {
            var l = Str.TrimWS(raw);
            if (l.Starts("## ")) { Flush(); title = Str.TrimWS(Str.DropFirst(l, 3)); continue; }
            if (title.Length == 0 || !l.Starts("- ")) continue;
            var t = Str.TrimWS(Str.DropFirst(l, 2));
            if (!DecidedWords.Any(t.Has) || UndecidedWords.Any(t.Has)) continue;
            cur.Add(Clip(t, 120));
        }
        Flush();
        var picked = new List<List<string>>();
        int used = 0;
        for (int i = groups.Count - 1; i >= 0; i--)
        {
            int n = groups[i].Sum(x => Str.Count(x) + 1);
            if (used + n > DecidedLimit) break;
            picked.Insert(0, groups[i]);
            used += n;
        }
        return picked.SelectMany(x => x).ToList();
    }

    /// OPEN.md to-dos not ticked yet (「- [ ] item｜owner｜due｜meeting id」), not this meeting's; over the limit keep the newest (end of file)
    internal static List<string> OpenLines(string text, string? meetingID)
    {
        var rows = new List<string>();
        foreach (var raw in Str.Lines(text))
        {
            var l = Str.TrimWS(raw);
            if (!l.Starts("- [ ] ")) continue;
            var cols = Str.DropFirst(l, 6).Split('｜').Select(Str.TrimWS).ToList();
            if (cols[0].Length == 0) continue;
            var meeting = cols.Count >= 4 ? cols[^1] : "";
            if (!string.IsNullOrEmpty(meetingID) && meeting == meetingID) continue;
            var owner = cols.Count > 1 ? cols[1] : "";
            var due = cols.Count > 2 ? cols[2] : "";
            var day = Str.Prefix(meeting, 10);
            rows.Add($"{cols[0]}｜{owner}｜{due}" + (day.Length == 0 ? "" : $"｜{day}"));
        }
        var picked = new List<string>();
        int used = 0;
        for (int i = rows.Count - 1; i >= 0; i--)
        {
            if (used + Str.Count(rows[i]) + 1 > OpenLimit) break;
            picked.Insert(0, rows[i]);
            used += Str.Count(rows[i]) + 1;
        }
        return picked;
    }

    internal static string Clip(string s, int n) => Str.Count(s) <= n ? s : Str.Prefix(s, n - 1) + "…";
}
