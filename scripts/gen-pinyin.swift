// gen-pinyin — 產生「漢字 → 無聲調拼音」表（HearbyCore／Hearby.Core 的讀音比對用；兩邊同一份，Windows 不靠 macOS）
//
// 來源：macOS 內建 CFStringTransform（Mandarin→Latin，再去掉聲調）＝ICU／CLDR 的 Han-Latin 轉寫資料（Unicode License）。
// 範圍：CJK 統一表意文字 U+4E00–U+9FFF 與擴充 A U+3400–U+4DBF（都在 BMP，C# 一個 char 就是一個字）；轉不出拼音的字不收。
// 多音字只有最常見的一個讀音；名冊第 5 欄（讀音，例「藏＝ㄗㄤˋ」）會蓋過它。
//
//   swift scripts/gen-pinyin.swift            重產 Sources/HearbyCore/Speech/PinyinData.swift 與 windows/src/Hearby.Core/PinyinData.cs
//   swift scripts/gen-pinyin.swift --tsv 檔    另外寫一份「字<TAB>拼音」（實測腳本用）
import Foundation

var bySyllable: [String: [Character]] = [:]
var tsv = ""
for range in [0x3400...0x4DBF, 0x4E00...0x9FFF] {
    for v in range {
        guard let u = Unicode.Scalar(v) else { continue }
        let ch = Character(u)
        let s = NSMutableString(string: String(ch))
        CFStringTransform(s, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(s, nil, kCFStringTransformStripDiacritics, false)
        let py = (s as String).lowercased().trimmingCharacters(in: .whitespaces)
        guard !py.isEmpty, py.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { continue }
        bySyllable[py, default: []].append(ch)
        tsv += "\(ch)\t\(py)\n"
    }
}
// 一行一個音節：「音節 字字字…」（音節照字母排、字照碼位排）
let table = bySyllable.keys.sorted().map { "\($0) " + String(bySyllable[$0]!) }.joined(separator: "\n")
let count = bySyllable.values.reduce(0) { $0 + $1.count }

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--tsv"), i + 1 < args.count {
    try tsv.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
    print("tsv：\(count) 字 → \(args[i + 1])")
    exit(0)
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let note = "由 scripts/gen-pinyin.swift 產生，不要手改（\(count) 字、\(bySyllable.count) 個音節）。來源：macOS CFStringTransform＝ICU／CLDR Han-Latin 轉寫（Unicode License）。"
let swift = """
// PinyinData — 漢字 → 無聲調拼音（讀音比對用；Windows 的 PinyinData.cs 是同一份）
// \(note)
enum PinyinData {
    static let table = \"\"\"
\(table)
\"\"\"
}

"""
try swift.write(to: root.appendingPathComponent("Sources/HearbyCore/Speech/PinyinData.swift"), atomically: true, encoding: .utf8)
let cs = """
// PinyinData — Han character → toneless pinyin (for sound-alike matching; same data as the Mac side's PinyinData.swift)
// \(note)
namespace Hearby.Core;

static class PinyinData
{
    public const string Table = \"\"\"
\(table)
\"\"\";
}

"""
try cs.write(to: root.appendingPathComponent("windows/src/Hearby.Core/PinyinData.cs"), atomically: true, encoding: .utf8)
print("PinyinData：\(count) 字、\(bySyllable.count) 個音節")
