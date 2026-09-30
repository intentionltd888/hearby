// AppState — 殼的狀態機：待命／錄音中／處理中／剛完成／出事；真錄音、真管線、救援、匯入、下載
import AppKit
import AVFoundation
import Combine
import Foundation
import HearbyCore
import HearbyUI
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let panel = PanelModel()
    @Published private(set) var phase: Phase = .idle
    private var recorder: DualRecorder?
    private var timer: Timer?
    private var meta = MeetingMeta()
    private var recTicks = 0
    /// 麥克風健康（沒暫停卻連續兩分鐘沒聲音＝多半選錯麥克風）
    private var micWatch = MicWatch(now: Date())
    /// 暫停多久之後提醒一次（第一次 10 分鐘，之後每 30 分鐘）
    private var nextPauseReminder: TimeInterval = 600
    static let micSilentAlertPrefix = "麥克風兩分鐘沒收到聲音"
    private var recordActivity: NSObjectProtocol?
    private var sleepObservers: [NSObjectProtocol] = []
    private var download: ModelDownload?
    private var downloadTimer: Timer?
    private var importTask: Task<Void, Never>?
    // 整理中（聽打＋AI）：擋閒置睡眠＋紀錄睡了多久。電池供電的闔蓋睡眠系統不給任何 app 擋：
    // 闔上筆電 whisper 就整個被凍住、打開才繼續——不說清楚的話看起來像「聽打很慢」，其實算力時間只有幾十秒。
    private var processActivity: NSObjectProtocol?
    private var processSleepObservers: [NSObjectProtocol] = []
    private var processSleptAt: Date?
    private var processSleptSecs: TimeInterval = 0
    var openWindow: () -> Void = {}
    var showPanel: () -> Void = {}
    var onPhase: (Phase) -> Void = { _ in }
    var presentExport: (URL) -> Void = { _ in }

    private init() {
        let cfg = ConfigStore.shared.current
        panel.scene = RecordScene.allCases.firstIndex { $0.rawValue == cfg.scene } ?? 0
        panel.online = cfg.online
        panel.brief = cfg.lastBrief ?? ""
        panel.onStart = { [weak self] in self?.start() }
        panel.onStop = { [weak self] in self?.stop() }
        panel.onPause = { [weak self] in self?.pause() }
        panel.onResume = { [weak self] in self?.resume() }
        panel.onDismiss = { [weak self] in self?.dismiss() }
        panel.onOpenWindow = { [weak self] in self?.openWindow(); WindowNav.shared.tab = 0 }
        panel.onOpenSettings = { [weak self] in self?.openWindow(); WindowNav.shared.tab = 1 }
        panel.onOpenMD = { [weak self] u in self?.openWindow(); WindowNav.shared.openRecord = u }
        panel.onExportWord = { [weak self] u in self?.exportWord(u) }
        panel.onContinueClaude = { u in _ = Exporters.continueWithClaude(mdURL: u) }
        panel.onDownloadModel = { [weak self] in self?.downloadWhisper() }
        panel.onRecover = { [weak self] r in self?.recover(r) }
        panel.onIgnoreRecovery = { r in try? Data().write(to: r.dir.appendingPathComponent(".ignored")); AppState.shared.refreshIdle() }
        panel.onImport = { [weak self] in self?.pickImport() }
        panel.onExportPDF = { [weak self] u in self?.presentExport(u) }
        refreshIdle()
    }

    // MARK: 狀態機
    @discardableResult
    func go(_ next: Phase, reason: String = "") -> Bool {
        guard phase.canGo(to: next) else { HearbyLog.write("state: \(phase.rawValue) → \(next.rawValue) 不合法，忽略 \(reason)"); return false }
        HearbyLog.write("state: \(phase.rawValue) → \(next.rawValue) \(reason)")
        phase = next
        panel.phase = next
        onPhase(next)
        if next == .idle { refreshIdle() }
        if next == .done || next == .error { showPanel() }
        if (next == .done || next == .error), ProcessInfo.processInfo.environment["HEARBY_AUTOQUIT"] == "1" {
            HearbyLog.write("autoquit phase=\(next.rawValue)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(next == .done ? 0 : 1) }
        }
        return true
    }
    func fail(_ msg: String) { panel.errorText = msg; go(.error, reason: msg) }
    func dismiss() { go(.idle, reason: "dismiss") }

    /// 待命頁要看的東西
    func refreshIdle() {
        panel.modelReady = SharedPaths.installedModel() != nil
        panel.lastMeeting = MeetingIndex.scan().first
        panel.pendingRecoveries = Pipeline.pendingRecoveries()
        panel.suggestedBrief = ConfigStore.shared.current.memoryEnabled ? MemoryStore.openItems() : []
        DispatchQueue.global(qos: .utility).async {
            let ok = ClaudeCLI.available && ClaudeCLI.authStatus()?.loggedIn == true
            DispatchQueue.main.async { self.panel.claudeReady = ok }
        }
    }

    var source: AudioSource { panel.online ? .online : .room }

    // MARK: 開錄
    func start() {
        guard recorder == nil, phase == .idle || phase == .done else { return }
        guard WhisperEngine.cliPath() != nil else { fail("語音辨識元件遺失，請重新下載安裝 Hearby"); return }
        guard SharedPaths.installedModel() != nil else {
            downloadWhisper()
            panel.downloadNote = "聽打模型還沒好：先下載（1.6 GB），好了就能錄"
            return
        }
        let scene = RecordScene.allCases[min(max(panel.scene, 0), RecordScene.allCases.count - 1)]
        try? ConfigStore.shared.update { $0.scene = scene.rawValue; $0.online = panel.online; $0.lastBrief = panel.brief }
        guard let (dir, stamp) = try? Pipeline.newWorkDir() else { fail("建不了錄音工作夾，請確認磁碟還有空間"); return }
        let rec = DualRecorder(dir: dir, source: source)
        recorder = rec
        meta = MeetingMeta()
        meta.id = stamp
        meta.started = Date()
        meta.scene = scene.rawValue
        meta.source = source.rawValue
        let briefLines = panel.brief.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        meta.brief = briefLines.isEmpty ? nil : briefLines
        meta.title = briefLines.first.map { String($0.prefix(40)) } ?? ""
        panel.alerts = []
        panel.micHistory = []; panel.sysHistory = []
        panel.elapsedText = "00:00"
        panel.paused = false; panel.pausedText = ""; panel.micName = ""
        Task { @MainActor in
            do {
                let warns = try await rec.start()
                meta.warnings = warns
                panel.alerts = warns
                panel.micName = rec.micDeviceName
                micWatch = MicWatch(now: Date())
                nextPauseReminder = 600
                if let free = DualRecorder.availableDiskBytes(at: Pipeline.recordingsDir), free < 2_000_000_000 {
                    panel.alerts.append("磁碟只剩約 \(String(format: "%.1f", Double(free) / 1_000_000_000)) GB，長會議可能中途存不進去")
                }
                panel.sysActive = rec.systemAudioActive
                go(.recording, reason: "start")
                recordActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "會議錄音中")
                installSleepObservers(rec)
                panel.noticeLine = "錄音中不要闔上筆電，闔上就沒有聲音了"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.panel.noticeLine = nil }
                startTimer()
                Pipeline.saveMeta(meta, to: dir)
            } catch {
                recorder = nil
                fail(error.localizedDescription)
            }
        }
    }

    private func installSleepObservers(_ rec: DualRecorder) {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in rec.noteSleep() },
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                // 暫停中睡著不算（那段本來就不錄），不用跟使用者說
                if rec.noteWake() { self?.panel.alerts.append("電腦剛才睡著了，睡眠期間沒有聲音（時長已扣除）") }
            },
        ]
    }
    private func removeSleepObservers() {
        for o in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        sleepObservers = []
        if let a = recordActivity { ProcessInfo.processInfo.endActivity(a); recordActivity = nil }
    }

    private func startTimer() {
        recTicks = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let rec = self.recorder, self.phase == .recording else { return }
            let now = Date()
            let elapsed = rec.recordedSeconds
            self.panel.elapsedText = Self.clockText(elapsed)
            let paused = rec.isPaused
            if self.panel.paused != paused { self.panel.paused = paused }
            if paused {
                let p = rec.currentPauseSeconds
                self.panel.pausedText = Self.clockText(p)
                if p >= self.nextPauseReminder {
                    self.nextPauseReminder += 1800
                    HearbyLog.write("rec pause reminder \(Int(p))s")
                    self.notify(title: "Hearby 還在暫停中", body: "已經暫停 \(PauseSpan.durText(p))，這段沒有在錄。要繼續就按選單列的 Hearby → 繼續錄。")
                }
            } else {
                // 麥克風健康：沒暫停卻連續兩分鐘幾乎沒聲音＝多半選錯麥克風或被靜音；有聲音了就收掉提醒
                switch self.micWatch.update(level: rec.micLevel, now: now) {
                case .silent?:
                    // 用的是哪支麥克風，計時底下那行已經寫了
                    HearbyLog.write("rec mic silent 120s dev=\(rec.micDeviceName)")
                    self.panel.alerts.append("\(Self.micSilentAlertPrefix)：是不是選錯麥克風，或被靜音了？")
                case .recovered?:
                    self.panel.alerts.removeAll { $0.hasPrefix(Self.micSilentAlertPrefix) }
                case nil:
                    break
                }
            }
            if self.panel.micName != rec.micDeviceName { self.panel.micName = rec.micDeviceName }
            self.panel.micHistory.append(rec.micLevel)
            self.panel.sysHistory.append(rec.sysLevel)
            if self.panel.micHistory.count > PanelModel.waveSlots { self.panel.micHistory.removeFirst() }
            if self.panel.sysHistory.count > PanelModel.waveSlots { self.panel.sysHistory.removeFirst() }
            self.panel.sysActive = rec.systemAudioActive
            if rec.writeFailures > 30, !self.panel.alerts.contains(where: { $0.contains("存不進磁碟") }) {
                self.panel.alerts.append("錄音存不進磁碟（可能已滿），請立刻清出空間"); NSSound(named: "Basso")?.play()
            }
            if rec.micDead, !self.panel.alerts.contains(where: { $0.contains("麥克風已中斷") }) {
                self.panel.alerts.append("麥克風已中斷（裝置切換後接不回來）——請按停止、確認麥克風後重新開始；已錄的部分都在"); NSSound(named: "Basso")?.play()
            }
            if rec.micRecovered { rec.micRecovered = false; self.panel.alerts.removeAll { $0.contains("麥克風已中斷") } }
            if rec.systemAudioActive, elapsed > 60, rec.sysMax < 0.015, !self.panel.alerts.contains(where: { $0.contains("電腦裡") }) {
                self.panel.alerts.append("電腦裡那條一直沒動：線上另一端的聲音沒進來（同一個房間開會就正常）")
            }
            self.recTicks += 1
            if self.recTicks % 300 == 0 { self.meta.seconds = elapsed; Pipeline.saveMeta(self.meta, to: rec.dir) }
        }
    }

    /// 00:00 或 1:02:03
    static func clockText(_ seconds: TimeInterval) -> String {
        let s = Int(Fmt.clampSeconds(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: 暫停／繼續（phase 仍是 recording；裝置不關，只是不寫檔）
    func pause() {
        guard phase == .recording, let rec = recorder, rec.pause() else { return }
        nextPauseReminder = 600
        panel.paused = true
        panel.pausedText = "00:00"
        meta.pauses = rec.pauses
        meta.seconds = rec.recordedSeconds
        Pipeline.saveMeta(meta, to: rec.dir)   // 當下就存：暫停中當機，重開補整理也知道停在哪
        HearbyLog.write("rec pause at \(Int(rec.recordedSeconds))s")
    }

    func resume() {
        guard phase == .recording, let rec = recorder, rec.resume() else { return }
        panel.paused = false
        panel.pausedText = ""
        micWatch.reset(now: Date())
        meta.pauses = rec.pauses
        Pipeline.saveMeta(meta, to: rec.dir)
        HearbyLog.write("rec resume after \(Int(rec.pauses.last?.seconds ?? 0))s")
    }

    // MARK: 停止 → 整理
    func stop() {
        guard let rec = recorder else { return }
        timer?.invalidate(); timer = nil
        removeSleepObservers()
        let secs = rec.stop()
        panel.paused = false
        panel.pausedText = ""
        meta.seconds = secs
        meta.micMax = rec.micMax
        meta.sysMax = rec.sysMax
        meta.pauses = rec.pauses.isEmpty ? nil : rec.pauses
        var warnings = meta.warnings
        if source.wantsSystemAudio, !rec.systemAudioActive, !warnings.contains(where: { $0.contains("系統聲音") }) { warnings.append("系統聲音軌中途中斷或未啟用") }
        if rec.systemAudioActive, rec.sysBufferCount == 0 { warnings.append("系統聲音串流已啟動，但整場沒有收到任何聲音資料") }
        if let e = rec.sysStopError { warnings.append("系統聲音串流中途被系統中止：\(e)") }
        if rec.micInterrupted { warnings.append("錄音中麥克風裝置曾被切換，已自動接續，交界處可能缺幾秒") }
        if rec.sleptWhileRecording { warnings.append("錄音中電腦曾睡眠約 \(max(1, Int(rec.sleepSeconds / 60))) 分鐘，睡眠期間收不到聲音，時長已扣除") }
        if let wavSecs = DualRecorder.wavSeconds(of: rec.dir.appendingPathComponent("mic.wav")), secs > 120, wavSecs < secs * 0.9 {
            warnings.append("音檔比計時短約 \(Int((secs - wavSecs) / 60) + 1) 分鐘，中途可能磁碟滿或裝置中斷")
        }
        if rec.writeFailures > 0 { warnings.append("錄音期間發生 \(rec.writeFailures) 次寫入失敗（磁碟滿？），內容可能不完整") }
        meta.warnings = warnings
        Pipeline.saveMeta(meta, to: rec.dir)
        recorder = nil
        if secs < 3 {
            // 太短＝誤按：不整理，直接回待命
            try? Data().write(to: rec.dir.appendingPathComponent(".ignored"))
            go(.idle, reason: "too short")
            return
        }
        process(dir: rec.dir, meta: meta)
    }

    private func process(dir: URL, meta m: MeetingMeta) {
        guard go(.processing, reason: "process") else { return }
        panel.stageText = "準備聽打…"
        panel.partial = ""
        beginProcessActivity()
        let provider = Providers.current()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Pipeline()
            p.onStage = { s in DispatchQueue.main.async { self?.panel.stageText = s } }
            p.onPartialTranscript = { t in DispatchQueue.main.async { self?.panel.partial = t } }
            do {
                let out = try p.process(dir: dir, meta: m, provider: provider)
                DispatchQueue.main.async {
                    guard let self else { return }
                    let slept = self.endProcessActivity()
                    self.panel.doneTitle = out.mdURL.deletingPathExtension().lastPathComponent
                    self.panel.doneLines = Polish.threeLines(md: (try? String(contentsOf: out.mdURL, encoding: .utf8)) ?? "")
                    self.panel.doneMD = out.mdURL
                    var note = out.polishErr.map { "整理沒成功：\($0)。逐字稿已經存好了，之後打開這份紀錄按「重新整理全篇」就能補。" } ?? ""
                    if slept >= 30 { note += (note.isEmpty ? "" : "\n") + "這次比較久，是因為整理期間電腦睡了約 \(max(1, Int(slept / 60))) 分鐘：闔上筆電就會暫停，打開才繼續。" }
                    self.panel.doneNote = note
                    self.go(.done, reason: "pipeline done")
                    self.notify(title: "紀錄整理好了", body: out.summary)
                    self.panel.brief = ""
                    try? ConfigStore.shared.update { $0.lastBrief = nil }
                }
            } catch {
                DispatchQueue.main.async { _ = self?.endProcessActivity(); self?.fail(error.localizedDescription) }
            }
        }
    }

    /// 整理期間：擋閒置睡眠（筆電開著放著不會睡；插電外接螢幕闔蓋也不會睡）；電池闔蓋照睡＝系統不給擋，只能記下睡了多久、完成頁說清楚
    private func beginProcessActivity() {
        processActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "整理會議紀錄中")
        processSleptSecs = 0; processSleptAt = nil
        let nc = NSWorkspace.shared.notificationCenter
        processSleepObservers = [
            nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.processSleptAt = Date()
                HearbyLog.write("processing: system sleep（聽打／整理暫停，醒來才會繼續）")
            },
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, let t = self.processSleptAt else { return }
                self.processSleptSecs += Date().timeIntervalSince(t); self.processSleptAt = nil
                HearbyLog.write("processing: wake，整理期間累計睡了 \(Int(self.processSleptSecs))s")
                self.panel.stageText = "電腦剛睡著了約 \(max(1, Int(self.processSleptSecs / 60))) 分鐘，整理暫停過，現在繼續…"
            },
        ]
    }
    /// 回傳這次整理期間總共睡了幾秒
    @discardableResult private func endProcessActivity() -> TimeInterval {
        for o in processSleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        processSleepObservers = []
        if let a = processActivity { ProcessInfo.processInfo.endActivity(a); processActivity = nil }
        if let t = processSleptAt { processSleptSecs += Date().timeIntervalSince(t); processSleptAt = nil }
        return processSleptSecs
    }

    private func notify(title: String, body: String) {
        // 不是從 .app 包裡跑（開發時直接跑執行檔）就沒有通知中心可用：UNUserNotificationCenter.current() 會丟例外
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let c = UNUserNotificationCenter.current()
        c.getNotificationSettings { s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else { return }
            let n = UNMutableNotificationContent()
            n.title = title
            n.body = String(body.prefix(140))
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
        }
    }

    // MARK: 救援／匯入
    func recover(_ item: Pipeline.RecoveryItem) {
        guard phase == .idle else { return }
        WavIO.repairHeader(item.dir.appendingPathComponent("mic.wav"))
        WavIO.repairHeader(item.dir.appendingPathComponent("system.wav"))
        var m = Pipeline.loadMeta(item.dir) ?? MeetingMeta()
        if let s = item.started { m.started = s }
        if m.seconds <= 0 || m.imported == true { m.seconds = item.seconds }
        m.micMax = 1; m.sysMax = 1
        if !m.warnings.contains(where: { $0.contains("救援") }) { m.warnings.append("此紀錄由中斷救援補整理，錄音可能不完整") }
        process(dir: item.dir, meta: m)
    }

    func pickImport() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff]
        p.allowsMultipleSelection = false
        p.message = "選一個音檔或影片，Hearby 會聽打並整理"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { importMedia(u) }
    }

    func importMedia(_ url: URL) {
        guard recorder == nil, importTask == nil, phase == .idle || phase == .done else { return }
        guard SharedPaths.installedModel() != nil else { downloadWhisper(); return }
        let ext = url.pathExtension.lowercased()
        guard MediaImporter.allExts.contains(ext) else { fail("不支援的檔案格式（.\(ext)）。支援 m4a／mp3／wav／aiff 音檔與 mp4／mov 影片"); return }
        guard go(.processing, reason: "import") else { return }
        panel.stageText = "讀取檔案…"
        guard let (dir, stamp) = try? Pipeline.newWorkDir() else { fail("建不了工作夾，請確認磁碟還有空間"); return }
        importTask = Task { @MainActor in
            do {
                let probe = try await MediaImporter.probe(url)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var m = MeetingMeta()
                m.id = stamp; m.started = Date(); m.imported = true; m.sourceFile = url.path
                m.title = url.deletingPathExtension().lastPathComponent
                m.seconds = probe.seconds
                Pipeline.saveMeta(m, to: dir)
                let secs = try await MediaImporter.transcode(probe, to: dir.appendingPathComponent("mic.wav")) { frac in
                    DispatchQueue.main.async { self.panel.stageText = String(format: "轉檔中 %.0f%%", frac * 100) }
                }
                m.seconds = secs; m.micMax = 1; m.sysMax = 0
                Pipeline.saveMeta(m, to: dir)
                importTask = nil
                phase = .idle; panel.phase = .idle   // 讓 process() 的狀態閘通過
                process(dir: dir, meta: m)
            } catch {
                importTask = nil
                // 匯入失敗的工作夾不要變成「還沒整理的錄音」：來源檔還在，要重來就再匯入一次
                try? "import-failed".write(to: dir.appendingPathComponent(".ignored"), atomically: true, encoding: .utf8)
                fail(error.localizedDescription)
            }
        }
    }

    // MARK: 模型下載
    func downloadWhisper() {
        guard download == nil else { return }
        panel.downloadFraction = 0
        panel.downloadNote = ""
        let d = ModelDownload.start(ModelCatalog.whisper) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.downloadTimer?.invalidate(); self.downloadTimer = nil
                self.download = nil
                self.panel.downloadFraction = nil
                switch r {
                case .success: self.panel.modelReady = true; self.panel.downloadNote = ""
                case .failure(let e): self.panel.downloadNote = e.localizedDescription
                }
            }
        }
        download = d
        downloadTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.panel.downloadFraction = d.fraction
        }
    }

    // MARK: 匯出／重整理（視窗用）
    func exportWord(_ md: URL) { presentExport(md) }

    func windowActions() -> WindowActions {
        var a = WindowActions()
        a.openMD = { [weak self] u in self?.openWindow(); WindowNav.shared.openRecord = u }
        a.revealDir = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        a.exportWord = { md, h, done in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Exporters.word(mdURL: md, header: h)
                DispatchQueue.main.async { if case .success(let u) = r { NSWorkspace.shared.activateFileViewerSelecting([u]) }; done(r) }
            }
        }
        a.exportPDF = { md, h, done in Exporters.pdf(mdURL: md, header: h) { r in if case .success(let u) = r { NSWorkspace.shared.activateFileViewerSelecting([u]) }; done(r) } }
        a.exportPages = { md, h, done in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Exporters.pages(mdURL: md, header: h)
                DispatchQueue.main.async { done(r) }
            }
        }
        a.continueClaude = { _ = Exporters.continueWithClaude(mdURL: $0) }
        a.repolish = { md, corr, stage, done in
            let provider = Providers.current()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard provider.id != "none" else { throw HearbyError("先到設定選「用我的訂閱」才能重新整理") }
                    let (_, s) = try Repolish.whole(mdURL: md, corrections: corr, provider: provider) { t in DispatchQueue.main.async { stage(t) } }
                    DispatchQueue.main.async { done(.success(s)) }
                } catch { DispatchQueue.main.async { done(.failure(error)) } }
            }
        }
        a.sectionEdit = { md, sec, ins, done in
            let provider = Providers.current()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard provider.id != "none" else { throw HearbyError("先到設定選「用我的訂閱」才能請 AI 改") }
                    let t = try Repolish.section(mdURL: md, sectionName: sec, instruction: ins, provider: provider)
                    DispatchQueue.main.async { done(.success(t)) }
                } catch { DispatchQueue.main.async { done(.failure(error)) } }
            }
        }
        a.translate = { md, lang, done in
            let provider = Providers.current()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard provider.id != "none" else { throw HearbyError("先到設定把紀錄交給 Claude 或 ChatGPT 整理，才能翻譯") }
                    let u = try Repolish.translate(mdURL: md, language: lang, provider: provider)
                    DispatchQueue.main.async { done(.success(u)) }
                } catch { DispatchQueue.main.async { done(.failure(error)) } }
            }
        }
        a.renameMeeting = { [weak self] dir, title, done in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let r = try MeetingRename.rename(dir: dir, to: title)
                    DispatchQueue.main.async {
                        // 完成頁還指著這一場：跟著換，按「打開這份紀錄」才找得到
                        if let self, let u = self.panel.doneMD, let n = r.mdURL,
                           u.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path {
                            self.panel.doneMD = n
                            self.panel.doneTitle = r.newID
                        }
                        done(.success(r))
                    }
                } catch { DispatchQueue.main.async { done(.failure(error)) } }
            }
        }
        a.runDoctorDeep = { Doctor.run(deep: true) }
        a.exportDiagnostics = { Exporters.diagnostics() }
        a.rerunWizard = { [weak self] in self?.showWizard() }
        return a
    }

    var showWizard: () -> Void = {}
}
