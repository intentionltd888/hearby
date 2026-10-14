// TaigiTests — 國台混講：每段把握、送哪些地方（沒把握的段落＋有人聲的空檔）、整截換字（全部沙箱、不跑模型）
import Foundation
import XCTest
@testable import HearbyCore

final class TaigiTests: XCTestCase {
    var box: URL!
    override func setUp() {
        box = FileManager.default.temporaryDirectory.appendingPathComponent("hearby-taigi-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        setenv("HEARBY_OUTPUT_ROOT", box.appendingPathComponent("root").path, 1)
        setenv("HEARBY_SUPPORT_DIR", box.appendingPathComponent("support").path, 1)
        setenv("HEARBY_LOG_DIR", box.appendingPathComponent("logs").path, 1)
        ConfigStore.shared.reset()
    }
    override func tearDown() {
        if let b = box, b.path.hasPrefix(FileManager.default.temporaryDirectory.path) { try? FileManager.default.removeItem(at: b) }
        unsetenv("HEARBY_OUTPUT_ROOT"); unsetenv("HEARBY_SUPPORT_DIR"); unsetenv("HEARBY_LOG_DIR")
        ConfigStore.shared.reset()
    }

    func seg(_ f: Int, _ t: Int, _ s: String, _ who: String = "現場") -> Segment { Segment(fromMs: f, toMs: t, text: s, who: who) }
    func sc(_ pairs: [(Segment, Double)]) -> [String: Taigi.Score] {
        Dictionary(uniqueKeysWithValues: pairs.map { (Taigi.key($0.0), Taigi.Score(logp: $0.1, tokens: 10)) })
    }
    func result(_ f: Int, _ t: Int, _ segs: [(Segment, Double)]) -> Taigi.SpanResult {
        Taigi.SpanResult(from: f, to: t, segs: segs.map(\.0), scores: sc(segs))
    }

    // MARK: 讀 -ojf

    func testScoresReadTokenProbabilitiesAndSkipSpecialTokens() throws {
        let json = """
        {"transcription":[
          {"offsets":{"from":0,"to":2000},"text":"你好","tokens":[
            {"text":"[_BEG_]","p":0.01},{"text":"你","p":0.9},{"text":"好","p":0.8},{"text":"[_TT_100]","p":0.02}]},
          {"offsets":{"from":2000,"to":4000},"text":"沒有機率"}
        ]}
        """
        let u = box.appendingPathComponent("a.json")
        try json.write(to: u, atomically: true, encoding: .utf8)
        let s = Taigi.scores(u, offsetMs: 60_000)
        XCTAssertEqual(s.count, 1, "沒有 tokens 的段落（不是 -ojf 跑的）不給分數")
        let v = try XCTUnwrap(s["60000-62000"], "key 要加上 offset，跟 parseWhisperJSON 的段落對得上")
        XCTAssertEqual(v.tokens, 2, "[_BEG_]、時間戳不算")
        XCTAssertEqual(v.logp, (log(0.9) + log(0.8)) / 2, accuracy: 1e-9)
    }

    // MARK: 送哪些地方

    func testSpansJoinPadMinLengthAndClamp() {
        let p = [seg(1000, 2000, "a"), seg(2500, 4000, "b"), seg(4000, 9000, "c"), seg(9500, 9800, "d"), seg(20000, 21000, "e")]
        let s = sc([(p[0], -0.8), (p[1], -0.9), (p[2], -0.1), (p[3], -0.7), (p[4], -0.5)])
        let spans = Taigi.spans(p, scores: s, levels: [], from: 0, to: 20_800)
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].0, 800); XCTAssertEqual(spans[0].1, 4200, "a、b 相隔 0.5 秒併成一截，前後各墊 0.2 秒")
        XCTAssertEqual(spans[1].1 - spans[1].0, 1500, "d 只有 0.3 秒：撐到至少 1.5 秒")
        XCTAssertEqual(spans[2].1, 20_800, "夾在這一片的結尾")
    }

    func testVoicedGapIsSentButSilentGapIsNot() {
        // 0–10 秒：主模型只在 0–2 秒、9–10 秒有字。2–6 秒有人聲（主模型跳過了）、6–9 秒是安靜的
        let p = [seg(0, 2000, "前面"), seg(9000, 10_000, "後面")]
        let s = sc([(p[0], -0.1), (p[1], -0.1)])
        var lv = [Float](repeating: 0.001, count: 100)
        for i in 20..<60 { lv[i] = 0.08 }
        let spans = Taigi.spans(p, scores: s, levels: lv, from: 0, to: 10_000)
        XCTAssertEqual(spans.count, 1, "安靜的 6–9 秒不送")
        XCTAssertEqual(spans[0].0, 1800); XCTAssertEqual(spans[0].1, 9200, "跳過的 2–9 秒整段送（空檔算到下一段字開始），前後墊 0.2 秒")
    }

    func testSpansUseSliceOffsetForLevels() {
        // 這一片從 60 秒開始：音量陣列的第 0 格＝60 秒
        let p = [seg(60_000, 61_000, "前面"), seg(65_000, 66_000, "後面")]
        var lv = [Float](repeating: 0.001, count: 60)
        for i in 10..<50 { lv[i] = 0.08 }
        let spans = Taigi.spans(p, scores: sc([(p[0], -0.1), (p[1], -0.1)]), levels: lv, from: 60_000, to: 66_000)
        XCTAssertEqual(spans.map(\.0), [60_800])
    }

    func testPunctuateTurnsSpacesBetweenHanziIntoCommas() {
        XCTAssertEqual(Taigi.punctuate(" 解決糾紛 難道只能打官司 ADR 很方便 "), "解決糾紛，難道只能打官司 ADR 很方便")
    }

    func testPunctuateDropsBreathHallucination() {
        XCTAssertEqual(Taigi.punctuate("惜 我現在要說一下 惜惜 所以不需要我 惜惜喔"), "我現在要說一下，所以不需要我", "單獨成句的「惜」是換氣處的幻聽")
        XCTAssertEqual(Taigi.punctuate("囡仔愛惜惜"), "囡仔愛惜惜", "句子裡的「惜」不動")
    }

    // MARK: 換字

    func testConfidentMandarinIsNeverReplaced() {
        let p = [seg(0, 3000, "今天開會"), seg(3000, 6000, "討論預算")]
        let m = Taigi.merge(primary: p, primaryScores: sc([(p[0], -0.1), (p[1], -0.05)]),
                            results: [result(0, 6000, [(seg(0, 6000, "今仔日開會討論預算"), -0.05)])])
        XCTAssertEqual(m.segs, p, "主模型有把握：台語模型再有把握也不換")
        XCTAssertEqual(m.switched, 0)
    }

    func testUnsureSpanSwitchesWholeWhenTaigiModelIsSurer() {
        let p = [seg(0, 3000, "今天開會"), seg(3000, 5000, "改革求婚"), seg(5000, 8000, "說怎麼可以打冠事"), seg(8000, 11000, "好我們繼續")]
        let m = Taigi.merge(primary: p, primaryScores: sc([(p[0], -0.1), (p[1], -1.2), (p[2], -0.9), (p[3], -0.1)]),
                            results: [result(2800, 8200, [(seg(2800, 8200, "解決糾紛，難道只能打官司"), -0.3)])])
        XCTAssertEqual(m.segs.map(\.text), ["今天開會", "解決糾紛，難道只能打官司", "好我們繼續"], "截內兩段整截換掉，前後有把握的不動")
        XCTAssertEqual(m.segs[1].who, "現場", "講者沿用主模型那一軌")
        XCTAssertEqual(m.switched, 1)
        XCTAssertEqual(m.switchedMs, 5400)
    }

    func testUnsureButTaigiModelNotSurerKeepsPrimary() {
        let p = [seg(0, 3000, "嗯對")]
        let m = Taigi.merge(primary: p, primaryScores: sc([(p[0], -0.5)]), results: [result(0, 3000, [(seg(0, 3000, "嘿啦"), -0.45)])])
        XCTAssertEqual(m.segs, p, "台語模型只高 0.05、不到 margin：不換")
    }

    func testSkippedGapIsFilledOnlyWhenTaigiModelIsSure() {
        let p = [seg(0, 2000, "前面"), seg(9000, 10_000, "後面")]
        let ps = sc([(p[0], -0.1), (p[1], -0.1)])
        let sure = Taigi.merge(primary: p, primaryScores: ps, results: [result(1800, 9200, [(seg(1800, 9200, "免操煩"), -0.3)])])
        XCTAssertEqual(sure.segs.map(\.text), ["前面", "免操煩", "後面"], "主模型跳過的空檔：台語模型有把握就補上")
        let unsure = Taigi.merge(primary: p, primaryScores: ps, results: [result(1800, 9200, [(seg(1800, 9200, "謝謝"), -1.2)])])
        XCTAssertEqual(unsure.segs, p, "台語模型也沒把握（可能是雜音）：不補，不會多出沒人講過的話")
        let off = Taigi.merge(primary: p, primaryScores: ps, results: [result(1800, 9200, [(seg(1800, 9200, "免操煩"), -0.3)])],
                              rule: .init(low: -0.3, margin: 0.1, fillIn: nil))
        XCTAssertEqual(off.segs, p, "fillIn＝nil：只換不補")
    }

    func testPrimaryThatSkippedMostOfTheSpanIsReplaced() {
        // turbo 一段 16 秒只寫一句（其餘跳過），信心還算可以（−0.25，沒低於 −0.3）
        let p = [seg(114_000, 130_000, "那個小美整天打混摸魚")]
        let long = "目前已進入汛期，這也是台灣最容易遭受颱風水災土石流侵襲的時期，請民眾留意氣象資訊，那個小美整天打混摸魚"
        let m = Taigi.merge(primary: p, primaryScores: sc([(p[0], -0.25)]), results: [result(90_000, 130_000, [(seg(90_000, 130_000, long), -0.3)])])
        XCTAssertEqual(m.segs.map(\.text), [long], "台語模型的字多出一倍以上＝主模型漏聽：換")
        let same = Taigi.merge(primary: p, primaryScores: sc([(p[0], -0.25)]), results: [result(90_000, 130_000, [(seg(90_000, 130_000, "那個小美整天在打混摸魚"), -0.3)])])
        XCTAssertEqual(same.segs, p, "字數差不多、主模型也沒低於門檻：不換")
    }

    func testMissingScoresKeepPrimary() {
        // 迴圈修補換進來的段落沒有分數：當成主模型有把握
        let p = [seg(0, 3000, "修補過的段落")]
        XCTAssertEqual(Taigi.merge(primary: p, primaryScores: [:], results: [result(0, 3000, [(seg(0, 3000, "台語"), -0.1)])]).segs, p)
    }
}
