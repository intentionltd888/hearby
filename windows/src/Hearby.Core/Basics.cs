// Basics — version, the five states, the three scenes, time formatting, errors, platform hooks.
// Mirrors Sources/HearbyCore/Phase.swift and Process.swift (Fmt, HearbyError).
using System.Globalization;

namespace Hearby.Core;

public static class HearbyVersion
{
    public const string Version = "1.0.0";
    public const string Build = "1";
    /// The macOS core this port follows (contract fixtures were generated from it)
    public const string CoreParity = "2.1.0 (build 22)";
}

/// idle → recording → processing → done → idle; any → error → idle
public enum Phase { Idle, Recording, Processing, Done, Error }

public static class PhaseExt
{
    public static string Label(this Phase p) => p switch
    {
        Phase.Idle => "待命",
        Phase.Recording => "錄音中",
        Phase.Processing => "處理中",
        Phase.Done => "剛完成",
        _ => "有個問題",
    };

    public static bool CanGo(this Phase from, Phase next) => (from, next) switch
    {
        (Phase.Idle, Phase.Recording) or (Phase.Recording, Phase.Processing) or (Phase.Processing, Phase.Done) or (Phase.Done, Phase.Idle) => true,
        (_, Phase.Error) => true,
        (Phase.Error, Phase.Idle) or (Phase.Recording, Phase.Idle) or (Phase.Done, Phase.Recording) => true,
        // Importing audio and "補整理" skip recording: straight from idle/done into processing
        (Phase.Idle, Phase.Processing) or (Phase.Done, Phase.Processing) => true,
        _ => false,
    };
}

/// Scene: meeting (several people, a record) / interview (Q&A) / note (one person, an article)
public enum RecordScene { Meeting, Interview, Note }

public static class RecordSceneExt
{
    public static readonly RecordScene[] All = [RecordScene.Meeting, RecordScene.Interview, RecordScene.Note];
    public static string Raw(this RecordScene s) => s switch { RecordScene.Interview => "interview", RecordScene.Note => "note", _ => "meeting" };
    public static RecordScene? FromRaw(string? raw) => raw switch { "meeting" => RecordScene.Meeting, "interview" => RecordScene.Interview, "note" => RecordScene.Note, _ => null };
    public static string Label(this RecordScene s) => s switch { RecordScene.Interview => "採訪", RecordScene.Note => "筆記", _ => "會議" };
    public static string Hint(this RecordScene s) => s switch
    {
        RecordScene.Interview => "一問一答：整理成可引用的訪談稿",
        RecordScene.Note => "一個人講：整理成一篇排版好的筆記",
        _ => "多人開會：摘要、與會者、重點、決議、待辦",
    };
    /// First-level heading of the record md
    public static string MdTitle(this RecordScene s) => s switch { RecordScene.Interview => "訪談", RecordScene.Note => "筆記", _ => "會議紀錄" };
    /// Older files used 「會議記錄」 (言部); both are recognised, existing folders are never renamed
    public static readonly string[] LegacyMdTitles = ["會議記錄"];
    public static RecordScene FromMdTitle(string line)
    {
        if (line.Starts("# 訪談")) return RecordScene.Interview;
        if (line.Starts("# 筆記")) return RecordScene.Note;
        return RecordScene.Meeting;
    }
}

public sealed class HearbyError(string message) : Exception(message);

public static class Fmt
{
    /// Every seconds value goes through here before becoming an int: NaN, ±inf, negatives and absurd values clamp to 0…10 days
    public static double ClampSeconds(double s) => double.IsFinite(s) ? Math.Min(Math.Max(0, s), 864_000) : 0;

    /// 00:00 or h:mm:ss
    public static string Ts(int ms)
    {
        int s = ms / 1000;
        if (s >= 3600) return $"{s / 3600}:{Str.D2((s % 3600) / 60)}:{Str.D2(s % 60)}";
        return $"{Str.D2(s / 60)}:{Str.D2(s % 60)}";
    }

    /// 1小時2分 / 3分4秒 / 5秒
    public static string Dur(double seconds)
    {
        int s = (int)ClampSeconds(seconds);
        if (s >= 3600) return $"{s / 3600}小時{(s % 3600) / 60}分";
        if (s >= 60) return $"{s / 60}分{s % 60}秒";
        return $"{s}秒";
    }

    public static string Inv(double v, string fmt) => v.ToString(fmt, CultureInfo.InvariantCulture);
}

/// Local wall-clock time zone. Tests pin it (Asia/Taipei) so fixture times match the macOS run.
public static class HearbyTime
{
    public static TimeZoneInfo Zone { get; set; } = TimeZoneInfo.Local;
    public static DateTime Local(DateTimeOffset t) => TimeZoneInfo.ConvertTime(t, Zone).DateTime;
    public static DateTimeOffset Now => DateTimeOffset.Now;
}
