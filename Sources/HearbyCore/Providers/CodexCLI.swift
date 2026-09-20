// CodexCLI — 用使用者自己的 ChatGPT 訂閱（OpenAI Codex CLI，`codex exec`）整理會議
// 找法：app 自己下載的執行檔 → ChatGPT 桌面版自帶那顆 → 另外裝的 codex。永遠不帶 OPENAI_API_KEY。
import Foundation

public struct CodexCLI: Provider {
    public init() {}
    public var id: String { "codex" }
    public var displayName: String { "交給我的 ChatGPT 整理" }
    public var contextBudget: Int { 120_000 }
    public var maxOutputTokens: Int { 8000 }
    public var trustLevel: TrustLevel { .subscription }

    public static var available: Bool { binaryPath() != nil }
    public static let loginHint = "Codex 還沒登入 ChatGPT——設定頁那列按「登入」"
    public static var installedPath: String { Paths.support.appendingPathComponent("bin/codex").path }

    public static func binaryPath() -> String? {
        var c: [String] = []
        if let p = ConfigStore.shared.current.codexPath, !p.isEmpty { c.append((p as NSString).expandingTildeInPath) }
        let home = NSHomeDirectory()
        c += [installedPath, "/Applications/ChatGPT.app/Contents/Resources/codex", home + "/Applications/ChatGPT.app/Contents/Resources/codex",
              home + "/.npm-global/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex", home + "/.bun/bin/codex"]
        return c.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 找到了工具，但它是 `#!/usr/bin/env node` 腳本、而這台找不到 node（exit 127）
    public private(set) static var nodeMissing = false
    private static var loginCache: (Date, Bool)?
    private static let loginLock = NSLock()
    public static func loggedIn(force: Bool = false) -> Bool? {
        guard let bin = binaryPath() else { return nil }
        loginLock.lock()
        if !force, let (t, v) = loginCache, Date().timeIntervalSince(t) < 20 { loginLock.unlock(); return v }
        loginLock.unlock()
        let r = runProcess(bin, ["login", "status"], env: cleanEnv(), timeout: 8)
        nodeMissing = CLIFailure.isMissingNode(r)
        let text = (r.stdout + r.stderr).lowercased()
        let ok = r.status == 0 && text.contains("logged in") && !text.contains("not logged in")   // 「Not logged in」裡就含 logged in
        loginLock.lock(); loginCache = (Date(), ok); loginLock.unlock()
        return ok
    }
    public static func resetLoginCache() { loginLock.lock(); loginCache = nil; loginLock.unlock() }

    static func cleanEnv() -> [String: String] {
        var e: [String: String] = [:]
        for (k, _) in ProcessInfo.processInfo.environment where k.hasPrefix("OPENAI") || k.hasPrefix("CODEX") { e[k] = "" }
        return e
    }
    public static func neutralCwd() -> URL {
        let u = Paths.support.appendingPathComponent("codex-cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    public func check() -> ProviderStatus {
        guard Self.available else { return ProviderStatus(.missing, "還沒接上（按一下會幫你裝好）", action: "接上 ChatGPT") }
        let logged = Self.loggedIn()
        if Self.nodeMissing { return ProviderStatus(.missing, "找到了，但它需要的 Node.js 找不到（按一下改裝不需要 Node.js 的版本）", action: "接上 ChatGPT") }
        switch logged {
        case .some(true): return ProviderStatus(.ready, "已接上，可以用")
        default: return ProviderStatus(.pending, "裝好了，還沒登入（按一下會開瀏覽器）", action: "登入 ChatGPT")
        }
    }

    /// 外層沙箱（macOS seatbelt）。逐字稿＝會議裡任何人講的話，不可信；而 `codex exec` 是帶 shell 工具的代理，
    /// `-s read-only` 只擋寫檔與連網，擋不了「讀這台的檔案再寫進紀錄」。
    ///
    /// 實測（codex-cli 0.153.4）：
    ///   ・照原本的旗標叫它 `cat` 一個檔 → 紀錄裡是 `exec /bin/zsh -lc 'cat …' succeeded`，內容原樣進了回覆。
    ///   ・把會動手的功能用 `-c features.<名稱>=false` 全關（shell_tool、unified_exec…共 23 個）→ **照樣讀得到**，這條路無效。
    ///   ・整顆 codex 包進下面這個沙箱 → 它要替子行程再套一層沙箱時被系統拒絕
    ///     （`sandbox-exec: sandbox_apply: Operation not permitted`），任何指令都起不來；整理本身照常。
    /// 兩道保險：①巢狀沙箱不被允許＝指令工具整個失效；②就算哪天允許了，這份規則也不准讀 /Users 與 /Volumes
    /// （只留 codex 自己的設定夾、鑰匙圈、空的工作夾、執行檔所在處）。不依賴 codex 自己的任何開關。
    static func sandboxProfile(bin: String, cwd: String, home: String = NSHomeDirectory()) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let real = URL(fileURLWithPath: bin).resolvingSymlinksInPath().path
        var allow = [home + "/.codex", home + "/Library/Keychains", cwd, (real as NSString).deletingLastPathComponent]
        // 工具鏈的安裝夾（node 與套件本體；是程式、不是使用者的資料）
        allow += ["/.nvm", "/.volta", "/.bun", "/.npm-global", "/Library/pnpm", "/.asdf", "/.local/share/mise"].map { home + $0 }
        // npm 裝的那種：執行檔在套件夾裡，連同套件夾一起放行
        if let r = real.range(of: "/node_modules/") {
            let rest = real[r.upperBound...].split(separator: "/")
            let pkg = rest.first.map { $0.hasPrefix("@") && rest.count > 1 ? "\($0)/\(rest[1])" : String($0) } ?? ""
            if !pkg.isEmpty { allow.append(String(real[..<r.upperBound]) + pkg) }
        }
        var lines = [
            "(version 1)", "(allow default)",
            "(deny file-read* (subpath \"/Users\"))", "(deny file-read* (subpath \"/Volumes\"))",
            "(allow file-read-metadata (subpath \"/Users\"))",
        ]
        for a in allow { lines.append("(allow file-read* (subpath \(q(a))))") }
        return lines.joined(separator: "\n")
    }
    static let sandboxExec = "/usr/bin/sandbox-exec"

    public func complete(system: String, user: String) -> (String?, String?) {
        guard let bin = Self.binaryPath() else { return (nil, "找不到 codex（裝 ChatGPT 桌面版就有）") }
        let prompt = system + "\n\n不要使用任何工具、不要讀寫檔案、不要問問題，直接輸出會議紀錄。\n\n" + user
        let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("hearby-codex-\(UUID().uuidString).txt")
        var args = ["exec", "-s", "read-only", "-C", Self.neutralCwd().path, "--skip-git-repo-check", "--ephemeral",
                    "--ignore-user-config", "--ignore-rules", "--color", "never", "-o", outFile.path]
        if let m = ConfigStore.shared.current.codexModel, !m.isEmpty { args += ["-m", m] }
        // prompt 走 stdin（不給 PROMPT 參數就是讀 stdin；這版 CLI 不收 `-`）：
        // 放 argv 的話同機其他帳號用 ps 看得到整份逐字稿，太長還會 E2BIG
        HearbyLog.write("polish codex start chars=\(prompt.count)")
        let t0 = Date()
        // 一律包在外層沙箱裡跑；沙箱起不來就是失敗，**不退回沒有沙箱的跑法**（那等於把洞打開）
        let cwd = Self.neutralCwd().resolvingSymlinksInPath().path
        let profile = Self.sandboxProfile(bin: bin, cwd: cwd)
        let r = runProcess(Self.sandboxExec, ["-p", profile, bin] + args, stdin: prompt, env: Self.cleanEnv(), timeout: 900, cwd: cwd)
        let last = (try? String(contentsOf: outFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try? FileManager.default.removeItem(at: outFile)
        let out = last.isEmpty ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : last
        HearbyLog.write(String(format: "polish codex done %.0fs exit=%d out=%d", Date().timeIntervalSince(t0), r.status, out.count))
        guard r.status == 0, !out.isEmpty else {
            let low = (r.stderr + r.stdout).lowercased()
            if low.contains("not logged in") || (low.contains("login") && low.contains("required")) || low.contains("401") || low.contains("unauthorized") {
                Self.resetLoginCache()
                return (nil, Self.loginHint)
            }
            // 只認沙箱真的起不來的訊息。不可以比對 "sandbox" 這個字：codex 每次都會在 stderr 印一行 `sandbox: read-only`，
            // 那樣任何失敗（額度、斷網、逾時）都會被報成沙箱問題、叫人重裝。
            if out.isEmpty, low.contains("sandbox_apply") || low.contains("sandbox-exec:") {
                return (nil, "這顆 Codex 在安全沙箱裡啟動不了（多半是裝在家目錄深處的版本）。到設定按「接上 ChatGPT」讓 Hearby 裝一顆，或改用 ChatGPT 桌面版自帶的。")
            }
            if let why = CLIFailure.explain(r, who: "ChatGPT", seconds: 900) { return (nil, why) }
            let tail = CLIFailure.tail(r)
            return (nil, "ChatGPT 整理失敗（exit \(r.status)）\(tail.isEmpty ? "" : "：" + tail)")
        }
        return (out, nil)
    }
}
