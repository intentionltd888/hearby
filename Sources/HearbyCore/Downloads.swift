// Downloads — 聽打模型下載（可續傳、會校驗；來源＝官方 Hugging Face 主源＋選填鏡像）
import CryptoKit
import Foundation

public enum ModelCatalog {
    public struct Spec {
        public let id: String
        public var file: String
        public var bytes: Int64
        public var sha256: String?
        public var urls: [URL]
    }
    public static var whisper = Spec(
        id: "whisper", file: "ggml-large-v3-turbo.bin", bytes: 1_624_555_275,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        urls: [URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!])

    /// 來源順序：使用者設定的鏡像（選填）→ 官方
    public static func sources(_ s: Spec) -> [URL] {
        var out: [URL] = []
        if let m = ConfigStore.shared.current.modelMirror, let u = URL(string: m.hasSuffix("/") ? m + s.file : m + "/" + s.file) { out.append(u) }
        out += s.urls
        return out
    }
}

public final class ModelDownload: NSObject, URLSessionDataDelegate {
    public enum Phase: Equatable { case downloading, verifying, done, failed(String) }
    public let spec: ModelCatalog.Spec
    public let dest: URL
    private let sources: [URL]
    private let done: (Result<String, Error>) -> Void
    public static var stallSeconds: TimeInterval = 45
    public static var maxRounds = 6
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var out: FileHandle?
    private var offset: Int64 = 0
    private var round = 1
    private var sourceIndex = 0
    private var finished = false
    private var cancelledByUser = false
    private var lastReason = "未知錯誤"
    private var watchdog: DispatchSourceTimer?
    private let lock = NSLock()
    private var lastActivity = Date()
    private var pendingFailReason: String?
    private var verifyOnCancel = false
    public private(set) var fraction: Double = 0
    public private(set) var phase: Phase = .downloading
    public private(set) var bytesWritten: Int64 = 0
    private static var workDir: URL { Paths.support.appendingPathComponent("downloads", isDirectory: true) }
    private var partFile: URL { Self.workDir.appendingPathComponent(spec.file + ".part") }

    @discardableResult
    public static func start(_ spec: ModelCatalog.Spec, done: @escaping (Result<String, Error>) -> Void) -> ModelDownload {
        let d = ModelDownload(spec: spec, done: done)
        d.begin()
        return d
    }
    private init(spec: ModelCatalog.Spec, done: @escaping (Result<String, Error>) -> Void) {
        self.spec = spec
        self.dest = Paths.support.appendingPathComponent("models/\(spec.file)")
        self.sources = ModelCatalog.sources(spec)
        self.done = done
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 6 * 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = true
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
    }
    private func begin() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.workDir, withIntermediateDirectories: true)
        if let msg = Self.diskShortfallMessage(need: spec.bytes) { finish(.failure(HearbyError(msg))); return }
        if !fm.fileExists(atPath: partFile.path) { fm.createFile(atPath: partFile.path, contents: nil) }
        offset = (try? fm.attributesOfItem(atPath: partFile.path))?[.size] as? Int64 ?? 0
        if spec.bytes <= 0 || offset > spec.bytes { offset = 0 }
        guard let h = try? FileHandle(forWritingTo: partFile) else { finish(.failure(HearbyError("無法寫入下載暫存檔"))); return }
        out = h
        try? h.truncate(atOffset: UInt64(offset)); _ = try? h.seekToEnd()
        bytesWritten = offset
        if spec.bytes > 0 { fraction = min(0.999, Double(offset) / Double(spec.bytes)) }
        startWatchdog()
        attempt()
    }
    private func attempt() {
        guard !finished, !cancelledByUser else { return }
        let url = sources[sourceIndex]
        lock.withLock { lastActivity = Date(); pendingFailReason = nil; verifyOnCancel = false }
        var req = URLRequest(url: url)
        req.setValue("Hearby/\(HearbyVersion.build)", forHTTPHeaderField: "User-Agent")
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        HearbyLog.write("download attempt r\(round) s#\(sourceIndex) \(url.host ?? "?") offset=\(offset / 1_048_576)MB")
        task = session.dataTask(with: req)
        task?.resume()
    }
    private func attemptFailed(_ reason: String) {
        guard !finished, !cancelledByUser else { return }
        HearbyLog.write("download fail r\(round) s#\(sourceIndex): \(reason)")
        lastReason = reason
        sourceIndex += 1
        if sourceIndex < sources.count { attempt(); return }
        sourceIndex = 0; round += 1
        guard round <= Self.maxRounds else {
            finish(.failure(HearbyError("下載失敗：所有來源輪流試了 \(Self.maxRounds) 輪（最後原因：\(lastReason)）。已下載的部分有保留，按重試會從斷點接續")))
            return
        }
        let delay = min(30.0, pow(2, Double(round - 1)))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in self?.attempt() }
    }
    public func cancel() { cancelledByUser = true; task?.cancel(); watchdog?.cancel(); try? out?.synchronize() }
    private func truncatePart() { try? out?.truncate(atOffset: 0); offset = 0; bytesWritten = 0; fraction = 0 }
    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self, !self.finished, !self.cancelledByUser, let task = self.task, task.state == .running else { return }
            let stalled: Bool = self.lock.withLock { Date().timeIntervalSince(self.lastActivity) > Self.stallSeconds }
            guard stalled else { return }
            self.lock.withLock { self.pendingFailReason = "來源停滯（\(Int(Self.stallSeconds)) 秒沒有任何資料）" }
            task.cancel()
        }
        t.activate()
        watchdog = t
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !finished else { return completionHandler(.cancel) }
        lock.withLock { lastActivity = Date() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 206:
            let cr = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")) ?? ""
            let start = Int64(cr.dropFirst("bytes ".count).split(separator: "-").first.map(String.init) ?? "") ?? -1
            if start != offset { truncatePart(); lock.withLock { pendingFailReason = "續傳起點不符" }; return completionHandler(.cancel) }
            completionHandler(.allow)
        case 200:
            if offset > 0 { truncatePart() }
            completionHandler(.allow)
        case 416:
            if spec.bytes > 0, offset >= spec.bytes { lock.withLock { verifyOnCancel = true } } else { truncatePart(); lock.withLock { pendingFailReason = "伺服器回應 416" } }
            completionHandler(.cancel)
        default:
            lock.withLock { pendingFailReason = "伺服器回應 \(status)" }
            completionHandler(.cancel)
        }
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, let out else { return }
        lock.withLock { lastActivity = Date() }
        do { try out.write(contentsOf: data) } catch { lock.withLock { pendingFailReason = "寫入失敗：\(error.localizedDescription)" }; dataTask.cancel(); return }
        offset += Int64(data.count)
        bytesWritten = offset
        if spec.bytes > 0 {
            if offset > spec.bytes { truncatePart(); lock.withLock { pendingFailReason = "內容超出預期大小（來源給錯檔）" }; dataTask.cancel(); return }
            fraction = min(0.999, Double(offset) / Double(spec.bytes))
        }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let error {
            if cancelledByUser { return }
            let (reason, verify): (String?, Bool) = lock.withLock { (pendingFailReason, verifyOnCancel) }
            if verify { return verifyAndFinish() }
            if let reason { return attemptFailed(reason) }
            return attemptFailed((error as NSError).localizedDescription)
        }
        if spec.bytes > 0, offset != spec.bytes { return attemptFailed("下載中斷（收到 \(offset / 1_048_576)MB／應為 \(spec.bytes / 1_048_576)MB）") }
        verifyAndFinish()
    }
    private func verifyAndFinish() {
        guard !finished else { return }
        phase = .verifying
        try? out?.synchronize(); try? out?.close(); out = nil
        let size = (try? FileManager.default.attributesOfItem(atPath: partFile.path))?[.size] as? Int64 ?? 0
        if spec.bytes > 0, size != spec.bytes { reopen(); return attemptFailed("下載不完整") }
        if let want = spec.sha256, Self.sha256(of: partFile) != want {   // 算不出來（nil）也算不符
            try? FileManager.default.removeItem(at: partFile); reopen()
            return attemptFailed("檔案校驗失敗（內容與官方不符），已丟棄重抓")
        }
        do { _ = try FileManager.default.replaceItemAt(dest, withItemAt: partFile) } catch { finish(.failure(HearbyError("寫入模型檔失敗：\(error.localizedDescription)"))); return }
        fraction = 1; phase = .done
        HearbyLog.write("download done \(spec.file) \(size) bytes")
        finish(.success(dest.path))
    }
    private func reopen() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: partFile.path) { fm.createFile(atPath: partFile.path, contents: nil) }
        out = try? FileHandle(forWritingTo: partFile)
        try? out?.truncate(atOffset: 0)
        offset = 0; bytesWritten = 0; fraction = 0; phase = .downloading
    }
    private func finish(_ r: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        watchdog?.cancel(); try? out?.close(); out = nil
        if case .failure(let e) = r { phase = .failed(e.localizedDescription) }
        session.finishTasksAndInvalidate()
        done(r)
    }
    public static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: { let c = h.readData(ofLength: 4 * 1_048_576); if c.isEmpty { return false }; hasher.update(data: c); return true }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func diskShortfallMessage(need: Int64) -> String? {
        let url = Paths.support
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage else { return nil }
        let want = need + 500 * 1_048_576
        guard free < want else { return nil }
        let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1_000_000_000) }
        return "磁碟空間不足：這顆模型需要約 \(gb(need))，目前只剩 \(gb(free))。請清出空間後再試"
    }
}
