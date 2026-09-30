// MeetingRenameTests — 改一場的標題：資料夾、夾裡的檔、紀錄表頭、meta.json、記憶、副本一起換；別的東西不動
import Foundation
import XCTest
@testable import HearbyCore

final class MeetingRenameTests: XCTestCase {
    var box: URL!
    let id = "2026-09-20_1430_週會"
    let fm = FileManager.default
    var day: String { MemoryStore.Backups().day }

    override func setUp() {
        box = fm.temporaryDirectory.appendingPathComponent("hearby-rename-\(UUID().uuidString)")
        setenv("HEARBY_OUTPUT_ROOT", box.appendingPathComponent("root").path, 1)
        setenv("HEARBY_SUPPORT_DIR", box.appendingPathComponent("support").path, 1)
        setenv("HEARBY_LOG_DIR", box.appendingPathComponent("logs").path, 1)
        ConfigStore.shared.reset()
        try? Paths.ensure()
        try? ConfigStore.shared.update { $0.memoryEnabled = true }
        try? MemoryStore.ensure()
    }

    override func tearDown() {
        // 只清自己建的沙箱夾（temporaryDirectory 底下）
        if let b = box, b.path.hasPrefix(fm.temporaryDirectory.path) { try? fm.removeItem(at: b) }
        unsetenv("HEARBY_OUTPUT_ROOT"); unsetenv("HEARBY_SUPPORT_DIR"); unsetenv("HEARBY_LOG_DIR")
        ConfigStore.shared.reset()
    }

    // MARK: 素材

    func record(_ id: String, title: String? = "週會") -> String {
        let head = "> Hearby 錄音｜時長 12分30秒" + (title.map { "｜\($0)" } ?? "")
        return """
            # 會議紀錄 2026-09-20 14:30

            \(head)
            > 音檔：\(Paths.meetings.path)/\(id)/\(id).m4a
            > ⚠ 系統聲音軌全程無聲

            ## AI 會議摘要
            討論預算。
            ## 與會者
            - 王小明 — 主持
            ## 決議
            - 預算三十萬 [01:05]
            ## 待辦
            - [ ] 寫官網文案｜王小明｜下週三

            ---

            ## 逐字稿
            - [00:12][我方] 週會開始
            """
    }

    /// 開完會的樣子：資料夾、紀錄、音檔、PDF、舊版、備份、翻譯、meta、別的檔；錄音工作夾的 meta；記憶同步過一次
    @discardableResult
    func meeting(_ id: String, folder: String? = nil, title: String? = "週會", work: String = "work-1") throws -> URL {
        let dir = Paths.meetings.appendingPathComponent(folder ?? id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let md = dir.appendingPathComponent(id + ".md")
        try record(id, title: title).write(to: md, atomically: true, encoding: .utf8)
        for suffix in [".m4a", ".pdf", "_舊版1.md", ".md.bak-2026-09-21", ".en.md"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(id + suffix))
        }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("內網草稿.json"))
        var m = MeetingMeta()
        m.id = work; m.title = title ?? ""; m.outName = id
        m.started = ISO8601DateFormatter().date(from: "2026-09-20T06:30:00Z")!
        Pipeline.saveMeta(m, to: dir)
        let wd = Pipeline.recordingsDir.appendingPathComponent(work)
        try fm.createDirectory(at: wd, withIntermediateDirectories: true)
        Pipeline.saveMeta(m, to: wd)
        _ = try MemoryStore.sync(mdURL: md)
        return dir
    }

    func mem(_ f: String) throws -> String { try String(contentsOf: Paths.memory.appendingPathComponent(f), encoding: .utf8) }
    func put(_ f: String, _ t: String) throws { try t.write(to: Paths.memory.appendingPathComponent(f), atomically: true, encoding: .utf8) }
    func json(_ f: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: Paths.memory.appendingPathComponent(f))) as? [String: Any] ?? [:]
    }
    func rows() throws -> [[String: Any]] { try json("index.json")["meetings"] as? [[String: Any]] ?? [] }
    func files(_ dir: URL) throws -> [String] { try fm.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }.sorted() }

    // MARK: 一般改名

    func testRenameMovesFolderFilesHeaderMetaAndMemory() throws {
        let dir = try meeting(id)
        let new = "2026-09-20_1430_第三季預算"
        // 記憶裡使用者自己寫的東西：THREADS 提到這場、MEETINGS 手加一行、OPEN 手加一條
        try put("THREADS.md", "# 議題\n\n## 預算\n- 預算三十萬（出處：\(id)）\n")
        try put("MEETINGS.md", try mem("MEETINGS.md").replacingOccurrences(of: "- 紀錄：會議/\(id)/\(id).md", with: "- 紀錄：會議/\(id)/\(id).md\n- 備註：很重要"))
        try put("OPEN.md", try mem("OPEN.md") + "- [ ] 我自己加的｜我｜｜\(id)\n")

        let r = try MeetingRename.rename(dir: dir, to: "第三季預算")
        XCTAssertFalse(r.unchanged)
        XCTAssertEqual(r.oldID, id)
        XCTAssertEqual(r.newID, new)
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")

        // 資料夾與檔
        let nd = Paths.meetings.appendingPathComponent(new)
        XCTAssertEqual(r.dir.lastPathComponent, new)
        XCTAssertFalse(fm.fileExists(atPath: dir.path))
        XCTAssertEqual(try files(nd), [new + ".en.md", new + ".m4a", new + ".md", new + ".md.bak-2026-09-21", new + ".pdf", new + "_舊版1.md", "meta.json", "內網草稿.json"])
        XCTAssertEqual(r.mdURL, nd.appendingPathComponent(new + ".md"))

        // 紀錄表頭：標題、音檔路徑；其他行一字不動
        let md = try String(contentsOf: nd.appendingPathComponent(new + ".md"), encoding: .utf8)
        XCTAssertEqual(md, record(new, title: "第三季預算").replacingOccurrences(of: "> 音檔：\(Paths.meetings.path)/\(new)/\(new).m4a", with: "> 音檔：\(nd.path)/\(new).m4a"))
        XCTAssertEqual(RecordMD.parse(md: md).parts.custom, "第三季預算")

        // meta.json：這一場的、錄音工作夾的
        XCTAssertEqual(Pipeline.loadMeta(nd)?.title, "第三季預算")
        XCTAssertEqual(Pipeline.loadMeta(nd)?.outName, new)
        let wm = Pipeline.loadMeta(Pipeline.recordingsDir.appendingPathComponent("work-1"))
        XCTAssertEqual(wm?.title, "第三季預算")
        XCTAssertEqual(wm?.outName, new)

        // 記憶：id 全換、標題跟著紀錄、使用者的行留著
        let meetings = try mem("MEETINGS.md")
        XCTAssertFalse(meetings.contains(id))
        XCTAssertTrue(meetings.contains("## \(new)\n- 標題：第三季預算\n"))
        XCTAssertTrue(meetings.contains("- 紀錄：會議/\(new)/\(new).md\n- 備註：很重要"))
        let open = try mem("OPEN.md")
        XCTAssertFalse(open.contains(id))
        XCTAssertTrue(open.contains("<!-- \(new) -->\n- [ ] 寫官網文案｜王小明｜下週三｜\(new)"))
        XCTAssertTrue(open.contains("- [ ] 我自己加的｜我｜｜\(new)"))
        XCTAssertTrue(try mem("PEOPLE.md").contains("## 王小明\n- 出席：\(new)"))
        XCTAssertEqual(try mem("THREADS.md"), "# 議題\n\n## 預算\n- 預算三十萬（出處：\(new)）\n")
        let row = try XCTUnwrap(try rows().first)
        XCTAssertEqual(try rows().count, 1)
        XCTAssertEqual(row["id"] as? String, new)
        XCTAssertEqual(row["path"] as? String, "會議/\(new)/\(new).md")
        XCTAssertEqual(row["title"] as? String, "第三季預算")
        let book = try json(MemoryStore.writtenBook)["meetings"] as? [String: Any] ?? [:]
        XCTAssertNil(book[id])
        XCTAssertEqual((book[new] as? [String: Any])?["MEETINGS.md"] as? [String], MemoryStore.entry(md: md, id: new).meetings)
        let names = try json(NameLedger.stateFile)["written"] as? [String: String] ?? [:]
        XCTAssertNil(names[id])
        XCTAssertEqual(names[new], NameLedger.hash(md))
        XCTAssertEqual(r.memory, ["MEETINGS.md", "OPEN.md", "PEOPLE.md", "THREADS.md", "index.json"])
        XCTAssertEqual(r.backups.map(\.lastPathComponent).sorted(), ["MEETINGS.md", "OPEN.md", "PEOPLE.md", "THREADS.md", "index.json"].map { "\($0).bak-\(day)" })

        // 之後再同步：不會多一塊、不會多一條
        let again = try XCTUnwrap(try MemoryStore.sync(mdURL: nd.appendingPathComponent(new + ".md")))
        XCTAssertEqual(again.changed, [])
        XCTAssertEqual(try rows().count, 1)
    }

    func testOtherMeetingsAndLongerIDsAreNotTouched() throws {
        let dir = try meeting(id)
        let second = id + "-2"
        // 同一分鐘的另兩場：「-2」（開完會撞名的尾巴）、標題更長的（id 以這場的 id 開頭）——都認得，所以不換
        let longer = "2026-09-20_1430_週會延長"
        try meeting(second, work: "work-2")
        try meeting(longer, title: "週會延長", work: "work-3")
        try put("THREADS.md", "- 三場：\(id)、\(second)、\(longer)\n")
        let r = try MeetingRename.rename(dir: dir, to: "季度會議")
        XCTAssertEqual(r.newID, "2026-09-20_1430_季度會議")
        XCTAssertEqual(try mem("THREADS.md"), "- 三場：2026-09-20_1430_季度會議、\(second)、\(longer)\n")
        for other in [second, longer] {
            XCTAssertTrue(try mem("MEETINGS.md").contains("## \(other)\n"))
            XCTAssertTrue(try mem("OPEN.md").contains("｜\(other)"))
            XCTAssertTrue(fm.fileExists(atPath: Paths.meetings.appendingPathComponent(other).appendingPathComponent(other + ".md").path))
        }
        XCTAssertEqual(try rows().compactMap { $0["id"] as? String }.sorted(), ["2026-09-20_1430_季度會議", second, longer].sorted())
    }

    func testNameTakenGetsNumbered() throws {
        let dir = try meeting(id)
        try meeting("2026-09-20_1430_預算", work: "work-4")
        let r = try MeetingRename.rename(dir: dir, to: "預算")
        XCTAssertEqual(r.newID, "2026-09-20_1430_預算-2")
        XCTAssertTrue(fm.fileExists(atPath: r.dir.appendingPathComponent("2026-09-20_1430_預算-2.md").path))
        // 同一分鐘的「預算」那場沒被動到
        XCTAssertTrue(try mem("MEETINGS.md").contains("## 2026-09-20_1430_預算\n"))
    }

    func testMeetingWithoutCustomTitleGetsOne() throws {
        let plain = "2026-09-20_1430_會議紀錄"
        let dir = try meeting(plain, title: nil)
        XCTAssertEqual(try MeetingRename.rename(dir: dir, to: "會議紀錄").unchanged, true)
        let r = try MeetingRename.rename(dir: dir, to: "產品週會")
        let md = try String(contentsOf: try XCTUnwrap(r.mdURL), encoding: .utf8)
        XCTAssertTrue(md.contains("\n> Hearby 錄音｜時長 12分30秒｜產品週會\n"))
        XCTAssertEqual(try rows().first?["title"] as? String, "產品週會")
        XCTAssertTrue(try mem("MEETINGS.md").contains("## 2026-09-20_1430_產品週會\n- 標題：產品週會\n"))
    }

    func testSameTitleIsUnchanged() throws {
        let dir = try meeting(id)
        let before = try mem("MEETINGS.md")
        let r = try MeetingRename.rename(dir: dir, to: "  週會\n")
        XCTAssertTrue(r.unchanged)
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(id + ".md").path))
        XCTAssertEqual(try mem("MEETINGS.md"), before)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: Paths.memory.path).contains { $0.contains(".bak-") })
    }

    func testOnlyLetterCaseChanges() throws {
        let lower = "2026-09-20_1430_weekly sync"
        let dir = try meeting(lower, title: "weekly sync")
        let r = try MeetingRename.rename(dir: dir, to: "Weekly Sync")
        let upper = "2026-09-20_1430_Weekly Sync"
        XCTAssertEqual(r.newID, upper)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: Paths.meetings.path).filter { !$0.hasPrefix(".") }, [upper])
        XCTAssertTrue(try files(r.dir).contains(upper + ".md"))
        XCTAssertFalse(try files(r.dir).contains(lower + ".md"))
        XCTAssertTrue(try mem("MEETINGS.md").contains("## \(upper)\n"))
    }

    /// 資料夾名被人改過、檔名與記憶沒跟上（資料夾少了句號）：照清單上的標題再存一次＝檔名與記憶補齊
    func testFolderRenamedByHandIsCompleted() throws {
        let fileID = "2026-09-20_1430_週會。"
        let dir = try meeting(fileID, folder: id, title: "週會。")
        XCTAssertEqual(MeetingRename.mainRecord(in: dir)?.lastPathComponent, fileID + ".md")
        let r = try MeetingRename.rename(dir: dir, to: "週會")
        XCTAssertFalse(r.unchanged)
        XCTAssertEqual(r.oldID, fileID)
        XCTAssertEqual(r.newID, id)
        XCTAssertEqual(r.dir.lastPathComponent, id)
        XCTAssertEqual(try files(r.dir), [id + ".en.md", id + ".m4a", id + ".md", id + ".md.bak-2026-09-21", id + ".pdf", id + "_舊版1.md", "meta.json", "內網草稿.json"])
        let md = try String(contentsOf: r.dir.appendingPathComponent(id + ".md"), encoding: .utf8)
        XCTAssertTrue(md.contains("> 音檔：\(r.dir.path)/\(id).m4a"))
        XCTAssertEqual(RecordMD.parse(md: md).parts.custom, "週會")
        XCTAssertFalse(try mem("MEETINGS.md").contains(fileID))
        XCTAssertEqual(try rows().first?["path"] as? String, "會議/\(id)/\(id).md")
    }

    func testBusyMeetingIsRefused() throws {
        let dir = try meeting(id)
        MeetingBusy.begin(dir)
        defer { MeetingBusy.end(dir) }
        XCTAssertThrowsError(try MeetingRename.rename(dir: dir, to: "別的"))
        XCTAssertTrue(fm.fileExists(atPath: dir.path))
        MeetingBusy.end(dir)
        XCTAssertFalse(MeetingBusy.contains(dir))
        MeetingBusy.begin(dir)   // 讓 defer 那次 end 有東西可減
    }

    /// 別的程式（app）正在整理這一場：它對鎖檔持有 flock，命令列這邊的 contains 也要看到「忙」
    func testBusyInAnotherProcessIsRefused() throws {
        let dir = try meeting(id)
        let k = MeetingBusy.key(dir)
        let u = MeetingBusy.lockFile(k)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(u.path, O_RDWR | O_CREAT, 0o600)   // 另一個 open＝另一份檔案描述，flock 跟別的程式一樣會互擋
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertTrue(MeetingBusy.contains(dir))
        XCTAssertThrowsError(try MeetingRename.rename(dir: dir, to: "別的"))
        flock(fd, LOCK_UN); close(fd)
        XCTAssertFalse(MeetingBusy.contains(dir))
        // 自己忙完放掉之後，別人鎖得到
        MeetingBusy.begin(dir)
        MeetingBusy.end(dir)
        XCTAssertFalse(MeetingBusy.contains(dir))
    }

    func testEmptyTitleIsRefused() throws {
        let dir = try meeting(id)
        XCTAssertThrowsError(try MeetingRename.rename(dir: dir, to: " \n "))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(id + ".md").path))
    }

    func testMirrorFollows() throws {
        let mirror = box.appendingPathComponent("mirror")
        try fm.createDirectory(at: mirror, withIntermediateDirectories: true)
        try ConfigStore.shared.update { $0.mirrorDir = mirror.path }
        let dir = try meeting(id)
        try Data("舊的".utf8).write(to: mirror.appendingPathComponent(id + ".md"))
        try Data("en".utf8).write(to: mirror.appendingPathComponent(id + ".en.md"))
        try Data("別場".utf8).write(to: mirror.appendingPathComponent(id + "-2.md"))
        try Data("別的".utf8).write(to: mirror.appendingPathComponent("周會記錄.docx"))
        let r = try MeetingRename.rename(dir: dir, to: "預算")
        let new = "2026-09-20_1430_預算"
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: mirror.path).sorted(), [id + "-2.md", new + ".en.md", new + ".md", "周會記錄.docx"])
        XCTAssertEqual(try String(contentsOf: mirror.appendingPathComponent(new + ".md"), encoding: .utf8),
                       try String(contentsOf: r.dir.appendingPathComponent(new + ".md"), encoding: .utf8))
        XCTAssertEqual(Set(r.mirror.map(\.lastPathComponent)), [new + ".md", new + ".en.md"])
    }

    func testMemoryOffLeavesMemoryAlone() throws {
        let dir = try meeting(id)
        try ConfigStore.shared.update { $0.memoryEnabled = false }
        let before = try mem("MEETINGS.md")
        let r = try MeetingRename.rename(dir: dir, to: "預算")
        XCTAssertEqual(r.memory, [])
        XCTAssertEqual(try mem("MEETINGS.md"), before)
        XCTAssertTrue(fm.fileExists(atPath: r.dir.appendingPathComponent("2026-09-20_1430_預算.md").path))
    }

    // MARK: 零件

    func testRetitled() {
        let md = "# 會議紀錄 2026-09-20 14:30\r\n\r\n> Hearby 錄音｜時長 5分｜舊｜標題\r\n> 音檔：/a/b.m4a\r\n\r\n## 摘要\r\n> Hearby 錄音｜時長 1分｜這行在內文\r\n"
        let out = RecordMD.retitled(md: md, title: "新標題", audio: { $0 == "/a/b.m4a" ? "/c/d.m4a" : nil })
        XCTAssertEqual(out, "# 會議紀錄 2026-09-20 14:30\r\n\r\n> Hearby 錄音｜時長 5分｜新標題\r\n> 音檔：/c/d.m4a\r\n\r\n## 摘要\r\n> Hearby 錄音｜時長 1分｜這行在內文\r\n")
        // 第一行不是「…｜時長 …」：不動
        let odd = "# 筆記\n\n> 本場情境：線上\n> 音檔：/a/b.m4a\n"
        XCTAssertEqual(RecordMD.retitled(md: odd, title: "新", audio: { _ in nil }), odd)
    }

    func testReplacingID() {
        let longer = ["A_週會延長"]
        XCTAssertEqual(MemoryStore.replacingID("A_週會、A_週會-2、A_週會延長、A_週會。", old: "A_週會", new: "B", longer: longer), "B、A_週會-2、A_週會延長、B。")
        XCTAssertEqual(MemoryStore.replacingID("會議/A_週會/A_週會.md", old: "A_週會", new: "B", longer: []), "會議/B/B.md")
        XCTAssertEqual(MemoryStore.replacingID("沒提到", old: "A_週會", new: "B", longer: []), "沒提到")
    }

    func testFolderName() {
        XCTAssertEqual(MeetingRename.folderName(current: "2026-09-20_1430_週會-2", title: "預算/季度"), "2026-09-20_1430_預算 季度")
        XCTAssertEqual(MeetingRename.folderName(current: "我自己的夾", title: "預算"), "預算")
        XCTAssertEqual(MeetingRename.renamed("A.md.bak-1", oldID: "A", folder: "A", newName: "B"), "B.md.bak-1")
        XCTAssertNil(MeetingRename.renamed("AB.md", oldID: "A", folder: "A", newName: "B"))
        XCTAssertNil(MeetingRename.renamed("meta.json", oldID: "A", folder: "A", newName: "B"))
    }
}
