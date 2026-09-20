// MemoryStore — ~/Hearby/memory/ 五檔＋index.json（機械層：開完會當下純字串追加，不過模型）
//
// 三條寫入紀律（additive，不可協商）：
//   1. 永不覆蓋使用者改過的行——只在檔尾或對應段落尾追加，從不重寫既有行
//   2. 寫入前先看——同一場（同 id）已經寫過就不再寫
//   3. 髒東西不進記憶——幻聽已在逐字稿層濾掉；這裡只搬紀錄檔裡結構化的節
import Foundation

public enum MemoryStore {
    public static let files = ["PEOPLE.md", "MEETINGS.md", "THREADS.md", "OPEN.md", "GLOSSARY.md"]

    static func url(_ name: String) -> URL { Paths.memory.appendingPathComponent(name) }

    /// 建齊五檔＋index.json（冪等）
    public static func ensure() throws {
        try FileManager.default.createDirectory(at: Paths.memory, withIntermediateDirectories: true)
        let heads: [String: String] = [
            "PEOPLE.md": "# 人（誰是誰、怎麼稱呼、出席過哪些會）\n\n<!-- 每人一節：## 名字 ／ - 別名：… ／ - 單位：… ／ - 出席：會議 id -->\n",
            "MEETINGS.md": "# 會議（每場一段：摘要、決議；完整紀錄在 會議/ 資料夾）\n",
            "THREADS.md": "# 議題（跨會議在談的事；跟 AI 討論完的新決定寫回這裡）\n",
            "OPEN.md": "# 還沒完成的事（開完會自動搬進來；完成就打勾）\n",
            "GLOSSARY.md": "# 專有名詞與別名（正名 = 別名1, 別名2；下一場聽打後自動改正）\n",
        ]
        for f in files {
            let u = url(f)
            if !FileManager.default.fileExists(atPath: u.path) { try heads[f]!.write(to: u, atomically: true, encoding: .utf8) }
        }
        let idx = url("index.json")
        if !FileManager.default.fileExists(atPath: idx.path) {
            let d = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "meetings": [], "consumers": []], options: [.prettyPrinted, .sortedKeys])
            try d.write(to: idx)
        }
    }

    static func loadIndex() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: url("index.json")))) as? [String: Any] ?? ["schemaVersion": 1, "meetings": [], "consumers": []]
    }

    /// 開完會當下：MEETINGS 追加一段、OPEN 搬待辦、PEOPLE 補出席、index.json 加一筆。同 id 不重寫。
    public static func appendMeeting(mdURL: URL) throws {
        guard ConfigStore.shared.current.memoryEnabled else { return }
        try ensure()
        guard let md = try? String(contentsOf: mdURL, encoding: .utf8) else { return }
        let rec = RecordMD.parse(md: md)
        let id = mdURL.deletingPathExtension().lastPathComponent
        var idx = loadIndex()
        var meetings = idx["meetings"] as? [[String: Any]] ?? []
        if meetings.contains(where: { ($0["id"] as? String) == id }) {
            // 已寫過：只更新 index 的 people／title（紀錄可能重整理過）
            HearbyLog.write("memory: \(id) 已在索引，略過追加")
            return
        }
        let parts = rec.parts
        let people = rec.people
        let secs = parseDur(parts.dur)

        // MEETINGS.md
        var block = "\n## \(id)\n"
        if !parts.custom.isEmpty { block += "- 標題：\(parts.custom)\n" }
        block += "- 日期：\(parts.date)　時長：\(parts.dur)\n"
        if !people.isEmpty { block += "- 與會：\(people.joined(separator: "、"))\n" }
        let summary = rec.summaryText
        if !summary.isEmpty, !summary.hasPrefix("（") { block += "- 摘要：\(summary)\n" }
        for d in rec.section("決議") ?? [] where d != "無明確決議" { block += "- 決議：\(strip(d))\n" }
        block += "- 紀錄：會議/\(id)/\(id).md\n"
        try appendText(block, to: url("MEETINGS.md"))

        // OPEN.md
        let open = rec.todos.filter { !$0.done }
        if !open.isEmpty {
            var t = "\n<!-- \(id) -->\n"
            for o in open { t += "- [ ] \(o.item)｜\(o.owner)｜\(o.due)｜\(id)\n" }
            try appendText(t, to: url("OPEN.md"))
        }

        // PEOPLE.md
        if !people.isEmpty {
            let peopleURL = url("PEOPLE.md")
            let existing = try? String(contentsOf: peopleURL, encoding: .utf8)
            // 檔案在、卻讀不成 UTF-8（被別的工具存成別的編碼）＝不動它；當成空字串寫回會把整份洗掉
            let unreadable = existing == nil && FileManager.default.fileExists(atPath: peopleURL.path)
            if unreadable { HearbyLog.write("memory: PEOPLE.md 讀不到（不是 UTF-8？），這次不動它") }
            var s = existing ?? ""
            for p in people {
                let name = p.replacingOccurrences(of: #"（[^）]*）"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                if let r = s.range(of: "\n## \(name)\n") {
                    // 在該節尾（下一個 ## 之前）追加一行出席
                    let after = s[r.upperBound...]
                    let insertAt = after.range(of: "\n## ")?.lowerBound ?? s.endIndex
                    s.insert(contentsOf: "- 出席：\(id)\n", at: insertAt)
                } else {
                    s += "\n## \(name)\n- 出席：\(id)\n"
                }
            }
            if !unreadable { try s.write(to: peopleURL, atomically: true, encoding: .utf8) }
        }

        // index.json
        meetings.append(["id": id, "title": parts.custom, "date": parts.date, "seconds": secs, "path": "會議/\(id)/\(id).md", "people": people])
        idx["meetings"] = meetings
        let d = try JSONSerialization.data(withJSONObject: idx, options: [.prettyPrinted, .sortedKeys])
        try d.write(to: url("index.json"), options: .atomic)
        HearbyLog.write("memory: appended \(id) people=\(people.count) todos=\(open.count)")
    }

    /// 上一場沒完成的事（會前準備卡帶入用）
    public static func openItems(limit: Int = 8) -> [String] {
        guard let s = try? String(contentsOf: url("OPEN.md"), encoding: .utf8) else { return [] }
        return s.components(separatedBy: "\n").filter { $0.hasPrefix("- [ ] ") }.suffix(limit).map {
            let body = String($0.dropFirst(6))
            let cols = body.components(separatedBy: "｜")
            return cols[0] + (cols.count > 1 && !cols[1].isEmpty ? "（\(cols[1])）" : "")
        }
    }

    static func appendText(_ t: String, to u: URL) throws {
        if let h = try? FileHandle(forWritingTo: u) { defer { try? h.close() }; try h.seekToEnd(); try h.write(contentsOf: Data(t.utf8)) }
        else { try t.write(to: u, atomically: true, encoding: .utf8) }
    }
    static func strip(_ s: String) -> String { s.replacingOccurrences(of: #"\s*\[(?:\d{1,2}:)?\d{1,3}:[0-5]\d\]"#, with: "", options: .regularExpression) }
    static func parseDur(_ s: String) -> Double {
        var secs = 0.0
        if let r = s.range(of: #"(\d+)小時"#, options: .regularExpression) { secs += (Double(s[r].filter(\.isNumber)) ?? 0) * 3600 }
        if let r = s.range(of: #"(\d+)分"#, options: .regularExpression) { secs += (Double(s[r].filter(\.isNumber)) ?? 0) * 60 }
        if let r = s.range(of: #"(\d+)秒"#, options: .regularExpression) { secs += Double(s[r].filter(\.isNumber)) ?? 0 }
        return secs
    }
}
