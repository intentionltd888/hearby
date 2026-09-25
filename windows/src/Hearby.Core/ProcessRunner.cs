// ProcessRunner — run a child process, collect stdout/stderr, with a timeout. Mirrors Process.swift (runProcess, ChildEnv, RunningChildren).
using System.Diagnostics;
using System.Text;

namespace Hearby.Core;

public sealed record RunResult(int Status, string Stdout, string Stderr, bool TimedOut = false);

/// Children still running; all of them are ended when the app quits (no orphaned CLIs or half-done transcription)
public static class RunningChildren
{
    static readonly object Gate = new();
    static readonly HashSet<Process> Procs = [];
    internal static void Add(Process p) { lock (Gate) Procs.Add(p); }
    internal static void Remove(Process p) { lock (Gate) Procs.Remove(p); }
    public static void TerminateAll()
    {
        Process[] all; lock (Gate) all = [.. Procs];
        foreach (var p in all) { try { if (!p.HasExited) p.Kill(entireProcessTree: true); } catch { } }
    }
}

public static class ChildEnv
{
    /// Places CLIs are installed on Windows (the app may be started with a narrow PATH)
    public static IEnumerable<string> ExtraDirs(string launchPath)
    {
        var home = Paths.Home;
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var dir = Path.GetDirectoryName(launchPath);
        if (!string.IsNullOrEmpty(dir)) yield return dir;
        yield return Path.Combine(home, ".local", "bin");
        yield return Path.Combine(roaming, "npm");
        yield return Path.Combine(local, "Microsoft", "WinGet", "Links");
        yield return Path.Combine(local, "Programs", "nodejs");
    }

    public static string BuildPath(string launchPath, string? basePath)
    {
        var sep = Path.PathSeparator;
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var dirs = ExtraDirs(launchPath).Concat((basePath ?? "").Split(sep, StringSplitOptions.RemoveEmptyEntries));
        return string.Join(sep, dirs.Where(d => d.Length > 0 && seen.Add(d)));
    }
}

public static class ProcessRunner
{
    public static RunResult Run(string launchPath, IEnumerable<string> args, string? stdin = null,
        IDictionary<string, string>? env = null, double timeoutSeconds = 600, string? cwd = null, ProcessPriorityClass? priority = null)
    {
        var psi = new ProcessStartInfo(launchPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = stdin != null,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
        };
        if (stdin != null) psi.StandardInputEncoding = new UTF8Encoding(false);
        foreach (var a in args) psi.ArgumentList.Add(a);
        if (cwd != null) psi.WorkingDirectory = cwd;
        if (env != null) foreach (var kv in env) psi.Environment[kv.Key] = kv.Value;
        // inherited host variables would make a child wait for the host's authorisation forever
        foreach (var k in psi.Environment.Keys.Where(k => k.StartsWith("CLAUDE", StringComparison.OrdinalIgnoreCase) || k.StartsWith("ANTHROPIC", StringComparison.OrdinalIgnoreCase)).ToList())
            psi.Environment.Remove(k);
        var pathKey = psi.Environment.Keys.FirstOrDefault(k => k.Equals("PATH", StringComparison.OrdinalIgnoreCase)) ?? "PATH";
        psi.Environment.TryGetValue(pathKey, out var basePath);
        psi.Environment[pathKey] = ChildEnv.BuildPath(launchPath, basePath);

        var p = new Process { StartInfo = psi };
        var outSb = new StringBuilder();
        var errSb = new StringBuilder();
        var outDone = new ManualResetEventSlim();
        var errDone = new ManualResetEventSlim();
        p.OutputDataReceived += (_, e) => { if (e.Data == null) outDone.Set(); else lock (outSb) outSb.Append(e.Data).Append('\n'); };
        p.ErrorDataReceived += (_, e) => { if (e.Data == null) errDone.Set(); else lock (errSb) errSb.Append(e.Data).Append('\n'); };
        try { if (!p.Start()) return new RunResult(-1, "", "無法啟動"); }
        catch (Exception e) { return new RunResult(-1, "", e.Message); }
        RunningChildren.Add(p);
        try
        {
            if (priority is { } pr) { try { p.PriorityClass = pr; } catch { } }
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            if (stdin != null)
            {
                // write in the background: a child that never reads stdin must not block us past the timeout
                var w = p.StandardInput;
                Task.Run(() => { try { w.Write(stdin); w.Close(); } catch { } });
            }
            bool exited = p.WaitForExit(TimeSpan.FromSeconds(timeoutSeconds));
            bool timedOut = false;
            if (!exited)
            {
                timedOut = true;
                try { p.Kill(entireProcessTree: true); } catch { }
                p.WaitForExit(5000);
            }
            else p.WaitForExit();
            outDone.Wait(TimeSpan.FromSeconds(10));
            errDone.Wait(TimeSpan.FromSeconds(10));
            int code; try { code = p.ExitCode; } catch { code = -1; }
            string o, e2;
            lock (outSb) o = outSb.ToString();
            lock (errSb) e2 = errSb.ToString();
            return new RunResult(timedOut ? -9 : code, o, e2, timedOut);
        }
        finally { RunningChildren.Remove(p); p.Dispose(); }
    }

    /// Find an executable on PATH (+ the usual CLI install folders)
    public static string? Which(string name)
    {
        var exts = OperatingSystem.IsWindows() ? new[] { ".exe", ".cmd", ".bat", "" } : new[] { "" };
        var dirs = ChildEnv.ExtraDirs("").Concat((Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries));
        foreach (var d in dirs)
            foreach (var ext in exts)
            {
                var p = Path.Combine(d, name + ext);
                if (File.Exists(p)) return p;
            }
        return null;
    }
}

public static class CLIFailure
{
    /// Last two non-empty lines (stderr, else stdout)
    public static string Tail(RunResult r)
    {
        static string Last2(string s) => string.Join(" ", s.Split('\n').Select(l => Str.TrimWS(l)).Where(l => l.Length > 0).TakeLast(2));
        var t = Last2(r.Stderr);
        var x = t.Length == 0 ? Last2(r.Stdout) : t;
        return Str.Prefix(x, 300);
    }
    public static bool IsMissingNode(RunResult r) => r.Status == 127 || (r.Stderr + r.Stdout).Has("env: node");
    public static bool IsUsageLimit(string low) => new[] { "hit your", "limit reached", "usage limit", "rate limit", "rate_limit", "quota", "too many requests", " 429" }.Any(low.Has);
    public static bool IsTooLong(string low) => new[] { "prompt is too long", "prompt too long", "context length", "context_length", "maximum context", "too many tokens" }.Any(low.Has);
    public static bool IsOverloaded(string low) => low.Has("overloaded") || low.Has("error 529") || low.Has("status 529");

    public static string? Explain(RunResult r, string who, int seconds)
    {
        var low = (r.Stderr + "\n" + r.Stdout).ToLowerInvariant();
        if (r.TimedOut) return $"{who} 整理逾時（{seconds} 秒沒有回來）——可以按「重新整理全篇」再跑一次";
        if (r.Status == -1) return $"{who} 的指令列工具起不來：{Tail(r)}";
        if (IsMissingNode(r)) return $"找到了 {who} 的指令列工具，但它需要的 Node.js 找不到。到設定按一下那一列，讓 Hearby 裝一顆不需要 Node.js 的。";
        if (IsUsageLimit(low)) return $"{who} 的額度暫時用完了（它說：{Tail(r)}）。等它恢復後按「重新整理全篇」。";
        if (IsTooLong(low)) return $"這場太長，超過 {who} 一次能讀的量。目前先保留逐字稿版本。";
        if (IsOverloaded(low)) return $"{who} 那邊現在很忙（{Tail(r)}），晚點再按「重新整理全篇」。";
        return null;
    }
}
