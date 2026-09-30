// PauseTests — 錄音中途暫停：時間帳、逐字稿標記、給模型的合併稿、紀錄表頭、meta 相容（全部沙箱、不碰真資料、不開音訊裝置）
import Foundation
import XCTest
@testable import HearbyCore

final class PauseTests: XCTestCase {
    var box: URL!
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    override func setUp() {
        box = FileManager.default.temporaryDirectory.appendingPathComponent("hearby-pause-\(UUID().uuidString)")
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
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    // MARK: 時間帳

    func testPauseResumeSubtractsPausedTime() {
        var c = RecordingClock(startedAt: t0)
        XCTAssertEqual(c.recorded(at: at(60)), 60, accuracy: 0.001)
        XCTAssertTrue(c.pause(at: at(60)))
        XCTAssertFalse(c.pause(at: at(70)), "已經在暫停，再按一次不算")
        XCTAssertTrue(c.isPaused)
        XCTAssertEqual(c.recorded(at: at(120)), 60, accuracy: 0.001, "暫停中計時停住")
        XCTAssertEqual(c.currentPause(at: at(120)), 60, accuracy: 0.001)
        XCTAssertTrue(c.resume(at: at(120)))
        XCTAssertFalse(c.resume(at: at(121)), "沒在暫停，按繼續不算")
        XCTAssertEqual(c.recorded(at: at(180)), 120, accuracy: 0.001, "錄 60＋停 60＋錄 60＝有錄到 120")
        XCTAssertEqual(c.pauses.count, 1)
        XCTAssertEqual(c.pauses[0].atSeconds, 60, accuracy: 0.001, "暫停位置＝當時錄到的秒數")
        XCTAssertEqual(c.pauses[0].seconds ?? -1, 60, accuracy: 0.001)
    }

    func testSleepWhilePausedIsNotSubtractedTwice() {
        var c = RecordingClock(startedAt: t0)
        c.pause(at: at(100))
        XCTAssertFalse(c.noteSleep(at: at(110)), "暫停中睡著不記：那段本來就不錄")
        XCTAssertFalse(c.noteWake(at: at(400)), "暫停中睡醒不用提醒使用者")
        c.resume(at: at(500))
        XCTAssertEqual(c.recorded(at: at(560)), 160, accuracy: 0.001, "只扣暫停的 400 秒，不重複扣睡眠")
        XCTAssertFalse(c.sleptWhileRecording)
    }

    func testSleepWhileRecordingStillSubtracted() {
        var c = RecordingClock(startedAt: t0)
        XCTAssertTrue(c.noteSleep(at: at(30)))
        XCTAssertTrue(c.noteWake(at: at(90)))
        XCTAssertEqual(c.recorded(at: at(100)), 40, accuracy: 0.001)
        XCTAssertTrue(c.sleptWhileRecording)
        XCTAssertEqual(c.sleepSeconds, 60, accuracy: 0.001)
    }

    func testStopWhilePausedClosesTheSpan() {
        var c = RecordingClock(startedAt: t0)
        c.pause(at: at(50))
        c.close(at: at(80))
        XCTAssertFalse(c.isPaused)
        XCTAssertEqual(c.recorded(at: at(80)), 50, accuracy: 0.001)
        XCTAssertNotNil(c.pauses.last?.ended, "停止時把進行中的暫停結掉")
        // 最後一段暫停後面沒再錄到東西＝不是「中途」暫停，紀錄上不標
        XCTAssertTrue(PauseSpan.midPauses(c.pauses, totalSeconds: 50).isEmpty)
    }

    func testMicWatchAlertsAfterTwoSilentMinutesAndRecovers() {
        var w = MicWatch(now: t0)
        XCTAssertNil(w.update(level: 0.0, now: at(60)))
        XCTAssertNil(w.update(level: 0.001, now: at(119)))
        XCTAssertEqual(w.update(level: 0.0, now: at(120)), .silent, "連續兩分鐘沒聲音＝提醒一次")
        XCTAssertNil(w.update(level: 0.0, now: at(200)), "已經提醒過，不重複")
        XCTAssertEqual(w.update(level: 0.2, now: at(201)), .recovered, "有聲音了＝收掉提醒")
        XCTAssertNil(w.update(level: 0.0, now: at(300)), "重新算兩分鐘")
        w.reset(now: at(310))   // 暫停後繼續
        XCTAssertNil(w.update(level: 0.0, now: at(400)))
        XCTAssertEqual(w.update(level: 0.0, now: at(430)), .silent)
        // 一般房間底噪（實測中位數 0.044）在門檻之上：不會誤響
        var room = MicWatch(now: t0)
        XCTAssertNil(room.update(level: 0.044, now: at(500)))
    }

    // MARK: 紀錄上的標記

    func testDurText() {
        XCTAssertEqual(PauseSpan.durText(40), "40 秒")
        XCTAssertEqual(PauseSpan.durText(12 * 60 + 20), "12 分鐘")
        XCTAssertEqual(PauseSpan.durText(3600), "1 小時")
        XCTAssertEqual(PauseSpan.durText(3600 + 5 * 60), "1 小時 5 分鐘")
    }

    func testWeaveInsertsMarkerBeforeFirstLineAfterPause() {
        let p = PauseSpan(atSeconds: 60, began: at(60), ended: at(60 + 12 * 60))
        let lines: [(fromMs: Int, text: String)] = [(0, "- [00:00][現場] 開場"), (30_000, "- [00:30][現場] 第一件事"), (61_000, "- [01:01][現場] 回來了"), (90_000, "- [01:30][現場] 結論")]
        let out = PauseSpan.weave(lines, pauses: [p], totalSeconds: 120)
        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(out[1], "- [00:30][現場] 第一件事")
        XCTAssertTrue(PauseSpan.isMarker(out[2]), "標記在暫停之後第一句的前面：\(out[2])")
        XCTAssertTrue(out[2].contains("暫停了 12 分鐘"))
        XCTAssertTrue(out[2].contains("這段沒有錄"))
        XCTAssertEqual(out[3], "- [01:01][現場] 回來了")
        let note = PauseSpan.note([p], totalSeconds: 120)
        XCTAssertEqual(note, "中途暫停 1 次，共 12 分鐘（暫停時沒有錄音，逐字稿裡標了位置）")
    }

    func testMarkerLandsBeforeSegmentStartingExactlyAtTheCut() {
        // 聽打從暫停位置切開後，第二片的第一句起點＝切點（整數毫秒）；暫停位置帶小數也要判成「之後」
        let p = PauseSpan(atSeconds: 14.2369, began: at(14), ended: at(24))
        let lines: [(fromMs: Int, text: String)] = [(0, "- [00:00][遠端] 前"), (p.atMs, "- [00:14][遠端] 後")]
        let out = PauseSpan.weave(lines, pauses: [p], totalSeconds: 30)
        XCTAssertEqual(out.count, 3)
        XCTAssertTrue(PauseSpan.isMarker(out[1]), "\(out)")
        XCTAssertEqual(Transcriber.split([(0, 30_000)], at: [p.atMs]).map { $0.0 }, [0, p.atMs], "聽打切點跟標記用同一個位置")
        XCTAssertEqual(Transcriber.split([(0, 30_000)], at: [1_000]).count, 1, "切出來不到 2 秒就不切")
    }

    func testWeaveSkipsTrailingAndOpenPauses() {
        let trailing = PauseSpan(atSeconds: 119.5, began: at(200), ended: at(260))
        let open = PauseSpan(atSeconds: 50, began: at(100), ended: nil)
        let lines: [(fromMs: Int, text: String)] = [(0, "- [00:00][現場] a"), (60_000, "- [01:00][現場] b")]
        XCTAssertEqual(PauseSpan.weave(lines, pauses: [trailing, open], totalSeconds: 120), lines.map(\.text))
        XCTAssertNil(PauseSpan.note([trailing, open], totalSeconds: 120))
    }

    func testMarkerSurvivesMergeForModelAndIsNotMergedIntoSpeech() {
        let marker = PauseSpan(atSeconds: 10, began: at(10), ended: at(70)).markerLine
        let t = ["- [00:01][現場] 第一句", "- [00:05][現場] 第二句", marker, "- [00:11][現場] 第三句"].joined(separator: "\n")
        let merged = Transcriber.mergedForLLM(t).components(separatedBy: "\n")
        XCTAssertEqual(merged.count, 3, "前兩句併成一段，標記自成一行，第三句不併進去：\(merged)")
        XCTAssertEqual(merged[1], marker)
        XCTAssertTrue(merged[2].hasPrefix("- [00:11][現場] 第三句"))
    }

    func testTranscriptOnlyRecordCarriesPauseHeaderAndMarker() {
        let p = PauseSpan(atSeconds: 60, began: at(60), ended: at(60 + 15 * 60))
        let transcript = PauseSpan.weave([(0, "- [00:00][現場] 開場"), (70_000, "- [01:10][現場] 回來了")], pauses: [p], totalSeconds: 130).joined(separator: "\n")
        var input = Polish.Input(transcript: transcript, title: "週會", attendees: "", dateStr: "2026-09-25 10:00", durStr: "2分10秒", warnings: [], audioLine: "/tmp/a.m4a")
        input.pauseNote = PauseSpan.note([p], totalSeconds: 130)
        let (md, _, err) = Polish.buildNotes(input, provider: nil)
        XCTAssertNil(err)
        XCTAssertTrue(md.contains("> ⏸ 中途暫停 1 次，共 15 分鐘"), md)
        XCTAssertTrue(md.contains(p.markerLine))
        // 表頭第一行（時長）格式不變：解析時長的地方不受影響
        let rec = RecordMD.parse(md: md)
        XCTAssertEqual(rec.parts.dur, "2分10秒")
        XCTAssertEqual(rec.parts.custom, "週會")
        // 逐字稿段原樣保留標記（重新整理全篇從這裡讀回去）
        XCTAssertTrue(RecordMD.transcript(of: md)?.contains(p.markerLine) == true)
    }

    // MARK: meta.json

    func testMetaRoundTripsPausesAndOldFilesStillLoad() throws {
        let dir = box.appendingPathComponent("w1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var m = MeetingMeta()
        m.title = "暫停測試"; m.seconds = 120
        m.pauses = [PauseSpan(atSeconds: 60, began: at(60), ended: at(120))]
        Pipeline.saveMeta(m, to: dir)
        let back = try XCTUnwrap(Pipeline.loadMeta(dir))
        XCTAssertEqual(back.pauses?.count, 1)
        XCTAssertEqual(back.pauses?[0].atSeconds ?? -1, 60, accuracy: 0.001)
        XCTAssertEqual(back.pauses?[0].seconds ?? -1, 60, accuracy: 1)
        // 2.0.1 以前寫的 meta.json（沒有 pauses 欄）照樣讀得到
        let old = """
        {"title":"舊的","attendees":"","started":"2026-09-20T10:00:00Z","seconds":300,"micMax":0.5,"sysMax":0,"warnings":[]}
        """
        let dir2 = box.appendingPathComponent("w2")
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try old.write(to: dir2.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        let o = try XCTUnwrap(Pipeline.loadMeta(dir2))
        XCTAssertEqual(o.title, "舊的")
        XCTAssertNil(o.pauses)
    }

    func testConfigFloatingBarDefaultsOnAndOldConfigLoads() throws {
        XCTAssertTrue(Config().floatingBarOn)
        let old = #"{"schemaVersion":1,"provider":"claude"}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(Config.self, from: old)
        XCTAssertTrue(c.floatingBarOn, "舊設定檔沒有這個欄位＝開")
        try ConfigStore.shared.update { $0.floatingBar = false }
        ConfigStore.shared.reset()
        XCTAssertFalse(ConfigStore.shared.current.floatingBarOn)
    }
}

// MARK: - 本機模型端點（不連網路的部分）

final class LocalEndpointTests: XCTestCase {
    func testURLPolicy() {
        XCTAssertNil(LocalEndpoint.urlProblem("http://127.0.0.1:11434"))
        XCTAssertNil(LocalEndpoint.urlProblem("http://localhost:1234/v1"))
        XCTAssertNil(LocalEndpoint.urlProblem("http://100.101.102.103:11434"), "Tailscale 內網（100.64.0.0/10）")
        XCTAssertNil(LocalEndpoint.urlProblem("http://llm-box.example-tailnet.ts.net:11434"))
        XCTAssertNil(LocalEndpoint.urlProblem("https://llm.example.com"))
        XCTAssertNotNil(LocalEndpoint.urlProblem("http://192.168.1.20:11434"), "區網不加密的 http 不接")
        XCTAssertNotNil(LocalEndpoint.urlProblem("http://100.200.1.1:11434"), "100.128 以上不是 Tailscale 的段")
        XCTAssertNotNil(LocalEndpoint.urlProblem("ftp://127.0.0.1"))
        XCTAssertNotNil(LocalEndpoint.urlProblem("127.0.0.1:11434"), "沒寫 http:// 看不懂")
        XCTAssertEqual(LocalEndpoint.root("http://127.0.0.1:1234/v1/"), "http://127.0.0.1:1234")
    }

    func testContextSizingByMemory() {
        let gb: UInt64 = 1_073_741_824
        XCTAssertEqual(LocalEndpoint.maxContextTokens(physicalMemory: 8 * gb), 16_384)
        XCTAssertEqual(LocalEndpoint.maxContextTokens(physicalMemory: 16 * gb), 32_768)
        XCTAssertEqual(LocalEndpoint.maxContextTokens(physicalMemory: 64 * gb), 65_536)
        // 短會：至少開 8K；一小時的會（約 1 萬 5 千字）：開到剛好夠、4K 一級
        XCTAssertEqual(LocalEndpoint.contextFor(systemChars: 2000, userChars: 800, maxOutput: 6000, cap: 32_768), 12_288)
        XCTAssertEqual(LocalEndpoint.contextFor(systemChars: 2000, userChars: 15_000, maxOutput: 6000, cap: 32_768), 24_576)
        XCTAssertNil(LocalEndpoint.contextFor(systemChars: 2000, userChars: 30_000, maxOutput: 6000, cap: 32_768), "吃不下就明說，不偷偷截斷")
    }

    func testThinkingBlocksAreStripped() {
        XCTAssertEqual(LocalEndpoint.stripThinking("<think>\n先想一下\n</think>\n\n## 摘要\n- 一件事"), "## 摘要\n- 一件事")
        XCTAssertEqual(LocalEndpoint.stripThinking("## 摘要\n- 沒有思考段"), "## 摘要\n- 沒有思考段")
    }

    func testProviderFactoryKnowsEndpoint() {
        XCTAssertEqual(Providers.make("endpoint").id, "endpoint")
        XCTAssertTrue(Providers.all.contains { $0.id == "endpoint" })
    }
}

// MARK: - 待辦期限：時間戳不是期限

final class TodoDueGuardTests: XCTestCase {
    func testTimestampInDueColumnIsCleared() {
        let src = "- [01:55][現場] 那我禮拜五前把圖重做\n- [1:02:03][現場] 好"
        let md = """
        ## 待辦
        - [ ] 重做第三區段的圖｜現場A｜01:55
        - [ ] 另一件｜｜[1:02:03]
        - [ ] 圖重做｜現場A｜禮拜五前
        """
        let out = PolishGuards.sanitizeTodoDues(notesMD: md, sourceText: src).components(separatedBy: "\n")
        XCTAssertEqual(out[1], "- [ ] 重做第三區段的圖｜現場A｜", "時間戳出現在原文裡也不算期限")
        XCTAssertEqual(out[2], "- [ ] 另一件｜｜")
        XCTAssertEqual(out[3], "- [ ] 圖重做｜現場A｜禮拜五前", "照抄原話的期限留著")
    }
}

final class LocalModelLabelTests: XCTestCase {
    func testClientVersionDropsLocalModelNoteButKeepsPauseLine() {
        let md = """
        # 會議紀錄 2026-09-25 10:00

        > Hearby 錄音｜時長 30分0秒｜週會
        > 音檔：/tmp/a.m4a
        > ⏸ 中途暫停 1 次，共 12 分鐘（暫停時沒有錄音，逐字稿裡標了位置）
        > 本機模型整理（qwen3:4b-instruct）：比雲端整理簡略，決議與待辦請對照逐字稿再看一次

        ## 摘要
        一句話 [00:10]
        """
        let c = RecordMD.clientVersion(md: md)
        XCTAssertFalse(c.contains("本機模型整理"), "內部提醒不進客戶版")
        XCTAssertFalse(c.contains("/tmp/a.m4a"))
        XCTAssertTrue(c.contains("中途暫停 1 次"))
        XCTAssertFalse(c.contains("[00:10]"))
    }
}

final class PlaceholderOwnerTests: XCTestCase {
    func testPlaceholderOwnersClearedRealNamesKept() {
        let md = """
        ## 待辦
        - [ ] 篩選案例｜現場A｜
        - [ ] 設計櫻桃｜現場C｜禮拜五前
        - [ ] 回覆報價｜Kevin｜月底
        - [ ] 問電視部門｜遠端｜
        ## 開放問題
        - 現場A 說的｜現場B｜
        """
        let out = PolishGuards.clearPlaceholderOwners(notesMD: md).components(separatedBy: "\n")
        XCTAssertEqual(out[1], "- [ ] 篩選案例｜｜")
        XCTAssertEqual(out[2], "- [ ] 設計櫻桃｜｜禮拜五前", "期限照留")
        XCTAssertEqual(out[3], "- [ ] 回覆報價｜Kevin｜月底", "真的人名留著")
        XCTAssertEqual(out[4], "- [ ] 問電視部門｜｜")
        XCTAssertEqual(out[6], "- 現場A 說的｜現場B｜", "待辦以外的節不動")
    }
}
