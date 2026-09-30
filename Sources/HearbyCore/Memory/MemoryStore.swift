// MemoryStore — ~/Hearby/memory/ 五檔＋index.json（機械層：純字串，不過模型）
//
// 寫入紀律（不可協商）：
//   1. 使用者改過的行不動——只換 Hearby 自己寫、之後沒人動過的行；使用者打勾、改寫、刪掉的都照使用者的
//   2. 一場一份：同一場（同 id）再寫＝同步成紀錄現在的樣子，不重複追加
//   3. 改到或拿掉既有的行之前，先把原檔複製成 <檔名>.bak-<日期>（不覆寫舊備份、不刪檔）；只在後面多加行不備份
//   4. 髒東西不進記憶——幻聽已在逐字稿層濾掉；這裡只搬紀錄檔裡結構化的節
//
// 怎麼認「Hearby 寫的、沒人動過」：memory/.hearby-written.json 記著每一場上一次算出來的行；
// 檔裡的行跟那份（或跟這次算出來的）一字不差＝Hearby 的，對不上＝有人改過。
// 那份記錄出現之前就寫進記憶的場，改拿這場紀錄找得到的每個版本（_舊版N.md、.md.bak-*、現在的 md）重算來認。
// 為什麼記整行、不在檔裡加標記：人和 AI 讀的檔保持乾淨；紀錄在別的編輯器直接改掉、沒留舊版也認得出；出事時打開就看得懂（雜湊做不到）。
import Foundation

public enum MemoryStore {
    public static let files = ["PEOPLE.md", "MEETINGS.md", "THREADS.md", "OPEN.md", "GLOSSARY.md"]
    /// 每一場上一次算出來、寫進記憶的行（認「哪幾行是 Hearby 寫的」用；不是給人或 AI 讀的）
    public static let writtenBook = ".hearby-written.json"

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

    // MARK: 同步

    /// 一次同步的結果（命令列印給人看）
    public struct SyncReport {
        public var id = ""
        /// 這一場第一次寫進記憶
        public var isNew = false
        /// 動到的檔
        public var changed: [String] = []
        /// 這一場裡使用者自己改過或加的行（照舊留著）
        public var kept = 0
        /// 這次留的備份
        public var backups: [URL] = []
    }

    /// 這一場寫進記憶：第一次＝追加；寫過了＝同步成紀錄現在的樣子。記憶關著、或不是一場的主紀錄＝不動、回 nil
    @discardableResult
    public static func sync(mdURL: URL) throws -> SyncReport? {
        guard ConfigStore.shared.current.memoryEnabled else { return nil }
        return try sync(mdURL: mdURL, backups: Backups())
    }

    /// 一次同步好幾場（--memory-rebuild 全部）：同一個檔這一輪只備份一次；一場出錯不擋其他場
    public static func sync(_ urls: [URL]) -> [(url: URL, report: SyncReport?, error: String?)] {
        guard ConfigStore.shared.current.memoryEnabled else { return [] }
        let b = Backups()
        return urls.map { u in
            do { return (u, try sync(mdURL: u, backups: b), nil) } catch { return (u, nil, error.localizedDescription) }
        }
    }

    /// 進記憶的只有每場的主紀錄：翻譯（<名>.en.md…）、覆寫前的舊版（_舊版N.md）不算
    public static func isMainRecord(_ u: URL) -> Bool {
        let n = u.lastPathComponent
        return u.pathExtension.lowercased() == "md" && !n.hasPrefix(".") && !n.contains("_舊版") && DocLabels.language(of: u) == "zh"
    }

    /// 會議/ 底下每一場的主紀錄（<夾名>.md；沒有就夾裡唯一一份主紀錄），依夾名排（日期在前＝舊的先）
    public static func allRecords() -> [URL] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.meetings, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for d in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let named = d.appendingPathComponent(d.lastPathComponent + ".md")
            if fm.fileExists(atPath: named.path) { out.append(named); continue }
            let mains = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).filter(isMainRecord)
            if mains.count == 1 { out.append(mains[0]) }
        }
        return out
    }

    static func sync(mdURL: URL, backups: Backups) throws -> SyncReport? {
        guard isMainRecord(mdURL) else { HearbyLog.write("memory: \(mdURL.lastPathComponent) 不是一場的主紀錄，略過"); return nil }
        try ensure()
        guard let md = try? String(contentsOf: mdURL, encoding: .utf8) else { return nil }
        let id = mdURL.deletingPathExtension().lastPathComponent
        let madeBefore = backups.made.count
        let now = entry(md: md, id: id)
        var report = SyncReport()
        report.id = id

        var idx = loadIndex()
        var rows = idx["meetings"] as? [[String: Any]] ?? []
        let row = rows.firstIndex { ($0["id"] as? String) == id }
        report.isNew = row == nil

        let texts = ["MEETINGS.md", "OPEN.md", "PEOPLE.md"].map { readText(url($0)) }

        // 上一次寫出去的（written）、認得出是 Hearby 寫的（owned）：有記錄照記錄，沒有就拿紀錄的每個版本重算
        var book = loadBook()
        var bookMeetings = book["meetings"] as? [String: Any] ?? [:]
        let known = bookMeetings[id] as? [String: Any] ?? [:]
        var written = Lines(), owned = Lines()
        if known["MEETINGS.md"] == nil || known["OPEN.md"] == nil || known["PEOPLE.md"] == nil {
            let olds = (olderVersions(of: mdURL) + [md]).map { entry(md: $0, id: id) }   // 舊的在前
            let rowPeople = row.flatMap { rows[$0]["people"] as? [String] } ?? []
            let rowTitle = row.flatMap { rows[$0]["title"] as? String } ?? ""
            let wasWritten = row != nil || (texts[0].map { blockRange(in: $0.components(separatedBy: "\n"), id: id) != nil } ?? false)
            if wasWritten, let first = olds.first {
                written = Lines(meetings: first.meetings, open: openLines(first, id: id, before: []), names: row != nil ? names(of: rowPeople) : first.names)
            }
            for e in olds { owned.meetings += e.meetings; owned.open += openLines(e, id: id, before: []); owned.names += e.names }
            if !rowPeople.isEmpty { owned.meetings.append("- 與會：\(rowPeople.joined(separator: "、"))"); owned.names += names(of: rowPeople) }
            if !rowTitle.isEmpty { owned.meetings.append("- 標題：\(rowTitle)") }
        }
        if let w = known["MEETINGS.md"] as? [String] { written.meetings = w; owned.meetings = w }
        if let w = known["OPEN.md"] as? [String] { written.open = w; owned.open = w }
        if let w = known["PEOPLE.md"] as? [String] { written.names = w; owned.names = w }
        let fresh = Lines(meetings: now.meetings, open: openLines(now, id: id, before: written.open), names: now.names)
        owned.meetings += fresh.meetings; owned.open += fresh.open; owned.names += fresh.names

        var entryBook = known
        if let t = texts[0] {
            let m = mergeMeetings(t, id: id, fresh: fresh.meetings, owned: Set(owned.meetings), written: written.meetings)
            report.kept += m.kept
            if try save(m.text, over: t, to: url("MEETINGS.md"), touched: m.touched, backups: backups) { report.changed.append("MEETINGS.md") }
            entryBook["MEETINGS.md"] = fresh.meetings
        }
        if let t = texts[1] {
            let m = mergeOpen(t, id: id, fresh: fresh.open, owned: Set(owned.open), written: written.open)
            report.kept += m.kept
            if try save(m.text, over: t, to: url("OPEN.md"), touched: m.touched, backups: backups) { report.changed.append("OPEN.md") }
            entryBook["OPEN.md"] = fresh.open
            // 紀錄「之前的事」寫做完的：別場那一條打勾（改到既有的行，先備份）
            let ticked = FollowUps.tick(open: m.text, done: FollowUps.doneItems(md), meeting: id)
            if ticked != m.text, try save(ticked, over: m.text, to: url("OPEN.md"), touched: true, backups: backups), !report.changed.contains("OPEN.md") {
                report.changed.append("OPEN.md")
            }
        }
        if let t = texts[2] {
            let m = mergePeople(t, id: id, names: fresh.names, owned: unique(owned.names), written: written.names)
            if try save(m.text, over: t, to: url("PEOPLE.md"), touched: m.touched, backups: backups) { report.changed.append("PEOPLE.md") }
            entryBook["PEOPLE.md"] = fresh.names
        }

        // index.json：新的一場加一筆；已經有了只更新 people／title
        if let r = row {
            var x = rows[r]
            if (x["people"] as? [String] ?? []) != now.people || (x["title"] as? String ?? "") != now.title {
                x["people"] = now.people
                x["title"] = now.title
                rows[r] = x
                try backups.before(url("index.json"))
                idx["meetings"] = rows
                try saveJSON(idx, to: url("index.json"))
                report.changed.append("index.json")
            }
        } else {
            rows.append(["id": id, "title": now.title, "date": now.date, "seconds": now.seconds, "path": "會議/\(id)/\(id).md", "people": now.people])
            idx["meetings"] = rows
            try saveJSON(idx, to: url("index.json"))
            report.changed.append("index.json")
        }

        if !((bookMeetings[id] as? NSDictionary)?.isEqual(to: entryBook) ?? false) {
            bookMeetings[id] = entryBook
            book["meetings"] = bookMeetings
            book["schemaVersion"] = 1
            try saveJSON(book, to: url(writtenBook))
        }
        report.backups = Array(backups.made[madeBefore...])
        HearbyLog.write("memory: \(report.isNew ? "appended" : "synced") \(id) changed=\(report.changed.joined(separator: ",")) kept=\(report.kept)")
        NameLedger.afterSync(mdURL: mdURL, md: md)   // 記下這一版（--memory-rebuild 找得到改之前那一版）、AI 沒把握的名字進「要確認」
        return report
    }

    // MARK: 改名

    /// 認得的每一場 id：index.json 的、會議/ 底下的夾名與主紀錄檔名
    static func knownIDs() -> [String] {
        var s: [String] = []
        for r in loadIndex()["meetings"] as? [[String: Any]] ?? [] { if let i = r["id"] as? String { s.append(i) } }
        for d in ((try? FileManager.default.contentsOfDirectory(atPath: Paths.meetings.path)) ?? []).sorted() where !d.hasPrefix(".") { s.append(d) }
        for u in allRecords() { s.append(u.deletingPathExtension().lastPathComponent) }
        return unique(s)
    }

    /// 一場改了名字（id 換了）：記憶裡用到舊 id 的地方都換成新的——每個記憶檔（memory/ 底下的 .md：MEETINGS 的「## id」與
    /// 「- 紀錄：」、OPEN 的待辦尾欄與「<!-- id -->」、PEOPLE 的「- 出席：」、THREADS／NAMES／STATE… 裡提到這場的）、index.json 的
    /// id 與 path、Hearby 自己的兩份記錄（.hearby-written.json、.hearby-names.json）。改到的記憶檔先留 .bak-日期。回傳動到的檔
    static func renameMeeting(from old: String, to new: String, backups: Backups) throws -> [String] {
        guard old != new, !old.isEmpty else { return [] }
        let fm = FileManager.default
        let longer = knownIDs().filter { $0 != new && $0.count > old.count && $0.hasPrefix(old) }
        var changed: [String] = []
        for f in ((try? fm.contentsOfDirectory(atPath: Paths.memory.path)) ?? []).sorted() where f.hasSuffix(".md") && !f.hasPrefix(".") {
            let u = url(f)
            guard let t = try? String(contentsOf: u, encoding: .utf8) else { continue }
            let r = replacingID(t, old: old, new: new, longer: longer)
            guard r != t else { continue }
            try backups.before(u)
            try r.write(to: u, atomically: true, encoding: .utf8)
            changed.append(f)
        }
        var idx = loadIndex()
        if var rows = idx["meetings"] as? [[String: Any]], let i = rows.firstIndex(where: { ($0["id"] as? String) == old }) {
            rows[i]["id"] = new
            rows[i]["path"] = "會議/\(new)/\(new).md"
            idx["meetings"] = rows
            try backups.before(url("index.json"))
            try saveJSON(idx, to: url("index.json"))
            changed.append("index.json")
        }
        var book = loadBook()
        if var ms = book["meetings"] as? [String: Any], let e = ms[old] as? [String: Any] {
            var moved: [String: Any] = [:]
            for (k, v) in e { moved[k] = (v as? [String]).map { $0.map { replacingID($0, old: old, new: new, longer: longer) } } ?? v }
            ms[old] = nil
            ms[new] = moved
            book["meetings"] = ms
            try saveJSON(book, to: url(writtenBook))
        }
        NameLedger.renameMeeting(from: old, to: new)
        return changed
    }

    /// 文字裡的舊 id 換成新的：只換整個 id——後面接著「-數字」（同一分鐘的另一場）、或其實是別場更長的 id 的開頭，不換
    static func replacingID(_ text: String, old: String, new: String, longer: [String]) -> String {
        guard !old.isEmpty, text.contains(old) else { return text }
        var out = ""
        var i = text.startIndex
        while let r = text.range(of: old, options: .literal, range: i..<text.endIndex) {
            out += text[i..<r.lowerBound]
            let after = text[r.upperBound...]
            let numbered = after.hasPrefix("-") && (after.dropFirst().first.map { $0.isASCII && $0.isNumber } ?? false)
            let other = longer.contains { text[r.lowerBound...].hasPrefix($0) }
            out += numbered || other ? old : new
            i = r.upperBound
        }
        out += text[i...]
        return out
    }

    // MARK: 一場該寫的行（全由紀錄 md 算出來）

    struct Entry {
        var meetings: [String] = []
        var todos: [(item: String, owner: String, due: String, done: Bool)] = []
        /// index.json 的 people（紀錄「與會者」原樣）
        var people: [String] = []
        /// PEOPLE.md 記出席的名字
        var names: [String] = []
        var title = ""
        var date = ""
        var seconds = 0.0
    }

    struct Lines {
        var meetings: [String] = []
        var open: [String] = []
        var names: [String] = []
    }

    static func entry(md: String, id: String) -> Entry {
        let rec = RecordMD.parse(md: md)
        let parts = rec.parts
        var e = Entry()
        e.people = rec.people
        e.names = names(of: rec.people)
        e.todos = rec.todos
        e.title = parts.custom
        e.date = parts.date
        e.seconds = parseDur(parts.dur)
        if !parts.custom.isEmpty { e.meetings.append("- 標題：\(parts.custom)") }
        e.meetings.append("- 日期：\(parts.date)　時長：\(parts.dur)")
        if !rec.people.isEmpty { e.meetings.append("- 與會：\(rec.people.joined(separator: "、"))") }
        let summary = rec.summaryText
        if !summary.isEmpty, !summary.hasPrefix("（") { e.meetings.append("- 摘要：\(summary)") }
        for d in rec.section("決議") ?? [] where d != "無明確決議" { e.meetings.append("- 決議：\(strip(d))") }
        e.meetings.append("- 紀錄：會議/\(id)/\(id).md")
        return e
    }

    /// 「王小明（Ming）」→「王小明」；空的不要、重複的只留一個
    static func names(of people: [String]) -> [String] {
        var out: [String] = []
        for p in people {
            let n = p.replacingOccurrences(of: #"（[^）]*）"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if !n.isEmpty, !out.contains(n) { out.append(n) }
        }
        return out
    }

    /// OPEN.md 的行：沒完成的都寫；完成的只在「之前以沒完成寫過」時寫成打勾（把完成帶過來，不是多一條）
    static func openLines(_ e: Entry, id: String, before: [String]) -> [String] {
        let had = Set(before.compactMap(todoItem))
        return e.todos.filter { !$0.done || had.contains($0.item) }.map { "- [\($0.done ? "x" : " ")] \($0.item)｜\($0.owner)｜\($0.due)｜\(id)" }
    }

    /// 「- [ ] 事項｜負責人｜期限｜會議id」→「事項」；不是待辦行＝nil
    static func todoItem(_ line: String) -> String? {
        for p in ["- [ ] ", "- [x] ", "- [X] "] where line.hasPrefix(p) {
            return String(line.dropFirst(p.count)).components(separatedBy: "｜")[0].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// 待辦行最後一欄（會議 id）
    static func todoMeeting(_ line: String) -> String {
        (line.components(separatedBy: "｜").last ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// MEETINGS.md 一行佔的位子：標題／日期／與會／摘要／紀錄一場各一行，決議與其他行以整行為準
    static func meetingKey(_ line: String) -> String {
        for k in ["- 標題：", "- 日期：", "- 與會：", "- 摘要：", "- 紀錄："] where line.hasPrefix(k) { return k }
        return line
    }

    // MARK: 三個檔各自怎麼換

    /// MEETINGS.md 裡「## id」那一塊：(標題行, 內容結束的下一行)；內容尾巴的空行不算
    static func blockRange(in lines: [String], id: String) -> (Int, Int)? {
        guard let h = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## \(id)" }) else { return nil }
        var e = lines[(h + 1)...].firstIndex(where: { $0.hasPrefix("## ") || $0.hasPrefix("# ") }) ?? lines.count
        while e > h + 1, lines[e - 1].trimmingCharacters(in: .whitespaces).isEmpty { e -= 1 }
        return (h, e)
    }

    /// MEETINGS.md 這一場的區塊：Hearby 的行換成新版；使用者改寫過或拿掉的那一格（標題、與會、摘要…；決議看整行）不補新版
    static func mergeMeetings(_ text: String, id: String, fresh: [String], owned: Set<String>, written: [String]) -> Merged {
        let lines = text.components(separatedBy: "\n")
        guard let (h, e) = blockRange(in: lines, id: id) else {
            // 這場還沒有區塊（第一次寫，或整塊被拿掉）：接在檔尾
            return Merged(text: text + "\n## \(id)\n" + fresh.joined(separator: "\n") + "\n")
        }
        let body = Array((h + 1)..<e)
        let slots = body.filter { owned.contains(lines[$0]) }
        let users = body.filter { !owned.contains(lines[$0]) }
        let present = Set(body.map { lines[$0] })
        let ownedKeys = Set(slots.map { meetingKey(lines[$0]) })
        var drop = Set(users.map { meetingKey(lines[$0]) })
        for w in written where !present.contains(w) && !ownedKeys.contains(meetingKey(w)) { drop.insert(meetingKey(w)) }
        let kept = users.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }.count
        let r = refill(lines, slots: slots, fresh: fresh.filter { !drop.contains(meetingKey($0)) }, fallback: e)
        return Merged(text: r.lines.joined(separator: "\n"), kept: kept, touched: r.replaced)
    }

    /// OPEN.md 這一場的待辦（行尾是這場 id）：Hearby 寫的、沒打勾沒改過的換成新版；使用者打勾、改寫、刪掉的那一條不補新版
    static func mergeOpen(_ text: String, id: String, fresh: [String], owned: Set<String>, written: [String]) -> Merged {
        let lines = text.components(separatedBy: "\n")
        let marker = "<!-- \(id) -->"
        let mine = lines.indices.filter { todoItem(lines[$0]) != nil && todoMeeting(lines[$0]) == id }
        let markerAt = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == marker }
        guard markerAt != nil || !mine.isEmpty else {
            // 這場在 OPEN 一點痕跡都沒有（第一次寫，或整份重來）：接在檔尾
            return Merged(text: fresh.isEmpty ? text : text + "\n\(marker)\n" + fresh.joined(separator: "\n") + "\n")
        }
        let slots = lines.indices.filter { owned.contains(lines[$0]) }
        let users = mine.filter { !owned.contains(lines[$0]) }
        let present = Set(lines)
        let ownedItems = Set(slots.compactMap { todoItem(lines[$0]) })
        var drop = Set(users.compactMap { todoItem(lines[$0]) })
        for w in written where !present.contains(w) { if let it = todoItem(w), !ownedItems.contains(it) { drop.insert(it) } }
        // 沒有一條可換時，新的插在這場標記那一段的尾巴（沒有標記＝這場最後一條後面）
        var fallback = lines.last == "" ? lines.count - 1 : lines.count
        if let m = markerAt {
            fallback = lines[(m + 1)...].firstIndex { l in
                let t = l.trimmingCharacters(in: .whitespaces)
                return t.isEmpty || t.hasPrefix("<!--") || t.hasPrefix("#")
            } ?? lines.count
        } else if let last = mine.last { fallback = last + 1 }
        let r = refill(lines, slots: slots, fresh: fresh.filter { !drop.contains(todoItem($0) ?? "") }, fallback: fallback)
        return Merged(text: r.lines.joined(separator: "\n"), kept: users.count, touched: r.replaced)
    }

    /// PEOPLE.md 裡「## 名字」那一節：(標題行, 下一個標題)
    static func section(in lines: [String], name: String) -> (Int, Int)? {
        guard let h = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## \(name)" }) else { return nil }
        return (h, lines[(h + 1)...].firstIndex(where: { $0.hasPrefix("## ") || $0.hasPrefix("# ") }) ?? lines.count)
    }

    /// PEOPLE.md：這一場的出席（- 出席：id）跟著紀錄的與會者走。不在名單的拿掉那一行（那一節因此只剩標題才連標題拿掉）；
    /// 新名字接在那人那一節的尾巴，沒有那一節就在檔尾開一節。寫過、後來被使用者拿掉的不補回去
    static func mergePeople(_ text: String, id: String, names: [String], owned: [String], written: [String]) -> Merged {
        let attend = "- 出席：\(id)"
        var lines = text.components(separatedBy: "\n")
        let hadTrace = lines.contains(attend)
        var touched = false
        for n in owned where !names.contains(n) {
            guard let (h, e) = section(in: lines, name: n), let a = lines[(h + 1)..<e].firstIndex(of: attend) else { continue }
            lines.remove(at: a)
            touched = true
            if lines[(h + 1)..<(e - 1)].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let from = h > 0 && lines[h - 1].trimmingCharacters(in: .whitespaces).isEmpty ? h - 1 : h
                lines.removeSubrange(from...h)
            }
        }
        for n in names {
            if let (h, e) = section(in: lines, name: n) {
                if lines[(h + 1)..<e].contains(attend) || (hadTrace && written.contains(n)) { continue }
                var at = e
                while at > h + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
                lines.insert(attend, at: at)
            } else if !(hadTrace && written.contains(n)) {
                lines = (lines.joined(separator: "\n") + "\n## \(n)\n\(attend)\n").components(separatedBy: "\n")
            }
        }
        return Merged(text: lines.joined(separator: "\n"), touched: touched)
    }

    /// 一個檔換完的樣子：kept＝這一場裡使用者自己的行（照舊留著）；touched＝有沒有換掉或拿掉既有的行（有＝寫之前要備份）
    struct Merged {
        var text: String
        var kept = 0
        var touched = false
    }

    /// 換行：slots 是 Hearby 的行（依檔案順序）。還在新版裡的原地留著；空出來的位子依序放新的行，放不下的接在
    /// 「新版裡排它前面、已經放好的那一行」後面；多的位子拿掉。一個位子都沒有＝全部插在 fallback。其他行不動
    static func refill(_ lines: [String], slots: [Int], fresh: [String], fallback: Int) -> (lines: [String], replaced: Bool) {
        if slots.isEmpty {
            var out = lines
            out.insert(contentsOf: fresh, at: fallback)
            return (out, false)
        }
        var used = [Bool](repeating: false, count: fresh.count)
        var at: [Int: Int] = [:]
        for s in slots {
            if let f = fresh.indices.first(where: { !used[$0] && fresh[$0] == lines[s] }) { at[s] = f; used[f] = true }
        }
        let replaced = slots.contains { at[$0] == nil }
        var waiting = fresh.indices.filter { !used[$0] }
        for s in slots where at[s] == nil && !waiting.isEmpty { at[s] = waiting.removeFirst() }
        let slotSet = Set(slots)
        var out: [(line: String, f: Int?)] = []
        var firstSlot = 0
        for (i, l) in lines.enumerated() {
            if i == slots[0] { firstSlot = out.count }
            if !slotSet.contains(i) { out.append((l, nil)) } else if let f = at[i] { out.append((fresh[f], f)) }
        }
        for f in waiting {
            if let p = out.indices.filter({ (out[$0].f ?? Int.max) < f }).max(by: { out[$0].f! < out[$1].f! }) {
                out.insert((fresh[f], f), at: p + 1)
            } else if let n = out.indices.filter({ (out[$0].f ?? -1) > f }).min(by: { out[$0].f! < out[$1].f! }) {
                out.insert((fresh[f], f), at: n)
            } else {
                out.insert((fresh[f], f), at: firstSlot)
                firstSlot += 1
            }
        }
        return (out.map(\.line), replaced)
    }

    // MARK: 讀寫

    /// 讀一個記憶檔（換行統一成 \n）；檔案在卻讀不成 UTF-8＝nil，這次不動它（當成空的寫回會把整份洗掉）
    static func readText(_ u: URL) -> String? {
        guard FileManager.default.fileExists(atPath: u.path) else { return "" }
        guard let s = try? String(contentsOf: u, encoding: .utf8) else {
            HearbyLog.write("memory: \(u.lastPathComponent) 讀不到（不是 UTF-8？），這次不動它")
            return nil
        }
        return s.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// 寫回一個記憶檔：沒變＝不寫；換掉或拿掉既有的行＝先備份再整份換；只多了行＝不備份（檔尾多的就接在後面）
    static func save(_ new: String, over old: String, to u: URL, touched: Bool, backups: Backups) throws -> Bool {
        guard new != old else { return false }
        if touched { try backups.before(u) }
        else if new.hasPrefix(old) {
            try appendText(String(new.dropFirst(old.count)), to: u)
            return true
        }
        try new.write(to: u, atomically: true, encoding: .utf8)
        return true
    }

    /// 這場紀錄覆寫前留下的舊版（<名>_舊版N.md、<名>.md.bak-*），舊的在前（照修改時間）
    static func olderVersions(of mdURL: URL) -> [String] {
        let fm = FileManager.default
        let dir = mdURL.deletingLastPathComponent()
        let base = mdURL.deletingPathExtension().lastPathComponent
        guard let all = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        func modified(_ n: String) -> Date {
            let attrs = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(n).path)
            return attrs?[.modificationDate] as? Date ?? .distantPast
        }
        let olds: [(name: String, date: Date)] = all
            .filter { ($0.hasPrefix(base + "_舊版") && $0.hasSuffix(".md")) || $0.hasPrefix(base + ".md.bak") }
            .map { ($0, modified($0)) }
            .sorted { $0.date != $1.date ? $0.date < $1.date : $0.name < $1.name }
        return olds.compactMap { try? String(contentsOf: dir.appendingPathComponent($0.name), encoding: .utf8) }
    }

    static func loadBook() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: url(writtenBook)))) as? [String: Any] ?? ["schemaVersion": 1, "meetings": [String: Any]()]
    }

    static func saveJSON(_ obj: [String: Any], to u: URL) throws {
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try d.write(to: u, options: .atomic)
    }

    static func unique(_ a: [String]) -> [String] {
        var out: [String] = []
        for x in a where !out.contains(x) { out.append(x) }
        return out
    }

    /// 備份：同一次動作裡每個檔最多一份——<檔名>.bak-<日期>，已經有了就 -2、-3…（不覆寫、不刪）
    final class Backups {
        private(set) var made: [URL] = []
        private var seen: Set<String> = []
        let day: String

        init(now: Date = Date()) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"
            day = f.string(from: now)
        }

        func before(_ u: URL) throws {
            guard !seen.contains(u.path) else { return }
            seen.insert(u.path)
            let fm = FileManager.default
            guard fm.fileExists(atPath: u.path) else { return }
            let dir = u.deletingLastPathComponent()
            var bak = dir.appendingPathComponent("\(u.lastPathComponent).bak-\(day)")
            var k = 2
            while fm.fileExists(atPath: bak.path) { bak = dir.appendingPathComponent("\(u.lastPathComponent).bak-\(day)-\(k)"); k += 1 }
            try fm.copyItem(at: u, to: bak)
            made.append(bak)
        }
    }

    // MARK: 其他

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
