// Process — 跑子行程收 stdout/stderr（有逾時）；整個引擎共用
import Foundation

public struct RunResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    /// 是不是被逾時收掉的（不要再從結束碼與輸出去猜）
    public var timedOut = false
}

/// 從 Finder 啟動的 app，PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin。npm 裝的 claude／codex 是 `#!/usr/bin/env node` 腳本，
/// 找不到 node 就是 exit 127（`env: node: No such file or directory`）。子行程一律補上常見的安裝位置與執行檔自己的目錄。
public enum ChildEnv {
    public static func path(for launchPath: String, base: String?) -> String {
        let home = NSHomeDirectory()
        let real = URL(fileURLWithPath: launchPath).resolvingSymlinksInPath().path
        var dirs = [(launchPath as NSString).deletingLastPathComponent, (real as NSString).deletingLastPathComponent,
                    "/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.volta/bin", home + "/.bun/bin",
                    home + "/.npm-global/bin", home + "/Library/pnpm", home + "/.yarn/bin", home + "/.asdf/shims", home + "/.local/share/mise/shims"]
        // nvm：取版本號最大的那個 node
        let nvm = home + "/.nvm/versions/node"
        if let vs = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            let best = vs.filter { $0.hasPrefix("v") }.max { $0.compare($1, options: .numeric) == .orderedAscending }
            if let best { dirs.append("\(nvm)/\(best)/bin") }
        }
        dirs += (base ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }
}

/// 正在跑的子行程。app 要結束時一起收掉，不留孤兒（卡住的 CLI、跑到一半的 whisper 會一直佔著資源）。
public enum RunningChildren {
    private static let lock = NSLock()
    private static var procs: [ObjectIdentifier: Process] = [:]
    static func add(_ p: Process) { lock.lock(); procs[ObjectIdentifier(p)] = p; lock.unlock() }
    static func remove(_ p: Process) { lock.lock(); procs[ObjectIdentifier(p)] = nil; lock.unlock() }
    public static func terminateAll() {
        lock.lock(); let all = Array(procs.values); lock.unlock()
        for p in all where p.isRunning { p.terminate() }
    }
}

public struct HearbyError: LocalizedError {
    public let msg: String
    public init(_ m: String) { msg = m }
    public var errorDescription: String? { msg }
}

/// 子行程在讀完 stdin 前就結束時，往它的 pipe 寫會收到 SIGPIPE——預設動作是殺掉整個 app、沒有任何訊息，
/// `try?` 擋不住。忽略之後 write 改成丟 EPIPE，照一般錯誤處理。整個行程只設一次。
private let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

@discardableResult
public func runProcess(
    _ launchPath: String, _ args: [String], stdin: String? = nil,
    env: [String: String]? = nil, timeout: TimeInterval = 600, cwd: String? = nil
) -> RunResult {
    _ = ignoreSIGPIPE
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    var e = ProcessInfo.processInfo.environment
    if let env { for (k, v) in env { e[k] = v } }
    // 從某些終端環境啟動 app 時會繼承宿主的變數，子行程等宿主授權＝永久卡住
    for k in e.keys where k.hasPrefix("CLAUDE") || k.hasPrefix("ANTHROPIC") { e.removeValue(forKey: k) }
    e["PATH"] = ChildEnv.path(for: launchPath, base: e["PATH"])
    p.environment = e
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    var outData = Data()
    var errData = Data()
    let ioQueue = DispatchQueue(label: "hearby.proc.io")
    let eofGroup = DispatchGroup()
    eofGroup.enter()
    outPipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        if d.isEmpty { h.readabilityHandler = nil; eofGroup.leave(); return }
        ioQueue.sync { outData.append(d) }
    }
    eofGroup.enter()
    errPipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        if d.isEmpty { h.readabilityHandler = nil; eofGroup.leave(); return }
        ioQueue.sync { errData.append(d) }
    }
    let inPipe: Pipe? = stdin == nil ? nil : Pipe()
    p.standardInput = inPipe ?? FileHandle.nullDevice
    do { try p.run() } catch { return RunResult(status: -1, stdout: "", stderr: "\(error)") }
    // 逾時要在寫 stdin「之前」掛上：子行程活著卻不讀 stdin 時 write 會一直卡住，逾時就永遠不會啟動。
    // SIGTERM 不理的，5 秒後 SIGKILL。
    RunningChildren.add(p)
    defer { RunningChildren.remove(p) }
    var didTimeOut = false
    let killer = DispatchWorkItem {
        guard p.isRunning else { return }
        ioQueue.sync { didTimeOut = true }
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    if let stdin, let inPipe {
        // 背景寫：大輸入超過 pipe 緩衝時不擋住這條執行緒；子行程先走了就是 EPIPE，安靜結束
        let data = stdin.data(using: .utf8) ?? Data()
        DispatchQueue.global(qos: .userInitiated).async {
            try? inPipe.fileHandleForWriting.write(contentsOf: data)
            try? inPipe.fileHandleForWriting.close()
        }
    }
    p.waitUntilExit()
    killer.cancel()
    _ = eofGroup.wait(timeout: .now() + 10)
    return ioQueue.sync {
        // 寬鬆解碼：輸出裡有一個壞位元組，不該讓整份回覆變成空字串
        RunResult(
            status: p.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            timedOut: didTimeOut)
    }
}

public enum Fmt {
    /// 秒數進 Int 之前一律過這裡：非數、無限大、負數、離譜的大數都收斂到 0…10 天（Int(1e300) 會讓整個行程 trap）
    public static func clampSeconds(_ s: Double) -> Double { s.isFinite ? min(max(0, s), 864_000) : 0 }
    /// 00:00 或 h:mm:ss
    public static func ts(_ ms: Int) -> String {
        let s = ms / 1000
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
    /// 1小時2分／3分4秒／5秒
    public static func dur(_ seconds: Double) -> String {
        let s = Int(clampSeconds(seconds))
        if s >= 3600 { return "\(s / 3600)小時\((s % 3600) / 60)分" }
        if s >= 60 { return "\(s / 60)分\(s % 60)秒" }
        return "\(s)秒"
    }
}
