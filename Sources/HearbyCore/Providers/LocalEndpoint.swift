// LocalEndpoint — 交給使用者自己的模型整理：這台電腦上的 Ollama／LM Studio，或自己架的伺服器（OpenAI 相容端點）
//
// 不內建模型、不包 llama.cpp：app 不變重，要的人自己裝、自己選模型。這一版只接不用金鑰的端點（沒有金鑰欄）。
// 位址規則：不加密的 http 只放行這台電腦（127.0.0.1／localhost／::1）與 Tailscale 內網（100.64.0.0/10、*.ts.net，
//   Tailscale 本身已加密）；其他位址一律 https。
// Ollama 走原生 /api/chat，逐場算需要的上下文長度（num_ctx）：Ollama 的預設上下文很短，不設的話長逐字稿的前段會被默默截掉。
// 其他端點走 /v1/chat/completions，上下文長度由那一端的設定決定；超過就把對方的錯誤原文帶回來。
// 一次吃不下的長會議（超過這台記憶體撐得住的上下文）直接說清楚、逐字稿照存，不硬塞、不偷偷截斷。

import Foundation

public struct LocalEndpoint: Provider {
    public init() {}
    public var id: String { "endpoint" }
    public var displayName: String { "交給本機模型整理" }
    /// 輸入字元預算（中文約 1 字 1 token）：扣掉輸出與系統提示的餘裕
    public var contextBudget: Int { max(0, Self.maxContextTokens() - maxOutputTokens - 2048) }
    public var maxOutputTokens: Int { 6000 }
    public var trustLevel: TrustLevel {
        guard let h = URL(string: Self.baseURLString)?.host?.lowercased() else { return .api }
        return Self.isLoopback(h) ? .local : .api
    }

    public static let defaultURL = "http://127.0.0.1:11434"
    /// 建議的模型（盲測過：人稱／事實不亂寫，2.5 GB）；只是建議，選單裡有什麼都能選
    public static let suggestedModel = "qwen3:4b-instruct"
    public static var baseURLString: String {
        let s = ConfigStore.shared.current.endpointURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? defaultURL : s
    }
    public static var model: String? {
        let m = ConfigStore.shared.current.endpointModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return m.isEmpty ? nil : m
    }

    public enum Flavor: String { case ollama, openai }

    // MARK: 位址

    /// 回 nil＝可以用；否則回一句人話
    public static func urlProblem(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased(), !host.isEmpty else {
            return "位址看不懂（例：http://127.0.0.1:11434）"
        }
        if scheme == "https" { return nil }
        guard scheme == "http" else { return "只接 http 或 https 開頭的位址" }
        if isLoopback(host) || isTailnet(host) { return nil }
        return "不加密的 http 只能接這台電腦（127.0.0.1）或 Tailscale 內網；其他位址請用 https"
    }
    static func isLoopback(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h == "::1" || h.hasPrefix("127.")
    }
    static func isTailnet(_ host: String) -> Bool {
        if host.hasSuffix(".ts.net") { return true }
        let p = host.split(separator: ".").map { Int($0) }
        guard p.count == 4, let a = p[0], let b = p[1] else { return false }
        return a == 100 && (64...127).contains(b)
    }
    /// 去掉結尾斜線，也容忍使用者貼成 …/v1
    static func root(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        if t.hasSuffix("/v1") { t.removeLast(3) }
        return t
    }

    // MARK: 記憶體 → 一次吃得下多長

    /// 這台電腦跑本機模型時的上下文上限（token）。4B 級模型每 1K token 的上下文約佔 150 MB 記憶體，
    /// 16 GB 的電腦還要留給會議軟體與系統，所以只給到 32K（約 2 萬 4 千字、90 分鐘左右的會）。
    public static func maxContextTokens(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let gb = Double(physicalMemory) / 1_073_741_824
        if gb >= 31 { return 65_536 }
        if gb >= 15 { return 32_768 }
        return 16_384
    }
    /// 16 GB 以下的電腦：可以用，但會慢、可能卡（設定頁照這個提醒）
    public static var memoryIsTight: Bool { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 < 15 }

    /// 這一場要開多大的上下文；超過上限回 nil
    public static func contextFor(systemChars: Int, userChars: Int, maxOutput: Int, cap: Int) -> Int? {
        let need = systemChars + userChars + maxOutput + 1024
        guard need <= cap else { return nil }
        let rounded = ((need + 4095) / 4096) * 4096
        return min(cap, max(8192, rounded))
    }

    // MARK: 連線

    /// 問端點有哪些模型：先試 Ollama（/api/tags），再試 OpenAI 相容（/v1/models）
    public static func listModels(_ base: String = baseURLString, timeout: TimeInterval = 4) -> (flavor: Flavor, models: [String])? {
        let r = root(base)
        if let d = httpGet(r + "/api/tags", timeout: timeout),
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ms = j["models"] as? [[String: Any]] {
            return (.ollama, ms.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) })
        }
        if let d = httpGet(r + "/v1/models", timeout: timeout),
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ms = j["data"] as? [[String: Any]] {
            return (.openai, ms.compactMap { $0["id"] as? String })
        }
        return nil
    }

    public func check() -> ProviderStatus {
        let base = Self.baseURLString
        if let p = Self.urlProblem(base) { return ProviderStatus(.missing, p) }
        guard let (_, models) = Self.listModels(base) else {
            return ProviderStatus(.missing, "連不上 \(URL(string: base)?.host ?? base)——Ollama 或 LM Studio 有開著嗎？")
        }
        guard let m = Self.model else { return ProviderStatus(.pending, models.isEmpty ? "連上了，但裡面還沒有模型" : "連上了，選一個模型") }
        guard models.contains(m) else { return ProviderStatus(.missing, "找不到模型「\(m)」") }
        return ProviderStatus(.ready, Self.memoryIsTight ? "\(m)：可以用（這台記憶體不到 16 GB，會比較慢）" : "\(m)：可以用")
    }

    public func complete(system: String, user: String) -> (String?, String?) {
        let base = Self.baseURLString
        if let p = Self.urlProblem(base) { return (nil, p) }
        guard let m = Self.model else { return (nil, "還沒選本機模型：到設定「紀錄要誰寫」那一列選一個") }
        guard let (flavor, models) = Self.listModels(base) else { return (nil, "連不上本機模型（\(base)）：Ollama 或 LM Studio 有開著嗎？逐字稿已經存好了，開起來後按「重新整理全篇」就能補") }
        if !models.isEmpty, !models.contains(m) { return (nil, "本機找不到模型「\(m)」，到設定重新選一個") }
        let cap = Self.maxContextTokens()
        guard let ctx = Self.contextFor(systemChars: system.count, userChars: user.count, maxOutput: maxOutputTokens, cap: cap) else {
            return (nil, "這場逐字稿約 \(user.count) 字，這台電腦的本機模型一次最多吃約 \(max(0, cap - maxOutputTokens - 1024 - system.count)) 字。逐字稿已經存好了；這一場可以改用 Claude 或 ChatGPT 整理")
        }
        let t0 = Date()
        HearbyLog.write("polish endpoint start flavor=\(flavor.rawValue) model=\(m) ctx=\(ctx) chars=\(user.count)")
        let r: (String?, String?)
        switch flavor {
        case .ollama:
            let body: [String: Any] = [
                "model": m, "stream": false, "keep_alive": "5m",
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
                "options": ["num_ctx": ctx, "temperature": 0, "num_predict": maxOutputTokens],
            ]
            r = Self.post(Self.root(base) + "/api/chat", body: body) { j in (j["message"] as? [String: Any])?["content"] as? String }
        case .openai:
            let body: [String: Any] = [
                "model": m, "stream": false, "temperature": 0, "max_tokens": maxOutputTokens,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            ]
            r = Self.post(Self.root(base) + "/v1/chat/completions", body: body) { j in
                ((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
            }
        }
        HearbyLog.write(String(format: "polish endpoint done %.0fs out=%d err=%@", Date().timeIntervalSince(t0), r.0?.count ?? 0, r.1 ?? "-"))
        guard let text = r.0 else { return (nil, r.1) }
        return (Self.stripThinking(text), nil)
    }

    /// 思考型模型會把推理過程包在 <think>…</think> 裡：拿掉，只留紀錄本身
    public static func stripThinking(_ s: String) -> String {
        s.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: HTTP（同步：整理本來就跑在背景執行緒）

    private static func httpGet(_ url: String, timeout: TimeInterval) -> Data? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = "GET"
        let (d, code, _) = send(req)
        return code == 200 ? d : nil
    }

    /// 長會議在慢的電腦上可能要跑十幾分鐘：逾時給到 30 分鐘
    static func post(_ url: String, body: [String: Any], timeout: TimeInterval = 1800, pick: ([String: Any]) -> String?) -> (String?, String?) {
        guard let u = URL(string: url), let data = try? JSONSerialization.data(withJSONObject: body) else { return (nil, "位址或內容格式不對") }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (d, code, err) = send(req)
        if let err { return (nil, "本機模型沒有回應：\(err)") }
        let j = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if code != 200 {
            let msg = (j["error"] as? String) ?? ((j["error"] as? [String: Any])?["message"] as? String) ?? d.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.prefix(200)) } ?? ""
            return (nil, "本機模型回了錯誤（\(code)）：\(msg)")
        }
        guard let text = pick(j), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, "本機模型回了空白內容") }
        return (text, nil)
    }

    private static func send(_ req: URLRequest) -> (Data?, Int, String?) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = req.timeoutInterval
        cfg.timeoutIntervalForResource = req.timeoutInterval
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let sem = DispatchSemaphore(value: 0)
        var out: (Data?, Int, String?) = (nil, 0, nil)
        session.dataTask(with: req) { d, resp, e in
            out = (d, (resp as? HTTPURLResponse)?.statusCode ?? 0, e?.localizedDescription)
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }
}
