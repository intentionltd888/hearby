// Exporters — Word (.docx), PDF (the print layout rendered by Microsoft Edge, which every Windows 10/11 has), "talk it over
// with Claude", and the diagnostics file. Mirrors HearbyApp/Exporters.swift.
using System.Diagnostics;
using System.Text;
using Hearby.Core;
using Microsoft.Win32;

namespace Hearby.App;

static class Exporters
{
    /// Word: .docx next to the record; returns its path
    public static string Word(string mdPath, DocHeader? header = null)
    {
        string raw;
        try { raw = RecordMD.Read(mdPath); } catch { throw new HearbyError($"讀不到 {Path.GetFileName(mdPath)}"); }
        var model = DocBuilder.Build(RecordMD.ClientVersion(raw), header);
        var dest = Path.Combine(Path.GetDirectoryName(mdPath)!, Path.GetFileNameWithoutExtension(mdPath) + ".docx");
        try { Docx.Write(model, dest); }
        catch (IOException e) when (IsLocked(e)) { throw new HearbyError($"{Path.GetFileName(dest)} 正在 Word 裡開著：先關掉它再匯出一次"); }
        HearbyLog.Write($"export word {Path.GetFileName(dest)}");
        return dest;
    }

    static bool IsLocked(IOException e) => (e.HResult & 0xFFFF) is 32 or 33;

    static string? EdgePath()
    {
        var cands = new List<string>();
        foreach (var root in new[] { Environment.GetEnvironmentVariable("ProgramFiles(x86)"), Environment.GetEnvironmentVariable("ProgramFiles"), Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) })
            if (!string.IsNullOrEmpty(root)) cands.Add(Path.Combine(root, "Microsoft", "Edge", "Application", "msedge.exe"));
        try
        {
            if (Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe")?.GetValue(null) is string reg) cands.Insert(0, reg.Trim('"'));
        }
        catch { }
        return cands.FirstOrDefault(File.Exists);
    }

    /// PDF: the same print layout as the macOS version, printed by Edge without a window (no JavaScript, its own profile
    /// so an Edge that is already open is not disturbed). Returns the PDF's path.
    public static string Pdf(string mdPath, DocHeader? header = null)
    {
        string raw;
        try { raw = RecordMD.Read(mdPath); } catch { throw new HearbyError($"讀不到 {Path.GetFileName(mdPath)}"); }
        var edge = EdgePath() ?? throw new HearbyError("這台電腦找不到 Microsoft Edge，PDF 出不來：改用「存成 Word」，在 Word 裡另存成 PDF");
        var work = Path.Combine(Paths.Support, "export");
        Directory.CreateDirectory(work);
        var id = Guid.NewGuid().ToString("N");
        var html = Path.Combine(work, id + ".html");
        var tmpPdf = Path.Combine(work, id + ".pdf");
        var dest = Path.Combine(Path.GetDirectoryName(mdPath)!, Path.GetFileNameWithoutExtension(mdPath) + ".pdf");
        try
        {
            File.WriteAllText(html, Locked(Html.Render(RecordMD.ClientVersion(raw), header)), new UTF8Encoding(true));
            var args = new List<string>
            {
                "--headless", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--disable-extensions",
                "--user-data-dir=" + Path.Combine(work, "edge-profile"),
                "--no-pdf-header-footer", "--print-to-pdf-no-header", "--print-to-pdf=" + tmpPdf, new Uri(html).AbsoluteUri,
            };
            var r = ProcessRunner.Run(edge, args, timeoutSeconds: 90, cwd: work);
            if (!File.Exists(tmpPdf) || new FileInfo(tmpPdf).Length == 0)
            {
                HearbyLog.Write($"export pdf fail exit={r.Status} {CLIFailure.Tail(r)}");
                throw new HearbyError(r.TimedOut ? "PDF 逾時（Edge 90 秒沒有做完）：再試一次，或改用「存成 Word」" : "PDF 產生失敗：改用「存成 Word」，在 Word 裡另存成 PDF");
            }
            try { File.Move(tmpPdf, dest, overwrite: true); }
            catch (IOException e) when (IsLocked(e)) { throw new HearbyError($"{Path.GetFileName(dest)} 正在別的程式裡開著：先關掉它再匯出一次"); }
            HearbyLog.Write($"export pdf {Path.GetFileName(dest)}");
            return dest;
        }
        finally
        {
            try { if (File.Exists(html)) File.Delete(html); } catch { }
            try { if (File.Exists(tmpPdf)) File.Delete(tmpPdf); } catch { }
        }
    }

    /// The print layout lives in the user's folder (~/Hearby/templates/pdf.html can be edited by anything that can write
    /// there): the page Edge prints may run no script and fetch nothing from the network, whatever the template says.
    /// (Edge's own switch for turning JavaScript off also stops its PDF printing, so the rule goes into the page.)
    static string Locked(string html)
    {
        const string csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:\">";
        int head = html.IndexOf("<head>", StringComparison.OrdinalIgnoreCase);
        return head >= 0 ? html.Insert(head + "<head>".Length, csp) : csp + html;
    }

    /// Automatic PDF after every meeting (setting): quietly, never in the way
    public static void AutoPdf(string mdPath)
    {
        if (!ConfigStore.Shared.Current.AutoPDF) return;
        Task.Run(() => { try { Pdf(mdPath); } catch (Exception e) { HearbyLog.Write($"auto pdf: {e.Message}"); } });
    }

    static bool ClaudeDesktopInstalled()
    {
        try { return Registry.ClassesRoot.OpenSubKey("claude") != null; } catch { return false; }
    }

    /// 「跟 Claude 討論」: Claude desktop app → a new Code session in the Hearby folder with this meeting's question
    /// (claude://code/new?folder=…&q=…). The question also goes on the clipboard. Without the desktop app: PowerShell in the
    /// Hearby folder running the Claude Code CLI with the same question (passed encoded, so no character in a title can escape it).
    public static bool ContinueWithClaude(string mdPath)
    {
        EntryFiles.Ensure();
        var q = EntryFiles.ContinueQuestion(mdPath);
        try { System.Windows.Clipboard.SetText(q); } catch { }
        var root = Paths.Root;
        try
        {
            if (ClaudeDesktopInstalled())
            {
                var url = "claude://code/new?folder=" + Uri.EscapeDataString(root) + "&q=" + Uri.EscapeDataString(q) + "&source=hearby";
                HearbyLog.Write("claude desktop → code/new");
                Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
                return true;
            }
            var claude = ClaudeCli.BinaryPath();
            if (claude == null) return false;
            static string Sq(string s) => "'" + s.Replace("'", "''") + "'";
            var script = $"$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8; Set-Location -LiteralPath {Sq(root)}; & {Sq(claude)} {Sq(q)}";
            var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
            HearbyLog.Write("claude desktop not installed → powershell");
            var psi = new ProcessStartInfo("powershell.exe") { UseShellExecute = true, WorkingDirectory = root };
            psi.ArgumentList.Add("-NoExit");
            psi.ArgumentList.Add("-NoProfile");
            psi.ArgumentList.Add("-EncodedCommand");
            psi.ArgumentList.Add(encoded);
            Process.Start(psi);
            return true;
        }
        catch (Exception e) { HearbyLog.Write($"continue with claude fail: {e.Message}"); return false; }
    }

    /// Diagnostics file on the desktop: doctor, settings (meeting notes masked), system, last 300 log lines; the user's
    /// folder name is written as ~
    public static string? Diagnostics()
    {
        var s = new StringBuilder(Doctor.Run(deep: true).Text);
        s.Append("\n── 設定 ──\n");
        try
        {
            if (File.Exists(ConfigStore.Shared.Url) && System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(ConfigStore.Shared.Url)) is System.Text.Json.Nodes.JsonObject o)
            {
                foreach (var k in new[] { "lastBrief", "brief" }) if (o.ContainsKey(k)) o[k] = "（已遮蔽）";
                s.Append(JsonUtil.SortedPretty(o)).Append('\n');
            }
        }
        catch { }
        var mem = LocalEndpoint.TotalMemory() / 1_073_741_824;
        s.Append($"\n── 系統 ──\n{Environment.OSVersion.VersionString}（{System.Runtime.InteropServices.RuntimeInformation.OSArchitecture}，{Environment.ProcessorCount} 執行緒）；記憶體 {mem}GB；app {HearbyVersion.Version} build {HearbyVersion.Build}\n");
        s.Append("\n── 紀錄檔最後 300 行 ──\n");
        try
        {
            var lines = File.ReadAllLines(HearbyLog.File, Encoding.UTF8);
            s.Append(string.Join("\n", lines.Skip(Math.Max(0, lines.Length - 300))));
        }
        catch { s.Append("（沒有紀錄檔）"); }
        var text = s.ToString().Replace(Paths.Home, "~", StringComparison.OrdinalIgnoreCase);
        var desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        var path = Path.Combine(desktop, $"Hearby診斷_{DateTime.Now.ToString("yyyyMMdd-HHmm", System.Globalization.CultureInfo.InvariantCulture)}.txt");
        try { File.WriteAllText(path, text, new UTF8Encoding(true)); return path; }
        catch (Exception e) { HearbyLog.Write($"diagnostics export fail: {e.Message}"); return null; }
    }

    /// Show a file or folder in File Explorer (selected)
    public static void Reveal(string path)
    {
        try
        {
            if (File.Exists(path)) Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
            else { Directory.CreateDirectory(path); Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        }
        catch (Exception e) { HearbyLog.Write($"reveal fail: {e.Message}"); }
    }

    public static void Open(string pathOrUrl)
    {
        try { Process.Start(new ProcessStartInfo(pathOrUrl) { UseShellExecute = true }); }
        catch (Exception e) { HearbyLog.Write($"open fail: {e.Message}"); }
    }
}
