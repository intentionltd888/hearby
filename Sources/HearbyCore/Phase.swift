// Phase — 狀態機的五態（Core 定義，UI 與殼共用；零 AppKit）
//
//   idle（待命）→ recording（錄音中）→ processing（處理中）→ done（剛完成）→ idle
//   任一態 → error（出事：系統聲掉了、空間快滿、電腦要睡了）→ idle
// 轉移規則在殼（AppState）；這裡只定義態與人看的名字。

import Foundation

public enum Phase: String, CaseIterable, Equatable {
    case idle, recording, processing, done, error

    public var label: String {
        switch self {
        case .idle: return "待命"
        case .recording: return "錄音中"
        case .processing: return "處理中"
        case .done: return "剛完成"
        case .error: return "有個問題"
        }
    }

    /// 合法轉移
    public func canGo(to next: Phase) -> Bool {
        switch (self, next) {
        case (.idle, .recording), (.recording, .processing), (.processing, .done), (.done, .idle),
             (_, .error), (.error, .idle), (.recording, .idle), (.done, .recording),
             // 匯入音檔與「補整理」不經過錄音：從待命或剛完成直接進處理中。
             // 少了這兩條時，圖形介面選完檔案（⌘O、面板按鈕）與按「補整理」都被這道閘默默擋掉、畫面毫無反應。
             (.idle, .processing), (.done, .processing):
            return true
        default:
            return false
        }
    }
}

/// 情境：會議（多人、出紀錄）／採訪（一問一答、出訪談稿）／筆記（一個人講、出一篇文章）。
/// 線上／現場另外用開關（決定要不要開系統聲），不是情境。
public enum RecordScene: String, CaseIterable {
    case meeting, interview, note
    public var label: String {
        switch self {
        case .meeting: return "會議"
        case .interview: return "採訪"
        case .note: return "筆記"
        }
    }
    public var hint: String {
        switch self {
        case .meeting: return "多人開會：摘要、與會者、重點、決議、待辦"
        case .interview: return "一問一答：整理成可引用的訪談稿"
        case .note: return "一個人講：整理成一篇排版好的筆記"
        }
    }
    /// 紀錄 md 的一級標題
    public var mdTitle: String {
        switch self {
        case .meeting: return "會議紀錄"
        case .interview: return "訪談"
        case .note: return "筆記"
        }
    }
    /// 舊版寫進檔案的文件名（2.0.0 build 17 以前「會議記錄」是言部）。讀舊檔時兩種寫法都要認；既有資料夾不改名。
    public static let legacyMdTitles = ["會議記錄"]

    public static func from(mdTitle line: String) -> RecordScene {
        if line.hasPrefix("# 訪談") { return .interview }
        if line.hasPrefix("# 筆記") { return .note }
        return .meeting
    }
}

public enum HearbyVersion {
    public static let version = "2.0.0"
    public static let build = "18"
}
