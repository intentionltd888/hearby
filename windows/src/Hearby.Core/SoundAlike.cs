// SoundAlike — sound-alike matching: stretches of the transcript that sound like a roster name but are written differently
// (「隱形」 sounds like 「尹馨」, 「郁婷」 like 「昱廷」).
//
// Candidates only — Hearby itself never rewrites a character from them: most are ordinary words (「諮詢」 sounds like 「姿均」). They go to the
// polishing AI to judge in context (a section of Prompt.MemoryBlock), and only what it recognizes goes into 「## 名字更正」. Second use: when the
// AI changes a word into part of a roster name (a short form: 亞特蘭提斯 → 「亞特」), the heard string must sound like it (NameFixes.Known).
// Matching (Pinyin): every character must be at least nearly the same, and at most one may be only nearly the same (the rest sound the same);
// same length, 2–6 characters. Roster column 3 (known misheard spellings) is handled by the roster rule, so it is masked here and not listed;
// a stretch containing 的、是、有、一… is not listed (nearly always an ordinary word). Same behaviour as the Mac side (contract/fixtures/sound_alike.json).
using System.Text.RegularExpressions;

namespace Hearby.Core;

public static class SoundAlike
{
    /// Rank = which roster line (the roster is ordered by importance: own people, projects, companies, products, others)
    public sealed record Target(string Name, List<string> Syllables, int Rank);

    public sealed class Hit
    {
        public string Heard = "";
        public List<string> Names = [];
        public int Count;
        public List<string> Stamps = [];
        public int Rank;
    }

    /// A stretch containing any of these is not listed (「有人」 like 「佑任」, 「是為」 like 「思緯」: ordinary words are most of them)
    static readonly HashSet<char> Stop = [.. "的了是在我你他她它們這那個就都也要會說很不沒嗎呢吧啊喔哦呀嗯欸耶有一"];
    /// Three characters starting with a common surname: also match the last two (people are often called by the given name: 吳昱廷 → 昱廷)
    static readonly HashSet<char> Surnames = [.. "陳林黃張李王吳劉蔡楊許鄭謝郭洪曾邱廖賴周徐蘇葉莊呂江何蕭羅高潘簡朱鍾游彭詹胡施沈余盧梁趙顏柯翁魏孫戴范方宋鄧杜傅侯曹薛丁卓阮馬董溫唐藍蔣石古紀姚連馮歐程湯田康姜汪白鄒尤巫鐘黎涂龔嚴韓袁金童陸夏柳邵錢伍倪于譚駱熊任甘秦顧毛章史官萬俞雷粘饒闕凌崔尹孔辛武辜陶段龍韋葛池孟褚殷麥賀賈莫文管關向包丘梅華利裴樊房全佘左花"];
    /// At most this many go to the AI
    public const int ListLimit = 60;
    static readonly Regex Paren = new("（[^）]*）");

    /// Roster → match targets (the 2–6 Han-character stretches of the canonical name and aliases; a column-5 reading overrides the table)
    /// and the known misheard spellings (column 3, and the X of 「「X」可能是／不是…」 lines)
    public static (List<Target> Targets, List<string> Heard) Targets(string roster)
    {
        var targets = new List<Target>();
        var names = new HashSet<string>();
        var heard = new List<string>();
        string Strip(string s) => Str.TrimWS(Paren.Replace(s, ""));
        void AddHeard(string s)
        {
            var t = Strip(s);
            if (Str.Count(t) >= 2 && !heard.Contains(t)) heard.Add(t);
        }
        int rank = 0;
        void Add(List<string> run, Dictionary<string, string> reading)
        {
            var name = string.Concat(run);
            if (run.Count < 2 || run.Count > 6 || names.Contains(name)) return;
            var syl = new List<string>();
            foreach (var ch in run)
            {
                var p = reading.GetValueOrDefault(ch) ?? Pinyin.Of(ch);
                if (p == null) return;
                syl.Add(p);
            }
            names.Add(name);
            targets.Add(new Target(name, syl, rank));
        }
        foreach (var raw in Str.Lines(Clean.StripHTMLComments(roster)))
        {
            var l = Str.TrimWS(raw);
            if (!l.Starts("- ")) continue;
            if (!l.Has("｜"))
            {
                // 「- 「品博」可能是 黃品柏：看上下文才換」「- 「星核」不是星河：不要換」
                int a = l.Find("「");
                if (a >= 0)
                {
                    int b = l.Find("」", a + 1);
                    if (b >= 0) AddHeard(l[(a + 1)..b]);
                }
                continue;
            }
            var cols = Str.DropFirst(l, 2).Split('｜');
            var reading = new Dictionary<string, string>();
            if (cols.Length > 4)
            {
                var r = Str.Chars(cols[4]);
                for (int j = 1; j < r.Count; j++)
                {
                    if (r[j] != "＝" || !Pinyin.IsHan(r[j - 1])) continue;
                    int k = j + 1;
                    var z = "";
                    while (k < r.Count && IsZhuyin(r[k])) { z += r[k]; k++; }
                    if (Pinyin.FromZhuyin(z) is { } p) reading[r[j - 1]] = p;
                }
            }
            var list = new List<string> { Strip(cols[0]) };
            if (cols.Length > 1 && !cols[1].Has("：")) list.AddRange(Clean.SplitTerms(cols[1]).Select(Strip));
            foreach (var n in list)
                foreach (var run in HanRuns(n))
                {
                    Add(run, reading);
                    if (run.Count == 3 && Surnames.Contains(run[0][0])) Add(run.Skip(1).ToList(), reading);
                }
            if (cols.Length > 2) Clean.SplitTerms(cols[2]).ForEach(AddHeard);
            rank++;
        }
        return (targets, heard);
    }

    static bool IsZhuyin(string c) => c.Length == 1 && ((c[0] >= 'ㄅ' && c[0] <= 'ㄯ') || Pinyin.Tones.Contains(c[0]));

    /// Runs of consecutive Han characters (graphemes)
    static List<List<string>> HanRuns(string s) => HanRunsWithOffsets(s).Select(r => r.Chars).ToList();

    static List<(int Offset, List<string> Chars)> HanRunsWithOffsets(string s)
    {
        var outList = new List<(int, List<string>)>();
        var cur = new List<string>();
        int start = 0, i = 0;
        foreach (var ch in Str.Chars(s))
        {
            if (Pinyin.IsHan(ch))
            {
                if (cur.Count == 0) start = i;
                cur.Add(ch);
            }
            else if (cur.Count > 0) { outList.Add((start, cur)); cur = []; }
            i++;
        }
        if (cur.Count > 0) outList.Add((start, cur));
        return outList;
    }

    sealed record Found(string Heard, List<string> Names, int Start, int Len, int Rank);

    /// Stretches of the transcript (one 「- [mm:ss][who] text」 per line) that sound like a target but are written differently.
    /// Order: the matched name's roster line first (own people first), then more occurrences, then first appearance
    public static List<Hit> Scan(string transcript, List<Target> targets, List<string> heard)
    {
        if (targets.Count == 0) return [];
        var index = new Dictionary<string, List<int>>();
        for (int i = 0; i < targets.Count; i++)
        {
            var key = string.Join(" ", targets[i].Syllables.Select(Pinyin.Coarse));
            if (!index.TryGetValue(key, out var l)) index[key] = l = [];
            l.Add(i);
        }
        var lengths = targets.Select(t => t.Syllables.Count).Distinct().OrderBy(n => n).ToList();
        var names = targets.Select(t => t.Name).ToHashSet();
        var known = heard.ToHashSet();
        var masks = heard.OrderByDescending(Str.Count).ToList();
        var order = new List<string>();
        var agg = new Dictionary<string, Hit>();
        foreach (var line in Str.Lines(transcript))
        {
            var l = Str.TrimWS(line);
            if (!l.Starts("- [")) continue;
            int tsEnd = l.Find("][");
            if (tsEnd < 0) continue;
            int whoEnd = l.Find("] ", tsEnd + 2);
            if (whoEnd < 0) continue;
            var stamp = l[3..tsEnd];
            var text = l[(whoEnd + 2)..];
            foreach (var h in masks)
                if (text.Has(h)) text = text.Rep(h, new string(' ', Str.Count(h)));
            var found = new List<Found>();
            foreach (var (offset, chars) in HanRunsWithOffsets(text))
            {
                var py = chars.Select(Pinyin.Of).ToList();
                var co = py.Select(p => p == null ? null : Pinyin.Coarse(p)).ToList();
                var ky = py.Select(p => p == null ? null : Pinyin.Key(p)).ToList();
                foreach (var n in lengths)
                {
                    if (n > chars.Count) continue;
                    for (int i = 0; i <= chars.Count - n; i++)
                    {
                        var cs = co.GetRange(i, n);
                        if (cs.Any(c => c == null) || !index.TryGetValue(string.Join(" ", cs), out var cands)) continue;
                        var w = string.Concat(chars.GetRange(i, n));
                        if (names.Contains(w) || known.Contains(w) || w.Any(Stop.Contains)) continue;
                        var hit = new List<string>();
                        int best = int.MaxValue;
                        foreach (var c in cands)
                        {
                            var t = targets[c];
                            int diff = 0;
                            for (int k = 0; k < t.Syllables.Count; k++) if (ky[i + k] != Pinyin.Key(t.Syllables[k])) diff++;
                            if (diff <= 1) { hit.Add(t.Name); best = Math.Min(best, t.Rank); }
                        }
                        if (hit.Count > 0) found.Add(new Found(w, hit, offset + i, n, best));
                    }
                }
            }
            // A longer stretch covers a shorter one (「星雨→芯妤」 inside 「流星雨→劉芯妤」): the shorter is not listed
            var kept = found.Where(a => !found.Any(b =>
                b.Len > a.Len && b.Start <= a.Start && b.Start + b.Len >= a.Start + a.Len && a.Names.Any(n => b.Names.Any(x => x.Has(n))))).ToList();
            foreach (var f in kept)
            {
                if (agg.TryGetValue(f.Heard, out var h))
                {
                    h.Count++;
                    foreach (var n in f.Names) if (!h.Names.Contains(n)) h.Names.Add(n);
                    if (!h.Stamps.Contains(stamp)) h.Stamps.Add(stamp);
                    h.Rank = Math.Min(h.Rank, f.Rank);
                }
                else
                {
                    agg[f.Heard] = new Hit { Heard = f.Heard, Names = [.. f.Names], Count = 1, Stamps = [stamp], Rank = f.Rank };
                    order.Add(f.Heard);
                }
            }
        }
        return order.Select((w, i) => (Hit: agg[w], I: i)).OrderBy(x => x.Hit.Rank).ThenByDescending(x => x.Hit.Count).ThenBy(x => x.I).Select(x => x.Hit).ToList();
    }

    /// Lines for the AI (at most ListLimit): 「- heard → name？×count [mm:ss]…」 (at most three timestamps)
    public static List<string> Lines(List<Hit> hits) =>
        hits.Take(ListLimit).Select(h => $"- {h.Heard} → {string.Join("／", h.Names)}？" + (h.Count > 1 ? $"×{h.Count}" : "") + " "
            + string.Join(" ", h.Stamps.Take(3).Select(s => $"[{s}]"))).ToList();

    /// Does the heard string sound like the name (used when the AI changes a word into part of a roster name): same length, all in the table,
    /// at least half the characters nearly the same
    public static bool Close(string heard, string name)
    {
        var a = Str.Chars(heard);
        var b = Str.Chars(name);
        if (a.Count != b.Count || a.Count < 2) return false;
        int same = 0;
        for (int i = 0; i < a.Count; i++)
        {
            var p = Pinyin.Of(a[i]);
            var q = Pinyin.Of(b[i]);
            if (p == null || q == null) return false;
            if (Pinyin.Coarse(p) == Pinyin.Coarse(q)) same++;
        }
        return same * 2 >= a.Count;
    }
}
