// NameLedgerTests — 名字確認帳（memory/NAMES.md）：改一次就記住、撞名檢查、要確認只問一次、帶進下一場
// 名字全是假的（公開倉）。
import Foundation
import XCTest
@testable import HearbyCore

final class NameLedgerTests: XCTestCase {
    var box: URL!
    override func setUp() {
        box = FileManager.default.temporaryDirectory.appendingPathComponent("hearby-names-\(UUID().uuidString)")
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

    static let sample = """
        # 名字確認帳
        <!-- - 註解裡 → 不算 -->
        ## 名字
        - 林曉安 → 林小安｜一律｜你在 Hearby 改的｜2026-09-20｜2026-09-20_1400_週會
        - 梅玲 → 陳美玲｜看上下文｜重新整理時的更正｜2026-09-21｜2026-09-21_1000_週會
        - 小星 → 星河計畫｜不換｜你在 Hearby 改的｜2026-09-21｜2026-09-21_1000_週會
        - 「星核」→「星河計畫」
        ## 要確認
        - 凌那邊 → 林那邊？｜2026-09-22_0900_週會｜是
        - 阿明 → 王小明？｜2026-09-22_0900_週會｜不是
        - 小花 → 陳美玲？｜2026-09-22_0900_週會｜
        """

    func testParse() {
        let (e, q) = NameLedger.parse(Self.sample)
        XCTAssertEqual(e.map { "\($0.heard)→\($0.name)=\($0.how)" }, ["林曉安→林小安=一律", "梅玲→陳美玲=看上下文", "小星→星河計畫=不換", "星核→星河計畫=看上下文"],
                       "沒寫換法的（使用者自己加的一行）當看上下文；註解裡的不算")
        XCTAssertEqual(q.map { "\($0.heard)→\($0.name)|\($0.answer)" }, ["凌那邊→林那邊|是", "阿明→王小明|不是", "小花→陳美玲|"])
        XCTAssertTrue(q[0].yes); XCTAssertTrue(q[1].no); XCTAssertFalse(q[2].yes || q[2].no)
    }

    func testAddingKeepsSectionsAndAsksOnce() {
        let first = NameLedger.adding(entries: [NameLedger.Entry(heard: "林曉安", name: "林小安", how: "一律", who: "你", date: "2026-09-20", meeting: "m1")],
                                      questions: [NameLedger.Question(heard: "梅玲", name: "陳美玲", meeting: "m1")], to: nil)
        XCTAssertTrue(first.hasPrefix(NameLedger.header.components(separatedBy: "\n")[0]))
        XCTAssertTrue(first.contains("## 名字\n- 林曉安 → 林小安｜一律｜你｜2026-09-20｜m1\n\n## 要確認\n- 梅玲 → 陳美玲？｜m1｜\n"))
        let again = NameLedger.adding(entries: [NameLedger.Entry(heard: "林曉安", name: "林小安", how: "一律")],
                                      questions: [NameLedger.Question(heard: "梅玲", name: "陳美玲", meeting: "m2"),
                                                  NameLedger.Question(heard: "林曉安", name: "林小安", meeting: "m2")], to: first)
        XCTAssertEqual(again, first, "記過的不再記、問過的不再問、已經確認的名字不用問")
        let more = NameLedger.adding(entries: [NameLedger.Entry(heard: "星核", name: "星河計畫", how: "一律", meeting: "m2")], to: first)
        XCTAssertTrue(more.contains("- 林曉安 → 林小安｜一律｜你｜2026-09-20｜m1\n- 星核 → 星河計畫｜一律｜｜｜m2\n\n## 要確認"), "加在那一節尾巴、空行之前")
    }

    func testAnsweringAndContext() {
        let answered = NameLedger.answering(heard: "小花", name: "陳美玲", answer: "是", in: Self.sample)
        XCTAssertTrue(answered.contains("- 小花 → 陳美玲？｜2026-09-22_0900_週會｜是"))
        let (e, q) = NameLedger.parse(answered)
        XCTAssertEqual(NameLedger.contextLines(e, q), [
            "## 確認過的名字",
            "- 林小安｜｜林曉安｜確認過｜",
            "- 陳美玲｜｜梅玲（看上下文）、小花（看上下文）｜確認過｜",
            "- 星河計畫｜｜星核（看上下文）｜確認過｜",
            "- 林那邊｜｜凌那邊（看上下文）｜確認過｜",
            "## 確認過不是聽錯",
            "- 「小星」不是星河計畫：不要換",
            "- 「阿明」不是王小明：不要換",
        ])
        XCTAssertEqual(NameLedger.aliasPairs(e).map { "\($0.alias)→\($0.canonical)" }, ["林曉安→林小安"], "只有一律的聽打完直接換")
    }

    func testClassify() {
        let others = [(id: "m2", transcript: "- [00:01][我方] 梅玲說好"), (id: "m1", transcript: "- [00:01][我方] 林曉安在這場")]
        XCTAssertEqual(NameLedger.classify(heard: "林曉安", meeting: "m1", others: others, known: ["林小安"]), "一律", "別場沒出現、不是別的名字的一部分")
        XCTAssertEqual(NameLedger.classify(heard: "梅玲", meeting: "m1", others: others, known: []), "看上下文", "別場逐字稿出現過")
        XCTAssertEqual(NameLedger.classify(heard: "小安", meeting: "m1", others: others, known: ["林小安"]), "看上下文", "是名冊上別的名字的一部分")
        XCTAssertEqual(NameLedger.classify(heard: "喊", meeting: "m1", others: others, known: []), "看上下文", "一個字")
    }

    func testPairsFromCorrections() {
        let p = NameLedger.pairs(fromCorrections: "「林曉安」應為「林小安」；「預算三十萬」改成「預算三十五萬」；「他」應為「她」；「星核」是「星河計畫」", known: ["林小安"])
        XCTAssertEqual(p.map { "\($0.heard)→\($0.name)" }, ["林曉安→林小安", "星核→星河計畫"], "數字與一個字的不算名字")
    }

    static let before = """
        # 會議紀錄 2026-09-20 14:00

        ## AI 會議摘要
        林曉安說明星核計畫的預算三十萬，動畫部門下週交。
        ## 重點
        - 林曉安、梅玲負責提案 [00:12]

        ---

        ## 逐字稿
        - [00:12][我方] 林曉安跟梅玲說星核計畫要趕
        - [01:05][遠端] Cloud Code 可以幫忙，動畫部門下週交
        - [02:10][我方] 預算三十萬
        """

    func testPairsFromEdit() {
        let after = Self.before
            .replacingOccurrences(of: "林曉安", with: "林小安")
            .replacingOccurrences(of: "星核計畫", with: "星河計畫")
            .replacingOccurrences(of: "Cloud Code", with: "Claude Code")
            .replacingOccurrences(of: "預算三十萬", with: "預算三十五萬")
            .replacingOccurrences(of: "- [01:05][遠端] Cloud Code 可以幫忙，動畫部門下週交", with: "- [01:05][遠端] Cloud Code 可以幫忙，動劃部門下週交")
        let p = NameLedger.pairs(old: Self.before, new: after, known: ["林小安", "星河計畫", "Claude Code", "陳美玲"])
        XCTAssertEqual(p.map { "\($0.heard)→\($0.name)" }, ["林曉安→林小安", "星核計畫→星河計畫", "Cloud Code→Claude Code"],
                       "名字與案子名記下；數字改動、名冊蓋不住又只改一次的一個字（畫→劃）不算；英文補成名冊上的名字")
        let summaryOnly = Self.before.replacingOccurrences(of: "林曉安說明", with: "林小安說明")
        XCTAssertEqual(NameLedger.pairs(old: Self.before, new: summaryOnly, known: ["林小安"]).map { "\($0.heard)→\($0.name)" }, ["林曉安→林小安"],
                       "只改摘要：改成的剛好是名冊上的名字才算")
        XCTAssertTrue(NameLedger.pairs(old: Self.before, new: Self.before.replacingOccurrences(of: "林曉安說明", with: "林大華說明"), known: ["林小安"]).isEmpty,
                      "只改摘要、改成的不是名冊上的名字：不算（可能是改內容）")
        let two = Self.before.replacingOccurrences(of: "林曉安、梅玲", with: "林小安、陳美玲")
        XCTAssertEqual(NameLedger.pairs(old: Self.before, new: two, known: ["林小安", "陳美玲"]).map { "\($0.heard)→\($0.name)" }, ["林曉安→林小安", "梅玲→陳美玲"],
                       "隔一個標點的兩個名字分開記")
    }

    func testQuestionsFromRecord() {
        let md = "# 會議紀錄\n\n> 名字更正：逐字稿照名冊改了 2 處（林曉安→林小安 ×2）；沒改：梅玲→陳美玲？、凌→林小安？（沒把握，或名冊、逐字稿對不上；紀錄裡提到的地方標了 [[?]]）\n"
        XCTAssertEqual(NameLedger.questions(fromRecord: md, meeting: "m1").map { "\($0.heard)→\($0.name)|\($0.meeting)" }, ["梅玲→陳美玲|m1", "凌→林小安|m1"])
        XCTAssertTrue(NameLedger.questions(fromRecord: "# 沒有表頭", meeting: "m1").isEmpty)
    }

    /// 整條路：自己改 → 記進帳（撞名檢查）→ 下一場的名冊與聽打替換都有；別的程式改 → --memory-rebuild 學；AI 沒把握的 → 問一次
    /// 沒改的超過 6 組：表頭全列、每一組都變成一題，不出「…等 N 組」怪題
    func testQuestionsFromLongHeader() {
        let u = (1...9).map { NameFixes.Fix(heard: "疑\($0)", name: "名\($0)", sure: false, stamps: []) }
        let md = "# 紀錄\n\n" + NameFixes.headerLine(applied: [], unsure: u)! + "\n"
        XCTAssertEqual(NameLedger.questions(fromRecord: md, meeting: "m").map { $0.heard + "→" + $0.name }, u.map { $0.heard + "→" + $0.name })
        let old = "> 名字更正：沒改：疑1→名1？、疑2→名2？…等 9 組（沒把握，或名冊、逐字稿對不上；紀錄裡提到的地方標了 [[?]]）"
        XCTAssertEqual(NameLedger.questions(fromRecord: old, meeting: "m").map(\.name), ["名1", "名2"])
    }

    func testLearnLoop() throws {
        try ConfigStore.shared.update { $0.memoryEnabled = true }
        try MemoryStore.ensure()
        func meeting(_ id: String, _ md: String) throws -> URL {
            let d = Paths.meetings.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let u = d.appendingPathComponent(id + ".md")
            try md.write(to: u, atomically: true, encoding: .utf8)
            return u
        }
        _ = try meeting("2026-09-10_1000_舊會", "# 會議紀錄\n\n---\n\n## 逐字稿\n- [00:01][我方] 梅玲今天請假")
        let u = try meeting("2026-09-20_1400_週會", Self.before)
        XCTAssertTrue(NameLedger.learn(old: Self.before, new: Self.before, who: "你", mdURL: u).isEmpty)

        // 1) 自己改：林曉安→林小安（別場沒出現＝一律）、梅玲→陳美玲（舊會出現過＝看上下文）
        let after = Self.before.replacingOccurrences(of: "林曉安", with: "林小安").replacingOccurrences(of: "梅玲", with: "陳美玲")
        try after.write(to: u, atomically: true, encoding: .utf8)
        let learned = NameLedger.learn(old: Self.before, new: after, who: "你在 Hearby 改的", mdURL: u)
        XCTAssertEqual(learned.map { "\($0.heard)→\($0.name)=\($0.how)" }, ["林曉安→林小安=一律", "梅玲→陳美玲=看上下文"])
        XCTAssertTrue(Clean.aliasTable().contains { $0.alias == "林曉安" && $0.canonical == "林小安" }, "一律的聽打完直接換")
        XCTAssertFalse(Clean.aliasTable().contains { $0.alias == "梅玲" }, "看上下文的不直接換")
        let ctx = try XCTUnwrap(PolishContext.load(excluding: "2026-09-20_1400_週會"), "只有名字確認帳、沒有 ROSTER.md 也帶")
        XCTAssertTrue(ctx.roster.hasPrefix("## 確認過的名字\n- 林小安｜｜林曉安｜確認過｜\n- 陳美玲｜｜梅玲（看上下文）｜確認過｜"))
        XCTAssertEqual(ctx.names, ["林小安", "陳美玲"])

        // 2) 記憶同步：記下這一版；別的程式改了（先留 .bak）再 --memory-rebuild → 學到
        _ = try MemoryStore.sync(mdURL: u)
        try FileManager.default.copyItem(at: u, to: u.deletingLastPathComponent().appendingPathComponent("2026-09-20_1400_週會.md.bak-2026-09-21"))
        try after.replacingOccurrences(of: "星核計畫", with: "星河計畫").write(to: u, atomically: true, encoding: .utf8)
        try "- 星河計畫｜星河｜｜年度企劃｜".write(to: Paths.memory.appendingPathComponent("ROSTER.md"), atomically: true, encoding: .utf8)
        let edited = try XCTUnwrap(NameLedger.learnFromEdit(mdURL: u))
        XCTAssertEqual(edited.map { "\($0.heard)→\($0.name)" }, ["星核計畫→星河計畫"])
        _ = try MemoryStore.sync(mdURL: u)
        XCTAssertEqual(NameLedger.learnFromEdit(mdURL: u)?.count, 0, "同步過、沒再改＝沒東西學")
        try after.replacingOccurrences(of: "預算", with: "經費").write(to: u, atomically: true, encoding: .utf8)
        try? FileManager.default.trashItem(at: u.deletingLastPathComponent().appendingPathComponent("2026-09-20_1400_週會.md.bak-2026-09-21"), resultingItemURL: nil)
        XCTAssertNil(NameLedger.learnFromEdit(mdURL: u), "改之前沒留備份（找不到上次那一版）＝學不到，要講出來")

        // 3) AI 沒把握的名字：同步時進「要確認」，答一次（先留備份），之後不再問
        let withAsk = "# 會議紀錄\n\n> 名字更正：沒改：凌那邊→林那邊？（沒把握，或名冊、逐字稿對不上；紀錄裡提到的地方標了 [[?]]）\n\n---\n\n## 逐字稿\n- [00:01][我方] 凌那邊"
        let v = try meeting("2026-09-22_0900_週會", withAsk)
        _ = try MemoryStore.sync(mdURL: v)
        XCTAssertEqual(NameLedger.pending(meeting: "2026-09-22_0900_週會").map(\.heard), ["凌那邊"])
        try NameLedger.answer(heard: "凌那邊", name: "林那邊", yes: false)
        XCTAssertTrue(NameLedger.pending(meeting: "2026-09-22_0900_週會").isEmpty)
        _ = try MemoryStore.sync(mdURL: v)
        XCTAssertTrue(NameLedger.pending(meeting: "2026-09-22_0900_週會").isEmpty, "答過的不再問")
        let files = try FileManager.default.contentsOfDirectory(atPath: Paths.memory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("NAMES.md.bak-") }, "答題改到既有的行，先留備份")
        XCTAssertTrue(PolishContext.load()!.roster.contains("- 「凌那邊」不是林那邊：不要換"))
    }

    func testMemoryOffLearnsNothing() throws {
        let u = Paths.meetings.appendingPathComponent("x/x.md")
        XCTAssertTrue(NameLedger.learn(old: Self.before, new: Self.before.replacingOccurrences(of: "林曉安", with: "林小安"), who: "你", mdURL: u).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.memory.appendingPathComponent(NameLedger.file).path))
    }
}
