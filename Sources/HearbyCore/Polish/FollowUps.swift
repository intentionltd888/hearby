// FollowUps — 紀錄裡的「## 之前的事」：帶進整理的待辦、案子、還沒定的事，這場有講到的，一件一行「- 事情 → 這場怎麼了 [mm:ss]」
//
// AI 寫（見 Prompt.memoryRules）；Hearby 守門：沒有時間戳的那一行不留（逐字稿沒講過＝不准寫），整節空了或只有「無」＝拿掉這一節。
// 記憶同步時（MemoryStore.sync）：寫「做完／不做了」的，把 OPEN.md 裡別場那一條（事項一字不差、還沒打勾）打勾——
// 改到既有的行之前先留 OPEN.md.bak-日期；打過勾的那一行之後算你改過的，那一場再同步也不會被改回去。
import Foundation

public enum FollowUps {
    public static let heading = "## 之前的事"
    static let stamp = #"\[(?:\d{1,2}:)?\d{1,3}:[0-5]\d\]"#
    static let doneWords = ["做完", "完成", "交了", "搞定", "不做了", "取消"]
    static let notDoneWords = ["沒做完", "還沒", "未完成", "沒完成", "不確定"]

    /// 整理結果裡的這一節：沒有時間戳的行拿掉；空了（或只剩「無」）整節拿掉
    public static func prune(_ notes: String) -> String {
        var lines = notes.components(separatedBy: "\n")
        guard let h = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }) else { return notes }
        var e = lines.count
        for i in (h + 1)..<lines.count where lines[i].hasPrefix("## ") { e = i; break }
        let kept = lines[(h + 1)..<e].filter { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- ") && t.range(of: stamp, options: .regularExpression) != nil
        }
        if kept.isEmpty {
            lines.removeSubrange(h..<e)
            if h > 0, h < lines.count, lines[h - 1].trimmingCharacters(in: .whitespaces).isEmpty, lines[h].trimmingCharacters(in: .whitespaces).isEmpty { lines.remove(at: h) }
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        } else {
            lines.replaceSubrange((h + 1)..<e, with: kept)
        }
        return lines.joined(separator: "\n")
    }

    /// 紀錄裡寫「做完／不做了」的事情（「- 事情 → 結果 [mm:ss]」的「事情」；事情寫成「事項｜負責人｜…」取第一欄）
    public static func doneItems(_ md: String) -> [String] {
        var out: [String] = []
        var inSec = false
        for raw in md.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("## ") { inSec = l == heading; continue }
            guard inSec, l.hasPrefix("- "), let arrow = l.range(of: "→") else { continue }
            let item = String(l[l.index(l.startIndex, offsetBy: 2)..<arrow.lowerBound]).components(separatedBy: "｜")[0].trimmingCharacters(in: .whitespaces)
            let result = String(l[arrow.upperBound...])
            guard !item.isEmpty, doneWords.contains(where: { result.contains($0) }), !notDoneWords.contains(where: { result.contains($0) }) else { continue }
            if !out.contains(item) { out.append(item) }
        }
        return out
    }

    /// OPEN.md：別場還沒打勾、事項一字不差的那一條打勾（這一場自己的不動——它跟著紀錄走）
    public static func tick(open text: String, done: [String], meeting: String) -> String {
        guard !done.isEmpty else { return text }
        return text.components(separatedBy: "\n").map { line -> String in
            guard line.hasPrefix("- [ ] ") else { return line }
            let cols = String(line.dropFirst(6)).components(separatedBy: "｜")
            let item = cols[0].trimmingCharacters(in: .whitespaces)
            let from = cols.count >= 4 ? cols[cols.count - 1].trimmingCharacters(in: .whitespaces) : ""
            guard done.contains(item), from != meeting else { return line }
            return "- [x] " + String(line.dropFirst(6))
        }.joined(separator: "\n")
    }
}
