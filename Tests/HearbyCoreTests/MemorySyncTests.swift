// MemorySyncTests — 紀錄改過（重新整理全篇、自己改、請 AI 改一段）之後，記憶跟著換：只換 Hearby 寫的、沒人動過的行
import Foundation
import XCTest
@testable import HearbyCore

final class MemorySyncTests: XCTestCase {
    var box: URL!
    let id = "2026-09-20_1430_週會"
    var day: String { MemoryStore.Backups().day }

    override func setUp() {
        box = FileManager.default.temporaryDirectory.appendingPathComponent("hearby-memsync-\(UUID().uuidString)")
        setenv("HEARBY_OUTPUT_ROOT", box.appendingPathComponent("root").path, 1)
        setenv("HEARBY_SUPPORT_DIR", box.appendingPathComponent("support").path, 1)
        setenv("HEARBY_LOG_DIR", box.appendingPathComponent("logs").path, 1)
        ConfigStore.shared.reset()
        try? Paths.ensure()
        try? ConfigStore.shared.update { $0.memoryEnabled = true }
        try? MemoryStore.ensure()
        try? "# 人（誰是誰、怎麼稱呼、出席過哪些會）\n\n<!-- 每人一節：## 名字 ／ - 別名：… ／ - 單位：… ／ - 出席：會議 id -->\n\n## 王小明\n- 別名：Ming\n- 單位：產品部\n"
            .write(to: Paths.memory.appendingPathComponent("PEOPLE.md"), atomically: true, encoding: .utf8)
        try? "# 還沒完成的事（開完會自動搬進來；完成就打勾）\n\n<!-- 2026-09-01_0900_舊會 -->\n- [ ] 舊的待辦｜｜｜2026-09-01_0900_舊會\n"
            .write(to: Paths.memory.appendingPathComponent("OPEN.md"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        // 只清自己建的沙箱夾（temporaryDirectory 底下）
        if let b = box, b.path.hasPrefix(FileManager.default.temporaryDirectory.path) { try? FileManager.default.removeItem(at: b) }
        unsetenv("HEARBY_OUTPUT_ROOT"); unsetenv("HEARBY_SUPPORT_DIR"); unsetenv("HEARBY_LOG_DIR")
        ConfigStore.shared.reset()
    }

    // MARK: 素材

    static let v1 = """
        # 會議紀錄 2026-09-20 14:30

        > Hearby 錄音｜時長 12分30秒｜週會

        ## AI 會議摘要
        討論 Windows 版與預算。
        ## 與會者
        - 王小明（Ming） — 主持
        - 李大化 — 報告
        ## 決議
        - 先做骨架版 [00:12]
        - 預算三十萬 [01:05]
        ## 待辦
        - [ ] 準備測試機｜王小明｜明天
        - [ ] 寫官網文案｜李大化｜下週三
        - [ ] 買咖啡｜｜
        - [ ] 整理需求｜李大化｜

        ---

        ## 逐字稿
        - [00:12][我方] 骨架版先做半天
        """

    /// 重新整理後：名字改對、多一位、摘要與決議換了、多一條待辦、準備測試機做完了、標題改了
    static let v2 = """
        # 會議紀錄 2026-09-20 14:30

        > Hearby 錄音｜時長 12分30秒｜週會 Windows 版

        ## AI 會議摘要
        討論 Windows 版、預算與時程。
        ## 與會者
        - 王小明（Ming） — 主持
        - 李大華 — 報告
        - 陳美玲 — 發言
        ## 決議
        - 先做骨架版 [00:12]
        - 預算三十五萬 [01:05]
        - 時程延一週 [02:10]
        ## 待辦
        - [x] 準備測試機｜王小明｜明天
        - [ ] 寫官網文案｜李大華｜下週三
        - [ ] 買咖啡｜｜
        - [ ] 整理需求｜李大華｜
        - [ ] 訂會議室｜陳美玲｜週五

        ---

        ## 逐字稿
        - [00:12][我方] 骨架版先做半天
        """

    var md: URL { Paths.meetings.appendingPathComponent(id).appendingPathComponent(id + ".md") }

    @discardableResult
    func record(_ text: String, id: String? = nil) throws -> URL {
        let i = id ?? self.id
        let dir = Paths.meetings.appendingPathComponent(i)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(i + ".md")
        try text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    func text(_ f: String) throws -> String { try String(contentsOf: Paths.memory.appendingPathComponent(f), encoding: .utf8) }
    func put(_ f: String, _ t: String) throws { try t.write(to: Paths.memory.appendingPathComponent(f), atomically: true, encoding: .utf8) }
    func edit(_ f: String, _ pairs: [(String, String)]) throws {
        var t = try text(f)
        for (a, b) in pairs { XCTAssertTrue(t.contains(a), "找不到要改的：\(a)"); t = t.replacingOccurrences(of: a, with: b) }
        try put(f, t)
    }
    func block(_ id: String) throws -> [String] {
        let lines = try text("MEETINGS.md").components(separatedBy: "\n")
        guard let (h, e) = MemoryStore.blockRange(in: lines, id: id) else { return [] }
        return Array(lines[h..<e])
    }
    func openLines(_ id: String) throws -> [String] {
        try text("OPEN.md").components(separatedBy: "\n").filter { $0.hasSuffix("｜\(id)") }
    }
    func indexRow(_ id: String) throws -> [String: Any]? {
        let idx = try JSONSerialization.jsonObject(with: Data(contentsOf: Paths.memory.appendingPathComponent("index.json"))) as? [String: Any]
        return (idx?["meetings"] as? [[String: Any]])?.first { ($0["id"] as? String) == id }
    }
    func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: Paths.memory.path).filter { $0.contains(".bak-") }.sorted()
    }
    /// 「重新整理全篇」存檔前那一步：原檔留成 _舊版N.md（放舊一點的修改時間，跟真的一樣早於新版）
    func keepOldVersion() {
        RecordMD.backupIfExists(md)
        let old = md.deletingLastPathComponent().appendingPathComponent(id + "_舊版1.md")
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)
    }
    /// 模擬這份記錄出現之前就寫好的記憶（舊版 Hearby 寫的）
    func forgetBook() throws { try put(MemoryStore.writtenBook, "{\"schemaVersion\":1,\"meetings\":{}}") }

    // MARK: 第一次寫＝跟以前一樣追加

    func testFirstSyncAppendsLikeBefore() throws {
        try record(Self.v1)
        let r = try XCTUnwrap(MemoryStore.sync(mdURL: md))
        XCTAssertTrue(r.isNew)
        XCTAssertEqual(try block(id), [
            "## \(id)", "- 標題：週會", "- 日期：2026-09-20 14:30　時長：12分30秒", "- 與會：王小明（Ming）、李大化",
            "- 摘要：討論 Windows 版與預算。", "- 決議：先做骨架版", "- 決議：預算三十萬", "- 紀錄：會議/\(id)/\(id).md",
        ])
        XCTAssertEqual(try openLines(id), [
            "- [ ] 準備測試機｜王小明｜明天｜\(id)", "- [ ] 寫官網文案｜李大化｜下週三｜\(id)", "- [ ] 買咖啡｜｜｜\(id)", "- [ ] 整理需求｜李大化｜｜\(id)",
        ])
        XCTAssertTrue(try text("PEOPLE.md").contains("## 王小明\n- 別名：Ming\n- 單位：產品部\n- 出席：\(id)\n"))
        XCTAssertTrue(try text("PEOPLE.md").hasSuffix("\n## 李大化\n- 出席：\(id)\n"))
        XCTAssertEqual(try backups(), [], "只有新增：不備份")
    }

    // MARK: 重新整理全篇之後

    func testRepolishReplacesOnlyUntouchedHearbyLines() throws {
        try record(Self.v1)
        try MemoryStore.sync(mdURL: md)
        // 使用者（或他的 AI）在記憶裡動過手
        try edit("OPEN.md", [
            ("- [ ] 買咖啡｜｜｜\(id)", "- [x] 買咖啡｜｜｜\(id)"),
            ("- [ ] 寫官網文案｜李大化｜下週三｜\(id)", "- [ ] 寫官網文案｜陳美玲｜下週三｜\(id)"),
            ("- [ ] 整理需求｜李大化｜｜\(id)\n", "- [ ] 會後補的事｜王小明｜｜\(id)\n"),
        ])
        try edit("MEETINGS.md", [
            ("- 摘要：討論 Windows 版與預算。", "- 摘要：（我改的）談 Windows 版。"),
            ("- 紀錄：會議/\(id)/\(id).md\n", "- 紀錄：會議/\(id)/\(id).md\n- 備註：這場很重要\n"),
        ])
        try edit("PEOPLE.md", [("## 李大化\n", "## 李大化\n- 別名：大化\n")])
        let before = try ["MEETINGS.md", "OPEN.md", "PEOPLE.md", "index.json"].map(text)

        keepOldVersion()
        try record(Self.v2)
        let r = try XCTUnwrap(MemoryStore.sync(mdURL: md))

        XCTAssertFalse(r.isNew)
        XCTAssertEqual(Set(r.changed), ["MEETINGS.md", "OPEN.md", "PEOPLE.md", "index.json"])
        XCTAssertEqual(try block(id), [
            "## \(id)", "- 標題：週會 Windows 版", "- 日期：2026-09-20 14:30　時長：12分30秒", "- 與會：王小明（Ming）、李大華、陳美玲",
            "- 摘要：（我改的）談 Windows 版。",                 // 使用者改過：新版摘要不蓋上去
            "- 決議：先做骨架版", "- 決議：預算三十五萬", "- 決議：時程延一週", "- 紀錄：會議/\(id)/\(id).md",
            "- 備註：這場很重要",                               // 使用者加的：原地留著
        ])
        XCTAssertEqual(try openLines(id), [
            "- [x] 準備測試機｜王小明｜明天｜\(id)",              // 紀錄裡做完了：Hearby 自己那條跟著打勾
            "- [ ] 訂會議室｜陳美玲｜週五｜\(id)",                // 新的一條
            "- [ ] 寫官網文案｜陳美玲｜下週三｜\(id)",            // 使用者改過負責人：不動、也不再補一條
            "- [x] 買咖啡｜｜｜\(id)",                            // 使用者打過勾：不動
            "- [ ] 會後補的事｜王小明｜｜\(id)",                  // 使用者加的；「整理需求」被他刪了，不補回來
        ])
        XCTAssertTrue(try text("OPEN.md").contains("<!-- 2026-09-01_0900_舊會 -->\n- [ ] 舊的待辦｜｜｜2026-09-01_0900_舊會\n"), "別場不碰")
        let people = try text("PEOPLE.md")
        XCTAssertTrue(people.contains("## 李大化\n- 別名：大化\n\n## 李大華\n- 出席：\(id)\n\n## 陳美玲\n- 出席：\(id)\n"),
                      "舊名字那一節有使用者寫的別名：只拿掉出席，標題留著；新名字各開一節\n\(people)")
        XCTAssertTrue(people.contains("## 王小明\n- 別名：Ming\n- 單位：產品部\n- 出席：\(id)\n"))
        XCTAssertEqual(try indexRow(id)?["people"] as? [String], ["王小明（Ming）", "李大華", "陳美玲"])
        XCTAssertEqual(try indexRow(id)?["title"] as? String, "週會 Windows 版")
        XCTAssertEqual(r.kept, 5, "MEETINGS 兩行＋OPEN 三行是使用者的")

        // 改之前各留一份，內容就是改之前的樣子
        XCTAssertEqual(try backups(), ["MEETINGS.md", "OPEN.md", "PEOPLE.md", "index.json"].map { "\($0).bak-\(day)" }.sorted())
        for (f, old) in zip(["MEETINGS.md", "OPEN.md", "PEOPLE.md", "index.json"], before) { XCTAssertEqual(try text("\(f).bak-\(day)"), old) }
    }

    func testSyncAgainWithoutChangesWritesNothing() throws {
        try record(Self.v1)
        try MemoryStore.sync(mdURL: md)
        keepOldVersion()
        try record(Self.v2)
        try MemoryStore.sync(mdURL: md)
        let snapshot = try ["MEETINGS.md", "OPEN.md", "PEOPLE.md", "index.json", MemoryStore.writtenBook].map(text)
        let bakCount = try backups().count
        let r = try XCTUnwrap(MemoryStore.sync(mdURL: md))
        XCTAssertEqual(r.changed, [])
        XCTAssertEqual(try ["MEETINGS.md", "OPEN.md", "PEOPLE.md", "index.json", MemoryStore.writtenBook].map(text), snapshot)
        XCTAssertEqual(try backups().count, bakCount, "沒改就不備份")
    }

    // MARK: 自己改紀錄（沒留舊版）

    func testHandEditWithoutOldVersionStillSyncs() throws {
        try record(Self.v1)
        try MemoryStore.sync(mdURL: md)
        // 直接在編輯器把名字改對：沒有 _舊版，靠記錄認出哪幾行是 Hearby 寫的
        try record(Self.v1.replacingOccurrences(of: "李大化", with: "李大華"))
        try MemoryStore.sync(mdURL: md)
        XCTAssertTrue(try block(id).contains("- 與會：王小明（Ming）、李大華"))
        XCTAssertEqual(try openLines(id), [
            "- [ ] 準備測試機｜王小明｜明天｜\(id)", "- [ ] 寫官網文案｜李大華｜下週三｜\(id)", "- [ ] 買咖啡｜｜｜\(id)", "- [ ] 整理需求｜李大華｜｜\(id)",
        ])
        let people = try text("PEOPLE.md")
        XCTAssertFalse(people.contains("## 李大化"), "只為這一場開的那一節空了：連標題拿掉\n\(people)")
        XCTAssertTrue(people.hasSuffix("## 王小明\n- 別名：Ming\n- 單位：產品部\n- 出席：\(id)\n\n## 李大華\n- 出席：\(id)\n"), people)
        XCTAssertEqual(try indexRow(id)?["people"] as? [String], ["王小明（Ming）", "李大華"])
    }

    // MARK: 這份記錄出現之前寫的場（舊版 Hearby）

    func testLegacyMeetingRecognisedFromOldVersion() throws {
        try record(Self.v1)
        try MemoryStore.sync(mdURL: md)
        try forgetBook()
        try edit("OPEN.md", [("- [ ] 買咖啡｜｜｜\(id)", "- [x] 買咖啡｜｜｜\(id)")])
        keepOldVersion()
        try record(Self.v2)
        try MemoryStore.sync(mdURL: md)
        XCTAssertEqual(try block(id), [
            "## \(id)", "- 標題：週會 Windows 版", "- 日期：2026-09-20 14:30　時長：12分30秒", "- 與會：王小明（Ming）、李大華、陳美玲",
            "- 摘要：討論 Windows 版、預算與時程。", "- 決議：先做骨架版", "- 決議：預算三十五萬", "- 決議：時程延一週", "- 紀錄：會議/\(id)/\(id).md",
        ])
        XCTAssertEqual(try openLines(id), [
            "- [x] 準備測試機｜王小明｜明天｜\(id)", "- [ ] 寫官網文案｜李大華｜下週三｜\(id)", "- [x] 買咖啡｜｜｜\(id)",
            "- [ ] 整理需求｜李大華｜｜\(id)", "- [ ] 訂會議室｜陳美玲｜週五｜\(id)",
        ])
        XCTAssertTrue(try text(MemoryStore.writtenBook).contains(id), "同步完就有記錄，下次不必再猜")
    }

    func testLegacyHandEditWithoutOldVersionUsesIndexNames() throws {
        try record(Self.v1)
        try MemoryStore.sync(mdURL: md)
        try forgetBook()
        try record(Self.v1.replacingOccurrences(of: "- 李大化 — 報告", with: "- 李大華 — 報告"))
        try MemoryStore.sync(mdURL: md)
        XCTAssertTrue(try block(id).contains("- 與會：王小明（Ming）、李大華"), "index.json 記著當初寫的名單：認得出舊的與會行")
        XCTAssertTrue(try text("PEOPLE.md").hasSuffix("\n## 李大華\n- 出席：\(id)\n"))
        XCTAssertFalse(try text("PEOPLE.md").contains("## 李大化"))
    }

    // MARK: 備份、範圍、開關

    func testBackupNeverOverwritesAnExistingOne() throws {
        try record(Self.v1)
        try MemoryStore.sync(mdURL: md)
        try put("MEETINGS.md.bak-\(day)", "早上手動留的")
        try record(Self.v2)
        try MemoryStore.sync(mdURL: md)
        XCTAssertEqual(try text("MEETINGS.md.bak-\(day)"), "早上手動留的")
        XCTAssertTrue(try text("MEETINGS.md.bak-\(day)-2").contains("- 摘要：討論 Windows 版與預算。"))
    }

    func testRebuildAllBacksUpEachFileOnce() throws {
        let other = "2026-09-21_0900_客戶電話"
        try record(Self.v1)
        let otherV1 = Self.v1.replacingOccurrences(of: "2026-09-20 14:30", with: "2026-09-21 09:00").replacingOccurrences(of: "｜週會", with: "｜客戶電話")
        try record(otherV1, id: other)
        _ = MemoryStore.sync(MemoryStore.allRecords())
        try record(Self.v1.replacingOccurrences(of: "預算三十萬", with: "預算四十萬"))
        try record(otherV1.replacingOccurrences(of: "預算三十萬", with: "預算五十萬"), id: other)
        let rs = MemoryStore.sync(MemoryStore.allRecords())
        XCTAssertEqual(rs.map { $0.report?.changed ?? [] }, [["MEETINGS.md"], ["MEETINGS.md"]])
        XCTAssertEqual(try backups(), ["MEETINGS.md.bak-\(day)"], "一輪只備份一次")
        XCTAssertTrue(try block(id).contains("- 決議：預算四十萬"))
        XCTAssertTrue(try block(other).contains("- 決議：預算五十萬"))
    }

    func testOnlyMainRecordsAreSynced() throws {
        try record(Self.v1)
        let dir = md.deletingLastPathComponent()
        let en = dir.appendingPathComponent(id + ".en.md"), old = dir.appendingPathComponent(id + "_舊版1.md")
        try Self.v2.write(to: en, atomically: true, encoding: .utf8)
        try Self.v2.write(to: old, atomically: true, encoding: .utf8)
        XCTAssertNil(try MemoryStore.sync(mdURL: en))
        XCTAssertNil(try MemoryStore.sync(mdURL: old))
        XCTAssertEqual(try block(id), [])
        XCTAssertEqual(MemoryStore.allRecords().map(\.lastPathComponent), [id + ".md"])
    }

    func testMemoryOffWritesNothing() throws {
        try ConfigStore.shared.update { $0.memoryEnabled = false }
        try record(Self.v1)
        XCTAssertNil(try MemoryStore.sync(mdURL: md))
        XCTAssertEqual(try block(id), [])
    }

    func testUnreadablePeopleFileIsLeftAlone() throws {
        try record(Self.v1)
        try MemoryStore.sync(mdURL: md)
        let utf16 = "## 王小明\n- 出席：\(id)\n".data(using: .utf16)!
        try utf16.write(to: Paths.memory.appendingPathComponent("PEOPLE.md"))
        try record(Self.v2)
        try MemoryStore.sync(mdURL: md)
        XCTAssertEqual(try Data(contentsOf: Paths.memory.appendingPathComponent("PEOPLE.md")), utf16, "讀不懂的檔不碰")
        XCTAssertTrue(try block(id).contains("- 與會：王小明（Ming）、李大華、陳美玲"), "其他檔照常同步")
    }

    func testOpenFileStartedOverGetsThisMeetingBack() throws {
        try record(Self.v1)
        try MemoryStore.sync(mdURL: md)
        try put("OPEN.md", "# 還沒完成的事（開完會自動搬進來；完成就打勾）\n")
        try MemoryStore.sync(mdURL: md)
        XCTAssertEqual(try openLines(id).count, 4, "整份重來、這場一點痕跡都沒有：當成沒寫過，重寫一份")
    }
}
