// Pinyin — the base of sound-alike matching: toneless pinyin per Han character (the PinyinData table, same data as the Mac side),
// zhuyin → pinyin, and the Taiwan-accent "sounds the same".
//
// The table holds one reading per character (the most common: 藏 = cang); a reading in roster column 5 (「藏＝ㄗㄤˋ」) overrides it in SoundAlike.
// Key (sounds the same): retroflex = flat (zh ch sh → z c s), -ng = -n, l = n; tones are never looked at.
// Coarse (nearly the same): additionally aspirated = unaspirated (b p, d t, g k, z c, j q x).
namespace Hearby.Core;

public static class Pinyin
{
    static readonly Lazy<Dictionary<char, string>> table = new(() =>
    {
        var t = new Dictionary<char, string>();
        foreach (var line in PinyinData.Table.Split('\n'))
        {
            int sp = line.IndexOf(' ');
            if (sp < 0) continue;
            var py = line[..sp].TrimEnd('\r');
            foreach (var ch in line[(sp + 1)..]) if (ch != '\r') t[ch] = py;
        }
        return t;
    });

    /// How many characters the table holds (contract check)
    internal static int Count => table.Value.Count;

    /// A character's pinyin (no tone); null when the table has none. Takes a grapheme (Swift Character): only single BMP Han characters are in the table
    public static string? Of(string ch) => ch.Length == 1 && table.Value.TryGetValue(ch[0], out var p) ? p : null;

    /// CJK Unified Ideographs (with Extension A): what the table covers, and where matching cuts runs
    internal static bool IsHan(string ch) => ch.Length == 1 && ((ch[0] >= '㐀' && ch[0] <= '䶿') || (ch[0] >= '一' && ch[0] <= '鿿'));

    static readonly Dictionary<char, string> Initials = new()
    {
        ['ㄅ'] = "b", ['ㄆ'] = "p", ['ㄇ'] = "m", ['ㄈ'] = "f", ['ㄉ'] = "d", ['ㄊ'] = "t", ['ㄋ'] = "n", ['ㄌ'] = "l", ['ㄍ'] = "g", ['ㄎ'] = "k", ['ㄏ'] = "h",
        ['ㄐ'] = "j", ['ㄑ'] = "q", ['ㄒ'] = "x", ['ㄓ'] = "zh", ['ㄔ'] = "ch", ['ㄕ'] = "sh", ['ㄖ'] = "r", ['ㄗ'] = "z", ['ㄘ'] = "c", ['ㄙ'] = "s",
    };
    static readonly Dictionary<char, string> Finals = new()
    {
        ['ㄚ'] = "a", ['ㄛ'] = "o", ['ㄜ'] = "e", ['ㄝ'] = "e", ['ㄞ'] = "ai", ['ㄟ'] = "ei", ['ㄠ'] = "ao", ['ㄡ'] = "ou", ['ㄢ'] = "an", ['ㄣ'] = "en",
        ['ㄤ'] = "ang", ['ㄥ'] = "eng", ['ㄦ'] = "er",
    };
    internal static readonly HashSet<char> Tones = ['ˊ', 'ˇ', 'ˋ', '˙', 'ˉ'];
    static readonly Dictionary<string, string> WithI = new() { [""] = "i", ["a"] = "ia", ["o"] = "io", ["e"] = "ie", ["ai"] = "iai", ["ao"] = "iao", ["ou"] = "iu", ["an"] = "ian", ["en"] = "in", ["ang"] = "iang", ["eng"] = "ing" };
    static readonly Dictionary<string, string> WithU = new() { [""] = "u", ["a"] = "ua", ["o"] = "uo", ["ai"] = "uai", ["ei"] = "ui", ["an"] = "uan", ["en"] = "un", ["ang"] = "uang", ["eng"] = "ong" };
    static readonly Dictionary<string, string> WithV = new() { [""] = "u", ["e"] = "ue", ["an"] = "uan", ["en"] = "un", ["eng"] = "iong" };
    static readonly Dictionary<string, string> BareI = new() { ["i"] = "yi", ["ia"] = "ya", ["io"] = "yo", ["ie"] = "ye", ["iai"] = "yai", ["iao"] = "yao", ["iu"] = "you", ["ian"] = "yan", ["in"] = "yin", ["iang"] = "yang", ["ing"] = "ying" };
    static readonly Dictionary<string, string> BareU = new() { ["u"] = "wu", ["ua"] = "wa", ["uo"] = "wo", ["uai"] = "wai", ["ui"] = "wei", ["uan"] = "wan", ["un"] = "wen", ["uang"] = "wang", ["ong"] = "weng" };
    static readonly Dictionary<string, string> BareV = new() { ["u"] = "yu", ["ue"] = "yue", ["uan"] = "yuan", ["un"] = "yun", ["iong"] = "yong" };

    /// One zhuyin syllable → pinyin (no tone; ㄩ written u, like the table's diacritic-stripped spelling: ㄋㄩˇ = nu); unreadable = null
    public static string? FromZhuyin(string z)
    {
        var cs = z.Where(c => !Tones.Contains(c) && c != ' ').ToList();
        if (cs.Count == 0) return null;
        var ini = "";
        if (Initials.TryGetValue(cs[0], out var i0)) { ini = i0; cs.RemoveAt(0); }
        char? med = null;
        if (cs.Count > 0 && (cs[0] == 'ㄧ' || cs[0] == 'ㄨ' || cs[0] == 'ㄩ')) { med = cs[0]; cs.RemoveAt(0); }
        var fin = "";
        if (cs.Count > 0)
        {
            if (cs.Count != 1 || !Finals.TryGetValue(cs[0], out var f)) return null;
            fin = f;
        }
        string? With(Dictionary<string, string> with, Dictionary<string, string> bare) =>
            !with.TryGetValue(fin, out var b) ? null : ini.Length == 0 ? bare.GetValueOrDefault(b) : ini + b;
        return med switch
        {
            'ㄧ' => With(WithI, BareI),
            'ㄨ' => With(WithU, BareU),
            'ㄩ' => With(WithV, BareV),
            _ => fin.Length > 0 ? ini + fin : new[] { "zh", "ch", "sh", "r", "z", "c", "s" }.Contains(ini) ? ini + "i" : null,
        };
    }

    /// Sounds the same: retroflex = flat, -ng = -n, l = n
    public static string Key(string s)
    {
        var k = s.Replace("zh", "z").Replace("ch", "c").Replace("sh", "s");
        if (k.Length > 2 && k.EndsWith("ng", StringComparison.Ordinal)) k = k[..^1];
        if (k.StartsWith('l')) k = "n" + k[1..];
        return k;
    }

    static readonly Dictionary<char, char> Aspirated = new() { ['p'] = 'b', ['t'] = 'd', ['k'] = 'g', ['c'] = 'z', ['q'] = 'j', ['x'] = 'j' };

    /// Nearly the same: sounds the same, and aspirated = unaspirated
    public static string Coarse(string s)
    {
        var k = Key(s);
        return k.Length > 0 && Aspirated.TryGetValue(k[0], out var m) ? m + k[1..] : k;
    }
}
