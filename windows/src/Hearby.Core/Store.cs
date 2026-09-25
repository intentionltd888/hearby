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

/// Memory — ~/Hearby/memory/ five files + index.json (mechanical: plain appends right after the meeting, no model).
/// Three rules: never rewrite lines the user changed (append only); write each meeting once (by id); only structured sections move in.
public static class MemoryStore
{
    public static readonly string[] Files = ["PEOPLE.md", "MEETINGS.md", "THREADS.md", "OPEN.md", "GLOSSARY.md"];
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

    /// Right after the meeting: MEETINGS gets a block, OPEN gets the to-dos, PEOPLE gets attendance, index.json a row. Same id → once.
    public static void AppendMeeting(string mdPath)
    {
        if (!ConfigStore.Shared.Current.MemoryEnabled) return;
        Ensure();
        string md; try { md = RecordMD.Read(mdPath); } catch { return; }
        var rec = RecordMD.Parse(md);
        var id = Path.GetFileNameWithoutExtension(mdPath);
        var idx = LoadIndex();
        var meetings = idx["meetings"] as JsonArray ?? [];
        if (meetings.Any(m => (m as JsonObject)?["id"] is JsonValue v && v.TryGetValue<string>(out var sid) && sid == id))
        {
            HearbyLog.Write($"memory: {id} 已在索引，略過追加");
            return;
        }
        var parts = rec.Parts;
        var people = rec.People;
        var secs = ParseDur(parts.Dur);

        var block = new StringBuilder($"\n## {id}\n");
        if (parts.Custom.Length > 0) block.Append($"- 標題：{parts.Custom}\n");
        block.Append($"- 日期：{parts.Date}　時長：{parts.Dur}\n");
        if (people.Count > 0) block.Append($"- 與會：{string.Join("、", people)}\n");
        var summary = rec.SummaryText;
        if (summary.Length > 0 && !summary.Starts("（")) block.Append($"- 摘要：{summary}\n");
        foreach (var d in rec.Section("決議") ?? []) if (d != "無明確決議") block.Append($"- 決議：{StampRe.Replace(d, "")}\n");
        block.Append($"- 紀錄：會議/{id}/{id}.md\n");
        AppendText(block.ToString(), Url("MEETINGS.md"));

        var open = rec.Todos.Where(t => !t.Done).ToList();
        if (open.Count > 0)
        {
            var t = new StringBuilder($"\n<!-- {id} -->\n");
            foreach (var o in open) t.Append($"- [ ] {o.Item}｜{o.Owner}｜{o.Due}｜{id}\n");
            AppendText(t.ToString(), Url("OPEN.md"));
        }

        if (people.Count > 0)
        {
            var peopleUrl = Url("PEOPLE.md");
            string? existing = null;
            bool unreadable = false;
            if (File.Exists(peopleUrl)) { try { existing = Str.NormalizeNewlines(Clean.ReadUtf8Strict(peopleUrl)); } catch { unreadable = true; } }
            if (unreadable) HearbyLog.Write("memory: PEOPLE.md 讀不到（不是 UTF-8？），這次不動它");
            var s = existing ?? "";
            foreach (var p in people)
            {
                var name = Str.TrimWS(Regex.Replace(p, "（[^）]*）", ""));
                if (name.Length == 0) continue;
                int r = s.Find($"\n## {name}\n");
                if (r >= 0)
                {
                    int afterStart = r + $"\n## {name}\n".Length;
                    int next = s.Find("\n## ", afterStart);
                    int insertAt = next >= 0 ? next : s.Length;
                    s = s.Insert(insertAt, $"- 出席：{id}\n");
                }
                else s += $"\n## {name}\n- 出席：{id}\n";
            }
            if (!unreadable) File.WriteAllText(peopleUrl, s, new UTF8Encoding(false));
        }

        var row = new JsonObject
        {
            ["id"] = id, ["title"] = parts.Custom, ["date"] = parts.Date, ["seconds"] = secs,
            ["path"] = $"會議/{id}/{id}.md", ["people"] = new JsonArray(people.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray()),
        };
        meetings.Add(row);
        idx["meetings"] = meetings.DeepClone();
        var tmp = Url("index.json") + ".tmp";
        File.WriteAllText(tmp, JsonUtil.SortedPretty(idx), new UTF8Encoding(false));
        File.Move(tmp, Url("index.json"), overwrite: true);
        HearbyLog.Write($"memory: appended {id} people={people.Count} todos={open.Count}");
    }

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
}

/// Re-polish the whole record (no re-recording, no re-transcribing; only the model runs again)
public static class Repolish
{
    public static (string Md, string Summary) Whole(string mdPath, string corrections, IProvider provider, Action<string>? onStage = null)
    {
        if (provider.Id == "none") throw new HearbyError("這個動作要用 AI 整理，但現在的整理方式是「只要逐字稿」。先到設定選「交給我的 Claude 整理」或本機模型。");
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
        md = Clean.ToTraditional(md);
        summary = Clean.ToTraditional(summary);
        onStage?.Invoke("存檔中…");
        RecordMD.BackupIfExists(mdPath);
        RecordMD.Write(mdPath, md);
        try { Mirror.Copy(mdPath); } catch { }
        try { MemoryStore.AppendMeeting(mdPath); } catch { }
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
    }
}
