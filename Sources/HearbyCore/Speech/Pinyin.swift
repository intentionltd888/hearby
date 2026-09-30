// Pinyin — 讀音比對的底：漢字的無聲調拼音（PinyinData 那張表，macOS 與 Windows 同一份）、注音轉拼音、台灣口音的「聽起來一樣」
//
// 表裡多音字只有最常見的一個讀音（藏＝cang）；名冊第 5 欄寫的讀音（「藏＝ㄗㄤˋ」）由 SoundAlike 蓋過去。
// key（聽起來一樣）：翹舌＝平舌（zh ch sh → z c s）、ㄣㄥ不分（-ng → -n）、ㄌㄋ不分（l → n）；聲調本來就不看。
// coarse（差一點）：再把送氣、不送氣併成一組（b p、d t、g k、z c、j q x）。
import Foundation

public enum Pinyin {
    static let table: [Character: String] = {
        var t: [Character: String] = [:]
        for line in PinyinData.table.split(separator: "\n") {
            guard let sp = line.firstIndex(of: " ") else { continue }
            let py = String(line[..<sp])
            for ch in line[line.index(after: sp)...] { t[ch] = py }
        }
        return t
    }()

    /// 一個字的拼音（沒有聲調）；表裡沒有＝nil
    public static func of(_ ch: Character) -> String? { table[ch] }

    /// CJK 統一表意文字（含擴充 A）：表收的範圍，也是比對時切段的依據
    static func isHan(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let v = ch.unicodeScalars.first?.value else { return false }
        return (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v)
    }

    static let initials: [Character: String] = [
        "ㄅ": "b", "ㄆ": "p", "ㄇ": "m", "ㄈ": "f", "ㄉ": "d", "ㄊ": "t", "ㄋ": "n", "ㄌ": "l", "ㄍ": "g", "ㄎ": "k", "ㄏ": "h",
        "ㄐ": "j", "ㄑ": "q", "ㄒ": "x", "ㄓ": "zh", "ㄔ": "ch", "ㄕ": "sh", "ㄖ": "r", "ㄗ": "z", "ㄘ": "c", "ㄙ": "s"]
    static let finals: [Character: String] = [
        "ㄚ": "a", "ㄛ": "o", "ㄜ": "e", "ㄝ": "e", "ㄞ": "ai", "ㄟ": "ei", "ㄠ": "ao", "ㄡ": "ou", "ㄢ": "an", "ㄣ": "en",
        "ㄤ": "ang", "ㄥ": "eng", "ㄦ": "er"]
    static let tones: Set<Character> = ["ˊ", "ˇ", "ˋ", "˙", "ˉ"]
    static let withI = ["": "i", "a": "ia", "o": "io", "e": "ie", "ai": "iai", "ao": "iao", "ou": "iu", "an": "ian", "en": "in", "ang": "iang", "eng": "ing"]
    static let withU = ["": "u", "a": "ua", "o": "uo", "ai": "uai", "ei": "ui", "an": "uan", "en": "un", "ang": "uang", "eng": "ong"]
    static let withV = ["": "u", "e": "ue", "an": "uan", "en": "un", "eng": "iong"]
    static let bareI = ["i": "yi", "ia": "ya", "io": "yo", "ie": "ye", "iai": "yai", "iao": "yao", "iu": "you", "ian": "yan", "in": "yin", "iang": "yang", "ing": "ying"]
    static let bareU = ["u": "wu", "ua": "wa", "uo": "wo", "uai": "wai", "ui": "wei", "uan": "wan", "un": "wen", "uang": "wang", "ong": "weng"]
    static let bareV = ["u": "yu", "ue": "yue", "uan": "yuan", "un": "yun", "iong": "yong"]

    /// 注音一個音節 → 拼音（沒有聲調；ㄩ 寫成 u，跟表裡去掉變音符號的寫法一樣：ㄋㄩˇ＝nu）；看不懂＝nil
    public static func fromZhuyin(_ z: String) -> String? {
        var cs = Array(z.filter { !tones.contains($0) && $0 != " " })
        guard !cs.isEmpty else { return nil }
        var ini = ""
        if let i = initials[cs[0]] { ini = i; cs.removeFirst() }
        var med: Character? = nil
        if let c = cs.first, c == "ㄧ" || c == "ㄨ" || c == "ㄩ" { med = c; cs.removeFirst() }
        var fin = ""
        if !cs.isEmpty {
            guard cs.count == 1, let f = finals[cs[0]] else { return nil }
            fin = f
        }
        switch med {
        case "ㄧ":
            guard let b = withI[fin] else { return nil }
            return ini.isEmpty ? bareI[b] : ini + b
        case "ㄨ":
            guard let b = withU[fin] else { return nil }
            return ini.isEmpty ? bareU[b] : ini + b
        case "ㄩ":
            guard let b = withV[fin] else { return nil }
            return ini.isEmpty ? bareV[b] : ini + b
        default:
            if !fin.isEmpty { return ini + fin }
            return ["zh", "ch", "sh", "r", "z", "c", "s"].contains(ini) ? ini + "i" : nil
        }
    }

    /// 聽起來一樣：翹舌＝平舌、-ng＝-n、l＝n
    public static func key(_ s: String) -> String {
        var k = s.replacingOccurrences(of: "zh", with: "z").replacingOccurrences(of: "ch", with: "c").replacingOccurrences(of: "sh", with: "s")
        if k.count > 2, k.hasSuffix("ng") { k.removeLast() }
        if k.hasPrefix("l") { k = "n" + k.dropFirst() }
        return k
    }

    static let aspirated: [Character: Character] = ["p": "b", "t": "d", "k": "g", "c": "z", "q": "j", "x": "j"]

    /// 差一點：聽起來一樣，再加上送氣、不送氣不分
    public static func coarse(_ s: String) -> String {
        let k = key(s)
        guard let f = k.first, let m = aspirated[f] else { return k }
        return String(m) + k.dropFirst()
    }
}
