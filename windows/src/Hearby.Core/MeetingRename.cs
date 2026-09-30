// MeetingRename — rename a meeting. The list shows the folder name (<date_time_title>); a meeting's id is its main record's file name,
// and memory (index.json, MEETINGS, OPEN, PEOPLE…) finds the meeting by that id — so a new title changes all of them together
// (renaming only the folder breaks the paths):
//   1. folder: the "date_time_" prefix stays, the title part is the new one (same naming as after a meeting: Paths.SafeTitle; taken = -2, -3)
//   2. files in the folder that start with the old name (.md .m4a .pdf .docx .srt, _舊版N.md, .md.bak-*, translations .en.md…) follow
//   3. the record's header "> Hearby 錄音｜時長 …｜title" gets the new title; "> 音檔：" pointing at this meeting's file gets the new path
//   4. meta.json (the meeting's and the recording work folder's): title and outName — a later re-run still writes into this folder
//   5. memory on: the old id is replaced by the new one everywhere (changed files get .bak-<date> first), then one sync from the record
//   6. mirror folder (config mirrorDir): copies starting with the old id are renamed, then the new version is written once
// A meeting that is being processed, re-polished, translated or exported cannot be renamed (the result is written when it finishes).
// Mirrors Store/MeetingRename.swift.
using System.Text;
using System.Text.RegularExpressions;

namespace Hearby.Core;

public static class MeetingRename
{
    public sealed class Report
    {
        public string OldId = "";
        public string NewId = "";
        public string Dir = "";
        public string? MdPath;
        /// Files in the folder that were renamed (new names)
        public List<string> Renamed = [];
        /// Memory files that changed
        public List<string> Memory = [];
        /// Backups of memory files made before changing them
        public List<string> Backups = [];
        /// Files in the mirror folder that were renamed (or rewritten)
        public List<string> Mirror = [];
        /// What did not work out (a file that could not be renamed, memory that could not be written…); the folder itself was renamed
        public List<string> Warnings = [];
        /// Same title and nothing to complete: nothing was touched
        public bool Unchanged;
    }

    static readonly Regex StampPrefix = new(@"^\d{4}-\d{2}-\d{2}_\d{4}_", RegexOptions.CultureInvariant);

    /// The title on one line (newlines become spaces, spaces at both ends go) — the way the record header writes a title
    public static string OneLine(string title) =>
        Str.TrimWS(string.Join(" ", title.Split(['\n', '\r', '\u000B', '\u000C', '\u0085', (char)0x2028, (char)0x2029])));

    /// The folder name's "yyyy-MM-dd_HHmm_"; a folder in another format (put there by the user) has none
    public static string Prefix(string folderName)
    {
        var m = StampPrefix.Match(folderName);
        return m.Success ? m.Value : "";
    }

    /// The folder name after the new title (before checking whether it is taken)
    public static string FolderName(string current, string title, bool windowsRules = true) =>
        Prefix(current) + Paths.SafeTitle(OneLine(title), windowsRules);

    /// The folder's main record: <folder>.md, else the folder's only main record (when the folder was renamed and the files were not)
    public static string? MainRecord(string dir)
    {
        var named = Path.Combine(dir, Path.GetFileName(dir) + ".md");
        if (File.Exists(named)) return named;
        var mains = Directory.EnumerateFiles(dir).Where(MemoryStore.IsMainRecord).ToList();
        return mains.Count == 1 ? mains[0] : null;
    }

    /// What a file in the folder is called after the rename: starts with the old id (or the old folder name) followed by "." or "_"
    /// or nothing = that start becomes the new name; any other file = null (left alone)
    internal static string? Renamed(string name, string oldId, string folder, string newName)
    {
        foreach (var b in new[] { oldId, folder })
        {
            if (b.Length == 0 || !name.Starts(b)) continue;
            var rest = name[b.Length..];
            if (rest.Length == 0 || rest.Starts(".") || rest.Starts("_")) return newName + rest;
        }
        return null;
    }

    static bool SameIgnoringCase(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    /// Rename a meeting. dir = the meeting's folder (under 會議/); title = the new title
    public static Report Rename(string dir, string title, bool windowsRules = true)
    {
        var t = OneLine(title);
        if (t.Length == 0) throw new HearbyError("標題不能是空的");
        dir = Path.TrimEndingDirectorySeparator(dir);
        if (!Directory.Exists(dir)) throw new HearbyError($"找不到這一場的資料夾：{dir}");
        if (MeetingBusy.Contains(dir)) throw new HearbyError("這一場正在整理（或重新整理、翻譯、匯出），等它做完再改標題");
        var folder = Path.GetFileName(dir);
        var parent = Path.GetDirectoryName(dir)!;
        var md = MainRecord(dir);
        var oldId = md != null ? Path.GetFileNameWithoutExtension(md) : folder;
        string? oldText = null;
        if (md != null) { try { oldText = File.ReadAllText(md, Encoding.UTF8); } catch { } }
        var header = oldText != null ? RecordMD.Parse(oldText).Parts.Custom : null;

        // new folder name: taken by another meeting (another folder, or a meeting memory still knows) = -2, -3…; the same folder
        // differing only in letter case is not taken
        var taken = MemoryStore.KnownIds().Where(x => x != oldId && x != folder).ToHashSet(StringComparer.Ordinal);
        bool Free(string n) => SameIgnoringCase(n, folder) || n == oldId || (!taken.Contains(n) && !Directory.Exists(Path.Combine(parent, n)) && !File.Exists(Path.Combine(parent, n)));
        var baseName = FolderName(folder, t, windowsRules);
        var newName = baseName;
        for (int k = 2; !Free(newName); k++) newName = $"{baseName}-{k}";

        var report = new Report { OldId = oldId, NewId = newName, Dir = dir, MdPath = md };
        var shown = MeetingIndex.Split(folder).Title;
        if (newName == folder && oldId == folder && (header == null || header == t || (header.Length == 0 && shown == t)))
        {
            report.Unchanged = true;
            return report;
        }

        // 1. folder
        var newDir = dir;
        if (newName != folder)
        {
            newDir = Path.Combine(parent, newName);
            Move(dir, newDir, directory: true);
        }
        report.Dir = newDir;

        // 2. files in the folder that start with the old name
        foreach (var name in Directory.EnumerateFileSystemEntries(newDir).Select(x => Path.GetFileName(x)).OrderBy(x => x, StringComparer.Ordinal).ToList())
        {
            if (Renamed(name, oldId, folder, newName) is not { } to || to == name) continue;
            var dst = Path.Combine(newDir, to);
            if ((File.Exists(dst) || Directory.Exists(dst)) && !SameIgnoringCase(to, name)) { report.Warnings.Add($"{name} 沒改名：夾裡已經有 {to}"); continue; }
            try { Move(Path.Combine(newDir, name), dst, Directory.Exists(Path.Combine(newDir, name))); report.Renamed.Add(to); }
            catch (Exception e) { report.Warnings.Add($"{name} 沒改名：{e.Message}"); }
        }
        string? newMd = md == null ? null : Path.Combine(newDir, Renamed(Path.GetFileName(md), oldId, folder, newName) ?? Path.GetFileName(md));
        report.MdPath = newMd;

        // 3. record header: title, audio path
        if (newMd != null && oldText != null)
        {
            var oldDirs = new[] { dir, Path.Combine(parent, oldId) };
            var outText = RecordMD.Retitled(oldText, t, p => AudioPath(p, oldDirs, newDir, oldId, folder, newName));
            if (outText != oldText)
            {
                try { File.WriteAllText(newMd, outText, new UTF8Encoding(false)); }
                catch (Exception e) { report.Warnings.Add($"紀錄表頭沒改到：{e.Message}"); }
            }
        }

        // 4. meta.json: the meeting's and the recording work folder's
        if (MeetingMeta.Load(newDir) is { } m)
        {
            var workId = m.Id;
            m.Title = t; m.OutName = newName;
            MeetingMeta.Save(m, newDir);
            if (workId is { Length: > 0 })
            {
                var work = Path.Combine(Pipeline.RecordingsDir, workId);
                if (MeetingMeta.Load(work) is { } wm && (wm.OutName == null || wm.OutName == folder || wm.OutName == oldId))
                {
                    wm.Title = t; wm.OutName = newName;
                    MeetingMeta.Save(wm, work);
                }
            }
        }

        // 5. memory
        if (ConfigStore.Shared.Current.MemoryEnabled && Directory.Exists(Paths.Memory))
        {
            var backups = new MemoryStore.Backups();
            try
            {
                report.Memory = MemoryStore.RenameMeeting(oldId, newName, backups);
                if (newMd != null && MemoryStore.Sync(newMd, backups) is { } r)
                    foreach (var f in r.Changed) if (!report.Memory.Contains(f)) report.Memory.Add(f);
            }
            catch (Exception e) { report.Warnings.Add($"記憶沒改完：{e.Message}（可以再跑一次 --memory-rebuild）"); }
            report.Backups = [.. backups.Made];
        }

        // 6. mirror folder
        var (moved, skipped) = Mirror.Rename(oldId, newName);
        report.Mirror = moved;
        foreach (var n in skipped) report.Warnings.Add($"副本資料夾的 {n} 沒改名（那裡已經有新名字的檔）");
        if (newMd != null && Paths.Mirror is { } mirror)
        {
            try
            {
                Mirror.Copy(newMd);
                var c = Path.Combine(mirror, Path.GetFileName(newMd));
                if (!report.Mirror.Contains(c)) report.Mirror.Add(c);
            }
            catch (Exception e) { report.Warnings.Add($"副本沒寫成：{e.Message}"); }
        }

        HearbyLog.Write($"rename: {oldId} → {newName} files={report.Renamed.Count} memory={string.Join(",", report.Memory)} mirror={report.Mirror.Count} warnings={report.Warnings.Count}");
        return report;
    }

    /// Move / rename (never overwrites). Only letter case differs (on a case-insensitive disk both names are the same file):
    /// go through a temporary name first
    internal static void Move(string src, string dst, bool directory)
    {
        void Mv(string a, string b) { if (directory) Directory.Move(a, b); else File.Move(a, b); }
        if (Path.GetFileName(src) == Path.GetFileName(dst) || !SameIgnoringCase(Path.GetFileName(src), Path.GetFileName(dst))) { Mv(src, dst); return; }
        var tmp = Path.Combine(Path.GetDirectoryName(src)!, ".hearby-rename-" + Guid.NewGuid().ToString("N"));
        Mv(src, tmp);
        try { Mv(tmp, dst); } catch { try { Mv(tmp, src); } catch { } throw; }
    }

    /// "> 音檔：" points at a file in this meeting's old folder: the renamed file in the new folder; anywhere else (the work folder) = null
    internal static string? AudioPath(string path, string[] oldDirs, string newDir, string oldId, string folder, string newName)
    {
        var parent = Path.GetDirectoryName(path);
        if (parent == null || !oldDirs.Contains(parent)) return null;
        var name = Path.GetFileName(path);
        return Path.Combine(newDir, Renamed(name, oldId, folder, newName) ?? name);
    }
}

/// Meetings being processed, re-polished, translated or exported (folders): these write their result when they finish, and a folder
/// renamed halfway would leave nowhere to write it
public static class MeetingBusy
{
    static readonly object Gate = new();
    static readonly Dictionary<string, int> Dirs = new(StringComparer.Ordinal);

    static string Key(string dir) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(dir));

    public static void Begin(string dir) { lock (Gate) { var k = Key(dir); Dirs[k] = Dirs.GetValueOrDefault(k) + 1; } }

    public static void End(string dir)
    {
        lock (Gate)
        {
            var k = Key(dir);
            if (!Dirs.TryGetValue(k, out var n)) return;
            if (n > 1) Dirs[k] = n - 1; else Dirs.Remove(k);
        }
    }

    public static bool Contains(string dir) { lock (Gate) return Dirs.ContainsKey(Key(dir)); }

    /// using var _ = MeetingBusy.Scope(dir); — busy until the end of the block
    public static IDisposable Scope(string dir) { Begin(dir); return new Ender(dir); }

    sealed class Ender(string dir) : IDisposable
    {
        bool done;
        public void Dispose() { if (!done) { done = true; End(dir); } }
    }
}
