// Install／Login — 在 app 裡直接裝與登入 Claude Code／Codex（不開終端機、不收帳密）
import AppKit
import Foundation
import HearbyCore

public enum Connect {
    /// pipefail：下載失敗時整條管線要回非 0（不然 curl 失敗、bash 讀到空輸入照樣 exit 0，畫面會寫「安裝沒成功（exit 0）」）
    public static var claudeInstallCommand: String { "set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash" }
    /// 選用某顆整理方式：寫設定＋標記使用者選過
    public static func select(_ id: String) {
        try? ConfigStore.shared.update { $0.provider = id; $0.providerChosen = true }
        ClaudeCLI.resetAuthCache(); CodexCLI.resetLoginCache()
        HearbyLog.write("provider select → \(id)")
    }
    /// 打開終端機執行（.command 檔，不需自動化權限）
    @discardableResult
    public static func runInTerminal(_ command: String, banner: String = "照著下面的指示做，做完可以關掉這個視窗") -> Bool {
        let dir = Paths.support.appendingPathComponent("terminal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("hearby-\(Int(Date().timeIntervalSince1970)).command")
        let script = "#!/bin/zsh\nclear\necho \(EntryFiles.shellQuote("── Hearby：\(banner) ──"))\n\(command)\n"
        guard (try? script.write(to: f, atomically: true, encoding: .utf8)) != nil else { return false }
        chmod(f.path, 0o755)
        return NSWorkspace.shared.open(f)
    }
    public static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

public final class ClaudeInstall: ObservableObject {
    public static let shared = ClaudeInstall()
    @Published public var running = false
    @Published public var failed = false
    @Published public var succeeded = false
    @Published public var note = ""
    private var process: Process?
    private var outPipe: Pipe?
    private var buffer = ""
    private var startedAt = Date()

    @discardableResult
    public func start() -> Bool {
        if running { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", Connect.claudeInstallCommand]
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
        env["HOME"] = NSHomeDirectory()
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env
        p.currentDirectoryURL = ClaudeCLI.neutralCwd()
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(s) }
        }
        p.terminationHandler = { [weak self] proc in DispatchQueue.main.async { self?.ended(status: proc.terminationStatus) } }
        do { try p.run() } catch { HearbyLog.write("claude install spawn fail: \(error.localizedDescription)"); return false }
        process = p; outPipe = out; buffer = ""
        running = true; failed = false; succeeded = false; startedAt = Date()
        note = "正在下載並安裝 Claude Code（通常 1 分鐘內，看網路）…"
        HearbyLog.write("claude install start")
        return true
    }
    private func consume(_ s: String) {
        buffer += s
        let lines = buffer.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { $0.trimmingCharacters(in: .whitespaces) }
        if let last = lines.last(where: { !$0.isEmpty && !$0.contains("%") && !$0.hasPrefix("#") }) { note = "安裝中：" + String(last.prefix(90)) }
    }
    private func ended(status: Int32) {
        outPipe?.fileHandleForReading.readabilityHandler = nil
        outPipe = nil; process = nil; running = false
        ClaudeCLI.resetAuthCache()
        let ok = status == 0 && ClaudeCLI.binaryPath() != nil
        succeeded = ok; failed = !ok
        let secs = Int(Date().timeIntervalSince(startedAt))
        if ok {
            note = "Claude Code 裝好了（\(secs) 秒）。接著登入你的 Claude："
            HearbyLog.write("claude install ok \(secs)s")
            ClaudeLogin.shared.start()
        } else {
            let tail = buffer.split(separator: "\n").suffix(3).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " / ")
            note = "安裝沒成功（exit \(status)）：\(String(tail.prefix(200)))。再按一次「安裝」；還是不行就用「複製指令」貼到終端機。"
            HearbyLog.write("claude install fail exit=\(status)")
        }
    }
    public func cancel() { if let p = process, p.isRunning { p.terminate() }; note = "已取消。"; running = false; failed = false }
}

public final class ClaudeLogin: ObservableObject {
    public static let shared = ClaudeLogin()
    @Published public var running = false
    @Published public var needsCode = false
    @Published public var url: String?
    @Published public var note = ""
    @Published public var succeeded = false
    private var process: Process?
    private var inPipe: Pipe?
    private var outBuffer = ""
    private var poll: Timer?
    private var startedAt = Date()

    @discardableResult
    public func start() -> Bool {
        if running { return true }
        guard let bin = ClaudeCLI.binaryPath() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["auth", "login"]
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
        env.removeValue(forKey: "BROWSER")
        p.environment = env
        p.currentDirectoryURL = ClaudeCLI.neutralCwd()
        let inP = Pipe(), outP = Pipe()
        p.standardInput = inP; p.standardOutput = outP; p.standardError = outP
        outP.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(s) }
        }
        p.terminationHandler = { [weak self] proc in DispatchQueue.main.async { self?.processEnded(status: proc.terminationStatus) } }
        do { try p.run() } catch { HearbyLog.write("claude login spawn fail: \(error.localizedDescription)"); return false }
        process = p; inPipe = inP; outBuffer = ""; url = nil; needsCode = false; succeeded = false; running = true; startedAt = Date()
        note = "瀏覽器會打開 Claude 的登入頁：用你的 Claude 帳號登入並按「允許」。"
        HearbyLog.write("claude login start")
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkStatus() }
        return true
    }
    private func consume(_ s: String) {
        outBuffer += s
        if url == nil, let r = outBuffer.range(of: "https://") {
            let tail = outBuffer[r.lowerBound...]
            let end = tail.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\r" }) ?? tail.endIndex
            url = String(tail[..<end])
        }
        if outBuffer.contains("Paste code"), !needsCode {
            needsCode = true
            note = "登入後網頁會給你一串代碼：複製它，貼到下面那格按「送出」。（有些情況登入完會自動接上，不用貼）"
        }
        let low = outBuffer.lowercased()
        if low.contains("error") || low.contains("failed") {
            if let l = outBuffer.split(separator: "\n").last(where: { $0.lowercased().contains("error") || $0.lowercased().contains("fail") }) { note = "登入沒成功：\(String(l).prefix(160))。可以再按一次「登入」。" }
        }
    }
    public func submit(code: String) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, let h = inPipe?.fileHandleForWriting else { return }
        // 登入行程已經結束時寫 pipe 會失敗：舊式 write 會丟例外當機，這裡改成說一聲
        do { try h.write(contentsOf: Data((c + "\n").utf8)); note = "代碼已送出，確認中…" }
        catch { note = "登入視窗已經關閉，請重新按一次登入" }
    }
    public func openBrowserAgain() { if let u = url, let x = URL(string: u) { NSWorkspace.shared.open(x) } }
    private func checkStatus() {
        guard running else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let st = ClaudeCLI.authStatus(force: true)
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                if st?.loggedIn == true { self.finish(ok: true) }
                else if Date().timeIntervalSince(self.startedAt) > 600 { self.note = "等了 10 分鐘還沒登入，先取消；要再試就再按一次「登入」。"; self.finish(ok: false) }
            }
        }
    }
    private func processEnded(status: Int32) {
        guard running else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let st = ClaudeCLI.authStatus(force: true)
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                if st?.loggedIn == true { self.finish(ok: true) }
                else { self.note = status == 0 ? "CLI 說完成了，但還沒看到登入狀態；再按一次「重新檢查」看看。" : "登入沒完成（exit \(status)）。再按一次「登入」。"; self.finish(ok: false) }
            }
        }
    }
    private func finish(ok: Bool) {
        poll?.invalidate(); poll = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        try? inPipe?.fileHandleForWriting.close(); inPipe = nil
        running = false; needsCode = false; succeeded = ok
        if ok {
            note = "登入成功，已接上你的 Claude。"
            HearbyLog.write("claude login ok → select claude")
            Connect.select("claude")
        }
    }
    public func cancel() { note = "已取消。"; finish(ok: false) }
}

public final class CodexInstall: NSObject, ObservableObject, URLSessionDownloadDelegate {
    public static let shared = CodexInstall()
    public static var releaseURL: URL { URL(string: "https://github.com/openai/codex/releases/latest/download/codex-aarch64-apple-darwin.tar.gz")! }
    static var installDir: URL { Paths.support.appendingPathComponent("bin", isDirectory: true) }
    @Published public var running = false
    @Published public var failed = false
    @Published public var succeeded = false
    @Published public var fraction: Double = 0
    @Published public var note = ""
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var startedAt = Date()

    @discardableResult
    public func start() -> Bool {
        if running { return true }
        running = true; failed = false; succeeded = false; fraction = 0; startedAt = Date()
        note = "正在下載 ChatGPT 的 Codex（約 90MB，看網路 1–3 分鐘）…"
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        let t = s.downloadTask(with: Self.releaseURL)
        task = t; t.resume()
        HearbyLog.write("codex install start")
        return true
    }
    public func cancel() { task?.cancel(); task = nil; running = false; failed = false; note = "已取消。" }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let f = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.fraction = f; self.note = String(format: "下載中 %.0f%%", f * 100) }
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 404／403 的回應也會「下載成功」（拿到的是一頁 HTML）：先看狀態碼，不要讓它走到解壓才報一句看不懂的錯
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            finish(false, "下載失敗（伺服器回 \(http.statusCode)）。可能是官方的檔名改了——先用 ChatGPT 桌面版自帶的，或晚點再試。"); return
        }
        let fm = FileManager.default
        let dir = Self.installDir
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tgz = dir.appendingPathComponent("codex.tar.gz")
        do {
            if fm.fileExists(atPath: tgz.path) { _ = try fm.replaceItemAt(tgz, withItemAt: location) } else { try fm.moveItem(at: location, to: tgz) }
        } catch { finish(false, "存檔失敗：\(error.localizedDescription)"); return }
        let r = runProcess("/usr/bin/tar", ["-xzf", tgz.path, "-C", dir.path], timeout: 120)
        guard r.status == 0 else { finish(false, "解壓失敗（tar exit \(r.status)）"); return }
        let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let final = dir.appendingPathComponent("codex")
        if let name = items.first(where: { $0.hasPrefix("codex-") && !$0.hasSuffix(".gz") }) {
            let src = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: final.path) { _ = try? fm.replaceItemAt(final, withItemAt: src) } else { try? fm.moveItem(at: src, to: final) }
        }
        guard fm.fileExists(atPath: final.path) else { finish(false, "壓縮檔裡找不到 codex"); return }
        chmod(final.path, 0o755)
        _ = runProcess("/usr/bin/xattr", ["-d", "com.apple.quarantine", final.path], timeout: 10)
        let v = runProcess(final.path, ["--version"], timeout: 20)
        guard v.status == 0 else { finish(false, "codex 跑不起來（exit \(v.status)）"); return }
        finish(true, "Codex 裝好了（\(v.stdout.trimmingCharacters(in: .whitespacesAndNewlines))，\(Int(Date().timeIntervalSince(startedAt))) 秒）。接著登入你的 ChatGPT：")
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error as NSError?, e.code != NSURLErrorCancelled { finish(false, "下載失敗：\(e.localizedDescription)") }
    }
    private func finish(_ ok: Bool, _ msg: String) {
        DispatchQueue.main.async {
            self.running = false; self.succeeded = ok; self.failed = !ok; self.note = msg; self.task = nil
            HearbyLog.write("codex install \(ok ? "ok" : "fail"): \(msg)")
            if ok { CodexCLI.resetLoginCache(); CodexLogin.shared.start() }
        }
    }
}

public final class CodexLogin: ObservableObject {
    public static let shared = CodexLogin()
    @Published public var running = false
    @Published public var url: String?
    @Published public var note = ""
    @Published public var succeeded = false
    private var process: Process?
    private var outPipe: Pipe?
    private var buffer = ""
    private var poll: Timer?
    private var startedAt = Date()

    @discardableResult
    public func start() -> Bool {
        if running { return true }
        guard let bin = CodexCLI.binaryPath() else { return false }
        // 已登入的機器絕不再跑 codex login（會先把人登出）
        if CodexCLI.loggedIn(force: true) == true { note = "已經登入了。"; succeeded = true; Connect.select("codex"); return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["login"]
        p.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("OPENAI") && !$0.key.hasPrefix("CODEX") }
        p.currentDirectoryURL = CodexCLI.neutralCwd()
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(s) }
        }
        p.terminationHandler = { [weak self] proc in DispatchQueue.main.async { self?.ended(proc.terminationStatus) } }
        do { try p.run() } catch { HearbyLog.write("codex login spawn fail: \(error.localizedDescription)"); return false }
        process = p; outPipe = out; buffer = ""; url = nil; succeeded = false; running = true; startedAt = Date()
        note = "瀏覽器會打開 ChatGPT 的登入頁：登入你的帳號、按「允許」，回來這裡會自動接上。"
        HearbyLog.write("codex login start")
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
        return true
    }
    private func consume(_ s: String) {
        buffer += s
        if url == nil, let r = buffer.range(of: "https://") {
            let tail = buffer[r.lowerBound...]
            let end = tail.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\r" }) ?? tail.endIndex
            url = String(tail[..<end])
        }
    }
    private func check() {
        guard running else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = CodexCLI.loggedIn(force: true) == true
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                if ok { self.finish(true) } else if Date().timeIntervalSince(self.startedAt) > 600 { self.note = "等了 10 分鐘還沒登入，先取消；要再試就再按一次「登入」。"; self.finish(false) }
            }
        }
    }
    private func ended(_ status: Int32) {
        guard running else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = CodexCLI.loggedIn(force: true) == true
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                if ok { self.finish(true) } else { self.note = "登入沒完成（exit \(status)）。再按一次「登入」。"; self.finish(false) }
            }
        }
    }
    private func finish(_ ok: Bool) {
        poll?.invalidate(); poll = nil
        outPipe?.fileHandleForReading.readabilityHandler = nil; outPipe = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil; running = false; succeeded = ok
        if ok { note = "登入成功，已接上你的 ChatGPT。"; HearbyLog.write("codex login ok → select codex"); CodexCLI.resetLoginCache(); Connect.select("codex") }
    }
    public func openBrowserAgain() { if let u = url, let x = URL(string: u) { NSWorkspace.shared.open(x) } }
    public func cancel() { note = "已取消。"; finish(false) }
}
