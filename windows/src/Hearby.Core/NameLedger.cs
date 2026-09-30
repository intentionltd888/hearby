// NameLedger — memory/NAMES.md: a name corrected once is written down here, so the next meeting gets it right.
// Mirrors Memory/NameLedger.swift step by step (who writes it, how 一律／看上下文 is decided, the edit diff, the file discipline).
// Characters are text elements (Str.Chars / Str.Count), the same unit as Swift's Character.
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hearby.Core;

public static class NameLedger
{
    public const string FileName = "NAMES.md";
    /// What Hearby last wrote for each meeting (hash): --memory-rebuild finds "the version before the edit" with it
    public const string StateFile = ".hearby-names.json";
    public const string Always = "一律", ByContext = "看上下文", Never = "不換";

    public sealed record Entry(string Heard, string Name, string How, string Who = "", string Date = "", string Meeting = "");

    public sealed record Question(string Heard, string Name, string Meeting = "", string Answer = "")
    {
        public bool Yes => Answer is "是" or "對" or "yes" or "Yes";
        public bool No => Answer is "不是" or "不對" or "否" or "no" or "No";
    }

    public const string Header = "# 名字確認帳（改過一次的名字記在這裡，下一場 Hearby 自己就對）\n\n<!-- Hearby 會自己記：在 Hearby 裡自己改紀錄、重新整理時寫的「A」應為「B」、別的程式改了紀錄後跑 --memory-rebuild（改之前要留 .bak）。\n     一行一筆：- 聽到 → 正名｜換法｜誰改的｜日期｜哪一場\n     換法：一律＝聽打完直接換（別場逐字稿沒出現過、不是別的名字的一部分）；看上下文＝交給 AI 看上下文才換；不換＝這不是聽錯。\n     「換法」可以直接改；刪掉一行＝忘掉這筆。「要確認」那一節在最後一欄寫「是」或「不是」就算答了，同一題不再問。 -->\n\n## 名字\n\n## 要確認\n";

    // ── read ──

    public static (List<Entry> Entries, List<Question> Questions) Parse(string text)
    {
        var entries = new List<Entry>();
        var qs = new List<Question>();
        bool asking = false;
        foreach (var raw in Str.Lines(Clean.StripHTMLComments(text)))
        {
            var l = Str.TrimWS(raw);
            if (l.Starts("## ")) { asking = l.Has("要確認"); continue; }
            if (!l.Starts("- ")) continue;
            var cols = Str.DropFirst(l, 2).Split('｜').Select(Str.TrimWS).ToList();
            if (Pair(cols[0]) is not { } p) continue;
            string Col(int i) => i < cols.Count ? cols[i] : "";
            if (asking)
            {
                var n = p.Name;
                while (n.Ends("？") || n.Ends("?")) n = Str.DropLast(n, 1);
                n = Str.TrimWS(n);
                if (n.Length > 0 && n != p.Heard) qs.Add(new Question(p.Heard, n, Col(1), Col(2)));
            }
            else
            {
                var how = Col(1) is Always or ByContext or Never ? Col(1) : ByContext;
                entries.Add(new Entry(p.Heard, p.Name, how, Col(2), Col(3), Col(4)));
            }
        }
        return (entries, qs);
    }

    /// 「heard → name」 (the arrow may also be -> or =>; quotes removed); equal or empty sides = null
    internal static (string Heard, string Name)? Pair(string s)
    {
        int at = -1, len = 0;
        foreach (var a in new[] { "→", "->", "=>" })
        {
            int k = s.Find(a);
            if (k >= 0) { at = k; len = a.Length; break; }
        }
        if (at < 0) return null;
        const string q = " 「」『』\"'“”";
        var h = Str.TrimSet(s[..at], q);
        var n = Str.TrimSet(s[(at + len)..], q);
        return h.Length == 0 || n.Length == 0 || h == n ? null : (h, n);
    }

    static string? Read()
    {
        var p = Path.Combine(Paths.Memory, FileName);
        try { return File.Exists(p) ? File.ReadAllText(p, Encoding.UTF8) : null; } catch { return null; }
    }

    // ── write (pure: text in, text out) ──

    /// Add lines at the end of 「名字」 and 「要確認」 (no file = start from the header); a pair already there is not added again,
    /// a question already asked or already known is not asked again
    public static string Adding(List<Entry>? newEntries, List<Question>? newQs, string? text)
    {
        var lines = (text ?? Header).Rep("\r\n", "\n").Split('\n').ToList();
        var (have, asked) = Parse(string.Join("\n", lines));
        var seen = new HashSet<string>(have.Select(e => e.Heard + "→" + e.Name));
        var addE = new List<string>();
        foreach (var e in newEntries ?? [])
            if (seen.Add(e.Heard + "→" + e.Name)) addE.Add($"- {e.Heard} → {e.Name}｜{e.How}｜{e.Who}｜{e.Date}｜{e.Meeting}");
        var askedKeys = new HashSet<string>(asked.Select(x => x.Heard + "→" + x.Name));
        var addQ = new List<string>();
        foreach (var q in newQs ?? [])
        {
            var k = q.Heard + "→" + q.Name;
            if (seen.Contains(k) || !askedKeys.Add(k)) continue;
            addQ.Add($"- {q.Heard} → {q.Name}？｜{q.Meeting}｜{q.Answer}");
        }
        if (addE.Count > 0) Insert(addE, "## 名字", lines);
        if (addQ.Count > 0) Insert(addQ, "## 要確認", lines);
        return string.Join("\n", lines);
    }

    static void Insert(List<string> add, string heading, List<string> lines)
    {
        int h = lines.FindIndex(l => Str.TrimWS(l) == heading);
        if (h < 0)
        {
            while (lines.Count > 0 && Str.TrimWS(lines[^1]).Length == 0) lines.RemoveAt(lines.Count - 1);
            lines.Add(""); lines.Add(heading); lines.AddRange(add); lines.Add("");
            return;
        }
        int e = lines.Count;
        for (int i = h + 1; i < lines.Count; i++) if (lines[i].Starts("## ") || lines[i].Starts("# ")) { e = i; break; }
        while (e > h + 1 && Str.TrimWS(lines[e - 1]).Length == 0) e--;
        lines.InsertRange(e, add);
    }

    /// Answer one question: its last column gets the answer (question not found = unchanged)
    public static string Answering(string heard, string name, string answer, string text)
    {
        var lines = text.Rep("\r\n", "\n").Split('\n');
        bool asking = false;
        for (int i = 0; i < lines.Length; i++)
        {
            var l = Str.TrimWS(lines[i]);
            if (l.Starts("## ")) { asking = l.Has("要確認"); continue; }
            if (!asking || !l.Starts("- ")) continue;
            var cols = Str.DropFirst(l, 2).Split('｜').Select(Str.TrimWS).ToList();
            if (Pair(cols[0]) is not { } p) continue;
            var n = p.Name;
            while (n.Ends("？") || n.Ends("?")) n = Str.DropLast(n, 1);
            if (p.Heard != heard || Str.TrimWS(n) != name) continue;
            lines[i] = $"- {heard} → {name}？｜{(cols.Count > 1 ? cols[1] : "")}｜{answer}";
            break;
        }
        return string.Join("\n", lines);
    }

    // ── use ──

    /// Roster lines carried into the polish (first in the roster): names confirmed; spellings confirmed not to be mishearings
    public static List<string> ContextLines(List<Entry> entries, List<Question> qs)
    {
        var order = new List<string>();
        var heards = new Dictionary<string, List<string>>();
        var nots = new List<string>();
        void Add(string name, string h)
        {
            if (!heards.ContainsKey(name)) { order.Add(name); heards[name] = []; }
            if (!heards[name].Contains(h)) heards[name].Add(h);
        }
        foreach (var e in entries)
        {
            if (e.How == Never) nots.Add($"- 「{e.Heard}」不是{e.Name}：不要換");
            else Add(e.Name, e.How == Always ? e.Heard : e.Heard + "（看上下文）");
        }
        foreach (var q in qs)
        {
            if (q.Yes) Add(q.Name, q.Heard + "（看上下文）");
            else if (q.No) nots.Add($"- 「{q.Heard}」不是{q.Name}：不要換");
        }
        var outList = new List<string>();
        if (order.Count > 0) { outList.Add("## 確認過的名字"); outList.AddRange(order.Select(n => $"- {n}｜｜{string.Join("、", heards[n])}｜確認過｜")); }
        if (nots.Count > 0) { outList.Add("## 確認過不是聽錯"); outList.AddRange(nots); }
        return outList;
    }

    /// 一律 entries are replaced right after transcription (Clean.AliasTable reads these)
    public static List<(string Alias, string Canonical)> AliasPairs(List<Entry> entries) =>
        entries.Where(e => e.How == Always && Str.Count(e.Heard) >= 2).Select(e => (e.Heard, e.Name)).ToList();

    // ── learn ──

    /// Collision check: two characters or more, absent from other meetings' transcripts, not part of another roster name = 一律; else 看上下文
    public static string Classify(string heard, string meeting, List<(string Id, string Transcript)> others, List<string> known)
    {
        if (Str.Count(heard) < 2) return ByContext;
        if (known.Any(k => k != heard && k.Has(heard))) return ByContext;
        if (others.Any(o => o.Id != meeting && o.Transcript.Has(heard))) return ByContext;
        return Always;
    }

    const string Numerals = "0123456789０１２３４５６７８９〇一二三四五六七八九十百千萬万億亿兩两零";

    /// Looks like a name: the name contains a roster name; or both sides are short (≤ 6) with no numerals
    internal static bool NameLike(string heard, string name, List<string> known)
    {
        if (known.Any(k => Str.Count(k) >= 2 && name.Has(k))) return true;
        static bool Num(string s) => s.Any(c => Numerals.Contains(c));
        return Str.Count(heard) <= 6 && Str.Count(name) <= 6 && !Num(heard) && !Num(name);
    }

    /// Basic shape: both have letters, differ, at most 12 characters, neither contains the other (that is adding or dropping words)
    internal static bool Plausible(string heard, string name)
    {
        static bool Word(string s) => Str.Chars(s).Any(IsWordChar);
        return heard.Length > 0 && name.Length > 0 && heard != name && Str.Count(heard) <= 12 && Str.Count(name) <= 12
            && !heard.Has(name) && !name.Has(heard) && Word(heard) && Word(name);
    }

    internal static bool IsCJK(string g) => Str.FirstScalar(g) is var v && (v is >= 0x4E00 and <= 0x9FFF || v is >= 0x3400 and <= 0x4DBF || v is >= 0xF900 and <= 0xFAFF);
    internal static bool IsLatin(string g) => g.EnumerateRunes().Count() == 1 && Str.FirstScalar(g) is var v && (v is >= 0x41 and <= 0x5A || v is >= 0x61 and <= 0x7A || v is >= 0x30 and <= 0x39);
    internal static bool IsWordChar(string g) => IsCJK(g) || IsLatin(g);

    static readonly Regex CorrectionRe = new(@"「([^「」]{1,40})」\s*(?:應為|应为|是|改成|改為)\s*「([^「」]{1,40})」", RegexOptions.CultureInvariant);

    /// 「A」應為「B」 written when re-polishing (same form as PolishGuards.ApplyMechanicalCorrections) → pairs that look like names
    public static List<(string Heard, string Name)> PairsFromCorrections(string corrections, List<string> known)
    {
        var outList = new List<(string, string)>();
        foreach (Match m in CorrectionRe.Matches(corrections))
        {
            var h = Str.TrimWS(m.Groups[1].Value);
            var n = Str.TrimWS(m.Groups[2].Value);
            if (Str.Count(h) < 2 || !Plausible(h, n) || !NameLike(h, n, known) || outList.Contains((h, n))) continue;
            outList.Add((h, n));
        }
        return outList;
    }

    /// Before / after an edit: where one name became another (line to line, then character to character). Kept when it looks like a name;
    /// a one-character change no roster name covers must appear twice; Latin needs a roster name; outside the transcript it must land on a
    /// roster name exactly, or also be changed in the transcript, or be changed twice
    public static List<(string Heard, string Name)> PairsFromEdit(string oldText, string newText, List<string> known)
    {
        var a = oldText.Rep("\r\n", "\n").Split('\n');
        var b = newText.Rep("\r\n", "\n").Split('\n');
        int tb = Array.FindIndex(b, l => l.Starts("## 逐字稿"));
        if (tb < 0) tb = b.Length;
        var raw = new List<(string Heard, string Name, bool Transcript, List<(string, string)> Alts)>();
        var dels = new List<int>();
        var ins = new List<int>();
        void Flush()
        {
            if (dels.Count > 0 && dels.Count == ins.Count)
                for (int k = 0; k < dels.Count; k++)
                    foreach (var h in Hunks(a[dels[k]], b[ins[k]], known)) raw.Add((h.Old, h.New, ins[k] > tb, h.Alts));
            dels.Clear(); ins.Clear();
        }
        foreach (var (i, j) in Align(a, b))
        {
            if (i is { } x && j is null) dels.Add(x);
            else if (i is null && j is { } y) ins.Add(y);
            else Flush();
        }
        Flush();
        var altCount = new Dictionary<string, int>();
        foreach (var r in raw.Where(r => r.Alts.Count > 0))
        {
            var seen = new HashSet<string>();
            foreach (var c in r.Alts) if (seen.Add(c.Item1 + "→" + c.Item2)) altCount[c.Item1 + "→" + c.Item2] = altCount.GetValueOrDefault(c.Item1 + "→" + c.Item2) + 1;
        }
        var found = new List<(string Heard, string Name, bool Transcript, bool Repeated)>();
        foreach (var r in raw)
        {
            if (r.Alts.Count == 0) { found.Add((r.Heard, r.Name, r.Transcript, false)); continue; }
            (string, string)? pick = null;
            int most = 1;
            foreach (var c in r.Alts)
            {
                int cnt = altCount.GetValueOrDefault(c.Item1 + "→" + c.Item2);
                if (cnt > most) { pick = c; most = cnt; }
            }
            if (pick is { } p) found.Add((p.Item1, p.Item2, r.Transcript, true));
        }
        static bool Latin(string s) => Str.Chars(s).Any(IsLatin);
        var outList = new List<(string, string)>();
        foreach (var f in found)
        {
            if (!Plausible(f.Heard, f.Name) || !NameLike(f.Heard, f.Name, known)) continue;
            bool knownName = known.Any(k => Str.Count(k) >= 2 && f.Name.Has(k));
            if ((Latin(f.Heard) || Latin(f.Name)) && !knownName) continue;
            int times = found.Count(x => x.Heard == f.Heard && x.Name == f.Name);
            if (!f.Transcript && !f.Repeated)
                if (!(known.Contains(f.Name) || times >= 2 || found.Any(x => x.Transcript && x.Heard == f.Heard && x.Name == f.Name))) continue;
            if (outList.Contains((f.Heard, f.Name))) continue;
            outList.Add((f.Heard, f.Name));
        }
        return outList;
    }

    sealed class H { public int A0, A1, B0, B1; public bool Cjk; }

    /// Where one line changed (see NameLedger.swift hunks: merging across one CJK character, Latin word expansion,
    /// expansion to the longest covering roster name, one-character alternates)
    public static List<(string Old, string New, List<(string, string)> Alts)> Hunks(string x, string y, List<string> known)
    {
        var a = Str.Chars(x);
        var b = Str.Chars(y);
        var hs = new List<H>();
        H? cur = null;
        int gap = 0, ai = 0, bi = 0;
        foreach (var (i, j) in Align(a, b))
        {
            if (i != null && j != null)
            {
                if (cur != null)
                {
                    gap++;
                    if (gap > 1 || !IsCJK(a[ai]) || !cur.Cjk) { hs.Add(cur); cur = null; gap = 0; }
                }
                ai++; bi++;
                continue;
            }
            var ch = i != null ? a[ai] : b[bi];
            if (cur != null && gap == 1 && (!IsCJK(ch) || !cur.Cjk)) { hs.Add(cur); cur = null; }
            cur ??= new H { A0 = ai, A1 = ai, B0 = bi, B1 = bi, Cjk = true };
            gap = 0;
            if (!IsCJK(ch)) cur.Cjk = false;
            if (i != null) ai++; else bi++;
            cur.A1 = ai; cur.B1 = bi;
        }
        if (cur != null) hs.Add(cur);

        static List<H> MergeOverlaps(List<H> list)
        {
            var outL = new List<H>();
            foreach (var h in list)
            {
                if (outL.Count > 0 && (h.A0 < outL[^1].A1 || h.B0 < outL[^1].B1))
                {
                    var last = outL[^1];
                    last.A0 = Math.Min(last.A0, h.A0); last.B0 = Math.Min(last.B0, h.B0); last.A1 = Math.Max(last.A1, h.A1); last.B1 = Math.Max(last.B1, h.B1); last.Cjk = last.Cjk && h.Cjk;
                }
                else outL.Add(new H { A0 = h.A0, A1 = h.A1, B0 = h.B0, B1 = h.B1, Cjk = h.Cjk });
            }
            return outL;
        }
        bool Eq(int a0, int b0, int len) { for (int k = 0; k < len; k++) if (a[a0 + k] != b[b0 + k]) return false; return true; }
        bool ExpandKnown(H h)
        {
            (int S, int E)? best = null;
            foreach (var kn in known)
            {
                if (Str.Count(kn) < 2) continue;
                var kc = Str.Chars(kn);
                if (kc.Count <= (best is { } bb ? bb.E - bb.S : 0) || kc.Count > b.Count || kc.Count < h.B1 - h.B0) continue;
                for (int st = Math.Max(0, h.B1 - kc.Count); st <= Math.Min(h.B0, b.Count - kc.Count); st++)
                {
                    int en = st + kc.Count, la = h.A0 - (h.B0 - st), ra = h.A1 + (en - h.B1);
                    if (la < 0 || ra > a.Count) continue;
                    bool same = true;
                    for (int k = 0; k < kc.Count; k++) if (b[st + k] != kc[k]) { same = false; break; }
                    if (!same || !Eq(la, st, h.A0 - la) || !Eq(h.A1, h.B1, ra - h.A1)) continue;
                    best = (st, en);
                    break;
                }
            }
            if (best is not { } kb) return false;
            h.A0 -= h.B0 - kb.S; h.A1 += kb.E - h.B1; h.B0 = kb.S; h.B1 = kb.E;
            return true;
        }
        foreach (var h in hs.Where(h => !h.Cjk))
        {
            while (h.A0 > 0 && h.B0 > 0 && a[h.A0 - 1] == b[h.B0 - 1] && IsLatin(a[h.A0 - 1])) { h.A0--; h.B0--; }
            while (h.A1 < a.Count && h.B1 < b.Count && a[h.A1] == b[h.B1] && IsLatin(a[h.A1])) { h.A1++; h.B1++; }
        }
        hs = MergeOverlaps(hs);
        var shortOnes = new HashSet<int>();
        for (int k = 0; k < hs.Count; k++)
        {
            var h = hs[k];
            if (!ExpandKnown(h) && h.Cjk && (h.A1 - h.A0 < 2 || h.B1 - h.B0 < 2)) shortOnes.Add(k);
        }
        var outList = new List<(string, string, List<(string, string)>)>();
        for (int k = 0; k < hs.Count; k++)
        {
            var h = hs[k];
            var o = Str.TrimWS(string.Concat(a.Skip(h.A0).Take(h.A1 - h.A0)));
            var n = Str.TrimWS(string.Concat(b.Skip(h.B0).Take(h.B1 - h.B0)));
            if ((o.Length == 0 && n.Length == 0) || o == n) continue;
            var alts = new List<(string, string)>();
            if (shortOnes.Contains(k))
            {
                bool l = h.A0 > 0 && h.B0 > 0 && a[h.A0 - 1] == b[h.B0 - 1] && IsCJK(a[h.A0 - 1]);
                bool r = h.A1 < a.Count && h.B1 < b.Count && a[h.A1] == b[h.B1] && IsCJK(a[h.A1]);
                (string, string) Span(int dl, int dr) => (string.Concat(a.Skip(h.A0 - dl).Take(h.A1 + dr - h.A0 + dl)), string.Concat(b.Skip(h.B0 - dl).Take(h.B1 + dr - h.B0 + dl)));
                if (l && r) alts.Add(Span(1, 1));
                if (r) alts.Add(Span(0, 1));
                if (l) alts.Add(Span(1, 0));
                if (alts.Count == 0) continue;
            }
            if ((o.Length == 0 || n.Length == 0) && alts.Count == 0) continue;
            outList.Add((o, n, alts));
        }
        return outList;
    }

    /// Longest-common-subsequence alignment (both walked to the end): (index in a, index in b); null = that side has an extra item.
    /// Common head and tail are stripped first; on a tie a (deletion) goes first — the same steps as the Swift version
    public static List<(int? A, int? B)> Align(IReadOnlyList<string> a, IReadOnlyList<string> b)
    {
        int pre = 0;
        while (pre < a.Count && pre < b.Count && a[pre] == b[pre]) pre++;
        int suf = 0;
        while (suf < a.Count - pre && suf < b.Count - pre && a[a.Count - 1 - suf] == b[b.Count - 1 - suf]) suf++;
        int n = a.Count - pre - suf, m = b.Count - pre - suf;
        var dp = new int[n + 1, m + 1];
        for (int i = n - 1; i >= 0; i--)
            for (int j = m - 1; j >= 0; j--)
                dp[i, j] = a[pre + i] == b[pre + j] ? dp[i + 1, j + 1] + 1 : Math.Max(dp[i + 1, j], dp[i, j + 1]);
        var outList = new List<(int?, int?)>();
        for (int k = 0; k < pre; k++) outList.Add((k, k));
        int x = 0, y = 0;
        while (x < n && y < m)
        {
            if (a[pre + x] == b[pre + y]) { outList.Add((pre + x, pre + y)); x++; y++; }
            else if (dp[x + 1, y] >= dp[x, y + 1]) { outList.Add((pre + x, null)); x++; }
            else { outList.Add((null, pre + y)); y++; }
        }
        while (x < n) { outList.Add((pre + x, null)); x++; }
        while (y < m) { outList.Add((null, pre + y)); y++; }
        for (int k = 0; k < suf; k++) outList.Add((a.Count - suf + k, b.Count - suf + k));
        return outList;
    }

    /// The record header 「> 名字更正：…沒改：A→B？、C→D？（…）」 → questions to ask
    public static List<Question> QuestionsFromRecord(string md, string meeting)
    {
        var line = md.Split('\n').FirstOrDefault(l => l.Starts("> 名字更正："));
        if (line == null) return [];
        int r = line.Find("沒改：");
        if (r < 0) return [];
        var rest = line[(r + "沒改：".Length)..];
        int p = rest.Find("（沒把握");
        if (p >= 0) rest = rest[..p];
        int q = rest.Find("…等");
        if (q >= 0) rest = rest[..q];
        var outList = new List<Question>();
        foreach (var item in rest.Split("、"))
        {
            var t = Str.TrimWS(item);
            while (t.Ends("？") || t.Ends("?")) t = Str.DropLast(t, 1);
            if (Pair(t) is { } pr) outList.Add(new Question(pr.Heard, pr.Name, meeting));
        }
        return outList;
    }

    // ── files ──

    /// Names in the roster (ROSTER.md) and in this ledger: for the collision check and "looks like a name"
    static List<string> KnownNames(List<Entry> entries)
    {
        var outList = entries.Where(e => e.How != Never).Select(e => e.Name).ToList();
        var rp = Path.Combine(Paths.Memory, "ROSTER.md");
        try
        {
            if (File.Exists(rp))
            {
                var lines = Str.Lines(Clean.StripHTMLComments(File.ReadAllText(rp, Encoding.UTF8))).Select(Str.TrimWS).Where(l => l.Starts("- ")).ToList();
                outList.AddRange(PolishContext.RosterNames(lines));
            }
        }
        catch { }
        var seen = new HashSet<string>();
        return outList.Where(seen.Add).ToList();
    }

    /// Write into NAMES.md (only with memory on; pairs already there are not written again); returns what was newly written
    public static List<Entry> Record(List<(string Heard, string Name)> pairs, string who, string mdPath)
    {
        if (!ConfigStore.Shared.Current.MemoryEnabled || pairs.Count == 0) return [];
        var text = Read();
        var have = Parse(text ?? "").Entries;
        var id = Path.GetFileNameWithoutExtension(mdPath);
        var known = KnownNames(have);
        var others = new List<(string, string)>();
        foreach (var u in MemoryStore.AllRecords())
        {
            var rid = Path.GetFileNameWithoutExtension(u);
            if (rid == id) continue;
            try { others.Add((rid, RecordMD.Transcript(RecordMD.Read(u)) ?? "")); } catch { }
        }
        var day = HearbyTime.Local(DateTimeOffset.Now).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        // one misheard spelling pointing at two or more names = one word, several people: 看上下文
        var targets = pairs.Select(p => (p.Heard, p.Name)).Concat(have.Where(e => e.How != Never).Select(e => (e.Heard, e.Name)))
            .GroupBy(p => p.Item1).ToDictionary(g => g.Key, g => g.Select(p => p.Item2).Distinct().Count());
        var news = pairs.Where(p => !have.Any(e => e.Heard == p.Heard && e.Name == p.Name))
            .Select(p => new Entry(p.Heard, p.Name, targets.GetValueOrDefault(p.Heard) > 1 ? ByContext : Classify(p.Heard, id, others, known), who, day, id))
            .ToList();
        if (news.Count == 0) return [];
        try
        {
            Directory.CreateDirectory(Paths.Memory);
            File.WriteAllText(Path.Combine(Paths.Memory, FileName), Adding(news, null, text), new UTF8Encoding(false));
            HearbyLog.Write($"names: +{news.Count} ({who}) {id}");
        }
        catch (Exception e) { HearbyLog.Write($"names: 寫不進 {FileName}：{e.Message}"); return []; }
        return news;
    }

    /// Before / after editing a record: write down the names that changed
    public static List<Entry> Learn(string oldText, string newText, string who, string mdPath)
    {
        if (!ConfigStore.Shared.Current.MemoryEnabled) return [];
        return Record(PairsFromEdit(oldText, newText, KnownNames(Parse(Read() ?? "").Entries)), who, mdPath);
    }

    /// 「A」應為「B」 written when re-polishing: write down the ones that look like names
    public static List<Entry> LearnCorrections(string corrections, string mdPath)
    {
        if (!ConfigStore.Shared.Current.MemoryEnabled) return [];
        return Record(PairsFromCorrections(corrections, KnownNames(Parse(Read() ?? "").Entries)), "重新整理時的更正", mdPath);
    }

    /// --memory-rebuild: the record was changed by another program (differs from what Hearby last wrote); diff against the version
    /// Hearby last wrote (a .bak / _舊版) and write down the names that changed. That version not found (no backup before the edit) = null
    public static List<Entry>? LearnFromEdit(string mdPath)
    {
        if (!ConfigStore.Shared.Current.MemoryEnabled) return [];
        string md; try { md = RecordMD.Read(mdPath); } catch { return []; }
        var id = Path.GetFileNameWithoutExtension(mdPath);
        if (!LoadState().TryGetValue(id, out var last)) return [];
        if (Hash(md) == last) return [];
        var baseText = MemoryStore.OlderVersions(mdPath).LastOrDefault(v => Hash(v) == last);
        if (baseText == null) return null;
        return Learn(baseText, md, "改紀錄時改的", mdPath);
    }

    /// After a memory sync: remember this version (so the version before an edit can be found) and ask about names the AI was unsure of
    internal static void AfterSync(string mdPath, string md)
    {
        var id = Path.GetFileNameWithoutExtension(mdPath);
        var st = LoadState();
        var h = Hash(md);   // md as the sync read it (newlines normalized, same as LearnFromEdit reads)
        if (!st.TryGetValue(id, out var old) || old != h)
        {
            st[id] = h;
            SaveState(st);
        }
        var qs = QuestionsFromRecord(md, id);
        if (qs.Count == 0) return;
        var text = Read();
        var outText = Adding(null, qs, text);
        if (outText != (text ?? Header) || text == null)
        {
            try { File.WriteAllText(Path.Combine(Paths.Memory, FileName), outText, new UTF8Encoding(false)); HearbyLog.Write($"names: 要確認 +{qs.Count} {id}"); } catch { }
        }
    }

    /// Answer one question (是 / 不是 in the app): NAMES.md.bak-<date> first, then write
    public static void Answer(string heard, string name, bool yes)
    {
        var text = Read() ?? throw new HearbyError($"找不到 {FileName}");
        var outText = Answering(heard, name, yes ? "是" : "不是", text);
        if (outText == text) return;
        var p = Path.Combine(Paths.Memory, FileName);
        new MemoryStore.Backups().Before(p);
        File.WriteAllText(p, outText, new UTF8Encoding(false));
    }

    /// This meeting's questions not answered yet (listed on the record page)
    public static List<Question> Pending(string meeting) =>
        Parse(Read() ?? "").Questions.Where(q => q.Meeting == meeting && !q.Yes && !q.No).ToList();

    /// A meeting was renamed: "the version Hearby wrote last" moves to the new id (ids mentioned in NAMES.md change with MemoryStore)
    internal static void RenameMeeting(string old, string @new)
    {
        var st = LoadState();
        if (old == @new || !st.TryGetValue(old, out var h)) return;
        st.Remove(old);
        st[@new] = h;
        SaveState(st);
    }

    static void SaveState(Dictionary<string, string> st)
    {
        var written = new JsonObject();
        foreach (var kv in st.OrderBy(k => k.Key, StringComparer.Ordinal)) written[kv.Key] = kv.Value;
        try { File.WriteAllText(Path.Combine(Paths.Memory, StateFile), new JsonObject { ["schemaVersion"] = 1, ["written"] = written }.ToJsonString(new() { WriteIndented = true })); } catch { }
    }

    static Dictionary<string, string> LoadState()
    {
        try
        {
            var p = Path.Combine(Paths.Memory, StateFile);
            if (!File.Exists(p) || JsonNode.Parse(File.ReadAllText(p))?["written"] is not JsonObject w) return [];
            return w.Where(kv => kv.Value != null).ToDictionary(kv => kv.Key, kv => kv.Value!.GetValue<string>());
        }
        catch { return []; }
    }

    static string Hash(string s) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(s))).ToLowerInvariant();
}
