// Pipeline — 一場錄音從 wav 到紀錄：修 header → 聽打兩軌 → 情境判定與迴聲去重 → 別名回灌 →
// 逐字稿版先落檔 → 混 m4a → provider 整理 → 最終版覆寫 → 記憶機械層。落點＝~/Hearby/會議/<名>/。
import AVFoundation
import Foundation

public final class Pipeline {
    public var onStage: ((String) -> Void)?
    public var onPartialTranscript: ((String) -> Void)?
    private func stage(_ s: String) { onStage?(s) }
    public init() {}

    public static let silence: Float = 0.015

    /// 錄音工作夾根（app 資料，非使用者資料夾）
    public static var recordingsDir: URL { Paths.support.appendingPathComponent("recordings", isDirectory: true) }

    public static func loadMeta(_ dir: URL) -> MeetingMeta? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let m = try? dec.decode(MeetingMeta.self, from: d) { return m }
        return try? JSONDecoder().decode(MeetingMeta.self, from: d)
    }
    public static func saveMeta(_ m: MeetingMeta, to dir: URL) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(m) { try? d.write(to: dir.appendingPathComponent("meta.json"), options: .atomic) }
    }

    public struct Output {
        public let mdURL: URL
        public let meetingDir: URL
        public let summary: String
        public let polishErr: String?
    }

    public func process(dir: URL, meta rawMeta: MeetingMeta, provider: Provider) throws -> Output {
        var meta = rawMeta
        let micWav = dir.appendingPathComponent("mic.wav")
        let sysWav = dir.appendingPathComponent("system.wav")
        if meta.micMax == 0 && meta.sysMax == 0 { meta.micMax = 1; meta.sysMax = 1 }
        meta.seconds = Fmt.clampSeconds(meta.seconds)   // meta.json 裡的時長不可信（1e300 會讓後面的 Int() 直接 trap）
        if meta.seconds <= 0 { meta.seconds = Double(max(WavIO.durationMs(of: micWav) ?? 0, WavIO.durationMs(of: sysWav) ?? 0)) / 1000 }
        var warnings = meta.warnings
        var segs: [Segment] = []
        let attendeeNames = meta.attendees.trimmingCharacters(in: .whitespacesAndNewlines)
        var scenario = meta.scenario.flatMap { MeetingScenario(rawValue: $0) }
        let micWho = scenario?.micWho ?? "我方"
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "會議紀錄整理中")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        HearbyLog.write("pipeline start \(Int(meta.seconds))s provider=\(provider.id)")
        WavIO.repairHeader(micWav)
        WavIO.repairHeader(sysWav)

        let tr = Transcriber()
        tr.onStage = { [weak self] s in self?.stage(s) }
        let aliasTable = Clean.aliasTable()
        func partial(_ s: [Segment]) {
            onPartialTranscript?(s.suffix(6).map { "[\(Fmt.ts($0.fromMs))] \($0.text)" }.joined(separator: "\n"))
        }
        var trackErrors: [String] = []
        // 中途暫停的位置：聽打一定從這裡切開（暫停前後的話不會被併成同一句），逐字稿也在這裡插標記
        let pauses = meta.pauses ?? []
        let pauseCuts = PauseSpan.midPauses(pauses, totalSeconds: meta.seconds).map(\.atMs)
        if FileManager.default.fileExists(atPath: micWav.path), meta.micMax >= Self.silence {
            do { segs += try tr.transcribe(wav: micWav, who: micWho, label: "房間裡（麥克風）", workDir: dir, track: "mic", cuts: pauseCuts, onPartial: partial) }
            catch { trackErrors.append(error.localizedDescription); warnings.append("麥克風軌聽打失敗（\(error.localizedDescription)）") }
        } else { warnings.append("麥克風軌無聲，未聽打") }
        if FileManager.default.fileExists(atPath: sysWav.path), meta.sysMax >= Self.silence {
            do { segs += try tr.transcribe(wav: sysWav, who: "遠端", label: "電腦裡（系統聲音）", workDir: dir, track: "sys", cuts: pauseCuts, onPartial: partial) }
            catch { trackErrors.append(error.localizedDescription); warnings.append("系統聲音軌聽打失敗（\(error.localizedDescription)）") }
        } else if meta.sysMax < Self.silence, FileManager.default.fileExists(atPath: sysWav.path) {
            warnings.append("系統聲音軌全程無聲（會議可能沒有遠端聲音）")
        }
        warnings += tr.notes
        if segs.isEmpty {
            let fm = FileManager.default
            var why = trackErrors.first ?? (meta.imported == true ? "這個檔案裡沒有偵測到語音內容" : "兩軌都沒有偵測到語音內容")
            if !fm.fileExists(atPath: dir.path) { why = "找不到這個工作夾：\(dir.lastPathComponent)" }
            else if !fm.fileExists(atPath: micWav.path), !fm.fileExists(atPath: sysWav.path) { why = "這個工作夾裡沒有錄音檔（mic.wav／system.wav）" }
            else if trackErrors.isEmpty, let note = tr.notes.first(where: { $0.contains("音量太小") || $0.contains("空的") }) { why += "（\(note)）" }
            // 沒字的場次重跑也不會有字：標成不用再問，免得面板一直顯示「有 1 場錄音還沒整理」
            if trackErrors.isEmpty, fm.fileExists(atPath: dir.path) { try? "no-speech".write(to: dir.appendingPathComponent(".ignored"), atomically: true, encoding: .utf8) }
            throw HearbyError(why)
        }

        // 別名回灌（越用越好用）
        if !aliasTable.isEmpty {
            var n = 0
            segs = segs.map { s in
                let (t, k) = Clean.applyAliases(s.text, table: aliasTable)
                n += k
                return Segment(fromMs: s.fromMs, toMs: s.toMs, text: t, who: s.who)
            }
            if n > 0 { HearbyLog.write("alias applied \(n)") }
        }

        // 情境自動判定：兩軌都有且 mic 段 ≥15% 跟遠端高度重複＝開喇叭迴聲
        if scenario == nil {
            let sysSegs = segs.filter { $0.who == "遠端" }
            let micSegs = segs.filter { $0.who != "遠端" }
            if !sysSegs.isEmpty, !micSegs.isEmpty {
                let dup = micSegs.filter { Transcriber.bigramContainment($0.text, Transcriber.remoteTextAround(sysSegs, $0)) >= 0.6 }.count
                if Double(dup) / Double(micSegs.count) >= 0.15 { scenario = .onlineSpeaker }
            }
        }
        if scenario == .onlineSpeaker {
            let sysSegs = segs.filter { $0.who == "遠端" }
            if !sysSegs.isEmpty {
                let before = segs.count
                segs.removeAll { s in
                    guard s.who == micWho, !Transcriber.bigrams(s.text).isEmpty else { return false }
                    return Transcriber.bigramContainment(s.text, Transcriber.remoteTextAround(sysSegs, s)) >= 0.75
                }
                let removed = before - segs.count
                if removed > 0 { warnings.append("迴聲去重：移除 \(removed) 句與遠端重複的迴聲") }
            }
        }
        segs.sort { $0.fromMs < $1.fromMs }
        if scenario == .onlineHeadphones, !segs.contains(where: { $0.who == "遠端" }) { scenario = nil }
        let onsiteFallback = scenario == nil && !segs.contains { $0.who == "遠端" }
        let lines = segs.map { s -> (fromMs: Int, text: String) in
            let who = (onsiteFallback && s.who == "我方") ? "現場" : s.who
            return (s.fromMs, "- [\(Fmt.ts(s.fromMs))][\(who)] \(s.text)")
        }
        // 中途暫停過：在暫停的位置插一行標記（時間戳是錄到的時間，暫停那段不在音檔裡）
        let transcript = PauseSpan.weave(lines, pauses: pauses, totalSeconds: meta.seconds).joined(separator: "\n")
        try? transcript.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        meta.scenario = scenario?.rawValue

        // 檔名與落點
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"; df.locale = Locale(identifier: "zh_TW")
        let dateStr = df.string(from: meta.started)
        let durStr = Fmt.dur(meta.seconds)
        let baseName = Paths.meetingFolderName(date: meta.started, title: meta.title.isEmpty ? (RecordScene(rawValue: meta.scene ?? "meeting") ?? .meeting).mdTitle : meta.title)
        var name = baseName
        if let prev = meta.outName, !prev.isEmpty, prev.replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression) == baseName {
            name = prev
        } else {
            var n = 2
            while FileManager.default.fileExists(atPath: Paths.meetings.appendingPathComponent(name).path) { name = baseName + "-\(n)"; n += 1 }
            meta.outName = name
        }
        let meetingDir = Paths.meetings.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        // 逐字稿版先落檔之後這一場就出現在清單上；整理完才寫最終版：這段時間不能改標題
        MeetingBusy.begin(meetingDir)
        defer { MeetingBusy.end(meetingDir) }
        let mdURL = meetingDir.appendingPathComponent(name + ".md")
        let m4aDest = meetingDir.appendingPathComponent(name + ".m4a")
        Self.saveMeta(meta, to: dir)

        // 逐字稿版先落檔（任何時刻退出都至少有這份）
        stage("先存逐字稿版…")
        var input = Polish.Input(transcript: Transcriber.mergedForLLM(transcript), title: meta.title, attendees: attendeeNames, dateStr: dateStr, durStr: durStr, warnings: warnings, audioLine: dir.path)
        input.onsite = onsiteFallback; input.scenario = scenario; input.onsiteCount = meta.onsiteCount; input.brief = meta.brief ?? []
        input.scene = RecordScene(rawValue: meta.scene ?? "meeting") ?? .meeting
        input.pauseNote = PauseSpan.note(pauses, totalSeconds: meta.seconds)
        let (interim0, _, _) = Polish.buildNotes(input, provider: nil)
        let interim = Clean.toTraditional(interim0.replacingOccurrences(
            of: "（只有逐字稿：這場沒有接 AI 整理。逐字稿完整保留於下；到設定選「用我的訂閱」後，可用「重新整理全篇」補整理）",
            with: "（AI 整理進行中——若這一行一直在，代表整理沒跑完：打開這場紀錄按「重新整理全篇」即可補整理；逐字稿已完整保留於下）"))
        RecordMD.backupIfExists(mdURL)
        try interim.write(to: mdURL, atomically: true, encoding: .utf8)

        stage("壓製音檔（m4a）…")
        let m4aOK = Self.m4aLooksComplete(m4aDest, dir: dir) || Self.mixToM4A(dir: dir, dest: m4aDest, seconds: meta.seconds)
        if meta.imported == true {
            try? Srt.build(segs).write(to: meetingDir.appendingPathComponent(name + ".srt"), atomically: true, encoding: .utf8)
        }
        if !m4aOK { warnings.append("音檔混音未完成，原始分軌錄音仍在工作資料夾：\(dir.path)") }

        // 整理
        stage(provider.id == "none" ? "整理逐字稿…" : (meta.scene == "note" ? "AI 整理成筆記…" : meta.scene == "interview" ? "AI 整理成訪談稿…" : "AI 整理中…（判斷與會者、整理摘要與待辦）"))
        input.warnings = warnings
        input.audioLine = m4aOK ? m4aDest.path : dir.path
        input.context = PolishContext.load(excluding: name)   // 記憶裡有名冊才帶（沒有＝跟以前一樣）
        // 認聲音（實驗；macOS 15 以上、設定打開才跑）：這場有哪些聲音、認得的是誰；出錯只記 log，不擋整理
        // 分軌（mic.wav、system.wav）分開切；沒有分軌才用混好的 m4a
        var voiceSources = Voices.sources(workDir: dir)
        if voiceSources.isEmpty, m4aOK { voiceSources = [Voices.Source(url: m4aDest, track: "mix")] }
        if let v = Voices.recognize(sources: voiceSources, transcript: input.transcript, onStage: onStage) { input.voiceTags = v.tags; input.voiceLine = v.line }
        let (md0, summary0, polishErr) = Polish.buildNotes(input, provider: provider)
        let keep = input.context?.names ?? []   // 名冊上的名字不簡轉繁（「涂」不是「塗」）
        let md = Clean.toTraditional(md0, keep: keep)
        let summary = Clean.toTraditional(summary0, keep: keep)
        meta.provider = provider.id
        Self.saveMeta(meta, to: dir)

        stage("存檔中…")
        if let cur = try? String(contentsOf: mdURL, encoding: .utf8), cur != interim { RecordMD.backupIfExists(mdURL) }
        try md.write(to: mdURL, atomically: true, encoding: .utf8)
        try? md.write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        Self.saveMeta(meta, to: meetingDir)
        try? Mirror.copy(mdURL)
        EntryFiles.ensure()
        do { try MemoryStore.sync(mdURL: mdURL) } catch { HearbyLog.write("memory sync fail: \(error)") }
        if ConfigStore.shared.current.autoPDF { NotificationCenter.default.post(name: .hearbyWantsPDF, object: mdURL) }
        HearbyLog.write("pipeline done → \(mdURL.lastPathComponent) err=\(polishErr ?? "-")")
        return Output(mdURL: mdURL, meetingDir: meetingDir, summary: summary, polishErr: polishErr)
    }

    // MARK: m4a
    public static func m4aLooksComplete(_ dest: URL, dir: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: dest.path) else { return false }
        let wavMs = max(WavIO.durationMs(of: dir.appendingPathComponent("mic.wav")) ?? 0, WavIO.durationMs(of: dir.appendingPathComponent("system.wav")) ?? 0)
        guard wavMs > 0 else { return false }
        let want = Double(wavMs) / 1000
        let d = AVURLAsset(url: dest).duration.seconds
        return d.isFinite && d > 0 && abs(d - want) <= max(3, want * 0.05)
    }

    public static func mixToM4A(dir: URL, dest: URL, seconds: Double = 0) -> Bool {
        let tmp = dest.deletingPathExtension().appendingPathExtension("mixing.m4a")
        try? FileManager.default.removeItem(at: tmp)
        let comp = AVMutableComposition()
        var added = false
        for name in ["mic.wav", "system.wav"] {
            let u = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: u.path) else { continue }
            let asset = AVURLAsset(url: u)
            guard let src = asset.tracks(withMediaType: .audio).first,
                let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let dur = asset.duration
            guard dur.seconds > 0 else { continue }
            do { try t.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: .zero); added = true } catch { continue }
        }
        guard added, let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { return false }
        export.outputURL = tmp
        export.outputFileType = .m4a
        let sem = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sem.signal() }
        let limit = max(300.0, seconds * 0.5)
        if sem.wait(timeout: .now() + limit) == .timedOut { export.cancelExport() }
        guard export.status == .completed, FileManager.default.fileExists(atPath: tmp.path) else { try? FileManager.default.removeItem(at: tmp); return false }
        if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.trashItem(at: dest, resultingItemURL: nil) }
        do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { return false }
        return true
    }

    // MARK: 救援：沒整理完的工作夾
    public struct RecoveryItem: Identifiable {
        public var id: String { dir.path }
        public let dir: URL
        public let started: Date?
        public let seconds: Double
        public var title: String = ""
        public var looksLikeTest: Bool { seconds < 60 }
    }
    /// 工作夾名稱用的時間格式：固定西曆與 en_US_POSIX（系統設成民國／佛曆／日本年號時，預設格式會吐出 0115、2569 這種年份）
    public static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    /// 開一個新的工作夾（當場建好）。同一秒已經有一個＝加 -2、-3…：兩個匯入落在同一秒共用工作夾會互踩
    /// （沿用對方留下的 `.silent` 旗標而誤報「沒有偵測到語音」、同時寫同一個 mic.wav）。
    public static func newWorkDir(now: Date = Date()) throws -> (dir: URL, stamp: String) {
        let fm = FileManager.default
        try fm.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let base = stampFormatter.string(from: now)
        var name = base
        var k = 2
        while true {
            let d = recordingsDir.appendingPathComponent(name)
            do { try fm.createDirectory(at: d, withIntermediateDirectories: false); return (d, name) }
            catch CocoaError.fileWriteFileExists { name = "\(base)-\(k)"; k += 1; if k > 200 { throw HearbyError("建不了工作夾") } }
        }
    }

    public static func pendingRecoveries() -> [RecoveryItem] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil) else { return [] }
        let df = stampFormatter
        var items: [RecoveryItem] = []
        for d in dirs {
            let micURL = d.appendingPathComponent("mic.wav"), sysURL = d.appendingPathComponent("system.wav")
            guard fm.fileExists(atPath: micURL.path) || fm.fileExists(atPath: sysURL.path),
                !fm.fileExists(atPath: d.appendingPathComponent("notes.md").path),
                !fm.fileExists(atPath: d.appendingPathComponent(".ignored").path) else { continue }
            let secs = max(DualRecorder.wavSeconds(of: micURL) ?? 0, DualRecorder.wavSeconds(of: sysURL) ?? 0)
            if secs < 5 { continue }
            var item = RecoveryItem(dir: d, started: df.date(from: String(d.lastPathComponent.prefix(15))), seconds: secs)
            if let m = loadMeta(d) { item.title = m.title }
            items.append(item)
        }
        return items.sorted { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }
    }

    /// 30 天後把已整理的工作檔丟垃圾桶（可救回）
    public static func retentionSweep(days: Int = 30) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for d in dirs {
            let ignored = fm.fileExists(atPath: d.appendingPathComponent(".ignored").path)
            guard ignored || fm.fileExists(atPath: d.appendingPathComponent("notes.md").path) else { continue }
            if let notes = try? String(contentsOf: d.appendingPathComponent("notes.md"), encoding: .utf8), notes.contains("> 音檔：\(d.path)") { continue }
            let mod = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if mod < cutoff { try? fm.trashItem(at: d, resultingItemURL: nil) }
        }
    }
}

public extension Notification.Name {
    static let hearbyWantsPDF = Notification.Name("hearby.wantsPDF")
}
