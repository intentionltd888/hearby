// MeetingIndex — 掃 ~/Hearby/會議/ 下的每場資料夾（清單用；只讀檔頭不整份讀）
import Foundation

public struct MeetingItem: Identifiable, Equatable {
    public var id: String { dir.path }
    public let dir: URL
    public let mdURL: URL?
    public let folderName: String
    public let dateText: String
    public let title: String
    public var durText = ""
    public var gist = ""
    public let modified: Date?
    public var audio: URL? { dir.appendingPathComponent(folderName + ".m4a") }
}

public enum MeetingIndex {
    public static func scan() -> [MeetingItem] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.meetings, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var items: [MeetingItem] = []
        for d in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let base = d.lastPathComponent
            let contents = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
            let namedMD = d.appendingPathComponent(base + ".md")
            var mdURL: URL? = fm.fileExists(atPath: namedMD.path) ? namedMD : nil
            if mdURL == nil {
                let mds = contents.filter { $0.pathExtension.lowercased() == "md" && !$0.lastPathComponent.contains("_舊版") }
                if mds.count == 1 { mdURL = mds[0] }
            }
            guard mdURL != nil || base.range(of: #"^\d{4}-\d{2}-\d{2}_\d{4}"#, options: .regularExpression) != nil else { continue }
            let mod = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let (dateText, titleText) = split(folderName: base)
            var item = MeetingItem(dir: d, mdURL: mdURL, folderName: base, dateText: dateText, title: titleText.isEmpty ? base : titleText, modified: mod)
            if let md = mdURL, let head = RecordMD.head(of: md) {
                item.durText = head.components(separatedBy: "\n").first(where: { $0.hasPrefix("> ") && $0.contains("時長") })
                    .flatMap { $0.components(separatedBy: "｜").first(where: { $0.contains("時長") })?.replacingOccurrences(of: "時長", with: "").trimmingCharacters(in: .whitespaces) } ?? ""
                if let r = head.range(of: "## AI 會議摘要") ?? head.range(of: "## 摘要") ?? head.range(of: "## 一句話") {
                    let after = head[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    var s = after.components(separatedBy: "\n").first ?? ""
                    if let dot = s.firstIndex(of: "。") { s = String(s[...dot]) }
                    if s.count > 42 { s = String(s.prefix(42)) + "…" }
                    item.gist = s.trimmingCharacters(in: .whitespaces)
                }
            }
            items.append(item)
        }
        return items.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// yyyy-MM-dd_HHmm_標題 → ("yyyy-MM-dd HH:mm", 標題)
    public static func split(folderName: String) -> (String, String) {
        guard folderName.count >= 15, folderName[folderName.index(folderName.startIndex, offsetBy: 10)] == "_" else { return ("", folderName) }
        let d = String(folderName.prefix(10))
        let t = String(folderName.dropFirst(11).prefix(4))
        let rest = folderName.count > 16 ? String(folderName.dropFirst(16)) : ""
        return ("\(d) \(t.prefix(2)):\(t.suffix(2))", rest)
    }

    /// 搜說過的話：逐字稿全文 grep（回傳命中的場與那一行）
    public static func search(_ q: String, limit: Int = 50) -> [(item: MeetingItem, line: String)] {
        let needle = q.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return [] }
        var out: [(MeetingItem, String)] = []
        for item in scan() {
            guard let md = item.mdURL, let s = try? String(contentsOf: md, encoding: .utf8) else { continue }
            for line in s.components(separatedBy: "\n") where line.localizedCaseInsensitiveContains(needle) {
                out.append((item, line.trimmingCharacters(in: .whitespaces)))
                if out.count >= limit { return out }
            }
        }
        return out
    }
}
