// PipelinePartsTests — 聽打解析、清理、紀錄解析、匯出、記憶（全部沙箱、不碰真資料）
import Foundation
import XCTest
@testable import HearbyCore

final class PipelinePartsTests: XCTestCase {
    var box: URL!
    override func setUp() {
        box = FileManager.default.temporaryDirectory.appendingPathComponent("hearby-parts-\(UUID().uuidString)")
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

    func testWhisperJSONParseFiltersJunkAndFoldsRepeats() throws {
        let json = """
        {"transcription":[
          {"offsets":{"from":0,"to":1200},"text":" 今天要討論產品更新,對"},
          {"offsets":{"from":1200,"to":2000},"text":"謝謝觀看"},
          {"offsets":{"from":2000,"to":3000},"text":"今天要討論產品更新，對"},
          {"offsets":{"from":3000,"to":4000},"text":"干净的头发"}
        ]}
        """
        let u = box.appendingPathComponent("w.json")
        try json.write(to: u, atomically: true, encoding: .utf8)
        let r = try Transcriber.parseWhisperJSON(u, offsetMs: 60_000, who: "我方")
        XCTAssertEqual(r.segs.count, 2, "幻聽丟掉、連續重複摺疊")
        XCTAssertEqual(r.segs[0].fromMs, 60_000)
        XCTAssertEqual(r.segs[0].text, "今天要討論產品更新，對", "半形逗號全形化")
        XCTAssertEqual(r.segs[1].text, "乾淨的頭髮", "簡轉繁")
    }

    func testPlanSlicesShortFileNotSplit() {
        let u = box.appendingPathComponent("s.wav")
        FileManager.default.createFile(atPath: u.path, contents: WavIO.header(dataBytes: 0))
        XCTAssertEqual(Transcriber.planSlices(wav: u, totalMs: 60_000).count, 1)
    }

    func testWavSliceRoundTrip() throws {
        let u = box.appendingPathComponent("a.wav")
        var pcm = [Int16](repeating: 0, count: 16000 * 3)   // 3 秒
        for i in 16000..<32000 { pcm[i] = Int16(8000 * sin(Double(i) / 10)) }  // 第 2 秒有聲音
        var d = WavIO.header(dataBytes: UInt64(pcm.count * 2))
        d.append(pcm.withUnsafeBufferPointer { Data(buffer: $0) })
        try d.write(to: u)
        XCTAssertEqual(WavIO.durationMs(of: u), 3000)
        let lv = WavIO.blockLevels(WavIO.readPCM(u, fromMs: 0, toMs: 3000))
        XCTAssertEqual(lv.count, 30)
        XCTAssertLessThan(lv[0], 0.001); XCTAssertGreaterThan(lv[15], 0.1)
        let s = box.appendingPathComponent("slice.wav")
        XCTAssertTrue(WavIO.writeSlice(from: u, fromMs: 1000, toMs: 2000, to: s))
        XCTAssertEqual(WavIO.durationMs(of: s), 1000)
    }

    /// 小聲片不整片丟掉。四種片各自該不該放大
    func testQuietBoostOnlyRescuesQuietSpeech() {
        // 講話的樣子＝兩秒有聲、一秒停（講話佔超過一半時間也要認得）；amp 是取樣振幅
        func bursty(_ amp: Double) -> [Int16] {
            var p = [Int16](repeating: 0, count: 16000 * 10)
            for i in 0..<p.count where (i / 16000) % 3 != 0 { p[i] = Int16(amp * sin(Double(i) / 10)) }
            return p
        }
        let quiet = bursty(60)   // 電平約 0.005：以前整片跳過
        let g = Transcriber.quietBoost(levels: WavIO.blockLevels(quiet), pcm: quiet)
        XCTAssertNotNil(g, "小聲但有起伏＝放大聽打")
        let top = Float(quiet.map { abs(Int($0)) }.max() ?? 1)
        XCTAssertEqual((g ?? 0) * top, 0.7 * 32767, accuracy: 1, "放大到峰值七成滿")

        let loud = bursty(8000)
        XCTAssertNil(Transcriber.quietBoost(levels: WavIO.blockLevels(loud), pcm: loud), "聽得到的片不動（全面拉平音量實測不是乾淨的贏）")

        let silence = [Int16](repeating: 0, count: 16000 * 10)
        XCTAssertNil(Transcriber.quietBoost(levels: WavIO.blockLevels(silence), pcm: silence), "數位靜音照舊跳過")

        var hum = [Int16](repeating: 0, count: 16000 * 10)   // 平穩底噪：一直都在、沒有起伏
        for i in 0..<hum.count { hum[i] = Int16(60 * sin(Double(i) / 10)) }
        XCTAssertNil(Transcriber.quietBoost(levels: WavIO.blockLevels(hum), pcm: hum), "平穩底噪不放大，免得餵幻聽")

        let faint = bursty(1)    // 壓到連上限 1000 倍都拉不滿
        if let f = Transcriber.quietBoost(levels: WavIO.blockLevels(faint), pcm: faint) { XCTAssertLessThanOrEqual(f, Transcriber.quietGainMax) }
    }

    func testWritePCMAppliesGainAndClamps() throws {
        let u = box.appendingPathComponent("g.wav")
        XCTAssertTrue(WavIO.writePCM([10, -10, 20000, -20000], gain: 100, to: u))
        XCTAssertEqual(WavIO.readPCM(u, fromMs: 0, toMs: 1000), [1000, -1000, 32767, -32767], "放大 100 倍；爆掉的夾在邊界、不回捲")
        XCTAssertFalse(WavIO.writePCM([], gain: 2, to: box.appendingPathComponent("e.wav")))
    }

    /// 子行程沒讀 stdin 就結束：以前往它的 pipe 寫會收到 SIGPIPE，整個 app 無聲消失（try? 擋不住）
    func testRunProcessSurvivesChildThatExitsWithoutReadingStdin() {
        let big = String(repeating: "逐字稿", count: 400_000)   // 約 3.6 MB，遠超過 pipe 緩衝
        let r = runProcess("/bin/sh", ["-c", "exit 3"], stdin: big, timeout: 20)
        XCTAssertEqual(r.status, 3, "拿得到子行程的結束碼＝這個行程還活著")
    }

    /// 子行程活著卻不讀 stdin：逾時要照樣生效（以前逾時掛在寫 stdin 之後，write 卡住就永遠不會啟動）
    func testRunProcessTimeoutFiresEvenWhenChildNeverReadsStdin() {
        let big = String(repeating: "x", count: 2_000_000)
        let t0 = Date()
        let r = runProcess("/bin/sleep", ["60"], stdin: big, timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 15)
        XCTAssertNotEqual(r.status, 0, "被逾時收掉")
    }

    /// Codex 一律包在外層沙箱裡：不准讀 /Users 與 /Volumes，只放行它自己要用的幾處
    func testCodexSandboxProfileDeniesHomeAndAllowsOnlyWhatCodexNeeds() {
        let p = CodexCLI.sandboxProfile(bin: "/Applications/ChatGPT.app/Contents/Resources/codex", cwd: "/tmp/hearby-cwd", home: "/opt/fakehome")
        XCTAssertTrue(p.contains("(deny file-read* (subpath \"/Users\"))"))
        XCTAssertTrue(p.contains("(deny file-read* (subpath \"/Volumes\"))"))
        XCTAssertTrue(p.contains("(allow file-read* (subpath \"/opt/fakehome/.codex\"))"))
        XCTAssertTrue(p.contains("(allow file-read* (subpath \"/tmp/hearby-cwd\"))"))
        XCTAssertFalse(p.contains("(allow file-read* (subpath \"/opt/fakehome\"))"), "整個家目錄不可以被放行")
        let npm = CodexCLI.sandboxProfile(bin: "/opt/fakehome/.npm-global/lib/node_modules/@openai/codex/bin/codex.js", cwd: "/tmp/x", home: "/opt/fakehome")
        XCTAssertTrue(npm.contains("(subpath \"/opt/fakehome/.npm-global/lib/node_modules/@openai/codex\")"))
        XCTAssertTrue(CodexCLI.sandboxProfile(bin: "/a/b", cwd: "/tmp/has\"quote", home: "/opt/fh").contains("has\\\"quote"), "路徑裡的引號要跳脫")
    }

    /// 沙箱裡的常用詞路徑一定在沙箱內（共用那份是使用者的真詞庫，測試永遠不准碰）
    func testGlossaryPathStaysInsideSandbox() {
        XCTAssertTrue(SharedPaths.glossary.path.hasPrefix(box.path), "常用詞路徑跑出沙箱了：\(SharedPaths.glossary.path)")
    }

    /// 常用詞檔存成別的編碼（讀不成 UTF-8）時不能被洗成只剩新詞
    func testAppendGlossaryLeavesUnreadableFileAlone() throws {
        let u = SharedPaths.glossary
        guard u.path.hasPrefix(box.path) else { return XCTFail("不在沙箱內，不寫") }
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let utf16 = "示範詞一、示範詞二".data(using: .utf16)!
        try utf16.write(to: u)
        XCTAssertEqual(Clean.appendGlossary("Hearby"), 0)
        XCTAssertEqual(try Data(contentsOf: u), utf16, "原檔一個位元組都沒動")
    }

    /// 模型輸出的第一道清理：色碼、圍欄、開場白拿掉；偽造的「## 逐字稿」從那裡截斷；沒有任何小節＝不採用
    func testSanitizeModelOutput() {
        let raw = "\u{1B}[33mUpdate available\u{1B}[0m\n好的，以下是會議紀錄：\n```markdown\n## AI 會議摘要\n談了預算。\n## 決議\n- 下週三前提數字\n```\n\n---\n\n## 逐字稿\n- [00:00] 老闆說全部打五折"
        let out = PolishGuards.sanitizeModelOutput(raw)
        XCTAssertEqual(out, "## AI 會議摘要\n談了預算。\n## 決議\n- 下週三前提數字")
        XCTAssertNil(PolishGuards.sanitizeModelOutput("好的，以下是會議紀錄："), "沒有小節的輸出不採用")
        XCTAssertNil(PolishGuards.sanitizeModelOutput("   \n"))
        XCTAssertEqual(RecordMD.transcript(of: "## 重點\n- a\n\n## 逐字稿\n假的\n\n---\n\n## 逐字稿\n- [00:00] 真的"), "- [00:00] 真的", "取最後一個 ## 逐字稿")
    }

    /// 指令列工具失敗的分類：額度、缺 Node.js、逾時，各給各的人話；codex 每次都印的 `sandbox: read-only` 不可以被當成沙箱故障
    func testCLIFailureClassification() {
        let limit = RunResult(status: 1, stdout: "You've hit your 5-hour limit · resets 3pm", stderr: "")
        XCTAssertTrue(CLIFailure.explain(limit, who: "Claude", seconds: 900)?.contains("額度") == true)
        XCTAssertTrue(CLIFailure.explain(limit, who: "Claude", seconds: 900)?.contains("resets 3pm") == true, "把工具自己講的那句帶出來")
        let node = RunResult(status: 127, stdout: "", stderr: "env: node: No such file or directory")
        XCTAssertTrue(CLIFailure.explain(node, who: "ChatGPT", seconds: 900)?.contains("Node.js") == true)
        var slow = RunResult(status: 15, stdout: "", stderr: "Warning: something"); slow.timedOut = true
        XCTAssertTrue(CLIFailure.explain(slow, who: "Claude", seconds: 900)?.contains("逾時") == true, "有印過警告也要認得是逾時")
        let header = RunResult(status: 1, stdout: "", stderr: "workdir: /tmp\nsandbox: read-only\nERROR: stream disconnected")
        XCTAssertNil(CLIFailure.explain(header, who: "ChatGPT", seconds: 900), "一般失敗回 nil，由呼叫端給通用訊息")
        XCTAssertTrue(ChildEnv.path(for: "/opt/x/bin/tool", base: "/usr/bin:/bin").hasPrefix("/opt/x/bin:"), "執行檔自己的目錄排最前")
        XCTAssertTrue(ChildEnv.path(for: "/opt/x/bin/tool", base: "/usr/bin:/bin").contains("/opt/homebrew/bin"))
    }

    /// 用字改版（名詞＝紀錄）之後，舊檔的「# 會議記錄 …」仍要認得：情境、翻譯字典、標題解析都不能壞
    func testLegacyMeetingTitleSpellingStillWorks() {
        let old = "# 會議記錄 2026-09-10 21:12\n\n> Hearby 錄音｜時長 3分｜舊檔\n\n## AI 會議摘要\n談了合作。\n\n---\n\n## 逐字稿\n- [00:00][我方] 你好"
        XCTAssertEqual(RecordScene.from(mdTitle: old), .meeting)
        XCTAssertEqual(RecordScene.meeting.mdTitle, "會議紀錄", "新產的檔用名詞寫法")
        XCTAssertEqual(DocLabels.t("會議記錄", "en"), DocLabels.t("會議紀錄", "en"), "翻譯字典新舊 key 都查得到")
        let rec = RecordMD.parse(md: old)
        XCTAssertEqual(rec.parts.custom, "舊檔")
        XCTAssertEqual(RecordMD.transcript(of: old), "- [00:00][我方] 你好")
    }

    func testMergedForLLMChunksSameSpeaker() {
        let t = "- [00:00][我方] 一\n- [00:01][我方] 二\n- [00:02][遠端] 三"
        let m = Transcriber.mergedForLLM(t)
        XCTAssertEqual(m, "- [00:00][我方] 一 二\n- [00:02][遠端] 三")
    }

    func testRecordParseAndClientVersion() {
        let md = """
        # 會議紀錄 2026-09-10 21:12

        > Hearby 錄音｜時長 2小時54分｜甲方合作協議
        > 音檔：/x/y.m4a
        > ⚠ 系統聲音軌全程無聲

        ## AI 會議摘要
        談了合作分潤。細節見下。
        ## 與會者
        - 小明 — 自我介紹（我方）
        - 小華 — 被稱呼（遠端）
        ## 重點
        - **分潤**
        - 五五分 [12:03]
        ## 決議
        - 下週簽 [13:00]
        ## 待辦
        - [ ] 擬合約｜小明｜下週三
        - [x] 寄資料｜小華｜

        ---

        ## 逐字稿
        - [00:00][我方] 你好
        """
        let rec = RecordMD.parse(md: md)
        XCTAssertEqual(rec.parts.custom, "甲方合作協議")
        XCTAssertEqual(rec.parts.dur, "2小時54分")
        XCTAssertEqual(rec.people, ["小明", "小華"])
        XCTAssertEqual(rec.todos.count, 2)
        XCTAssertTrue(rec.todos[1].done)
        let cv = RecordMD.clientVersion(md: md)
        XCTAssertFalse(cv.contains("逐字稿"))
        XCTAssertFalse(cv.contains("[12:03]"))
        XCTAssertFalse(cv.contains("音檔"))
        XCTAssertTrue(cv.contains("- 小明"))
        XCTAssertFalse(cv.contains("自我介紹"))
        let html = Html.render(md: cv)
        XCTAssertTrue(html.contains("class=\"summary\"") && html.contains("table class=\"meta\""))
        XCTAssertTrue(html.contains("擬合約"))
        XCTAssertTrue(html.contains("甲方合作協議"))
        XCTAssertEqual(Polish.threeLines(md: md), ["談了合作分潤。", "細節見下。"], "重點不足兩條就退回摘要句")
    }

    func testSrtSplitsLongSegment() {
        let long = String(repeating: "這是一句很長的話，", count: 12)
        let s = Srt.build([Segment(fromMs: 0, toMs: 30_000, text: long, who: "x"), Segment(fromMs: 30_000, toMs: 31_000, text: "短", who: "x")])
        XCTAssertGreaterThan(s.components(separatedBy: "\n\n").count, 2)
        XCTAssertTrue(s.contains("00:00:30,000 --> 00:00:31,000"))
    }

    func testAliasesApplied() throws {
        try MemoryStore.ensure()
        try "# 人\n\n## Kevin\n- 別名：Kevien、Kevyn\n".write(to: Paths.memory.appendingPathComponent("PEOPLE.md"), atomically: true, encoding: .utf8)
        try "# 詞\nHearby = Herbie, 賀比\n".write(to: Paths.memory.appendingPathComponent("GLOSSARY.md"), atomically: true, encoding: .utf8)
        let (t, n) = Clean.applyAliases("Kevien 說 Herbie 很好，Kevyn 同意")
        XCTAssertEqual(t, "Kevin 說 Hearby 很好，Kevin 同意")
        XCTAssertEqual(n, 3)
    }

    func testMemoryAppendOnceAndOpenItems() throws {
        try ConfigStore.shared.update { $0.memoryEnabled = true }
        let dir = Paths.meetings.appendingPathComponent("2026-09-10_2112_測試")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let md = dir.appendingPathComponent("2026-09-10_2112_測試.md")
        try """
        # 會議紀錄 2026-09-10 21:12

        > Hearby 錄音｜時長 3分｜測試
        ## AI 會議摘要
        談了 A。
        ## 與會者
        - 小明 — x
        ## 決議
        - 做 A [00:10]
        ## 待辦
        - [ ] 寫 A｜小明｜明天
        ## 逐字稿
        - [00:00][我方] 你好
        """.write(to: md, atomically: true, encoding: .utf8)
        try MemoryStore.appendMeeting(mdURL: md)
        try MemoryStore.appendMeeting(mdURL: md)  // 第二次不重寫
        let meetings = try String(contentsOf: Paths.memory.appendingPathComponent("MEETINGS.md"), encoding: .utf8)
        XCTAssertEqual(meetings.components(separatedBy: "## 2026-09-10_2112_測試").count, 2, "只寫一次")
        XCTAssertTrue(meetings.contains("- 決議：做 A"))
        let people = try String(contentsOf: Paths.memory.appendingPathComponent("PEOPLE.md"), encoding: .utf8)
        XCTAssertTrue(people.contains("## 小明"))
        XCTAssertEqual(MemoryStore.openItems(), ["寫 A（小明）"])
        let idx = try JSONSerialization.jsonObject(with: Data(contentsOf: Paths.memory.appendingPathComponent("index.json"))) as? [String: Any]
        XCTAssertEqual((idx?["meetings"] as? [[String: Any]])?.count, 1)
    }

    func testGuardsVerifyCitationsAndOwners() {
        let notes = "## 重點\n- 真的 [00:10]\n- 假的 [09:59]\n## 待辦\n- [ ] 事｜王大朋｜明天\n- [ ] 事二｜路人｜"
        let (v, ghosts) = PolishGuards.verifyCitations(notesMD: notes, transcript: "- [00:10][我方] 嗨")
        XCTAssertEqual(ghosts, 1)
        XCTAssertTrue(v.contains("- 假的\n"))
        let o = PolishGuards.sanitizeTodoOwners(notesMD: notes, attendeeList: "王大明、小華")
        XCTAssertTrue(o.contains("事｜王大明｜明天"))
        XCTAssertTrue(o.contains("事二｜｜"))
    }

    func testMeetingFolderSplit() {
        let (d, t) = MeetingIndex.split(folderName: "2026-09-10_2112_甲方 合作")
        XCTAssertEqual(d, "2026-09-10 21:12"); XCTAssertEqual(t, "甲方 合作")
    }

    /// 重新整理全篇：舊紀錄裡的佔位標籤（現場A／遠端B／電話端／受訪者）不能當「使用者提供的名單」回灌；真名要留
    func testRepolishDropsPlaceholderAttendees() {
        let people = ["現場A（推測）", "現場B", "遠端 2", "電話端", "受訪者", "Speaker C", "王大明（推測）", "現場經理小華", "Kevin"]
        XCTAssertEqual(Repolish.realAttendees(people), ["王大明", "現場經理小華", "Kevin"])
        XCTAssertEqual(Repolish.realAttendees(["現場A", "現場B", "現場C"]), [])
    }
}
