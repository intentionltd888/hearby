// StoreTests — 沙箱下的 Paths／Config／Phase；永遠不碰真資料夾
import Foundation
import XCTest
@testable import HearbyCore

final class StoreTests: XCTestCase {
    var box: URL!

    override func setUp() {
        box = FileManager.default.temporaryDirectory.appendingPathComponent("hearby-test-\(UUID().uuidString)")
        setenv("HEARBY_OUTPUT_ROOT", box.appendingPathComponent("root").path, 1)
        setenv("HEARBY_SUPPORT_DIR", box.appendingPathComponent("support").path, 1)
        setenv("HEARBY_LOG_DIR", box.appendingPathComponent("logs").path, 1)
        ConfigStore.shared.reset()
    }

    override func tearDown() {
        // 只清自己建的沙箱夾（temporaryDirectory 底下）
        if let b = box, b.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: b)
        }
        unsetenv("HEARBY_OUTPUT_ROOT"); unsetenv("HEARBY_SUPPORT_DIR"); unsetenv("HEARBY_LOG_DIR")
        ConfigStore.shared.reset()
    }

    func testSandboxIsRespected() throws {
        XCTAssertTrue(Paths.root.path.hasPrefix(box.path), "測試必須寫進沙箱，不是真的 ~/Hearby")
        let made = try Paths.ensure()
        XCTAssertFalse(made.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Paths.meetings.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Paths.memory.path))
    }

    func testConfigRoundTripAndSchema() throws {
        try ConfigStore.shared.update { $0.provider = "claude"; $0.appearance = "dark" }
        ConfigStore.shared.reset()
        let c = ConfigStore.shared.current
        XCTAssertEqual(c.provider, "claude")
        XCTAssertEqual(c.appearance, "dark")
        XCTAssertEqual(c.schemaVersion, Config.currentSchema)
        let raw = try String(contentsOf: ConfigStore.shared.url, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"schemaVersion\" : 1"))
    }

    func testOldConfigMissingFieldsStillLoads() throws {
        try FileManager.default.createDirectory(at: ConfigStore.shared.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"provider":"claude"}"#.utf8).write(to: ConfigStore.shared.url)
        ConfigStore.shared.reset()
        let c = ConfigStore.shared.current
        XCTAssertEqual(c.provider, "claude")
        XCTAssertEqual(c.online, false)
        XCTAssertEqual(c.scene, "meeting")
        let dir = ConfigStore.shared.url.deletingLastPathComponent()
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(atPath: dir.path)).contains { $0.contains("broken-") }, "缺欄位不是壞檔")
    }

    func testBrokenConfigFallsBackAndKeepsEvidence() throws {
        try FileManager.default.createDirectory(at: ConfigStore.shared.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: ConfigStore.shared.url)
        ConfigStore.shared.reset()
        XCTAssertEqual(ConfigStore.shared.current, Config())
        let dir = ConfigStore.shared.url.deletingLastPathComponent()
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("broken-") }
        XCTAssertFalse(kept.isEmpty, "壞檔要留證據不覆蓋")
    }

    /// 檔名上限是 255 bytes：60 個合成 emoji（每個 25 bytes 以上）不能讓夾名爆掉
    func testSafeTitleIsCappedByBytesNotCharacters() {
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 60)
        let t = Paths.safeTitle(family)
        XCTAssertLessThanOrEqual(t.utf8.count, 180)
        XCTAssertFalse(t.isEmpty)
        XCTAssertEqual(Paths.safeTitle("  ／  ".replacingOccurrences(of: "／", with: "/")), "未命名")
    }

    /// 備份不靠「讀成 UTF-8 字串」：內容是別的編碼也要備得到；備份滿 50 份不覆寫第 50 份
    func testBackupCopiesBytesAndNeverOverwritesExistingBackups() throws {
        let dir = box.appendingPathComponent("bk"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let md = dir.appendingPathComponent("a.md")
        let bytes = "紀錄".data(using: .utf16)!
        try bytes.write(to: md)
        RecordMD.backupIfExists(md)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("a_舊版1.md")), bytes)
        for k in 2...50 { try Data("x\(k)".utf8).write(to: dir.appendingPathComponent("a_舊版\(k).md")) }
        RecordMD.backupIfExists(md)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a_舊版50.md"), encoding: .utf8), "x50", "第 50 份原封不動")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("a_舊版_") }.count, 1, "改用時間戳另起一份")
    }

    func testMeetingFolderName() {
        let d = DateComponents(calendar: .init(identifier: .gregorian), timeZone: TimeZone(identifier: "Asia/Taipei"),
                               year: 2026, month: 9, day: 10, hour: 21, minute: 12).date!
        XCTAssertEqual(Paths.meetingFolderName(date: d, title: "ABC/合作:協議"), "2026-09-10_2112_ABC 合作 協議")
        XCTAssertEqual(Paths.safeTitle("   "), "未命名")
    }

    func testPhaseTransitions() {
        XCTAssertTrue(Phase.idle.canGo(to: .recording))
        XCTAssertTrue(Phase.recording.canGo(to: .processing))
        XCTAssertTrue(Phase.processing.canGo(to: .done))
        XCTAssertTrue(Phase.done.canGo(to: .idle))
        XCTAssertTrue(Phase.recording.canGo(to: .error))
        XCTAssertTrue(Phase.idle.canGo(to: .processing), "匯入音檔、補整理：不經過錄音就進處理中")
        XCTAssertTrue(Phase.done.canGo(to: .processing), "剛完成一場，接著匯入下一個")
        XCTAssertFalse(Phase.processing.canGo(to: .processing), "處理中不重入")
        XCTAssertFalse(Phase.recording.canGo(to: .recording))
        XCTAssertFalse(Phase.processing.canGo(to: .recording))
    }

    func testDoctorHasSevenItems() {
        let r = Doctor.run(deep: false)
        XCTAssertEqual(r.items.count, 7)
        XCTAssertEqual(r.items.map(\.name), ["系統", "麥克風", "系統聲", "聽打模型", "整理方式", "磁碟", "資料夾"])
    }

    /// 標題是外來字串（匯入的檔名）：真的交給 zsh 跑，裡面的 $( )、反引號、變數、單引號都必須原樣出現、不被執行
    func testContinueCommandDoesNotLetShellExpandTitle() throws {
        _ = try Paths.ensure()
        let evil = "2026-09-10_2112_$(echo INJECTED) `echo BT` $HOME it's \"q\""
        let md = Paths.meetings.appendingPathComponent(evil).appendingPathComponent(evil + ".md")
        let cmd = EntryFiles.continueCommand(mdURL: md, claude: "/bin/echo")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        let out = Pipe()
        p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let printed = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(printed.trimmingCharacters(in: .newlines), EntryFiles.continueQuestion(mdURL: md), "shell 改動了問句＝有東西被展開或執行")
        XCTAssertTrue(printed.contains("$(echo INJECTED)") && printed.contains("`echo BT`") && printed.contains("$HOME"))
        XCTAssertEqual(EntryFiles.shellQuote("a'b"), "'a'\\''b'")
    }
}
