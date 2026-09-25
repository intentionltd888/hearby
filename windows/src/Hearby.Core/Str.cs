// Str — string helpers that count and cut the way the macOS (Swift) version does.
//
// Swift counts user-perceived characters (grapheme clusters); C# string.Length counts UTF-16 units.
// Titles, 60-character caps, "220 characters per chunk", "two-character prefix" all depend on counting,
// so everything that mirrors a Swift `.count` / `.prefix(n)` goes through here (contract fixtures check it).
using System.Globalization;
using System.Text;

namespace Hearby.Core;

public static class Str
{
    /// Grapheme clusters (Swift Characters)
    public static List<string> Chars(string s)
    {
        var list = new List<string>(s.Length);
        var e = StringInfo.GetTextElementEnumerator(s);
        while (e.MoveNext()) list.Add((string)e.Current);
        return list;
    }

    /// Swift `s.count`
    public static int Count(string s) => s.Length == 0 ? 0 : new StringInfo(s).LengthInTextElements;

    /// Swift `String(s.prefix(n))`
    public static string Prefix(string s, int n)
    {
        if (n <= 0 || s.Length == 0) return "";
        var si = new StringInfo(s);
        return n >= si.LengthInTextElements ? s : si.SubstringByTextElements(0, n);
    }

    /// Swift `String(s.dropFirst(n))`
    public static string DropFirst(string s, int n)
    {
        if (n <= 0) return s;
        var si = new StringInfo(s);
        return n >= si.LengthInTextElements ? "" : si.SubstringByTextElements(n);
    }

    /// Swift `String(s.suffix(n))`
    public static string Suffix(string s, int n)
    {
        var si = new StringInfo(s);
        int len = si.LengthInTextElements;
        return n >= len ? s : si.SubstringByTextElements(len - n);
    }

    /// Swift `String(s.dropLast(n))`
    public static string DropLast(string s, int n)
    {
        var si = new StringInfo(s);
        int len = si.LengthInTextElements;
        return n >= len ? "" : si.SubstringByTextElements(0, len - n);
    }

    /// Swift CharacterSet.whitespaces: Unicode Zs + TAB (no newlines)
    public static bool IsWS(char c) => c == '\t' || char.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

    /// Swift `trimmingCharacters(in: .whitespaces)`
    public static string TrimWS(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && IsWS(s[a])) a++;
        while (b > a && IsWS(s[b - 1])) b--;
        return (a == 0 && b == s.Length) ? s : s[a..b];
    }

    /// Swift `trimmingCharacters(in: .whitespacesAndNewlines)` (C# char.IsWhiteSpace is the same set)
    public static string TrimWSNL(string s) => s.Trim();

    /// Swift `trimmingCharacters(in: CharacterSet(charactersIn: chars))`
    public static string TrimSet(string s, string chars) => s.Trim(chars.ToCharArray());

    /// Swift `components(separatedBy: "\n")`
    public static string[] Lines(string s) => s.Split('\n');

    /// Swift `components(separatedBy: CharacterSet(charactersIn: chars))` (empty pieces kept)
    public static string[] SplitAny(string s, string chars) => s.Split(chars.ToCharArray());

    public static bool Has(this string s, string sub) => s.Contains(sub, StringComparison.Ordinal);
    public static bool Starts(this string s, string p) => s.StartsWith(p, StringComparison.Ordinal);
    public static bool Ends(this string s, string p) => s.EndsWith(p, StringComparison.Ordinal);
    public static int Find(this string s, string sub, int from = 0) => s.IndexOf(sub, from, StringComparison.Ordinal);
    public static int FindLast(this string s, string sub) => s.LastIndexOf(sub, StringComparison.Ordinal);
    public static string Rep(this string s, string a, string b) => s.Replace(a, b, StringComparison.Ordinal);

    /// Unicode scalars (Swift unicodeScalars)
    public static IEnumerable<Rune> Scalars(string s) => s.EnumerateRunes();

    /// First scalar of a grapheme (Swift `c.unicodeScalars.first`)
    public static int FirstScalar(string grapheme) => grapheme.Length == 0 ? -1 : Rune.GetRuneAt(grapheme, 0).Value;

    /// Swift Character.isLetter || isNumber (first scalar's category decides)
    public static bool IsLetterOrNumber(string grapheme)
    {
        if (grapheme.Length == 0) return false;
        var r = Rune.GetRuneAt(grapheme, 0);
        return Rune.IsLetter(r) || Rune.IsNumber(r);
    }

    /// Swift Character.isNumber on a scalar-level filter (`filter(\.isNumber)` over a digits string)
    public static string DigitsOnly(string s)
    {
        var sb = new StringBuilder();
        foreach (var g in Chars(s)) { var r = Rune.GetRuneAt(g, 0); if (Rune.IsNumber(r)) sb.Append(g); }
        return sb.ToString();
    }

    /// UTF-8 byte length (Swift `s.utf8.count`)
    public static int Utf8Len(string s) => Encoding.UTF8.GetByteCount(s);

    /// Swift `String(format: "%02d", n)`
    public static string D2(int n) => n.ToString("00", CultureInfo.InvariantCulture);

    /// Normalise text read from disk: CRLF / CR → LF (Notepad and other Windows editors save CRLF;
    /// the record format and every parser assume LF)
    public static string NormalizeNewlines(string s) => s.Contains('\r') ? s.Replace("\r\n", "\n").Replace('\r', '\n') : s;
}
