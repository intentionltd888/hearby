// Exporters — PDF（WKWebView 印表）、Word（RTF，Word／Pages 直接開）、開終端機接 Claude
import AppKit
import Foundation
import HearbyCore
import WebKit

enum Exporters {
    // PDF：WKWebView printOperation，原生分頁（不可用 op.run()——會無限分頁；必須 runModal(for:)）
    private final class PDFRenderer: NSObject, WKNavigationDelegate {
        static var active: [PDFRenderer] = []
        let webView: WKWebView
        let window: NSWindow
        let dest: URL
        let done: (Result<URL, Error>) -> Void
        var reported = false
        init(html: String, dest: URL, done: @escaping (Result<URL, Error>) -> Void) {
            let rect = NSRect(x: 0, y: 0, width: 595, height: 842)
            // 只拿來把 HTML 排成 PDF：關掉 JavaScript。版型檔放在使用者的專案夾（~/Hearby/templates），
            // 任何能寫那個夾的東西都改得到它；不跑 script，版型再怎麼被改也帶不走紀錄內容。
            let cfg = WKWebViewConfiguration()
            cfg.defaultWebpagePreferences.allowsContentJavaScript = false
            webView = WKWebView(frame: rect, configuration: cfg)
            window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            self.dest = dest
            self.done = done
            super.init()
            PDFRenderer.active.append(self)
            window.contentView = webView
            webView.navigationDelegate = self
            webView.loadHTMLString(html, baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.report(.failure(HearbyError("PDF 逾時"))) }
        }
        private func report(_ r: Result<URL, Error>) { guard !reported else { return }; reported = true; done(r) }
        private func release() { PDFRenderer.active.removeAll { $0 === self } }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.printToPDF() }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(.failure(error)); release() }
        private func printToPDF() {
            let pi = NSPrintInfo()
            pi.paperSize = NSSize(width: 595, height: 842)
            pi.topMargin = 46; pi.bottomMargin = 46; pi.leftMargin = 48; pi.rightMargin = 48
            pi.horizontalPagination = .fit; pi.verticalPagination = .automatic
            pi.jobDisposition = .save
            pi.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = dest as NSURL
            let op = webView.printOperation(with: pi)
            op.showsPrintPanel = false; op.showsProgressPanel = false
            op.view?.frame = NSRect(x: 0, y: 0, width: 595, height: 842)
            op.runModal(for: window, delegate: self, didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        @objc private func printDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            if success, FileManager.default.fileExists(atPath: dest.path) { report(.success(dest)) } else { report(.failure(HearbyError("PDF 產生失敗"))) }
            release()
        }
    }

    /// 主執行緒
    static func pdf(mdURL: URL, header: DocHeader?, done: @escaping (Result<URL, Error>) -> Void) {
        guard let md = try? String(contentsOf: mdURL, encoding: .utf8) else { done(.failure(HearbyError("讀不到 \(mdURL.lastPathComponent)"))); return }
        let base = mdURL.deletingPathExtension().lastPathComponent
        let dest = mdURL.deletingLastPathComponent().appendingPathComponent(base + ".pdf")
        _ = PDFRenderer(html: Html.render(md: RecordMD.clientVersion(md: md), header: header), dest: dest, done: done)
    }

    /// Word：純 Swift 產 .docx（Word／Pages 直接開；版型依情境）
    static func word(mdURL: URL, header: DocHeader? = nil) -> Result<URL, Error> {
        guard let raw = try? String(contentsOf: mdURL, encoding: .utf8) else { return .failure(HearbyError("讀不到 \(mdURL.lastPathComponent)")) }
        let model = DocBuilder.build(md: RecordMD.clientVersion(md: raw), header: header)
        let base = mdURL.deletingPathExtension().lastPathComponent
        let dest = mdURL.deletingLastPathComponent().appendingPathComponent(base + ".docx")
        do { try Docx.write(model: model, to: dest); return .success(dest) } catch { return .failure(error) }
    }

    /// Pages：Pages 沒有公開的檔案格式可以直接寫，正確做法＝出 .docx 再用 Pages 打開（Pages 原生支援），
    /// 之後在 Pages 裡「檔案 → 儲存」就是 .pages。有裝 Pages 就用它開，沒裝就退成 Word 檔。
    static func pages(mdURL: URL, header: DocHeader?) -> Result<URL, Error> {
        let r = word(mdURL: mdURL, header: header)
        guard case .success(let docx) = r else { return r }
        let pagesApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages")
        if let app = pagesApp {
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([docx], withApplicationAt: app, configuration: cfg) { _, e in if let e { HearbyLog.write("pages open fail: \(e)") } }
            return .success(docx)
        }
        return .failure(HearbyError("這台沒有裝 Pages（App Store 免費）；Word 檔已出：\(docx.lastPathComponent)"))
    }

    /// 「跟 Claude 討論」：開 Claude 桌面版、在 ~/Hearby/ 新開一個 Code session、把這場的問題帶進去
    /// （桌面版的深連結 claude://code/new?folder=…&q=…）。問題同時放進剪貼簿，萬一沒帶到，貼上就好。
    /// 沒裝桌面版才退回終端機（.command）。
    static func continueWithClaude(mdURL: URL) -> Bool {
        EntryFiles.ensure()
        let q = EntryFiles.continueQuestion(mdURL: mdURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(q, forType: .string)
        var c = URLComponents()
        c.scheme = "claude"; c.host = "code"; c.path = "/new"
        c.queryItems = [URLQueryItem(name: "folder", value: Paths.root.path), URLQueryItem(name: "q", value: q), URLQueryItem(name: "source", value: "hearby")]
        if let u = c.url, NSWorkspace.shared.urlForApplication(toOpen: u) != nil {
            HearbyLog.write("claude desktop → code/new folder=\(Paths.root.path)")
            return NSWorkspace.shared.open(u)
        }
        HearbyLog.write("claude desktop not installed → terminal fallback")
        let cmd = EntryFiles.continueCommand(mdURL: mdURL, claude: ClaudeCLI.binaryPath() ?? "claude")
        let dir = Paths.support.appendingPathComponent("terminal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("hearby-claude-\(Int(Date().timeIntervalSince1970)).command")
        let script = "#!/bin/zsh\nclear\nexport PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"\n" + cmd + "\n"
        guard (try? script.write(to: f, atomically: true, encoding: .utf8)) != nil else { return false }
        chmod(f.path, 0o755)
        return NSWorkspace.shared.open(f)
    }

    /// 診斷檔到桌面
    static func diagnostics() -> URL? {
        var s = Doctor.run(deep: true).text
        s += "\n── 設定 ──\n"
        if let d = try? Data(contentsOf: ConfigStore.shared.url), var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            // 會前重點是使用者打的會議內容，不進診斷檔；只留「有沒有填」
            for k in ["lastBrief", "brief"] where obj[k] != nil { obj[k] = "（已遮蔽）" }
            if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]), let t = String(data: out, encoding: .utf8) { s += t + "\n" }
        }
        s += "\n── 系統 ──\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)；記憶體 \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)GB；app \(HearbyVersion.version) build \(HearbyVersion.build)\n"
        s += "\n── 紀錄檔最後 300 行 ──\n"
        if let log = try? String(contentsOf: HearbyLog.file, encoding: .utf8) { s += log.split(separator: "\n").suffix(300).joined(separator: "\n") } else { s += "（沒有紀錄檔）" }
        // 帳號名不必跟著診斷檔出去：家目錄一律寫成 ~
        s = s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Hearby診斷_\(f.string(from: Date())).txt")
        do { try s.write(to: url, atomically: true, encoding: .utf8); return url } catch { HearbyLog.write("diagnostics export fail: \(error)"); return nil }
    }
}
