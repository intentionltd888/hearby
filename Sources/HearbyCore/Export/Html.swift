// Html — PDF 版型（中性文件，不放 Hearby 品牌）：吃 DocBuilder 的區塊；三情境版型差在區塊順序與樣式
import Foundation

public struct DocHeader: Equatable {
    public var title = ""
    public var company = ""
    public var units = ""
    public var recorder = ""
    public var date = ""
    public var attendees = ""
    public var language = "zh"
    public init() {}
    public static func prefill(md: String, language: String = "zh") -> DocHeader {
        let rec = RecordMD.parse(md: md)
        let p = rec.parts
        var h = DocHeader()
        h.language = language
        h.title = p.custom.isEmpty ? DocLabels.t(rec.scene.mdTitle, language) : p.custom
        h.date = p.date
        h.attendees = rec.people.map { n in
            var t = n
            for m in ["我方", "遠端", "現場", "電話端", "推測", "訪談者", "受訪者"] { t = t.replacingOccurrences(of: "（\(m)）", with: "").replacingOccurrences(of: "(\(m))", with: "") }
            return t.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && $0 != "訪談者" }.joined(separator: "、")
        let c = ConfigStore.shared.current
        h.company = c.docCompany ?? ""
        h.recorder = c.docRecorder ?? ""
        return h
    }
}

public enum Html {
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    public static func inline(_ s: String) -> String {
        var t = escape(DocBuilder.strip(s))
        for (pat, open, close) in [(#"\*\*([^*]+)\*\*"#, "<b>", "</b>"), (#"`([^`]+)`"#, "<code>", "</code>")] {
            if let re = try? NSRegularExpression(pattern: pat) { t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "\(open)$1\(close)") }
        }
        return t
    }
    public static func plain(_ s: String) -> String { s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "") }

    public static func templateURL(_ name: String) -> URL? {
        var c = [Paths.userTemplates.appendingPathComponent(name)]
        if let e = ProcessInfo.processInfo.environment["HEARBY_TEMPLATES_DIR"], !e.isEmpty { c.append(URL(fileURLWithPath: e).appendingPathComponent(name)) }
        if let res = Bundle.main.resourceURL { c.append(res.appendingPathComponent("templates/\(name)")) }
        return c.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func render(md: String, header h: DocHeader? = nil) -> String {
        render(model: DocBuilder.build(md: md, header: h))
    }

    public static func render(model m: DocModel) -> String {
        var title = ""
        var meta = ""
        var body = ""
        for b in m.blocks {
            switch b {
            case .title(let t): title = escape(t)
            case .meta(let rows):
                meta = "<table class=\"meta\">" + rows.map { "<tr><th>\(escape($0.0))</th><td>\(escape($0.1))</td></tr>" }.joined() + "</table>"
            case .summary(let label, let lines):
                body += "<section class=\"summary\"><h2>\(escape(label))</h2>" + lines.map { "<p>\(inline($0))</p>" }.joined() + "</section>"
            case .heading(let t): body += "<h2>\(escape(t))</h2>"
            case .subheading(let t): body += "<h3>\(escape(t))</h3>"
            case .paragraph(let t): body += "<p class=\"para\">\(inline(t))</p>"
            case .bullets(let l): body += "<ul>" + l.map { "<li>\(inline($0))</li>" }.joined() + "</ul>"
            case .numbered(let l): body += "<ol class=\"decisions\">" + l.map { "<li>\(inline($0))</li>" }.joined() + "</ol>"
            case .qa(let q, let a):
                body += "<div class=\"qa\"><p class=\"q\">\(escape(DocLabels.t("問：", m.header.language)))\(inline(q))</p>" + a.map { "<p class=\"a\">\(inline($0))</p>" }.joined() + "</div>"
            case .quote(let t): body += "<blockquote>\(inline(t))</blockquote>"
            case .todos(let ts):
                let L = m.header.language
                body += "<table class=\"todo\"><thead><tr><th style=\"width:8%\">#</th><th style=\"width:50%\">\(DocLabels.t("事項", L))</th><th style=\"width:20%\">\(DocLabels.t("負責人", L))</th><th style=\"width:22%\">\(DocLabels.t("期限", L))</th></tr></thead><tbody>"
                for (i, t) in ts.enumerated() { body += "<tr\(t.done ? " class=\"done\"" : "")><td>\(i + 1)</td><td>\(inline(t.item))</td><td>\(escape(t.owner))</td><td>\(escape(t.due))</td></tr>" }
                body += "</tbody></table>"
            }
        }
        let tpl = (templateURL("pdf.html").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? builtin
        let values = ["company": escape(m.header.company), "doctype": escape(m.doctype), "title": title, "meta": meta, "body": body, "footer": escape(m.footer)]
        var out = ""
        var rest = Substring(tpl)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else { out += rest[open.lowerBound...]; rest = ""; break }
            let key = String(rest[open.upperBound..<close.lowerBound])
            out += values[key] ?? String(rest[open.lowerBound..<close.upperBound])   // 不認得的佔位原樣留著
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    public static let builtin = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>
        *{margin:0;padding:0;box-sizing:border-box;-webkit-print-color-adjust:exact}
        html,body{background:#FFFFFF}
        body{font-family:"PingFang TC","Noto Sans TC",-apple-system,sans-serif;color:#1A1A1A;font-size:10.5pt;line-height:1.7}
        @media screen{body{max-width:760px;margin:0 auto;padding:56px 48px}}
        .top{display:flex;justify-content:space-between;align-items:baseline;padding-bottom:10px;border-bottom:2px solid #1A1A1A}
        .company{font-size:11pt;font-weight:600;letter-spacing:.02em}
        .doctype{font-size:9pt;color:#6B6B6B;letter-spacing:.12em}
        h1{font-size:22pt;font-weight:700;line-height:1.3;margin:26px 0 14px}
        table.meta{border-collapse:collapse;margin-bottom:24px;font-size:9.5pt}
        table.meta th{text-align:left;font-weight:500;color:#6B6B6B;padding:3px 28px 3px 0;white-space:nowrap;vertical-align:top}
        table.meta td{padding:3px 0;vertical-align:top}
        .summary{background:#F4F4F2;border-left:3px solid #1A1A1A;padding:12px 16px;margin:0 0 6px}
        .summary h2{margin:0 0 4px;border:0;padding:0;font-size:9pt;color:#6B6B6B;letter-spacing:.08em}
        .summary p{font-size:10.5pt}
        h2{font-size:12pt;font-weight:700;margin:24px 0 8px;padding-bottom:5px;border-bottom:1px solid #D9D9D6;break-after:avoid-page}
        h3{font-size:10.5pt;font-weight:700;margin:12px 0 4px}
        p.para{margin:0 0 8px;text-align:justify}
        ul{list-style:none} li{padding:3px 0 3px 14px;position:relative}
        ul li::before{content:"–";position:absolute;left:0;color:#8A8A8A}
        ol.decisions{padding-left:22px} ol.decisions li{padding:4px 0;font-weight:500}
        .qa{margin:10px 0 14px;break-inside:avoid}
        .qa .q{font-weight:700;margin-bottom:4px}
        .qa .a{margin:0 0 6px 0;padding-left:14px;border-left:2px solid #D9D9D6;text-align:justify}
        blockquote{margin:8px 0;padding:8px 16px;background:#F4F4F2;font-size:11pt;line-height:1.6}
        table.todo{width:100%;border-collapse:collapse;margin-top:4px}
        table.todo th{text-align:left;font-size:9pt;font-weight:600;color:#1A1A1A;border-bottom:1.5px solid #1A1A1A;padding:6px 8px}
        table.todo td{padding:7px 8px;border-bottom:1px solid #E2E2DF;font-size:10pt;vertical-align:top}
        table.todo tr.done td{color:#8A8A8A;text-decoration:line-through}
        table.todo tr{break-inside:avoid}
        a{color:#1A1A1A}
        code{font-family:"SF Mono",Menlo,monospace;font-size:9pt;background:#F1F1EF;padding:0 3px;border-radius:2px}
        footer{margin-top:36px;padding-top:8px;border-top:1px solid #D9D9D6;font-size:8pt;color:#8A8A8A}
        </style></head><body>
        <div class="top"><span class="company">{{company}}</span><span class="doctype">{{doctype}}</span></div>
        <h1>{{title}}</h1>
        {{meta}}
        {{body}}
        <footer>{{footer}}</footer>
        </body></html>
        """
}
