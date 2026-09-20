// DocBuilder — 紀錄 md → 文件區塊（三情境各一套版型；HTML／DOCX 兩個渲染器共用同一份區塊）
import Foundation

public enum DocBlock: Equatable {
    case title(String)
    case meta([(String, String)])
    case summary(label: String, lines: [String])
    case heading(String)
    case subheading(String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case qa(question: String, answers: [String])
    case quote(String)
    case todos([(item: String, owner: String, due: String, done: Bool)])

    public static func == (a: DocBlock, b: DocBlock) -> Bool {
        switch (a, b) {
        case (.title(let x), .title(let y)): return x == y
        case (.heading(let x), .heading(let y)): return x == y
        case (.paragraph(let x), .paragraph(let y)): return x == y
        default: return false
        }
    }
}

public struct DocModel {
    public var scene: RecordScene
    public var header: DocHeader
    public var doctype: String
    public var blocks: [DocBlock]
    public var footer: String
}

public enum DocBuilder {
    static let ts = #"\s*\[(?:\d{1,2}:)?\d{1,3}:[0-5]\d\]"#
    static func strip(_ s: String) -> String { s.replacingOccurrences(of: ts, with: "", options: .regularExpression) }

    public static func build(md: String, header h: DocHeader? = nil) -> DocModel {
        let rec = RecordMD.parse(md: md)
        let header = h ?? DocHeader.prefill(md: md)
        let scene = rec.scene
        let L = header.language
        func t(_ k: String) -> String { DocLabels.t(k, L) }
        var blocks: [DocBlock] = []
        blocks.append(.title(header.title))
        var meta: [(String, String)] = []
        if !header.date.isEmpty { meta.append((t("日期"), header.date)) }
        if !rec.parts.dur.isEmpty { meta.append((t("時長"), DocLabels.duration(rec.parts.dur, L))) }
        switch scene {
        case .meeting:
            if !header.units.isEmpty { meta.append((t("與會單位"), header.units)) }
            if !header.attendees.isEmpty { meta.append((t("與會者"), header.attendees)) }
        case .interview:
            if !header.units.isEmpty { meta.append((t("單位"), header.units)) }
            if !header.attendees.isEmpty { meta.append((t("受訪者"), header.attendees)) }
        case .note:
            if !header.units.isEmpty { meta.append((t("主題"), header.units)) }
        }
        if !header.recorder.isEmpty { meta.append((t(scene == .interview ? "訪談／記錄" : "記錄"), header.recorder)) }
        blocks.append(.meta(meta))

        let rawSummary = (rec.section("摘要") ?? rec.section("一句話") ?? []).filter { $0 != "---" && !$0.isEmpty }
        let summary = rawSummary.filter { !$0.hasPrefix("（") }
        if !summary.isEmpty { blocks.append(.summary(label: t(scene == .note ? "一句話" : "摘要"), lines: summary)) }
        else if let note = rawSummary.first(where: { $0.hasPrefix("（") }) { blocks.append(.paragraph(note)) }

        switch scene {
        case .meeting:
            if let d = rec.section("決議"), !d.isEmpty, !(d.count == 1 && (d[0].contains("無明確決議") || d[0].lowercased().contains("no explicit decision") || d[0].contains("明確な決定"))) {
                blocks.append(.heading(t("決議"))); blocks.append(.numbered(d))
            }
            if !rec.todos.isEmpty { blocks.append(.heading(t("待辦"))); blocks.append(.todos(rec.todos)) }
            if let lines = rec.section("重點"), !lines.isEmpty {
                blocks.append(.heading(t("重點"))); blocks += grouped(lines, asParagraph: false)
            }
            if let q = rec.section("開放問題"), !q.isEmpty, !(q.count == 1 && q[0] == "無") { blocks.append(.heading(t("待確認"))); blocks.append(.bullets(q)) }
            if let b = rec.section("會前重點對照"), !b.isEmpty { blocks.append(.heading(t("會前重點下落"))); blocks.append(.bullets(b)) }
        case .interview:
            if let lines = rec.section("內容"), !lines.isEmpty {
                blocks.append(.heading(t("內容")))
                var q: String? = nil
                var answers: [String] = []
                func flush() { if let qq = q { blocks.append(.qa(question: qq, answers: answers)) }; q = nil; answers = [] }
                for l in lines {
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("**問"), t.hasSuffix("**") { flush(); q = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "問：", with: ""); continue }
                    if t.hasPrefix("**"), t.hasSuffix("**") { flush(); blocks.append(.subheading(t.replacingOccurrences(of: "**", with: ""))); continue }
                    var a = t
                    if a.hasPrefix("答：") { a = String(a.dropFirst(2)) }
                    if q == nil { blocks.append(.paragraph(a)) } else { answers.append(a) }
                }
                flush()
            }
            if let qs = rec.section("引言"), !qs.isEmpty, !(qs.count == 1 && qs[0] == "無") {
                blocks.append(.heading(t("引言")))
                for l in qs { blocks.append(.quote(l)) }
            }
            if !rec.todos.isEmpty { blocks.append(.heading(t("待辦"))); blocks.append(.todos(rec.todos)) }
        case .note:
            if let lines = rec.section("內容"), !lines.isEmpty {
                blocks.append(.heading(t("內容"))); blocks += grouped(lines, asParagraph: true)
            }
            if !rec.todos.isEmpty { blocks.append(.heading(t("待辦"))); blocks.append(.todos(rec.todos)) }
        }
        if let l = rec.section("參考連結"), !l.isEmpty { blocks.append(.heading(t("參考連結"))); blocks.append(.bullets(l)) }
        let footer = [header.company, header.title, header.date].filter { !$0.isEmpty }.joined(separator: "　·　")
        return DocModel(scene: scene, header: header, doctype: t(scene.mdTitle), blocks: blocks, footer: footer)
    }

    /// 「**小標**」＋其下條列／段落
    static func grouped(_ lines: [String], asParagraph: Bool) -> [DocBlock] {
        var out: [DocBlock] = []
        var buf: [String] = []
        func flush() {
            guard !buf.isEmpty else { return }
            if asParagraph { for p in buf { out.append(.paragraph(p)) } } else { out.append(.bullets(buf)) }
            buf = []
        }
        for l in lines {
            if l.hasPrefix("**"), l.hasSuffix("**") { flush(); out.append(.subheading(l.replacingOccurrences(of: "**", with: ""))) }
            else { buf.append(l) }
        }
        flush()
        return out
    }
}
