// Transcript — whisper 轉寫（切片跑、迴圈修補、整片退化重轉、續跑）
//
// 同一個 wav 切 15 分鐘暫存片段逐一跑：每片 30 MB 記憶體、切點對齊靜音、無聲片跳過、
// 每片 JSON 即落地＝續跑、一片失敗只重跑那一片。從 stderr 認 Metal 有沒有載到。

import Foundation

public struct MeetingMeta: Codable, Equatable {
    public var schemaVersion: Int? = 1
    public var id: String? = nil          // 工作夾名（yyyyMMdd_HHmmss）
    public var title: String = ""
    public var attendees: String = ""
    public var started: Date = Date()
    public var seconds: Double = 0
    public var micMax: Float = 0
    public var sysMax: Float = 0
    public var warnings: [String] = []
    public var scene: String? = nil        // meeting／interview／call／memo
    public var source: String? = nil       // room／online／mixed（實際用的收音來源）
    public var scenario: String? = nil     // 判定後的 prompt 情境（MeetingScenario.rawValue）
    public var onsiteCount: Int? = nil
    public var brief: [String]? = nil
    public var imported: Bool? = nil
    public var sourceFile: String? = nil
    public var provider: String? = nil     // 整理用的 provider id
    public var outName: String? = nil      // 定案的紀錄檔名（續跑沿用）
    public var versions: [String]? = nil   // 重整理的版本紀錄
    public var pauses: [PauseSpan]? = nil  // 錄音中途的暫停（位置＝錄到的秒數；按下與繼續當下就存，當機也不丟）
    public init() {}
}

/// prompt 情境變體（軌≠人：通道是事實，「軌裡是誰」由情境映射）
public enum MeetingScenario: String, CaseIterable {
    case onsite
    case onlineHeadphones = "online_headphones"
    case onlineSpeaker = "online_speaker"
    case phoneSpeaker = "phone_speaker"
    public var displayName: String {
        switch self {
        case .onsite: return "只有現場人"
        case .onlineHeadphones: return "線上・戴耳機"
        case .onlineSpeaker: return "線上・開喇叭"
        case .phoneSpeaker: return "電話擴音"
        }
    }
    public var micWho: String {
        switch self {
        case .onsite, .phoneSpeaker: return "現場"
        case .onlineHeadphones, .onlineSpeaker: return "我方"
        }
    }
}

public struct Segment: Equatable {
    public let fromMs: Int
    public let toMs: Int
    public let text: String
    public let who: String
    public init(fromMs: Int, toMs: Int, text: String, who: String) {
        self.fromMs = fromMs; self.toMs = toMs; self.text = text; self.who = who
    }
}

public enum WhisperEngine {
    /// whisper-cli：環境變數 > app 內 Resources/whisper > 常見安裝位置
    public static func cliPath() -> String? {
        var c: [String] = []
        if let e = ProcessInfo.processInfo.environment["HEARBY_WHISPER_CLI"], !e.isEmpty { c.append(e) }
        if let res = Bundle.main.resourceURL { c.append(res.appendingPathComponent("whisper/whisper-cli").path) }
        c += ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        return c.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    /// GGML_BACKEND_PATH：直指 Metal 後端（混雜資料夾自動搜尋只會上 CPU）
    public static func env(forCLI cli: String) -> [String: String] {
        let dir = (cli as NSString).deletingLastPathComponent
        let metal = dir + "/libggml-metal.so"
        return ["GGML_BACKEND_PATH": FileManager.default.fileExists(atPath: metal) ? metal : dir]
    }
    /// 效能核心數＝CPU 轉寫執行緒數
    public static let perfCores: Int = {
        var n: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel0.physicalcpu", &n, &sz, nil, 0)
        return n > 0 ? Int(n) : max(4, ProcessInfo.processInfo.activeProcessorCount / 2)
    }()
}

public final class Transcriber {
    public var onStage: ((String) -> Void)?
    private func stage(_ s: String) { onStage?(s) }

    public static let sliceTargetMs = 15 * 60_000
    public static let sliceSearchMs = 30_000
    public static let sliceSilence: Float = 0.015
    /// 低於這個＝真的沒聲音（沒開線上會議時的系統聲軌是數位靜音），不聽打也不備註
    public static let quietFloor: Float = 0.0005
    /// 小聲片放大上限（1000 倍＝+60 dB）
    public static let quietGainMax: Float = 1000
    public static let loopMinRepeats = 6
    public static let loopMinSpanMs = 15_000
    static let prompt = "以下是台灣繁體中文的會議對話逐字稿。"

    public private(set) var notes: [String] = []
    public private(set) var usedMetal: Bool? = nil

    public init() {}

    /// 小聲片（整片最響的 0.1 秒都不到 `sliceSilence`）要不要放大聽打、放大幾倍；nil＝照舊跳過。
    ///
    /// 直接跳過的話整片沒字，只留一句「音量太小，未聽打」。
    /// 實測（一場收音正常的會議前 5 分鐘、916 字當標準答案，人為壓小聲）：
    ///
    ///     壓 −45 dB（電平 0.012，會被跳過）  原樣聽打字錯率  9.8%   放大後  9.5%
    ///     壓 −55 dB（電平 0.0038）           原樣聽打       13.6%   放大後 11.2%
    ///     壓 −65 dB（電平 0.0012）           原樣聽打       25.3%   放大後 19.8%
    ///
    /// 跳過＝100% 沒字，放大聽打＝八到九成對。反向也測了：純粉紅噪音與沒人講話的系統聲軌
    /// 放大後，whisper 只吐「中文字幕:CM 李宗盛」「MING PAO…」——都在 `Hallucination` 片語表裡，
    /// 濾完零句，呼叫端照舊記「音量太小，未聽打」。
    ///
    /// ⚠ 這裡只救「以前整片丟掉」的片。對聽得到的錄音全面拉平音量（ffmpeg dynaudnorm、
    /// 固定增益對齊峰值或均值）在三場真實錄音上量過，**不是乾淨的贏**：個別詞變對，
    /// 但時間戳變粗（685 段→531 段、冒出 25 秒以上長段）、
    /// 一場出現「沒問題。」連跳 7 次、一場靜音尾巴被放大出一句幻聽。沒有標準答案前不要做。
    public static func quietBoost(levels lv: [Float], pcm: [Int16]) -> Float? {
        let peak = lv.max() ?? 0
        guard peak > quietFloor, peak < sliceSilence else { return nil }
        // 平穩底噪（冷氣、風扇）沒有人聲的起伏：最響的 5% 不到最靜的 25% 的 2.5 倍就不放大
        //（實測四段人聲 5.8–7.9 倍、粉紅噪音 1.4 倍；斷續的提示音底是 0，放行後交給幻聽濾網）。
        // 底用 p25 不用中位數：講話佔超過一半時間時，中位數自己就是人聲。
        let sorted = lv.sorted()
        let p25 = sorted[sorted.count / 4]
        let p95 = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        if p25 > 0, p95 < p25 * 2.5 { return nil }
        var maxAbs: Int32 = 0
        for v in pcm { let m = abs(Int32(v)); if m > maxAbs { maxAbs = m } }
        guard maxAbs > 0 else { return nil }
        return min(quietGainMax, 0.7 * 32767 / Float(maxAbs))
    }

    /// 規劃切點：短檔不切；切點取「目標點 ±30 秒」內最安靜的 0.5 秒中心。
    /// forcedCuts＝一定要切的位置（中途暫停的地方）：暫停前後在音檔裡是直接接著的，不切的話 whisper 會把兩邊的話併成同一句，
    /// 暫停標記就放不到對的位置。切出來的兩邊都要至少 2 秒，太短就不切。
    public static func planSlices(wav: URL, totalMs: Int, targetMs: Int = sliceTargetMs, forcedCuts: [Int] = []) -> [(Int, Int)] {
        split(silenceSlices(wav: wav, totalMs: totalMs, targetMs: targetMs), at: forcedCuts)
    }

    static func split(_ slices: [(Int, Int)], at cuts: [Int], minMs: Int = 2000) -> [(Int, Int)] {
        guard !cuts.isEmpty else { return slices }
        var out: [(Int, Int)] = []
        for (a, b) in slices {
            var start = a
            for c in cuts.sorted() where c - start >= minMs && b - c >= minMs {
                out.append((start, c)); start = c
            }
            out.append((start, b))
        }
        return out
    }

    static func silenceSlices(wav: URL, totalMs: Int, targetMs: Int) -> [(Int, Int)] {
        if totalMs <= targetMs * 135 / 100 { return [(0, totalMs)] }
        var cuts: [Int] = [0]
        var mark = targetMs
        while totalMs - mark > targetMs * 35 / 100 {
            let a = max(cuts.last! + 60_000, mark - sliceSearchMs)
            let b = min(totalMs, mark + sliceSearchMs)
            var best = mark
            let lv = WavIO.blockLevels(WavIO.readPCM(wav, fromMs: a, toMs: b))
            if lv.count >= 5 {
                var sum: Float = lv[0..<5].reduce(0, +)
                var bestSum = sum
                var bestI = 0
                var i = 1
                while i + 5 <= lv.count {
                    sum += lv[i + 4] - lv[i - 1]
                    if sum < bestSum { bestSum = sum; bestI = i }
                    i += 1
                }
                best = a + (bestI + 2) * 100 + 50
            }
            cuts.append(best)
            mark = best + targetMs
        }
        cuts.append(totalMs)
        return zip(cuts, cuts.dropFirst()).map { ($0, $1) }
    }

    /// 解析 whisper -oj 的 JSON → (segs, loops, rawRepeat)
    public static func parseWhisperJSON(_ url: URL, offsetMs: Int, who: String) throws
        -> (segs: [Segment], loops: [(Int, Int)], rawRepeat: Double)
    {
        let data = Data(String(decoding: try Data(contentsOf: url), as: UTF8.self).utf8)   // 壞位元組換成 U+FFFD，不讓一個壞字丟掉整片
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let trans = obj["transcription"] as? [[String: Any]]
        else { throw HearbyError("whisper JSON 解析失敗") }
        var segs: [Segment] = []
        var loops: [(Int, Int)] = []
        var lastTo = 0
        var runText = ""; var runStart = 0; var runEnd = 0; var runCount = 0
        var rawTotal = 0; var rawDup = 0
        func closeRun() {
            if runCount >= loopMinRepeats, runEnd - runStart >= loopMinSpanMs { loops.append((runStart + offsetMs, runEnd + offsetMs)) }
        }
        for t in trans {
            guard let raw = t["text"] as? String else { continue }
            let offsets = t["offsets"] as? [String: Any]
            let from = (offsets?["from"] as? Int) ?? lastTo
            let to = (offsets?["to"] as? Int) ?? from
            lastTo = max(lastTo, to)
            let rawTrim = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            rawTotal += 1
            if rawTrim == runText, !rawTrim.isEmpty { rawDup += 1; runCount += 1; runEnd = to }
            else { closeRun(); runText = rawTrim; runStart = from; runEnd = to; runCount = 1 }
            let text = Clean.toTraditional(Clean.normalizePunct(rawTrim))
            if text.isEmpty || Hallucination.isJunk(text, signals: .init(noSpeechProb: t["no_speech_prob"] as? Double, durationMs: to - from)) { continue }
            if let last = segs.last, last.text == text { continue }
            segs.append(Segment(fromMs: from + offsetMs, toMs: to + offsetMs, text: text, who: who))
        }
        closeRun()
        return (segs, loops, rawTotal > 0 ? Double(rawDup) / Double(rawTotal) : 0)
    }

    /// 整片品質檢查：重複、缺標點、「某某:」前綴 latch
    public static func degeneracy(_ segs: [Segment], rawRepeatRatio: Double = 0) -> (bad: Bool, score: Double) {
        guard segs.count >= 8 else { return (false, 1) }
        let texts = segs.map { $0.text }
        let all = texts.joined()
        guard all.count > 200 else { return (false, 1) }
        let punct = all.filter { "，。？！、,.?!".contains($0) }.count
        let punctRatio = Double(punct) / Double(all.count)
        var prefixes: [String: Int] = [:]
        for t in texts {
            guard let idx = t.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let p = String(t[t.startIndex..<idx])
            if p.count >= 1, p.count <= 8 { prefixes[p, default: 0] += 1 }
        }
        let latchRatio = Double(prefixes.values.max() ?? 0) / Double(texts.count)
        let bad = rawRepeatRatio > 0.25 || punctRatio < 0.02 || latchRatio > 0.3
        return (bad, punctRatio - rawRepeatRatio - latchRatio)
    }

    private func runWhisper(cli: String, model: String, wav: URL, jsonBase: URL, extra: [String], env: [String: String], timeout: TimeInterval) -> RunResult {
        runProcess(
            cli,
            ["-m", model, "-f", wav.path, "-l", "zh", "-t", "\(WhisperEngine.perfCores)",
             "--prompt", Self.prompt, "--carry-initial-prompt", "-oj", "-of", jsonBase.path, "-np"] + extra,
            env: env, timeout: timeout)
    }

    private func repairLoops(
        segs: [Segment], loops: [(Int, Int)], sliceFrom: Int, sliceTo: Int, wav: URL, who: String,
        name: String, label: String, workDir: URL, sliceDir: URL, cli: String, model: String, env: [String: String]
    ) -> ([Segment], Int) {
        var out = segs
        var fixed = 0
        var giveUps: [(Int, Int)] = []
        var merged: [(Int, Int)] = []
        for l in loops.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, l.0 - last.1 < 10_000 { merged[merged.count - 1].1 = max(last.1, l.1) } else { merged.append(l) }
        }
        for (k, (ls, le)) in merged.enumerated() {
            if k >= 4 { giveUps.append((ls, le)); continue }
            var a = max(sliceFrom, ls - 3000)
            var b = min(sliceTo, le + 3000)
            let overlapping = out.filter { $0.toMs > a && $0.fromMs < b }
            if let lo = overlapping.map({ $0.fromMs }).min() { a = max(sliceFrom, min(a, lo)) }
            if let hi = overlapping.map({ $0.toMs }).max() { b = min(sliceTo, max(b, hi)) }
            guard b - a >= 5000 else { continue }
            let winLv = WavIO.blockLevels(WavIO.readPCM(wav, fromMs: a, toMs: b))
            if (winLv.max() ?? 0) < Self.sliceSilence {
                out.removeAll { $0.toMs > a && $0.fromMs < b }
                fixed += 1
                continue
            }
            let fixName = String(format: "%@-fix%d", name, k)
            let fixJSON = workDir.appendingPathComponent(fixName + ".json")
            var result: (segs: [Segment], loops: [(Int, Int)], rawRepeat: Double)? =
                FileManager.default.fileExists(atPath: fixJSON.path) ? (try? Self.parseWhisperJSON(fixJSON, offsetMs: a, who: who)) : nil
            if result == nil {
                let fixWav = sliceDir.appendingPathComponent(fixName + ".wav")
                guard WavIO.writeSlice(from: wav, fromMs: a, toMs: b, to: fixWav) else { giveUps.append((ls, le)); continue }
                var best: (segs: [Segment], loops: [(Int, Int)], rawRepeat: Double)? = nil
                var bestResidue = Int.max
                for pass in 0..<2 {
                    _ = runWhisper(cli: cli, model: model, wav: fixWav, jsonBase: fixJSON.deletingPathExtension(),
                                   extra: pass == 1 ? ["-mc", "16"] : [], env: env, timeout: max(120, Double(b - a) / 1000 * 4))
                    guard let r = try? Self.parseWhisperJSON(fixJSON, offsetMs: a, who: who) else { break }
                    let residue = r.loops.reduce(0) { $0 + ($1.1 - $1.0) }
                    if residue < bestResidue { bestResidue = residue; best = r }
                    if residue < 8000 { break }
                    try? FileManager.default.removeItem(at: fixJSON)
                }
                result = best
                if bestResidue >= 8000 { giveUps.append((ls, le)) }
                if best == nil { try? FileManager.default.removeItem(at: fixJSON) }
                try? FileManager.default.removeItem(at: fixWav)
            }
            guard let r = result, !r.segs.isEmpty else { giveUps.append((ls, le)); continue }
            out.removeAll { $0.toMs > a && $0.fromMs < b }
            out += r.segs
            fixed += 1
        }
        if !giveUps.isEmpty {
            let spans = giveUps.prefix(3).map { "\(Fmt.ts($0.0))–\(Fmt.ts($0.1))" }.joined(separator: "、")
            let more = giveUps.count > 3 ? "等 \(giveUps.count) 處" : ""
            notes.append("\(label)音軌 \(spans)\(more) 語音辨識出現重複迴圈、自動重轉未能完全修復，這幾段可能不完整")
        }
        out.sort { $0.fromMs < $1.fromMs }
        return (out, fixed)
    }

    /// 轉寫一軌。空檔／讀不到＝回空陣列＋備註，不 throw。
    /// cuts＝一定要切開的位置（毫秒；中途暫停的地方），見 planSlices
    public func transcribe(wav: URL, who: String, label: String, workDir: URL, track: String, cuts: [Int] = [], onPartial: (([Segment]) -> Void)? = nil) throws -> [Segment] {
        guard let cli = WhisperEngine.cliPath() else { throw HearbyError("找不到 whisper-cli（app 內應自帶；開發機請跑 scripts/vendor-fetch.sh）") }
        guard let modelURL = SharedPaths.installedModel() else { throw HearbyError("找不到聽打模型（\(SharedPaths.whisperModelFile)）") }
        let model = modelURL.path
        guard let totalMs = WavIO.durationMs(of: wav), totalMs > 0 else {
            notes.append("\(label)音軌沒有錄到任何內容（檔案是空的），這份紀錄不含這一軌")
            return []
        }
        HearbyLog.write("transcribe start \(track) \(totalMs / 60000)min")
        let env = WhisperEngine.env(forCLI: cli)
        let target = usedMetal == false ? 5 * 60_000 : Self.sliceTargetMs
        let slices = Self.planSlices(wav: wav, totalMs: totalMs, targetMs: target, forcedCuts: cuts)
        let sliceDir = workDir.appendingPathComponent("slices")
        try? FileManager.default.createDirectory(at: sliceDir, withIntermediateDirectories: true)
        var segs: [Segment] = []
        var failed: [(Int, Int)] = []
        var skipped = 0
        var quietSpans: [(Int, Int)] = []
        var boostedSpans: [(Int, Int)] = []
        var loopFixes = 0
        var degenFixes = 0
        var degenLeft: [(Int, Int)] = []
        var ranMs = 0
        var ranSecs: TimeInterval = 0
        let partial = workDir.appendingPathComponent("transcript.partial-\(track).md")

        for (i, (a, b)) in slices.enumerated() {
            // 有暫停切點時片名帶起點秒數：切法不同的舊 JSON（續跑用的快取）不會被誤拿來用
            let name = String(format: "%@-w%02d", track, i) + (cuts.isEmpty ? "" : "-\(a / 1000)s")
            let jsonURL = workDir.appendingPathComponent(name + ".json")
            let speed = (ranMs > 0 && ranSecs > 0) ? Double(ranMs) / ranSecs : (usedMetal == false ? 700.0 : 15000.0)
            let remainMs = slices[i...].reduce(0) { $0 + ($1.1 - $1.0) }
            let eta = "・約剩 \(Fmt.dur(Double(remainMs) / speed))"
            let cpuNote = usedMetal == false ? "（本機以 CPU 轉寫，較慢）" : ""
            stage(slices.count > 1 ? "聽打\(label) \(i + 1)/\(slices.count)\(eta)\(cpuNote)" : "聽打\(label)…\(cpuNote)")

            var parsed: (segs: [Segment], loops: [(Int, Int)], rawRepeat: Double)? = nil
            if FileManager.default.fileExists(atPath: jsonURL.path) { parsed = try? Self.parseWhisperJSON(jsonURL, offsetMs: a, who: who) }
            let silentFlag = workDir.appendingPathComponent(name + ".silent")
            if parsed == nil, FileManager.default.fileExists(atPath: silentFlag.path) { skipped += 1; continue }
            let boostFlag = workDir.appendingPathComponent(name + ".boosted")
            if parsed == nil {
                let pcm = WavIO.readPCM(wav, fromMs: a, toMs: b)
                let lv = WavIO.blockLevels(pcm)
                let peak = lv.max() ?? 0
                var gain: Float? = nil
                if peak < Self.sliceSilence {
                    gain = Self.quietBoost(levels: lv, pcm: pcm)
                    if gain == nil {
                        skipped += 1
                        if peak > Self.quietFloor { quietSpans.append((a, b)) }
                        try? "silent".write(to: silentFlag, atomically: true, encoding: .utf8)
                        continue
                    }
                }
                let sliceURL = sliceDir.appendingPathComponent(name + ".wav")
                if let g = gain {
                    // 小聲片：放大後聽打，不再整片丟掉（理由與實測見 quietBoost）
                    guard WavIO.writePCM(pcm, gain: g, to: sliceURL) else { failed.append((a, b)); continue }
                    try? "boosted".write(to: boostFlag, atomically: true, encoding: .utf8)
                    HearbyLog.write(String(format: "quiet boost %@ level=%.4f gain=%.0fx", name, peak, g))
                } else {
                    guard WavIO.writeSlice(from: wav, fromMs: a, toMs: b, to: sliceURL) else { failed.append((a, b)); continue }
                }
                // 用 systemUptime 計時：電腦睡著時它不走，ran= 與「約剩」才是真的算力時間（Date() 會把闔蓋睡掉的 25 分鐘算進去，看起來像聽打很慢）
                let t0 = ProcessInfo.processInfo.systemUptime
                for attempt in 1...2 {
                    let r = runWhisper(cli: cli, model: model, wav: sliceURL, jsonBase: jsonURL.deletingPathExtension(), extra: [], env: env, timeout: max(600, Double(b - a) / 1000 * 4))
                    if usedMetal == nil {
                        usedMetal = r.stderr.contains("ggml_metal_device_init")
                        HearbyLog.write("whisper metal=\(usedMetal == true)")
                    }
                    if FileManager.default.fileExists(atPath: jsonURL.path), let p = try? Self.parseWhisperJSON(jsonURL, offsetMs: a, who: who) { parsed = p; break }
                    try? FileManager.default.removeItem(at: jsonURL)
                    HearbyLog.write("whisper \(name) attempt \(attempt) fail (\(r.status)): \(String(r.stderr.suffix(200)))")
                }
                try? FileManager.default.removeItem(at: sliceURL)
                ranSecs += ProcessInfo.processInfo.systemUptime - t0
                ranMs += (b - a)
                guard parsed != nil else { failed.append((a, b)); continue }
            }
            // 放大聽打的片（旗標檔讓中斷重跑也認得）：濾完幻聽一句不剩＝還是太小聲，照舊記
            let boosted = FileManager.default.fileExists(atPath: boostFlag.path)
            if boosted {
                if parsed?.segs.isEmpty ?? true { skipped += 1; quietSpans.append((a, b)); continue }
                boostedSpans.append((a, b))
            }
            var sliceSegs = parsed?.segs ?? []
            let deg = Self.degeneracy(sliceSegs, rawRepeatRatio: parsed?.rawRepeat ?? 0)
            if deg.bad, !sliceSegs.isEmpty {
                let retryJSON = workDir.appendingPathComponent(name + "-r.json")
                var retry: (segs: [Segment], loops: [(Int, Int)], rawRepeat: Double)? =
                    FileManager.default.fileExists(atPath: retryJSON.path) ? try? Self.parseWhisperJSON(retryJSON, offsetMs: a, who: who) : nil
                if retry == nil {
                    let sliceURL = sliceDir.appendingPathComponent(name + "-r.wav")
                    var wrote = false
                    if boosted {
                        let pcm = WavIO.readPCM(wav, fromMs: a, toMs: b)
                        if let g = Self.quietBoost(levels: WavIO.blockLevels(pcm), pcm: pcm) { wrote = WavIO.writePCM(pcm, gain: g, to: sliceURL) }
                    } else {
                        wrote = WavIO.writeSlice(from: wav, fromMs: a, toMs: b, to: sliceURL)
                    }
                    if wrote {
                        HearbyLog.write(String(format: "degen retry %@ score=%.3f", name, deg.score))
                        _ = runWhisper(cli: cli, model: model, wav: sliceURL, jsonBase: retryJSON.deletingPathExtension(), extra: ["-mc", "16"], env: env, timeout: max(600, Double(b - a) / 1000 * 4))
                        retry = try? Self.parseWhisperJSON(retryJSON, offsetMs: a, who: who)
                        try? FileManager.default.removeItem(at: sliceURL)
                    }
                }
                if let r = retry, !r.segs.isEmpty, Self.degeneracy(r.segs, rawRepeatRatio: r.rawRepeat).score > deg.score {
                    parsed = r; sliceSegs = r.segs; degenFixes += 1
                } else { degenLeft.append((a, b)) }
            }
            if let loops = parsed?.loops, !loops.isEmpty {
                let (fixedSegs, n) = repairLoops(segs: sliceSegs, loops: loops, sliceFrom: a, sliceTo: b, wav: wav, who: who, name: name, label: label, workDir: workDir, sliceDir: sliceDir, cli: cli, model: model, env: env)
                sliceSegs = fixedSegs
                loopFixes += n
            }
            for s in sliceSegs {
                if let last = segs.last, last.text == s.text { continue }
                segs.append(s)
            }
            try? segs.map { "- [\(Fmt.ts($0.fromMs))] \($0.text)" }.joined(separator: "\n").write(to: partial, atomically: true, encoding: .utf8)
            onPartial?(segs)
        }
        try? FileManager.default.removeItem(at: sliceDir)

        let attempted = slices.count - skipped
        if attempted > 0, failed.count == attempted {
            throw HearbyError("聽打失敗（\(label) \(attempted) 片全部失敗，請重試）")
        }
        if !failed.isEmpty {
            let spans = failed.prefix(3).map { "\(Fmt.ts($0.0))–\(Fmt.ts($0.1))" }.joined(separator: "、")
            notes.append("\(label)音軌 \(spans)\(failed.count > 3 ? "等 \(failed.count) 段" : "") 聽打失敗、內容缺（原始錄音仍在，可用「匯入音檔」重跑）")
        }
        if !quietSpans.isEmpty {
            let spans = quietSpans.prefix(3).map { "\(Fmt.ts($0.0))–\(Fmt.ts($0.1))" }.joined(separator: "、")
            notes.append("\(label)音軌 \(spans)\(quietSpans.count > 3 ? "等 \(quietSpans.count) 段" : "") 音量太小，未聽打")
        }
        if !boostedSpans.isEmpty {
            let spans = boostedSpans.prefix(3).map { "\(Fmt.ts($0.0))–\(Fmt.ts($0.1))" }.joined(separator: "、")
            notes.append("\(label)音軌 \(spans)\(boostedSpans.count > 3 ? "等 \(boostedSpans.count) 段" : "") 音量很小，已放大後聽打，這幾段可能比較不準")
        }
        if !degenLeft.isEmpty {
            let spans = degenLeft.prefix(2).map { "\(Fmt.ts($0.0))–\(Fmt.ts($0.1))" }.joined(separator: "、")
            notes.append("\(label)音軌 \(spans) 附近語音辨識品質異常（重複或缺標點），內容可能不完整")
        }
        if usedMetal == false, !notes.contains(where: { $0.contains("CPU") }) { notes.append("本機聽打未使用 GPU 加速（以 CPU 進行，時間較長）") }
        HearbyLog.write("transcribe done \(track) \(slices.count)片 skip=\(skipped) fail=\(failed.count) loopfix=\(loopFixes) degen=\(degenFixes) ran=\(Int(ranSecs))s/\(ranMs / 1000)s metal=\(usedMetal == true)")
        return segs
    }

    // MARK: 迴聲去重（開喇叭：遠端每句話經喇叭再進 mic 一次）
    public static func bigrams(_ s: String) -> Set<String> {
        let c = Array(s.filter { $0.isLetter || $0.isNumber })
        guard c.count >= 2 else { return c.isEmpty ? [] : [String(c)] }
        var g = Set<String>()
        for i in 0..<(c.count - 1) { g.insert(String(c[i...(i + 1)])) }
        return g
    }
    public static func bigramContainment(_ a: String, _ b: String) -> Double {
        let ga = bigrams(a), gb = bigrams(b)
        guard !ga.isEmpty, !gb.isEmpty else { return 0 }
        return Double(ga.intersection(gb).count) / Double(ga.count)
    }
    public static func remoteTextAround(_ sysSegs: [Segment], _ s: Segment) -> String {
        sysSegs.filter { $0.toMs >= s.fromMs - 8000 && $0.fromMs <= s.toMs + 8000 }.map { $0.text }.joined()
    }

    /// 逐字稿餵模型前的分塊合併：連續同講者行併到 ~220 字/塊
    public static func mergedForLLM(_ transcript: String) -> String {
        struct Chunk { let ts: String; let who: String; var text: String; var marker = false }
        var chunks: [Chunk] = []
        for line in transcript.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            // 暫停標記原樣留在原位（不併進前後的發言）：模型要知道那裡斷過，重新整理全篇後紀錄上也還看得到
            if PauseSpan.isMarker(l) { chunks.append(Chunk(ts: "", who: "", text: l, marker: true)); continue }
            guard l.hasPrefix("- ["), let tsEnd = l.range(of: "]["), let whoEnd = l.range(of: "] ", range: tsEnd.upperBound..<l.endIndex) else { continue }
            let ts = String(l[l.index(l.startIndex, offsetBy: 3)..<tsEnd.lowerBound])
            let who = String(l[tsEnd.upperBound..<whoEnd.lowerBound])
            let text = String(l[whoEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if var last = chunks.last, !last.marker, last.who == who, last.text.count + text.count <= 220 {
                last.text += " " + text
                chunks[chunks.count - 1] = last
            } else { chunks.append(Chunk(ts: ts, who: who, text: text)) }
        }
        guard chunks.contains(where: { !$0.marker }) else { return transcript }
        return chunks.map { $0.marker ? $0.text : "- [\($0.ts)][\($0.who)] \($0.text)" }.joined(separator: "\n")
    }
}
