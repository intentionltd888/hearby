// DualRecorder — 雙軌錄音（介面層切割：睡眠通知改由殼呼叫 noteSleep／noteWake）
//   軌 1（房間裡）：麥克風 AVAudioEngine → mic.wav；IO 單元直接綁在預設輸入裝置上，不經過聲音輸出（見 bindMicToDefaultInput）
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
    private let engine = AVAudioEngine()
    private var stream: SCStream?
    private var micConverter: AVAudioConverter?
    private let micOutFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: kSampleRate, channels: 1, interleaved: false)!
    private let sysQueue = DispatchQueue(label: "hearby.sysaudio")
    private var _stopping = false
    private var isStopping: Bool { levelLock.withLock { _stopping } }
    private var sysConverter: AVAudioConverter?
    private var sysConverterInFormat: AVAudioFormat?
    private var micConverterInFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?
    private var micDeviceID = AudioDeviceID(0)  // IO 單元現在綁著的輸入裝置；0＝沒綁上（走系統的聚合裝置）
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    public private(set) var micInterrupted = false
    public private(set) var micDead = false
    public var micRecovered = false
    private var retapAttempts = 0
    private var retryInFlight = false

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

    public private(set) var startedAt = Date()
    public private(set) var systemAudioActive = false

    private var _micWriteFailures = 0
    private var _sysWriteFailures = 0
    public var writeFailures: Int { levelLock.withLock { _micWriteFailures + _sysWriteFailures } }

    // 睡眠扣除（殼負責通知）
    private var sleepBegan: Date?
    private var _sleepSeconds: TimeInterval = 0
    public var sleepSeconds: TimeInterval { levelLock.withLock { _sleepSeconds } }
    public private(set) var sleptWhileRecording = false
    public func noteSleep() { levelLock.withLock { if sleepBegan == nil { sleepBegan = Date() } } }
    public func noteWake() {
        levelLock.withLock {
            if let b = sleepBegan {
                _sleepSeconds += Date().timeIntervalSince(b)
                sleepBegan = nil
                sleptWhileRecording = true
            }
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
        startedAt = Date()  // mic.wav 從這裡開始；系統聲音那軌起不來時可能要等約 10 秒，計時不能從那之後才算
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

    private func startMic() throws {
        let t0 = Date()
        do {
            micFile = try CrashSafeWavWriter(url: dir.appendingPathComponent("mic.wav"))
            try installMicTapAndStart()
        } catch {
            // 畫面只給一句話；原始錯誤與花了多久記在這裡（裝置卡住的樣子＝等約 10 秒後回 'stop'）
            HearbyLog.write(String(format: "rec mic start fail %.1fs: ", Date().timeIntervalSince(t0)) + "\(error)")
            throw error
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in DispatchQueue.main.async { self?.handleEngineConfigChange() } }
        // IO 單元綁在固定裝置上之後，系統換預設麥克風（插拔耳機、在控制中心換）engine 不會自己跟；由這裡接手，照舊跟著預設走
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handleDefaultInputChange() }
        var addr = AudioDevices.defaultInputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener) == noErr {
            defaultInputListener = listener
        }
    }

    private func installMicTapAndStart() throws {
        let input = engine.inputNode
        let bound = bindMicToDefaultInput()
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw HearbyError("找不到麥克風輸入裝置") }
        HearbyLog.write("rec mic dev=\(AudioDevices.defaultInputName() ?? "?") bind=\(bound) sr=\(Int(inFormat.sampleRate)) ch=\(inFormat.channelCount)")
        micConverter = AVAudioConverter(from: inFormat, to: micOutFormat)
        micConverterInFormat = inFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            guard let self, !self.isStopping, let file = self.micFile else { return }
            if self.micConverterInFormat != buf.format {
                self.micConverter = AVAudioConverter(from: buf.format, to: self.micOutFormat)
                self.micConverterInFormat = buf.format
            }
            guard let conv = self.micConverter else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * kSampleRate / buf.format.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: self.micOutFormat, frameCapacity: cap) else { return }
            var consumed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buf
            }
            if out.frameLength > 0 {
                self.setMic(rmsLevel(out))
                if !file.write(out) { self.levelLock.withLock { self._micWriteFailures += 1 } }
            }
        }
        try engine.start()
    }

    private func handleEngineConfigChange(_ why: String = "config change") {
        guard !isStopping else { return }
        // 綁裝置這個動作本身也會讓 engine 發一次設定變更，而且晚一點才送到（開錄後約 0.1 秒）。
        // engine 真的因硬體變更停下來時 isRunning 已經是 false；還在跑、綁的也還是預設麥克風＝沒有要接的，重接反而白白斷一截
        if engine.isRunning, micDeviceID != 0, micDeviceID == AudioDevices.defaultInputID() {
            HearbyLog.write("rec mic \(why) ignored: still running on dev \(micDeviceID)")
            return
        }
        micInterrupted = true
        HearbyLog.write("rec mic \(why) → dev=\(AudioDevices.defaultInputName() ?? "?")")
        guard !retryInFlight else { return }
        retryInFlight = true
        retapAttempts = 0
        attemptRetap()
    }

    private func handleDefaultInputChange() {
        guard !isStopping, AudioDevices.defaultInputID() != micDeviceID else { return }
        handleEngineConfigChange("default input change")
    }

    private func attemptRetap() {
        guard !isStopping else { retryInFlight = false; return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()  // 預設麥克風換了的時候 engine 還在舊裝置上跑，換綁前先停
        setMic(0)
        do {
            try installMicTapAndStart()
            retryInFlight = false
            if micDead { micDead = false; micRecovered = true }
        } catch {
            retapAttempts += 1
            HearbyLog.write("rec mic retap fail #\(retapAttempts): \(error)")
            if retapAttempts <= 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.attemptRetap() }
            } else {
                retryInFlight = false
                micDead = true
                HearbyLog.write("rec mic dead after 10 retries: \(error.localizedDescription)")
            }
        }
    }

    /// 麥克風這一軌不經過聲音輸出：AVAudioEngine 預設把「預設輸入＋預設輸出」組成一顆私有聚合裝置一起啟動，
    /// 預設輸出（例如 DisplayPort 螢幕）的音訊卡住時，啟動要等約 10 秒後回 'stop'，麥克風好好的也錄不到。
    /// 這一軌用不到輸出，所以把 IO 單元直接綁在這一刻的預設輸入裝置上（系統聲音那一軌是另一條路，不經過這裡）。
    /// 已經綁在同一顆就不重設。回傳給 log 看的裝置代號；綁不上＝照舊走系統的聚合裝置。
    private func bindMicToDefaultInput() -> String {
        guard let dev = AudioDevices.defaultInputID(), let unit = engine.inputNode.audioUnit else {
            micDeviceID = 0
            return "default"
        }
        var cur = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &size) == noErr, cur == dev {
            micDeviceID = dev
            return "\(dev)"
        }
        var id = dev
        let st = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        micDeviceID = st == noErr ? dev : 0
        return st == noErr ? "\(dev)" : "default(bind \(st))"
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
            guard let self, !self.isStopping, let file = self.sysFile, let fmt = self.tapFormat else { return }
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
        guard type == .audio, !isStopping, sampleBuffer.isValid, let file = sysFile else { return }
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

    /// 停止並 finalize；回傳實錄秒數（已扣除睡眠時間）
    public func stop() -> TimeInterval {
        levelLock.withLock { _stopping = true }
        levelLock.withLock {
            if let b = sleepBegan { _sleepSeconds += Date().timeIntervalSince(b); sleepBegan = nil }
        }
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        if let l = defaultInputListener {
            var addr = AudioDevices.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, l)
            defaultInputListener = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        setMic(0); setSys(0)
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
        micFile?.close(); micFile = nil
        sysQueue.sync { self.sysFile?.close(); self.sysFile = nil }
        return max(0, Date().timeIntervalSince(startedAt) - sleepSeconds)
    }
}
