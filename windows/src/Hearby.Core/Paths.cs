// Paths — where things live (mirrors Sources/HearbyCore/Store/Paths.swift, with Windows locations)
//
//   %USERPROFILE%\Hearby\CLAUDE.md  AGENTS.md          ← entry points for the user's AI
//   %USERPROFILE%\Hearby\會議\<日期_時間_標題>\         ← one folder per meeting: .m4a .md meta.json
//   %USERPROFILE%\Hearby\memory\                       ← five files + index.json
//   %USERPROFILE%\Hearby\templates\
// App data (config, models, recording work folders, downloads): %LOCALAPPDATA%\Hearby\ ; logs: %LOCALAPPDATA%\Hearby\Logs\
//
// Test/dev sandbox (tests must never write into the real folders):
//   HEARBY_OUTPUT_ROOT  replaces %USERPROFILE%\Hearby
//   HEARBY_SUPPORT_DIR  replaces %LOCALAPPDATA%\Hearby
//   HEARBY_LOG_DIR      replaces %LOCALAPPDATA%\Hearby\Logs
using System.Globalization;
using System.Text;

namespace Hearby.Core;

public static class Paths
{
    static string? Env(string k) { var v = Environment.GetEnvironmentVariable(k); return string.IsNullOrEmpty(v) ? null : v; }

    public static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// "~/x" → home/x (config values may be written either way)
    public static string ExpandTilde(string p)
    {
        if (p == "~") return Home;
        if (p.Starts("~/") || p.Starts("~\\")) return Path.Combine(Home, p[2..]);
        return p;
    }

    /// User data root: env > config.outputRoot > %USERPROFILE%\Hearby
    public static string Root
    {
        get
        {
            if (Env("HEARBY_OUTPUT_ROOT") is { } e) return e;
            var c = ConfigStore.Shared.Current.OutputRoot;
            if (!string.IsNullOrEmpty(c)) return ExpandTilde(c);
            return Path.Combine(Home, "Hearby");
        }
    }

    public static string Meetings => Path.Combine(Root, "會議");
    public static string Memory => Path.Combine(Root, "memory");
    public static string UserTemplates => Path.Combine(Root, "templates");

    /// Optional second copy of every record; null = off
    public static string? Mirror
    {
        get { var m = ConfigStore.Shared.Current.MirrorDir; return string.IsNullOrEmpty(m) ? null : ExpandTilde(m); }
    }

    /// App data
    public static string Support
    {
        get
        {
            if (Env("HEARBY_SUPPORT_DIR") is { } e) return e;
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Hearby");
        }
    }

    public static string Logs
    {
        get
        {
            if (Env("HEARBY_LOG_DIR") is { } e) return e;
            if (Env("HEARBY_SUPPORT_DIR") is { } s) return Path.Combine(s, "Logs");
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Hearby", "Logs");
        }
    }

    public static string Models => Path.Combine(Support, "models");

    /// Creates every folder (idempotent); returns the ones it created
    public static List<string> Ensure()
    {
        var made = new List<string>();
        foreach (var u in new[] { Root, Meetings, Memory, UserTemplates, Support, Logs })
        {
            if (!Directory.Exists(u)) { Directory.CreateDirectory(u); made.Add(u); }
        }
        return made;
    }

    /// Meeting folder name: yyyy-MM-dd_HHmm_標題 (same as macOS; always Gregorian digits)
    public static string MeetingFolderName(DateTimeOffset date, string title)
    {
        var t = HearbyTime.Local(date);
        return t.ToString("yyyy-MM-dd_HHmm", CultureInfo.InvariantCulture) + "_" + SafeTitle(title);
    }

    static bool IsBadMac(Rune r)
    {
        int v = r.Value;
        if (v == '/' || v == ':' || v == '\\') return true;
        if (v is >= 0x0A and <= 0x0D || v == 0x85 || v == 0x2028 || v == 0x2029) return true;   // CharacterSet.newlines
        if (v <= 0x1F || (v >= 0x7F && v <= 0x9F)) return true;                              // C0/C1 controls only
        return false;
    }

    /// File-name safe title. Same rules as macOS (controls, path separators, 60 characters / 180 UTF-8 bytes),
    /// plus what Windows forbids: < > " | ? * become spaces and the name may not end with a space or a dot.
    public static string SafeTitle(string s, bool windowsRules = true)
    {
        var sb = new StringBuilder();
        foreach (var r in s.EnumerateRunes())
        {
            bool bad = IsBadMac(r) || (windowsRules && r.Value is '<' or '>' or '"' or '|' or '?' or '*');
            sb.Append(bad ? " " : r.ToString());
        }
        var t = Str.TrimWSNL(sb.ToString());
        if (t.Length == 0) return "未命名";
        var o = Str.Prefix(t, 60);
        while (Str.Utf8Len(o) > 180) o = Str.DropLast(o, 1);
        o = Str.TrimWS(o);
        if (windowsRules) o = o.TrimEnd('.', ' ');
        return o.Length == 0 ? "未命名" : o;
    }

    /// Can we write here? Doctor only looks (never creates); if it does not exist yet, check the parent
    public static bool IsWritable(string dir)
    {
        try
        {
            if (File.Exists(dir)) return false;
            var probeDir = Directory.Exists(dir) ? dir : Path.GetDirectoryName(dir);
            if (probeDir == null || !Directory.Exists(probeDir)) return false;
            // A probe the OS removes when the handle closes (Windows ACLs are not visible from attributes)
            var probe = Path.Combine(probeDir, ".hearby-write-probe-" + Environment.ProcessId);
            using (new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1, FileOptions.DeleteOnClose)) { }
            return true;
        }
        catch { return false; }
    }
}

/// Log — one line per event (%LOCALAPPDATA%\Hearby\Logs\hearby.log); rotates at 5 MB. Never blocks anything.
public static class HearbyLog
{
    static readonly object Gate = new();
    public static string File => Path.Combine(Paths.Logs, "hearby.log");

    public static void Write(string message)
    {
        var line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture) + " " + message + "\n";
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Paths.Logs);
                var f = new FileInfo(File);
                if (f.Exists && f.Length > 5_000_000) System.IO.File.Move(File, File + ".1", overwrite: true);
                System.IO.File.AppendAllText(File, line, new UTF8Encoding(false));
            }
            catch { /* a log that cannot be written must not stop anything */ }
        }
    }
}
