// NameFixes — 帶名冊整理時，AI 另外回一節「## 名字更正」（逐字稿原字 → 正名｜把握｜[時間戳]…），Hearby 照它改逐字稿
//
// 只改清單上那幾行（時間戳對得上）裡的那個字串。這些不改：把握不是「高」、原字不到兩個字（一個字會改到別的詞）、
// 正名裡沒有名冊或與會者名單的名字（不讓 AI 借更正改寫別的內容；正名是名冊名字的簡稱時，原字要唸起來像它）、那一行找不到原字。
// 沒改的在紀錄裡第一次提到的地方標 [[?]]；改了什麼寫在紀錄表頭「> 名字更正：」一行（原本的逐字稿在覆寫前的備份裡）。
// 同一個正名有一組改成了、另一組沒改成＝不標（名字本身是確定的）。
import Foundation

public enum NameFixes {
    public struct Fix: Equatable {
        public var heard: String
        public var name: String
        public var sure: Bool
        public var stamps: [String]
        public init(heard: String, name: String, sure: Bool, stamps: [String]) {
            self.heard = heard; self.name = name; self.sure = sure; self.stamps = stamps
        }
    }

    public static let heading = "## 名字更正"
    static let stampPattern = #"\[((?:\d{1,2}:)?\d{1,3}:[0-5]\d)\]"#

    /// 從整理結果拿出「## 名字更正」一節（到下一個「## 」或結尾）：回（拿掉這一節的整理結果, 清單）
    public static func extract(_ notes: String) -> (notes: String, fixes: [Fix]) {
        var lines = notes.components(separatedBy: "\n")
        guard let h = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(heading) }) else { return (notes, []) }
        var e = lines.count
        for i in (h + 1)..<lines.count where lines[i].hasPrefix("## ") { e = i; break }
        let fixes = lines[(h + 1)..<e].compactMap(parse)
        lines.removeSubrange(h..<e)
        if h > 0, h < lines.count, lines[h - 1].trimmingCharacters(in: .whitespaces).isEmpty, lines[h].trimmingCharacters(in: .whitespaces).isEmpty { lines.remove(at: h) }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return (lines.joined(separator: "\n"), fixes)
    }

    /// 「- 原字 → 正名｜高｜[01:02] [1:03:04]」；箭頭也認 -> =>，直線也認半形；沒箭頭、兩邊一樣、「- 無」＝不算
    static func parse(_ raw: String) -> Fix? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("-") else { return nil }
        t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != "無" else { return nil }
        var stamps: [String] = []
        if let re = try? NSRegularExpression(pattern: stampPattern) {
            let ns = t as NSString
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let s = ns.substring(with: m.range(at: 1))
                if !stamps.contains(s) { stamps.append(s) }
            }
        }
        t = t.replacingOccurrences(of: stampPattern, with: "", options: .regularExpression)
        let cols = t.components(separatedBy: CharacterSet(charactersIn: "｜|")).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let arrow = ["→", "->", "=>"].lazy.compactMap({ cols[0].range(of: $0) }).first else { return nil }
        let quotes = CharacterSet(charactersIn: " 「」『』\"'“”")
        let heard = String(cols[0][..<arrow.lowerBound]).trimmingCharacters(in: quotes)
        let name = String(cols[0][arrow.upperBound...]).trimmingCharacters(in: quotes)
        guard !heard.isEmpty, !name.isEmpty, heard != name else { return nil }
        let sure = cols.dropFirst().contains { $0 == "高" || $0.lowercased() == "high" }
        return Fix(heard: heard, name: name, sure: sure, stamps: stamps)
    }

    /// 套到逐字稿（一行一句「- [mm:ss][誰] 內容」）：回（新逐字稿, 改了的（更正, 處數）, 沒改的）。
    /// 一邊包含另一邊的（「預算 → 預算表」「王小明 → 小明」）不是聽錯，是在改寫內容：整筆不算（不改、不標、不列）
    public static func apply(_ fixes: [Fix], transcript: String, names: [String]) -> (transcript: String, applied: [(fix: Fix, count: Int)], skipped: [Fix]) {
        var lines = transcript.components(separatedBy: "\n")
        var applied: [(fix: Fix, count: Int)] = []
        var skipped: [Fix] = []
        for f in fixes where !f.name.contains(f.heard) && !f.heard.contains(f.name) {
            guard f.sure, f.heard.count >= 2, known(f, names), !dropsWords(f) else { skipped.append(f); continue }
            var n = 0
            for s in f.stamps {
                let prefix = "- [\(s)]["
                for i in lines.indices where lines[i].hasPrefix(prefix) {
                    let l = lines[i]
                    guard let close = l.range(of: "] ", range: l.index(l.startIndex, offsetBy: prefix.count)..<l.endIndex) else { continue }
                    let text = String(l[close.upperBound...])
                    let k = text.components(separatedBy: f.heard).count - 1
                    guard k > 0 else { continue }
                    n += k
                    lines[i] = String(l[..<close.upperBound]) + text.replacingOccurrences(of: f.heard, with: f.name)
                }
            }
            if n > 0 { applied.append((f, n)) } else { skipped.append(f) }
        }
        return (lines.joined(separator: "\n"), applied, skipped)
    }

    /// 中文的名字聽錯，字數幾乎不變；沒有英文字母、正名卻少了兩個字以上＝把原字前後的字弄丟了（「林曉安老師 → 林小安」）
    static func dropsWords(_ f: Fix) -> Bool {
        let latin = { (s: String) in s.range(of: "[A-Za-z]", options: .regularExpression) != nil }
        return !latin(f.heard) && !latin(f.name) && f.heard.count - f.name.count >= 2
    }

    /// 正名裡要有一個名冊（或與會者）的名字、而且原字裡沒有它（「凌那邊 → 林那邊」的「林」）；
    /// 或正名是名冊名字的一段（簡稱：「亞特」之於亞特蘭提斯、「昱廷」之於吳昱廷），而且原字唸起來像它（SoundAlike.close）
    static func known(_ f: Fix, _ names: [String]) -> Bool {
        names.contains { !$0.isEmpty && f.name.contains($0) && !f.heard.contains($0) }
            || (f.name.count >= 2 && names.contains { $0.count > f.name.count && $0.contains(f.name) } && SoundAlike.close(f.heard, f.name))
    }

    /// 沒改的：紀錄裡第一次提到的地方後面標 [[?]]——一節一節找（摘要 → 重點 → 決議 → 開放問題；與會者、待辦不動），
    /// 每一節先找正名、再找原字；一個字的不標（會標在別的詞中間）；同一個正名只標一次。
    /// 正名本來就在逐字稿裡講過（不分大小寫；例：公司名）＝紀錄提到它是對的，只找原字，不標在正名上
    public static func markUnsure(_ notes: String, _ fixes: [Fix], transcript: String = "") -> String {
        guard !fixes.isEmpty else { return notes }
        var lines = notes.components(separatedBy: "\n")
        var section: [String] = []
        var cur = ""
        for l in lines {
            if l.hasPrefix("## ") { cur = String(l.dropFirst(3)); section.append("") } else { section.append(cur) }
        }
        var seen = Set<String>()
        for f in fixes where !seen.contains(f.name) {
            seen.insert(f.name)
            let spoken = !transcript.isEmpty && transcript.range(of: f.name, options: .caseInsensitive) != nil
            search: for key in ["摘要", "重點", "決議", "開放問題"] {
                for word in (spoken ? [f.heard] : [f.name, f.heard]) where word.count >= 2 {
                    for i in lines.indices where section[i].contains(key) {
                        guard let r = lines[i].range(of: word) else { continue }
                        let rest = lines[i][r.upperBound...]
                        if !(rest.hasPrefix(" [[?]]") || rest.hasPrefix("[[?]]")) { lines[i].insert(contentsOf: " [[?]]", at: r.upperBound) }
                        break search
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 紀錄表頭那一行；什麼都沒有＝nil
    public static func headerLine(applied: [(fix: Fix, count: Int)], unsure: [Fix]) -> String? {
        guard !applied.isEmpty || !unsure.isEmpty else { return nil }
        func list(_ xs: [String]) -> String { xs.prefix(6).joined(separator: "、") + (xs.count > 6 ? "…等 \(xs.count) 組" : "") }
        var parts: [String] = []
        if !applied.isEmpty {
            let total = applied.reduce(0) { $0 + $1.count }
            parts.append("逐字稿照名冊改了 \(total) 處（" + list(applied.map { "\($0.fix.heard)→\($0.fix.name)" + ($0.count > 1 ? " ×\($0.count)" : "") }) + "）")
        }
        if !unsure.isEmpty {
            // 全列不截：記憶同步從這一段出「要確認」的題目（NameLedger.questions(fromRecord:)），截掉的就問不到
            parts.append("沒改：" + unsure.map { "\($0.heard)→\($0.name)？" }.joined(separator: "、") + "（沒把握，或名冊、逐字稿對不上；紀錄裡提到的地方標了 [[?]]）")
        }
        return "> 名字更正：" + parts.joined(separator: "；")
    }

    /// 待辦跟 OPEN.md 裡別場還沒完成的是同一條（事項一字不差、負責人與期限沒有新的）＝不再開一條
    public static func dropRepeatedTodos(_ notes: String, open: [String]) -> String {
        let known = open.map { row -> (item: String, owner: String, due: String) in
            let c = row.components(separatedBy: "｜")
            return (c[0], c.count > 1 ? c[1] : "", c.count > 2 ? c[2] : "")
        }
        guard !known.isEmpty else { return notes }
        var inTodo = false
        return notes.components(separatedBy: "\n").filter { line in
            if line.hasPrefix("## ") { inTodo = line.contains("待辦") }
            guard inTodo, line.hasPrefix("- [ ] ") else { return true }
            let c = String(line.dropFirst(6)).components(separatedBy: "｜").map { $0.trimmingCharacters(in: .whitespaces) }
            let owner = c.count > 1 ? c[1] : "", due = c.count > 2 ? c[2] : ""
            return !known.contains { $0.item == c[0] && (owner.isEmpty || owner == $0.owner) && (due.isEmpty || due == $0.due) }
        }.joined(separator: "\n")
    }
}
