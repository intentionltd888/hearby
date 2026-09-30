// Provider — 「用什麼來整理」的協定（開源後別人接的東西）
import Foundation

public enum TrustLevel: String { case local, subscription, api }

public struct ProviderStatus: Equatable {
    public enum Level: Equatable { case ready, pending, missing }
    public let level: Level
    public let text: String
    public let action: String?   // 主動作標題（安裝／登入）；nil＝沒有要做的
    public init(_ level: Level, _ text: String, action: String? = nil) { self.level = level; self.text = text; self.action = action }
}

public protocol Provider {
    var id: String { get }
    var displayName: String { get }
    var contextBudget: Int { get }       // 輸入字元預算（中文 ≈1 token/字）
    var maxOutputTokens: Int { get }
    var trustLevel: TrustLevel { get }
    func check() -> ProviderStatus
    /// 回 (輸出, 錯誤)；輸出 nil 就一定有錯誤
    func complete(system: String, user: String) -> (String?, String?)
}

public enum Providers {
    /// 依 config.provider 取實例
    public static func current() -> Provider {
        make(ConfigStore.shared.current.provider)
    }
    public static func make(_ id: String) -> Provider {
        switch id {
        case "claude": return ClaudeCLI()
        case "codex": return CodexCLI()
        case "endpoint": return LocalEndpoint()
        default: return NoneProvider()
        }
    }
    public static let all: [Provider] = [ClaudeCLI(), CodexCLI(), LocalEndpoint(), NoneProvider()]

    /// 自動挑：使用者選過就不動；否則已登入的 Claude → 已登入的 Codex → 只要逐字稿
    @discardableResult
    public static func autoPick() -> String {
        let c = ConfigStore.shared.current
        if c.providerChosen == true { return c.provider }
        var pick = "none"
        if ClaudeCLI.available, ClaudeCLI.authStatus()?.loggedIn == true { pick = "claude" }
        else if CodexCLI.available, CodexCLI.loggedIn() == true { pick = "codex" }
        try? ConfigStore.shared.update { $0.provider = pick }
        HearbyLog.write("provider autopick → \(pick)")
        return pick
    }
}

public struct NoneProvider: Provider {
    public init() {}
    public var id: String { "none" }
    public var displayName: String { "先只要逐字稿" }
    public var contextBudget: Int { 0 }
    public var maxOutputTokens: Int { 0 }
    public var trustLevel: TrustLevel { .local }
    public func check() -> ProviderStatus { ProviderStatus(.ready, "不用帳號，馬上能用") }
    public func complete(system: String, user: String) -> (String?, String?) { (nil, nil) }
}


/// 指令列工具失敗時，兩家共用的分類與人話。只看得到輸出文字，所以比對要寬、訊息要把工具自己講的那句帶出來。
public enum CLIFailure {
    /// 輸出最後兩行非空白（stderr 沒東西就看 stdout——有些工具把錯誤印在 stdout）
    public static func tail(_ r: RunResult) -> String {
        func last2(_ s: String) -> String { s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(2).joined(separator: " ") }
        let t = last2(r.stderr)
        return String((t.isEmpty ? last2(r.stdout) : t).prefix(300))
    }
    public static func isMissingNode(_ r: RunResult) -> Bool {
        r.status == 127 || (r.stderr + r.stdout).contains("env: node")
    }
    /// 額度：訊息各版不同（hit your session／weekly／Opus limit、usage limit reached、rate limit、quota、resets 3pm…）
    public static func isUsageLimit(_ low: String) -> Bool {
        ["hit your", "limit reached", "usage limit", "rate limit", "rate_limit", "quota", "too many requests", " 429"].contains { low.contains($0) }
    }
    public static func isTooLong(_ low: String) -> Bool {
        ["prompt is too long", "prompt too long", "context length", "context_length", "maximum context", "too many tokens"].contains { low.contains($0) }
    }
    public static func isOverloaded(_ low: String) -> Bool { low.contains("overloaded") || low.contains("error 529") || low.contains("status 529") }

    /// 回一句人話；都不像就回 nil，讓呼叫端用通用訊息
    public static func explain(_ r: RunResult, who: String, seconds: Int) -> String? {
        let low = (r.stderr + "\n" + r.stdout).lowercased()
        if r.timedOut { return "\(who) 整理逾時（\(seconds) 秒沒有回來）——可以按「重新整理全篇」再跑一次" }
        if r.status == -1 { return "\(who) 的指令列工具起不來：\(tail(r))" }
        if isMissingNode(r) { return "找到了 \(who) 的指令列工具，但它需要的 Node.js 找不到。到設定按一下那一列，讓 Hearby 裝一顆不需要 Node.js 的。" }
        if isUsageLimit(low) { return "\(who) 的額度暫時用完了（它說：\(tail(r))）。等它恢復後按「重新整理全篇」。" }
        if isTooLong(low) { return "這場太長，超過 \(who) 一次能讀的量。目前先保留逐字稿版本。" }
        if isOverloaded(low) { return "\(who) 那邊現在很忙（\(tail(r))），晚點再按「重新整理全篇」。" }
        return nil
    }
}
