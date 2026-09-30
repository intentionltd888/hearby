// NameFixes — with a roster the model also returns a 「## 名字更正」 section (heard → name｜sure｜[stamps]…); Hearby fixes the
// transcript from it: only the listed lines, only that string. Not sure, a one-character heard string, a name that is not in the
// roster or attendee list, or a line that does not contain it = no change; those get [[?]] where the record first mentions them,
// and the record header says what was changed. Mirrors Polish/NameFixes.swift.
using System.Text.RegularExpressions;

namespace Hearby.Core;

public static class NameFixes
{
    public sealed record Fix(string Heard, string Name, bool Sure, List<string> Stamps);

    public const string Heading = "## 名字更正";
    static readonly Regex StampRe = new(@"\[((?:\d{1,2}:)?\d{1,3}:[0-5]\d)\]", RegexOptions.CultureInvariant);
    const string Quotes = " 「」『』\"'“”";

    /// Take the 「## 名字更正」 section out of the polish (up to the next 「## 」 or the end): (polish without it, fixes)
    public static (string Notes, List<Fix> Fixes) Extract(string notes)
    {
        var lines = Str.Lines(notes).ToList();
        int h = lines.FindIndex(l => Str.TrimWS(l).Starts(Heading));
        if (h < 0) return (notes, []);
        int e = lines.Count;
        for (int i = h + 1; i < lines.Count; i++) if (lines[i].Starts("## ")) { e = i; break; }
        var fixes = lines.Skip(h + 1).Take(e - h - 1).Select(Parse).OfType<Fix>().ToList();
        lines.RemoveRange(h, e - h);
        if (h > 0 && h < lines.Count && Str.TrimWS(lines[h - 1]).Length == 0 && Str.TrimWS(lines[h]).Length == 0) lines.RemoveAt(h);
        while (lines.Count > 0 && Str.TrimWS(lines[^1]).Length == 0) lines.RemoveAt(lines.Count - 1);
        return (string.Join("\n", lines), fixes);
    }

    /// 「- heard → name｜高｜[01:02] [1:03:04]」; the arrow may also be -> or =>, the bar may be ASCII; no arrow, both sides equal, 「- 無」 = not a fix
    internal static Fix? Parse(string raw)
    {
        var t = Str.TrimWS(raw);
        if (!t.Starts("-")) return null;
        t = Str.TrimWS(Str.DropFirst(t, 1));
        if (t.Length == 0 || t == "無") return null;
        var stamps = new List<string>();
        foreach (Match m in StampRe.Matches(t)) if (!stamps.Contains(m.Groups[1].Value)) stamps.Add(m.Groups[1].Value);
        t = StampRe.Replace(t, "");
        var cols = Str.SplitAny(t, "｜|").Select(Str.TrimWS).ToList();
        int at = -1, len = 0;
        foreach (var a in new[] { "→", "->", "=>" })
        {
            int k = cols[0].Find(a);
            if (k >= 0) { at = k; len = a.Length; break; }
        }
        if (at < 0) return null;
        var heard = Str.TrimSet(cols[0][..at], Quotes);
        var name = Str.TrimSet(cols[0][(at + len)..], Quotes);
        if (heard.Length == 0 || name.Length == 0 || heard == name) return null;
        bool sure = cols.Skip(1).Any(c => c == "高" || c.ToLowerInvariant() == "high");
        return new Fix(heard, name, sure, stamps);
    }

    /// Apply to the transcript (one line each 「- [mm:ss][who] text」): (new transcript, applied (fix, count), skipped).
    /// One side containing the other (「預算 → 預算表」) is rewriting, not a mishearing: dropped entirely (no change, no mark, not listed)
    public static (string Transcript, List<(Fix Fix, int Count)> Applied, List<Fix> Skipped) Apply(List<Fix> fixes, string transcript, List<string> names)
    {
        var lines = Str.Lines(transcript);
        var applied = new List<(Fix, int)>();
        var skipped = new List<Fix>();
        foreach (var f in fixes.Where(f => !f.Name.Has(f.Heard) && !f.Heard.Has(f.Name)))
        {
            if (!f.Sure || Str.Count(f.Heard) < 2 || !Known(f, names) || DropsWords(f)) { skipped.Add(f); continue; }
            int n = 0;
            foreach (var s in f.Stamps)
            {
                var prefix = $"- [{s}][";
                for (int i = 0; i < lines.Length; i++)
                {
                    var l = lines[i];
                    if (!l.Starts(prefix)) continue;
                    int close = l.Find("] ", prefix.Length);
                    if (close < 0) continue;
                    var text = l[(close + 2)..];
                    int k = Occurrences(text, f.Heard);
                    if (k == 0) continue;
                    n += k;
                    lines[i] = l[..(close + 2)] + text.Rep(f.Heard, f.Name);
                }
            }
            if (n > 0) applied.Add((f, n)); else skipped.Add(f);
        }
        return (string.Join("\n", lines), applied, skipped);
    }

    static int Occurrences(string s, string sub)
    {
        int n = 0;
        for (int i = s.Find(sub); i >= 0; i = s.Find(sub, i + sub.Length)) n++;
        return n;
    }

    /// A misheard Chinese name keeps its length; no Latin letters and a name two or more characters shorter = words were lost (「林曉安老師 → 林小安」)
    static readonly Regex Latin = new("[A-Za-z]", RegexOptions.CultureInvariant);
    static bool DropsWords(Fix f) => !Latin.IsMatch(f.Heard) && !Latin.IsMatch(f.Name) && Str.Count(f.Heard) - Str.Count(f.Name) >= 2;

    /// The name must contain a roster (or attendee) name that the heard string does not (「凌那邊 → 林那邊」: 林);
    /// or the name is part of a roster name (a short form: 「亞特」 of 亞特蘭提斯, 「昱廷」 of 吳昱廷) and the heard string sounds like it (SoundAlike.Close)
    static bool Known(Fix f, List<string> names) =>
        names.Any(x => x.Length > 0 && f.Name.Has(x) && !f.Heard.Has(x))
        || (Str.Count(f.Name) >= 2 && names.Any(x => Str.Count(x) > Str.Count(f.Name) && x.Has(f.Name)) && SoundAlike.Close(f.Heard, f.Name));

    /// Not changed: mark [[?]] after the first mention — section by section (summary → key points → decisions → open questions;
    /// attendees and to-dos untouched), in each the name first, then the heard string; one-character words are not marked; each name once
    public static string MarkUnsure(string notes, List<Fix> fixes, string transcript = "")
    {
        if (fixes.Count == 0) return notes;
        var lines = Str.Lines(notes);
        var section = new List<string>();
        var cur = "";
        foreach (var l in lines)
        {
            if (l.Starts("## ")) { cur = Str.DropFirst(l, 3); section.Add(""); } else section.Add(cur);
        }
        var seen = new HashSet<string>();
        foreach (var f in fixes)
        {
            if (!seen.Add(f.Name)) continue;
            bool done = false;
            foreach (var key in new[] { "摘要", "重點", "決議", "開放問題" })
            {
                // The name already spoken in the transcript (any case; e.g. a company name): mentioning it is right — look only for the heard string
                bool spoken = transcript.Length > 0 && transcript.Contains(f.Name, StringComparison.OrdinalIgnoreCase);
                foreach (var word in spoken ? new[] { f.Heard } : new[] { f.Name, f.Heard })
                {
                    if (Str.Count(word) < 2) continue;
                    for (int i = 0; i < lines.Length; i++)
                    {
                        if (!section[i].Has(key)) continue;
                        int r = lines[i].Find(word);
                        if (r < 0) continue;
                        var rest = lines[i][(r + word.Length)..];
                        if (!(rest.Starts(" [[?]]") || rest.Starts("[[?]]"))) lines[i] = lines[i][..(r + word.Length)] + " [[?]]" + rest;
                        done = true;
                        break;
                    }
                    if (done) break;
                }
                if (done) break;
            }
        }
        return string.Join("\n", lines);
    }

    /// The record header line; nothing to say = null
    public static string? HeaderLine(List<(Fix Fix, int Count)> applied, List<Fix> unsure)
    {
        if (applied.Count == 0 && unsure.Count == 0) return null;
        static string List(List<string> xs) => string.Join("、", xs.Take(6)) + (xs.Count > 6 ? $"…等 {xs.Count} 組" : "");
        var parts = new List<string>();
        if (applied.Count > 0)
        {
            int total = applied.Sum(a => a.Count);
            parts.Add($"逐字稿照名冊改了 {total} 處（" + List(applied.Select(a => $"{a.Fix.Heard}→{a.Fix.Name}" + (a.Count > 1 ? $" ×{a.Count}" : "")).ToList()) + "）");
        }
        if (unsure.Count > 0)
            // 全列不截：記憶同步從這一段出「要確認」的題目（NameLedger.QuestionsFromRecord），截掉的就問不到
            parts.Add("沒改：" + string.Join("、", unsure.Select(u => $"{u.Heard}→{u.Name}？")) + "（沒把握，或名冊、逐字稿對不上；紀錄裡提到的地方標了 [[?]]）");
        return "> 名字更正：" + string.Join("；", parts);
    }

    /// A to-do that is the same as one still open in OPEN.md from another meeting (same item, no new owner or due) is not opened again
    public static string DropRepeatedTodos(string notes, List<string> open)
    {
        var known = open.Select(row =>
        {
            var c = row.Split('｜');
            return (Item: c[0], Owner: c.Length > 1 ? c[1] : "", Due: c.Length > 2 ? c[2] : "");
        }).ToList();
        if (known.Count == 0) return notes;
        bool inTodo = false;
        return string.Join("\n", Str.Lines(notes).Where(line =>
        {
            if (line.Starts("## ")) inTodo = line.Has("待辦");
            if (!inTodo || !line.Starts("- [ ] ")) return true;
            var c = Str.DropFirst(line, 6).Split('｜').Select(Str.TrimWS).ToList();
            var owner = c.Count > 1 ? c[1] : "";
            var due = c.Count > 2 ? c[2] : "";
            return !known.Any(k => k.Item == c[0] && (owner.Length == 0 || owner == k.Owner) && (due.Length == 0 || due == k.Due));
        }));
    }
}
