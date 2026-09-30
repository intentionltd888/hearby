// Record — 紀錄 md 的結構解析、客戶版剝除（PDF／Word／xlsx 共用；格式一字不改）
import Foundation

public struct MeetingRecord {
    public var title = "會議紀錄"
    public var meta = ""
    public var sections: [(name: String, lines: [String])] = []
    public var declaredAttendees = ""
    public var todos: [(item: String, owner: String, due: String, done: Bool)] = []
    public var images: [String] = []
    public init() {}

    public func section(_ name: String) -> [String]? { sections.first { $0.name.contains(name) }?.lines }
    /// (日期, 時長, 自訂標題)
    public var parts: (date: String, dur: String, custom: String) {
        let metaParts = meta.components(separatedBy: "｜").map { $0.trimmingCharacters(in: .whitespaces) }
        let custom = metaParts.count > 2 ? metaParts[2...].joined(separator: "｜") : ""
        let dur = (metaParts.first(where: { $0.hasPrefix("時長") }) ?? "").replacingOccurrences(of: "時長", with: "").trimmingCharacters(in: .whitespaces)
        var date = ""
        if let r = title.range(of: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}"#, options: .regularExpression) { date = String(title[r]) }
        return (date, dur, custom)
    }
    public var summaryText: String { ((section("摘要") ?? section("一句話")) ?? []).joined(separator: " ") }
    public var isNote: Bool { scene == .note }
    public var scene: RecordScene { RecordScene.from(mdTitle: "# " + title) }
    public var people: [String] {
        (section("與會者") ?? []).map { l in
            var t = l.trimmingCharacters(in: .whitespaces)
            for sep in ["—", "──", "--"] { if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) } }
            return t.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && !$0.hasPrefix(">") }
    }
}

public enum RecordMD {
    public static func todoParts(_ raw: String) -> (item: String, owner: String, due: String) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.contains("｜") {
            let p = t.components(separatedBy: "｜").map { $0.trimmingCharacters(in: .whitespaces) }
            return (p[0], p.count > 1 ? p[1] : "", p.count > 2 ? p[2...].joined(separator: "｜") : "")
        }
        if t.hasSuffix("）"), let open = t.range(of: "（", options: .backwards) {
            let item = String(t[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
            let inner = String(t[open.upperBound...].dropLast())
            let p = inner.components(separatedBy: "；").map { $0.trimmingCharacters(in: .whitespaces) }
            return (item, p.first ?? "", p.count > 1 ? p[1] : "")
        }
        return (t, "", "")
    }

    public static func parse(md: String) -> MeetingRecord {
        var rec = MeetingRecord()
        var current: String? = nil
        var lines: [String] = []
        func flush() {
            if let c = current, !lines.isEmpty, !c.contains("待辦") { rec.sections.append((c, lines)) }
            lines = []
        }
        for rawLine in md.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") { rec.title = String(line.dropFirst(2)) }
            else if line.hasPrefix("> ") {
                if rec.meta.isEmpty { rec.meta = String(line.dropFirst(2)) }
                else if line.hasPrefix("> 與會者（你填的）：") { rec.declaredAttendees = String(line.dropFirst("> 與會者（你填的）：".count)).trimmingCharacters(in: .whitespaces) }
            } else if line.hasPrefix("## ") { flush(); current = String(line.dropFirst(3)) }
            else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                let done = !line.hasPrefix("- [ ] ")
                let p = todoParts(String(line.dropFirst(6)))
                if p.item != "無" { rec.todos.append((p.item, p.owner, p.due, done)) }
            } else if line.hasPrefix("![](") && line.hasSuffix(")") { rec.images.append(String(line.dropFirst(4).dropLast())) }
            else if line.hasPrefix("- ") { let t = String(line.dropFirst(2)); if t != "無" { lines.append(t) } }
            else if !line.isEmpty { lines.append(line) }
        }
        flush()
        if !rec.declaredAttendees.isEmpty, !rec.sections.contains(where: { $0.name.contains("與會者") }) {
            let names = rec.declaredAttendees.components(separatedBy: CharacterSet(charactersIn: "、,，")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !names.isEmpty { rec.sections.insert(("與會者", names), at: 0) }
        }
        return rec
    }

    /// 客戶版：去逐字稿、去內部路徑與警告、去修正紀錄、剝時間戳
    public static func clientVersion(md: String) -> String {
        let record = md.components(separatedBy: "\n## 逐字稿").first ?? md
        var out: [String] = []
        var inAttendees = false
        var skipSection = false
        for raw in record.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") { skipSection = line.contains("修正紀錄") }
            if skipSection { continue }
            if line.contains("模型未交代此條") || line.contains("AI 整理未執行") { continue }
            if line.hasPrefix("> 音檔：") || line.hasPrefix("> ⚠") || line.hasPrefix("> 本機模型整理") || line.hasPrefix("> 名字更正") || line.hasPrefix("> 聲紋") || line == "---" { continue }
            if line.hasPrefix("（AI 整理失敗") || line.hasPrefix("（AI 整理已關閉") || line.hasPrefix("（AI 整理進行中") || line.hasPrefix("（只有逐字稿") {
                out.append("（本場僅整理逐字稿，未附 AI 摘要）")
                continue
            }
            if line.hasPrefix("## ") { inAttendees = line.contains("與會者") }
            if inAttendees, line.hasPrefix("- "), let r = line.range(of: "—") {
                out.append(String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces))
                continue
            }
            out.append(raw)
        }
        return out.joined(separator: "\n").replacingOccurrences(of: #"\s*\[(?:\d{1,2}:)?\d{1,3}:[0-5]\d\]"#, with: "", options: .regularExpression)
    }

    /// 只讀檔頭若干位元組（清單不整份讀）
    public static func head(of url: URL, maxBytes: Int = 4096) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        guard let nl = data.lastIndex(of: UInt8(ascii: "\n")) else { return nil }
        return String(data: data[..<nl], encoding: .utf8)
    }

    /// 逐字稿段（「## 逐字稿」之後）
    public static func transcript(of md: String) -> String? {
        guard let r = md.range(of: "## 逐字稿", options: .backwards) else { return nil }
        let t = String(md[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 改標題：表頭第一行「> Hearby 錄音｜時長 …｜標題」的標題換成新的（原本沒有標題就接在後面）；「> 音檔：路徑」交給 audio 換
    /// （回 nil＝不動）。只看第一個「## 」之前的表頭；第一行不是「…｜時長 …」的格式就不動它；其他行一字不改
    public static func retitled(md: String, title: String, audio: (String) -> String? = { _ in nil }) -> String {
        var lines = md.components(separatedBy: "\n")
        var sawHead = false
        for i in lines.indices {
            let cr = lines[i].hasSuffix("\r")
            let line = cr ? String(lines[i].dropLast()) : lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { break }
            guard trimmed.hasPrefix("> "), let at = line.range(of: "> ") else { continue }
            let lead = String(line[..<at.lowerBound])
            let body = String(trimmed.dropFirst(2))
            if !sawHead {
                sawHead = true
                let parts = body.components(separatedBy: "｜")
                guard parts.count >= 2, parts[1].trimmingCharacters(in: .whitespaces).hasPrefix("時長") else { continue }
                lines[i] = lead + "> " + (Array(parts.prefix(2)) + [title]).joined(separator: "｜") + (cr ? "\r" : "")
            } else if body.hasPrefix("音檔：") {
                let path = String(body.dropFirst("音檔：".count)).trimmingCharacters(in: .whitespaces)
                if let p = audio(path) { lines[i] = lead + "> 音檔：" + p + (cr ? "\r" : "") }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 覆寫前備份成 _舊版N.md
    public static func backupIfExists(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 0 else { return }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "md" : url.pathExtension
        var k = 1
        var bak = dir.appendingPathComponent("\(base)_舊版\(k).\(ext)")
        while fm.fileExists(atPath: bak.path), k < 50 { k += 1; bak = dir.appendingPathComponent("\(base)_舊版\(k).\(ext)") }
        // 第 50 份也佔了：用時間戳另起一份，永遠不覆寫既有備份
        if fm.fileExists(atPath: bak.path) { bak = dir.appendingPathComponent("\(base)_舊版_\(Int(Date().timeIntervalSince1970)).\(ext)") }
        // 位元組複製：內容不是 UTF-8 也照樣備得到
        do { try fm.copyItem(at: url, to: bak) } catch { HearbyLog.write("backup fail \(url.lastPathComponent): \(error.localizedDescription)") }
    }
}
