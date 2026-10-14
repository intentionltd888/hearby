// Taigi — 國台混講：主模型沒把握的地方剪出來，再交給台語模型聽一次；台語模型比較有把握才換成它的字
//
// 台語模型＝聯發創新基地 Breeze-ASR-26（Whisper large-v2 用約一萬小時台語語音微調，Apache-2.0）。
// 它把台語聽成「華語用字」（不是台文），所以換進來的字跟其他行一樣能被整理、搜尋。
//
// 為什麼不整場換台語模型：它在國語上錯很多（行政院國台語平行廣告實測：國語字錯率 3% → 25%），英文會被翻成中文。
// 為什麼不靠 whisper 自己判斷語言：whisper 沒有台語的語言代碼，台語會被當成 zh 硬聽成國語（「解決糾紛」→「改革求婚」）。
// 判斷依據＝兩顆模型各自對這段字有多確定（whisper -ojf 每個字的機率取 log 平均）：
//   主模型（turbo）聽國語時多半很確定（中位數 −0.13），聽台語時明顯沒把握（中位數 −0.61）。
// 送哪些地方：主模型沒把握的段落，加上「有人聲但主模型沒出字」的空檔——turbo 聽不懂時會整段跳過（實測一次跳 25 秒）。
// 怎麼送：台語模型不切時間戳（每 30 秒只吐一段字），所以每一截各存一個小檔、一次呼叫 whisper-cli（每個 -f 配一個 -of，
//   模型只載入一次），每截的字各自對回那一截。整場再聽一遍要多花六成時間；只送這些地方，實測多花約兩成。
// 實測數字與選型見 docs/taigi.md；重跑：scripts/taigi/bench.py。

import Foundation

public enum Taigi {
    /// 台語模型檔（下載到 Hearby 的模型資料夾；跟聽打模型同一套搜尋路徑）
    public static var modelURL: URL? { SharedPaths.installedModel(ModelCatalog.taigi.file) }
    /// 設定打開而且模型在
    public static var enabled: Bool { ConfigStore.shared.current.taigiEnabled && modelURL != nil }

    /// 一段字的把握：平均 log 機率（只算文字，不算時間戳等特殊記號）
    public struct Score: Equatable {
        public let logp: Double
        public let tokens: Int
        public init(logp: Double, tokens: Int) { self.logp = logp; self.tokens = tokens }
    }

    /// 讀 whisper `-ojf` 的 JSON：每段的把握，key＝`fromMs-toMs`（加過 offset，跟 parseWhisperJSON 出來的段落對得上）。
    /// 沒有 tokens 欄（不是 -ojf 跑的、舊的續跑快取）＝空表，那些段落當成主模型有把握。
    public static func scores(_ url: URL, offsetMs: Int) -> [String: Score] {
        guard let raw = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: Data(String(decoding: raw, as: UTF8.self).utf8)) as? [String: Any],
            let trans = obj["transcription"] as? [[String: Any]]
        else { return [:] }
        var out: [String: Score] = [:]
        var lastTo = 0
        for t in trans {
            let offsets = t["offsets"] as? [String: Any]
            let from = (offsets?["from"] as? Int) ?? lastTo
            let to = (offsets?["to"] as? Int) ?? from
            lastTo = max(lastTo, to)
            guard let toks = t["tokens"] as? [[String: Any]] else { continue }
            var sum = 0.0, n = 0
            for k in toks {
                guard let p = k["p"] as? Double, let text = k["text"] as? String, !text.hasPrefix("[_") else { continue }
                sum += log(max(p, 1e-6)); n += 1
            }
            if n > 0 { out[key(from + offsetMs, to + offsetMs)] = Score(logp: sum / Double(n), tokens: n) }
        }
        return out
    }

    static func key(_ from: Int, _ to: Int) -> String { "\(from)-\(to)" }
    static func key(_ s: Segment) -> String { key(s.fromMs, s.toMs) }

    /// 判定參數。數字從行政院國台語平行廣告組成的混講測試帶量出來（scripts/taigi/bench.py report）
    public struct Rule {
        /// 主模型平均 log 機率低於這個＝沒把握，送台語模型
        public var low: Double
        /// 台語模型要比主模型高出這麼多才換
        public var margin: Double
        /// 主模型整截沒字（跳過的空檔）：台語模型把握高於這個才補進來；nil＝不補
        public var fillIn: Double?
        /// 主模型漏聽：段落時間蓋到了、字卻只有一句（turbo 一段 16 秒只寫 30 字，其餘跳過）。
        /// 台語模型的字數 ≥ 主模型的這個倍數＋10 字、而且把握過 fillIn 那條線，也換。nil＝不看
        public var skipRatio: Double?
        public init(low: Double, margin: Double, fillIn: Double? = -0.5, skipRatio: Double? = 1.5) {
            self.low = low; self.margin = margin; self.fillIn = fillIn; self.skipRatio = skipRatio
        }
    }
    /// margin 0.1 與 0.2 在混講測試帶上結果一樣；取 0.2，真實的純國語會議裡少換一些
    public static var rule = Rule(low: -0.3, margin: 0.2)

    /// 「有人聲」：100 ms 一格的音量超過這條線（跟 Transcriber.sliceSilence 同一條）的格數達三成
    public static let voiceLevel: Float = 0.015

    // MARK: 送哪些地方

    /// 要送台語模型的範圍（原時間軸，毫秒）：主模型沒把握的段落＋有人聲但主模型沒出字的空檔（至少 2 秒），
    /// 間隔不到 1.5 秒的併起來、前後各墊 0.2 秒、每截至少 1.5 秒，夾在這一片 [lo, hi) 裡。
    /// levels＝這一片從 lo 起每 100 ms 的音量（WavIO.blockLevels）；空陣列＝不找空檔。
    public static func spans(_ segs: [Segment], scores: [String: Score], levels: [Float], from lo: Int, to hi: Int, rule: Rule = rule) -> [(Int, Int)] {
        let pad = 200, join = 1500, minLen = 1500, minGap = 2000
        var raw: [(Int, Int)] = segs.filter { (scores[key($0)]?.logp ?? 0) < rule.low }.map { ($0.fromMs, $0.toMs) }
        if !levels.isEmpty {
            var edge = lo
            for s in segs.sorted(by: { $0.fromMs < $1.fromMs }) + [Segment(fromMs: hi, toMs: hi, text: "", who: "")] {
                if s.fromMs - edge >= minGap, voiced(levels, from: edge - lo, to: s.fromMs - lo) { raw.append((edge, s.fromMs)) }
                edge = max(edge, s.toMs)
            }
        }
        var merged: [(Int, Int)] = []
        for (f, t) in raw.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, f - last.1 < join { merged[merged.count - 1].1 = max(last.1, t) } else { merged.append((f, t)) }
        }
        var out: [(Int, Int)] = []
        for (f0, t0) in merged {
            var f = max(lo, f0 - pad), t = min(hi, t0 + pad)
            if t - f < minLen { let c = (f + t) / 2; f = max(lo, c - minLen / 2); t = min(hi, c + minLen / 2) }
            guard t > f else { continue }
            if let last = out.last, f <= last.1 { out[out.count - 1].1 = max(last.1, t) } else { out.append((f, t)) }
        }
        return out
    }

    static func voiced(_ levels: [Float], from: Int, to: Int) -> Bool {
        let a = max(0, from / 100), b = min(levels.count, to / 100)
        guard b > a else { return false }
        return Double(levels[a..<b].filter { $0 > voiceLevel }.count) >= 0.3 * Double(b - a)
    }

    // MARK: 換字

    /// 台語模型用空格斷句、不加標點：中文字之間的空格換成「，」，跟其他行一樣好讀。
    /// 先拿掉它在換氣、停頓處吐的「惜」「惜惜（喔）」——單獨成一句的才拿（真實國語會議實測一場十幾次）
    public static func punctuate(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.range(of: #"^惜+[喔哦啊]?$"#, options: .regularExpression) == nil }
            .joined(separator: " ")
            .replacingOccurrences(of: #"(?<=[\x{4E00}-\x{9FFF}])\s+(?=[\x{4E00}-\x{9FFF}])"#, with: "，", options: .regularExpression)
    }

    /// 一截的台語模型結果（段落與分數都已對回原時間軸）
    public struct SpanResult {
        public let from: Int, to: Int
        public let segs: [Segment]
        public let scores: [String: Score]
        public init(from: Int, to: Int, segs: [Segment], scores: [String: Score]) { self.from = from; self.to = to; self.segs = segs; self.scores = scores }
    }

    public struct Merged: Equatable {
        public var segs: [Segment]
        /// 換成（或補上）台語模型的字的時間（毫秒）與截數
        public var switchedMs: Int
        public var switched: Int
    }

    static func chars(_ segs: [Segment]) -> Int { segs.reduce(0) { $0 + $1.text.filter { $0.isLetter || $0.isNumber }.count } }

    /// 每一截：主模型在截內（段落中點落在截裡）的段落 vs 台語模型這一截的字。
    /// 主模型沒把握、台語模型高出 margin → 整截換；主模型漏聽（字數少很多）→ 換；
    /// 主模型這截沒字（跳過的空檔）→ 台語模型把握夠才補。
    /// 沒有分數的段落：主模型那邊當成有把握（迴圈修補換進來的段落），台語模型那邊當成沒把握。
    public static func merge(primary: [Segment], primaryScores: [String: Score], results: [SpanResult], rule: Rule = rule) -> Merged {
        var drop = Set<Int>(), add: [Segment] = []
        var switchedMs = 0, switched = 0
        func conf(_ segs: [Segment], _ sc: [String: Score], missing: Double) -> Double {
            var sum = 0.0, n = 0
            for s in segs { if let v = sc[key(s)] { sum += v.logp * Double(v.tokens); n += v.tokens } else { sum += missing; n += 1 } }
            return n > 0 ? sum / Double(n) : missing
        }
        for r in results where !r.segs.isEmpty {
            let inside = primary.indices.filter { let m = (primary[$0].fromMs + primary[$0].toMs) / 2; return m >= r.from && m < r.to }
            let ct = conf(r.segs, r.scores, missing: -9)
            let take: Bool
            if inside.isEmpty {
                take = rule.fillIn.map { ct > $0 } ?? false
            } else {
                let cp = conf(inside.map { primary[$0] }, primaryScores, missing: 0)
                let skipped = rule.skipRatio.map { ratio in
                    ct > (rule.fillIn ?? 0) && Double(chars(r.segs)) >= ratio * Double(chars(inside.map { primary[$0] })) + 10
                } ?? false
                take = (cp < rule.low && ct >= cp + rule.margin) || skipped
            }
            guard take else { continue }
            let who = inside.first.map { primary[$0].who } ?? r.segs[0].who   // 講者沿用主模型那一軌
            drop.formUnion(inside)
            add += r.segs.map { Segment(fromMs: $0.fromMs, toMs: $0.toMs, text: $0.text, who: who) }
            switched += 1; switchedMs += r.to - r.from
        }
        let out = (primary.indices.filter { !drop.contains($0) }.map { primary[$0] } + add).sorted { $0.fromMs < $1.fromMs }
        return Merged(segs: out, switchedMs: switchedMs, switched: switched)
    }
}
