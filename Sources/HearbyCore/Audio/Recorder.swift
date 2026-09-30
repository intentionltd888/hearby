// DualRecorder — 雙軌錄音（介面層切割：睡眠通知改由殼呼叫 noteSleep／noteWake）
//   軌 1（房間裡）：麥克風 AudioQueue → mic.wav；只開輸入裝置、不碰聲音輸出（見 MicQueue.swift）。
//   開、關、換裝置都在背景，等的一方有上限（開 3 秒）：系統音訊服務卡住時，主執行緒不跟著卡。
//   按停止：兩軌的收尾一起在背景做，主執行緒合計最多等 2 秒（輸出裝置卡住時，關保活與 tap 也會卡；見 stop()）。
//   軌 2（電腦裡）：系統聲音 → system.wav；macOS 14.4+ 走 Core Audio process tap（純音訊權限，
//   不在「螢幕錄製」那類每次更新重問的名單），14.0–14.3 退路 ScreenCaptureKit。
//   tap 要有輸出裝置在跑才送 buffer，所以兩軌模式另在預設輸出上跑一條只送靜音的 IOProc（見 startOutputKeepAlive）。
// 兩軌皆 16 kHz mono s16 wav，whisper 可直接吃。
//
// 收音來源三選：room＝只開麥克風（零系統聲權限）；online／mixed＝兩軌。

import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

public enum AudioSource: String, CaseIterable {
    case room, online
    public var label: String {
        switch self {
        case .room: return "同一個房間"
        case .online: return "線上會議"
        }
    }
    public var wantsSystemAudio: Bool { self == .online }
}

public final class DualRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    public let dir: URL
    public let source: AudioSource
    private var micFile: CrashSafeWavWriter?
    private var sysFile: CrashSafeWavWriter?
    public private(set) var sysBufferCount = 0
    public private(set) var sysStopError: String?
    private var stream: SCStream?
    // 系統聲那一軌轉檔的目標格式（16 kHz 單聲道浮點，寫檔時轉 s16）
    private let micOutFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: kSampleRate, channels: 1, interleaved: false)!
    private let sysQueue = DispatchQueue(label: "hearby.sysaudio")
    private var _stopping = false
    private var isStopping: Bool { levelLock.withLock { _stopping } }
    private var sysConverter: AVAudioConverter?
    private var sysConverterInFormat: AVAudioFormat?

    // 麥克風（見 MicQueue.swift）：每一格的回呼、寫檔、關檔都在 micCB 上（同一條序列佇列＝關檔不會跟寫入撞）；
    // 開、關、換裝置在 micCtl 上。兩條都不是主執行緒；會卡在系統音訊服務裡的呼叫，等的一方都有上限
    private let micCB = DispatchQueue(label: "hearby.mic", qos: .userInitiated)
    private let micCtl = DispatchQueue(label: "hearby.mic.ctl", qos: .userInitiated)
    private var mic: MicQueue?                  // 只在 micCtl 上動
    private var micCheck: DispatchSourceTimer?  // 只在 micCtl 上動
    private var lastDefaultInput = AudioDeviceID(0)
    private var reopenInFlight = false
    private var reopenAttempts = 0
    private var stallReopens = 0
    /// 麥克風開最多等幾秒；逾時用人話說明，不讓等的一方跟著卡住
    public static let micStartTimeout: TimeInterval = 3
    /// 按停止時主執行緒合計最多等幾秒（兩軌收尾一起在背景做）
    public static let stopTimeout: TimeInterval = 2
    /// 這一條幾秒沒送任何一格就重開（裝置被拔、系統音訊服務重啟）；連續重開都沒聲音，間隔加倍（最多 48 秒）
    static let micStallSeconds: TimeInterval = 3
    private var _micInterrupted = false
    private var _micDead = false
    private var _micRecovered = false
    private var _micDeviceName = ""
    private var _stallCheckAfter = Date.distantPast  // 睡眠中不查卡住；醒來先緩 5 秒
    public var micInterrupted: Bool { levelLock.withLock { _micInterrupted } }
    public var micDead: Bool { levelLock.withLock { _micDead } }
    public var micRecovered: Bool {
        get { levelLock.withLock { _micRecovered } }
        set { levelLock.withLock { _micRecovered = newValue } }
    }
    /// 正在用的麥克風（給畫面看：錄錯麥克風是最常見的「白錄一場」）
    public var micDeviceName: String { levelLock.withLock { _micDeviceName } }

    // process tap（14.4+）
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var tapProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var keepAliveDevice = AudioDeviceID(0)
    private var keepAliveProcID: AudioDeviceIOProcID?
    public private(set) var systemAudioMode = "none"  // none／tap／sck

    private let levelLock = NSLock()
    private var _micLevel: Float = 0
    private var _sysLevel: Float = 0
    private var _micMax: Float = 0
    private var _sysMax: Float = 0
    public var micLevel: Float { levelLock.withLock { _micLevel } }
    public var sysLevel: Float { levelLock.withLock { _sysLevel } }
    public var micMax: Float { levelLock.withLock { _micMax } }
    public var sysMax: Float { levelLock.withLock { _sysMax } }
    private func setMic(_ l: Float) { levelLock.withLock { _micLevel = l; if l > _micMax { _micMax = l } } }
    private func setSys(_ l: Float) { levelLock.withLock { _sysLevel = l; if l > _sysMax { _sysMax = l } } }

    public private(set) var systemAudioActive = false

    private var _micWriteFailures = 0
    private var _sysWriteFailures = 0
    public var writeFailures: Int { levelLock.withLock { _micWriteFailures + _sysWriteFailures } }

    // 時間帳：睡眠與暫停都扣（殼負責通知睡眠；暫停由使用者按）。細節見 Pause.swift
    private var clock = RecordingClock(startedAt: Date())
    public var startedAt: Date { levelLock.withLock { clock.startedAt } }
    public var sleepSeconds: TimeInterval { levelLock.withLock { clock.sleepSeconds } }
    public var sleptWhileRecording: Bool { levelLock.withLock { clock.sleptWhileRecording } }
    public var isPaused: Bool { levelLock.withLock { clock.isPaused } }
    public var pauses: [PauseSpan] { levelLock.withLock { clock.pauses } }
    /// 真的有錄到的秒數（扣掉睡眠與暫停）
    public var recordedSeconds: TimeInterval { levelLock.withLock { clock.recorded(at: Date()) } }
    /// 這一次暫停了多久（沒在暫停＝0）
    public var currentPauseSeconds: TimeInterval { levelLock.withLock { clock.currentPause(at: Date()) } }
    public func noteSleep() { levelLock.withLock { _ = clock.noteSleep(at: Date()); _stallCheckAfter = .distantFuture } }
    /// 回 true＝錄音中睡過一段（暫停中睡著不算：那段本來就不錄）
    @discardableResult public func noteWake() -> Bool {
        levelLock.withLock {
            _stallCheckAfter = Date().addingTimeInterval(5)  // 醒來後麥克風要一下子才恢復送音，先別當成卡住
            return clock.noteWake(at: Date())
        }
    }

    /// 暫停：裝置不關、只是不寫檔，所以繼續是即時的（重接音訊裝置可能卡住，見 startOutputKeepAlive 的說明）。
    /// 兩軌看同一個旗標，同一刻停寫、同一刻恢復，時間軸照樣對齊。
    @discardableResult public func pause() -> Bool {
        levelLock.withLock {
            guard !_stopping, clock.pause(at: Date()) else { return false }
            _micLevel = 0; _sysLevel = 0
            return true
        }
    }
    @discardableResult public func resume() -> Bool { levelLock.withLock { !_stopping && clock.resume(at: Date()) } }

    /// 這一刻收到的聲音要不要寫：停止中＝丟；暫停中＝丟，並把畫面上的音量歸零
    private func shouldWrite(mic: Bool) -> Bool {
        levelLock.withLock {
            if _stopping { return false }
            if clock.isPaused {
                if mic { _micLevel = 0 } else { _sysLevel = 0 }
                return false
            }
            return true
        }
    }

    public static func availableDiskBytes(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
    public static func wavSeconds(of url: URL) -> Double? {
        guard let ms = WavIO.durationMs(of: url) else { return nil }
        return Double(ms) / 1000.0
    }

    public init(dir: URL, source: AudioSource) {
        self.dir = dir
        self.source = source
        super.init()
    }

    /// 回傳警告清單；麥克風權限沒給＝throw
    public func start() async throws -> [String] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var warnings: [String] = []
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        guard micOK else {
            HearbyLog.write("rec mic start fail: 麥克風權限未授權")
            throw HearbyError("麥克風權限未授權：系統設定 → 隱私權與安全性 → 麥克風 → 開啟 Hearby")
        }
        try startMic()
        levelLock.withLock { clock = RecordingClock(startedAt: Date()) }  // mic.wav 從這裡開始；系統聲音那軌起不來時可能要等約 10 秒，計時不能從那之後才算
        if source.wantsSystemAudio {
            do {
                try await startSystem()
                systemAudioActive = true
            } catch {
                HearbyLog.write("sysaudio start fail: \(error.localizedDescription)")
                warnings.append("系統聲音沒錄到（線上另一端的聲音會缺）：\(error.localizedDescription)。這場先用麥克風錄，內容照樣完整。")
            }
        }
        return warnings
    }

    /// 開麥克風：在背景開、這裡最多等 micStartTimeout 秒（start() 是 async，本來就不在主執行緒上）
    private func startMic() throws {
        let t0 = Date()
        do {
            micFile = try CrashSafeWavWriter(url: dir.appendingPathComponent("mic.wav"))
            let m = try openMic()
            levelLock.withLock { _micDeviceName = m.deviceName }
            micCtl.sync {
                mic = m
                lastDefaultInput = m.device
                startMicCheck()
            }
        } catch {
            // 畫面只給一句話；原始錯誤與花了多久記在這裡
            HearbyLog.write(String(format: "rec mic start fail %.1fs: ", Date().timeIntervalSince(t0)) + "\(error)")
            throw error
        }
    }

    /// 在背景開一條新的麥克風佇列（綁這一刻的預設輸入），最多等 micStartTimeout 秒。
    /// 逾時＝放棄這一條（之後才起來也會馬上關掉），丟一句人話給畫面
    private func openMic() throws -> MicQueue {
        let m = MicQueue(callbackQueue: micCB) { [weak self] pcm in self?.micPCM(pcm) }
        guard let r = Bounded.run(Self.micStartTimeout, { try m.start() }) else {
            m.abandon()
            HearbyLog.write("rec mic start timeout \(Int(Self.micStartTimeout))s（系統音訊服務沒回應）")
            throw HearbyError("麥克風 \(Int(Self.micStartTimeout)) 秒沒有回應：這台 Mac 的音訊服務卡住了，重開機通常就好。")
        }
        try r.get()
        return m
    }

    /// 麥克風的每一格（micCB 上）：已經是 16 kHz 單聲道 s16，原樣寫
    private func micPCM(_ pcm: UnsafeBufferPointer<Int16>) {
        guard shouldWrite(mic: true), let file = micFile else { return }
        setMic(rmsLevel(pcm))
        if !file.write(samples: pcm) { levelLock.withLock { _micWriteFailures += 1 } }
    }

    private func startMicCheck() {  // micCtl 上
        let t = DispatchSource.makeTimerSource(queue: micCtl)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.checkMic() }
        t.resume()
        micCheck = t
    }

    /// 每秒一次（micCtl 上，不經過主執行緒）：
    ///   系統換了預設麥克風（插拔耳機、在控制中心換）＝重開一條跟過去；
    ///   這一條幾秒沒送任何一格（裝置被拔、系統音訊服務重啟）＝重開。暫停中照樣會送、只是不寫，不會誤判
    private func checkMic() {
        guard !isStopping, !reopenInFlight else { return }
        let now = Date()
        let def = AudioDevices.defaultInputID() ?? 0
        defer { lastDefaultInput = def }
        guard let m = mic else {
            if def != lastDefaultInput { reopenMic("default input change") }  // 已經判定中斷：換了麥克風就再試一輪
            return
        }
        if def != 0, def != m.device {
            reopenMic("default input change")
            return
        }
        let silent = m.silentFor(at: now)
        if silent > 1 { setMic(0) }  // 沒有新的一格：畫面上的音量不要停在最後那一格
        let stallAfter = Self.micStallSeconds * pow(2, Double(min(stallReopens, 4)))
        if silent > stallAfter, now > levelLock.withLock({ _stallCheckAfter }) {
            stallReopens += 1
            if stallReopens >= 3 { levelLock.withLock { _micDead = true } }  // 連重開三次都沒聲音：請使用者檢查麥克風
            reopenMic(String(format: "stalled %.0fs", silent))
        } else if silent < 1, stallReopens > 0 {
            stallReopens = 0
            levelLock.withLock { if _micDead { _micDead = false; _micRecovered = true } }
        }
    }

    /// micCtl 上：換掉現在這一條、開一條新的（綁這一刻的預設輸入）。舊的當下就不再寫、在背景關，不等它
    /// （系統音訊服務卡住時關也會卡，等它＝這幾秒都沒錄到）；開最多等 3 秒，開不起來每秒再試，
    /// 10 次後判定中斷（畫面提醒；之後換了麥克風會再試）
    private func reopenMic(_ why: String) {
        guard !isStopping, !reopenInFlight else { return }
        reopenInFlight = true
        levelLock.withLock { _micInterrupted = true }
        HearbyLog.write("rec mic \(why) → dev=\(AudioDevices.defaultInputName() ?? "?")")
        if let old = mic {
            mic = nil
            old.abandon()
        }
        setMic(0)
        reopenAttempts = 0
        attemptReopen()
    }

    private func attemptReopen() {  // micCtl 上
        guard !isStopping else { reopenInFlight = false; return }
        let t0 = Date()
        do {
            let m = try openMic()
            mic = m
            reopenInFlight = false
            levelLock.withLock {
                _micDeviceName = m.deviceName
                if _micDead, stallReopens == 0 { _micDead = false; _micRecovered = true }
            }
            HearbyLog.write(String(format: "rec mic reopened %.2fs", Date().timeIntervalSince(t0)))
        } catch {
            reopenAttempts += 1
            HearbyLog.write("rec mic reopen fail #\(reopenAttempts): \(error)")
            if reopenAttempts <= 10 {
                micCtl.asyncAfter(deadline: .now() + 1) { [weak self] in self?.attemptReopen() }
            } else {
                reopenInFlight = false
                levelLock.withLock { _micDead = true }
                HearbyLog.write("rec mic dead after 10 retries: \(error.localizedDescription)")
            }
        }
    }

    /// 開發用（命令列 --reopen-mic-at）：裝置沒換也照樣重開一次麥克風，量交界少了多少
    public func reopenMicForTesting() { micCtl.async { [weak self] in self?.reopenMic("forced") } }
    /// 開發用（命令列 --stall-mic-at）：現在這一條不再送音，測「幾秒沒收到就重開」
    public func stallMicForTesting() { micCtl.async { [weak self] in self?.mic?.pauseForTesting() } }

    /// 麥克風收尾（在背景跑，見 stop()）：停掉佇列、關檔
    private func closeMic() {
        let m: MicQueue? = micCtl.sync {
            micCheck?.cancel()
            micCheck = nil
            defer { mic = nil }
            return mic
        }
        m?.stop()
        micCB.sync { micFile?.close(); micFile = nil }
    }

    // MARK: 系統聲：process tap（14.4+）→ SCK 退路

    private func startSystem() async throws {
        sysFile = try CrashSafeWavWriter(url: dir.appendingPathComponent("system.wav"))
        // 輸出起不來＝tap 等不到任何 buffer，卡著的 tap 還會讓之後的麥克風重接跟著卡住：直接回報，不接 tap、不退 SCK
        try startOutputKeepAlive()
        if #available(macOS 14.4, *) {
            do {
                try startProcessTap()
                systemAudioMode = "tap"
                HearbyLog.write("sysaudio via process tap")
                return
            } catch {
                HearbyLog.write("process tap fail → SCK: \(error.localizedDescription)")
            }
        }
        try await startSCK()
        systemAudioMode = "sck"
    }

    /// process tap 只在「有輸出裝置在跑」時才送 buffer；沒有任何 app 出聲時 system.wav 會停住，兩軌時間軸就對不上。
    /// 以前是麥克風的 AVAudioEngine 順便把預設輸出跑起來（預設輸入＋預設輸出的聚合裝置）；麥克風改綁輸入裝置後，
    /// 由這裡在預設輸出上跑一條只送靜音的 IOProc，效果同以前（SCK 退路也一樣，維持以前的條件）。
    /// 預設輸出起不來（例如螢幕的音訊卡住，約 10 秒後回 'stop'）就 throw。
    private func startOutputKeepAlive() throws {
        guard let dev = AudioDevices.defaultOutputID() else { throw HearbyError("找不到聲音輸出裝置") }
        let name = AudioDevices.name(dev) ?? "\(dev)"
        var procID: AudioDeviceIOProcID?
        // queue 給 nil：直接在 IO 執行緒上填靜音，不跟 sysQueue 上寫檔的 tap 搶
        var st = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, _, _, outData, _ in
            for b in UnsafeMutableAudioBufferListPointer(outData) {
                if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) }
            }
        }
        guard st == noErr, let pid = procID else { throw HearbyError("聲音輸出裝置「\(name)」接不上（\(st)）") }
        let t0 = Date()
        st = AudioDeviceStart(dev, pid)
        let secs = String(format: "%.1fs", Date().timeIntervalSince(t0))
        guard st == noErr else {
            AudioDeviceDestroyIOProcID(dev, pid)
            HearbyLog.write("sysaudio keepalive fail \(secs) dev=\(name) st=\(st)")
            throw HearbyError("聲音輸出裝置「\(name)」沒有回應")
        }
        keepAliveDevice = dev
        keepAliveProcID = pid
        HearbyLog.write("sysaudio keepalive dev=\(name) \(secs)")
    }

    @available(macOS 14.4, *)
    private func startProcessTap() throws {
        // 全系統輸出（排除自己）的 tap → 私有聚合裝置 → IOProc 讀 buffer
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Hearby system audio"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap: AudioObjectID = 0
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr, tap != 0 else { throw HearbyError("建立 process tap 失敗（\(st)）") }
        tapID = tap
        // 聚合裝置只含這個 tap
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Hearby tap aggregate",
            kAudioAggregateDeviceUIDKey as String: "ltd.intention.hearby.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey as String: true]
            ],
        ]
        var agg: AudioObjectID = 0
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard st == noErr, agg != 0 else {
            AudioHardwareDestroyProcessTap(tap); tapID = 0
            throw HearbyError("建立聚合裝置失敗（\(st)）")
        }
        aggregateID = agg
        // tap 的串流格式
        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        st = AudioObjectGetPropertyData(tap, &fmtAddr, 0, nil, &size, &asbd)
        guard st == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else { throw HearbyError("讀 tap 格式失敗（\(st)）") }
        tapFormat = fmt
        var procID: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, sysQueue) { [weak self] _, inData, _, _, _ in
            guard let self, self.shouldWrite(mic: false), let file = self.sysFile, let fmt = self.tapFormat else { return }
            let abl = UnsafeMutablePointer<AudioBufferList>(mutating: inData)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: abl) else { return }
            self.sysBufferCount &+= 1
            self.setSys(rmsLevel(buf))
            self.writeSys(buf, file: file)
        }
        guard st == noErr, let pid = procID else { throw HearbyError("建 IOProc 失敗（\(st)）") }
        tapProcID = pid
        st = AudioDeviceStart(agg, pid)
        guard st == noErr else { throw HearbyError("啟動聚合裝置失敗（\(st)）") }
    }

    /// 任意格式 → 16k mono 寫檔（tap 與 SCK 共用）
    private func writeSys(_ buf: AVAudioPCMBuffer, file: CrashSafeWavWriter) {
        let fmt = buf.format
        if fmt.sampleRate == kSampleRate, fmt.channelCount == 1, fmt.commonFormat == .pcmFormatFloat32, !fmt.isInterleaved {
            if !file.write(buf) { levelLock.withLock { _sysWriteFailures += 1 } }
            return
        }
        if sysConverter == nil || sysConverterInFormat != fmt {
            sysConverter = AVAudioConverter(from: fmt, to: micOutFormat)
            sysConverterInFormat = fmt
        }
        guard let conv = sysConverter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * kSampleRate / fmt.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: micOutFormat, frameCapacity: cap) else { return }
        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buf
        }
        if out.frameLength > 0, !file.write(out) { levelLock.withLock { _sysWriteFailures += 1 } }
    }

    private func startSCK() async throws {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            throw HearbyError("尚未授權「螢幕與系統音訊錄製」（授權後要重開 app）")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw HearbyError("找不到顯示器") }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = Int(kSampleRate)
        cfg.channelCount = 1
        cfg.width = 64; cfg.height = 64
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sysQueue)
        try? s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sysQueue)
        try await s.startCapture()
        stream = s
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, shouldWrite(mic: false), sampleBuffer.isValid, let file = sysFile else { return }
        sysBufferCount &+= 1
        try? sampleBuffer.withAudioBufferList(body: { abl, _ in
            guard let absd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                let fmt = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate, channels: AVAudioChannelCount(absd.mChannelsPerFrame)),
                let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: abl.unsafePointer)
            else { return }
            self.setSys(rmsLevel(buf))
            self.writeSys(buf, file: file)
        })
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        systemAudioActive = false
        sysStopError = error.localizedDescription
    }

    /// 停止並 finalize；回傳實錄秒數（扣掉睡眠與暫停；算到按下停止那一刻，不含收尾的幾秒）
    public func stop() -> TimeInterval {
        let now = Date()
        levelLock.withLock { _stopping = true; clock.close(at: now) }
        // 兩軌的收尾都會進系統音訊服務（關麥克風佇列；關 tap、聚合裝置、輸出保活），輸出裝置或音訊服務卡住時也會卡。
        // 一起丟到背景，主執行緒合計最多等 stopTimeout 秒。寫入在 _stopping 那一刻就停了；
        // 逾時的那一軌另外排一個關檔（跟寫入同一條佇列，不會撞），音檔照樣完整，背景那一段之後自己收完
        let deadline = DispatchTime.now() + Self.stopTimeout
        let micDone = DispatchGroup(), sysDone = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: micDone) { [self] in closeMic() }
        DispatchQueue.global(qos: .userInitiated).async(group: sysDone) { [self] in closeSystem() }
        if micDone.wait(timeout: deadline) == .timedOut {
            HearbyLog.write("rec mic stop timeout \(Int(Self.stopTimeout))s")
            micCB.async { [self] in micFile?.close(); micFile = nil }
        }
        if sysDone.wait(timeout: deadline) == .timedOut {
            HearbyLog.write("sysaudio stop timeout \(Int(Self.stopTimeout))s")
            sysQueue.async { [self] in sysFile?.close(); sysFile = nil }
        }
        setMic(0); setSys(0)
        return levelLock.withLock { clock.recorded(at: now) }
    }

    /// 系統聲收尾（在背景跑，見 stop()）：以下幾行跟以前在 stop() 裡的一字不差，只是不在主執行緒上做
    private func closeSystem() {
        TestHook.delay("HEARBY_TEST_SYS_STOP_DELAY")
        if let s = stream {
            let sem = DispatchSemaphore(value: 0)
            s.stopCapture { _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 3)
            stream = nil
        }
        if aggregateID != 0 {
            if let pid = tapProcID { AudioDeviceStop(aggregateID, pid); AudioDeviceDestroyIOProcID(aggregateID, pid) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0; tapProcID = nil
        }
        if tapID != 0 {
            if #available(macOS 14.4, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = 0
        }
        if let pid = keepAliveProcID {
            AudioDeviceStop(keepAliveDevice, pid)
            AudioDeviceDestroyIOProcID(keepAliveDevice, pid)
            keepAliveProcID = nil
        }
        sysQueue.sync { self.sysFile?.close(); self.sysFile = nil }
    }
}
