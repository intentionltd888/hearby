// ContractFixtureTests — 兩平台合約：同一組輸入，這份 Swift（macOS 版）跑出來的結果，就是 Windows 版（windows/，C#）的標準答案
//
//   重寫夾具：HEARBY_WRITE_CONTRACT=1 swift test --filter ContractFixtureTests   → contract/fixtures/*.json
//   平常：swift test → 逐檔比對。這裡紅了＝macOS 版的行為變了：確認是有意的，就重寫夾具，並讓 Windows 版跟上（dotnet test 會紅）
//
// 夾具只放合成資料（不放任何真實會議）；時間一律用 Asia/Taipei，兩邊才會算出同一個「幾點幾分」。
import CryptoKit
import Foundation
import XCTest
@testable import HearbyCore

final class ContractFixtureTests: XCTestCase {
    var box: URL!
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixturesDir = repoRoot.appendingPathComponent("contract/fixtures", isDirectory: true)
    static let tz = TimeZone(identifier: "Asia/Taipei")!
    private var writing: Bool { ProcessInfo.processInfo.environment["HEARBY_WRITE_CONTRACT"] == "1" }
    private var savedTZ: TimeZone?

    override func setUp() {
        box = FileManager.default.temporaryDirectory.appendingPathComponent("hearby-contract-\(UUID().uuidString)")
        setenv("HEARBY_OUTPUT_ROOT", box.appendingPathComponent("root").path, 1)
        setenv("HEARBY_SUPPORT_DIR", box.appendingPathComponent("support").path, 1)
        setenv("HEARBY_LOG_DIR", box.appendingPathComponent("logs").path, 1)
        ConfigStore.shared.reset()
        try? Paths.ensure()
        savedTZ = NSTimeZone.default
        NSTimeZone.default = Self.tz
    }

    override func tearDown() {
        if let b = box, b.path.hasPrefix(FileManager.default.temporaryDirectory.path) { try? FileManager.default.removeItem(at: b) }
        unsetenv("HEARBY_OUTPUT_ROOT"); unsetenv("HEARBY_SUPPORT_DIR"); unsetenv("HEARBY_LOG_DIR"); unsetenv("HEARBY_WHISPER_CLI"); unsetenv("HEARBY_TEST_WHISPER_DIR")
        ConfigStore.shared.reset()
        if let t = savedTZ { NSTimeZone.default = t }
    }

    // MARK: - 寫檔／比對

    private func emit(_ name: String, _ cases: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) throws {
        let obj: [String: Any] = ["contract": 1, "name": name, "cases": cases]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let url = Self.fixturesDir.appendingPathComponent(name + ".json")
        if writing {
            try FileManager.default.createDirectory(at: Self.fixturesDir, withIntermediateDirectories: true)
            try (data + Data("\n".utf8)).write(to: url, options: .atomic)
            return
        }
        guard let old = try? Data(contentsOf: url) else {
            XCTFail("缺夾具 \(name).json：先跑 HEARBY_WRITE_CONTRACT=1 swift test --filter ContractFixtureTests", file: file, line: line)
            return
        }
        let a = try JSONSerialization.jsonObject(with: old) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        XCTAssertEqual(a, b, "\(name).json 跟現在的 macOS 邏輯對不上：有意改的話重寫夾具，並讓 Windows 版跟上", file: file, line: line)
    }

    private static func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private static func isoString(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
    private static func any(_ v: String?) -> Any { v.map { $0 as Any } ?? NSNull() }
    private static func any(_ v: Int?) -> Any { v.map { $0 as Any } ?? NSNull() }
    private static func any(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
    private static func any(_ v: Float?) -> Any { v.map { Double($0) as Any } ?? NSNull() }

    // MARK: - 合成音檔（兩邊用同一個算式生：方波，整數，不牽涉三角函數的捨入）

    /// spec：[[秒數, 振幅]…]，振幅 0＝靜音；方波週期 32 個取樣
    static func synthPCM(_ spec: [[Int]]) -> [Int16] {
        var out: [Int16] = []
        for seg in spec {
            let n = seg[0] * 16000, amp = seg[1]
            for i in 0..<n { out.append(Int16(amp == 0 ? 0 : ((i / 16) % 2 == 0 ? amp : -amp))) }
        }
        return out
    }
    static func writeWav(_ pcm: [Int16], to url: URL) throws {
        var d = WavIO.header(dataBytes: UInt64(pcm.count * 2))
        d.append(pcm.withUnsafeBufferPointer { Data(buffer: $0) })
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: url)
    }
    /// quietBoost 的講話樣子：兩秒有聲、一秒停，共 10 秒
    static func bursty(_ amp: Int) -> [Int16] {
        var p = [Int16](repeating: 0, count: 16000 * 10)
        for i in 0..<p.count where (i / 16000) % 3 != 0 { p[i] = Int16((i / 16) % 2 == 0 ? amp : -amp) }
        return p
    }

    // MARK: - 1 清理：標點

    func testCleanPunct() throws {
        let inputs = [
            "今天要討論產品更新,對", "好,我們開始!", "你確定嗎?確定.", "價格是3.5元.下次再說.", "時間:明天;地點:會議室",
            "Hello, world. OK?", "我們用 Claude, 還有 ChatGPT.", "這個.那個", "好.", "結尾是句點.", "A,B,C", "中文,English,中文",
            "數字1,000,中文", "我說:「好」", "…...", "", "講完了. 下一個", "Q3 營收成長 12.5%,毛利率下降", "表情😀,好", "一,二,三.四",
        ]
        try emit("clean_punct", inputs.map { ["input": $0, "expected": Clean.normalizePunct($0)] })
    }

    // MARK: - 2 幻聽濾網

    func testHallucination() throws {
        let inputs: [(String, Int?)] = [
            ("謝謝觀看", nil), ("字幕由Amara.org社區提供", nil), ("中文字幕志願者 李宗盛", nil),
            ("請不吝點贊 訂閱 轉發 打賞支持明鏡與點點欄目", nil), ("訂閱支持", nil), ("要不要訂閱", nil), ("請訂閱", nil),
            ("我們下週要訂閱新的雲端方案，還要評估成本", nil), ("Thank you.", nil), ("you", nil), ("thanks for watching", nil),
            ("中文字幕:CM 李宗盛", nil), ("今天我們開會討論第三季的預算", nil), ("好", nil), ("對", nil), ("", nil),
            ("優優獨播劇場——YoYo Television Series Exclusive", nil), ("字幕:李宗盛", nil), ("詞：李宗盛", nil),
            ("李宗盛的歌很好聽", nil), ("♪", nil), ("(音樂)", nil), ("謝謝觀看，我們下次再見", 20000),
            ("中文字幕 請不吝點贊", 30000), ("以上言論不代表本台立場", nil), ("這是一條語音備忘錄", nil), ("點贊", nil),
            ("大家記得點贊", nil), ("感謝收看 下集更精彩", 12000), ("MING PAO CANADA MING PAO TORONTO", nil),
            ("這一段講得很慢但是真的內容", 30000), ("影片即將結束，謝謝大家", nil),
        ]
        try emit("hallucination", inputs.map { t, ms in
            ["text": t, "durationMs": Self.any(ms), "expected": Hallucination.isJunk(t, signals: .init(noSpeechProb: nil, durationMs: ms))]
        })
    }

    // MARK: - 3 逐字稿併塊（餵模型前）

    func testMergedForLLM() throws {
        let long = String(repeating: "預算", count: 50)   // 100 字
        let inputs = [
            "- [00:01][我方] 你好\n- [00:03][我方] 今天討論預算\n- [00:05][遠端] 好的\n- [00:09][遠端] 我這邊準備好了",
            "- [00:01][我方] 先講到這\n（⏸ 14:32–14:44 暫停了 12 分鐘，這段沒有錄）\n- [00:20][我方] 繼續講",
            "- [00:01][現場] \(long)\n- [00:10][現場] \(long)\n- [00:20][現場] \(long)\n- [00:30][現場] 最後一句",
            "（⏸ 10:00 暫停了 40 秒，這段沒有錄）",
            "不是逐字稿的一行\n- [00:02][我方] 有效的一行\n- [壞掉的格式\n- [00:05][遠端]    ",
            "",
            "- [1:02:03][遠端] 超過一小時的時間戳\n- [1:02:05][遠端] 同一個人接著講",
        ]
        try emit("merged_for_llm", inputs.map { ["input": $0, "expected": Transcriber.mergedForLLM($0)] })
    }

    // MARK: - 4 whisper JSON 解析

    func testWhisperJSON() throws {
        func seg(_ from: Int, _ to: Int, _ text: String, _ extra: String = "") -> String {
            "{\"offsets\":{\"from\":\(from),\"to\":\(to)},\"text\":\"\(text)\"\(extra)}"
        }
        var loopSegs: [String] = []
        for i in 0..<7 { loopSegs.append(seg(i * 3000, i * 3000 + 3000, " 好的好的")) }
        let inputs: [(String, Int, String)] = [
            ("{\"transcription\":[" + [seg(0, 1200, " 今天要討論產品更新,對"), seg(1200, 2000, "謝謝觀看"), seg(2000, 3000, "今天要討論產品更新，對"), seg(3000, 4000, "預算是三十萬.")].joined(separator: ",") + "]}", 60_000, "我方"),
            ("{\"transcription\":[" + loopSegs.joined(separator: ",") + "," + seg(21000, 23000, "換個話題") + "]}", 0, "遠端"),
            ("{\"transcription\":[{\"text\":\" 沒有時間戳\"}," + seg(5000, 6000, " 有時間戳") + ",{\"text\":\"又沒有\"}]}", 1000, "現場"),
            ("{\"transcription\":[" + seg(0, 30000, "中文字幕志願者 李宗盛", ",\"no_speech_prob\":0.0000001") + "," + seg(30000, 31000, "  ") + "," + seg(31000, 33000, "我們開始吧!") + "]}", 0, "我方"),
            ("{\"transcription\":[]}", 0, "我方"),
            ("{\"transcription\":[" + [seg(0, 1000, "嗯"), seg(1000, 2000, "嗯"), seg(2000, 3000, "對"), seg(3000, 4000, "對")].joined(separator: ",") + "]}", 5000, "遠端"),
        ]
        var cases: [[String: Any]] = []
        for (i, (json, off, who)) in inputs.enumerated() {
            let u = box.appendingPathComponent("w\(i).json")
            try json.write(to: u, atomically: true, encoding: .utf8)
            let r = try Transcriber.parseWhisperJSON(u, offsetMs: off, who: who)
            cases.append([
                "json": json, "offsetMs": off, "who": who,
                "segs": r.segs.map { ["fromMs": $0.fromMs, "toMs": $0.toMs, "text": $0.text, "who": $0.who] },
                "loops": r.loops.map { [$0.0, $0.1] }, "rawRepeat": r.rawRepeat,
            ])
        }
        try emit("whisper_json", cases)
    }

    // MARK: - 5 整片品質（退化判定）

    func testDegeneracy() throws {
        func segs(_ texts: [String]) -> [Segment] { texts.enumerated().map { Segment(fromMs: $0.offset * 1000, toMs: $0.offset * 1000 + 900, text: $0.element, who: "我方") } }
        let normal = (0..<10).map { "第\($0)句：我們今天討論的是預算與時程，這部分需要再確認，請大家會後回覆。" }
        let noPunct = (0..<10).map { "第\($0)句我們今天討論的是預算與時程這部分需要再確認請大家會後回覆好不好" }
        let latch = (0..<10).map { "主持人：第\($0)句我們今天討論的是預算與時程，這部分需要再確認，請回覆。" }
        let inputs: [([String], Double)] = [
            (Array(normal.prefix(5)), 0), (["短", "短", "短", "短", "短", "短", "短", "短", "短"], 0), (normal, 0), (noPunct, 0), (latch, 0), (normal, 0.3), (normal, 0.2),
        ]
        try emit("degeneracy", inputs.map { texts, rr in
            let r = Transcriber.degeneracy(segs(texts), rawRepeatRatio: rr)
            return ["texts": texts, "rawRepeatRatio": rr, "bad": r.bad, "score": r.score]
        })
    }

    // MARK: - 6 切片：暫停切點、靜音切點

    func testSlices() throws {
        let splitInputs: [([[Int]], [Int], Int)] = [
            ([[0, 600_000]], [], 2000), ([[0, 600_000]], [120_000], 2000), ([[0, 600_000]], [1000, 599_500], 2000),
            ([[0, 300_000], [300_000, 700_000]], [100_000, 450_000, 650_000], 2000), ([[0, 600_000]], [400_000, 200_000], 2000),
            ([[0, 10_000]], [5000], 6000),
        ]
        var cases: [[String: Any]] = splitInputs.map { slices, cuts, minMs in
            let out = Transcriber.split(slices.map { ($0[0], $0[1]) }, at: cuts, minMs: minMs)
            return ["kind": "split", "slices": slices, "cuts": cuts, "minMs": minMs, "expected": out.map { [$0.0, $0.1] }]
        }
        // 靜音切點：200 秒、目標 60 秒；70–72 秒、140–142 秒是靜音
        let specs: [[[Int]]] = [
            [[70, 6000], [2, 0], [68, 6000], [2, 0], [58, 6000]],
            [[200, 6000]],
            [[50, 6000]],
        ]
        for spec in specs {
            let pcm = Self.synthPCM(spec)
            let u = box.appendingPathComponent("s-\(UUID().uuidString).wav")
            try Self.writeWav(pcm, to: u)
            let total = WavIO.durationMs(of: u) ?? 0
            let out = Transcriber.silenceSlices(wav: u, totalMs: total, targetMs: 60_000)
            cases.append(["kind": "silence", "spec": spec, "totalMs": total, "targetMs": 60_000, "expected": out.map { [$0.0, $0.1] }])
        }
        try emit("slices", cases)
    }

    // MARK: - 7 小聲片放大

    func testQuietBoost() throws {
        var cases: [[String: Any]] = []
        for amp in [60, 8000, 0, 3, 200] {
            let pcm = Self.bursty(amp)
            let g = Transcriber.quietBoost(levels: WavIO.blockLevels(pcm), pcm: pcm)
            let lv = WavIO.blockLevels(pcm)
            cases.append(["kind": "bursty", "amp": amp, "expected": Self.any(g), "peakLevel": Double(lv.max() ?? 0)])
        }
        // 平穩底噪：整段同一個振幅（沒有人聲的起伏）→ 不放大
        let steady = Self.synthPCM([[10, 50]])
        let g = Transcriber.quietBoost(levels: WavIO.blockLevels(steady), pcm: steady)
        cases.append(["kind": "steady", "amp": 50, "expected": Self.any(g), "peakLevel": Double(WavIO.blockLevels(steady).max() ?? 0)])
        try emit("quiet_boost", cases)
    }

    // MARK: - 8 暫停：時間帳與逐字稿標記

    func testPause() throws {
        var cases: [[String: Any]] = []
        for s in [0, 1, 40, 59.6, 60, 89, 90, 3599, 3600, 3660, 7200, 7260.4, -5, 1e300] as [Double] {
            cases.append(["kind": "durText", "seconds": s, "expected": PauseSpan.durText(s)])
        }
        let t0 = Self.iso("2026-09-20T06:30:00Z")   // 台北 14:30
        let spans: [PauseSpan] = [
            PauseSpan(atSeconds: 120, began: t0.addingTimeInterval(120), ended: t0.addingTimeInterval(840)),
            PauseSpan(atSeconds: 300.4, began: t0.addingTimeInterval(1020.4), ended: t0.addingTimeInterval(1060)),
            PauseSpan(atSeconds: 600, began: t0.addingTimeInterval(1400), ended: nil),
            PauseSpan(atSeconds: 1199.5, began: t0.addingTimeInterval(2000), ended: t0.addingTimeInterval(2100)),
        ]
        func spanObj(_ p: PauseSpan) -> [String: Any] { ["atSeconds": p.atSeconds, "began": Self.isoString(p.began), "ended": Self.any(p.ended.map { Self.isoString($0) })] }
        for p in spans { cases.append(["kind": "markerLine", "span": spanObj(p), "atMs": p.atMs, "expected": p.markerLine]) }
        let lines: [(Int, String)] = [(0, "- [00:00][我方] 開始"), (119_000, "- [01:59][我方] 暫停前"), (125_000, "- [02:05][我方] 暫停後"), (301_000, "- [05:01][遠端] 第二段"), (900_000, "- [15:00][我方] 最後")]
        for total in [1200.0, 1199.9, 400.0] {
            cases.append([
                "kind": "weave", "totalSeconds": total, "pauses": spans.map(spanObj),
                "lines": lines.map { ["fromMs": $0.0, "text": $0.1] },
                "expected": PauseSpan.weave(lines.map { (fromMs: $0.0, text: $0.1) }, pauses: spans, totalSeconds: total),
                "note": Self.any(PauseSpan.note(spans, totalSeconds: total)),
                "mid": PauseSpan.midPauses(spans, totalSeconds: total).map(spanObj),
            ])
        }
        // 時間帳：暫停、繼續、睡眠、醒來、停止（暫停中睡著不另外記）
        var c = RecordingClock(startedAt: t0)
        var log: [[String: Any]] = []
        let events: [(String, Double)] = [("recorded", 30), ("pause", 60), ("recorded", 90), ("resume", 120), ("recorded", 150), ("sleep", 200), ("recorded", 260), ("wake", 300), ("pause", 400), ("sleep", 410), ("wake", 500), ("resume", 520), ("recorded", 600), ("close", 700), ("recorded", 800)]
        for (e, t) in events {
            let now = t0.addingTimeInterval(t)
            var ret: Any = NSNull()
            switch e {
            case "pause": ret = c.pause(at: now)
            case "resume": ret = c.resume(at: now)
            case "sleep": ret = c.noteSleep(at: now)
            case "wake": ret = c.noteWake(at: now)
            case "close": c.close(at: now)
            default: break
            }
            log.append(["event": e, "t": t, "ret": ret, "recorded": c.recorded(at: now), "isPaused": c.isPaused, "currentPause": c.currentPause(at: now), "slept": c.sleptWhileRecording])
        }
        cases.append(["kind": "clock", "startedAt": Self.isoString(t0), "steps": log, "pauses": c.pauses.map(spanObj), "sleepSeconds": c.sleepSeconds, "pausedSeconds": c.pausedSeconds])
        try emit("pause", cases)
    }

    // MARK: - 9 整理守門（逐條）

    static let sampleNotes = """
        ## AI 會議摘要
        這場會議討論 Hearby Windows 版的上線時程與預算，決定先做骨架版。示例甲（Alpha）也提到了。
        ## 與會者
        - 王小明（Ming） — 自我介紹
        - 李大華 — 被點名
        - 陳美玲（行銷部） — 發言
        - 現場A — 推測
        - 王小明 — 重複的一行
        ## 重點
        **時程**
        - 骨架版先做半天 [00:12]
        - 預算 30 萬 [01:05]
        - 這條時間戳是假的 [09:59]
        ## 決議
        - - 無明確決議
        ## 開放問題
        - 要不要買憑證 [02:10]
        ## 待辦
        - [ ] 準備測試機｜Ming｜明天
        - [ ] 寫官網文案｜李大化｜下週三
        - [ ] 範例事項｜｜
        - [ ] 買咖啡｜余童修｜01:55
        - [ ] 整理需求｜｜
        - [ ] 跟客戶確認｜現場B｜月底
        - [ ] 只有一欄的待辦
        """
    static let sampleTranscript = "- [00:12][我方] 骨架版先做半天\n- [01:05][遠端] 預算三十萬\n- [02:10][我方] 要不要買憑證，明天，下週三"
    static let sampleAttendees = "王小明（Ming）、李大華、陳美玲（行銷部）"

    func testPolishGuards() throws {
        var cases: [[String: Any]] = []
        let raws = [
            "好的，以下是整理：\n\n```markdown\n## AI 會議摘要\n內容\n## 待辦\n- 無\n```\n",
            "\u{1B}[1m## AI 會議摘要\u{1B}[0m\n摘要\n## 重點\n- 一 [00:01]\n\n---\n\n## 逐字稿\n- [00:01][我方] 偽造的逐字稿",
            "我無法完成這個要求。",
            "",
            "## 摘要\n只有一節",
            "前言\n## 一句話\n這篇在講 X\n## 內容\n**小標**\n內容 [00:03]",
        ]
        for r in raws { cases.append(["fn": "sanitizeModelOutput", "input": r, "expected": Self.any(PolishGuards.sanitizeModelOutput(r))]) }
        let (v, n) = PolishGuards.verifyCitations(notesMD: Self.sampleNotes, transcript: Self.sampleTranscript)
        cases.append(["fn": "verifyCitations", "input": Self.sampleNotes, "transcript": Self.sampleTranscript, "expected": v, "removed": n])
        let (v2, n2) = PolishGuards.verifyCitations(notesMD: Self.sampleNotes, transcript: "沒有時間戳的舊逐字稿")
        cases.append(["fn": "verifyCitations", "input": Self.sampleNotes, "transcript": "沒有時間戳的舊逐字稿", "expected": v2, "removed": n2])
        let corrs = [
            "「Kevien」應為「Kevin」", "「他」應為「她」", "「預算三十萬」改成「預算三十五萬」；負責人是小華", "「不存在的字」應為「別的」\n期限改到月底",
            "「Kevien」是「Kevin」的錯譯", "",
        ]
        for corr in corrs {
            let (t, sem) = PolishGuards.applyMechanicalCorrections(transcript: Self.sampleTranscript + "\n- [03:00][遠端] Kevien 說他會處理", corrections: corr)
            cases.append(["fn": "applyMechanicalCorrections", "transcript": Self.sampleTranscript + "\n- [03:00][遠端] Kevien 說他會處理", "corrections": corr, "expected": t, "semantic": sem])
        }
        for list in [Self.sampleAttendees, "", "甲（某公司）、乙（某公司）、丙"] {
            cases.append(["fn": "filterAttendees", "input": Self.sampleNotes, "attendees": list, "expected": PolishGuards.filterAttendees(notesMD: Self.sampleNotes, attendeeList: list)])
            cases.append(["fn": "sanitizeTodoOwners", "input": Self.sampleNotes, "attendees": list, "expected": PolishGuards.sanitizeTodoOwners(notesMD: Self.sampleNotes, attendeeList: list)])
        }
        for fn in ["stripExampleTodos", "normalizeEmptyMarkers", "tidyTodoRendering", "stripExampleNames", "clearPlaceholderOwners"] {
            let out: String
            switch fn {
            case "stripExampleTodos": out = PolishGuards.stripExampleTodos(notesMD: Self.sampleNotes)
            case "normalizeEmptyMarkers": out = PolishGuards.normalizeEmptyMarkers(notesMD: Self.sampleNotes)
            case "tidyTodoRendering": out = PolishGuards.tidyTodoRendering(notesMD: Self.sampleNotes)
            case "stripExampleNames": out = PolishGuards.stripExampleNames(notesMD: Self.sampleNotes)
            default: out = PolishGuards.clearPlaceholderOwners(notesMD: Self.sampleNotes)
            }
            cases.append(["fn": fn, "input": Self.sampleNotes, "expected": out])
        }
        let onlyExample = "## 待辦\n- [ ] 範例事項｜｜\n## 其他\n- 內容"
        cases.append(["fn": "stripExampleTodos", "input": onlyExample, "expected": PolishGuards.stripExampleTodos(notesMD: onlyExample)])
        let scenarios: [(MeetingScenario?, Int?)] = [(nil, nil), (.onsite, 3), (.onsite, 7), (.onsite, nil), (.phoneSpeaker, 2), (.phoneSpeaker, nil), (.onlineHeadphones, nil)]
        for (sc, cnt) in scenarios {
            cases.append(["fn": "insertOnsiteNote", "input": Self.sampleNotes, "scenario": Self.any(sc?.rawValue), "onsiteCount": Self.any(cnt),
                          "expected": PolishGuards.insertOnsiteNote(notesMD: Self.sampleNotes, scenario: sc, onsiteCount: cnt)])
        }
        let src = Self.sampleTranscript + "\n修正：月底"
        cases.append(["fn": "sanitizeTodoDues", "input": Self.sampleNotes, "source": src, "expected": PolishGuards.sanitizeTodoDues(notesMD: Self.sampleNotes, sourceText: src)])
        let briefNotes = Self.sampleNotes + "\n## 會前重點對照\n- 確認上線時程 → 先做骨架版\n- 預算｜三十萬"
        let brief = ["確認上線時程", "預算", "有沒有人要買憑證"]
        cases.append(["fn": "normalizeBriefLedger", "input": briefNotes, "brief": brief, "expected": Polish.normalizeBriefLedger(notesMD: briefNotes, brief: brief)])
        cases.append(["fn": "normalizeBriefLedger", "input": Self.sampleNotes, "brief": brief, "expected": Polish.normalizeBriefLedger(notesMD: Self.sampleNotes, brief: brief)])
        try emit("polish_guards", cases)
    }

    // MARK: - 10 組稿＋提示詞原文（假的整理方式：收下 system／user、回固定內容）

    final class FakeProvider: Provider {
        let id: String
        let reply: String?
        let err: String?
        var seenSystem: String?
        var seenUser: String?
        init(id: String = "fake", reply: String?, err: String? = nil) { self.id = id; self.reply = reply; self.err = err }
        var displayName: String { "假的整理" }
        var contextBudget: Int { 100_000 }
        var maxOutputTokens: Int { 8000 }
        var trustLevel: TrustLevel { .local }
        func check() -> ProviderStatus { ProviderStatus(.ready, "ok") }
        func complete(system: String, user: String) -> (String?, String?) {
            seenSystem = system; seenUser = user
            return (reply, reply == nil ? (err ?? "假的錯誤") : nil)
        }
    }

    static let goodMeeting = """
        ## AI 會議摘要
        這場會議討論 Hearby 的 Windows 版。決定先做骨架版。預算三十萬。
        ## 與會者
        - 王小明 — 自我介紹
        - 現場A — 推測
        ## 重點
        **時程**
        - 骨架版先做半天 [00:12]
        - 預算三十萬 [01:05]
        ## 決議
        - 先做骨架版 [00:12]
        ## 開放問題
        - 要不要買憑證 [02:10]
        ## 待辦
        - [ ] 準備測試機｜王小明｜明天
        - [ ] 寫文案｜現場A｜
        ## 會前重點對照
        - 確認時程 → 先做骨架版
        """
    // 名冊樣本（名字都是假的）
    static let sampleRoster = """
        # 名冊（示範用，名字都是假的）
        <!-- 產生：測試；- 註解裡的行不算｜不算｜ -->
        一行一個：正名｜別名｜聽錯｜是誰｜讀音
        ## 人
        - 林小安｜小安｜林曉安、琳小安｜產品經理｜
        - 陳美玲｜美玲｜梅玲（看上下文）｜行銷部｜
        ## 案子
        - 星河計畫｜星河｜星核計畫｜年度企劃｜
        - 藏寶圖 App｜藏寶圖｜葬寶圖｜手機遊戲｜藏＝ㄘㄤˊ
        ## 容易搞混
        - 「梅玲」可能是 陳美玲：看上下文才換
        """
    static let sampleThreads = """
        # 議題
        ## 官網改版
        - 起點：2026-09-01 週會
        - 2026-09-03 定案：首頁改成三段
        - 2026-09-05 還沒定：要不要加影片
        - 2026-09-06 決定：十月上線
        <!-- - 2026-09-07 定案：註解裡的不算 -->
        ## 招募
        - 2026-09-10 同意先找一位 PM
        - 2026-09-11 不確定要不要再找一位
        """
    static let sampleOpen = """
        # 還沒完成的事
        <!-- 2026-09-01_1000_週會 -->
        - [ ] 準備測試機｜林小安｜明天｜2026-09-01_1000_週會
        - [x] 寫文案｜｜｜2026-09-01_1000_週會
        - [ ] 只有一欄的待辦
        <!-- 2026-09-20_1430_週會 -->
        - [ ] 這一場自己的｜｜｜2026-09-20_1430_週會
        """
    static let rosterTranscript = "- [00:12][我方] 星核計畫骨架版先做半天\n- [01:05][遠端] 林曉安說預算三十萬，林曉安會寄\n- [02:10][我方] 要不要買憑證，梅玲說明天"
    static let rosterMeeting = """
        ## AI 會議摘要
        這場會議討論星河計畫的時程，林小安說明預算三十萬，梅玲提到憑證。
        ## 與會者
        - 林小安 — 自己報預算
        ## 重點
        - 星河計畫骨架版先做半天 [00:12]
        - 預算三十萬 [01:05]
        ## 決議
        - 先做骨架版 [00:12]
        ## 開放問題
        - 要不要買憑證 [02:10]
        ## 待辦
        - [ ] 準備測試機｜林小安｜明天
        - [ ] 寄預算｜林小安｜
        ## 名字更正
        - 林曉安 → 林小安｜高｜[01:05]
        - 星核計畫 → 星河計畫｜高｜[00:12] [09:59]
        - 梅玲 → 陳美玲｜低｜[02:10]
        - 預算 → 預算表｜高｜[01:05]
        """
    static func contextJSON(_ c: PolishContext) -> [String: Any] {
        var o: [String: Any] = ["roster": c.roster, "decided": c.decided, "openTodos": c.openTodos, "names": c.names]
        if !c.projects.isEmpty { o["projects"] = c.projects }
        if !c.undecided.isEmpty { o["undecided"] = c.undecided }
        return o
    }
    static let sampleState = """
        # 現況（示範用，名字都是假的）
        <!-- 自動產生 -->
        ## 案子
        - 星河計畫｜林小安｜製作中｜10/2 交視覺提案｜2026-10-02
        - 藏寶圖 App｜陳美玲｜開案｜等對方簽約｜
        ## 還沒完成的待辦
        - 準備測試機｜林小安｜2026-10-01｜星河計畫
        - 整理預算表｜陳美玲｜｜
        ## 最近定案
        - 2026-09-25｜官網改成三段
        ## 還沒定的事
        - 2026-09-20｜要不要加影片
        - 2026-09-21｜要不要再找一位 PM
        """
    static func fixJSON(_ f: NameFixes.Fix) -> [String: Any] { ["heard": f.heard, "name": f.name, "sure": f.sure, "stamps": f.stamps] }

    func testNameFixes() throws {
        var cases: [[String: Any]] = []
        let longRoster = "## 人\n" + (1...30).map { "- 測試人\($0)｜｜｜第 \($0) 位｜" }.joined(separator: "\n") + "\n## 案子\n- 很後面的案子｜｜｜｜"
        let rosters: [(String, String?, String?, String?, Int)] = [
            (Self.sampleRoster, Self.sampleThreads, Self.sampleOpen, "2026-09-20_1430_週會", PolishContext.rosterLimit),
            (Self.sampleRoster, nil, nil, nil, PolishContext.rosterLimit),
            ("# 名冊\n\n只有說明\n<!-- - 註解｜裡 -->", nil, nil, nil, PolishContext.rosterLimit),
            (longRoster, nil, Self.sampleOpen, nil, 120),
            (longRoster, nil, nil, nil, 40),
        ]
        for (r, t, o, ex, lim) in rosters {
            let c = PolishContext.make(roster: r, threads: t, open: o, excluding: ex, limit: lim)
            cases.append(["fn": "make", "roster": r, "threads": Self.any(t), "open": Self.any(o), "excluding": Self.any(ex), "limit": lim,
                          "expected": c.map { Self.contextJSON($0) as Any } ?? NSNull()])
        }
        for line in ["- 林曉安 → 林小安｜高｜[01:05] [1:02:03] [01:05]", "- 「梅玲」->「陳美玲」| 低 | [02:10]", "- 星核 => 星河｜high｜[00:12]",
                     "-  葬寶圖→藏寶圖 ｜ 中 ｜", "- 無", "- 沒有箭頭｜高｜[00:01]", "- 一樣 → 一樣｜高｜[00:01]", "不是清單 → 行｜高", "- → 空的｜高"] {
            cases.append(["fn": "parse", "line": line, "expected": NameFixes.parse(line).map { Self.fixJSON($0) as Any } ?? NSNull()])
        }
        let notesList = [Self.rosterMeeting, "## AI 會議摘要\n摘要\n\n## 名字更正\n- 林曉安 → 林小安｜高｜[01:05]\n\n## 待辦\n- 無\n", "## 摘要\n內容", "## 名字更正\n- 無"]
        for n in notesList {
            let (o, f) = NameFixes.extract(n)
            cases.append(["fn": "extract", "notes": n, "expected": o, "fixes": f.map(Self.fixJSON)])
        }
        let fixes = NameFixes.extract(Self.rosterMeeting).fixes + [NameFixes.Fix(heard: "凌", name: "林小安", sure: true, stamps: ["02:10"]),
                                                                   NameFixes.Fix(heard: "要不要", name: "小安要不要", sure: true, stamps: ["02:10"])]
        let names = PolishContext.make(roster: Self.sampleRoster, threads: nil, open: nil, excluding: nil)!.names
        for tr in [Self.rosterTranscript, "- [00:12][星核計畫] 星核計畫\n（⏸ 14:32–14:44 暫停了 12 分鐘，這段沒有錄）\n- [01:05][遠端]林曉安沒有空格", ""] {
            let r = NameFixes.apply(fixes, transcript: tr, names: names)
            cases.append(["fn": "apply", "fixes": fixes.map(Self.fixJSON), "transcript": tr, "names": names, "expected": r.transcript,
                          "applied": r.applied.map { ["fix": Self.fixJSON($0.fix), "count": $0.count] }, "skipped": r.skipped.map(Self.fixJSON)])
        }
        let shortFixes = [NameFixes.Fix(heard: "新和", name: "星河", sure: true, stamps: ["00:05"]), NameFixes.Fix(heard: "明天", name: "星河", sure: true, stamps: ["00:05"]),
                          NameFixes.Fix(heard: "新和", name: "新和計畫", sure: true, stamps: ["00:05"]), NameFixes.Fix(heard: "美林", name: "美玲", sure: true, stamps: ["00:05"])]
        for nm in [["星河計畫"], ["星河計畫", "陳美玲"], ["星河"]] {
            let tr = "- [00:05][我方] 新和明天開工，美林說好"
            let r = NameFixes.apply(shortFixes, transcript: tr, names: nm)
            cases.append(["fn": "apply", "fixes": shortFixes.map(Self.fixJSON), "transcript": tr, "names": nm, "expected": r.transcript,
                          "applied": r.applied.map { ["fix": Self.fixJSON($0.fix), "count": $0.count] }, "skipped": r.skipped.map(Self.fixJSON)])
        }
        let unsure = [NameFixes.Fix(heard: "梅玲", name: "陳美玲", sure: false, stamps: ["02:10"]), NameFixes.Fix(heard: "玲", name: "凌", sure: false, stamps: []),
                      NameFixes.Fix(heard: "星核", name: "星河計畫", sure: false, stamps: [])]
        let markNotes = "## AI 會議摘要\n梅玲說明天要交。\n## 與會者\n- 陳美玲 — 推測\n## 重點\n- 星河計畫 [[?]]先做 [00:12]\n- 陳美玲提到預算 [01:05]\n## 待辦\n- [ ] 交報告｜陳美玲｜明天"
        for n in [markNotes, NameFixes.markUnsure(markNotes, unsure), "## 開放問題\n- 陳美玲要不要來\n## 決議\n- 陳美玲負責"] {
            cases.append(["fn": "markUnsure", "notes": n, "fixes": unsure.map(Self.fixJSON), "expected": NameFixes.markUnsure(n, unsure)])
        }
        // 正名在逐字稿講過（不分大小寫）：只找原字
        let spokenFixes = [NameFixes.Fix(heard: "英特網", name: "STARLINE", sure: false, stamps: []), NameFixes.Fix(heard: "梅玲", name: "陳美玲", sure: false, stamps: [])]
        let spokenNotes = "## AI 會議摘要\nSTARLINE 的兩條路，英特網那段再確認。梅玲說明天要交。\n## 重點\n- 陳美玲提到預算"
        for tr in ["- [00:10][現場] 我們 Starline 要轉型\n- [00:20][現場] 英特網的部分", "- [00:10][現場] 陳美玲說明天交", ""] {
            cases.append(["fn": "markUnsure", "notes": spokenNotes, "fixes": spokenFixes.map(Self.fixJSON), "transcript": tr,
                          "expected": NameFixes.markUnsure(spokenNotes, spokenFixes, transcript: tr)])
        }
        let applied: [(fix: NameFixes.Fix, count: Int)] = (1...8).map { (NameFixes.Fix(heard: "錯\($0)", name: "對\($0)", sure: true, stamps: []), $0) }
        let manyUnsure = (1...8).map { NameFixes.Fix(heard: "疑\($0)", name: "名\($0)", sure: false, stamps: []) }
        for (a, u) in [(Array(applied.prefix(2)), Array(unsure.prefix(1))), (applied, []), ([], unsure), ([], []), (applied, manyUnsure)] as [([(fix: NameFixes.Fix, count: Int)], [NameFixes.Fix])] {
            cases.append(["fn": "headerLine", "applied": a.map { ["fix": Self.fixJSON($0.fix), "count": $0.count] }, "unsure": u.map(Self.fixJSON),
                          "expected": Self.any(NameFixes.headerLine(applied: a, unsure: u))])
        }
        let todoNotes = "## 待辦\n- [ ] 準備測試機｜林小安｜明天\n- [ ] 準備測試機｜林小安｜下週三\n- [ ] 整理預算表｜｜\n- [ ] 新的事｜｜\n## 其他\n- [ ] 準備測試機｜林小安｜明天"
        for open in [["準備測試機｜林小安｜明天｜2026-09-01", "整理預算表｜陳美玲｜月底｜2026-09-20"], [], ["只有事項"]] {
            cases.append(["fn": "dropRepeatedTodos", "notes": todoNotes, "open": open, "expected": NameFixes.dropRepeatedTodos(todoNotes, open: open)])
        }
        cases.append(["fn": "memoryBlock", "context": Self.contextJSON(PolishContext.make(roster: Self.sampleRoster, threads: Self.sampleThreads, open: Self.sampleOpen, excluding: nil)!),
                      "expected": Prompt.memoryBlock(PolishContext.make(roster: Self.sampleRoster, threads: Self.sampleThreads, open: Self.sampleOpen, excluding: nil)!)])
        cases.append(["fn": "memoryBlock", "context": Self.contextJSON(PolishContext(roster: "- 只有名冊｜｜｜｜")), "expected": Prompt.memoryBlock(PolishContext(roster: "- 只有名冊｜｜｜｜"))])
        try emit("name_fixes", cases)
    }

    // MARK: - 名字確認帳（NAMES.md）：讀、寫、撞名檢查、從改動學名字（假名字）

    static let sampleNames = """
        # 名字確認帳
        <!-- - 註解裡 → 不算｜一律 -->
        ## 名字
        - 林曉安 → 林小安｜一律｜你在 Hearby 改的｜2026-09-20｜2026-09-20_1400_週會
        - 梅玲 → 陳美玲｜看上下文｜重新整理時的更正｜2026-09-21｜2026-09-21_1000_週會
        - 小星 → 星河計畫｜不換｜你在 Hearby 改的｜2026-09-21｜2026-09-21_1000_週會
        - 「星核」→「星河計畫」
        - 沒有箭頭的一行
        ## 要確認
        - 凌那邊 → 林那邊？｜2026-09-22_0900_週會｜是
        - 阿明 → 王小明?｜2026-09-22_0900_週會｜不是
        - 小花 → 陳美玲？｜2026-09-22_0900_週會｜
        - 同一個 → 同一個？｜x｜
        """
    static let editBefore = """
        # 會議紀錄 2026-09-20 14:00

        ## AI 會議摘要
        林曉安說明星核計畫的預算三十萬，動畫部門下週交。
        ## 重點
        - 林曉安、梅玲負責提案 [00:12]
        - 由林曉安跟阿明對接 [01:05]

        ---

        ## 逐字稿
        - [00:12][我方] 林曉安跟梅玲說星核計畫要趕
        - [01:05][遠端] Cloud Code 可以幫忙，動畫部門下週交
        - [02:10][我方] 預算三十萬，問林曉安
        """
    // 讀音比對（SoundAlike）：拼音表、注音、正規化、名冊→目標、逐字稿→候選、帶給 AI 的行、簡稱守門
    static let soundsTranscript = """
        - [00:05][我方] 新河計畫要趕，美林說好
        - [00:40][遠端] 臟寶圖上線，曉安會寄
        - [01:10][我方] 林曉安說有人要來，星核計畫先停
        （⏸ 14:32–14:44 暫停了 12 分鐘，這段沒有錄）
        - [01:30][我方] 新河計畫第二版，新和也要
        不是逐字稿的行 新河計畫
        """

    func testSoundAlike() throws {
        var cases: [[String: Any]] = []
        let table = PinyinData.table
        cases.append(["fn": "table", "sha256": SHA256.hash(data: Data(table.utf8)).map { String(format: "%02x", $0) }.joined(),
                      "chars": Pinyin.table.count])
        cases.append(["fn": "of", "chars": ["林", "曉", "安", "小", "藏", "柏", "的", "a", "1", "😀", "㐀", "鿿"],
                      "expected": ["林", "曉", "安", "小", "藏", "柏", "的", "a", "1", "😀", "㐀", "鿿"].map { Self.any(Pinyin.of(Character($0))) }])
        let zs = ["ㄗㄤˋ", "ㄅㄛˊ", "ㄓ", "ㄧ", "ㄨㄥ", "ㄩㄥˇ", "ㄋㄩˇ", "ㄌㄩㄝˋ", "ㄐㄩㄢ", "ㄒㄧㄥ", "ㄦˊ", "ㄇ", "ㄅㄧㄝ", "ㄏㄨㄟ", "ㄧㄡ", "ㄨㄣ", "abc", "", "ㄗㄤㄤ", "ㄧㄦ"]
        cases.append(["fn": "fromZhuyin", "input": zs, "expected": zs.map { Self.any(Pinyin.fromZhuyin($0)) }])
        let sy = ["zhang", "chi", "shi", "ling", "lan", "ping", "xiong", "qu", "ke", "ng", "long", "tian", "nu", "eng", "cang"]
        cases.append(["fn": "key", "input": sy, "expected": sy.map(Pinyin.key)])
        cases.append(["fn": "coarse", "input": sy, "expected": sy.map(Pinyin.coarse)])
        let names = "## 確認過的名字\n- 林小安｜｜林曉安、琳小安｜確認過｜\n## 確認過不是聽錯\n- 「星核」不是星河：不要換\n"
        let rosters = [Self.sampleRoster, names + Self.sampleRoster, "- 王大明 Leo｜大明、Leo、阿明（綽號）｜大名（看上下文）｜說明：第二欄有冒號就不算別名｜",
                       "- 甲｜｜｜只有一個字｜\n- 一二三四五六七｜｜｜七個字｜\n- 𠀋𠀋｜｜｜表外的字｜", "只有說明"]
        for r in rosters {
            let t = SoundAlike.targets(roster: r)
            cases.append(["fn": "targets", "roster": r, "targets": t.targets.map { ["name": $0.name, "syllables": $0.syllables, "rank": $0.rank] }, "heard": t.heard])
        }
        func hitJSON(_ h: SoundAlike.Hit) -> [String: Any] { ["heard": h.heard, "names": h.names, "count": h.count, "stamps": h.stamps, "rank": h.rank] }
        for (tr, r) in [(Self.soundsTranscript, Self.sampleRoster), (Self.soundsTranscript, names + Self.sampleRoster), (Self.rosterTranscript, Self.sampleRoster),
                        (Self.soundsTranscript, ""), ("", Self.sampleRoster)] {
            let t = SoundAlike.targets(roster: r)
            let hits = SoundAlike.scan(tr, targets: t.targets, heard: t.heard)
            cases.append(["fn": "scan", "transcript": tr, "roster": r, "expected": hits.map(hitJSON), "lines": SoundAlike.lines(hits)])
        }
        let many = (1...70).map { SoundAlike.Hit(heard: "字\($0)", names: ["名\($0)", "別\($0)"], count: $0 % 3 + 1, stamps: ["00:0\($0 % 10)", "01:00", "02:00", "03:00"], rank: $0) }
        cases.append(["fn": "lines", "hits": many.map(hitJSON), "expected": SoundAlike.lines(many)])
        let pairs = [("新和", "星河"), ("新聞", "星河"), ("明天", "星河"), ("星河", "星河計畫"), ("雅特", "亞特"), ("A1", "星河"), ("三", "山"), ("葬寶圖", "藏寶圖"), ("早飯圖", "藏寶圖")]
        cases.append(["fn": "close", "pairs": pairs.map { [$0.0, $0.1] }, "expected": pairs.map { SoundAlike.close($0.0, $0.1) }])
        try emit("sound_alike", cases)
    }

    static func namesJSON(_ r: (entries: [NameLedger.Entry], questions: [NameLedger.Question])) -> [String: Any] {
        ["entries": r.entries.map { ["heard": $0.heard, "name": $0.name, "how": $0.how, "who": $0.who, "date": $0.date, "meeting": $0.meeting] },
         "questions": r.questions.map { ["heard": $0.heard, "name": $0.name, "meeting": $0.meeting, "answer": $0.answer, "yes": $0.yes, "no": $0.no] }]
    }

    func testNameLedger() throws {
        var cases: [[String: Any]] = []
        for t in [Self.sampleNames, NameLedger.header, "", "- a → b"] { cases.append(["fn": "parse", "text": t, "expected": Self.namesJSON(NameLedger.parse(t))]) }
        let e1 = NameLedger.Entry(heard: "林曉安", name: "林小安", how: "一律", who: "你", date: "2026-09-20", meeting: "m1")
        let e2 = NameLedger.Entry(heard: "星核", name: "星河計畫", how: "看上下文", meeting: "m2")
        let q1 = NameLedger.Question(heard: "梅玲", name: "陳美玲", meeting: "m1")
        let q2 = NameLedger.Question(heard: "林曉安", name: "林小安", meeting: "m2")
        let addCases: [([NameLedger.Entry], [NameLedger.Question], String?)] = [
            ([e1], [q1], nil), ([e1, e2], [q1, q2], Self.sampleNames), ([], [q1], "# 自己寫的\n\n- 自己加的 → 一行"), ([e2], [], "## 名字\n- 舊 → 新\n\n\n## 要確認\n"), ([], [], nil),
        ]
        for (e, q, t) in addCases {
            cases.append(["fn": "adding", "entries": Self.namesJSON((e, []))["entries"]!, "questions": Self.namesJSON(([], q))["questions"]!,
                          "text": Self.any(t), "expected": NameLedger.adding(entries: e, questions: q, to: t)])
        }
        for (h, n, a) in [("小花", "陳美玲", "是"), ("凌那邊", "林那邊", "不是"), ("不存在", "的題", "是")] {
            cases.append(["fn": "answering", "heard": h, "name": n, "answer": a, "text": Self.sampleNames, "expected": NameLedger.answering(heard: h, name: n, answer: a, in: Self.sampleNames)])
        }
        for t in [Self.sampleNames, NameLedger.answering(heard: "小花", name: "陳美玲", answer: "是", in: Self.sampleNames), ""] {
            let r = NameLedger.parse(t)
            cases.append(["fn": "contextLines", "text": t, "expected": NameLedger.contextLines(r.entries, r.questions),
                          "aliasPairs": NameLedger.aliasPairs(r.entries).map { [$0.alias, $0.canonical] }])
        }
        let others: [(id: String, transcript: String)] = [("m2", "- [00:01][我方] 梅玲說好"), ("m1", "- [00:01][我方] 林曉安在這場")]
        for (h, known) in [("林曉安", ["林小安"]), ("梅玲", []), ("小安", ["林小安"]), ("喊", []), ("星核計畫", ["星河計畫"])] as [(String, [String])] {
            cases.append(["fn": "classify", "heard": h, "meeting": "m1", "others": others.map { ["id": $0.id, "transcript": $0.transcript] }, "known": known,
                          "expected": NameLedger.classify(heard: h, meeting: "m1", others: others, known: known)])
        }
        for (c, known) in [("「林曉安」應為「林小安」；「預算三十萬」改成「預算三十五萬」；「他」應為「她」；「星核」是「星河計畫」", ["林小安"]),
                           ("「Cloud」改為「Claude」\n「好長好長好長好長好長的一句話」應為「另一句好長好長好長好長的話」", ["Claude Code"]), ("", [])] as [(String, [String])] {
            cases.append(["fn": "pairsFromCorrections", "corrections": c, "known": known, "expected": NameLedger.pairs(fromCorrections: c, known: known).map { [$0.heard, $0.name] }])
        }
        let edits: [(String, [String])] = [
            (Self.editBefore.replacingOccurrences(of: "林曉安", with: "林小安").replacingOccurrences(of: "星核計畫", with: "星河計畫")
                .replacingOccurrences(of: "Cloud Code", with: "Claude Code").replacingOccurrences(of: "預算三十萬", with: "預算三十五萬")
                .replacingOccurrences(of: "- [01:05][遠端] Cloud Code 可以幫忙，動畫部門", with: "- [01:05][遠端] Claude Code 可以幫忙，動劃部門"), ["林小安", "星河計畫", "Claude Code"]),
            (Self.editBefore.replacingOccurrences(of: "林曉安", with: "林小安").replacingOccurrences(of: "梅玲", with: "陳美玲"), []),
            (Self.editBefore.replacingOccurrences(of: "林曉安說明", with: "林大華說明"), ["林小安"]),
            (Self.editBefore.replacingOccurrences(of: "林曉安、梅玲", with: "林小安、陳美玲"), ["林小安", "陳美玲"]),
            (Self.editBefore.replacingOccurrences(of: "阿明", with: "王小明"), []),
            (Self.editBefore.replacingOccurrences(of: "## 重點\n", with: "## 重點\n- 新加的一行 [00:12]\n"), ["林小安"]),
            (Self.editBefore, ["林小安"]),
        ]
        for (new, known) in edits {
            cases.append(["fn": "pairsFromEdit", "old": Self.editBefore, "new": new, "known": known, "expected": NameLedger.pairs(old: Self.editBefore, new: new, known: known).map { [$0.heard, $0.name] }])
        }
        let lines: [(String, String, [String])] = [
            ("由林曉安跟梅玲說", "由林小安跟陳美玲說", []), ("由林曉安跟梅玲說", "由林小安跟陳美玲說", ["林小安"]), ("Cloud Code 可以", "Claude Code 可以", ["Claude Code"]),
            ("甲乙的案子", "丙乙丁的案子", []), ("TANVAS是林曉安", "Canvas是林小安", ["Canvas", "林小安"]), ("a", "b", []), ("完全一樣", "完全一樣", []), ("", "新的", []),
            ("王曉明說", "王小明說", ["小明", "王小明"]), ("🎉林曉安", "🎉林小安", []),
        ]
        for (x, y, known) in lines {
            cases.append(["fn": "hunks", "x": x, "y": y, "known": known,
                          "expected": NameLedger.hunks(x, y, known: known).map { ["old": $0.old, "new": $0.new, "alts": $0.alts.map { [$0.0, $0.1] }] }])
        }
        for (x, y) in [("abcabba", "cbabac"), ("曉安", "小安"), ("", "ab"), ("ab", ""), ("same", "same"), ("梅玲", "陳美玲")] {
            cases.append(["fn": "align", "x": x, "y": y, "expected": NameLedger.align(Array(x), Array(y)).map { [Self.any($0.0), Self.any($0.1)] }])
        }
        for md in ["# 會議紀錄\n\n> 名字更正：逐字稿照名冊改了 2 處（林曉安→林小安 ×2）；沒改：梅玲→陳美玲？、凌→林小安？、壞掉的一項（沒把握，或名冊、逐字稿對不上；紀錄裡提到的地方標了 [[?]]）\n",
                   "> 名字更正：逐字稿照名冊改了 1 處（林曉安→林小安）", "沒有表頭",
                   NameFixes.headerLine(applied: [], unsure: (1...8).map { NameFixes.Fix(heard: "疑\($0)", name: "名\($0)", sure: false, stamps: []) })!,
                   "> 名字更正：沒改：疑1→名1？、疑2→名2？…等 9 組（沒把握，或名冊、逐字稿對不上；紀錄裡提到的地方標了 [[?]]）"] {
            cases.append(["fn": "questionsFromRecord", "md": md, "meeting": "m1", "expected": Self.namesJSON(([], NameLedger.questions(fromRecord: md, meeting: "m1")))["questions"]!])
        }
        for (roster, names) in [(Self.sampleRoster, Self.sampleNames), ("", Self.sampleNames), ("", "# 空的帳\n## 名字\n"), (Self.sampleRoster, "")] {
            let c = PolishContext.make(roster: roster, threads: nil, open: nil, excluding: nil, limit: 300, names: names)
            cases.append(["fn": "makeWithNames", "roster": roster, "names": names, "limit": 300, "expected": c.map { Self.contextJSON($0) as Any } ?? NSNull()])
        }
        // 現況（STATE.md）：待辦與定案用它的，另外帶案子現況與還沒定的事；只有 STATE.md 也帶；節是空的就照舊
        for (roster, state) in [(Self.sampleRoster, Self.sampleState), ("", Self.sampleState), (Self.sampleRoster, "## 案子\n\n## 最近定案\n"),
                                (Self.sampleRoster, Self.sampleState.replacingOccurrences(of: "## 最近定案\n- 2026-09-25｜官網改成三段\n", with: ""))] {
            let c = PolishContext.make(roster: roster, threads: Self.sampleThreads, open: Self.sampleOpen, excluding: nil, limit: 300, state: state)
            cases.append(["fn": "makeWithState", "roster": roster, "threads": Self.sampleThreads, "open": Self.sampleOpen, "state": state, "limit": 300,
                          "expected": c.map { Self.contextJSON($0) as Any } ?? NSNull(), "memoryBlock": Self.any(c.map { Prompt.memoryBlock($0) })])
        }
        // 之前的事（FollowUps）：整理結果裡那一節的守門、紀錄寫做完的事情、OPEN.md 打勾
        let fuNotes = ["## 待辦\n- 無\n## 之前的事\n- 準備測試機 → 做完了 [01:05]\n- 整理預算表 → 沒講到\n- 星河計畫 → 改到 10/9 交 [02:10]\n## 名字更正\n- 無",
                       "## 待辦\n- 無\n\n## 之前的事\n- 無\n", "## 摘要\n內容", "## 之前的事\n- 只有沒時間戳的 → 做完"]
        for n in fuNotes { cases.append(["fn": "followPrune", "notes": n, "expected": FollowUps.prune(n)]) }
        let fuMD = "## 之前的事\n- 準備測試機 → 做完了 [01:05]\n- 整理預算表｜陳美玲｜月底 → 還沒做完，改到下週 [02:10]\n- 寫文案 → 不做了 [03:00]\n- 沒有箭頭的一行 [03:10]\n## 待辦\n- [ ] 準備測試機 → 做完了"
        let fuOpen = "# 還沒完成的事\n- [ ] 準備測試機｜林小安｜明天｜m1\n- [ ] 準備測試機｜林小安｜明天｜m3\n- [ ] 寫文案｜｜｜m1\n- [x] 已經勾了｜｜｜m1\n- [ ] 整理預算表｜陳美玲｜月底｜m1\n- [ ] 只有一欄"
        cases.append(["fn": "followDone", "md": fuMD, "expected": FollowUps.doneItems(fuMD)])
        cases.append(["fn": "followTick", "open": fuOpen, "done": FollowUps.doneItems(fuMD), "meeting": "m3", "expected": FollowUps.tick(open: fuOpen, done: FollowUps.doneItems(fuMD), meeting: "m3")])
        try emit("name_ledger", cases)
    }

    static let goodInterview = "## 摘要\n受訪者談 Windows 版。\n## 受訪者\n- 受訪者 — 回答問題\n## 內容\n**問：什麼時候上線？**\n答：先做骨架版。[00:12]\n## 引言\n- 「先做骨架版」[00:12]\n## 待辦\n- 無"
    static let goodNote = "## 一句話\n這篇在講 Windows 版。\n## 內容\n**時程**\n先做骨架版。[00:12]\n## 待辦\n- [ ] 準備測試機｜｜明天"

    func testBuildNotes() throws {
        struct Case { var name: String; var scene: RecordScene = .meeting; var scenario: MeetingScenario? = nil; var onsite = false; var onsiteCount: Int? = nil
            var attendees = ""; var brief: [String] = []; var pauseNote: String? = nil; var warnings: [String] = []; var links: [String] = []
            var corrections: String? = nil; var baseline: String? = nil; var history: [String] = []; var title = "週會"
            var providerID: String? = "fake"; var reply: String? = nil; var err: String? = nil; var glossary: String? = nil; var endpointModel: String? = nil
            var context: PolishContext? = nil; var transcript: String? = nil }
        let rosterCtx = PolishContext.make(roster: Self.sampleRoster, threads: Self.sampleThreads, open: Self.sampleOpen, excluding: "2026-09-20_1430_週會")
        let cases: [Case] = [
            Case(name: "meeting_basic", attendees: "王小明、李大華", warnings: ["麥克風軌無聲，未聽打"], reply: Self.goodMeeting),
            Case(name: "meeting_online_speaker_brief_pause", scenario: .onlineSpeaker, brief: ["確認時程", "預算多少"], pauseNote: "中途暫停 1 次，共 12 分鐘（暫停時沒有錄音，逐字稿裡標了位置）", reply: Self.goodMeeting),
            Case(name: "meeting_onsite_fallback", onsite: true, reply: Self.goodMeeting),
            Case(name: "meeting_onsite_count", scenario: .onsite, onsiteCount: 3, attendees: "王小明", reply: Self.goodMeeting),
            Case(name: "meeting_phone_speaker", scenario: .phoneSpeaker, onsiteCount: 6, reply: Self.goodMeeting),
            Case(name: "meeting_headphones_glossary", scenario: .onlineHeadphones, reply: Self.goodMeeting, glossary: "Hearby、Claude Code、Kevin"),
            Case(name: "interview", scene: .interview, attendees: "受訪者甲", reply: Self.goodInterview),
            Case(name: "note", scene: .note, reply: Self.goodNote),
            Case(name: "transcript_only_nil_provider", providerID: nil),
            Case(name: "transcript_only_none_provider", brief: ["確認時程"], providerID: "none"),
            Case(name: "shape_error", reply: "好的，我會幫你整理。"),
            Case(name: "provider_error", reply: nil, err: "Claude 的額度暫時用完了"),
            Case(name: "endpoint_local_model", providerID: "endpoint", reply: Self.goodMeeting, endpointModel: "qwen3:4b-instruct"),
            Case(name: "repolish_style", attendees: "王小明", links: ["https://example.com/doc"], corrections: "「Kevien」應為「Kevin」", baseline: "## 重點\n- 骨架版 [00:12]", history: ["2026-09-01：名字改正"], reply: Self.goodMeeting),
            Case(name: "empty_reply", reply: "   "),
            // 帶名冊（ROSTER.md 在）：名冊、已定案、待辦進使用者訊息，規則進系統提示；AI 回的名字更正套到逐字稿
            Case(name: "meeting_roster", reply: Self.rosterMeeting, context: rosterCtx, transcript: Self.rosterTranscript),
            Case(name: "meeting_roster_no_fixes", attendees: "林小安", reply: Self.goodMeeting, context: rosterCtx, transcript: Self.rosterTranscript),
            Case(name: "meeting_roster_endpoint", providerID: "endpoint", reply: Self.rosterMeeting, endpointModel: "qwen3:4b-instruct", context: rosterCtx, transcript: Self.rosterTranscript),
            Case(name: "interview_roster", scene: .interview, reply: Self.goodInterview, context: rosterCtx, transcript: Self.rosterTranscript),
            Case(name: "meeting_roster_follow_ups", reply: Self.rosterMeeting.replacingOccurrences(of: "## 名字更正", with: "## 之前的事\n- 準備測試機 → 做完了 [01:05]\n- 整理預算表 → 沒講到\n## 名字更正"),
                 context: rosterCtx, transcript: Self.rosterTranscript),
            Case(name: "meeting_roster_sounds", reply: Self.rosterMeeting.replacingOccurrences(of: "## 名字更正\n", with: "## 名字更正\n- 新河計畫 → 星河計畫｜高｜[00:05] [01:30]\n- 美林 → 美玲｜高｜[00:05]\n- 新和 → 星河｜低｜[01:30]\n"),
                 context: rosterCtx, transcript: Self.soundsTranscript),
            Case(name: "meeting_roster_state", reply: Self.rosterMeeting, context: PolishContext.make(roster: Self.sampleRoster, threads: Self.sampleThreads, open: Self.sampleOpen,
                                                                                                      excluding: nil, state: Self.sampleState), transcript: Self.rosterTranscript),
        ]
        let transcript = "- [00:12][我方] 骨架版先做半天\n- [00:30][我方] 對\n- [01:05][遠端] 預算三十萬\n（⏸ 14:32–14:44 暫停了 12 分鐘，這段沒有錄）\n- [02:10][我方] 要不要買憑證，明天"
        var out: [[String: Any]] = []
        for c in cases {
            if let g = c.glossary { try g.write(to: Paths.support.appendingPathComponent("glossary.txt"), atomically: true, encoding: .utf8) }
            else { try? FileManager.default.removeItem(at: Paths.support.appendingPathComponent("glossary.txt")) }
            try ConfigStore.shared.update { $0.endpointModel = c.endpointModel }
            let transcript = c.transcript ?? transcript
            var input = Polish.Input(transcript: transcript, title: c.title, attendees: c.attendees, dateStr: "2026-09-20 14:30", durStr: "12分30秒", warnings: c.warnings, audioLine: "{AUDIO}")
            input.scene = c.scene; input.scenario = c.scenario; input.onsite = c.onsite; input.onsiteCount = c.onsiteCount; input.brief = c.brief
            input.pauseNote = c.pauseNote; input.links = c.links; input.corrections = c.corrections; input.baseline = c.baseline; input.history = c.history
            input.context = c.context
            let fake: FakeProvider? = c.providerID.flatMap { $0 == "none" ? nil : FakeProvider(id: $0, reply: c.reply, err: c.err) }
            let provider: Provider? = c.providerID == "none" ? NoneProvider() : fake
            let r = Polish.buildNotes(input, provider: provider)
            var row: [String: Any] = [
                "name": c.name, "scene": c.scene.rawValue, "scenario": Self.any(c.scenario?.rawValue), "onsite": c.onsite, "onsiteCount": Self.any(c.onsiteCount),
                "attendees": c.attendees, "brief": c.brief, "pauseNote": Self.any(c.pauseNote), "warnings": c.warnings, "links": c.links,
                "corrections": Self.any(c.corrections), "baseline": Self.any(c.baseline), "history": c.history, "title": c.title,
                "providerID": Self.any(c.providerID), "reply": Self.any(c.reply), "err": Self.any(c.err), "glossary": Self.any(c.glossary), "endpointModel": Self.any(c.endpointModel),
                "transcript": transcript, "dateStr": "2026-09-20 14:30", "durStr": "12分30秒", "audioLine": "{AUDIO}",
                "md": r.md, "summary": r.summary, "polishErr": Self.any(r.polishErr),
                "seenSystem": Self.any(fake?.seenSystem), "seenUser": Self.any(fake?.seenUser),
                "threeLines": Polish.threeLines(md: r.md),
            ]
            if let ctx = c.context { row["context"] = Self.contextJSON(ctx) }
            out.append(row)
        }
        try ConfigStore.shared.update { $0.endpointModel = nil }
        try emit("build_notes", out)
    }

    // MARK: - 11 紀錄 md 解析、客戶版、三行重點

    func testRecordMD() throws {
        let legacy = """
            # 會議記錄 2026-08-01 10:00
            > Hearby 錄音｜時長 1小時2分｜舊的｜標題
            > 音檔：/tmp/x.m4a
            > 與會者（你填的）：甲、乙

            ## 摘要
            （AI 整理失敗：逾時）
            ## 待辦
            - [x] 已完成的事（甲；明天）
            - [ ] 沒完成的事（乙）
            - [ ] 無
            ![](圖.png)

            ---

            ## 逐字稿
            - [00:01][我方] 內容
            """
        let noteMD = "# 筆記 2026-09-20 14:30\n\n> Hearby 錄音｜時長 3分0秒\n\n## 一句話\n這篇在講 Windows 版。\n## 內容\n**時程**\n先做骨架版。[00:12]\n**預算**\n三十萬 [01:05]\n## 待辦\n- 無\n\n---\n\n## 逐字稿\n- [00:12][我方] 骨架版"
        let interviewMD = "# 訪談 2026-09-20 14:30\n\n> Hearby 錄音｜時長 3分0秒｜專訪\n\n## 摘要\n受訪者談 Windows 版。第二句。第三句。第四句。\n## 受訪者\n- 受訪者 — 回答\n## 內容\n**問：何時？**\n答：先做骨架版。[00:12]\n## 引言\n- 「先做骨架版」[00:12]\n- 「預算三十萬」[1:01:05]\n## 待辦\n- 無\n\n---\n\n## 逐字稿\n- [00:12][遠端] 先做骨架版"
        let meetingMD = "# 會議紀錄 2026-09-20 14:30\n\n> Hearby 錄音｜時長 12分30秒｜週會\n> 音檔：{AUDIO}\n> ⚠ 麥克風軌無聲，未聽打\n> 本機模型整理（qwen3:4b-instruct）：比雲端整理簡略，決議與待辦請對照逐字稿再看一次\n\n" + Self.goodMeeting + "\n## 修正紀錄\n- 2026-09-01：名字改正\n\n---\n\n## 逐字稿\n- [00:12][我方] 骨架版先做半天\n- [01:05][遠端] 預算三十萬"
        let onlyTranscript = "# 會議紀錄 2026-09-20 14:30\n\n> Hearby 錄音｜時長 1分0秒\n\n## AI 會議摘要\n（只有逐字稿：這場沒有接 AI 整理。）\n\n---\n\n## 逐字稿\n- [00:01][我方] 你好"
        var cases: [[String: Any]] = []
        let fixedMD = meetingMD.replacingOccurrences(of: "> ⚠ 麥克風軌無聲", with: "> 名字更正：逐字稿照名冊改了 2 處（林曉安→林小安 ×2）\n> ⚠ 麥克風軌無聲")
            .replacingOccurrences(of: "預算三十萬。", with: "預算三十萬，梅玲 [[?]]提到憑證。")
        for (name, md) in [("legacy", legacy), ("note", noteMD), ("interview", interviewMD), ("meeting", meetingMD), ("transcript_only", onlyTranscript), ("empty", ""), ("meeting_name_fixes", fixedMD)] {
            let r = RecordMD.parse(md: md)
            let p = r.parts
            cases.append([
                "name": name, "md": md, "title": r.title, "meta": r.meta, "declaredAttendees": r.declaredAttendees,
                "sections": r.sections.map { ["name": $0.name, "lines": $0.lines] },
                "todos": r.todos.map { ["item": $0.item, "owner": $0.owner, "due": $0.due, "done": $0.done] },
                "images": r.images, "parts": ["date": p.date, "dur": p.dur, "custom": p.custom], "summaryText": r.summaryText,
                "people": r.people, "scene": r.scene.rawValue,
                "clientVersion": RecordMD.clientVersion(md: md), "transcript": Self.any(RecordMD.transcript(of: md)), "threeLines": Polish.threeLines(md: md),
            ])
        }
        for raw in ["事項｜負責人｜期限", "事項｜負責人", "事項", "事項（甲；明天）", "事項（甲）", "  事項｜｜  ", "a｜b｜c｜d"] {
            let t = RecordMD.todoParts(raw)
            cases.append(["name": "todoParts", "raw": raw, "item": t.item, "owner": t.owner, "due": t.due])
        }
        for (title, _) in [("# 訪談 x", 0), ("# 筆記 x", 0), ("# 會議紀錄 x", 0), ("# 會議記錄 x", 0), ("隨便", 0)] {
            cases.append(["name": "sceneFromTitle", "raw": title, "scene": RecordScene.from(mdTitle: title).rawValue])
        }
        try emit("record_md", cases)
    }

    // MARK: - 12 重新整理的零件

    func testRepolishParts() throws {
        var cases: [[String: Any]] = []
        let peopleLists: [[String]] = [["王小明（我方）", "現場A（推測）", "遠端 2", "Speaker B", "現場經理王小明", "受訪者", "陳美玲（行銷部）", "電話端", "我方", "Kevin(遠端)"], [], ["訪談者甲乙丙"]]
        for p in peopleLists { cases.append(["fn": "realAttendees", "people": p, "expected": Repolish.realAttendees(p)]) }
        let md = "## 待辦\n- [ ] 準備測試機｜王小明｜明天\n- [ ] 寫文案｜｜\n- [x] 已經做完的\n- [ ] 新的事項"
        let old: [(item: String, owner: String, due: String, done: Bool)] = [("準備測試機", "王小明", "明天", true), ("寫文案", "", "", false), ("不在新版的", "", "", true)]
        cases.append(["fn": "restoreTodoChecks", "md": md, "oldTodos": old.map { ["item": $0.item, "owner": $0.owner, "due": $0.due, "done": $0.done] },
                      "expected": Repolish.restoreTodoChecks(md: md, oldTodos: old)])
        try emit("repolish_parts", cases)
    }

    // MARK: - 13 記憶機械層（追加紀律）

    func testMemory() throws {
        try ConfigStore.shared.update { $0.memoryEnabled = true }
        try MemoryStore.ensure()
        let people = Paths.memory.appendingPathComponent("PEOPLE.md")
        let seededPeople = "# 人（誰是誰、怎麼稱呼、出席過哪些會）\n\n## 王小明\n- 別名：Ming、小明哥\n- 單位：產品部\n\n## 李大華\n- 出席：舊的會\n"
        try seededPeople.write(to: people, atomically: true, encoding: .utf8)
        let seeded = try MemoryStore.files.map { f -> (String, String) in (f, try String(contentsOf: Paths.memory.appendingPathComponent(f), encoding: .utf8)) }
        let m1 = "# 會議紀錄 2026-09-20 14:30\n\n> Hearby 錄音｜時長 12分30秒｜週會\n\n## AI 會議摘要\n討論 Windows 版。\n## 與會者\n- 王小明（Ming） — 自我介紹\n- 陳美玲 — 發言\n## 決議\n- 先做骨架版 [00:12]\n- 無明確決議\n## 待辦\n- [ ] 準備測試機｜王小明｜明天\n- [x] 已完成的｜陳美玲｜\n\n---\n\n## 逐字稿\n- [00:12][我方] 內容"
        let m2 = "# 會議紀錄 2026-09-21 09:00\n\n> Hearby 錄音｜時長 1小時2分\n\n## AI 會議摘要\n（只有逐字稿）\n## 待辦\n- 無\n\n---\n\n## 逐字稿\n- [00:01][我方] 你好"
        var cases: [[String: Any]] = []
        var step = 0
        for (name, md) in [("2026-09-20_1430_週會", m1), ("2026-09-21_0900_會議紀錄", m2), ("2026-09-20_1430_週會", m1)] {
            let dir = Paths.meetings.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let u = dir.appendingPathComponent(name + ".md")
            try md.write(to: u, atomically: true, encoding: .utf8)
            try MemoryStore.sync(mdURL: u)
            step += 1
            var files: [String: Any] = [:]
            for f in MemoryStore.files { files[f] = try String(contentsOf: Paths.memory.appendingPathComponent(f), encoding: .utf8) }
            let idx = try JSONSerialization.jsonObject(with: Data(contentsOf: Paths.memory.appendingPathComponent("index.json")))
            cases.append(["step": step, "id": name, "md": md, "files": files, "index": idx])
        }
        let openItems = MemoryStore.openItems()
        try emit("memory", [["seeded": Dictionary(uniqueKeysWithValues: seeded), "steps": cases, "openItems": openItems, "parseDur": ["1小時2分": MemoryStore.parseDur("1小時2分"), "12分30秒": MemoryStore.parseDur("12分30秒"), "5秒": MemoryStore.parseDur("5秒"), "": MemoryStore.parseDur("")]]])
        try ConfigStore.shared.update { $0.memoryEnabled = false }
    }

    // MARK: - 14 雜項：時間格式、夾名、本機模型位址、指令列錯誤分類、二字組

    func testMisc() throws {
        var cases: [[String: Any]] = []
        for ms in [0, 999, 1000, 59_999, 60_000, 3_599_000, 3_600_000, 3_661_000, 36_000_000] { cases.append(["fn": "ts", "ms": ms, "expected": Fmt.ts(ms)]) }
        for s in [0, 5, 59.9, 60, 61, 3599, 3600, 3725, -1, 1e300] as [Double] { cases.append(["fn": "dur", "seconds": s, "expected": Fmt.dur(s), "clamped": Fmt.clampSeconds(s)]) }
        for f in ["2026-09-20_1430_週會", "2026-09-20_1430", "2026-09-20_1430_", "隨便的夾", "2026-09-20-1430_x", "2026-09-20_1430_標題_有底線"] {
            let (d, t) = MeetingIndex.split(folderName: f)
            cases.append(["fn": "splitFolder", "input": f, "date": d, "title": t])
        }
        for t in ["週會", "", "   ", "a/b:c\\d", "換行\n標題", "表情😀標題", String(repeating: "長", count: 80), String(repeating: "🙂", count: 70), "結尾空白 ", "\u{0007}控制字元"] {
            cases.append(["fn": "safeTitle", "input": t, "expected": Paths.safeTitle(t)])
        }
        for u in ["http://127.0.0.1:11434", "http://localhost:1234/v1/", "https://my.server.com", "http://192.168.1.5:11434", "http://100.100.1.1:11434", "http://box.tail1234.ts.net", "ftp://x.com", "not a url", "http://[::1]:11434", ""] {
            cases.append(["fn": "urlProblem", "input": u, "expected": Self.any(LocalEndpoint.urlProblem(u)), "root": LocalEndpoint.root(u)])
        }
        for (sys, user, cap) in [(1000, 5000, 32768), (2000, 30000, 32768), (500, 100, 16384), (1000, 60000, 65536)] {
            cases.append(["fn": "contextFor", "system": sys, "user": user, "maxOutput": 6000, "cap": cap, "expected": Self.any(LocalEndpoint.contextFor(systemChars: sys, userChars: user, maxOutput: 6000, cap: cap))])
        }
        for gb in [8, 15, 16, 31, 32, 64] as [UInt64] { cases.append(["fn": "maxContextTokens", "gb": gb, "expected": LocalEndpoint.maxContextTokens(physicalMemory: gb * 1_073_741_824)]) }
        for s in ["<think>想一想</think>\n## AI 會議摘要\n內容", "沒有思考", "<think>a</think>b<think>c</think>d"] { cases.append(["fn": "stripThinking", "input": s, "expected": LocalEndpoint.stripThinking(s)]) }
        let runs: [(Int32, String, String, Bool)] = [
            (0, "", "", true), (-1, "", "spawn failed: no such file", false), (127, "", "env: node: No such file or directory", false),
            (1, "", "Error: You've hit your session limit · resets 3pm", false), (1, "Prompt is too long", "", false), (1, "", "API Error: 529 overloaded", false),
            (2, "", "line one\nline two\nline three", false), (1, "stdout only\nsecond", "", false),
        ]
        for (st, out, err, to) in runs {
            var r = RunResult(status: st, stdout: out, stderr: err)
            r.timedOut = to
            cases.append(["fn": "cliExplain", "status": Int(st), "stdout": out, "stderr": err, "timedOut": to, "expected": Self.any(CLIFailure.explain(r, who: "Claude", seconds: 900)), "tail": CLIFailure.tail(r)])
        }
        for (a, b) in [("今天討論預算", "今天我們討論預算與時程"), ("好", "好的"), ("", "x"), ("Hello World", "hello world"), ("A1B2", "A1B2C3")] {
            cases.append(["fn": "bigram", "a": a, "b": b, "bigramsA": Array(Transcriber.bigrams(a)).sorted(), "containment": Transcriber.bigramContainment(a, b)])
        }
        try emit("misc", cases)
    }

    // MARK: - 15 端到端：一場錄音從 wav 到紀錄（聽打換成假的 whisper：依片名回固定 JSON）

    func testPipelineEndToEnd() throws {
        // 假的 whisper-cli：照 -of 的檔名，從夾具夾複製同名 JSON；沒有就回空的
        let stub = box.appendingPathComponent("fake-whisper.sh")
        try """
            #!/bin/bash
            OF=""; while [ $# -gt 0 ]; do if [ "$1" = "-of" ]; then OF="$2"; shift; fi; shift; done
            SRC="$HEARBY_TEST_WHISPER_DIR/$(basename "$OF").json"
            if [ -f "$SRC" ]; then cp "$SRC" "$OF.json"; else echo '{"transcription":[]}' > "$OF.json"; fi
            """.write(to: stub, atomically: true, encoding: .utf8)
        chmod(stub.path, 0o755)
        setenv("HEARBY_WHISPER_CLI", stub.path, 1)
        let models = Paths.support.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: models.appendingPathComponent(SharedPaths.whisperModelFile).path, contents: Data("fake".utf8))

        func w(_ from: Int, _ to: Int, _ text: String) -> [String: Any] { ["offsets": ["from": from, "to": to], "text": text] }
        struct E2E { var name: String; var mic: [[Int]]?; var sys: [[Int]]?; var whisper: [String: [[String: Any]]]; var meta: [String: Any]; var reply: String?; var err: String? = nil; var providerNone = false }
        let t0 = "2026-09-20T06:30:00Z"
        let cases: [E2E] = [
            E2E(name: "room_with_pause", mic: [[20, 6000]], sys: nil,
                whisper: ["mic-w00-0s": [w(0, 3000, " 今天討論 Windows 版,先做骨架版"), w(3000, 7000, "預算是三十萬.")],
                          "mic-w01-8s": [w(0, 4000, "暫停回來了,繼續"), w(4000, 9000, "要不要買憑證?明天再說")]],
                meta: ["title": "週會", "attendees": "王小明、李大華", "scene": "meeting", "source": "room", "seconds": 20.0, "micMax": 0.9, "sysMax": 0.0,
                       "pauses": [["atSeconds": 8.0, "began": "2026-09-20T06:30:08Z", "ended": "2026-09-20T06:42:08Z"]]],
                reply: ContractFixtureTests.goodMeeting),
            E2E(name: "online_echo_none", mic: [[30, 6000]], sys: [[30, 6000]],
                whisper: ["mic-w00": [w(0, 3000, "我們今天先確認預算"), w(4000, 7000, "遠端說的預算三十萬可以接受"), w(8000, 11000, "遠端說的時程要再延一週"), w(12000, 15000, "好我這邊沒問題")],
                          "sys-w00": [w(3500, 7200, "遠端說的預算三十萬可以接受"), w(7900, 11200, "遠端說的時程要再延一週")]],
                meta: ["title": "", "attendees": "", "scene": "meeting", "source": "online", "seconds": 30.0, "micMax": 0.9, "sysMax": 0.9],
                reply: nil, providerNone: true),
            E2E(name: "online_silent_system_error", mic: [[12, 6000]], sys: [[12, 0]],
                whisper: ["mic-w00": [w(0, 5000, "只有我這邊在講話"), w(5000, 9000, "對方好像沒聲音")]],
                meta: ["title": "客戶電話", "attendees": "", "scene": "meeting", "source": "online", "seconds": 12.0, "micMax": 0.9, "sysMax": 0.001],
                reply: nil, err: "Claude 的額度暫時用完了（它說：hit your limit）。等它恢復後按「重新整理全篇」。"),
            E2E(name: "interview_note_scene", mic: [[10, 6000]], sys: nil,
                whisper: ["mic-w00": [w(0, 5000, "請問你怎麼看 Windows 版"), w(5000, 9000, "我覺得先做骨架版比較穩")]],
                meta: ["title": "專訪", "attendees": "", "scene": "interview", "source": "room", "seconds": 10.0, "micMax": 0.9, "sysMax": 0.0],
                reply: ContractFixtureTests.goodInterview),
        ]
        var out: [[String: Any]] = []
        for c in cases {
            let wdir = box.appendingPathComponent("whisper-\(c.name)", isDirectory: true)
            try FileManager.default.createDirectory(at: wdir, withIntermediateDirectories: true)
            for (k, v) in c.whisper { try JSONSerialization.data(withJSONObject: ["transcription": v], options: [.sortedKeys]).write(to: wdir.appendingPathComponent(k + ".json")) }
            setenv("HEARBY_TEST_WHISPER_DIR", wdir.path, 1)
            let dir = Pipeline.recordingsDir.appendingPathComponent("rec-e2e-\(c.name)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let s = c.mic { try Self.writeWav(Self.synthPCM(s), to: dir.appendingPathComponent("mic.wav")) }
            if let s = c.sys { try Self.writeWav(Self.synthPCM(s), to: dir.appendingPathComponent("system.wav")) }
            var m = MeetingMeta()
            m.started = Self.iso(t0); m.title = c.meta["title"] as! String; m.attendees = c.meta["attendees"] as! String
            m.scene = c.meta["scene"] as? String; m.source = c.meta["source"] as? String; m.seconds = c.meta["seconds"] as! Double
            m.micMax = Float(c.meta["micMax"] as! Double); m.sysMax = Float(c.meta["sysMax"] as! Double)
            if let ps = c.meta["pauses"] as? [[String: Any]] {
                m.pauses = ps.map { PauseSpan(atSeconds: $0["atSeconds"] as! Double, began: Self.iso($0["began"] as! String), ended: ($0["ended"] as? String).map(Self.iso)) }
            }
            let fake = FakeProvider(reply: c.reply, err: c.err)
            let provider: Provider = c.providerNone ? NoneProvider() : fake
            let r = try Pipeline().process(dir: dir, meta: m, provider: provider)
            let rootPath = Paths.root.path, workPath = dir.path
            func norm(_ s: String?) -> Any { s.map { $0.replacingOccurrences(of: workPath, with: "{WORK}").replacingOccurrences(of: rootPath, with: "{ROOT}") as Any } ?? NSNull() }
            let md = try String(contentsOf: r.mdURL, encoding: .utf8)
            let transcript = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
            out.append([
                "name": c.name, "mic": Self.anyArr(c.mic), "sys": Self.anyArr(c.sys), "whisper": c.whisper, "meta": c.meta, "started": t0,
                "providerNone": c.providerNone, "reply": Self.any(c.reply), "err": Self.any(c.err),
                "mdName": r.mdURL.lastPathComponent, "md": norm(md), "transcript": norm(transcript), "summary": r.summary, "polishErr": Self.any(r.polishErr),
                "seenSystem": c.providerNone ? NSNull() : norm(fake.seenSystem), "seenUser": c.providerNone ? NSNull() : norm(fake.seenUser),
            ])
        }
        try emit("pipeline_e2e", out)
    }
    private static func anyArr(_ v: [[Int]]?) -> Any { v.map { $0 as Any } ?? NSNull() }

    // MARK: - 16 別名表（PEOPLE.md／GLOSSARY.md → 聽打後的字串替換）

    func testAliasTable() throws {
        try MemoryStore.ensure()
        let heads = ["PEOPLE.md", "GLOSSARY.md"].map { f in (try? String(contentsOf: Paths.memory.appendingPathComponent(f), encoding: .utf8)) ?? "" }
        let inputs: [(String, String)] = [
            (heads[0], heads[1]),
            ("# 人\n\n## Kevin\n- 別名：Kevien、Kevyn\n- 單位：產品部\n\n## 王小明\n- 別名: 小明哥, Ming\n- aliases: Xiaoming\n",
             "# 詞\nHearby = Herbie, 賀比\n- Talky ＝ Tokey、托基\nFully = F\n = 沒有正名\n"),
            ("# 人\n\n<!-- 範例：\n## 假人\n- 別名：假名字、假名二\n-->\n## Kevin\n- 別名：Kevien <!-- 舊寫法：Kevyn -->\n",
             "# 專有名詞與別名（正名 = 別名1, 別名2；下一場聽打後自動改正）\n\n<!-- 單行註解：Pizza = 披薩 -->\nHearby = Herbie, 賀比 <!-- Herby 也常見 -->\n<!-- 不自動改：\n     流星 = 劉興\n-->\n## 也是標題 = 不是別名\nTalky = Tokey\n<!-- 沒收尾的註解一路算到檔尾\nFully = Fooly\n"),
            ("# 人\r\n\r\n## Kevin\r\n- 別名：Kevien\r\n", "# 詞\r\nHearby = Herbie\r\n<!-- a = bb -->Talky = Tokey\r\n"),
        ]
        let text = "Kevien 說 Herbie 很好，賀比 跟 Tokey 也是；別名1 不動"
        var cases: [[String: Any]] = []
        for (people, glossary) in inputs {
            try people.write(to: Paths.memory.appendingPathComponent("PEOPLE.md"), atomically: true, encoding: .utf8)
            try glossary.write(to: Paths.memory.appendingPathComponent("GLOSSARY.md"), atomically: true, encoding: .utf8)
            let table = Clean.aliasTable()
            let (applied, n) = Clean.applyAliases(text, table: table)
            cases.append(["people": people, "glossary": glossary, "expected": table.map { [$0.alias, $0.canonical] }, "text": text, "applied": applied, "count": n])
        }
        try emit("alias_table", cases)
    }

    // MARK: - 17 記憶同步（紀錄改過之後：只換 Hearby 寫的、沒人動過的行）
    //
    // 一串步驟照順序重播：write＝寫一個檔（相對 HEARBY_OUTPUT_ROOT；modified＝修改時間）、sync＝同步一場、
    // syncAll＝同步每一場、forget＝從 memory/.hearby-written.json 拿掉一場（當成舊版 Hearby 寫的）。
    // 每次同步後記下三個檔全文、index.json、.hearby-written.json、備份檔（檔名裡的日期寫成 {DAY}）

    static let syncA1 = """
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
    static let syncA2 = """
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
    static let syncB1 = "# 訪談 2026-09-21 09:00\n\n> Hearby 錄音｜時長 30分｜專訪\n\n## 摘要\n受訪者談導入流程。\n## 受訪者\n- 受訪者 — 回答\n## 內容\n**問：怎麼導入？**\n答：先試一週。[00:10]\n## 待辦\n- [ ] 寄問卷｜｜週五\n- [ ] 約第二次訪談｜｜\n\n---\n\n## 逐字稿\n- [00:10][遠端] 先試一週"
    static let syncB2 = "# 訪談 2026-09-21 09:00\n\n> Hearby 錄音｜時長 30分｜專訪\n\n## 摘要\n受訪者談導入流程與預算。\n## 受訪者\n- 受訪者 — 回答\n## 內容\n**問：怎麼導入？**\n答：先試一週。[00:10]\n## 待辦\n- [ ] 寄問卷｜陳美玲｜週五\n- [ ] 約第二次訪談｜｜\n- [ ] 整理訪談重點｜｜\n\n---\n\n## 逐字稿\n- [00:10][遠端] 先試一週"
    static let syncC1 = "# 會議紀錄 2026-09-22 10:00\n\n> Hearby 錄音｜時長 5分\n\n## AI 會議摘要\n確認場地。\n## 與會者\n- 張志明 — 發言\n- 林小芳（推測） — 發言\n## 決議\n- 無明確決議\n## 待辦\n- [ ] 訂場地｜張志明｜\n\n---\n\n## 逐字稿\n- [00:01][我方] 你好"
    static let syncD1 = "# 會議紀錄 2026-09-23 16:00\n\n> Hearby 錄音｜時長 1分0秒\n\n## AI 會議摘要\n（只有逐字稿：這場沒有接 AI 整理。）\n\n---\n\n## 逐字稿\n- [00:01][我方] 你好"

    func testMemorySync() throws {
        try ConfigStore.shared.update { $0.memoryEnabled = true }
        try MemoryStore.ensure()
        let day = MemoryStore.Backups().day
        let fm = FileManager.default
        let t0 = Self.iso("2026-09-20T06:00:00Z")
        let (a, b, c, d) = ("2026-09-20_1430_週會", "2026-09-21_0900_專訪", "2026-09-22_1000_會議紀錄", "2026-09-23_1600_會議紀錄")
        func rec(_ id: String, _ suffix: String = ".md") -> String { "會議/\(id)/\(id)\(suffix)" }
        var steps: [[String: Any]] = []

        func write(_ path: String, _ text: String, modified: Date? = nil) throws {
            let u = Paths.root.appendingPathComponent(path)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
            if let m = modified { try fm.setAttributes([.modificationDate: m], ofItemAtPath: u.path) }
            steps.append(["op": "write", "path": path, "text": text, "modified": Self.any(modified.map(Self.isoString))])
        }
        func memory(_ f: String) throws -> String { try String(contentsOf: Paths.memory.appendingPathComponent(f), encoding: .utf8) }
        func edit(_ f: String, _ pairs: [(String, String)]) throws {
            var t = try memory(f)
            for (x, y) in pairs { XCTAssertTrue(t.contains(x), "找不到要改的：\(x)"); t = t.replacingOccurrences(of: x, with: y) }
            try write("memory/\(f)", t)
        }
        func json(_ f: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(contentsOf: Paths.memory.appendingPathComponent(f))) }
        func after() throws -> [String: Any] {
            var files: [String: Any] = [:]
            for f in ["MEETINGS.md", "OPEN.md", "PEOPLE.md"] { files[f] = try memory(f) }
            var baks: [String: Any] = [:]
            for n in try fm.contentsOfDirectory(atPath: Paths.memory.path) where n.contains(".bak-") { baks[n.replacingOccurrences(of: day, with: "{DAY}")] = try memory(n) }
            return ["files": files, "index": try json("index.json"), "written": try json(MemoryStore.writtenBook), "backups": baks]
        }
        func report(_ r: MemoryStore.SyncReport?) -> Any {
            guard let r else { return NSNull() }
            return ["id": r.id, "isNew": r.isNew, "changed": r.changed, "kept": r.kept, "backups": r.backups.map { $0.lastPathComponent.replacingOccurrences(of: day, with: "{DAY}") }]
        }
        func sync(_ path: String) throws {
            let r = try MemoryStore.sync(mdURL: Paths.root.appendingPathComponent(path))
            steps.append(["op": "sync", "path": path, "report": report(r), "after": try after()])
        }
        func syncAll() throws {
            let rs = MemoryStore.sync(MemoryStore.allRecords()).map { r -> [String: Any] in
                ["path": "會議/\(r.url.deletingLastPathComponent().lastPathComponent)/\(r.url.lastPathComponent)", "report": report(r.report), "error": Self.any(r.error)]
            }
            steps.append(["op": "syncAll", "reports": rs, "after": try after()])
        }
        func forget(_ id: String) throws {
            var book = try json(MemoryStore.writtenBook) as! [String: Any]
            var ms = book["meetings"] as! [String: Any]
            ms[id] = nil
            book["meetings"] = ms
            try MemoryStore.saveJSON(book, to: Paths.memory.appendingPathComponent(MemoryStore.writtenBook))
            steps.append(["op": "forget", "id": id])
        }

        try write("memory/PEOPLE.md", "# 人（誰是誰、怎麼稱呼、出席過哪些會）\n\n<!-- 每人一節：## 名字 ／ - 別名：… ／ - 單位：… ／ - 出席：會議 id -->\n\n## 王小明\n- 別名：Ming\n- 單位：產品部\n")
        try write("memory/OPEN.md", "# 還沒完成的事（開完會自動搬進來；完成就打勾）\n\n<!-- 2026-09-01_0900_舊會 -->\n- [ ] 舊的待辦｜｜｜2026-09-01_0900_舊會\n")
        // A：第一次寫 → 使用者在記憶裡動手 → 重新整理全篇（留 _舊版1）→ 再同步一次（沒變）→ 自己改紀錄（沒留舊版）
        try write(rec(a), Self.syncA1)
        try sync(rec(a))
        try edit("OPEN.md", [
            ("- [ ] 買咖啡｜｜｜\(a)", "- [x] 買咖啡｜｜｜\(a)"),
            ("- [ ] 寫官網文案｜李大化｜下週三｜\(a)", "- [ ] 寫官網文案｜陳美玲｜下週三｜\(a)"),
            ("- [ ] 整理需求｜李大化｜｜\(a)\n", "- [ ] 會後補的事｜王小明｜｜\(a)\n"),
        ])
        try edit("MEETINGS.md", [("- 摘要：討論 Windows 版與預算。", "- 摘要：（我改的）談 Windows 版。"), ("- 紀錄：會議/\(a)/\(a).md\n", "- 紀錄：會議/\(a)/\(a).md\n- 備註：這場很重要\n")])
        try edit("PEOPLE.md", [("## 李大化\n", "## 李大化\n- 別名：大化\n")])
        try write(rec(a, "_舊版1.md"), Self.syncA1, modified: t0)
        try write(rec(a), Self.syncA2)
        try sync(rec(a))
        try sync(rec(a))
        try write(rec(a), Self.syncA2.replacingOccurrences(of: "- 陳美玲 — 發言\n", with: "").replacingOccurrences(of: "時程延一週", with: "時程延兩週"))
        try sync(rec(a))
        // B：舊版 Hearby 寫的（沒有記錄），使用者打了勾，之後重新整理（有 _舊版1）
        try write(rec(b), Self.syncB1)
        try sync(rec(b))
        try forget(b)
        try edit("OPEN.md", [("- [ ] 約第二次訪談｜｜｜\(b)", "- [x] 約第二次訪談｜｜｜\(b)")])
        try write(rec(b, "_舊版1.md"), Self.syncB1, modified: t0)
        try write(rec(b), Self.syncB2)
        try sync(rec(b))
        // C：舊版 Hearby 寫的，自己改了名字、沒留舊版：靠 index.json 當初的名單認
        try write(rec(c), Self.syncC1)
        try sync(rec(c))
        try forget(c)
        try write(rec(c), Self.syncC1.replacingOccurrences(of: "林小芳（推測）", with: "林曉芳"))
        try sync(rec(c))
        // 全部同步：D 從沒寫過；翻譯檔不算
        try write(rec(d), Self.syncD1)
        try write(rec(a, ".en.md"), Self.syncA2)
        try syncAll()
        // OPEN.md 整份重來：每一場當成沒寫過，重寫一份
        try write("memory/OPEN.md", "# 還沒完成的事（開完會自動搬進來；完成就打勾）\n")
        try syncAll()
        try emit("memory_sync", steps)
    }

    // MARK: - 改標題（meeting_rename）

    static func renameRecord(_ id: String, title: String?, date: String = "2026-09-20 14:30") -> String {
        """
        # 會議紀錄 \(date)

        > Hearby 錄音｜時長 12分30秒\(title.map { "｜\($0)" } ?? "")
        > 音檔：{MEETINGS}/\(id)/\(id).m4a
        > ⚠ 系統聲音軌全程無聲

        ## AI 會議摘要
        討論預算與分工。
        ## 與會者
        - 王小明（Ming） — 主持
        - 李大華 — 報告
        ## 決議
        - 預算三十萬 [01:05]
        ## 待辦
        - [ ] 寫官網文案｜李大華｜下週三
        - [ ] 訂會議室｜王小明｜

        ---

        ## 逐字稿
        - [00:12][我方] 開始
        """
    }

    /// 步驟重播：寫檔（路徑相對沙箱根：root/…、support/…、mirror/…；{MEETINGS}＝會議資料夾的絕對路徑）、寫 meta.json、同步一場、改標題。
    /// 每次改標題之後比對：回報、會議資料夾樹、各場 meta 的 title／outName、錄音工作夾的 meta、四個記憶檔、index、
    /// .hearby-written.json、.hearby-names.json 記了哪幾場、記憶備份、副本資料夾、每場主紀錄的全文
    func testMeetingRename() throws {
        let fm = FileManager.default
        let mirror = box.appendingPathComponent("mirror")
        try ConfigStore.shared.update { $0.memoryEnabled = true; $0.mirrorDir = mirror.path }
        try MemoryStore.ensure()
        let day = MemoryStore.Backups().day
        var steps: [[String: Any]] = [["op": "config", "memoryEnabled": true, "mirror": "mirror"]]
        func expand(_ s: String) -> String { s.replacingOccurrences(of: "{MEETINGS}", with: Paths.meetings.path) }
        func norm(_ s: String) -> String { s.replacingOccurrences(of: Paths.meetings.path, with: "{MEETINGS}") }
        func rel(_ u: URL) -> String { u.path.replacingOccurrences(of: Paths.root.path + "/", with: "") }
        func write(_ path: String, _ text: String) throws {
            let u = box.appendingPathComponent(path)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try expand(text).write(to: u, atomically: true, encoding: .utf8)
            steps.append(["op": "write", "path": path, "text": text])
        }
        func meta(_ path: String, work: String, title: String, outName: String) throws {
            let d = box.appendingPathComponent(path)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            var m = MeetingMeta()
            m.id = work; m.title = title; m.outName = outName; m.started = Self.iso("2026-09-20T06:30:00Z")
            Pipeline.saveMeta(m, to: d)
            steps.append(["op": "meta", "path": path, "work": work, "title": title, "outName": outName, "started": "2026-09-20T06:30:00Z"])
        }
        func sync(_ path: String) throws {
            _ = try MemoryStore.sync(mdURL: box.appendingPathComponent(path))
            steps.append(["op": "sync", "path": path])
        }
        func json(_ f: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(contentsOf: Paths.memory.appendingPathComponent(f))) }
        func metaOf(_ d: URL) -> Any {
            guard let m = Pipeline.loadMeta(d) else { return NSNull() }
            return ["title": m.title, "outName": Self.any(m.outName)]
        }
        func state() throws -> [String: Any] {
            var tree: [String: Any] = [:], metas: [String: Any] = [:], records: [String: Any] = [:]
            for d in try fm.contentsOfDirectory(atPath: Paths.meetings.path) where !d.hasPrefix(".") {
                let dir = Paths.meetings.appendingPathComponent(d)
                tree[d] = try fm.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }.sorted()
                metas[d] = metaOf(dir)
                if let u = MeetingRename.mainRecord(in: dir) { records[d] = norm(try String(contentsOf: u, encoding: .utf8)) }
            }
            var work: [String: Any] = [:]
            for w in (try? fm.contentsOfDirectory(atPath: Pipeline.recordingsDir.path)) ?? [] where !w.hasPrefix(".") {
                work[w] = metaOf(Pipeline.recordingsDir.appendingPathComponent(w))
            }
            var files: [String: Any] = [:]
            for f in ["MEETINGS.md", "OPEN.md", "PEOPLE.md", "THREADS.md"] { files[f] = try String(contentsOf: Paths.memory.appendingPathComponent(f), encoding: .utf8) }
            let names = ((try? json(NameLedger.stateFile)) as? [String: Any])?["written"] as? [String: Any] ?? [:]
            let baks = try fm.contentsOfDirectory(atPath: Paths.memory.path).filter { $0.contains(".bak-") }.map { $0.replacingOccurrences(of: day, with: "{DAY}") }.sorted()
            return ["tree": tree, "meta": metas, "work": work, "records": records, "files": files, "index": try json("index.json"),
                    "written": try json(MemoryStore.writtenBook), "names": names.keys.sorted(), "backups": baks,
                    "mirror": try fm.contentsOfDirectory(atPath: mirror.path).sorted()]
        }
        func rename(_ folder: String, _ title: String) throws {
            let r = try MeetingRename.rename(dir: Paths.meetings.appendingPathComponent(folder), to: title)
            let report: [String: Any] = [
                "oldID": r.oldID, "newID": r.newID, "dir": rel(r.dir), "md": Self.any(r.mdURL.map(rel)), "renamed": r.renamed, "memory": r.memory,
                "backups": r.backups.map { $0.lastPathComponent.replacingOccurrences(of: day, with: "{DAY}") },
                "mirror": r.mirror.map(\.lastPathComponent), "warnings": r.warnings, "unchanged": r.unchanged,
            ]
            steps.append(["op": "rename", "folder": folder, "title": title, "report": report, "after": try state()])
        }

        let (a, b, l, c, cf, d, e) = ("2026-09-20_1430_週會", "2026-09-20_1430_週會-2", "2026-09-20_1430_週會延長", "2026-09-22_1000_訪談。", "2026-09-22_1000_訪談",
                                      "2026-09-23_1600_會議紀錄", "2026-09-24_0900_weekly sync")
        try write("root/memory/PEOPLE.md", "# 人（誰是誰、怎麼稱呼、出席過哪些會）\n\n<!-- 每人一節：## 名字 ／ - 別名：… ／ - 單位：… ／ - 出席：會議 id -->\n\n## 王小明\n- 別名：Ming\n")
        try write("root/memory/OPEN.md", "# 還沒完成的事（開完會自動搬進來；完成就打勾）\n")
        // A：一般的一場（紀錄、音檔、PDF、舊版、備份、翻譯、別的檔、meta、錄音工作夾的 meta）
        try write("root/會議/\(a)/\(a).md", Self.renameRecord(a, title: "週會"))
        for suffix in [".m4a", ".pdf", "_舊版1.md", ".md.bak-2026-09-21", ".en.md"] { try write("root/會議/\(a)/\(a)\(suffix)", "x") }
        try write("root/會議/\(a)/內網草稿.json", "{}")
        try meta("root/會議/\(a)", work: "work-1", title: "週會", outName: a)
        try meta("support/recordings/work-1", work: "work-1", title: "週會", outName: a)
        try sync("root/會議/\(a)/\(a).md")
        // B（同一分鐘撞名的第二場）、L（標題更長、id 以 A 開頭）：改 A 的時候都不能被換到
        try write("root/會議/\(b)/\(b).md", Self.renameRecord(b, title: "週會"))
        try sync("root/會議/\(b)/\(b).md")
        try write("root/會議/\(l)/\(l).md", Self.renameRecord(l, title: "週會延長"))
        try sync("root/會議/\(l)/\(l).md")
        // 使用者在記憶裡自己寫的：THREADS 提到三場、OPEN 手加一條、MEETINGS 手加一行
        try write("root/memory/THREADS.md", "# 議題\n\n## 預算\n- 預算三十萬（出處：\(a)；另見 \(b)、\(l)）\n")
        let open = try String(contentsOf: Paths.memory.appendingPathComponent("OPEN.md"), encoding: .utf8)
        try write("root/memory/OPEN.md", open + "- [ ] 我自己加的｜我｜｜\(a)\n")
        let meetings = try String(contentsOf: Paths.memory.appendingPathComponent("MEETINGS.md"), encoding: .utf8)
        try write("root/memory/MEETINGS.md", meetings.replacingOccurrences(of: "- 紀錄：會議/\(a)/\(a).md\n", with: "- 紀錄：會議/\(a)/\(a).md\n- 備註：很重要\n"))
        // 副本資料夾：A 的舊副本與翻譯、B 的副本、別的檔
        try write("mirror/\(a).md", "舊的")
        try write("mirror/\(a).en.md", "en")
        try write("mirror/\(b).md", "B")
        try write("mirror/周會記錄.docx", "別的")
        try rename(a, "第三季預算")
        try rename("2026-09-20_1430_第三季預算", "第三季預算")          // 一樣：什麼都不動
        try rename(b, "第三季預算")                                    // 撞到 A 的新名字：加 -2
        // C：資料夾被人改過（少了句號），檔名與記憶還是舊的：照資料夾的標題存一次＝補齊
        try write("root/會議/\(cf)/\(c).md", Self.renameRecord(c, title: "訪談。", date: "2026-09-22 10:00"))
        try write("root/會議/\(cf)/\(c).m4a", "x")
        try sync("root/會議/\(cf)/\(c).md")
        try rename(cf, "訪談")
        // D：沒有自訂標題（表頭只有時長）：同名＝不動；取一個標題＝表頭多一段
        try write("root/會議/\(d)/\(d).md", Self.renameRecord(d, title: nil, date: "2026-09-23 16:00"))
        try sync("root/會議/\(d)/\(d).md")
        try rename(d, "會議紀錄")
        try rename(d, "產品週會")
        // E：只差大小寫
        try write("root/會議/\(e)/\(e).md", Self.renameRecord(e, title: "weekly sync", date: "2026-09-24 09:00"))
        try sync("root/會議/\(e)/\(e).md")
        try rename(e, "Weekly Sync")
        try emit("meeting_rename", steps)
    }
}
