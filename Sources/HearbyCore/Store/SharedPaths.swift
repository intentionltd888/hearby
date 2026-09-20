// SharedPaths — 跟姊妹 app（Talky）共用的東西：聽打模型與常用詞
//
// ⚠ 這個檔是整個倉唯一可以出現舊資料夾名的地方（scripts/check-clean.sh 白名單）。
//   舊版 Hearby（改名前）把模型與常用詞放在 ~/Library/Application Support/WereHear/；
//   Talky 也借用同一個夾（它的 SharedPaths.swift 指這裡）。兩個 app 共用 1.6 GB 模型不重下、
//   共用一份常用詞不重打，是刻意的。這裡只讀不刪；借不到就走 Hearby 自己的 Paths.support。

import Foundation

public enum SharedPaths {
    /// 舊資料夾名（借模型與詞庫用）
    private static let legacyFolderName = "WereHear"

    public static let whisperModelFile = "ggml-large-v3-turbo.bin"

    /// 舊夾（不存在＝nil，一切走自己的路徑）
    public static var legacySupport: URL? {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(legacyFolderName)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// 模型搜尋順序：舊夾（已下載就不重下）→ 自己的
    public static func modelSearchPaths(_ file: String = whisperModelFile) -> [URL] {
        var out: [URL] = []
        if let l = legacySupport { out.append(l.appendingPathComponent("models/\(file)")) }
        out.append(Paths.support.appendingPathComponent("models/\(file)"))
        return out
    }

    /// 找得到的模型檔；nil＝要下載
    public static func installedModel(_ file: String = whisperModelFile) -> URL? {
        modelSearchPaths(file).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 常用詞：設定指定 > 舊夾那份（跟 Talky 共用）> 自己的
    public static var glossary: URL {
        if let g = ConfigStore.shared.current.glossaryPath, !g.isEmpty {
            return URL(fileURLWithPath: (g as NSString).expandingTildeInPath)
        }
        // 沙箱（HEARBY_SUPPORT_DIR 有設＝測試或試跑）一律用沙箱自己的，不碰共用那份：
        // 常用詞是「會被寫」的檔，沙箱裡的程式寫到真檔就是洗掉使用者的詞庫。模型只讀，照舊可以借。
        let sandboxed = !(ProcessInfo.processInfo.environment["HEARBY_SUPPORT_DIR"] ?? "").isEmpty
        if !sandboxed, let l = legacySupport {
            let u = l.appendingPathComponent("glossary.txt")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return Paths.support.appendingPathComponent("glossary.txt")
    }
}
