// Clean — 機械清理（不過模型）：簡轉繁、標點全形、常用詞、別名回灌
import Foundation

public enum Clean {
    /// 簡轉繁（產出絕不出現簡體字）：macOS 內建 ICU 詞典級轉換
    public static func toTraditional(_ s: String) -> String {
        s.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? s
    }

    /// 簡轉繁，但 keep 裡的名字（名冊）照原樣留著：ICU 會把姓氏「涂」當成「塗」的簡體轉掉。
    /// 會被轉到的名字先換成私用區字元、轉完再換回來；keep 是空的＝跟 toTraditional(s) 一樣
    public static func toTraditional(_ s: String, keep: [String]) -> String {
        let risky = Array(keep.filter { !$0.isEmpty && toTraditional($0) != $0 }.sorted { $0.count > $1.count }.prefix(6000))
        guard !risky.isEmpty else { return toTraditional(s) }
        let mark = risky.indices.map { String(Character(UnicodeScalar(0xE000 + $0)!)) }
        var t = s
        for (i, n) in risky.enumerated() { t = t.replacingOccurrences(of: n, with: mark[i]) }
        t = toTraditional(t)
        for (i, n) in risky.enumerated() { t = t.replacingOccurrences(of: mark[i], with: n) }
        return t
    }

    /// 標點全形化：前一字元是 CJK 才替換；句點另需後一字元也是 CJK／空白／行尾
    public static func normalizePunct(_ s: String) -> String {
        let map: [Character: Character] = [",": "，", "!": "！", "?": "？", ";": "；", ":": "："]
        func isCJK(_ c: Character?) -> Bool {
            guard let c, let u = c.unicodeScalars.first else { return false }
            return (0x4E00...0x9FFF).contains(Int(u.value))
        }
        let chars = Array(s)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        for (i, c) in chars.enumerated() {
            let prev = i > 0 ? chars[i - 1] : nil
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if let rep = map[c], isCJK(prev) { out.append(rep) }
            else if c == ".", isCJK(prev), next == nil || next == " " || isCJK(next) { out.append("。") }
            else { out.append(c) }
        }
        return String(out)
    }

    // MARK: 常用詞（glossary.txt，跟姊妹 app 共用一份）

    public static func localGlossary() -> String? {
        guard let s = try? String(contentsOf: SharedPaths.glossary, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func splitTerms(_ s: String) -> [String] {
        let seps: Set<Character> = ["、", ",", "，", "\n"]
        return s.split(whereSeparator: { seps.contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 併進常用詞（去重、附加不覆蓋）；回傳實際新增數
    @discardableResult
    public static func appendGlossary(_ raw: String) -> Int {
        let incoming = splitTerms(raw)
        guard !incoming.isEmpty else { return 0 }
        let url = SharedPaths.glossary
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        // 檔案在、卻讀不成 UTF-8＝不動它（這份常用詞可能跟姊妹 app 共用，當成空的寫回會整份洗掉）
        if existing == nil, FileManager.default.fileExists(atPath: url.path) { return 0 }
        var terms = splitTerms(existing ?? "")
        var added = 0
        for t in incoming where !terms.contains(t) { terms.append(t); added += 1 }
        if added > 0 { try? terms.joined(separator: "、").write(to: url, atomically: true, encoding: .utf8) }
        return added
    }

    public static func seedGlossary() { appendGlossary("Hearby") }

    /// 設定頁「存常用詞」：整份換成畫面上的內容。這份檔可能跟姊妹 app 共用，所以——
    /// ①原檔存在卻讀不成 UTF-8（畫面上那份就是空的）＝不存，免得把整份洗掉；②存之前留一份備份；③寫不進去要回報。
    public static func saveGlossary(_ text: String) throws {
        let url = SharedPaths.glossary
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            guard (try? String(contentsOf: url, encoding: .utf8)) != nil else {
                throw HearbyError("現有的常用詞檔讀不出來（不是 UTF-8 純文字），為了不把它洗掉，這次沒有存。檔案在：\(url.path)")
            }
            // 備份：一天最多一份、檔名帶日期、不刪也不覆寫任何既有備份
            let day = String(Pipeline.stampFormatter.string(from: Date()).prefix(8))
            let bak = url.deletingLastPathComponent().appendingPathComponent("glossary.txt.bak-\(day)")
            if !fm.fileExists(atPath: bak.path) { try? fm.copyItem(at: url, to: bak) }
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: 別名回灌（越用越好用的實體）：讀 memory/PEOPLE.md、GLOSSARY.md 的別名與 NAMES.md 換法「一律」的，純字串替換
    //
    // 格式（兩個檔都認）：
    //   - 別名：Kevien、Kevyn      ← PEOPLE.md 某人段落底下
    //   Kevin = Kevien, Kevyn       ← GLOSSARY.md 一行一組
    // HTML 註解（<!-- … -->）裡的字不算；GLOSSARY.md 的 # 標題行也不算（表頭「正名 = 別名1, 別名2」是寫法說明，不是一組別名）
    public static func aliasTable() -> [(alias: String, canonical: String)] {
        var out: [(String, String)] = []
        let people = Paths.memory.appendingPathComponent("PEOPLE.md")
        if let s = try? String(contentsOf: people, encoding: .utf8) {
            var current: String? = nil
            for raw in stripHTMLComments(s).components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("## ") { current = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces); continue }
                guard let c = current else { continue }
                for key in ["- 別名：", "- 別名:", "- aliases:", "- 別名 "] where line.hasPrefix(key) {
                    for a in splitTerms(String(line.dropFirst(key.count))) where a != c && a.count >= 2 { out.append((a, c)) }
                }
            }
        }
        let gl = Paths.memory.appendingPathComponent("GLOSSARY.md")
        if let s = try? String(contentsOf: gl, encoding: .utf8) {
            for raw in stripHTMLComments(s).components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") { continue }
                guard let eq = line.range(of: " = ") ?? line.range(of: "＝") else { continue }
                let canonical = String(line[..<eq.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "- ")).trimmingCharacters(in: .whitespaces)
                guard !canonical.isEmpty else { continue }
                for a in splitTerms(String(line[eq.upperBound...])) where a != canonical && a.count >= 2 { out.append((a, canonical)) }
            }
        }
        // 名字確認帳（NAMES.md）換法「一律」的：撞名檢查過，聽打完直接換
        if let s = try? String(contentsOf: Paths.memory.appendingPathComponent(NameLedger.file), encoding: .utf8) {
            out += NameLedger.aliasPairs(NameLedger.parse(s).entries)
        }
        return out
    }

    /// 去掉 HTML 註解（<!-- … -->，可以跨行；沒收尾的一路算到檔尾）。註解裡的換行留著，其他行的行號不變；CRLF 當 LF
    static func stripHTMLComments(_ s: String) -> String {
        var rest = Substring(s.replacingOccurrences(of: "\r\n", with: "\n"))
        var out = ""
        while let open = rest.range(of: "<!--") {
            out += rest[..<open.lowerBound]
            let inside = rest[open.upperBound...]
            let close = inside.range(of: "-->")
            let comment = close.map { inside[..<$0.lowerBound] } ?? inside
            out += String(repeating: "\n", count: comment.unicodeScalars.filter { $0 == "\n" }.count)
            rest = close.map { inside[$0.upperBound...] } ?? ""
        }
        return out + rest
    }

    /// 套用別名表（長別名先換，免得短的吃掉長的）
    public static func applyAliases(_ text: String, table: [(alias: String, canonical: String)]? = nil) -> (String, Int) {
        let t = table ?? aliasTable()
        guard !t.isEmpty else { return (text, 0) }
        var s = text
        var n = 0
        for (a, c) in t.sorted(by: { $0.alias.count > $1.alias.count }) where s.contains(a) {
            let parts = s.components(separatedBy: a)
            n += parts.count - 1
            s = parts.joined(separator: c)
        }
        return (s, n)
    }
}
