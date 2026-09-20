// DocLabels — 文件（PDF／Word）的欄位與節名，依語言換字；紀錄 md 本身的 ## 標題永遠是中文（解析靠它）
import Foundation

public enum DocLabels {
    static let en: [String: String] = [
        "會議紀錄": "Meeting Minutes", "會議記錄": "Meeting Minutes", "訪談": "Interview", "筆記": "Notes",
        "摘要": "Summary", "一句話": "In one line", "決議": "Decisions", "待辦": "Action items", "重點": "Key points",
        "內容": "Content", "待確認": "Open questions", "引言": "Quotes", "會前重點下落": "Pre-meeting items", "參考連結": "Links",
        "日期": "Date", "時長": "Duration", "與會單位": "Parties", "與會者": "Attendees", "受訪者": "Interviewee", "單位": "Organization",
        "主題": "Topic", "記錄": "Recorded by", "訪談／記錄": "Interviewer / notes", "事項": "Item", "負責人": "Owner", "期限": "Due", "問：": "Q: ",
    ]
    static let ja: [String: String] = [
        "會議紀錄": "議事録", "會議記錄": "議事録", "訪談": "インタビュー", "筆記": "ノート",
        "摘要": "要約", "一句話": "ひとことで", "決議": "決定事項", "待辦": "アクション", "重點": "要点",
        "內容": "内容", "待確認": "未確認事項", "引言": "引用", "會前重點下落": "事前項目", "參考連結": "リンク",
        "日期": "日付", "時長": "所要時間", "與會單位": "参加組織", "與會者": "出席者", "受訪者": "回答者", "單位": "組織",
        "主題": "テーマ", "記錄": "記録", "訪談／記錄": "聞き手／記録", "事項": "項目", "負責人": "担当", "期限": "期限", "問：": "Q：",
    ]
    public static func t(_ key: String, _ lang: String) -> String {
        switch lang {
        case "en": return en[key] ?? key
        case "ja": return ja[key] ?? key
        default: return key
        }
    }
    /// 時長「1分10秒」依語言換寫法
    public static func duration(_ zh: String, _ lang: String) -> String {
        switch lang {
        case "en": return zh.replacingOccurrences(of: "小時", with: "h ").replacingOccurrences(of: "分", with: "m ").replacingOccurrences(of: "秒", with: "s").trimmingCharacters(in: .whitespaces)
        case "ja": return zh.replacingOccurrences(of: "小時", with: "時間").replacingOccurrences(of: "秒", with: "秒")
        default: return zh
        }
    }
    public static func name(_ lang: String) -> String {
        switch lang { case "en": return "英文"; case "ja": return "日文"; case "zh-CN": return "簡體中文"; default: return lang }
    }
    /// 從檔名認語言：xxx.en.md → en
    public static func language(of url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        for l in ["en", "ja", "zh-CN"] where base.hasSuffix("." + l) { return l }
        return "zh"
    }
}
