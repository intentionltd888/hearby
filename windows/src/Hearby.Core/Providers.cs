// Providers — who organises the transcript into a record. Mirrors Providers/Provider.swift, ClaudeCLI.swift, LocalEndpoint.swift.
//
// Windows 1.0 offers: the user's own Claude Code (official CLI, their subscription, no API key), a local model endpoint
// (Ollama / LM Studio / own server), or transcript only. ChatGPT (Codex CLI) is not offered on Windows yet: on macOS it
// runs inside an outer sandbox (sandbox-exec) so a prompt injected through the transcript cannot read the user's files;
// Windows has no equivalent we can apply to it, so it stays off until that is solved.
using System.Diagnostics;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hearby.Core;

public enum TrustLevel { Local, Subscription, Api }

public sealed record ProviderStatus(ProviderStatus.Levels Level, string Text, string? Action = null)
{
    public enum Levels { Ready, Pending, Missing }
}

public interface IProvider
{
    string Id { get; }
    string DisplayName { get; }
    int ContextBudget { get; }
    int MaxOutputTokens { get; }
    TrustLevel Trust { get; }
    ProviderStatus Check();
    /// (output, error); output null ⇒ there is an error
    (string? Output, string? Error) Complete(string system, string user);
}

public static class Providers
{
    public static IProvider Current() => Make(ConfigStore.Shared.Current.Provider);
    public static IProvider Make(string id) => id switch
    {
        "claude" => new ClaudeCli(),
        "endpoint" => new LocalEndpoint(),
        _ => new NoneProvider(),
    };
    public static IProvider[] All => [new ClaudeCli(), new LocalEndpoint(), new NoneProvider()];

    /// Auto-pick: the user's choice wins; otherwise a logged-in Claude → transcript only
    public static string AutoPick()
    {
        var c = ConfigStore.Shared.Current;
        if (c.ProviderChosen == true) return c.Provider;
        var pick = "none";
        if (ClaudeCli.Available && ClaudeCli.AuthStatus()?.LoggedIn == true) pick = "claude";
        ConfigStore.Shared.Update(x => x.Provider = pick);
        HearbyLog.Write($"provider autopick → {pick}");
        return pick;
    }

    /// Select one (and remember that the user chose)
    public static void Select(string id)
    {
        ConfigStore.Shared.Update(c => { c.Provider = id; c.ProviderChosen = true; });
        ClaudeCli.ResetAuthCache();
        HearbyLog.Write($"provider select → {id}");
    }
}

public sealed class NoneProvider : IProvider
{
    public string Id => "none";
    public string DisplayName => "先只要逐字稿";
    public int ContextBudget => 0;
    public int MaxOutputTokens => 0;
    public TrustLevel Trust => TrustLevel.Local;
    public ProviderStatus Check() => new(ProviderStatus.Levels.Ready, "不用帳號，馬上能用");
    public (string?, string?) Complete(string system, string user) => (null, null);
}

/// The user's own Claude subscription via the official Claude Code CLI.
/// Isolation: no tools, no session persistence, no MCP, no settings, no slash commands, one turn; neutral working folder;
/// CLAUDE*/ANTHROPIC* variables stripped. System prompt via a file (Windows command lines are capped at 32,767 characters),
/// transcript via stdin, 900 s timeout. Default model: Max plan = opus, otherwise sonnet (config.claudeModel overrides).
public sealed class ClaudeCli : IProvider
{
    public string Id => "claude";
    public string DisplayName => "交給我的 Claude 整理";
    public int ContextBudget => 150_000;
    public int MaxOutputTokens => 8000;
    public TrustLevel Trust => TrustLevel.Subscription;

    public const string LoginHint = "Claude Code 還沒登入或登入過期——設定頁那列按「登入」";
    /// Official installer (no admin rights needed): https://code.claude.com/docs/en/setup
    public const string InstallScript = "irm https://claude.ai/install.ps1 | iex";

    public static bool Available => BinaryPath() != null;

    public static string? BinaryPath()
    {
        var cands = new List<string>();
        var c = ConfigStore.Shared.Current.ClaudePath;
        if (!string.IsNullOrEmpty(c)) cands.Add(Paths.ExpandTilde(c));
        var home = Paths.Home;
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        cands.Add(Path.Combine(home, ".local", "bin", OperatingSystem.IsWindows() ? "claude.exe" : "claude"));
        cands.Add(Path.Combine(local, "Microsoft", "WinGet", "Links", "claude.exe"));
        cands.Add(Path.Combine(home, ".claude", "local", "claude.exe"));
        foreach (var p in cands) if (File.Exists(p)) return p;
        return ProcessRunner.Which("claude");
    }

    public sealed record Auth(bool LoggedIn, string? Subscription, string? Email)
    {
        public string SubscriptionLabel => (Subscription ?? "").ToLowerInvariant() switch
        {
            "max" => "Max", "pro" => "Pro", "team" => "Team", "enterprise" => "Enterprise", "" => "已登入", _ => Subscription!,
        };
    }

    static (DateTime At, Auth? Value)? authCache;
    static readonly object AuthGate = new();

    public static Auth? AuthStatus(bool force = false)
    {
        if (BinaryPath() is not { } bin) return null;
        lock (AuthGate) { if (!force && authCache is { } ac && (DateTime.UtcNow - ac.At).TotalSeconds < 20) return ac.Value; }
        var r = ProcessRunner.Run(bin, ["auth", "status"], timeoutSeconds: 12, cwd: NeutralCwd());
        Auth? st = null;
        var json = r.Stdout;
        int a = json.IndexOf('{'), b = json.LastIndexOf('}');
        if (a >= 0 && b > a) json = json[a..(b + 1)];
        try
        {
            if (JsonNode.Parse(json) is JsonObject o)
                st = new Auth(o["loggedIn"] is JsonValue lv && lv.TryGetValue<bool>(out var li) && li, JsonUtil.S(o["subscriptionType"]), JsonUtil.S(o["email"]));
        }
        catch { }
        lock (AuthGate) authCache = (DateTime.UtcNow, st);
        return st;
    }

    public static void ResetAuthCache() { lock (AuthGate) authCache = null; }

    public static string Model
    {
        get
        {
            var m = ConfigStore.Shared.Current.ClaudeModel;
            if (!string.IsNullOrEmpty(m)) return m;
            if (AuthStatus() is not { LoggedIn: true } st) return "sonnet";
            return (st.Subscription ?? "").Equals("max", StringComparison.OrdinalIgnoreCase) ? "opus" : "sonnet";
        }
    }

    static string? helpText;
    static bool SupportsEffort
    {
        get
        {
            if (helpText == null && BinaryPath() is { } bin) helpText = ProcessRunner.Run(bin, ["--help"], timeoutSeconds: 15, cwd: NeutralCwd()).Stdout;
            return (helpText ?? "").Has("--effort");
        }
    }

    public static string NeutralCwd()
    {
        var d = Path.Combine(Paths.Support, "claude-cwd");
        Directory.CreateDirectory(d);
        return d;
    }

    public static readonly string[] IsolationArgs =
        ["--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands", "--max-turns", "1"];

    public ProviderStatus Check()
    {
        if (!Available) return new(ProviderStatus.Levels.Missing, "還沒裝（按一下會幫你裝好）", "安裝");
        if (AuthStatus() is not { } st) return new(ProviderStatus.Levels.Pending, "裝好了，登入狀態查不到（按一下重新登入）", "登入");
        if (!st.LoggedIn) return new(ProviderStatus.Levels.Pending, "裝好了，還沒登入（按一下會開瀏覽器）", "登入");
        return new(ProviderStatus.Levels.Ready, $"已接上，可以用（{st.SubscriptionLabel} 方案）");
    }

    public (string?, string?) Complete(string system, string user)
    {
        if (BinaryPath() is not { } bin) return (null, "找不到 Claude Code（設定頁那列按「安裝」）");
        if (AuthStatus() is { LoggedIn: false }) return (null, LoginHint);
        var model = Model;
        var cwd = NeutralCwd();
        var promptFile = Path.Combine(cwd, $"system-prompt-{Environment.ProcessId}-{Guid.NewGuid():N}.txt");
        File.WriteAllText(promptFile, system, new UTF8Encoding(false));
        var args = new List<string> { "-p", "--model", model, "--output-format", "text" };
        args.AddRange(IsolationArgs);
        args.AddRange(["--append-system-prompt-file", promptFile]);
        if (SupportsEffort) args.AddRange(["--effort", ConfigStore.Shared.Current.ClaudeEffort ?? "high"]);
        HearbyLog.Write($"polish claude start model={model} chars={system.Length + user.Length}");
        var sw = Stopwatch.StartNew();
        RunResult r;
        try { r = ProcessRunner.Run(bin, args, stdin: user, timeoutSeconds: 900, cwd: cwd); }
        finally { try { File.Delete(promptFile); } catch { } }
        var outText = Str.TrimWSNL(r.Stdout);
        HearbyLog.Write($"polish claude done {(int)sw.Elapsed.TotalSeconds}s exit={r.Status} out={outText.Length}");
        if (r.Status != 0 || outText.Length == 0)
        {
            var low = (r.Stderr + outText).ToLowerInvariant();
            if (low.Has("login") || low.Has("authenticate") || low.Has("not logged in") || low.Has("token has expired")) { ResetAuthCache(); return (null, LoginHint); }
            if (CLIFailure.Explain(r, "Claude", 900) is { } why) return (null, why);
            if (outText.Length == 0 && r.Status == 0) return (null, "Claude 回了空白，沒有內容可以用——可以按「重新整理全篇」再跑一次");
            var tail = CLIFailure.Tail(r);
            return (null, $"Claude 整理失敗（exit {r.Status}）{(tail.Length == 0 ? "" : "：" + tail)}");
        }
        return (outText, null);
    }
}

/// The user's own model: Ollama / LM Studio on this computer, or their own server (OpenAI-compatible).
/// Plain http only for this computer (127.x / localhost / ::1) and Tailscale (100.64/10, *.ts.net); everything else https.
public sealed class LocalEndpoint : IProvider
{
    public string Id => "endpoint";
    public string DisplayName => "交給本機模型整理";
    public int ContextBudget => Math.Max(0, MaxContextTokens() - MaxOutputTokens - 2048);
    public int MaxOutputTokens => 6000;
    public TrustLevel Trust => Uri.TryCreate(BaseUrl, UriKind.Absolute, out var u) && IsLoopback(u.Host.ToLowerInvariant()) ? TrustLevel.Local : TrustLevel.Api;

    public const string DefaultUrl = "http://127.0.0.1:11434";
    public const string SuggestedModel = "qwen3:4b-instruct";
    public static string BaseUrl { get { var s = Str.TrimWSNL(ConfigStore.Shared.Current.EndpointURL ?? ""); return s.Length == 0 ? DefaultUrl : s; } }
    public static string? Model { get { var m = Str.TrimWSNL(ConfigStore.Shared.Current.EndpointModel ?? ""); return m.Length == 0 ? null : m; } }

    public enum Flavor { Ollama, OpenAI }

    /// null = usable; otherwise one sentence why not
    public static string? UrlProblem(string raw)
    {
        var s = Str.TrimWSNL(raw);
        if (!Uri.TryCreate(s, UriKind.Absolute, out var u) || u.Host.Length == 0 || !Regex.IsMatch(s, "^[A-Za-z][A-Za-z0-9+.-]*://"))
            return "位址看不懂（例：http://127.0.0.1:11434）";
        var scheme = u.Scheme.ToLowerInvariant();
        var host = u.Host.ToLowerInvariant();
        if (scheme == "https") return null;
        if (scheme != "http") return "只接 http 或 https 開頭的位址";
        if (IsLoopback(host) || IsTailnet(host)) return null;
        return "不加密的 http 只能接這台電腦（127.0.0.1）或 Tailscale 內網；其他位址請用 https";
    }

    internal static bool IsLoopback(string host)
    {
        var h = host.Trim('[', ']');
        return h == "localhost" || h == "::1" || h.Starts("127.");
    }

    internal static bool IsTailnet(string host)
    {
        if (host.Ends(".ts.net")) return true;
        var p = host.Split('.');
        if (p.Length != 4 || !int.TryParse(p[0], out var a) || !int.TryParse(p[1], out var b)) return false;
        return a == 100 && b >= 64 && b <= 127;
    }

    /// Trailing slashes removed; a pasted …/v1 tolerated
    internal static string Root(string s)
    {
        var t = Str.TrimWSNL(s);
        while (t.Ends("/")) t = t[..^1];
        if (t.Ends("/v1")) t = t[..^3];
        return t;
    }

    /// Context cap by memory: 4B-class models need ~150 MB per 1K tokens; 16 GB machines also run the meeting app
    public static int MaxContextTokens(ulong? physicalMemory = null)
    {
        double gb = (physicalMemory ?? TotalMemory()) / 1_073_741_824.0;
        if (gb >= 31) return 65_536;
        if (gb >= 15) return 32_768;
        return 16_384;
    }

    public static ulong TotalMemory() { try { return (ulong)GC.GetGCMemoryInfo().TotalAvailableMemoryBytes; } catch { return 16UL << 30; } }
    public static bool MemoryIsTight => TotalMemory() / 1_073_741_824.0 < 15;

    /// Context for this meeting; null = more than this machine can hold
    public static int? ContextFor(int systemChars, int userChars, int maxOutput, int cap)
    {
        int need = systemChars + userChars + maxOutput + 1024;
        if (need > cap) return null;
        int rounded = (need + 4095) / 4096 * 4096;
        return Math.Min(cap, Math.Max(8192, rounded));
    }

    static readonly HttpClient Http = new() { Timeout = Timeout.InfiniteTimeSpan };

    /// Ask the endpoint for its models: Ollama (/api/tags) first, then OpenAI-compatible (/v1/models)
    public static (Flavor Flavor, List<string> Models)? ListModels(string? baseUrl = null, double timeoutSeconds = 4)
    {
        var r = Root(baseUrl ?? BaseUrl);
        if (Get(r + "/api/tags", timeoutSeconds) is { } d1 && Parse(d1) is JsonObject j1 && j1["models"] is JsonArray ms1)
            return (Flavor.Ollama, ms1.Select(m => JsonUtil.S(m?["name"]) ?? JsonUtil.S(m?["model"])).Where(x => x != null).Select(x => x!).ToList());
        if (Get(r + "/v1/models", timeoutSeconds) is { } d2 && Parse(d2) is JsonObject j2 && j2["data"] is JsonArray ms2)
            return (Flavor.OpenAI, ms2.Select(m => JsonUtil.S(m?["id"])).Where(x => x != null).Select(x => x!).ToList());
        return null;
    }

    static JsonNode? Parse(string s) { try { return JsonNode.Parse(s); } catch { return null; } }

    public ProviderStatus Check()
    {
        var b = BaseUrl;
        if (UrlProblem(b) is { } p) return new(ProviderStatus.Levels.Missing, p);
        if (ListModels(b) is not { } lm) return new(ProviderStatus.Levels.Missing, $"連不上 {(Uri.TryCreate(b, UriKind.Absolute, out var u) ? u.Host : b)}——Ollama 或 LM Studio 有開著嗎？");
        if (Model is not { } m) return new(ProviderStatus.Levels.Pending, lm.Models.Count == 0 ? "連上了，但裡面還沒有模型" : "連上了，選一個模型");
        if (!lm.Models.Contains(m)) return new(ProviderStatus.Levels.Missing, $"找不到模型「{m}」");
        return new(ProviderStatus.Levels.Ready, MemoryIsTight ? $"{m}：可以用（這台記憶體不到 16 GB，會比較慢）" : $"{m}：可以用");
    }

    public (string?, string?) Complete(string system, string user)
    {
        var b = BaseUrl;
        if (UrlProblem(b) is { } p) return (null, p);
        if (Model is not { } m) return (null, "還沒選本機模型：到設定「紀錄要誰寫」那一列選一個");
        if (ListModels(b) is not { } lm) return (null, $"連不上本機模型（{b}）：Ollama 或 LM Studio 有開著嗎？逐字稿已經存好了，開起來後按「重新整理全篇」就能補");
        if (lm.Models.Count > 0 && !lm.Models.Contains(m)) return (null, $"本機找不到模型「{m}」，到設定重新選一個");
        int cap = MaxContextTokens();
        if (ContextFor(system.Length, user.Length, MaxOutputTokens, cap) is not { } ctx)
            return (null, $"這場逐字稿約 {user.Length} 字，這台電腦的本機模型一次最多吃約 {Math.Max(0, cap - MaxOutputTokens - 1024 - system.Length)} 字。逐字稿已經存好了；這一場可以改用 Claude 整理");
        var sw = Stopwatch.StartNew();
        HearbyLog.Write($"polish endpoint start flavor={lm.Flavor} model={m} ctx={ctx} chars={user.Length}");
        var messages = new JsonArray { new JsonObject { ["role"] = "system", ["content"] = system }, new JsonObject { ["role"] = "user", ["content"] = user } };
        (string?, string?) r = lm.Flavor == Flavor.Ollama
            ? Post(Root(b) + "/api/chat", new JsonObject
            {
                ["model"] = m, ["stream"] = false, ["keep_alive"] = "5m", ["messages"] = messages,
                ["options"] = new JsonObject { ["num_ctx"] = ctx, ["temperature"] = 0, ["num_predict"] = MaxOutputTokens },
            }, j => JsonUtil.S(j["message"]?["content"]))
            : Post(Root(b) + "/v1/chat/completions", new JsonObject
            {
                ["model"] = m, ["stream"] = false, ["temperature"] = 0, ["max_tokens"] = MaxOutputTokens, ["messages"] = messages,
            }, j => JsonUtil.S((j["choices"] as JsonArray)?.FirstOrDefault()?["message"]?["content"]));
        HearbyLog.Write($"polish endpoint done {(int)sw.Elapsed.TotalSeconds}s out={r.Item1?.Length ?? 0} err={r.Item2 ?? "-"}");
        if (r.Item1 is not { } text) return (null, r.Item2);
        return (StripThinking(text), null);
    }

    /// Thinking models wrap their reasoning in <think>…</think>: drop it
    public static string StripThinking(string s) => Str.TrimWSNL(Regex.Replace(s, @"<think>[\s\S]*?</think>", ""));

    static string? Get(string url, double timeoutSeconds)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
            using var resp = Http.GetAsync(url, cts.Token).GetAwaiter().GetResult();
            if ((int)resp.StatusCode != 200) return null;
            return resp.Content.ReadAsStringAsync(cts.Token).GetAwaiter().GetResult();
        }
        catch { return null; }
    }

    /// Long meetings on slow machines can take a while: 30-minute timeout
    static (string?, string?) Post(string url, JsonObject body, Func<JsonObject, string?> pick, double timeoutSeconds = 1800)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
            using var content = new StringContent(body.ToJsonString(), new UTF8Encoding(false), "application/json");
            using var resp = Http.PostAsync(url, content, cts.Token).GetAwaiter().GetResult();
            var text = resp.Content.ReadAsStringAsync(cts.Token).GetAwaiter().GetResult();
            var j = Parse(text) as JsonObject ?? new JsonObject();
            if ((int)resp.StatusCode != 200)
            {
                var msg = JsonUtil.S(j["error"]) ?? (j["error"] is JsonObject eo ? JsonUtil.S(eo["message"]) : null) ?? Str.Prefix(text, 200);
                return (null, $"本機模型回了錯誤（{(int)resp.StatusCode}）：{msg}");
            }
            var outText = pick(j);
            if (outText == null || Str.TrimWSNL(outText).Length == 0) return (null, "本機模型回了空白內容");
            return (outText, null);
        }
        catch (Exception e) { return (null, $"本機模型沒有回應：{e.Message}"); }
    }
}
