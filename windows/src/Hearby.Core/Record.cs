// Record — record md parsing and the client version (format unchanged). Mirrors Export/Record.swift.
using System.Text;
using System.Text.RegularExpressions;

namespace Hearby.Core;

public sealed record Todo(string Item, string Owner, string Due, bool Done);

public sealed class MeetingRecord
{
    public string Title = "會議紀錄";
    public string Meta = "";
    public List<(string Name, List<string> Lines)> Sections = [];
    public string DeclaredAttendees = "";
    public List<Todo> Todos = [];
    public List<string> Images = [];

    static readonly Regex DateRe = new(@"\d{4}-\d{2}-\d{2} \d{2}:\d{2}", RegexOptions.CultureInvariant);

    public List<string>? Section(string name) => Sections.FirstOrDefault(s => s.Name.Has(name)).Lines;

    /// (date, duration, custom title)
    public (string Date, string Dur, string Custom) Parts
    {
        get
        {
            var metaParts = Meta.Split('｜').Select(Str.TrimWS).ToList();
            var custom = metaParts.Count > 2 ? string.Join("｜", metaParts.Skip(2)) : "";
            var dur = Str.TrimWS((metaParts.FirstOrDefault(p => p.Starts("時長")) ?? "").Rep("時長", ""));
            var m = DateRe.Match(Title);
            return (m.Success ? m.Value : "", dur, custom);
        }
    }

    public string SummaryText => string.Join(" ", Section("摘要") ?? Section("一句話") ?? []);
    public RecordScene Scene => RecordSceneExt.FromMdTitle("# " + Title);
    public bool IsNote => Scene == RecordScene.Note;

    public List<string> People => (Section("與會者") ?? []).Select(l =>
    {
        var t = Str.TrimWS(l);
        foreach (var sep in new[] { "—", "──", "--" }) { int r = t.Find(sep); if (r >= 0) t = t[..r]; }
        return Str.TrimWS(t);
    }).Where(t => t.Length > 0 && !t.Starts(">")).ToList();
}

public static class RecordMD
{
    static readonly Regex StampRe = new(@"\s*\[(?:\d{1,2}:)?\d{1,3}:[0-5]\d\]", RegexOptions.CultureInvariant);

    public static (string Item, string Owner, string Due) TodoParts(string raw)
    {
        var t = Str.TrimWS(raw);
        if (t.Has("｜"))
        {
            var p = t.Split('｜').Select(Str.TrimWS).ToList();
            return (p[0], p.Count > 1 ? p[1] : "", p.Count > 2 ? string.Join("｜", p.Skip(2)) : "");
        }
        if (t.Ends("）"))
        {
            int open = t.FindLast("（");
            if (open >= 0)
            {
                var item = Str.TrimWS(t[..open]);
                var inner = t[(open + 1)..^1];
                var p = inner.Split('；').Select(Str.TrimWS).ToList();
                return (item, p.Count > 0 ? p[0] : "", p.Count > 1 ? p[1] : "");
            }
        }
        return (t, "", "");
    }

    public static MeetingRecord Parse(string md)
    {
        var rec = new MeetingRecord();
        string? current = null;
        var lines = new List<string>();
        void Flush()
        {
            if (current is { } c && lines.Count > 0 && !c.Has("待辦")) rec.Sections.Add((c, lines));
            lines = [];
        }
        const string declared = "> 與會者（你填的）：";
        foreach (var rawLine in Str.Lines(md))
        {
            var line = Str.TrimWS(rawLine);
            if (line.Starts("# ")) rec.Title = line[2..];
            else if (line.Starts("> "))
            {
                if (rec.Meta.Length == 0) rec.Meta = line[2..];
                else if (line.Starts(declared)) rec.DeclaredAttendees = Str.TrimWS(line[declared.Length..]);
            }
            else if (line.Starts("## ")) { Flush(); current = line[3..]; }
            else if (line.Starts("- [ ] ") || line.Starts("- [x] ") || line.Starts("- [X] "))
            {
                bool done = !line.Starts("- [ ] ");
                var p = TodoParts(line[6..]);
                if (p.Item != "無") rec.Todos.Add(new Todo(p.Item, p.Owner, p.Due, done));
            }
            else if (line.Starts("![](") && line.Ends(")")) rec.Images.Add(line[4..^1]);
            else if (line.Starts("- ")) { var t = line[2..]; if (t != "無") lines.Add(t); }
            else if (line.Length > 0) lines.Add(line);
        }
        Flush();
        if (rec.DeclaredAttendees.Length > 0 && !rec.Sections.Any(s => s.Name.Has("與會者")))
        {
            var names = Str.SplitAny(rec.DeclaredAttendees, "、,，").Select(Str.TrimWS).Where(x => x.Length > 0).ToList();
            if (names.Count > 0) rec.Sections.Insert(0, ("與會者", names));
        }
        return rec;
    }

    /// Client version: no transcript, no internal paths or warnings, no correction log, no timestamps
    public static string ClientVersion(string md)
    {
        int cut = md.Find("\n## 逐字稿");
        var record = cut >= 0 ? md[..cut] : md;
        var outList = new List<string>();
        bool inAttendees = false, skipSection = false;
        foreach (var raw in Str.Lines(record))
        {
            var line = Str.TrimWS(raw);
            if (line.Starts("## ")) skipSection = line.Has("修正紀錄");
            if (skipSection) continue;
            if (line.Has("模型未交代此條") || line.Has("AI 整理未執行")) continue;
            if (line.Starts("> 音檔：") || line.Starts("> ⚠") || line.Starts("> 本機模型整理") || line.Starts("> 名字更正") || line == "---") continue;
            if (line.Starts("（AI 整理失敗") || line.Starts("（AI 整理已關閉") || line.Starts("（AI 整理進行中") || line.Starts("（只有逐字稿"))
            {
                outList.Add("（本場僅整理逐字稿，未附 AI 摘要）");
                continue;
            }
            if (line.Starts("## ")) inAttendees = line.Has("與會者");
            if (inAttendees && line.Starts("- "))
            {
                int r = line.Find("—");
                if (r >= 0) { outList.Add(Str.TrimWS(line[..r])); continue; }
            }
            outList.Add(raw);
        }
        return StampRe.Replace(string.Join("\n", outList), "");
    }

    /// First bytes of a record (the list never reads whole files)
    public static string? Head(string path, int maxBytes = 4096)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var buf = new byte[maxBytes];
            int n = fs.Read(buf, 0, buf.Length);
            if (n <= 0) return null;
            var strict = new UTF8Encoding(false, true);
            try { return Str.NormalizeNewlines(strict.GetString(buf, 0, n)); }
            catch
            {
                int nl = Array.LastIndexOf(buf, (byte)'\n', n - 1);
                if (nl <= 0) return null;
                try { return Str.NormalizeNewlines(strict.GetString(buf, 0, nl)); } catch { return null; }
            }
        }
        catch { return null; }
    }

    /// Transcript section (after the last 「## 逐字稿」)
    public static string? Transcript(string md)
    {
        int r = md.FindLast("## 逐字稿");
        if (r < 0) return null;
        var t = Str.TrimWSNL(md[(r + "## 逐字稿".Length)..]);
        return t.Length == 0 ? null : t;
    }

    /// Rename: the title in the header's first line "> Hearby 錄音｜時長 …｜title" becomes the new one (added when there was none);
    /// "> 音檔：path" goes through audio (null = unchanged). Only the header before the first "## "; a first line not in the
    /// "…｜時長 …" format is left alone; every other line stays byte for byte (CRLF kept)
    public static string Retitled(string md, string title, Func<string, string?>? audio = null)
    {
        var lines = md.Split('\n');
        bool sawHead = false;
        for (int i = 0; i < lines.Length; i++)
        {
            bool cr = lines[i].Ends("\r");
            var line = cr ? lines[i][..^1] : lines[i];
            var trimmed = Str.TrimWS(line);
            if (trimmed.Starts("## ")) break;
            int at = line.Find("> ");
            if (!trimmed.Starts("> ") || at < 0) continue;
            var lead = line[..at];
            var body = trimmed[2..];
            if (!sawHead)
            {
                sawHead = true;
                var parts = body.Split('｜');
                if (parts.Length < 2 || !Str.TrimWS(parts[1]).Starts("時長")) continue;
                lines[i] = lead + "> " + string.Join("｜", parts.Take(2).Append(title)) + (cr ? "\r" : "");
            }
            else if (body.Starts("音檔："))
            {
                var path = Str.TrimWS(body["音檔：".Length..]);
                if (audio?.Invoke(path) is { } p) lines[i] = lead + "> 音檔：" + p + (cr ? "\r" : "");
            }
        }
        return string.Join("\n", lines);
    }

    /// Read a record as text (UTF-8, newlines normalised: Windows editors save CRLF)
    public static string Read(string path) => Str.NormalizeNewlines(File.ReadAllText(path, Encoding.UTF8));

    /// Write a record (UTF-8 without BOM, LF)
    public static void Write(string path, string md)
    {
        var tmp = path + ".tmp-" + Environment.ProcessId;
        File.WriteAllText(tmp, md, new UTF8Encoding(false));
        File.Move(tmp, path, overwrite: true);
    }

    /// Before overwriting: keep a copy as _舊版N.md (never overwrites an existing backup)
    public static void BackupIfExists(string path)
    {
        try
        {
            var fi = new FileInfo(path);
            if (!fi.Exists || fi.Length == 0) return;
            var dir = fi.DirectoryName!;
            var b = Path.GetFileNameWithoutExtension(path);
            var ext = Path.GetExtension(path).TrimStart('.');
            if (ext.Length == 0) ext = "md";
            int k = 1;
            var bak = Path.Combine(dir, $"{b}_舊版{k}.{ext}");
            while (File.Exists(bak) && k < 50) { k++; bak = Path.Combine(dir, $"{b}_舊版{k}.{ext}"); }
            if (File.Exists(bak)) bak = Path.Combine(dir, $"{b}_舊版_{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}.{ext}");
            File.Copy(path, bak);
        }
        catch (Exception e) { HearbyLog.Write($"backup fail {Path.GetFileName(path)}: {e.Message}"); }
    }
}
