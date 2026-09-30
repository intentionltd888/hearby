// VoicesTests — 認聲音（只有 macOS）：聲紋存與忘、比對門檻、哪一行是誰、交給 AI 的標籤、表頭、守門
// 聲紋是假的（幾個方向不同的短向量）；名字也是假的（公開倉）。真的分段引擎不在這裡測（要下載模型）。
import Foundation
import XCTest
@testable import HearbyCore

final class VoicesTests: XCTestCase {
    var box: URL!
    override func setUp() {
        box = FileManager.default.temporaryDirectory.appendingPathComponent("hearby-voices-\(UUID().uuidString)")
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
        Voices.engine = nil
    }

    static let a: [Float] = [1, 0, 0, 0]
    static let aNear: [Float] = [0.9, 0.3, 0, 0]      // 跟 a 像 0.95
    static let b: [Float] = [0, 1, 0, 0]
    static let c: [Float] = [0.5, 0, 0.87, 0]         // 跟 a 像 0.50（不夠）

    static let clusters = [
        Voices.Cluster(id: "S1", vector: aNear, seconds: 600, spans: [0...40, 70...100]),
        Voices.Cluster(id: "S2", vector: b, seconds: 300, spans: [40...70]),
        Voices.Cluster(id: "S3", vector: c, seconds: 120, spans: [100...130]),
        Voices.Cluster(id: "S4", vector: a, seconds: 5, spans: [130...135]),     // 太短：不比、不標
    ]

    func testRememberMergeForget() throws {
        XCTAssertTrue(Voices.people().isEmpty)
        XCTAssertThrowsError(try Voices.remember(name: "林小安", cluster: Self.clusters[3], model: "m", source: "x"), "講不到 20 秒不記")
        XCTAssertThrowsError(try Voices.remember(name: "  ", cluster: Self.clusters[0], model: "m", source: "x"))
        let p = try Voices.remember(name: "林小安", cluster: Self.clusters[0], model: "m", source: "2026-09-20_1430_週會",
                                    consentDate: ISO8601DateFormatter().date(from: "2026-09-20T06:00:00Z")!)
        XCTAssertEqual(p.consent, "2026-09-20 本人同意")
        XCTAssertEqual(p.vector.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-5, "存的是正規化過的")
        // 同一個人再記一場：照秒數加權併在一起、不重複
        let q = try Voices.remember(name: "林小安", cluster: Voices.Cluster(id: "S9", vector: Self.a, seconds: 200, spans: []), model: "m", source: "2026-09-21_1000_週會")
        XCTAssertEqual(Voices.people().count, 1)
        XCTAssertEqual(q.seconds, 800)
        XCTAssertEqual(q.sources, ["2026-09-20_1430_週會", "2026-09-21_1000_週會"])
        XCTAssertEqual(q.consent, p.consent, "同意的日期留第一次的")
        // 只存在支援資料夾，不在紀錄資料夾、不在記憶裡
        XCTAssertTrue(FileManager.default.fileExists(atPath: Paths.support.appendingPathComponent("voices.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.memory.appendingPathComponent("voices.json").path))
        XCTAssertTrue(try Voices.forget("林小安"))
        XCTAssertTrue(Voices.people().isEmpty)
        XCTAssertFalse(try Voices.forget("林小安"))
        let left = try FileManager.default.contentsOfDirectory(atPath: Paths.support.path).filter { $0.hasPrefix("voices") }
        XCTAssertEqual(left, ["voices.json"], "忘記＝整筆拿掉，不留備份")
    }

    func testMatchTagsAndHeader() {
        let people = [Voices.Print(name: "林小安", vector: Self.a, seconds: 600, sources: [], consent: "", model: "m"),
                      Voices.Print(name: "陳美玲", vector: [0, 0, 0, 1], seconds: 600, sources: [], consent: "", model: "m"),
                      Voices.Print(name: "別的模型", vector: Self.b, seconds: 600, sources: [], consent: "", model: "old")]
        let m = Voices.match(Self.clusters, people, model: "m")
        XCTAssertEqual(m["S1"]?.name, "林小安")
        XCTAssertNil(m["S2"], "別的模型算的聲紋不拿來比")
        XCTAssertNil(m["S3"], "像 0.50 不夠")
        XCTAssertNil(m["S4"], "太短不比")
        let tags = Voices.tags(Self.clusters, matched: m)
        XCTAssertEqual(tags, ["S1": "林小安", "S2": "聲音A", "S3": "聲音B"])
        XCTAssertEqual(Voices.headerLine(clusters: Self.clusters, matched: m, remembered: 2), "> 聲紋：認出 林小安（10 分鐘）；另有 2 個聲音沒認出")
        XCTAssertEqual(Voices.headerLine(clusters: Self.clusters, matched: [:], remembered: 0), "> 聲紋：這場 3 個聲音都沒認出（這台 Mac 還沒記住任何人的聲音）")
        XCTAssertNil(Voices.headerLine(clusters: [Self.clusters[3]], matched: [:], remembered: 0))
    }

    func testLineTagsAndInject() {
        let tr = """
            - [00:00][現場] 大家好，開始
            - [00:45][現場] 我來報預算
            （⏸ 00:60–01:00 暫停）
            - [01:12][現場] 回到剛剛
            - [01:50][遠端] 聽得到嗎
            不是逐字稿的行
            """
        let tags = Voices.tags(Self.clusters, matched: ["S1": ("林小安", 0.95)])
        let lt = Voices.lineTags(transcript: tr, clusters: Self.clusters, tags: tags)
        XCTAssertEqual(lt, [0: "林小安", 1: "聲音A", 3: "林小安", 4: "聲音B"])
        let out = Voices.inject(tr, tags: lt)
        XCTAssertTrue(out.contains("- [00:00][現場·林小安] 大家好，開始"))
        XCTAssertTrue(out.contains("- [00:45][現場·聲音A] 我來報預算"))
        XCTAssertTrue(out.contains("- [01:50][遠端·聲音B] 聽得到嗎"))
        XCTAssertTrue(out.contains("（⏸ 00:60–01:00 暫停）\n"))
        XCTAssertEqual(Voices.inject(tr, tags: [:]), tr)
        XCTAssertEqual(Voices.seconds("1:02:03"), 3723)
        XCTAssertNil(Voices.seconds("ab:cd"))
    }

    func testScrubTagPlaceholders() {
        let notes = "## 與會者\n- 林小安（現場）— 報預算\n- 聲音A（現場）— 沒認出\n- 聲音B — 遠端\n## 待辦\n- [ ] 寄報價｜聲音A｜明天\n- [ ] 準備測試機｜林小安｜週五"
        XCTAssertEqual(Voices.scrub(notes), "## 與會者\n- 林小安（現場）— 報預算\n## 待辦\n- [ ] 寄報價｜｜明天\n- [ ] 準備測試機｜林小安｜週五")
    }

    /// 整理：有標籤＝交給 AI 的逐字稿帶「·名字」、系統提示多一段規則、表頭多一行；存下來的逐字稿不動。沒標籤＝跟以前一模一樣
    func testPolishCarriesTags() {
        final class Fake: Provider {
            let id = "fake"
            var system = "", user = ""
            var displayName: String { "假的" }
            var contextBudget: Int { 100_000 }
            var maxOutputTokens: Int { 8000 }
            var trustLevel: TrustLevel { .local }
            func check() -> ProviderStatus { ProviderStatus(.ready, "ok") }
            func complete(system: String, user: String) -> (String?, String?) {
                self.system = system; self.user = user
                return ("## AI 會議摘要\n林小安報了預算。\n## 與會者\n- 林小安（現場）\n- 聲音A（現場）\n## 重點\n- 預算三十萬 [00:45]\n## 決議\n- 無\n## 開放問題\n- 無\n## 待辦\n- [ ] 寄報價｜聲音A｜明天", nil)
            }
        }
        let tr = "- [00:00][現場] 大家好，開始\n- [00:45][現場] 預算三十萬"
        var input = Polish.Input(transcript: tr, title: "週會", attendees: "", dateStr: "2026-09-20 14:30", durStr: "2分", warnings: [], audioLine: "{AUDIO}")
        let plain = Fake()
        let before = Polish.buildNotes(input, provider: plain)
        XCTAssertFalse(plain.system.contains("說話人（聲紋）"))
        XCTAssertFalse(plain.user.contains("·"))
        XCTAssertFalse(before.md.contains("> 聲紋"))

        input.voiceTags = [0: "林小安", 1: "聲音A"]
        input.voiceLine = "> 聲紋：認出 林小安（1 分鐘）；另有 1 個聲音沒認出"
        let fake = Fake()
        let r = Polish.buildNotes(input, provider: fake)
        XCTAssertTrue(fake.system.hasSuffix(Voices.promptRule))
        XCTAssertTrue(fake.user.contains("[00:00][現場·林小安] 大家好，開始"))
        XCTAssertTrue(fake.user.contains("[00:45][現場·聲音A] 預算三十萬"))
        XCTAssertTrue(r.md.contains("\n> 聲紋：認出 林小安（1 分鐘）；另有 1 個聲音沒認出\n"))
        XCTAssertFalse(r.md.contains("- 聲音A（現場）"), "代號不進與會者")
        let todo = r.md.components(separatedBy: "\n").first { $0.contains("寄報價") } ?? ""
        XCTAssertFalse(todo.contains("聲音A"), "代號不當負責人：\(todo)")
        XCTAssertTrue(r.md.hasSuffix("## 逐字稿\n" + tr + "\n"), "存下來的逐字稿不動")
        // 給客戶的版本不帶這一行
        XCTAssertFalse(RecordMD.clientVersion(md: r.md).contains("聲紋"))
    }

    /// 分軌：聲紋只跟同一軌比；遠端的行只看電腦聲音那軌，其他看麥克風那軌；一個人可以每軌各一筆
    func testTracks() throws {
        let mic = Voices.Cluster(id: "mic:S1", vector: Self.aNear, seconds: 600, spans: [0...60], track: "mic")
        let sys = Voices.Cluster(id: "system:S1", vector: Self.aNear, seconds: 300, spans: [0...60], track: "system")
        let other = Voices.Cluster(id: "system:S2", vector: Self.b, seconds: 300, spans: [60...120], track: "system")
        let people = [Voices.Print(name: "林小安", vector: Self.a, seconds: 600, sources: [], consent: "", model: "m", track: "mic")]
        let m = Voices.match([mic, sys, other], people, model: "m")
        XCTAssertEqual(m["mic:S1"]?.name, "林小安")
        XCTAssertNil(m["system:S1"], "麥克風記的聲紋不拿去比電腦聲音那軌")
        let tags = Voices.tags([mic, sys, other], matched: m)
        let tr = "- [00:10][我方] 我先講\n- [00:12][遠端] 對方回\n- [01:10][遠端] 另一個人"
        XCTAssertEqual(Voices.lineTags(transcript: tr, clusters: [mic, sys, other], tags: tags), [0: "林小安", 1: "聲音A", 2: "聲音B"])
        // 同一個人：麥克風一筆、電腦聲音一筆，分開存、忘記時一起拿掉
        try Voices.remember(name: "林小安", cluster: mic, model: "m", source: "x")
        try Voices.remember(name: "林小安", cluster: sys, model: "m", source: "y")
        XCTAssertEqual(Voices.people().map(\.track), ["mic", "system"])
        try Voices.forget("林小安")
        XCTAssertTrue(Voices.people().isEmpty)
    }

    /// 喇叭回音：麥克風那軌的聲音大多跟電腦聲音重疊＝回音，拿掉；自己講、偶爾搶話的留著
    func testDropEchoes() {
        let me = Voices.Cluster(id: "mic:S1", vector: Self.a, seconds: 100, spans: [0...80, 200...220], track: "mic")
        let echo = Voices.Cluster(id: "mic:S2", vector: Self.b, seconds: 50, spans: [100...140, 150...160], track: "mic")
        let far = Voices.Cluster(id: "system:S1", vector: Self.c, seconds: 90, spans: [70...160], track: "system")
        XCTAssertEqual(Voices.dropEchoes([me, echo, far]).map(\.id), ["mic:S1", "system:S1"])
        XCTAssertEqual(Voices.dropEchoes([me, echo]).map(\.id), ["mic:S1", "mic:S2"], "只有一軌不判斷")
    }

    /// 音源：工作夾的分軌（空檔不算）；紀錄資料夾的 meta.json 指得到分軌就用分軌，不然用 m4a
    func testSources() throws {
        let fm = FileManager.default
        let work = Pipeline.recordingsDir.appendingPathComponent("test-recording")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try Data(count: 5_000).write(to: work.appendingPathComponent("mic.wav"))
        try Data(count: 44).write(to: work.appendingPathComponent("system.wav"))
        XCTAssertEqual(Voices.sources(workDir: work).map(\.track), ["mic"])
        let meeting = Paths.meetings.appendingPathComponent("2026-09-20_1430_週會")
        try fm.createDirectory(at: meeting, withIntermediateDirectories: true)
        let m4a = meeting.appendingPathComponent("2026-09-20_1430_週會.m4a")
        try Data(count: 10).write(to: m4a)
        XCTAssertEqual(Voices.sources(meetingDir: meeting, m4a: m4a).map(\.track), ["mix"], "沒有 meta.json：用 m4a")
        try #"{"id": "test-recording"}"#.write(to: meeting.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Voices.sources(meetingDir: meeting, m4a: m4a).map(\.track), ["mic"])
        try #"{"id": "../../etc"}"#.write(to: meeting.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Voices.sources(meetingDir: meeting, m4a: m4a).map(\.track), ["mix"], "id 帶路徑不認")
        XCTAssertEqual(Voices.sources(meetingDir: meeting, m4a: nil), [])
    }

    /// 一軌沒有語音（現場開會，電腦聲音那軌整條安靜）：跳過那軌、另一軌照認；每一軌都失敗才算失敗
    func testSilentTrackIsSkipped() throws {
        final class Stub: Voices.Engine {
            let model = "m"
            func clusters(of audio: URL, progress: ((String) -> Void)?) async throws -> [Voices.Cluster] {
                if audio.lastPathComponent == "system.wav" { throw HearbyError("No speech detected in audio") }
                return [Voices.Cluster(id: "S1", vector: VoicesTests.a, seconds: 300, spans: [0...300])]
            }
        }
        let e = Stub()
        let mic = Voices.Source(url: URL(fileURLWithPath: "/x/mic.wav"), track: "mic")
        let sys = Voices.Source(url: URL(fileURLWithPath: "/x/system.wav"), track: "system")
        XCTAssertEqual(try Voices.clusters(of: [mic, sys], engine: e).map(\.id), ["mic:S1"])
        XCTAssertThrowsError(try Voices.clusters(of: [sys], engine: e))
    }

    /// 沒開、不能用、沒有錄音：不認、不擋整理
    func testRecognizeIsOptIn() {
        XCTAssertNil(Voices.recognize(sources: [], transcript: ""))
        XCTAssertFalse(Voices.enabled)
        XCTAssertNil(Voices.recognize(sources: [Voices.Source(url: URL(fileURLWithPath: "/tmp/not-there.m4a"), track: "mix")], transcript: ""), "沒開就不跑")
    }
}
