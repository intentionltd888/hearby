// Voices — 認聲音（實驗，只有 macOS 版）：這台 Mac 記得的聲紋，與一場錄音裡的聲音怎麼對到名字
//
// 守則：聲紋只在本人同意後才記（記的時候寫下誰、哪天同意），只存在 Hearby 支援資料夾的 voices.json（不進紀錄資料夾、不進記憶、
// 不上傳）；「忘記」＝整筆拿掉、不留備份。一場會的分段結果（每個聲音的聲紋）只在記憶體裡用完就丟——沒同意的人的聲紋不留。
// 說話人分段與聲紋由 HearbyVoice（FluidAudio）算，App 開起來時接到 Voices.engine；這個檔只管存、比、標（沒有第三方套件，測得到）。
// 整理時：交給 AI 的逐字稿，who 標籤後面加「·名字」（認得的）或「·聲音A」（沒認出、同一個代號＝同一個人），規則見 promptRule；
// 紀錄表頭寫一行「> 聲紋：…」；存下來的逐字稿一個字都不動。macOS 15 以上才開（14 的 Core ML 有會當掉的已知問題）。
// 分軌：錄音的工作夾還在（30 天內）就把麥克風（mic）與電腦聲音（system）分開切——混好的 m4a 會把遠端的人連同喇叭回音切成兩個聲音，
// 遠端兩個人也比較難分。同一個人在不同軌（混音、麥克風、電腦聲音）的聲紋互比只有 0.38–0.52，所以聲紋記下是哪一軌、只跟同一軌比；
// 一個人可以有好幾筆（現場一筆、遠端一筆）。
import Foundation

public enum Voices {
    /// 記住的一個人
    public struct Print: Codable, Equatable {
        public var name: String
        /// 聲紋（L2 正規化）
        public var vector: [Float]
        /// 累計用了多少秒的聲音
        public var seconds: Double
        /// 從哪幾場取的（會議資料夾名）
        public var sources: [String]
        /// 「2026-09-30 本人同意」
        public var consent: String
        /// 哪個模型算的（換模型要重記）
        public var model: String
        /// 哪一軌錄的（mic／system／mix）：只跟同一軌的聲音比
        public var track: String
        public init(name: String, vector: [Float], seconds: Double, sources: [String], consent: String, model: String, track: String = "mix") {
            self.name = name; self.vector = vector; self.seconds = seconds; self.sources = sources; self.consent = consent; self.model = model; self.track = track
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            vector = try c.decode([Float].self, forKey: .vector)
            seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
            sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
            consent = try c.decodeIfPresent(String.self, forKey: .consent) ?? ""
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
            track = try c.decodeIfPresent(String.self, forKey: .track) ?? "mix"
        }
    }

    struct Store: Codable {
        var version = 1
        var people: [Print] = []
    }

    /// 一場錄音裡的一個聲音（只在記憶體）
    public struct Cluster: Equatable {
        public var id: String
        public var vector: [Float]
        public var seconds: Double
        /// 講話的時間段（秒，從錄音開頭算）
        public var spans: [ClosedRange<Double>]
        /// 哪一軌：mic（這台 Mac 的麥克風）／system（電腦裡的聲音＝線上會議的對方）／mix（只剩混好的 m4a）
        public var track: String
        public init(id: String, vector: [Float], seconds: Double, spans: [ClosedRange<Double>], track: String = "mix") {
            self.id = id; self.vector = vector; self.seconds = seconds; self.spans = spans; self.track = track
        }
    }

    /// 一場的一個音源
    public struct Source: Equatable {
        public var url: URL
        public var track: String
        public init(url: URL, track: String) { self.url = url; self.track = track }
    }

    /// 軌的中文（畫面、命令列用）
    public static func trackName(_ t: String) -> String {
        switch t {
        case "mic": return "麥克風"
        case "system": return "電腦聲音（遠端）"
        default: return "混音"
        }
    }

    /// 錄音工作夾裡的分軌（mic.wav、system.wav；只有檔頭的空檔不算）
    public static func sources(workDir: URL) -> [Source] {
        [("mic.wav", "mic"), ("system.wav", "system")].compactMap { f, t in
            let u = workDir.appendingPathComponent(f)
            let n = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.intValue ?? 0
            return n > 1_000 ? Source(url: u, track: t) : nil
        }
    }

    /// 一場會議的音源：分軌還在（meta.json 的 id → 錄音工作夾，30 天後才丟垃圾桶）就用分軌；不然用混好的 m4a
    public static func sources(meetingDir: URL, m4a: URL?) -> [Source] {
        if let d = try? Data(contentsOf: meetingDir.appendingPathComponent("meta.json")),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = o["id"] as? String, !id.isEmpty, !id.contains("/") {
            let s = sources(workDir: Pipeline.recordingsDir.appendingPathComponent(id))
            if !s.isEmpty { return s }
        }
        if let m = m4a, FileManager.default.fileExists(atPath: m.path) { return [Source(url: m, track: "mix")] }
        return []
    }

    /// 逐字稿這一行是哪一軌講的：遠端＝電腦聲音，其他（我方、現場、電話端…）＝麥克風
    static func track(ofWho who: String) -> String { who.hasPrefix("遠端") ? "system" : "mic" }

    /// 說話人分段的實作（HearbyVoice 的 FluidVoiceEngine）；nil＝這個版本沒有（Windows、測試）
    public protocol Engine: AnyObject {
        var model: String { get }
        /// 一段錄音裡有哪些聲音；第一次會下載模型（約 22 MB）
        func clusters(of audio: URL, progress: ((String) -> Void)?) async throws -> [Cluster]
    }

    public static var engine: Engine?
    static let engineLock = NSLock()
    /// 聲紋像到多少算同一個人（實測：同一人 0.83–0.94、不同人 ≤ 0.60）
    public static let threshold: Float = 0.70
    /// 講不到這麼多秒的聲音不比、不標（太短的聲紋不準）
    public static let minSeconds: Double = 20

    /// 這台 Mac 能不能用：有引擎、macOS 15 以上
    public static var supported: Bool {
        engine != nil && ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    }
    /// 整理時要不要認聲音：能用、而且設定打開
    public static var enabled: Bool { supported && ConfigStore.shared.current.voicesEnabled }

    // MARK: 存

    static var fileURL: URL { Paths.support.appendingPathComponent("voices.json") }

    public static func people() -> [Print] {
        guard let d = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Store.self, from: d) else { return [] }
        return s.people
    }

    static func write(_ people: [Print]) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(Store(people: people)).write(to: fileURL, options: [.atomic])
    }

    /// 記住一個人（呼叫前要已經拿到本人同意）：同名、同模型、同一軌的併在一起（照秒數加權平均），不然新增一筆
    @discardableResult
    public static func remember(name raw: String, cluster: Cluster, model: String, source: String, consentDate: Date = Date()) throws -> Print {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HearbyError("名字是空的") }
        guard cluster.seconds >= minSeconds else { throw HearbyError("這個聲音只講了 \(Int(cluster.seconds)) 秒，太短了，記了也認不準（要 \(Int(minSeconds)) 秒以上）") }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.calendar = Calendar(identifier: .gregorian); df.dateFormat = "yyyy-MM-dd"
        var all = people()
        let v = normalized(cluster.vector)
        if let i = all.firstIndex(where: { $0.name == name && $0.model == model && $0.track == cluster.track }) {
            var p = all[i]
            let w = p.seconds + cluster.seconds
            p.vector = normalized(zip(p.vector, v).map { Float(($0 * Float(p.seconds) + $1 * Float(cluster.seconds)) / Float(w)) })
            p.seconds = w
            if !p.sources.contains(source) { p.sources.append(source) }
            all[i] = p
            try write(all)
            return p
        }
        let p = Print(name: name, vector: v, seconds: cluster.seconds, sources: [source], consent: "\(df.string(from: consentDate)) 本人同意", model: model, track: cluster.track)
        all.append(p)
        try write(all)
        return p
    }

    /// 忘記這個人：他的每一筆（每一軌）都拿掉（不留備份）；回有沒有這個人
    @discardableResult
    public static func forget(_ name: String) throws -> Bool {
        var all = people()
        let n = all.count
        all.removeAll { $0.name == name }
        guard all.count != n else { return false }
        try write(all)
        return true
    }

    // MARK: 比

    static func normalized(_ v: [Float]) -> [Float] {
        let n = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var d: Float = 0, x: Float = 0, y: Float = 0
        for i in a.indices { d += a[i] * b[i]; x += a[i] * a[i]; y += b[i] * b[i] }
        return x > 0 && y > 0 ? d / (x.squareRoot() * y.squareRoot()) : 0
    }

    /// 每個聲音（夠長的）最像的人，只跟同一軌、同一個模型的聲紋比，像到門檻以上才算；
    /// 同一個人可以對到兩個聲音（分段有時把一個人切成兩個）
    public static func match(_ clusters: [Cluster], _ people: [Print], model: String) -> [String: (name: String, score: Float)] {
        var out: [String: (name: String, score: Float)] = [:]
        let usable = people.filter { $0.model == model }
        for c in clusters where c.seconds >= minSeconds {
            var best: (name: String, score: Float)? = nil
            for p in usable where p.track == c.track {
                let s = cosine(c.vector, p.vector)
                if s >= threshold, s > (best?.score ?? -1) { best = (p.name, s) }
            }
            if let b = best { out[c.id] = b }
        }
        return out
    }

    /// 聲音 → 標籤：認得的＝名字；沒認出、夠長的＝「聲音A」「聲音B」…（講得多的排前面）；太短的不標
    public static func tags(_ clusters: [Cluster], matched: [String: (name: String, score: Float)]) -> [String: String] {
        var out: [String: String] = [:]
        var n = 0
        for c in clusters.sorted(by: { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.id < $1.id }) where c.seconds >= minSeconds {
            if let m = matched[c.id] { out[c.id] = m.name; continue }
            out[c.id] = "聲音" + letter(n)
            n += 1
        }
        return out
    }

    static func letter(_ i: Int) -> String {
        let a = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return i < a.count ? String(a[i]) : "\(i + 1)"
    }

    /// 「[mm:ss]」「[h:mm:ss]」→ 秒
    static func seconds(_ stamp: String) -> Double? {
        let p = stamp.split(separator: ":").map { Int($0) }
        guard !p.isEmpty, !p.contains(where: { $0 == nil }) else { return nil }
        return Double(p.reduce(0) { $0 * 60 + $1! })
    }

    /// 逐字稿每一行（「- [mm:ss][誰] 內容」）是哪個聲音講的：從這行的時間到下一行（最多 30 秒）跟哪個聲音重疊最多——
    /// 分軌切的只看同一軌（遠端的行看電腦聲音那軌，其他看麥克風那軌）；回（行號 → 標籤）
    public static func lineTags(transcript: String, clusters: [Cluster], tags: [String: String]) -> [Int: String] {
        let lines = transcript.components(separatedBy: "\n")
        var starts: [(Int, Double, String)] = []
        for (i, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ["), let e = t.range(of: "]") else { continue }
            var who = ""
            if let a = t.range(of: "]["), let b = t.range(of: "]", range: a.upperBound..<t.endIndex) { who = String(t[a.upperBound..<b.lowerBound]) }
            if let s = seconds(String(t[t.index(t.startIndex, offsetBy: 3)..<e.lowerBound])) { starts.append((i, s, track(ofWho: who))) }
        }
        let tagged = clusters.filter { tags[$0.id] != nil }
        var out: [Int: String] = [:]
        for (k, (i, s, tr)) in starts.enumerated() {
            var end = s + 30
            if let next = starts[(k + 1)...].first(where: { $0.1 > s }) { end = min(end, next.1) }
            if end <= s { end = s + 5 }
            var best: (String, Double)? = nil
            for c in tagged where c.track == "mix" || c.track == tr {
                var o = 0.0
                for sp in c.spans where sp.upperBound > s && sp.lowerBound < end { o += min(sp.upperBound, end) - max(sp.lowerBound, s) }
                if o > 0.5, o > (best?.1 ?? 0) { best = (c.id, o) }
            }
            if let b = best, let tag = tags[b.0] { out[i] = tag }
        }
        return out
    }

    /// 交給 AI 的逐字稿：有標籤的行 who 後面加「·標籤」（「- [00:12][我方·林小安] …」）
    public static func inject(_ transcript: String, tags: [Int: String]) -> String {
        guard !tags.isEmpty else { return transcript }
        var lines = transcript.components(separatedBy: "\n")
        for (i, tag) in tags where i < lines.count {
            let l = lines[i]
            guard let a = l.range(of: "]["), let b = l.range(of: "] ", range: a.upperBound..<l.endIndex) else { continue }
            lines[i] = String(l[..<b.lowerBound]) + "·" + tag + String(l[b.lowerBound...])
        }
        return lines.joined(separator: "\n")
    }

    /// 紀錄表頭一行
    public static func headerLine(clusters: [Cluster], matched: [String: (name: String, score: Float)], remembered: Int) -> String? {
        let big = clusters.filter { $0.seconds >= minSeconds }
        guard !big.isEmpty else { return nil }
        func mins(_ s: Double) -> String { s < 60 ? "不到 1 分鐘" : "\(Int(s / 60)) 分鐘" }
        var byName: [(String, Double)] = []
        for c in big.sorted(by: { $0.seconds > $1.seconds }) {
            guard let m = matched[c.id] else { continue }
            if let i = byName.firstIndex(where: { $0.0 == m.name }) { byName[i].1 += c.seconds } else { byName.append((m.name, c.seconds)) }
        }
        let unknown = big.filter { matched[$0.id] == nil }.count
        var parts: [String] = []
        if !byName.isEmpty { parts.append("認出 " + byName.map { "\($0.0)（\(mins($0.1))）" }.joined(separator: "、")) }
        if unknown > 0 { parts.append((byName.isEmpty ? "這場 \(unknown) 個聲音都沒認出" : "另有 \(unknown) 個聲音沒認出") + (remembered == 0 ? "（這台 Mac 還沒記住任何人的聲音）" : "")) }
        return "> 聲紋：" + parts.joined(separator: "；")
    }

    /// AI 還是把「聲音A」寫成與會者或待辦負責人的：與會者那一行拿掉、負責人清空
    public static func scrub(_ notes: String) -> String {
        let tag = #"^聲音[A-Z0-9]+$"#
        var sec = ""
        var out: [String] = []
        for line in notes.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { sec = line; out.append(line); continue }
            if sec.contains("與會者"), line.hasPrefix("- ") {
                let who = String(line.dropFirst(2)).components(separatedBy: CharacterSet(charactersIn: " —（(")).first ?? ""
                if who.range(of: tag, options: .regularExpression) != nil { continue }
            }
            if sec.contains("待辦"), line.contains("- ["), line.contains("｜") {
                var cols = line.components(separatedBy: "｜")
                if cols.count >= 2, cols[1].trimmingCharacters(in: .whitespaces).range(of: tag, options: .regularExpression) != nil {
                    cols[1] = ""
                    out.append(cols.joined(separator: "｜"))
                    continue
                }
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// 有標籤時多給 AI 的規則
    public static let promptRule = """


        說話人（聲紋）：逐字稿 who 標籤裡「·」後面是 Hearby 比對聲紋標的說話人——名字＝這台 Mac 記得、本人同意過的聲音；「聲音A」這類代號＝沒認出來，但同一個代號是同一個人。當參考：與會者、誰說了什麼可以照它寫；跟逐字稿內容明顯矛盾時照內容。「聲音A」這類代號不是名字：不要寫進與會者，也不要當待辦負責人。
        """

    // MARK: 一場

    /// 一場錄音認聲音的結果：交給 AI 的行標籤、表頭一行
    public struct Result {
        public var tags: [Int: String]
        public var line: String?
    }

    /// 每個音源各切一次，聲音代號前面加軌（「mic:S1」「system:S2」）。
    /// 一軌切不出來（現場開會時電腦聲音那軌整條沒人講話，分段會丟「沒有語音」）就跳過那一軌；每一軌都失敗才算失敗
    public static func clusters(of sources: [Source], engine e: Engine, progress: ((String) -> Void)? = nil) throws -> [Cluster] {
        // 一次只讓一件事用引擎（整理、重新整理、紀錄頁「找聲音」可能同時來）：模型第一次下載與載入不能兩邊一起做。
        // 呼叫端都在背景執行緒、在這裡等到做完，所以鎖在同一條執行緒上拿、上同一條執行緒放
        engineLock.lock()
        defer { engineLock.unlock() }
        var out: [Cluster] = []
        var lastError: Error? = nil
        var ok = 0
        for s in sources {
            do {
                let cl = try blocking { try await e.clusters(of: s.url, progress: progress) }
                out += cl.map { var c = $0; c.id = "\(s.track):\(c.id)"; c.track = s.track; return c }
                ok += 1
            } catch {
                HearbyLog.write("voices: \(s.track) 這軌跳過（\(error.localizedDescription)）")
                lastError = error
            }
        }
        if ok == 0, let err = lastError { throw err }
        return dropEchoes(out)
    }

    /// 喇叭回音：遠端的人從喇叭出來又被麥克風收進去，麥克風那軌會多出一個「聲音」，講話的時間幾乎都跟電腦聲音那軌重疊。
    /// 麥克風的聲音有六成以上的時間跟電腦聲音重疊＝回音，拿掉（不標、不算）。只有兩軌都在時才判斷
    public static func dropEchoes(_ clusters: [Cluster]) -> [Cluster] {
        let remote = clusters.filter { $0.track == "system" }.flatMap(\.spans).sorted { $0.lowerBound < $1.lowerBound }
        guard !remote.isEmpty, clusters.contains(where: { $0.track == "mic" }) else { return clusters }
        var merged: [ClosedRange<Double>] = []
        for r in remote {
            if let last = merged.last, r.lowerBound <= last.upperBound { merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound) } else { merged.append(r) }
        }
        return clusters.filter { c in
            guard c.track == "mic", c.seconds > 0 else { return true }
            var o = 0.0
            for sp in c.spans {
                for r in merged where r.upperBound > sp.lowerBound && r.lowerBound < sp.upperBound { o += min(r.upperBound, sp.upperBound) - max(r.lowerBound, sp.lowerBound) }
            }
            return o / c.seconds < 0.6
        }
    }

    /// 整理前跑（Pipeline、Repolish）：沒開、不能用、沒有音源＝nil；出錯只記 log，不擋整理
    public static func recognize(sources: [Source], transcript: String, onStage: ((String) -> Void)? = nil) -> Result? {
        guard enabled, let e = engine, !sources.isEmpty else { return nil }
        onStage?("認聲音中…（一小時的錄音約一分鐘）")
        do {
            let cl = try clusters(of: sources, engine: e, progress: onStage)
            let ps = people()
            let m = match(cl, ps, model: e.model)
            let t = tags(cl, matched: m)
            HearbyLog.write("voices: \(sources.map(\.track).joined(separator: "+"))，\(cl.count) 個聲音、認出 \(Set(m.values.map(\.name)).count) 人")
            return Result(tags: lineTags(transcript: transcript, clusters: cl, tags: t), line: headerLine(clusters: cl, matched: m, remembered: ps.count))
        } catch {
            HearbyLog.write("voices: 認聲音失敗 \(error.localizedDescription)")
            return nil
        }
    }

    /// 在背景執行緒等一個 async 工作做完（Pipeline、Repolish 都不在主執行緒）
    public static func blocking<T>(_ work: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var out: Result2<T> = .none
        Task.detached {
            do { out = .ok(try await work()) } catch { out = .err(error) }
            sem.signal()
        }
        sem.wait()
        switch out {
        case .ok(let v): return v
        case .err(let e): throw e
        case .none: throw HearbyError("認聲音沒有回應")
        }
    }

    enum Result2<T> { case none, ok(T), err(Error) }
}
