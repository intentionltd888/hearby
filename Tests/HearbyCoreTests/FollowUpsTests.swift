// FollowUpsTests — 紀錄的「## 之前的事」：沒時間戳的不留、做完的把別場待辦打勾（名字都是假的）
import Foundation
import XCTest
@testable import HearbyCore

final class FollowUpsTests: XCTestCase {
    var box: URL!
    override func setUp() {
        box = FileManager.default.temporaryDirectory.appendingPathComponent("hearby-follow-\(UUID().uuidString)")
        setenv("HEARBY_OUTPUT_ROOT", box.appendingPathComponent("root").path, 1)
        setenv("HEARBY_SUPPORT_DIR", box.appendingPathComponent("support").path, 1)
        setenv("HEARBY_LOG_DIR", box.appendingPathComponent("logs").path, 1)
        ConfigStore.shared.reset()
        try? Paths.ensure()
    }
    override func tearDown() {
        if let b = box, b.path.hasPrefix(FileManager.default.temporaryDirectory.path) { try? FileManager.default.removeItem(at: b) }
        unsetenv("HEARBY_OUTPUT_ROOT"); unsetenv("HEARBY_SUPPORT_DIR"); unsetenv("HEARBY_LOG_DIR")
        ConfigStore.shared.reset()
    }

    func testPrune() {
        let notes = "## 待辦\n- 無\n## 之前的事\n- 準備測試機 → 做完了 [01:05]\n- 整理預算表 → 沒講到\n- 星河計畫 → 改到 10/9 交 [02:10]\n## 名字更正\n- 無"
        XCTAssertEqual(FollowUps.prune(notes), "## 待辦\n- 無\n## 之前的事\n- 準備測試機 → 做完了 [01:05]\n- 星河計畫 → 改到 10/9 交 [02:10]\n## 名字更正\n- 無",
                       "沒有時間戳＝逐字稿沒講過，那一行不留")
        XCTAssertEqual(FollowUps.prune("## 待辦\n- 無\n\n## 之前的事\n- 無\n"), "## 待辦\n- 無", "只剩「無」＝整節拿掉")
        XCTAssertEqual(FollowUps.prune("## 摘要\n內容"), "## 摘要\n內容")
    }

    func testDoneItemsAndTick() {
        let md = "## 之前的事\n- 準備測試機 → 做完了 [01:05]\n- 整理預算表｜陳美玲｜月底 → 還沒做完，改到下週 [02:10]\n- 寫文案 → 不做了 [03:00]\n## 待辦\n- [ ] 準備測試機 → 做完了"
        XCTAssertEqual(FollowUps.doneItems(md), ["準備測試機", "寫文案"], "「還沒做完」不算；別節的不算")
        let open = "# 還沒完成的事\n- [ ] 準備測試機｜林小安｜明天｜m1\n- [ ] 準備測試機｜林小安｜明天｜m3\n- [ ] 寫文案｜｜｜m1\n- [x] 已經勾了｜｜｜m1\n- [ ] 整理預算表｜陳美玲｜月底｜m1"
        XCTAssertEqual(FollowUps.tick(open: open, done: FollowUps.doneItems(md), meeting: "m3"),
                       "# 還沒完成的事\n- [x] 準備測試機｜林小安｜明天｜m1\n- [ ] 準備測試機｜林小安｜明天｜m3\n- [x] 寫文案｜｜｜m1\n- [x] 已經勾了｜｜｜m1\n- [ ] 整理預算表｜陳美玲｜月底｜m1",
                       "別場的打勾；這一場自己的跟著紀錄走，不動")
    }

    func testSyncTicksOtherMeetings() throws {
        try ConfigStore.shared.update { $0.memoryEnabled = true }
        func record(_ id: String, _ body: String) throws -> URL {
            let d = Paths.meetings.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let u = d.appendingPathComponent(id + ".md")
            try ("# 會議紀錄 2026-09-2\(id.last!) 10:00\n\n> Hearby 錄音｜時長 1分0秒\n\n" + body + "\n\n---\n\n## 逐字稿\n- [00:01][我方] 內容").write(to: u, atomically: true, encoding: .utf8)
            return u
        }
        let a = try record("2026-09-20_1000_a", "## AI 會議摘要\n第一場。\n## 待辦\n- [ ] 準備測試機｜林小安｜明天")
        _ = try MemoryStore.sync(mdURL: a)
        let b = try record("2026-09-21_1000_b", "## AI 會議摘要\n第二場。\n## 待辦\n- 無\n## 之前的事\n- 準備測試機 → 做完了 [00:01]")
        let r = try XCTUnwrap(try MemoryStore.sync(mdURL: b))
        let open = try String(contentsOf: Paths.memory.appendingPathComponent("OPEN.md"), encoding: .utf8)
        XCTAssertTrue(open.contains("- [x] 準備測試機｜林小安｜明天｜2026-09-20_1000_a"), open)
        XCTAssertTrue(r.changed.contains("OPEN.md"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: Paths.memory.path).contains { $0.hasPrefix("OPEN.md.bak-") }, "改到既有的行，先備份")
        _ = try MemoryStore.sync(mdURL: a)
        XCTAssertTrue(try String(contentsOf: Paths.memory.appendingPathComponent("OPEN.md"), encoding: .utf8).contains("- [x] 準備測試機｜林小安｜明天｜2026-09-20_1000_a"),
                      "那一場再同步也不會被改回沒打勾（打勾算你改過的）")
    }
}
