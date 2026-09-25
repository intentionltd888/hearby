// Clean — mechanical cleanup (no model): simplified→traditional, full-width punctuation, glossary, alias feedback.
// Mirrors Speech/Clean.swift.
using System.Text;

namespace Hearby.Core;

/// Simplified → traditional Chinese. macOS uses ICU "Hans-Hant"; Windows uses LCMapStringEx(LCMAP_TRADITIONAL_CHINESE)
/// (set by the app at start-up). The two are character-level mappings and agree on common characters; tests pin the rest.
public interface IChineseConverter { string ToTraditional(string s); }

public sealed class IdentityConverter : IChineseConverter { public string ToTraditional(string s) => s; }

public static class Clean
{
    public static IChineseConverter Converter { get; set; } = new IdentityConverter();

    /// Output must never contain simplified characters
    public static string ToTraditional(string s) => s.Length == 0 ? s : Converter.ToTraditional(s);

    static bool IsCJK(string? g) => g != null && Str.FirstScalar(g) is >= 0x4E00 and <= 0x9FFF;

    /// Full-width punctuation: only after a CJK character; the period also needs a CJK / space / end after it
    public static string NormalizePunct(string s)
    {
        var chars = Str.Chars(s);
        var sb = new StringBuilder(s.Length);
        for (int i = 0; i < chars.Count; i++)
        {
            var c = chars[i];
            var prev = i > 0 ? chars[i - 1] : null;
            var next = i + 1 < chars.Count ? chars[i + 1] : null;
            string? rep = c switch { "," => "，", "!" => "！", "?" => "？", ";" => "；", ":" => "：", _ => null };
            if (rep != null && IsCJK(prev)) sb.Append(rep);
            else if (c == "." && IsCJK(prev) && (next == null || next == " " || IsCJK(next))) sb.Append('。');
            else sb.Append(c);
        }
        return sb.ToString();
    }

    // ── Glossary (glossary.txt) ──

    public static string GlossaryPath
    {
        get
        {
            var g = ConfigStore.Shared.Current.GlossaryPath;
            return string.IsNullOrEmpty(g) ? Path.Combine(Paths.Support, "glossary.txt") : Paths.ExpandTilde(g);
        }
    }

    public static string? LocalGlossary()
    {
        try
        {
            if (!File.Exists(GlossaryPath)) return null;
            var t = Str.TrimWSNL(ReadUtf8Strict(GlossaryPath));
            return t.Length == 0 ? null : t;
        }
        catch { return null; }
    }

    /// Reads UTF-8; throws if the bytes are not valid UTF-8 (a glossary saved in another encoding must not be overwritten)
    public static string ReadUtf8Strict(string path) => new UTF8Encoding(false, true).GetString(File.ReadAllBytes(path)).TrimStart('﻿');

    internal static List<string> SplitTerms(string s) =>
        s.Split(['、', ',', '，', '\n'], StringSplitOptions.RemoveEmptyEntries).Select(Str.TrimWS).Where(x => x.Length > 0).ToList();

    /// Merge terms (dedupe, append only); returns how many were added
    public static int AppendGlossary(string raw)
    {
        var incoming = SplitTerms(raw);
        if (incoming.Count == 0) return 0;
        var url = GlossaryPath;
        Directory.CreateDirectory(Path.GetDirectoryName(url)!);
        string? existing = null;
        if (File.Exists(url)) { try { existing = ReadUtf8Strict(url); } catch { return 0; } }
        var terms = SplitTerms(existing ?? "");
        int added = 0;
        foreach (var t in incoming) if (!terms.Contains(t)) { terms.Add(t); added++; }
        if (added > 0) File.WriteAllText(url, string.Join("、", terms), new UTF8Encoding(false));
        return added;
    }

    public static void SeedGlossary() => AppendGlossary("Hearby");

    /// Settings → save glossary: replace with what is on screen. Unreadable file = do not save; keep a daily backup first
    public static void SaveGlossary(string text)
    {
        var url = GlossaryPath;
        if (File.Exists(url))
        {
            try { ReadUtf8Strict(url); }
            catch { throw new HearbyError($"現有的常用詞檔讀不出來（不是 UTF-8 純文字），為了不把它洗掉，這次沒有存。檔案在：{url}"); }
            var bak = url + ".bak-" + DateTime.Now.ToString("yyyyMMdd");
            if (!File.Exists(bak)) { try { File.Copy(url, bak); } catch { } }
        }
        Directory.CreateDirectory(Path.GetDirectoryName(url)!);
        File.WriteAllText(url, text, new UTF8Encoding(false));
    }

    // ── Alias feedback (PEOPLE.md / GLOSSARY.md aliases, plain string replacement) ──

    public static List<(string Alias, string Canonical)> AliasTable()
    {
        var outList = new List<(string, string)>();
        var people = Path.Combine(Paths.Memory, "PEOPLE.md");
        if (TryRead(people) is { } s)
        {
            string? current = null;
            foreach (var raw in Str.Lines(s))
            {
                var line = Str.TrimWS(raw);
                if (line.Starts("## ")) { current = Str.TrimWS(line[3..]); continue; }
                if (current == null) continue;
                foreach (var key in new[] { "- 別名：", "- 別名:", "- aliases:", "- 別名 " })
                {
                    if (!line.Starts(key)) continue;
                    foreach (var a in SplitTerms(line[key.Length..])) if (a != current && Str.Count(a) >= 2) outList.Add((a, current));
                }
            }
        }
        var gl = Path.Combine(Paths.Memory, "GLOSSARY.md");
        if (TryRead(gl) is { } g)
        {
            foreach (var raw in Str.Lines(g))
            {
                var line = Str.TrimWS(raw);
                int eq = line.Find(" = "); int eqLen = 3;
                if (eq < 0) { eq = line.Find("＝"); eqLen = 1; }
                if (eq < 0) continue;
                var canonical = Str.TrimWS(Str.TrimSet(line[..eq], "- "));
                if (canonical.Length == 0) continue;
                foreach (var a in SplitTerms(line[(eq + eqLen)..])) if (a != canonical && Str.Count(a) >= 2) outList.Add((a, canonical));
            }
        }
        return outList;
    }

    static string? TryRead(string path) { try { return File.Exists(path) ? Str.NormalizeNewlines(ReadUtf8Strict(path)) : null; } catch { return null; } }

    /// Apply the alias table (longest alias first, so short ones do not eat long ones)
    public static (string Text, int Count) ApplyAliases(string text, List<(string Alias, string Canonical)>? table = null)
    {
        var t = table ?? AliasTable();
        if (t.Count == 0) return (text, 0);
        var s = text; int n = 0;
        foreach (var (a, c) in t.OrderByDescending(x => Str.Count(x.Alias)))
        {
            if (!s.Has(a)) continue;
            var parts = s.Split(a);
            n += parts.Length - 1;
            s = string.Join(c, parts);
        }
        return (s, n);
    }
}
