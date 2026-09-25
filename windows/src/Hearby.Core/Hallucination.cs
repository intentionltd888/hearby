// Hallucination — filter for whisper's silence hallucinations. Mirrors Speech/Hallucination.swift exactly
// (the reasoning, measurements and why the thresholds are tied together are documented there).
using System.Globalization;
using System.Text;

namespace Hearby.Core;

public static class Hallucination
{
    /// Strong phrases: subtitle credits / outro lines real meetings practically never say
    public static readonly string[] StrongJunkPatterns =
    [
        "謝謝觀看", "謝謝收看", "字幕由", "Amara", "amara.org", "字幕提供", "中文字幕",
        "MING PAO", "明鏡與點點", "♪", "🎵", "(音樂)", "[音樂]",
        "字幕志願者", "志願者", "感謝觀看", "感謝收看", "請不吝", "點贊", "轉發", "打賞", "欄目", "點點欄目",
        "已進行編輯", "以加入正確的標點符號", "以加入正確的標點", "編輯成功後",
        "以上言論不代表本台立場", "影片即將結束", "影片即將開始", "感謝您的觀看", "感謝您的收看",
        "這是一條語音備忘錄", "點點欄目", "轉發打賞", "打賞支持", "分享出去並按一個讚",
        "優優獨播劇場", "宣優獨播劇場", "獨播劇場",
        "YoYo Television Series Exclusive", "Television Series Exclusive",
        "字幕:李宗盛", "字幕：李宗盛", "詞:李宗盛", "詞：李宗盛",
    ];

    /// Weak phrases: short words real speech also uses; junk only when they make up half the line or more
    public static readonly string[] WeakJunkPatterns = ["請訂閱", "訂閱", "點贊"];

    /// Whole-line junk (after trimming punctuation, exact match)
    public static readonly HashSet<string> ExactJunk =
    [
        "thank you.", "thank you", "thanks for watching.", "thanks for watching", "you",
        "中文字幕:cm 李宗盛", "中文字幕：cm 李宗盛",
    ];

    /// Strong phrases longest first. Only safe with residue threshold ≥ 6 (see the macOS file header)
    public static readonly string[] StrongSorted = StrongJunkPatterns.Select((p, i) => (p, i))
        .OrderByDescending(x => Str.Count(x.p)).ThenBy(x => x.i).Select(x => x.p).ToArray();

    public readonly record struct Signals(double? NoSpeechProb = null, int? DurationMs = null);

    public sealed record Rules(bool SortStrongByLength = true, int ResidueThreshold = 6, int LowRateResidueThreshold = 10,
        int LowRateMinDurationMs = 8_000, double LowRateMaxCharsPerSec = 1.5, double? NoSpeechCut = null)
    {
        public static readonly Rules Shipping = new();
    }

    public static bool IsJunk(string text) => IsJunk(text, new Signals(), Rules.Shipping);

    public static bool IsJunk(string text, Signals signals, Rules? rules = null)
    {
        var r = rules ?? Rules.Shipping;
        if (text.Length == 0) return true;
        if (r.NoSpeechCut is { } cut && signals.NoSpeechProb is { } p && p > cut) return true;

        var bare = Str.TrimSet(text.ToLowerInvariant(), " 。．，,!！?？");
        if (ExactJunk.Contains(bare)) return true;

        int threshold = r.ResidueThreshold;
        if (signals.DurationMs is { } ms && ms >= r.LowRateMinDurationMs && Str.Count(text) / (ms / 1000.0) < r.LowRateMaxCharsPerSec)
            threshold = Math.Max(threshold, r.LowRateResidueThreshold);

        var stripped = text;
        bool strongHit = false;
        foreach (var junk in r.SortStrongByLength ? StrongSorted : StrongJunkPatterns)
        {
            if (!stripped.Has(junk)) continue;
            strongHit = true;
            stripped = stripped.Rep(junk, "");
        }
        if (strongHit && Residue(stripped) < threshold) return true;

        int count = Str.Count(text);
        return WeakJunkPatterns.Any(junk => text.Has(junk) && Str.Count(junk) * 2 >= count);
    }

    /// Residue = letters, marks and numbers (Swift CharacterSet.alphanumerics) + CJK; punctuation and spaces do not count
    static int Residue(string s)
    {
        int n = 0;
        foreach (var r in s.EnumerateRunes())
        {
            var cat = Rune.GetUnicodeCategory(r);
            bool alnum = cat is UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
                or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter or UnicodeCategory.NonSpacingMark
                or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark or UnicodeCategory.DecimalDigitNumber
                or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber;
            if (alnum || r.Value is >= 0x4E00 and <= 0x9FFF) n++;
        }
        return n;
    }
}
