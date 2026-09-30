// MicQueue — 麥克風這一軌的收音：AudioQueue 只開輸入裝置、完全不碰聲音輸出，
// 直接要 16 kHz 單聲道 s16（就是 mic.wav 的格式；裝置原生的取樣率由系統轉）。
//
// 為什麼不用 AVAudioEngine：engine.inputNode 一被碰到，就會去查「預設輸入＋預設輸出」組成的聚合裝置。
// 預設輸出（例如 DisplayPort 螢幕）的音訊卡住、系統音訊服務 coreaudiod 空轉時，這一查會卡死呼叫它的執行緒
// （inputNode → AVAudioIOUnit::GetHWFormat → AVAEHalUtil::GetSubDevices → HALC_ProxyObject::GetPropertyDataSize）；
// 先把 IO 單元綁到輸入裝置也擋不住，因為綁之前就得先拿到 inputNode。AudioQueue 只開輸入，同樣的狀態下照常約 0.2 秒開始錄。
//
// start／stop 還是會進系統音訊服務、還是可能卡住：一律在背景呼叫，呼叫端設等待上限（Bounded；見 DualRecorder）。
import AudioToolbox
import CoreAudio
import Foundation

final class MicQueue {
    /// 每格 100 ms、共 10 格：寫檔偶爾慢一下（每 5 秒回填一次表頭＋fsync）也有將近 1 秒的餘裕不掉音；停止時最多少最後一格
    static let bufferBytes: UInt32 = 3200
    static let bufferCount = 10

    private let cbQueue: DispatchQueue
    private let onPCM: (UnsafeBufferPointer<Int16>) -> Void
    private let lock = NSLock()
    private var queue: AudioQueueRef?
    private var stopped = false
    private var _device = AudioDeviceID(0)
    private var _deviceName = ""
    private var _lastBuffer = Date()

    /// onPCM 在 callbackQueue 上被叫，每次一格 16 kHz 單聲道 s16
    init(callbackQueue: DispatchQueue, onPCM: @escaping (UnsafeBufferPointer<Int16>) -> Void) {
        cbQueue = callbackQueue
        self.onPCM = onPCM
    }

    /// 開的那一刻的預設輸入（0＝問不到）與它的名字
    var device: AudioDeviceID { lock.withLock { _device } }
    var deviceName: String { lock.withLock { _deviceName } }
    /// 多久沒收到任何一格（暫停中照樣會收到，只是 DualRecorder 不寫）
    func silentFor(at now: Date) -> TimeInterval { lock.withLock { max(0, now.timeIntervalSince(_lastBuffer)) } }

    /// 綁這一刻的預設輸入並開始錄。會進系統音訊服務、可能卡住：只在背景呼叫
    func start() throws {
        TestHook.delay("HEARBY_TEST_MIC_START_DELAY")
        let t0 = Date()
        // 裝置先問好（這幾個查詢也會進系統音訊服務）；佇列起來之後只剩行程內的事
        let dev = AudioDevices.defaultInputID() ?? 0
        let uid = dev != 0 ? AudioDevices.uid(dev) : nil
        let name = (dev != 0 ? AudioDevices.name(dev) : nil) ?? ""
        var fmt = AudioStreamBasicDescription(
            mSampleRate: kSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var q: AudioQueueRef?
        var st = AudioQueueNewInputWithDispatchQueue(&q, &fmt, 0, cbQueue) { [weak self] aq, buf, _, _, _ in
            guard let self else { return }
            let live = self.lock.withLock { () -> Bool in
                if self.stopped { return false }
                self._lastBuffer = Date()
                return true
            }
            guard live else { return }  // 停了就不寫、也不再排回去
            let n = Int(buf.pointee.mAudioDataByteSize) / 2
            if n > 0 { self.onPCM(UnsafeBufferPointer(start: buf.pointee.mAudioData.assumingMemoryBound(to: Int16.self), count: n)) }
            AudioQueueEnqueueBuffer(aq, buf, 0, nil)
        }
        guard st == noErr, let q else { throw HearbyError("找不到麥克風輸入裝置（\(st)）") }
        // 綁在這一刻的預設輸入上：錄的就是畫面上寫的那一支。系統換預設麥克風時，DualRecorder 會重開一條跟過去
        var bind = "default"
        if var u = uid.map({ $0 as CFString }) {
            let s = withUnsafePointer(to: &u) {
                AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, $0, UInt32(MemoryLayout<CFString>.size))
            }
            bind = s == noErr ? "\(dev)" : "default(bind \(s))"
        }
        for _ in 0..<Self.bufferCount {
            var b: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(q, Self.bufferBytes, &b) == noErr, let b { AudioQueueEnqueueBuffer(q, b, 0, nil) }
        }
        st = AudioQueueStart(q, nil)
        guard st == noErr else {
            AudioQueueDispose(q, true)
            throw HearbyError("麥克風啟動失敗（\(st)）")
        }
        lock.lock()
        queue = q
        _device = dev
        _deviceName = name
        _lastBuffer = Date()
        let abandoned = stopped  // 呼叫端等不下去、已經放棄＝起來了也馬上關
        lock.unlock()
        HearbyLog.write(String(format: "rec mic dev=%@ bind=%@ aq 16k %.2fs", name.isEmpty ? "?" : name, bind, Date().timeIntervalSince(t0)))
        if abandoned {
            HearbyLog.write("rec mic started after the caller gave up → closed")
            stop()
        }
    }

    /// 停止並釋放。會進系統音訊服務、可能卡住：只在背景呼叫（呼叫端設上限）；不可在 callbackQueue 上呼叫
    func stop() {
        lock.lock()
        stopped = true  // 先擋住：還在路上的那幾格不再寫（換裝置時新舊兩條不會交錯寫進同一個檔）
        let q = queue
        queue = nil
        lock.unlock()
        guard let q else { return }
        let t0 = Date()
        TestHook.delay("HEARBY_TEST_MIC_STOP_DELAY")
        AudioQueueStop(q, true)
        cbQueue.sync {}  // 等還在跑的那一格回呼收完，再釋放
        AudioQueueDispose(q, true)
        let secs = Date().timeIntervalSince(t0)
        if secs > 1 { HearbyLog.write(String(format: "rec mic queue closed after %.1fs（系統音訊服務慢）", secs)) }
    }

    /// 呼叫端不等了：還沒起來＝起來後馬上關；已經起來＝在背景關
    func abandon() {
        lock.lock()
        stopped = true
        let running = queue != nil
        lock.unlock()
        if running { DispatchQueue.global(qos: .utility).async { self.stop() } }
    }

    /// 開發用：這一條不再送任何一格（裝置被拔、系統音訊服務重啟之後的樣子），測「卡住就重開」
    func pauseForTesting() {
        guard let q = lock.withLock({ queue }) else { return }
        AudioQueuePause(q)
    }
}

/// 測試鉤（TESTING.md「怎麼驗」）：環境變數給秒數，模擬系統音訊服務卡住（麥克風開／關、系統聲收尾各慢幾秒）
enum TestHook {
    static func delay(_ key: String) {
        guard let s = ProcessInfo.processInfo.environment[key].flatMap(Double.init), s > 0 else { return }
        Thread.sleep(forTimeInterval: s)
    }
}

/// 在背景跑、最多等 timeout 秒：回 nil＝逾時（工作照樣在背景跑完，結果丟掉）。
/// 給「可能卡在系統音訊服務裡」的呼叫用：等的那一方（主執行緒、micCtl）不陪著卡
enum Bounded {
    static func run<T>(_ timeout: TimeInterval, _ work: @escaping () throws -> T) -> Result<T, Error>? {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = Result { try work() }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }
}

private final class ResultBox<T> {
    private let lock = NSLock()
    private var _value: Result<T, Error>?
    var value: Result<T, Error>? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
