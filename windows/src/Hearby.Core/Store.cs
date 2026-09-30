// Store — entry files for the user's AI, the meeting list, memory (five files + index.json), re-polish, mirror copy.
// Mirrors Store/EntryFiles.swift, Store/MeetingIndex.swift, Memory/MemoryStore.swift, Polish/Repolish.swift.
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hearby.Core;

public static class EntryFiles
{
    public const string ClaudeMD =
        "# 這是我的會議記憶（Hearby 整理的）\n\n" +
        "- 認識的人、在談的事、還沒完成的事：`memory/` 裡五個檔，先讀 `THREADS.md` 和 `OPEN.md`\n" +
        "- 要找哪一場：`memory/index.json`；逐字稿與紀錄在 `會議/<日期_時間_標題>/`\n" +
        "- 每份紀錄的結構：`## AI 會議摘要`／`## 與會者`／`## 重點`／`## 決議`／`## 待辦`／`## 逐字稿`；重點與決議每行尾的 [mm:ss] 是逐字稿裡的出處\n" +
        "- 我跟你討論完的新決定，請直接寫進 `memory/THREADS.md` 對應那條，待辦寫進 `memory/OPEN.md`（格式：`- [ ] 事項｜負責人｜期限｜會議id`）\n" +
        "- 你幫我改了紀錄裡的人名：改之前先留 `<檔名>.bak-日期`，改完跑 Hearby 的 `--memory-rebuild <那份 md>`（指令寫在 AGENTS.md），改過的名字會記進 `memory/NAMES.md`，下一場自己就對\n" +
        "- 要改一場的標題：用 Hearby（紀錄清單滑到那一場按筆，或跑 `--rename <那份 md> \"<新標題>\"`），不要自己改 `會議/` 裡的資料夾名或檔名（記憶的路徑會斷）\n" +
        "- 規矩：我手改過的行不要動；不確定的標 [[?]]；不要發明我沒說過的話；不要動 `會議/` 裡的 .m4a";

    /// Create if missing (never overwrite what the user changed)
    public static void Ensure()
    {
        foreach (var name in new[] { "CLAUDE.md", "AGENTS.md" })
        {
            var u = Path.Combine(Paths.Root, name);
            try { if (!File.Exists(u)) { Directory.CreateDirectory(Paths.Root); File.WriteAllText(u, ClaudeMD, new UTF8Encoding(false)); } } catch { }
        }
    }

    public static string RelativeToRoot(string path)
    {
        var root = Paths.Root.TrimEnd('\\', '/') + Path.DirectorySeparatorChar;
        var rel = path.Starts(root) ? path[root.Length..] : path;
        return rel.Replace('\\', '/');
    }

    /// First line for "talk it over with Claude"
    public static string ContinueQuestion(string mdPath) =>
        $"我們剛開完〈{Path.GetFileNameWithoutExtension(mdPath)}〉，紀錄在 {RelativeToRoot(mdPath)}，讀完先列三個我該接著決定的事";
}

public sealed class MeetingItem
{
    public required string Dir { get; init; }
    public string? MdPath { get; init; }
    public required string FolderName { get; init; }
    public string DateText { get; init; } = "";
    public string Title { get; init; } = "";
    public string DurText { get; set; } = "";
    public string Gist { get; set; } = "";
    public DateTime? Modified { get; init; }
    public string AudioPath => Path.Combine(Dir, FolderName + ".m4a");
}

public static class MeetingIndex
{
    static readonly Regex StampedFolder = new(@"^\d{4}-\d{2}-\d{2}_\d{4}", RegexOptions.CultureInvariant);

    public static List<MeetingItem> Scan()
    {
        var items = new List<MeetingItem>();
        if (!Directory.Exists(Paths.Meetings)) return items;
        foreach (var d in Directory.EnumerateDirectories(Paths.Meetings))
        {
            var b = Path.GetFileName(d);
            string? md = Path.Combine(d, b + ".md");
            if (!File.Exists(md))
            {
                var mds = Directory.EnumerateFiles(d, "*.md").Where(f => !Path.GetFileName(f).Has("_舊版")).ToList();
                md = mds.Count == 1 ? mds[0] : null;
            }
            if (md == null && !StampedFolder.IsMatch(b)) continue;
            DateTime? mod = null; try { mod = Directory.GetLastWriteTime(d); } catch { }
            var (dateText, titleText) = Split(b);
            var item = new MeetingItem { Dir = d, MdPath = md, FolderName = b, DateText = dateText, Title = titleText.Length == 0 ? b : titleText, Modified = mod };
            if (md != null && RecordMD.Head(md) is { } head)
            {
                var durLine = Str.Lines(head).FirstOrDefault(l => l.Starts("> ") && l.Has("時長"));
                if (durLine != null) item.DurText = Str.TrimWS((durLine.Split('｜').FirstOrDefault(p => p.Has("時長")) ?? "").Rep("時長", ""));
                int r = head.Find("## AI 會議摘要"); string key = "## AI 會議摘要";
                if (r < 0) { r = head.Find("## 摘要"); key = "## 摘要"; }
                if (r < 0) { r = head.Find("## 一句話"); key = "## 一句話"; }
                if (r >= 0)
                {
                    var after = Str.TrimWSNL(head[(r + key.Length)..]);
                    var s = Str.Lines(after)[0];
                    int dot = s.Find("。");
                    if (dot >= 0) s = s[..(dot + 1)];
                    if (Str.Count(s) > 42) s = Str.Prefix(s, 42) + "…";
                    item.Gist = Str.TrimWS(s);
                }
            }
            items.Add(item);
        }
        return items.OrderByDescending(i => i.Modified ?? DateTime.MinValue).ToList();
    }

    /// yyyy-MM-dd_HHmm_標題 → ("yyyy-MM-dd HH:mm", 標題)
    public static (string Date, string Title) Split(string folderName)
    {
        var ch = Str.Chars(folderName);
        if (ch.Count < 15 || ch[10] != "_") return ("", folderName);
        var d = string.Concat(ch.Take(10));
        var t = string.Concat(ch.Skip(11).Take(4));
        var rest = ch.Count > 16 ? string.Concat(ch.Skip(16)) : "";
        return ($"{d} {Str.Prefix(t, 2)}:{Str.Suffix(t, 2)}", rest);
    }

    /// Search what was said: full-text over the records (meeting + line)
    public static List<(MeetingItem Item, string Line)> Search(string q, int limit = 50)
    {
        var needle = Str.TrimWS(q);
        var outList = new List<(MeetingItem, string)>();
        if (Str.Count(needle) < 2) return outList;
        foreach (var item in Scan())
        {
            if (item.MdPath == null) continue;
            string s; try { s = RecordMD.Read(item.MdPath); } catch { continue; }
            foreach (var line in Str.Lines(s))
            {
                if (CultureInfo.CurrentCulture.CompareInfo.IndexOf(line, needle, CompareOptions.IgnoreCase) < 0) continue;
                outList.Add((item, Str.TrimWS(line)));
                if (outList.Count >= limit) return outList;
            }
        }
        return outList;
    }
}

/// Memory — ~/Hearby/memory/ five files + index.json (mechanical, plain strings, no model).
/// Rules: lines the user changed are never touched — only lines Hearby wrote and nobody changed since get replaced; what the user
/// checked, rewrote or deleted stays that way. One meeting, one entry: writing the same id again syncs it to what the record says now.
/// Before an existing line is replaced or removed the file is copied to <name>.bak-<date> (never overwritten, nothing deleted).
/// Which lines are Hearby's: memory/.hearby-written.json keeps each meeting's last computed lines; a line identical to those (or to
/// this run's) is Hearby's. Meetings written before that file existed are recognised from every version of the record that is still
/// there (_舊版N.md, .md.bak-*, the current md). Whole lines rather than markers in the files or hashes: the files people and their AI
/// read stay clean, a record edited in another editor with no old version left is still recognised, and the book is readable when
/// something goes wrong. Mirrors Memory/MemoryStore.swift.
public static class MemoryStore
{
    public static readonly string[] Files = ["PEOPLE.md", "MEETINGS.md", "THREADS.md", "OPEN.md", "GLOSSARY.md"];
    /// Each meeting's last computed memory lines (tells Hearby's lines from the user's; not for people or the AI to read)
    public const string WrittenBook = ".hearby-written.json";
    static string Url(string name) => Path.Combine(Paths.Memory, name);
    static readonly Regex StampRe = new(@"\s*\[(?:\d{1,2}:)?\d{1,3}:[0-5]\d\]", RegexOptions.CultureInvariant);

    public static void Ensure()
    {
        Directory.CreateDirectory(Paths.Memory);
        var heads = new Dictionary<string, string>
        {
            ["PEOPLE.md"] = "# 人（誰是誰、怎麼稱呼、出席過哪些會）\n\n<!-- 每人一節：## 名字 ／ - 別名：… ／ - 單位：… ／ - 出席：會議 id -->\n",
            ["MEETINGS.md"] = "# 會議（每場一段：摘要、決議；完整紀錄在 會議/ 資料夾）\n",
            ["THREADS.md"] = "# 議題（跨會議在談的事；跟 AI 討論完的新決定寫回這裡）\n",
            ["OPEN.md"] = "# 還沒完成的事（開完會自動搬進來；完成就打勾）\n",
            ["GLOSSARY.md"] = "# 專有名詞與別名（正名 = 別名1, 別名2；下一場聽打後自動改正）\n",
        };
        foreach (var f in Files) if (!File.Exists(Url(f))) File.WriteAllText(Url(f), heads[f], new UTF8Encoding(false));
        var idx = Url("index.json");
        if (!File.Exists(idx)) File.WriteAllText(idx, JsonUtil.SortedPretty(new JsonObject { ["schemaVersion"] = 1, ["meetings"] = new JsonArray(), ["consumers"] = new JsonArray() }), new UTF8Encoding(false));
    }

    static JsonObject LoadIndex()
    {
        try { if (JsonNode.Parse(File.ReadAllText(Url("index.json"), Encoding.UTF8)) is JsonObject o) return o; } catch { }
        return new JsonObject { ["schemaVersion"] = 1, ["meetings"] = new JsonArray(), ["consumers"] = new JsonArray() };
    }

    // ── sync ──

    /// What one sync did (the command line prints it)
    public sealed class SyncReport
    {
        public string Id = "";
        /// First time this meeting went into memory
        public bool IsNew;
        /// Files that changed
        public List<string> Changed = [];
        /// The user's own lines in this meeting (left as they are)
        public int Kept;
        /// Backups made this time
        public List<string> Backups = [];
    }

    /// Put this meeting into memory: first time = append; already there = sync to what the record says now.
    /// Memory switched off, or not a meeting's main record = nothing written, null.
    public static SyncReport? Sync(string mdPath)
    {
        if (!ConfigStore.Shared.Current.MemoryEnabled) return null;
        return Sync(mdPath, new Backups());
    }

    /// Sync several meetings (--memory-rebuild without a file): each file is backed up at most once per run; one failure does not stop the rest
    public static List<(string Path, SyncReport? Report, string? Error)> Sync(IEnumerable<string> paths)
    {
        var outList = new List<(string, SyncReport?, string?)>();
        if (!ConfigStore.Shared.Current.MemoryEnabled) return outList;
        var b = new Backups();
        foreach (var p in paths)
        {
            try { outList.Add((p, Sync(p, b), null)); } catch (Exception e) { outList.Add((p, null, e.Message)); }
        }
        return outList;
    }

    /// Only a meeting's main record goes into memory: translations (<name>.en.md…) and pre-overwrite copies (_舊版N.md) do not
    public static bool IsMainRecord(string path)
    {
        var n = Path.GetFileName(path);
        return Path.GetExtension(path).Equals(".md", StringComparison.OrdinalIgnoreCase) && !n.Starts(".") && !n.Has("_舊版") && DocLabels.LanguageOf(path) == "zh";
    }

    /// Every meeting's main record under 會議/ (<folder>.md, else the folder's only main record), by folder name (date first = oldest first)
    public static List<string> AllRecords()
    {
        var outList = new List<string>();
        if (!Directory.Exists(Paths.Meetings)) return outList;
        foreach (var d in Directory.EnumerateDirectories(Paths.Meetings).OrderBy(x => Path.GetFileName(x), StringComparer.Ordinal))
        {
            var named = Path.Combine(d, Path.GetFileName(d) + ".md");
            if (File.Exists(named)) { outList.Add(named); continue; }
            var mains = Directory.EnumerateFiles(d).Where(IsMainRecord).ToList();
            if (mains.Count == 1) outList.Add(mains[0]);
        }
        return outList;
    }

    internal static SyncReport? Sync(string mdPath, Backups backups)
    {
        if (!IsMainRecord(mdPath)) { HearbyLog.Write($"memory: {Path.GetFileName(mdPath)} 不是一場的主紀錄，略過"); return null; }
        Ensure();
        string md; try { md = RecordMD.Read(mdPath); } catch { return null; }
        var id = Path.GetFileNameWithoutExtension(mdPath);
        int madeBefore = backups.Made.Count;
        var now = EntryOf(md, id);
        var report = new SyncReport { Id = id };

        var idx = LoadIndex();
        var rows = idx["meetings"] as JsonArray ?? [];
        int row = -1;
        for (int i = 0; i < rows.Count; i++) if (JsonUtil.S(rows[i]?["id"]) == id) { row = i; break; }
        report.IsNew = row < 0;

        var texts = new[] { "MEETINGS.md", "OPEN.md", "PEOPLE.md" }.Select(f => ReadText(Url(f))).ToArray();

        // What went out last time (written) and what can be recognised as Hearby's (owned): from the book if it has it, else recomputed
        var book = LoadBook();
        var bookMeetings = book["meetings"] as JsonObject ?? new JsonObject();
        var known = bookMeetings[id] as JsonObject ?? new JsonObject();
        var written = new Lines();
        var owned = new Lines();
        if (known["MEETINGS.md"] == null || known["OPEN.md"] == null || known["PEOPLE.md"] == null)
        {
            var olds = OlderVersions(mdPath).Append(md).Select(v => EntryOf(v, id)).ToList();
            var rowPeople = row >= 0 ? StrList(rows[row]?["people"]) : [];
            var rowTitle = row >= 0 ? JsonUtil.S(rows[row]?["title"]) ?? "" : "";
            bool wasWritten = row >= 0 || (texts[0] is { } mt && BlockRange(Str.Lines(mt).ToList(), id) != null);
            if (wasWritten && olds.Count > 0)
            {
                var first = olds[0];
                written = new Lines { Meetings = [.. first.Meetings], Open = OpenLines(first, id, []), Names = row >= 0 ? NamesOf(rowPeople) : [.. first.Names] };
            }
            foreach (var e in olds) { owned.Meetings.AddRange(e.Meetings); owned.Open.AddRange(OpenLines(e, id, [])); owned.Names.AddRange(e.Names); }
            if (rowPeople.Count > 0) { owned.Meetings.Add($"- 與會：{string.Join("、", rowPeople)}"); owned.Names.AddRange(NamesOf(rowPeople)); }
            if (rowTitle.Length > 0) owned.Meetings.Add($"- 標題：{rowTitle}");
        }
        if (StrListOrNull(known["MEETINGS.md"]) is { } w1) { written.Meetings = w1; owned.Meetings = [.. w1]; }
        if (StrListOrNull(known["OPEN.md"]) is { } w2) { written.Open = w2; owned.Open = [.. w2]; }
        if (StrListOrNull(known["PEOPLE.md"]) is { } w3) { written.Names = w3; owned.Names = [.. w3]; }
        var fresh = new Lines { Meetings = now.Meetings, Open = OpenLines(now, id, written.Open), Names = now.Names };
        owned.Meetings.AddRange(fresh.Meetings); owned.Open.AddRange(fresh.Open); owned.Names.AddRange(fresh.Names);

        var entryBook = (JsonObject)known.DeepClone();
        if (texts[0] is { } t0)
        {
            var m = MergeMeetings(t0, id, fresh.Meetings, [.. owned.Meetings], written.Meetings);
            report.Kept += m.Kept;
            if (Save(m.Text, t0, Url("MEETINGS.md"), m.Touched, backups)) report.Changed.Add("MEETINGS.md");
            entryBook["MEETINGS.md"] = ToArray(fresh.Meetings);
        }
        if (texts[1] is { } t1)
        {
            var m = MergeOpen(t1, id, fresh.Open, [.. owned.Open], written.Open);
            report.Kept += m.Kept;
            if (Save(m.Text, t1, Url("OPEN.md"), m.Touched, backups)) report.Changed.Add("OPEN.md");
            entryBook["OPEN.md"] = ToArray(fresh.Open);
            // the record's 「之前的事」 marks something done: tick that line from another meeting (an existing line changes: backup first)
            var ticked = FollowUps.Tick(m.Text, FollowUps.DoneItems(md), id);
            if (ticked != m.Text && Save(ticked, m.Text, Url("OPEN.md"), true, backups) && !report.Changed.Contains("OPEN.md")) report.Changed.Add("OPEN.md");
        }
        if (texts[2] is { } t2)
        {
            var m = MergePeople(t2, id, fresh.Names, owned.Names.Distinct().ToList(), written.Names);
            if (Save(m.Text, t2, Url("PEOPLE.md"), m.Touched, backups)) report.Changed.Add("PEOPLE.md");
            entryBook["PEOPLE.md"] = ToArray(fresh.Names);
        }

        // index.json: a new meeting gets a row; an existing one only has people / title updated
        if (row >= 0)
        {
            var x = rows[row]!.AsObject();
            if (!StrList(x["people"]).SequenceEqual(now.People) || (JsonUtil.S(x["title"]) ?? "") != now.Title)
            {
                x["people"] = ToArray(now.People);
                x["title"] = now.Title;
                backups.Before(Url("index.json"));
                SaveJson(idx, Url("index.json"));
                report.Changed.Add("index.json");
            }
        }
        else
        {
            rows.Add(new JsonObject
            {
                ["id"] = id, ["title"] = now.Title, ["date"] = now.Date, ["seconds"] = now.Seconds,
                ["path"] = $"會議/{id}/{id}.md", ["people"] = ToArray(now.People),
            });
            if (rows.Parent == null) idx["meetings"] = rows;
            SaveJson(idx, Url("index.json"));
            report.Changed.Add("index.json");
        }

        if (!JsonNode.DeepEquals(bookMeetings[id], entryBook))
        {
            bookMeetings[id] = entryBook;
            if (bookMeetings.Parent == null) book["meetings"] = bookMeetings;
            book["schemaVersion"] = 1;
            SaveJson(book, Url(WrittenBook));
        }
        report.Backups = backups.Made.Skip(madeBefore).ToList();
        HearbyLog.Write($"memory: {(report.IsNew ? "appended" : "synced")} {id} changed={string.Join(",", report.Changed)} kept={report.Kept}");
        NameLedger.AfterSync(mdPath, md);   // remember this version (--memory-rebuild finds the one before an edit); unsure names go to 要確認
        return report;
    }

    // ── rename ──

    /// Every meeting id we know of: index.json's, the folder names under 會議/ and their main records' names
    internal static List<string> KnownIds()
    {
        var s = new List<string>();
        foreach (var r in LoadIndex()["meetings"] as JsonArray ?? []) if (JsonUtil.S(r?["id"]) is { } i) s.Add(i);
        if (Directory.Exists(Paths.Meetings))
            foreach (var d in Directory.EnumerateFileSystemEntries(Paths.Meetings).Select(x => Path.GetFileName(x)).Where(n => !n.Starts(".")).OrderBy(x => x, StringComparer.Ordinal)) s.Add(d);
        foreach (var u in AllRecords()) s.Add(Path.GetFileNameWithoutExtension(u));
        return s.Distinct().ToList();
    }

    /// A meeting was renamed (its id changed): every place memory uses the old id gets the new one — every memory file (.md under
    /// memory/: MEETINGS' "## id" and "- 紀錄：", OPEN's last column and "<!-- id -->", PEOPLE's "- 出席：", mentions in THREADS / NAMES /
    /// STATE…), index.json's id and path, Hearby's own two books (.hearby-written.json, .hearby-names.json). Changed memory files are
    /// backed up to .bak-<date> first. Returns the files that changed
    internal static List<string> RenameMeeting(string old, string @new, Backups backups)
    {
        var changed = new List<string>();
        if (old == @new || old.Length == 0) return changed;
        var longer = KnownIds().Where(x => x != @new && x.Length > old.Length && x.Starts(old)).ToList();
        foreach (var f in Directory.EnumerateFiles(Paths.Memory).Select(x => Path.GetFileName(x)).Where(n => n.Ends(".md") && !n.Starts(".")).OrderBy(x => x, StringComparer.Ordinal).ToList())
        {
            var u = Url(f);
            string t; try { t = Clean.ReadUtf8Strict(u); } catch { continue; }
            var r = ReplacingId(t, old, @new, longer);
            if (r == t) continue;
            backups.Before(u);
            var tmp = u + ".tmp";
            File.WriteAllText(tmp, r, new UTF8Encoding(false));
            File.Move(tmp, u, overwrite: true);
            changed.Add(f);
        }
        var idx = LoadIndex();
        if (idx["meetings"] is JsonArray rows && rows.FirstOrDefault(x => JsonUtil.S(x?["id"]) == old) is JsonObject row)
        {
            row["id"] = @new;
            row["path"] = $"會議/{@new}/{@new}.md";
            backups.Before(Url("index.json"));
            SaveJson(idx, Url("index.json"));
            changed.Add("index.json");
        }
        var book = LoadBook();
        if (book["meetings"] is JsonObject ms && ms[old] is JsonObject e)
        {
            var moved = new JsonObject();
            foreach (var kv in e)
                moved[kv.Key] = kv.Value is JsonArray a
                    ? new JsonArray(a.Select(x => (JsonNode?)(JsonUtil.S(x) is { } s ? JsonValue.Create(ReplacingId(s, old, @new, longer)) : x?.DeepClone())).ToArray())
                    : kv.Value?.DeepClone();
            ms.Remove(old);
            ms[@new] = moved;
            SaveJson(book, Url(WrittenBook));
        }
        NameLedger.RenameMeeting(old, @new);
        return changed;
    }

    /// The old id in a text becomes the new one: whole ids only — followed by "-<digit>" (another meeting in the same minute), or the
    /// start of another meeting's longer id, stays
    internal static string ReplacingId(string text, string old, string @new, List<string> longer)
    {
        if (old.Length == 0 || !text.Has(old)) return text;
        var sb = new StringBuilder();
        int i = 0;
        for (int r; (r = text.Find(old, i)) >= 0; i = r + old.Length)
        {
            sb.Append(text, i, r - i);
            int after = r + old.Length;
            bool numbered = after + 1 < text.Length && text[after] == '-' && text[after + 1] >= '0' && text[after + 1] <= '9';
            bool other = longer.Any(l => string.CompareOrdinal(text, r, l, 0, l.Length) == 0 && r + l.Length <= text.Length);
            sb.Append(numbered || other ? old : @new);
        }
        sb.Append(text, i, text.Length - i);
        return sb.ToString();
    }

    // ── the lines one meeting should have (all computed from the record md) ──

    internal sealed class Entry
    {
        public List<string> Meetings = [];
        public List<Todo> Todos = [];
        /// index.json people (the record's attendees as written)
        public List<string> People = [];
        /// Names PEOPLE.md records attendance under
        public List<string> Names = [];
        public string Title = "", Date = "";
        public double Seconds;
    }

    internal sealed class Lines
    {
        public List<string> Meetings = [], Open = [], Names = [];
    }

    internal static Entry EntryOf(string md, string id)
    {
        var rec = RecordMD.Parse(md);
        var parts = rec.Parts;
        var e = new Entry { People = rec.People, Names = NamesOf(rec.People), Todos = rec.Todos, Title = parts.Custom, Date = parts.Date, Seconds = ParseDur(parts.Dur) };
        if (parts.Custom.Length > 0) e.Meetings.Add($"- 標題：{parts.Custom}");
        e.Meetings.Add($"- 日期：{parts.Date}　時長：{parts.Dur}");
        if (rec.People.Count > 0) e.Meetings.Add($"- 與會：{string.Join("、", rec.People)}");
        var summary = rec.SummaryText;
        if (summary.Length > 0 && !summary.Starts("（")) e.Meetings.Add($"- 摘要：{summary}");
        foreach (var d in rec.Section("決議") ?? []) if (d != "無明確決議") e.Meetings.Add($"- 決議：{StampRe.Replace(d, "")}");
        e.Meetings.Add($"- 紀錄：會議/{id}/{id}.md");
        return e;
    }

    /// 「王小明（Ming）」→「王小明」; empty ones dropped, duplicates once
    internal static List<string> NamesOf(List<string> people)
    {
        var outList = new List<string>();
        foreach (var p in people)
        {
            var n = Str.TrimWS(Regex.Replace(p, "（[^）]*）", ""));
            if (n.Length > 0 && !outList.Contains(n)) outList.Add(n);
        }
        return outList;
    }

    /// OPEN.md lines: every unfinished to-do; a finished one only when it was written before as unfinished (carries the tick over)
    internal static List<string> OpenLines(Entry e, string id, List<string> before)
    {
        var had = new HashSet<string>(before.Select(TodoItem).OfType<string>());
        return e.Todos.Where(t => !t.Done || had.Contains(t.Item)).Select(t => $"- [{(t.Done ? "x" : " ")}] {t.Item}｜{t.Owner}｜{t.Due}｜{id}").ToList();
    }

    /// 「- [ ] 事項｜負責人｜期限｜會議id」→「事項」; not a to-do line = null
    internal static string? TodoItem(string line)
    {
        foreach (var p in new[] { "- [ ] ", "- [x] ", "- [X] " }) if (line.Starts(p)) return Str.TrimWS(line[p.Length..].Split('｜')[0]);
        return null;
    }

    /// Last column of a to-do line (the meeting id)
    internal static string TodoMeeting(string line) => Str.TrimWS(line.Split('｜')[^1]);

    /// The slot a MEETINGS.md line takes: 標題／日期／與會／摘要／紀錄 one each per meeting; 決議 and other lines by the whole line
    internal static string MeetingKey(string line)
    {
        foreach (var k in new[] { "- 標題：", "- 日期：", "- 與會：", "- 摘要：", "- 紀錄：" }) if (line.Starts(k)) return k;
        return line;
    }

    // ── how each file is updated ──

    /// The 「## id」 block in MEETINGS.md: (heading line, end of content); trailing blank lines are not content
    internal static (int Head, int End)? BlockRange(List<string> lines, string id)
    {
        int h = lines.FindIndex(l => Str.TrimWS(l) == "## " + id);
        if (h < 0) return null;
        int e = lines.FindIndex(h + 1, l => l.Starts("## ") || l.Starts("# "));
        if (e < 0) e = lines.Count;
        while (e > h + 1 && Str.TrimWS(lines[e - 1]).Length == 0) e--;
        return (h, e);
    }

    /// This meeting's MEETINGS.md block: Hearby's lines become the new version; a slot the user rewrote or removed
    /// (標題, 與會, 摘要…; 決議 by the whole line) does not get the new version
    internal static Merged MergeMeetings(string text, string id, List<string> fresh, HashSet<string> owned, List<string> written)
    {
        var lines = Str.Lines(text).ToList();
        // No block for this meeting yet (first write, or the whole block was removed): append
        if (BlockRange(lines, id) is not var (h, e)) return new Merged(text + $"\n## {id}\n" + string.Join("\n", fresh) + "\n");
        var body = Enumerable.Range(h + 1, e - h - 1).ToList();
        var slots = body.Where(i => owned.Contains(lines[i])).ToList();
        var users = body.Where(i => !owned.Contains(lines[i])).ToList();
        var present = new HashSet<string>(body.Select(i => lines[i]));
        var ownedKeys = new HashSet<string>(slots.Select(i => MeetingKey(lines[i])));
        var drop = new HashSet<string>(users.Select(i => MeetingKey(lines[i])));
        foreach (var w in written) if (!present.Contains(w) && !ownedKeys.Contains(MeetingKey(w))) drop.Add(MeetingKey(w));
        int kept = users.Count(i => Str.TrimWS(lines[i]).Length > 0);
        var r = Refill(lines, slots, fresh.Where(f => !drop.Contains(MeetingKey(f))).ToList(), e);
        return new Merged(string.Join("\n", r.Lines), kept, r.Replaced);
    }

    /// This meeting's to-dos in OPEN.md (lines ending in its id): Hearby's, unticked and unchanged, become the new version;
    /// an item the user ticked, rewrote or deleted does not get the new version
    internal static Merged MergeOpen(string text, string id, List<string> fresh, HashSet<string> owned, List<string> written)
    {
        var lines = Str.Lines(text).ToList();
        var marker = $"<!-- {id} -->";
        var mine = Enumerable.Range(0, lines.Count).Where(i => TodoItem(lines[i]) != null && TodoMeeting(lines[i]) == id).ToList();
        int markerAt = lines.FindIndex(l => Str.TrimWS(l) == marker);
        // No trace of this meeting in OPEN (first write, or the file started over): append
        if (markerAt < 0 && mine.Count == 0) return new Merged(fresh.Count == 0 ? text : text + $"\n{marker}\n" + string.Join("\n", fresh) + "\n");
        var slots = Enumerable.Range(0, lines.Count).Where(i => owned.Contains(lines[i])).ToList();
        var users = mine.Where(i => !owned.Contains(lines[i])).ToList();
        var present = new HashSet<string>(lines);
        var ownedItems = new HashSet<string>(slots.Select(i => TodoItem(lines[i])).OfType<string>());
        var drop = new HashSet<string>(users.Select(i => TodoItem(lines[i])).OfType<string>());
        foreach (var w in written) if (!present.Contains(w) && TodoItem(w) is { } it && !ownedItems.Contains(it)) drop.Add(it);
        // Nothing to replace: new ones go at the end of this meeting's marker block (no marker = after its last line)
        int fallback = lines.Count > 0 && lines[^1] == "" ? lines.Count - 1 : lines.Count;
        if (markerAt >= 0)
        {
            int f = lines.FindIndex(markerAt + 1, l => { var t = Str.TrimWS(l); return t.Length == 0 || t.Starts("<!--") || t.Starts("#"); });
            fallback = f >= 0 ? f : lines.Count;
        }
        else if (mine.Count > 0) fallback = mine[^1] + 1;
        var r = Refill(lines, slots, fresh.Where(x => !drop.Contains(TodoItem(x) ?? "")).ToList(), fallback);
        return new Merged(string.Join("\n", r.Lines), users.Count, r.Replaced);
    }

    /// The 「## name」 section in PEOPLE.md: (heading line, next heading)
    internal static (int Head, int End)? Section(List<string> lines, string name)
    {
        int h = lines.FindIndex(l => Str.TrimWS(l) == "## " + name);
        if (h < 0) return null;
        int e = lines.FindIndex(h + 1, l => l.Starts("## ") || l.Starts("# "));
        return (h, e < 0 ? lines.Count : e);
    }

    /// PEOPLE.md: this meeting's attendance (- 出席：id) follows the record's attendees. A name no longer listed loses that line
    /// (and its heading, when only the heading is left); a new name goes at the end of its section, or a new section at the end.
    /// Attendance Hearby wrote and the user later removed is not put back
    internal static Merged MergePeople(string text, string id, List<string> names, List<string> owned, List<string> written)
    {
        var attend = $"- 出席：{id}";
        var lines = Str.Lines(text).ToList();
        bool hadTrace = lines.Contains(attend);
        bool touched = false;
        foreach (var n in owned)
        {
            if (names.Contains(n) || Section(lines, n) is not var (h, e)) continue;
            int a = lines.FindIndex(h + 1, e - h - 1, l => l == attend);
            if (a < 0) continue;
            lines.RemoveAt(a);
            touched = true;
            if (lines.Skip(h + 1).Take(e - 1 - (h + 1)).All(l => Str.TrimWS(l).Length == 0))
            {
                int from = h > 0 && Str.TrimWS(lines[h - 1]).Length == 0 ? h - 1 : h;
                lines.RemoveRange(from, h - from + 1);
            }
        }
        foreach (var n in names)
        {
            if (Section(lines, n) is var (h, e))
            {
                if (lines.Skip(h + 1).Take(e - h - 1).Contains(attend) || (hadTrace && written.Contains(n))) continue;
                int at = e;
                while (at > h + 1 && Str.TrimWS(lines[at - 1]).Length == 0) at--;
                lines.Insert(at, attend);
            }
            else if (!(hadTrace && written.Contains(n)))
                lines = Str.Lines(string.Join("\n", lines) + $"\n## {n}\n{attend}\n").ToList();
        }
        return new Merged(string.Join("\n", lines), 0, touched);
    }

    /// One file after the update: Kept = the user's own lines in this meeting; Touched = an existing line was replaced or removed (back up first)
    internal sealed record Merged(string Text, int Kept = 0, bool Touched = false);

    /// Slots are the positions of Hearby's lines (file order). Those still in the new version stay where they are; vacated slots take
    /// the new lines in order, the rest go right after the line that precedes them in the new version; extra slots are removed.
    /// No slots at all = everything goes in at fallback. Other lines are not touched
    internal static (List<string> Lines, bool Replaced) Refill(List<string> lines, List<int> slots, List<string> fresh, int fallback)
    {
        if (slots.Count == 0)
        {
            var o = new List<string>(lines);
            o.InsertRange(fallback, fresh);
            return (o, false);
        }
        var used = new bool[fresh.Count];
        var at = new Dictionary<int, int>();
        foreach (var s in slots)
            for (int f = 0; f < fresh.Count; f++)
                if (!used[f] && fresh[f] == lines[s]) { at[s] = f; used[f] = true; break; }
        bool replaced = slots.Any(s => !at.ContainsKey(s));
        var waiting = Enumerable.Range(0, fresh.Count).Where(f => !used[f]).ToList();
        foreach (var s in slots)
        {
            if (at.ContainsKey(s) || waiting.Count == 0) continue;
            at[s] = waiting[0];
            waiting.RemoveAt(0);
        }
        var slotSet = new HashSet<int>(slots);
        var outList = new List<(string Line, int? F)>();
        int firstSlot = 0;
        for (int i = 0; i < lines.Count; i++)
        {
            if (i == slots[0]) firstSlot = outList.Count;
            if (!slotSet.Contains(i)) outList.Add((lines[i], null));
            else if (at.TryGetValue(i, out var f)) outList.Add((fresh[f], f));
        }
        foreach (var f in waiting)
        {
            int p = -1, n = -1;
            for (int k = 0; k < outList.Count; k++)
            {
                if (outList[k].F is not int x) continue;
                if (x < f && (p < 0 || x > outList[p].F!.Value)) p = k;
                if (x > f && (n < 0 || x < outList[n].F!.Value)) n = k;
            }
            if (p >= 0) outList.Insert(p + 1, (fresh[f], f));
            else if (n >= 0) outList.Insert(n, (fresh[f], f));
            else outList.Insert(firstSlot++, (fresh[f], f));
        }
        return (outList.Select(x => x.Line).ToList(), replaced);
    }

    // ── read / write ──

    /// Read a memory file (newlines normalised); there but not UTF-8 = null, left alone this time (writing it back as empty would wipe it)
    static string? ReadText(string path)
    {
        if (!File.Exists(path)) return "";
        try { return Str.NormalizeNewlines(Clean.ReadUtf8Strict(path)); }
        catch
        {
            HearbyLog.Write($"memory: {Path.GetFileName(path)} 讀不到（不是 UTF-8？），這次不動它");
            return null;
        }
    }

    /// Write a memory file back: unchanged = not written; an existing line replaced or removed = back up, then replace the file;
    /// only lines added = no backup (added at the end = appended)
    static bool Save(string next, string old, string path, bool touched, Backups backups)
    {
        if (next == old) return false;
        if (touched) backups.Before(path);
        else if (next.Starts(old))
        {
            AppendText(next[old.Length..], path);
            return true;
        }
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, next, new UTF8Encoding(false));
        File.Move(tmp, path, overwrite: true);
        return true;
    }

    /// Versions of this record kept before it was overwritten (<name>_舊版N.md, <name>.md.bak-*), oldest first (by modification time)
    internal static List<string> OlderVersions(string mdPath)
    {
        var dir = Path.GetDirectoryName(mdPath)!;
        var b = Path.GetFileNameWithoutExtension(mdPath);
        var olds = new List<(string Name, DateTime Date)>();
        try
        {
            foreach (var f in Directory.EnumerateFiles(dir))
            {
                var n = Path.GetFileName(f);
                if ((n.Starts(b + "_舊版") && n.Ends(".md")) || n.Starts(b + ".md.bak")) olds.Add((n, File.GetLastWriteTimeUtc(f)));
            }
        }
        catch { return []; }
        var outList = new List<string>();
        foreach (var (n, _) in olds.OrderBy(x => x.Date).ThenBy(x => x.Name, StringComparer.Ordinal))
        {
            try { outList.Add(Str.NormalizeNewlines(Clean.ReadUtf8Strict(Path.Combine(dir, n)))); } catch { }
        }
        return outList;
    }

    static JsonObject LoadBook()
    {
        try { if (JsonNode.Parse(File.ReadAllText(Url(WrittenBook), Encoding.UTF8)) is JsonObject o) return o; } catch { }
        return new JsonObject { ["schemaVersion"] = 1, ["meetings"] = new JsonObject() };
    }

    internal static void SaveJson(JsonObject obj, string path)
    {
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, JsonUtil.SortedPretty(obj), new UTF8Encoding(false));
        File.Move(tmp, path, overwrite: true);
    }

    static JsonArray ToArray(List<string> xs) => new(xs.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray());
    static List<string>? StrListOrNull(JsonNode? n) => n is JsonArray a ? a.Select(JsonUtil.S).OfType<string>().ToList() : null;
    static List<string> StrList(JsonNode? n) => StrListOrNull(n) ?? [];

    /// Backups: at most one per file per action — <name>.bak-<date>, then -2, -3… when taken (never overwritten, never deleted)
    internal sealed class Backups
    {
        public readonly List<string> Made = [];
        readonly HashSet<string> seen = [];
        public string Day { get; } = HearbyTime.Local(DateTimeOffset.Now).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

        public void Before(string path)
        {
            if (!seen.Add(path) || !File.Exists(path)) return;
            var bak = $"{path}.bak-{Day}";
            for (int k = 2; File.Exists(bak); k++) bak = $"{path}.bak-{Day}-{k}";
            File.Copy(path, bak);
            Made.Add(bak);
        }
    }

    // ── other ──

    /// Unfinished items from past meetings (offered before the next recording)
    public static List<string> OpenItems(int limit = 8)
    {
        string s; try { s = RecordMD.Read(Url("OPEN.md")); } catch { return []; }
        return Str.Lines(s).Where(l => l.Starts("- [ ] ")).TakeLast(limit).Select(l =>
        {
            var cols = l[6..].Split('｜');
            return cols[0] + (cols.Length > 1 && cols[1].Length > 0 ? $"（{cols[1]}）" : "");
        }).ToList();
    }

    static void AppendText(string t, string path)
    {
        if (File.Exists(path)) File.AppendAllText(path, t, new UTF8Encoding(false));
        else File.WriteAllText(path, t, new UTF8Encoding(false));
    }

    internal static double ParseDur(string s)
    {
        double secs = 0;
        var h = Regex.Match(s, @"(\d+)小時"); if (h.Success) secs += double.Parse(Str.DigitsOnly(h.Value), CultureInfo.InvariantCulture) * 3600;
        var m = Regex.Match(s, @"(\d+)分"); if (m.Success) secs += double.Parse(Str.DigitsOnly(m.Value), CultureInfo.InvariantCulture) * 60;
        var x = Regex.Match(s, @"(\d+)秒"); if (x.Success) secs += double.Parse(Str.DigitsOnly(x.Value), CultureInfo.InvariantCulture);
        return secs;
    }
}

/// Second destination (config mirrorDir): every md write also goes there
public static class Mirror
{
    public static void Copy(string md)
    {
        if (Paths.Mirror is not { } m) return;
        Directory.CreateDirectory(m);
        File.Copy(md, Path.Combine(m, Path.GetFileName(md)), overwrite: true);
    }

    /// A meeting was renamed: this meeting's copies in the mirror folder (<old id>.md, translations <old id>.en.md…) follow.
    /// A file already there under the new name = not overwritten, the old one stays (listed in skipped). No mirror folder = nothing
    public static (List<string> Moved, List<string> Skipped) Rename(string old, string @new)
    {
        var moved = new List<string>();
        var skipped = new List<string>();
        if (Paths.Mirror is not { } m || old == @new || !Directory.Exists(m)) return (moved, skipped);
        foreach (var n in Directory.EnumerateFiles(m).Select(x => Path.GetFileName(x)).Where(n => n.Starts(old + ".")).OrderBy(x => x, StringComparer.Ordinal).ToList())
        {
            var dst = Path.Combine(m, @new + n[old.Length..]);
            if (File.Exists(dst) && !string.Equals(Path.GetFileName(dst), n, StringComparison.OrdinalIgnoreCase)) { skipped.Add(n); continue; }
            try { MeetingRename.Move(Path.Combine(m, n), dst, directory: false); moved.Add(dst); } catch { skipped.Add(n); }
        }
        return (moved, skipped);
    }
}

/// Re-polish the whole record (no re-recording, no re-transcribing; only the model runs again)
public static class Repolish
{
    public static (string Md, string Summary) Whole(string mdPath, string corrections, IProvider provider, Action<string>? onStage = null)
    {
        if (provider.Id == "none") throw new HearbyError("這個動作要用 AI 整理，但現在的整理方式是「只要逐字稿」。先到設定選「交給我的 Claude 整理」或本機模型。");
        using var busy = MeetingBusy.Scope(Path.GetDirectoryName(mdPath)!);
        onStage?.Invoke("讀取原紀錄…");
        string oldMD; try { oldMD = RecordMD.Read(mdPath); } catch { throw new HearbyError($"讀不到原紀錄：{Path.GetFileName(mdPath)}"); }
        var transcript = RecordMD.Transcript(oldMD) ?? throw new HearbyError("原紀錄裡找不到逐字稿段，無法重新整理");
        var rec = RecordMD.Parse(oldMD);
        var parts = rec.Parts;
        var dateStr = parts.Date.Length == 0 ? rec.Title : parts.Date;
        var lines = Str.Lines(oldMD);
        var audioLine = lines.FirstOrDefault(l => l.Starts("> 音檔：")) is { } al ? al["> 音檔：".Length..] : "（沿用原音檔）";
        var links = rec.Section("參考連結") ?? [];
        var warnings = lines.Where(l => l.Starts("> ⚠ ")).Select(l => l["> ⚠ ".Length..]).ToList();
        var attendees = string.Join("、", RealAttendees(rec.People));
        if (attendees.Length == 0) attendees = rec.DeclaredAttendees;

        var baseline = new StringBuilder();
        var baselineNames = RecordSceneExt.FromMdTitle(oldMD) switch
        {
            RecordScene.Note => new[] { "內容", "待辦" },
            RecordScene.Interview => new[] { "內容", "引言", "待辦" },
            _ => new[] { "重點", "決議", "開放問題", "待辦" },
        };
        foreach (var name in baselineNames)
        {
            if (rec.Section(name) is not { Count: > 0 } ls) continue;
            baseline.Append($"## {name}\n" + string.Join("\n", ls) + "\n\n");
        }
        var history = (rec.Section("修正紀錄") ?? []).Select(l => { var t = Str.TrimWS(l); if (t.Starts("-")) t = Str.TrimWS(t[1..]); return t; }).Where(t => t.Length > 0).ToList();
        history.AddRange(lines.Where(l => l.Starts("> 已依")).Select(l => l[2..]));

        onStage?.Invoke("AI 重新整理中…");
        var (fixedTranscript, semantic) = PolishGuards.ApplyMechanicalCorrections(transcript, corrections);
        var (fixedAttendees, _) = PolishGuards.ApplyMechanicalCorrections(attendees, corrections);
        MeetingScenario? scenario = null; int? onsiteCount = null;
        if (lines.FirstOrDefault(l => l.Starts("> 本場情境：")) is { } scLine)
        {
            scenario = MeetingScenarioExt.All.Cast<MeetingScenario?>().FirstOrDefault(s => scLine.Has(s!.Value.DisplayName()));
            var mc = Regex.Match(scLine, @"現場人數 (\d+)");
            if (mc.Success) onsiteCount = int.Parse(Str.DigitsOnly(mc.Value), CultureInfo.InvariantCulture);
        }
        var brief = (rec.Section("會前重點對照") ?? []).Select(line =>
        {
            var t = Str.TrimWS(line);
            if (t.Starts("-")) t = Str.TrimWS(t[1..]);
            if (t.Length == 0 || t.All(c => "-—─".Contains(c))) return null;
            bool found = false;
            foreach (var sep in new[] { " → ", "→", "｜" })
            {
                if (found) break;
                int r = t.Find(sep);
                if (r >= 0) { t = t[..r]; found = true; }
            }
            if (!found) return null;
            t = Str.TrimWS(t);
            return t.Length == 0 ? null : t;
        }).Where(x => x != null).Select(x => x!).ToList();
        bool onsite = scenario == null && !fixedTranscript.Has("[遠端]");
        var displayTranscript = Clean.NormalizePunct(onsite ? fixedTranscript.Rep("[我方]", "[現場]") : fixedTranscript);
        var input = new Polish.Input(Transcriber.MergedForLLM(displayTranscript), parts.Custom, fixedAttendees, dateStr, parts.Dur, warnings, audioLine)
        {
            Links = links, Corrections = semantic.Length == 0 ? null : semantic, Onsite = onsite, Scenario = scenario, OnsiteCount = onsiteCount, Brief = brief,
            PauseNote = lines.FirstOrDefault(l => l.Starts("> ⏸ ")) is { } pl ? pl["> ⏸ ".Length..] : null,
            Baseline = Str.TrimWSNL(baseline.ToString()), History = history, Scene = RecordSceneExt.FromMdTitle(oldMD),
            Context = PolishContext.Load(Path.GetFileNameWithoutExtension(mdPath)),
        };
        var (md, summary, err) = Polish.BuildNotes(input, provider);
        if (err != null) throw new HearbyError(err);
        md = RestoreTodoChecks(md, rec.Todos);
        var corrLine = Str.TrimWSNL(corrections).Rep("\n", "；");
        if (corrLine.Length > 0)
        {
            var today = DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            var block = "## 修正紀錄\n" + string.Join("\n", history.Append($"{today}：{corrLine}").Select(h => $"- {h}")) + "\n\n";
            int tr = md.Find("## 逐字稿");
            md = tr >= 0 ? md.Insert(tr, block) : md + "\n\n" + block;
        }
        md = Clean.ToTraditional(md, input.Context?.Names ?? []);   // roster names are not converted (涂 is not 塗)
        summary = Clean.ToTraditional(summary, input.Context?.Names ?? []);
        onStage?.Invoke("存檔中…");
        RecordMD.BackupIfExists(mdPath);
        RecordMD.Write(mdPath, md);
        try { Mirror.Copy(mdPath); } catch { }
        NameLedger.LearnCorrections(corrections, mdPath);   // 「A」應為「B」 that are names go into the name ledger
        // Memory follows the new version: Hearby's untouched lines are replaced, the user's are not
        try { MemoryStore.Sync(mdPath); } catch { }
        return (mdPath, summary);
    }

    /// Names from the old 「## 與會者」 that are real names (placeholder labels like 現場A are not a list)
    public static List<string> RealAttendees(List<string> people)
    {
        var placeholders = new[] { "現場", "遠端", "電話端", "我方", "受訪者", "訪談者", "發言者", "Speaker", "Remote", "Interviewee", "Interviewer" };
        return people.Select(n =>
        {
            var t = n;
            foreach (var m in new[] { "我方", "遠端", "現場", "電話端", "推測" }) t = t.Rep($"（{m}）", "").Rep($"({m})", "");
            return Str.TrimWS(t);
        }).Where(t =>
        {
            if (t.Length == 0) return false;
            foreach (var p in placeholders)
            {
                if (!t.Starts(p)) continue;
                var rest = Str.TrimWS(Str.DropFirst(t, Str.Count(p)));
                if (rest.Length == 0 || (Str.Count(rest) <= 2 && Str.Chars(rest).All(Str.IsLetterOrNumber))) return false;
            }
            return true;
        }).ToList();
    }

    internal static string RestoreTodoChecks(string md, List<Todo> oldTodos)
    {
        var doneItems = new HashSet<string>(oldTodos.Where(t => t.Done).Select(t => Str.TrimWS(t.Item)));
        if (doneItems.Count == 0) return md;
        return string.Join("\n", Str.Lines(md).Select(line =>
        {
            if (!line.Starts("- [ ] ")) return line;
            var body = line[6..];
            var item = Str.TrimWS(body.Split('｜')[0]);
            return doneItems.Contains(item) ? "- [x] " + body : line;
        }));
    }

    const string NeedsAI = "這個動作要用 AI 整理，但現在的整理方式是「只要逐字稿」。先到設定選「交給我的 Claude 整理」或本機模型，或在命令列加 --provider claude。";

    /// Translate the record (not the transcript) into another language, saved next to it as <name>.<lang>.md.
    /// Guards: section names and separators stay exactly as in the original (parsing relies on the Chinese names).
    public static string Translate(string mdPath, string language, IProvider provider)
    {
        if (provider.Id == "none") throw new HearbyError(NeedsAI);
        using var busy = MeetingBusy.Scope(Path.GetDirectoryName(mdPath)!);
        string md; try { md = RecordMD.Read(mdPath); } catch { throw new HearbyError("讀不到原紀錄"); }
        var record = md.Split("\n---\n\n## 逐字稿")[0];
        var (o, err) = provider.Complete(Prompt.Translate(language), record);
        var t = Str.TrimWSNL(o ?? "");
        if (t.Length == 0) throw new HearbyError(err ?? "模型沒有回應");
        var srcLines = record.Split('\n');
        var outLines = t.Split('\n').ToList();
        int firstHeading = Array.FindIndex(srcLines, l => l.Starts("## "));
        if (firstHeading < 0) firstHeading = srcLines.Length;
        string RestoredTitle(string src, string outLine)
        {
            var scene = RecordSceneExt.FromMdTitle(src);
            var tail = outLine.Starts("# ") ? outLine[2..] : outLine;
            foreach (var w in new[] { DocLabels.T(scene.MdTitle(), language), scene.MdTitle() }.Concat(RecordSceneExt.LegacyMdTitles))
                if (tail.Starts(w)) tail = Str.TrimWS(Str.DropFirst(tail, Str.Count(w)));
            return "# " + scene.MdTitle() + (tail.Length == 0 ? "" : " " + tail);
        }
        if (outLines.Count == srcLines.Length)
        {
            for (int i = 0; i < srcLines.Length; i++)
            {
                var l = srcLines[i];
                if (l.Starts("# ")) outLines[i] = RestoredTitle(l, outLines[i]);
                else if (l.Starts("## ") || l == "---") outLines[i] = l;
                else if (i < firstHeading && l.Starts("> 音檔")) outLines[i] = l;
                else if (i < firstHeading && l.Starts("> ") && l.Has("時長"))
                {
                    var src = l.Split('｜'); var dst = outLines[i].Split('｜');
                    outLines[i] = src.Length > 2 && dst.Length > 2 ? string.Join("｜", src.Take(2).Concat(dst.Skip(2))) : l;
                }
            }
        }
        else
        {
            var heads = srcLines.Where(l => l.Starts("## ")).ToList();
            int k = 0;
            outLines = outLines.Select(l => l.Starts("## ") && k < heads.Count ? heads[k++] : l).ToList();
            int ti = outLines.FindIndex(l => l.Starts("# "));
            var st = srcLines.FirstOrDefault(l => l.Starts("# "));
            if (ti >= 0 && st != null) outLines[ti] = RestoredTitle(st, outLines[ti]);
            else if (st != null) outLines.Insert(0, st);
        }
        t = string.Join("\n", outLines);
        var dest = Path.Combine(Path.GetDirectoryName(mdPath)!, Path.GetFileNameWithoutExtension(mdPath) + "." + language + ".md");
        var body = t + $"\n\n---\n\n## 逐字稿\n（原文逐字稿見 {Path.GetFileName(mdPath)}）\n";
        RecordMD.BackupIfExists(dest);
        RecordMD.Write(dest, body);
        try { Mirror.Copy(dest); } catch { }
        HearbyLog.Write($"translate {Path.GetFileNameWithoutExtension(mdPath)} → {language}");
        return dest;
    }

    /// Change one section only: returns the edited section text (the caller shows it side by side; saved only on confirm)
    public static string Section(string mdPath, string sectionName, string instruction, IProvider provider)
    {
        if (provider.Id == "none") throw new HearbyError(NeedsAI);
        string md; try { md = RecordMD.Read(mdPath); } catch { throw new HearbyError("讀不到原紀錄"); }
        var rec = RecordMD.Parse(md);
        var original = sectionName.Has("待辦")
            ? string.Join("\n", rec.Todos.Select(t => $"- [{(t.Done ? "x" : " ")}] {t.Item}｜{t.Owner}｜{t.Due}"))
            : string.Join("\n", (rec.Section(sectionName) ?? []).Select(l => "- " + l));
        var transcript = RecordMD.Transcript(md) ?? "";
        var user = $"## {sectionName}（原文）\n{original}\n\n逐字稿：\n{Transcriber.MergedForLLM(transcript)}";
        var (o, err) = provider.Complete(Prompt.SectionEdit(sectionName, instruction), user);
        if (o == null) throw new HearbyError(err ?? "模型沒有回應");
        return Clean.ToTraditional(Str.TrimWSNL(o));
    }

    /// Replace one section with new text and save (backup first)
    public static void ReplaceSection(string mdPath, string sectionName, string newBody)
    {
        var lines = Str.Lines(RecordMD.Read(mdPath)).ToList();
        int start = lines.FindIndex(l => l.Starts("## ") && l.Has(sectionName));
        if (start < 0) throw new HearbyError($"找不到「{sectionName}」這一節");
        int end = lines.Count;
        for (int i = start + 1; i < lines.Count; i++) if (lines[i].Starts("## ") || lines[i] == "---") { end = i; break; }
        lines.RemoveRange(start + 1, end - start - 1);
        lines.InsertRange(start + 1, Str.Lines(newBody).Append(""));
        RecordMD.BackupIfExists(mdPath);
        RecordMD.Write(mdPath, string.Join("\n", lines));
        try { Mirror.Copy(mdPath); } catch { }
        try { MemoryStore.Sync(mdPath); } catch { }
    }
}
