// FollowUps — the record's 「## 之前的事」: carried-in to-dos, projects and undecided items this meeting talked about, one per line
// 「- 事情 → 這場怎麼了 [mm:ss]」. Lines without a timestamp are dropped; an empty section is removed; during memory sync a 「做完／不做了」
// ticks that item in OPEN.md when it came from another meeting. Mirrors Polish/FollowUps.swift.
using System.Text.RegularExpressions;

namespace Hearby.Core;

public static class FollowUps
{
    public const string Heading = "## 之前的事";
    static readonly Regex StampRe = new(@"\[(?:\d{1,2}:)?\d{1,3}:[0-5]\d\]", RegexOptions.CultureInvariant);
    static readonly string[] DoneWords = ["做完", "完成", "交了", "搞定", "不做了", "取消"];
    static readonly string[] NotDoneWords = ["沒做完", "還沒", "未完成", "沒完成", "不確定"];

    /// The section in the polish: lines without a timestamp go; empty (or only 「無」) = the whole section goes
    public static string Prune(string notes)
    {
        var lines = Str.Lines(notes).ToList();
        int h = lines.FindIndex(l => Str.TrimWS(l) == Heading);
        if (h < 0) return notes;
        int e = lines.Count;
        for (int i = h + 1; i < lines.Count; i++) if (lines[i].Starts("## ")) { e = i; break; }
        var kept = lines.Skip(h + 1).Take(e - h - 1).Where(l => { var t = Str.TrimWS(l); return t.Starts("- ") && StampRe.IsMatch(t); }).ToList();
        if (kept.Count == 0)
        {
            lines.RemoveRange(h, e - h);
            if (h > 0 && h < lines.Count && Str.TrimWS(lines[h - 1]).Length == 0 && Str.TrimWS(lines[h]).Length == 0) lines.RemoveAt(h);
            while (lines.Count > 0 && Str.TrimWS(lines[^1]).Length == 0) lines.RemoveAt(lines.Count - 1);
        }
        else
        {
            lines.RemoveRange(h + 1, e - h - 1);
            lines.InsertRange(h + 1, kept);
        }
        return string.Join("\n", lines);
    }

    /// Items the record marks 做完／不做了 (「- 事情 → 結果 [mm:ss]」; an item written 「事項｜負責人｜…」 takes the first column)
    public static List<string> DoneItems(string md)
    {
        var outList = new List<string>();
        bool inSec = false;
        foreach (var raw in md.Split('\n'))
        {
            var l = Str.TrimWS(raw);
            if (l.Starts("## ")) { inSec = l == Heading; continue; }
            if (!inSec || !l.Starts("- ")) continue;
            int arrow = l.Find("→");
            if (arrow < 0) continue;
            var item = Str.TrimWS(l[2..arrow].Split('｜')[0]);
            var result = l[(arrow + 1)..];
            if (item.Length == 0 || !DoneWords.Any(result.Has) || NotDoneWords.Any(result.Has)) continue;
            if (!outList.Contains(item)) outList.Add(item);
        }
        return outList;
    }

    /// OPEN.md: the unticked line from another meeting with exactly that item gets ticked (this meeting's own lines follow the record)
    public static string Tick(string text, List<string> done, string meeting)
    {
        if (done.Count == 0) return text;
        return string.Join("\n", text.Split('\n').Select(line =>
        {
            if (!line.Starts("- [ ] ")) return line;
            var cols = line[6..].Split('｜');
            var item = Str.TrimWS(cols[0]);
            var from = cols.Length >= 4 ? Str.TrimWS(cols[^1]) : "";
            return done.Contains(item) && from != meeting ? "- [x] " + line[6..] : line;
        }));
    }
}
