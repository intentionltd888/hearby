// Pause — 錄音中途暫停：時間帳（扣掉睡眠與暫停）＋逐字稿上的暫停標記。純邏輯、時間由外面給，測試直接叫
//
// 暫停＝裝置照開、只是不寫檔（見 DualRecorder.shouldWrite）：繼續是即時的，不必重接音訊裝置。
// 音檔裡只有錄到的部分，所以逐字稿的時間戳是「錄到的時間」；暫停在哪、停了多久，靠這裡記下的位置補回紀錄上。
import Foundation

/// 一段暫停：在錄到的音檔裡的位置（秒）＋牆上的起訖時間
public struct PauseSpan: Codable, Equatable {
    public var atSeconds: Double
    public var began: Date
    public var ended: Date?
    public init(atSeconds: Double, began: Date, ended: Date? = nil) {
        self.atSeconds = atSeconds; self.began = began; self.ended = ended
    }
    /// 停了幾秒（還沒結束＝nil）
    public var seconds: Double? { ended.map { max(0, $0.timeIntervalSince(began)) } }
    /// 在音檔裡的位置（毫秒）。聽打的切點與逐字稿的標記都用這一個整數，兩邊才會對得上
    public var atMs: Int { Int(Fmt.clampSeconds(atSeconds) * 1000) }
}

/// 錄音的時間帳。暫停中睡著不另外記：那段本來就不錄，兩邊都扣會把時長扣掉兩次
public struct RecordingClock: Equatable {
    public private(set) var startedAt: Date
    public private(set) var sleepSeconds: TimeInterval = 0
    public private(set) var pausedSeconds: TimeInterval = 0
    public private(set) var pauses: [PauseSpan] = []
    public private(set) var sleptWhileRecording = false
    private var sleepBegan: Date?
    private var pauseBegan: Date?

    public init(startedAt: Date) { self.startedAt = startedAt }

    public var isPaused: Bool { pauseBegan != nil }

    /// 真的有錄到的秒數（扣掉睡眠與暫停，含進行中的那段）
    public func recorded(at now: Date) -> TimeInterval {
        let sleeping = sleepBegan.map { now.timeIntervalSince($0) } ?? 0
        let pausing = pauseBegan.map { now.timeIntervalSince($0) } ?? 0
        return max(0, now.timeIntervalSince(startedAt) - sleepSeconds - sleeping - pausedSeconds - pausing)
    }

    /// 這一次暫停了多久（沒在暫停＝0）
    public func currentPause(at now: Date) -> TimeInterval { pauseBegan.map { max(0, now.timeIntervalSince($0)) } ?? 0 }

    @discardableResult public mutating func pause(at now: Date) -> Bool {
        guard pauseBegan == nil else { return false }
        closeSleep(at: now)
        pauses.append(PauseSpan(atSeconds: recorded(at: now), began: now))
        pauseBegan = now
        return true
    }

    @discardableResult public mutating func resume(at now: Date) -> Bool {
        guard let b = pauseBegan else { return false }
        pausedSeconds += max(0, now.timeIntervalSince(b))
        pauseBegan = nil
        pauses[pauses.count - 1].ended = now
        return true
    }

    /// 暫停中睡著不記（回 false）
    @discardableResult public mutating func noteSleep(at now: Date) -> Bool {
        guard sleepBegan == nil, pauseBegan == nil else { return false }
        sleepBegan = now
        return true
    }

    /// 回 true＝剛結掉一段「錄音中」的睡眠（要跟使用者說那段沒聲音）
    @discardableResult public mutating func noteWake(at now: Date) -> Bool { closeSleep(at: now) }

    /// 停止：結掉進行中的睡眠與暫停
    public mutating func close(at now: Date) {
        closeSleep(at: now)
        resume(at: now)
    }

    @discardableResult private mutating func closeSleep(at now: Date) -> Bool {
        guard let b = sleepBegan else { return false }
        sleepSeconds += max(0, now.timeIntervalSince(b))
        sleepBegan = nil
        sleptWhileRecording = true
        return true
    }
}

// MARK: - 紀錄上的暫停標記

public extension PauseSpan {
    /// 逐字稿裡的暫停標記行開頭（不是「- [時間][誰]」格式：不算發言，解析發言的地方都會略過或原樣保留）
    static let markerPrefix = "（⏸ "

    static func isMarker(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("（⏸")
    }

    /// 中途的暫停＝之後還有錄到東西。按了暫停就直接停止的那一段不算，當機時還開著的那段也不算
    static func midPauses(_ pauses: [PauseSpan], totalSeconds: Double) -> [PauseSpan] {
        pauses.filter { $0.ended != nil && $0.atSeconds < totalSeconds - 1 }.sorted { $0.atSeconds < $1.atSeconds }
    }

    /// 40 秒／12 分鐘／1 小時 5 分鐘
    static func durText(_ seconds: Double) -> String {
        let t = Int(Fmt.clampSeconds(seconds).rounded())
        if t < 60 { return "\(t) 秒" }
        if t < 3600 { return "\(max(1, Int((Double(t) / 60).rounded()))) 分鐘" }
        let h = t / 3600, m = (t % 3600) / 60
        return m == 0 ? "\(h) 小時" : "\(h) 小時 \(m) 分鐘"
    }

    /// 牆上時間 HH:mm（固定西曆與 POSIX：系統設成民國曆或 12 小時制時也一樣）
    static func clock(_ d: Date) -> String { clockFormatter.string(from: d) }
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "HH:mm"
        return f
    }()

    /// 「（⏸ 14:32–14:44 暫停了 12 分鐘，這段沒有錄）」
    var markerLine: String {
        let from = Self.clock(began)
        let to = ended.map { Self.clock($0) } ?? from
        let when = from == to ? from : "\(from)–\(to)"
        return "\(Self.markerPrefix)\(when) 暫停了 \(Self.durText(seconds ?? 0))，這段沒有錄）"
    }

    /// 把暫停標記插進逐字稿：lines 依時間排好（起點毫秒, 那一行），標記放在暫停之後第一句的前面
    static func weave(_ lines: [(fromMs: Int, text: String)], pauses: [PauseSpan], totalSeconds: Double) -> [String] {
        let mids = midPauses(pauses, totalSeconds: totalSeconds)
        var out: [String] = []
        out.reserveCapacity(lines.count + mids.count)
        var k = 0
        for l in lines {
            while k < mids.count, l.fromMs >= mids[k].atMs { out.append(mids[k].markerLine); k += 1 }
            out.append(l.text)
        }
        while k < mids.count { out.append(mids[k].markerLine); k += 1 }
        return out
    }

    /// 紀錄表頭那一行（沒有中途暫停＝nil）
    static func note(_ pauses: [PauseSpan], totalSeconds: Double) -> String? {
        let mids = midPauses(pauses, totalSeconds: totalSeconds)
        guard !mids.isEmpty else { return nil }
        let total = mids.reduce(0) { $0 + ($1.seconds ?? 0) }
        return "中途暫停 \(mids.count) 次，共 \(durText(total))（暫停時沒有錄音，逐字稿裡標了位置）"
    }
}
