// Connect — install and sign in to Claude Code from inside the app (no terminal, no passwords typed into Hearby).
// Mirrors HearbyUI/Connect/Install.swift (Claude part). Install = Anthropic's official Windows installer
// (`irm https://claude.ai/install.ps1 | iex`, no administrator rights, lands in %USERPROFILE%\.local\bin\claude.exe).
// Sign-in = `claude auth login`: the browser opens Claude's sign-in page; some accounts get a code to paste back here.
using System.Diagnostics;
using System.Text;
using System.Windows.Threading;
using Hearby.Core;

namespace Hearby.App;

public sealed class ClaudeInstall
{
    public static readonly ClaudeInstall Shared = new();
    public bool Running { get; private set; }
    public bool Failed { get; private set; }
    public bool Succeeded { get; private set; }
    public string Note { get; private set; } = "";
    public event Action? Changed;
    Process? process;
    readonly StringBuilder buffer = new();
    DateTime startedAt;

    void Notify() => Gui.OnUi(() => Changed?.Invoke());

    public bool Start()
    {
        if (Running) return true;
        var psi = new ProcessStartInfo("powershell.exe")
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = ClaudeCli.NeutralCwd(),
        };
        foreach (var a in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command",
                     "[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference='SilentlyContinue'; " + ClaudeCli.InstallScript })
            psi.ArgumentList.Add(a);
        foreach (var k in psi.Environment.Keys.Where(k => k.StartsWith("CLAUDE", StringComparison.OrdinalIgnoreCase) || k.StartsWith("ANTHROPIC", StringComparison.OrdinalIgnoreCase)).ToList())
            psi.Environment.Remove(k);
        try
        {
            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            p.OutputDataReceived += (_, e) => { if (e.Data != null) Consume(e.Data); };
            p.ErrorDataReceived += (_, e) => { if (e.Data != null) Consume(e.Data); };
            p.Exited += (_, _) => Gui.OnUi(() => Ended(p.ExitCode));
            p.Start();
            p.StandardInput.Close();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            process = p;
        }
        catch (Exception e) { HearbyLog.Write($"claude install spawn fail: {e.Message}"); return false; }
        buffer.Clear();
        Running = true; Failed = false; Succeeded = false; startedAt = DateTime.Now;
        Note = "正在下載並安裝 Claude Code（通常 1 分鐘內，看網路）…";
        HearbyLog.Write("claude install start");
        Notify();
        return true;
    }

    void Consume(string line)
    {
        lock (buffer) buffer.AppendLine(line);
        var t = Str.TrimWS(line);
        if (t.Length == 0 || t.Contains('%') || t.StartsWith('#')) return;
        Gui.OnUi(() => { if (Running) { Note = "安裝中：" + (t.Length > 90 ? t[..90] : t); Changed?.Invoke(); } });
    }

    void Ended(int status)
    {
        if (!Running) return;
        process = null; Running = false;
        ClaudeCli.ResetAuthCache();
        bool ok = status == 0 && ClaudeCli.BinaryPath() != null;
        Succeeded = ok; Failed = !ok;
        int secs = (int)(DateTime.Now - startedAt).TotalSeconds;
        if (ok)
        {
            Note = $"Claude Code 裝好了（{secs} 秒）。接著登入你的 Claude：";
            HearbyLog.Write($"claude install ok {secs}s");
            ClaudeLogin.Shared.Start();
        }
        else
        {
            string tail; lock (buffer) tail = string.Join(" / ", buffer.ToString().Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).TakeLast(3));
            Note = $"安裝沒成功（exit {status}）：{(tail.Length > 200 ? tail[..200] : tail)}。再按一次「安裝」；還是不行，到 claude.com 下載 Claude Code 自己裝，裝好回來按「重新檢查」。";
            HearbyLog.Write($"claude install fail exit={status}");
        }
        Notify();
    }

    public void Cancel()
    {
        try { if (process is { HasExited: false } p) p.Kill(entireProcessTree: true); } catch { }
        Note = "已取消。"; Running = false; Failed = false;
        Notify();
    }
}

public sealed class ClaudeLogin
{
    public static readonly ClaudeLogin Shared = new();
    public bool Running { get; private set; }
    public bool NeedsCode { get; private set; }
    public string? Url { get; private set; }
    public string Note { get; private set; } = "";
    public bool Succeeded { get; private set; }
    public event Action? Changed;
    Process? process;
    readonly StringBuilder outBuffer = new();
    DispatcherTimer? poll;
    DateTime startedAt;
    int checking;

    void Notify() => Gui.OnUi(() => Changed?.Invoke());

    public bool Start()
    {
        if (Running) return true;
        if (ClaudeCli.BinaryPath() is not { } bin) return false;
        var psi = new ProcessStartInfo(bin)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8, WorkingDirectory = ClaudeCli.NeutralCwd(),
        };
        psi.ArgumentList.Add("auth");
        psi.ArgumentList.Add("login");
        foreach (var k in psi.Environment.Keys.Where(k => k.StartsWith("CLAUDE", StringComparison.OrdinalIgnoreCase) || k.StartsWith("ANTHROPIC", StringComparison.OrdinalIgnoreCase) || k.Equals("BROWSER", StringComparison.OrdinalIgnoreCase)).ToList())
            psi.Environment.Remove(k);
        try
        {
            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            p.Exited += (_, _) => { int code = -1; try { code = p.ExitCode; } catch { } Gui.OnUi(() => ProcessEnded(code)); };
            p.Start();
            // read as it comes, not line by line: the "Paste code here if prompted >" prompt has no line break after it
            Pump(p.StandardOutput);
            Pump(p.StandardError);
            process = p;
        }
        catch (Exception e) { HearbyLog.Write($"claude login spawn fail: {e.Message}"); return false; }
        lock (outBuffer) outBuffer.Clear();
        Url = null; NeedsCode = false; Succeeded = false; Running = true; startedAt = DateTime.Now;
        Note = "瀏覽器會打開 Claude 的登入頁：用你的 Claude 帳號登入並按「允許」。";
        HearbyLog.Write("claude login start");
        poll?.Stop();
        poll = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        poll.Tick += (_, _) => CheckStatus();
        poll.Start();
        Notify();
        return true;
    }

    static void PumpInto(StreamReader r, Action<string> sink) => Task.Run(() =>
    {
        var buf = new char[1024];
        try { int n; while ((n = r.Read(buf, 0, buf.Length)) > 0) sink(new string(buf, 0, n)); } catch { }
    });
    void Pump(StreamReader r) => PumpInto(r, Consume);

    void Consume(string chunk)
    {
        string all;
        lock (outBuffer) { outBuffer.Append(chunk); all = outBuffer.ToString(); }
        Gui.OnUi(() =>
        {
            if (!Running) return;
            if (Url == null && all.IndexOf("https://", StringComparison.Ordinal) is var i and >= 0)
            {
                var tail = all[i..];
                int end = tail.IndexOfAny([' ', '\n', '\r']);
                if (end > 0 || all.Contains("Paste code", StringComparison.OrdinalIgnoreCase)) Url = end < 0 ? tail : tail[..end];
            }
            // Claude's sign-in page ends with a code to paste back here: offer the field as soon as the page is open
            if (Url != null && !NeedsCode)
            {
                NeedsCode = true;
                Note = "瀏覽器打開了 Claude 的登入頁：登入並按「允許」。網頁最後會給你一串代碼：複製它，貼到下面那格按「送出」。（有些情況登入完會自動接上，不用貼）";
            }
            var last = all.Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.Length > 0) ?? "";
            var low = last.ToLowerInvariant();
            if ((low.Contains("error") || low.Contains("failed")) && !low.Contains("paste code"))
                Note = $"登入沒成功：{(last.Length > 160 ? last[..160] : last)}。可以再按一次「登入」。";
            Changed?.Invoke();
        });
    }

    public void Submit(string code)
    {
        var c = Str.TrimWSNL(code);
        if (c.Length == 0 || process is not { } p) return;
        try { p.StandardInput.WriteLine(c); p.StandardInput.Flush(); Note = "代碼已送出，確認中…"; }
        catch { Note = "登入視窗已經關閉，請重新按一次登入"; }
        Notify();
    }

    public void OpenBrowserAgain() { if (Url != null) Exporters.Open(Url); }

    void CheckStatus()
    {
        if (!Running || Interlocked.Exchange(ref checking, 1) == 1) return;
        Task.Run(() =>
        {
            var st = ClaudeCli.AuthStatus(force: true);
            Gui.OnUi(() =>
            {
                Volatile.Write(ref checking, 0);
                if (!Running) return;
                if (st?.LoggedIn == true) Finish(true);
                else if ((DateTime.Now - startedAt).TotalSeconds > 600) { Note = "等了 10 分鐘還沒登入，先取消；要再試就再按一次「登入」。"; Finish(false); }
            });
        });
    }

    void ProcessEnded(int status)
    {
        if (!Running) return;
        Task.Run(() =>
        {
            var st = ClaudeCli.AuthStatus(force: true);
            Gui.OnUi(() =>
            {
                if (!Running) return;
                if (st?.LoggedIn == true) Finish(true);
                else { Note = status == 0 ? "登入程式說完成了，但還沒看到登入狀態；按一次「重新檢查」看看。" : $"登入沒完成（exit {status}）。再按一次「登入」。"; Finish(false); }
            });
        });
    }

    void Finish(bool ok)
    {
        poll?.Stop(); poll = null;
        try { if (process is { HasExited: false } p) p.Kill(entireProcessTree: true); } catch { }
        process = null;
        Running = false; NeedsCode = false; Succeeded = ok;
        if (ok)
        {
            Note = "登入成功，已接上你的 Claude。";
            HearbyLog.Write("claude login ok → select claude");
            Providers.Select("claude");
        }
        Notify();
    }

    public void Cancel() { Note = "已取消。"; Finish(false); }
}
