// ClaudeCLI — 用使用者自己的 Claude 訂閱（這台電腦上的 Claude Code CLI）整理會議
//
// 法務四紅線（COMPLIANCE.md）：只 spawn 官方安裝的執行檔、不代付、登入走它自己的流程、宣傳只純文字提。
// 隔離旗標：--tools "" / --no-session-persistence / --strict-mcp-config / --setting-sources "" /
//           --disable-slash-commands / --max-turns 1；中性工作目錄；環境剝除 CLAUDE*／ANTHROPIC*。
// 會議整理＝一次性冷啟（system 走 --append-system-prompt、逐字稿走 stdin、逾時 900 秒）。
// 預設模型依方案：Max＝opus，其餘＝sonnet（怕把別人額度吃光）；config.claudeModel 可改。

import Foundation

public struct ClaudeCLI: Provider {
    public init() {}
    public var id: String { "claude" }
    public var displayName: String { "交給我的 Claude 整理" }
    public var contextBudget: Int { 150_000 }
    public var maxOutputTokens: Int { 8000 }
    public var trustLevel: TrustLevel { .subscription }

    public static var available: Bool { binaryPath() != nil }
    public static let loginHint = "Claude Code 還沒登入或登入過期——設定頁那列按「登入」"

    public static func binaryPath() -> String? {
        var c: [String] = []
        if let p = ConfigStore.shared.current.claudePath, !p.isEmpty { c.append((p as NSString).expandingTildeInPath) }
        let home = NSHomeDirectory()
        c += [home + "/.local/bin/claude", home + "/.claude/local/claude", home + "/bin/claude",
              "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.npm-global/bin/claude",
              home + "/.bun/bin/claude", home + "/.volta/bin/claude"]
        let fm = FileManager.default
        if let versions = try? fm.contentsOfDirectory(atPath: home + "/.nvm/versions/node") {
            for v in versions.sorted().reversed() { c.append(home + "/.nvm/versions/node/\(v)/bin/claude") }
        }
        if let hit = c.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }
        if let s = Doctor.which("claude"), fm.isExecutableFile(atPath: s) { return s }
        let desk = home + "/Library/Application Support/Claude/claude-code"
        if let vs = try? fm.contentsOfDirectory(atPath: desk) {
            for v in vs.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                let p = desk + "/\(v)/claude.app/Contents/MacOS/claude"
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    public struct AuthStatus {
        public let loggedIn: Bool
        public let subscription: String?
        public let email: String?
        public var subscriptionLabel: String {
            switch (subscription ?? "").lowercased() {
            case "max": return "Max"
            case "pro": return "Pro"
            case "team": return "Team"
            case "enterprise": return "Enterprise"
            case "": return "已登入"
            default: return subscription!
            }
        }
    }
    /// 找到了工具，但它是 `#!/usr/bin/env node` 腳本、而這台找不到 node（exit 127）
    public private(set) static var nodeMissing = false
    private static var authCache: (Date, AuthStatus?)?
    private static let authLock = NSLock()
    public static func authStatus(force: Bool = false) -> AuthStatus? {
        guard let bin = binaryPath() else { return nil }
        authLock.lock()
        if !force, let (t, v) = authCache, Date().timeIntervalSince(t) < 20 { authLock.unlock(); return v }
        authLock.unlock()
        let r = runProcess(bin, ["auth", "status"], env: [:], timeout: 8, cwd: neutralCwd().path)
        nodeMissing = CLIFailure.isMissingNode(r)
        var st: AuthStatus?
        // JSON 前後可能夾著升級提示之類的字：取第一個 { 到最後一個 }
        var json = r.stdout
        if let a = json.firstIndex(of: "{"), let b = json.lastIndex(of: "}"), a < b { json = String(json[a...b]) }
        if let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
            st = AuthStatus(loggedIn: obj["loggedIn"] as? Bool ?? false, subscription: obj["subscriptionType"] as? String, email: obj["email"] as? String)
        }
        authLock.lock(); authCache = (Date(), st); authLock.unlock()
        return st
    }
    public static func resetAuthCache() { authLock.lock(); authCache = nil; authLock.unlock() }

    /// 模型：設定 > 依方案（Max＝opus，其餘 sonnet）
    public static var model: String {
        if let m = ConfigStore.shared.current.claudeModel, !m.isEmpty { return m }
        guard let st = authStatus(), st.loggedIn else { return "sonnet" }
        return (st.subscription ?? "").lowercased() == "max" ? "opus" : "sonnet"
    }

    private static let helpText: String = {
        guard let bin = binaryPath() else { return "" }
        return runProcess(bin, ["--help"], env: [:], timeout: 10).stdout
    }()
    static var supportsEffort: Bool { helpText.contains("--effort") }

    public static func neutralCwd() -> URL {
        let dir = Paths.support.appendingPathComponent("claude-cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    public static let isolationArgs: [String] = [
        "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "",
        "--disable-slash-commands", "--max-turns", "1",
    ]

    public func check() -> ProviderStatus {
        guard Self.available else { return ProviderStatus(.missing, "還沒裝（按一下會幫你裝好）", action: "安裝") }
        guard let st = Self.authStatus() else {
            if Self.nodeMissing { return ProviderStatus(.missing, "找到了，但它需要的 Node.js 找不到（按一下改裝不需要 Node.js 的版本）", action: "安裝") }
            return ProviderStatus(.pending, "裝好了，登入狀態查不到（按一下重新登入）", action: "登入")
        }
        guard st.loggedIn else { return ProviderStatus(.pending, "裝好了，還沒登入（按一下會開瀏覽器）", action: "登入") }
        return ProviderStatus(.ready, "已接上，可以用（\(st.subscriptionLabel) 方案）")
    }

    public func complete(system: String, user: String) -> (String?, String?) {
        guard let bin = Self.binaryPath() else { return (nil, "找不到 Claude Code（設定頁那列按「安裝」）") }
        if let st = Self.authStatus(), !st.loggedIn { return (nil, Self.loginHint) }
        let model = Self.model
        var args = ["-p", "--model", model, "--output-format", "text"] + Self.isolationArgs + ["--append-system-prompt", system]
        if Self.supportsEffort { args += ["--effort", ConfigStore.shared.current.claudeEffort ?? "high"] }
        HearbyLog.write("polish claude start model=\(model) chars=\(system.count + user.count)")
        let t0 = Date()
        let r = runProcess(bin, args, stdin: user, env: [:], timeout: 900, cwd: Self.neutralCwd().path)
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        HearbyLog.write(String(format: "polish claude done %.0fs exit=%d out=%d", Date().timeIntervalSince(t0), r.status, out.count))
        guard r.status == 0, !out.isEmpty else {
            let low = (r.stderr + out).lowercased()
            if low.contains("login") || low.contains("authenticate") || low.contains("not logged in") || low.contains("token has expired") {
                Self.resetAuthCache()
                return (nil, Self.loginHint)
            }
            if let why = CLIFailure.explain(r, who: "Claude", seconds: 900) { return (nil, why) }
            if out.isEmpty, r.status == 0 { return (nil, "Claude 回了空白，沒有內容可以用——可以按「重新整理全篇」再跑一次") }
            let tail = CLIFailure.tail(r)
            return (nil, "Claude 整理失敗（exit \(r.status)）\(tail.isEmpty ? "" : "：" + tail)")
        }
        return (out, nil)
    }
}
