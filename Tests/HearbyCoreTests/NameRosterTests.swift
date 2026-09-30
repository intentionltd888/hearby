// NameRosterTests — 帶名冊整理：名冊與記憶怎麼讀（PolishContext）、AI 回的名字更正怎麼套（NameFixes）、整理流程接起來的樣子
// 名字全是假的（公開倉）。
import Foundation
import XCTest
@testable import HearbyCore

final class NameRosterTests: XCTestCase {
    var box: URL!
    override func setUp() {
        box = FileManager.default.temporaryDirectory.appendingPathComponent("hearby-roster-\(UUID().uuidString)")
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

    static let roster = """
        # 名冊（示範用，名字都是假的）
        <!-- 產生：測試；- 註解裡的行不算｜不算｜ -->
        一行一個：正名｜別名｜聽錯｜是誰｜讀音
        ## 人
        - 林小安｜小安｜林曉安、琳小安｜產品經理｜
        - 陳美玲｜美玲｜梅玲（看上下文）｜行銷部｜
        ## 案子
        - 星河計畫｜星河｜星核計畫｜年度企劃｜
        ## 容易搞混
        - 「梅玲」可能是 陳美玲：看上下文才換
        """
    static let threads = """
        # 議題
        ## 官網改版
        - 起點：2026-09-01 週會
        - 2026-09-03 定案：首頁改成三段
        - 2026-09-05 還沒定：要不要加影片
        - 2026-09-06 決定：十月上線
        ## 招募
        - 2026-09-10 同意先找一位 PM
        """
    static let open = """
        # 還沒完成的事
        <!-- 2026-09-01_1000_週會 -->
        - [ ] 準備測試機｜林小安｜明天｜2026-09-01_1000_週會
        - [x] 寫文案｜｜｜2026-09-01_1000_週會
        <!-- 2026-09-20_1400_週會 -->
        - [ ] 整理預算表｜陳美玲｜月底｜2026-09-20_1400_週會
        """

    func testContextNeedsMemoryOnAndARoster() throws {
        XCTAssertNil(PolishContext.load(), "記憶關著（預設）")
        try ConfigStore.shared.update { $0.memoryEnabled = true }
        try MemoryStore.ensure()
        XCTAssertNil(PolishContext.load(), "沒有 ROSTER.md＝跟以前一樣")
        try "# 名冊\n\n只有說明，一行都沒有\n".write(to: Paths.memory.appendingPathComponent("ROSTER.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(PolishContext.load(), "名冊一行都沒有＝不帶")
        try Self.roster.write(to: Paths.memory.appendingPathComponent("ROSTER.md"), atomically: true, encoding: .utf8)
        try Self.open.write(to: Paths.memory.appendingPathComponent("OPEN.md"), atomically: true, encoding: .utf8)
        let c = try XCTUnwrap(PolishContext.load(excluding: "2026-09-20_1400_週會"))
        XCTAssertEqual(c.openTodos, ["準備測試機｜林小安｜明天｜2026-09-01"], "這一場自己的待辦不算「之前的」；打勾的不算")
    }

    /// 現況（STATE.md）：在的話待辦與定案用它的（本機 OPEN.md、THREADS.md 不用），另外帶案子現況與還沒定的事；只有它也帶
    func testStateReplacesLocalOpenAndThreads() throws {
        try ConfigStore.shared.update { $0.memoryEnabled = true }
        try MemoryStore.ensure()
        try Self.open.write(to: Paths.memory.appendingPathComponent("OPEN.md"), atomically: true, encoding: .utf8)
        try Self.threads.write(to: Paths.memory.appendingPathComponent("THREADS.md"), atomically: true, encoding: .utf8)
        try """
            # 現況
            ## 案子
            - 星河計畫｜林小安｜製作中｜10/2 交視覺提案｜2026-10-02
            ## 還沒完成的待辦
            - 準備測試機｜林小安｜2026-10-01｜星河計畫
            ## 最近定案
            - 2026-09-25｜官網改成三段
            ## 還沒定的事
            - 2026-09-20｜要不要加影片
            """.write(to: Paths.memory.appendingPathComponent("STATE.md"), atomically: true, encoding: .utf8)
        let c = try XCTUnwrap(PolishContext.load(), "只有 STATE.md（沒有名冊）也帶")
        XCTAssertEqual(c.openTodos, ["準備測試機｜林小安｜2026-10-01｜星河計畫"], "待辦用現況的，不用本機 OPEN.md")
        XCTAssertEqual(c.decided, ["2026-09-25｜官網改成三段"], "定案用現況的，不用 THREADS.md")
        XCTAssertEqual(c.projects, ["星河計畫｜林小安｜製作中｜10/2 交視覺提案｜2026-10-02"])
        XCTAssertEqual(c.undecided, ["2026-09-20｜要不要加影片"])
        let block = Prompt.memoryBlock(c)
        XCTAssertTrue(block.contains("案子現況（開會前記的") && block.contains("還沒定的事（開會前還沒定案"))
    }

    func testRosterKeepsOnlyHeadingsAndEntries() throws {
        let c = try XCTUnwrap(PolishContext.make(roster: Self.roster, threads: nil, open: nil, excluding: nil))
        XCTAssertFalse(c.roster.contains("# 名冊"))
        XCTAssertFalse(c.roster.contains("一行一個"))
        XCTAssertFalse(c.roster.contains("不算"), "HTML 註解不帶")
        XCTAssertTrue(c.roster.hasPrefix("## 人\n- 林小安｜"))
        XCTAssertEqual(c.names, ["林小安", "小安", "陳美玲", "美玲", "星河計畫", "星河"], "只收正名與別名；聽錯的、「容易搞混」那種說明行不算")
    }

    func testRosterTooLongIsCutFromTheEnd() throws {
        let raw = "## 人\n" + (1...30).map { "- 測試人\($0)｜｜｜第 \($0) 位｜" }.joined(separator: "\n") + "\n## 案子\n- 很後面的案子｜｜｜｜"
        let c = try XCTUnwrap(PolishContext.make(roster: raw, threads: nil, open: nil, excluding: nil, limit: 120))
        XCTAssertTrue(c.roster.contains("- 測試人1｜"))
        XCTAssertFalse(c.roster.contains("很後面的案子"))
        XCTAssertFalse(c.roster.contains("## 案子"), "截在標題後面＝標題也不帶")
        XCTAssertTrue(c.roster.hasSuffix("行沒帶）"))
        XCTAssertLessThanOrEqual(c.roster.count, 120 + 30)
    }

    func testDecidedLinesSkipUndecided() {
        let d = PolishContext.decidedLines(Self.threads)
        XCTAssertEqual(d, ["【官網改版】2026-09-03 定案：首頁改成三段", "【官網改版】2026-09-06 決定：十月上線", "【招募】2026-09-10 同意先找一位 PM"])
    }

    func testParseFixLines() {
        XCTAssertEqual(NameFixes.parse("- 林曉安 → 林小安｜高｜[01:05] [1:02:03] [01:05]"),
                       NameFixes.Fix(heard: "林曉安", name: "林小安", sure: true, stamps: ["01:05", "1:02:03"]))
        XCTAssertEqual(NameFixes.parse("- 「梅玲」->「陳美玲」| 低 | [02:10]")?.sure, false)
        XCTAssertNil(NameFixes.parse("- 無"))
        XCTAssertNil(NameFixes.parse("- 沒有箭頭｜高｜[00:01]"))
        XCTAssertNil(NameFixes.parse("- 一樣 → 一樣｜高｜[00:01]"))
    }

    func testExtractRemovesTheSection() {
        let notes = "## AI 會議摘要\n摘要\n\n## 名字更正\n- 林曉安 → 林小安｜高｜[01:05]\n\n## 待辦\n- 無\n"
        let (out, fixes) = NameFixes.extract(notes)
        XCTAssertEqual(out, "## AI 會議摘要\n摘要\n\n## 待辦\n- 無")
        XCTAssertEqual(fixes.count, 1)
        XCTAssertEqual(NameFixes.extract("## 摘要\n內容").notes, "## 摘要\n內容", "沒有這一節＝原樣")
    }

    func testApplyOnlyTouchesTheListedLines() {
        let tr = "- [00:12][我方] 星核計畫先做半天\n- [01:05][遠端] 林曉安說預算三十萬，林曉安會寄\n- [02:10][我方] 林曉安明天回"
        let fixes = [
            NameFixes.Fix(heard: "林曉安", name: "林小安", sure: true, stamps: ["01:05"]),
            NameFixes.Fix(heard: "星核計畫", name: "星河計畫", sure: true, stamps: ["00:12", "09:59"]),
            NameFixes.Fix(heard: "梅玲", name: "陳美玲", sure: false, stamps: ["02:10"]),
            NameFixes.Fix(heard: "預算", name: "預算表", sure: true, stamps: ["01:05"]),
            NameFixes.Fix(heard: "凌", name: "林小安", sure: true, stamps: ["02:10"]),
        ]
        let r = NameFixes.apply(fixes, transcript: tr, names: ["林小安", "小安", "陳美玲", "星河計畫"])
        XCTAssertEqual(r.transcript, "- [00:12][我方] 星河計畫先做半天\n- [01:05][遠端] 林小安說預算三十萬，林小安會寄\n- [02:10][我方] 林曉安明天回",
                       "只改清單上那幾行；[02:10] 那行沒列在更正裡就不動")
        XCTAssertEqual(r.applied.map { "\($0.fix.heard)=\($0.count)" }, ["林曉安=2", "星核計畫=1"])
        XCTAssertEqual(r.skipped.map(\.heard), ["梅玲", "凌"], "沒把握、原字只有一個字＝不改（列出來、標 [[?]]）；「預算 → 預算表」一邊包含另一邊＝不是聽錯，整筆不算")
    }

    func testRosterNamesSurviveTraditionalConversion() {
        // ICU 的簡轉繁會把姓氏「涂」當成「塗」的簡體；名冊上的名字要原樣留著，其他照轉
        XCTAssertEqual(Clean.toTraditional("涂小明说"), "塗小明說", "沒給 keep＝照舊")
        XCTAssertEqual(Clean.toTraditional("涂小明说，涂改液", keep: ["涂小明", "林小安"]), "涂小明說，塗改液")
        XCTAssertEqual(Clean.toTraditional("干净", keep: []), Clean.toTraditional("干净"))
    }

    func testFixThatDropsWordsIsNotApplied() {
        let tr = "- [00:12][我方] 林曉安老師的提案"
        let f = NameFixes.Fix(heard: "林曉安老師", name: "林小安", sure: true, stamps: ["00:12"])
        let r = NameFixes.apply([f], transcript: tr, names: ["林小安"])
        XCTAssertEqual(r.transcript, tr, "正名比原字少兩個字以上（沒有英文）＝前後的字弄丟了，不改")
        XCTAssertEqual(r.skipped, [f])
        let ok = NameFixes.apply([NameFixes.Fix(heard: "林曉安老師", name: "林小安老師", sure: true, stamps: ["00:12"])], transcript: tr, names: ["林小安"])
        XCTAssertEqual(ok.transcript, "- [00:12][我方] 林小安老師的提案")
        let en = NameFixes.apply([NameFixes.Fix(heard: "Calculer", name: "Kep", sure: true, stamps: ["00:12"])], transcript: "- [00:12][我方] Calculer 說", names: ["Kep"])
        XCTAssertEqual(en.applied.count, 1, "英文拼錯長短差很多是常態，不擋")
    }

    func testMarkUnsureAndHeader() {
        let notes = "## AI 會議摘要\n梅玲說明天要交。\n## 與會者\n- 陳美玲 — 推測\n## 重點\n- 陳美玲提到預算 [01:05]\n## 待辦\n- [ ] 交報告｜陳美玲｜明天"
        let unsure = [NameFixes.Fix(heard: "梅玲", name: "陳美玲", sure: false, stamps: ["02:10"])]
        let marked = NameFixes.markUnsure(notes, unsure)
        XCTAssertTrue(marked.contains("梅玲 [[?]]說明天要交。"), "摘要裡沒有正名、有原字 → 標在摘要的原字（先把摘要找完才找下一節）")
        XCTAssertTrue(marked.contains("- 陳美玲提到預算 [01:05]"), "只標一個地方")
        XCTAssertTrue(marked.contains("- 陳美玲 — 推測"), "與會者不動")
        XCTAssertTrue(marked.contains("｜陳美玲｜"), "待辦不動")
        XCTAssertEqual(NameFixes.markUnsure(marked, unsure), marked, "標過了不再標")
        let applied = [(fix: NameFixes.Fix(heard: "林曉安", name: "林小安", sure: true, stamps: []), count: 2)]
        XCTAssertEqual(NameFixes.headerLine(applied: applied, unsure: unsure),
                       "> 名字更正：逐字稿照名冊改了 2 處（林曉安→林小安 ×2）；沒改：梅玲→陳美玲？（沒把握，或名冊、逐字稿對不上；紀錄裡提到的地方標了 [[?]]）")
        XCTAssertNil(NameFixes.headerLine(applied: [], unsure: []))
    }

    func testRepeatedTodosAreDropped() {
        let notes = "## 待辦\n- [ ] 準備測試機｜林小安｜明天\n- [ ] 準備測試機｜林小安｜下週三\n- [ ] 整理預算表｜｜\n- [ ] 新的事｜｜"
        let open = ["準備測試機｜林小安｜明天｜2026-09-01", "整理預算表｜陳美玲｜月底｜2026-09-20"]
        XCTAssertEqual(NameFixes.dropRepeatedTodos(notes, open: open),
                       "## 待辦\n- [ ] 準備測試機｜林小安｜下週三\n- [ ] 新的事｜｜", "一模一樣、或沒有新負責人／新期限的不再開；改了期限的留著")
    }

    func testBuildNotesWithRoster() throws {
        let tr = "- [00:12][我方] 星核計畫骨架版先做半天\n- [01:05][遠端] 林曉安說預算三十萬\n- [02:10][我方] 要不要買憑證，梅玲說明天"
        let reply = """
            ## AI 會議摘要
            這場會議討論星河計畫的時程，林小安說明預算三十萬，梅玲提到憑證。
            ## 與會者
            - 林小安 — 自己報預算
            ## 重點
            - 星河計畫骨架版先做半天 [00:12]
            ## 決議
            - 先做骨架版 [00:12]
            ## 開放問題
            - 要不要買憑證 [02:10]
            ## 待辦
            - [ ] 準備測試機｜林小安｜明天
            ## 名字更正
            - 林曉安 → 林小安｜高｜[01:05]
            - 星核計畫 → 星河計畫｜高｜[00:12]
            - 梅玲 → 陳美玲｜低｜[02:10]
            """
        final class Fake: Provider {
            let id: String, reply: String
            var system = "", user = ""
            init(_ id: String, _ reply: String) { self.id = id; self.reply = reply }
            var displayName: String { "假的" }
            var contextBudget: Int { 100_000 }
            var maxOutputTokens: Int { 8000 }
            var trustLevel: TrustLevel { .local }
            func check() -> ProviderStatus { ProviderStatus(.ready, "ok") }
            func complete(system: String, user: String) -> (String?, String?) { self.system = system; self.user = user; return (reply, nil) }
        }
        var input = Polish.Input(transcript: tr, title: "週會", attendees: "", dateStr: "2026-09-20 14:30", durStr: "12分30秒", warnings: [], audioLine: "{AUDIO}")
        let plain = Fake("fake", reply)
        let before = Polish.buildNotes(input, provider: plain)
        XCTAssertFalse(plain.system.contains("名冊"), "沒名冊＝提示跟以前一樣")
        XCTAssertTrue(before.md.contains("## 名字更正"), "沒名冊時不解析這一節（AI 本來也不會回）")

        input.context = PolishContext.make(roster: Self.roster, threads: Self.threads, open: Self.open, excluding: nil)
        let fake = Fake("fake", reply)
        let r = Polish.buildNotes(input, provider: fake)
        XCTAssertTrue(fake.system.hasSuffix("沒有要更正的就寫「- 無」。"))
        XCTAssertTrue(fake.user.contains("名冊（使用者圈子裡的人"))
        XCTAssertTrue(fake.user.contains("【官網改版】2026-09-06 決定：十月上線"))
        XCTAssertTrue(fake.user.contains("- 準備測試機｜林小安｜明天｜2026-09-01"))
        XCTAssertLessThan(fake.user.range(of: "名冊（")!.lowerBound, fake.user.range(of: "逐字稿：")!.lowerBound, "名冊在逐字稿前面")
        XCTAssertFalse(r.md.contains("## 名字更正"))
        XCTAssertTrue(r.md.contains("> 名字更正：逐字稿照名冊改了 2 處（林曉安→林小安、星核計畫→星河計畫）；沒改：梅玲→陳美玲？"))
        XCTAssertTrue(r.md.contains("- [00:12][我方] 星河計畫骨架版先做半天\n- [01:05][遠端] 林小安說預算三十萬\n- [02:10][我方] 要不要買憑證，梅玲說明天"))
        XCTAssertTrue(r.md.contains("梅玲 [[?]]提到憑證"), "沒把握的在摘要標 [[?]]")
        XCTAssertTrue(r.md.contains("## 待辦\n- 無"), "跟 OPEN.md 同一條的待辦不再開")
        XCTAssertTrue(r.summary.contains("[[?]]"))
        XCTAssertFalse(RecordMD.clientVersion(md: r.md).contains("名字更正"), "客戶版不帶這一行")

        let local = Fake("endpoint", reply)
        _ = Polish.buildNotes(input, provider: local)
        XCTAssertFalse(local.user.contains("名冊"), "本機小模型不帶名冊")
        input.scene = .interview
        let interview = Fake("fake", reply)
        _ = Polish.buildNotes(input, provider: interview)
        XCTAssertFalse(interview.user.contains("名冊"), "訪談不帶名冊")
    }
}
