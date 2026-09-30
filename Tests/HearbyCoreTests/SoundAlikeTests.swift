import XCTest
@testable import HearbyCore

/// 讀音比對（名字都是假的）：候選怎麼挑、怎麼排，簡稱守門
final class SoundAlikeTests: XCTestCase {
    static let roster = """
        - 林小安｜小安｜林曉安｜產品經理｜
        - 星河計畫｜｜｜年度企劃｜
        - 藏寶圖 App｜藏寶圖｜｜手機遊戲｜藏＝ㄗㄤˋ
        """

    func testReadingOverridesTable() {
        XCTAssertEqual(Pinyin.of("藏"), "cang")
        let t = SoundAlike.targets(roster: Self.roster).targets
        XCTAssertEqual(t.first { $0.name == "藏寶圖" }?.syllables, ["zang", "bao", "tu"])
        XCTAssertEqual(t.first { $0.name == "小安" }?.rank, 0)                       // 別名，也是「林小安」的名字兩字
        XCTAssertEqual(Pinyin.key("zheng"), Pinyin.key("zen"))                         // 翹舌、ㄣㄥ不分
        XCTAssertEqual(Pinyin.coarse("tian"), Pinyin.coarse("dian"))                   // 送氣不送氣：差一點
        XCTAssertNotEqual(Pinyin.key("tian"), Pinyin.key("dian"))
    }

    func testScanSkipsKnownStopWordsAndCoveredParts() {
        let t = SoundAlike.targets(roster: Self.roster)
        let tr = "- [00:05][我方] 林曉安說新河計畫先做，有人問葬寶圖\n- [00:30][我方] 新河計畫第二版"
        let hits = SoundAlike.scan(tr, targets: t.targets, heard: t.heard)
        // 「林曉安」是名冊寫的聽錯寫法（遮掉，連裡面的「曉安」也不列）；「新河」被「新河計畫」蓋住；「有人」有停用字
        XCTAssertEqual(hits.map(\.heard), ["新河計畫", "葬寶圖"])
        XCTAssertEqual(hits[0].count, 2)
        XCTAssertEqual(hits[0].stamps, ["00:05", "00:30"])
        XCTAssertEqual(SoundAlike.lines(hits), ["- 新河計畫 → 星河計畫？×2 [00:05] [00:30]", "- 葬寶圖 → 藏寶圖？ [00:05]"])
    }

    func testShortFormNeedsToSoundAlike() {
        let names = ["星河計畫"]
        let tr = "- [00:05][我方] 新和明天開工"
        let ok = NameFixes.apply([NameFixes.Fix(heard: "新和", name: "星河", sure: true, stamps: ["00:05"])], transcript: tr, names: names)
        XCTAssertEqual(ok.transcript, "- [00:05][我方] 星河明天開工")
        let no = NameFixes.apply([NameFixes.Fix(heard: "明天", name: "星河", sure: true, stamps: ["00:05"])], transcript: tr, names: names)
        XCTAssertEqual(no.transcript, tr)
        XCTAssertEqual(no.skipped.count, 1)
    }
}
