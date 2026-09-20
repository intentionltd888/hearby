// Paths — 檔案落點的唯一真相（零 AppKit）
//
// 使用者資料全在 ~/Hearby/（家目錄，零權限彈窗）：
//   ~/Hearby/CLAUDE.md  AGENTS.md            ← 給 AI 讀的入口
//   ~/Hearby/會議/<日期_時間_標題>/           ← 每場一夾：.m4a .md .docx (.pdf) meta.json
//   ~/Hearby/memory/                          ← 五檔 + index.json
//   ~/Hearby/templates/                       ← 使用者自己的範本（優先於 app 內建）
// 程式自己的東西（設定、下載暫存、log）在 ~/Library/Application Support/Hearby/ 與 ~/Library/Logs/Hearby/。
//
// 三個環境變數只給測試與開發用（沙箱原則：測試永遠不能寫進真資料夾）：
//   HEARBY_OUTPUT_ROOT   取代 ~/Hearby/
//   HEARBY_SUPPORT_DIR   取代 Application Support/Hearby/
//   HEARBY_LOG_DIR       取代 Logs/Hearby/

import Foundation

public enum Paths {
    static let fm = FileManager.default

    /// 使用者資料根：環境變數 > config.outputRoot > ~/Hearby
    public static var root: URL {
        if let e = ProcessInfo.processInfo.environment["HEARBY_OUTPUT_ROOT"], !e.isEmpty {
            return URL(fileURLWithPath: e, isDirectory: true)
        }
        if let c = ConfigStore.shared.current.outputRoot, !c.isEmpty {
            return URL(fileURLWithPath: (c as NSString).expandingTildeInPath, isDirectory: true)
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Hearby", isDirectory: true)
    }

    public static var meetings: URL { root.appendingPathComponent("會議", isDirectory: true) }
    public static var memory: URL { root.appendingPathComponent("memory", isDirectory: true) }
    public static var userTemplates: URL { root.appendingPathComponent("templates", isDirectory: true) }

    /// 選填的第二落點（例如同步到別的資料夾）；nil＝不寫副本
    public static var mirror: URL? {
        guard let m = ConfigStore.shared.current.mirrorDir, !m.isEmpty else { return nil }
        return URL(fileURLWithPath: (m as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// 程式資料（設定、下載暫存）
    public static var support: URL {
        if let e = ProcessInfo.processInfo.environment["HEARBY_SUPPORT_DIR"], !e.isEmpty {
            return URL(fileURLWithPath: e, isDirectory: true)
        }
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hearby", isDirectory: true)
    }

    public static var logs: URL {
        if let e = ProcessInfo.processInfo.environment["HEARBY_LOG_DIR"], !e.isEmpty {
            return URL(fileURLWithPath: e, isDirectory: true)
        }
        return fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Hearby", isDirectory: true)
    }

    /// 建齊所有資料夾（冪等）。回傳建了哪些（第一次啟動要顯示給人看）
    @discardableResult
    public static func ensure() throws -> [URL] {
        var made: [URL] = []
        for u in [root, meetings, memory, userTemplates, support, logs] {
            if !fm.fileExists(atPath: u.path) {
                try fm.createDirectory(at: u, withIntermediateDirectories: true)
                made.append(u)
            }
        }
        return made
    }

    /// 每場會議的夾名：<yyyy-MM-dd_HHmm_標題>（沿用舊格式，歷來會議掃描不用重寫）
    public static func meetingFolderName(date: Date, title: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return "\(f.string(from: date))_\(safeTitle(title))"
    }

    /// 檔名安全：去掉路徑分隔與控制字元，空的給「未命名」
    public static func safeTitle(_ s: String) -> String {
        // 只擋 C0／C1 控制字元與換行。不用 .controlCharacters：它連格式字元（ZWJ、變體選擇符）都算，合成 emoji 會被拆開
        var bad = CharacterSet(charactersIn: "/:\\").union(.newlines)
        bad.insert(charactersIn: "\u{00}"..."\u{1F}"); bad.insert(charactersIn: "\u{7F}"..."\u{9F}")
        let t = s.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "未命名" }
        // 檔名上限是 255 **bytes**：前面還有日期 16 bytes、後面有 `_舊版NN.md` 這類尾巴，標題收在 180 bytes 內
        var out = String(t.prefix(60))
        while out.utf8.count > 180 { out.removeLast() }
        out = out.trimmingCharacters(in: .whitespaces)   // 截完可能剛好停在空白：夾名以空白結尾在 SMB／exFAT 上會出事
        return out.isEmpty ? "未命名" : out
    }

    /// 這個資料夾能不能寫（doctor 用）。**不建資料夾**：doctor 只看不動；還不存在就看上一層能不能建。
    public static func isWritable(_ u: URL) -> Bool {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: u.path, isDirectory: &isDir) {
            guard isDir.boolValue else { return false }
            return fm.isWritableFile(atPath: u.path)
        }
        return fm.isWritableFile(atPath: u.deletingLastPathComponent().path)
    }
}
