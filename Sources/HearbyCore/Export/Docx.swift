// Docx — 純 Swift 產 .docx（OOXML）：標題、表頭表、摘要框、小標、段落、條列、編號、問答、引言、待辦表、頁尾
// Word 與 Pages 都直接開；不走 textutil（它會把表格與底色弄丟）。字型 PingFang TC；尺寸單位＝半點。
import Foundation

public enum Docx {
    static func x(_ s: String) -> String {
        // XML 1.0 合法字元：tab／換行／0x20 以上，但不含 U+FFFE、U+FFFF（Word 遇到會拒開整份檔）
        let cleaned = String(s.unicodeScalars.filter { ($0.value >= 0x20 || $0 == "\t" || $0 == "\n") && $0.value != 0xFFFE && $0.value != 0xFFFF })
        return cleaned.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    /// 行內：**粗體** 切成 run
    static func runs(_ s: String, size: Int = 21, color: String? = nil, bold: Bool = false, italic: Bool = false) -> String {
        var out = ""
        var text = DocBuilder.strip(s)
        while let r = text.range(of: #"\*\*([^*]+)\*\*"#, options: .regularExpression) {
            let before = String(text[..<r.lowerBound])
            let inner = String(text[r]).replacingOccurrences(of: "**", with: "")
            if !before.isEmpty { out += run(before, size: size, color: color, bold: bold, italic: italic) }
            out += run(inner, size: size, color: color, bold: true, italic: italic)
            text = String(text[r.upperBound...])
        }
        if !text.isEmpty { out += run(text, size: size, color: color, bold: bold, italic: italic) }
        return out
    }
    static func run(_ s: String, size: Int, color: String?, bold: Bool, italic: Bool) -> String {
        var rpr = "<w:rFonts w:ascii=\"PingFang TC\" w:hAnsi=\"PingFang TC\" w:eastAsia=\"PingFang TC\"/>"
        if bold { rpr += "<w:b/>" }
        if italic { rpr += "<w:i/>" }
        if let c = color { rpr += "<w:color w:val=\"\(c)\"/>" }
        rpr += "<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/>"
        return "<w:r><w:rPr>\(rpr)</w:rPr><w:t xml:space=\"preserve\">\(x(s))</w:t></w:r>"
    }
    static func p(_ content: String, style: String? = nil, before: Int = 0, after: Int = 120, indentLeft: Int? = nil, hanging: Int? = nil, shade: String? = nil, leftBorder: String? = nil, keepNext: Bool = false, jc: String? = nil) -> String {
        var ppr = ""
        if let s = style { ppr += "<w:pStyle w:val=\"\(s)\"/>" }
        if keepNext { ppr += "<w:keepNext/>" }
        if let lb = leftBorder { ppr += "<w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"\(lb)\"/></w:pBdr>" }
        if let sh = shade { ppr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(sh)\"/>" }
        ppr += "<w:spacing w:before=\"\(before)\" w:after=\"\(after)\" w:line=\"320\" w:lineRule=\"auto\"/>"
        if let l = indentLeft { ppr += "<w:ind w:left=\"\(l)\"" + (hanging.map { " w:hanging=\"\($0)\"" } ?? "") + "/>" }
        if let j = jc { ppr += "<w:jc w:val=\"\(j)\"/>" }
        return "<w:p><w:pPr>\(ppr)</w:pPr>\(content)</w:p>"
    }
    static func cell(_ content: String, width: Int, fill: String? = nil, bottom: String? = "E2E2DF", bottomSz: Int = 4) -> String {
        var tcpr = "<w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>"
        if let b = bottom { tcpr += "<w:tcBorders><w:top w:val=\"nil\"/><w:left w:val=\"nil\"/><w:right w:val=\"nil\"/><w:bottom w:val=\"single\" w:sz=\"\(bottomSz)\" w:color=\"\(b)\"/></w:tcBorders>" }
        else { tcpr += "<w:tcBorders><w:top w:val=\"nil\"/><w:left w:val=\"nil\"/><w:right w:val=\"nil\"/><w:bottom w:val=\"nil\"/></w:tcBorders>" }
        if let f = fill { tcpr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(f)\"/>" }
        tcpr += "<w:tcMar><w:top w:w=\"80\" w:type=\"dxa\"/><w:bottom w:w=\"80\" w:type=\"dxa\"/><w:left w:w=\"100\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tcMar>"
        return "<w:tc><w:tcPr>\(tcpr)</w:tcPr>\(content)</w:tc>"
    }
    static func table(rows: [String], widths: [Int]) -> String {
        let grid = widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined()
        let total = widths.reduce(0, +)
        return "<w:tbl><w:tblPr><w:tblW w:w=\"\(total)\" w:type=\"dxa\"/><w:tblLayout w:type=\"fixed\"/><w:tblBorders><w:top w:val=\"nil\"/><w:left w:val=\"nil\"/><w:bottom w:val=\"nil\"/><w:right w:val=\"nil\"/><w:insideH w:val=\"nil\"/><w:insideV w:val=\"nil\"/></w:tblBorders></w:tblPr><w:tblGrid>\(grid)</w:tblGrid>" + rows.joined() + "</w:tbl>"
    }

    public static func document(model m: DocModel) -> String {
        var body = ""
        let ink = "1A1A1A", grey = "6B6B6B", light = "8A8A8A"
        // 頂列：公司 ｜ 文件類型（用兩欄表＋底線）
        let top = table(rows: [
            "<w:tr>" + cell(p(run(m.header.company, size: 22, color: ink, bold: true, italic: false), after: 0), width: 6000, bottom: ink, bottomSz: 12)
                + cell(p(run(m.doctype, size: 18, color: grey, bold: false, italic: false), after: 0, jc: "right"), width: 3360, bottom: ink, bottomSz: 12) + "</w:tr>"
        ], widths: [6000, 3360])
        body += top
        for b in m.blocks {
            switch b {
            case .title(let t):
                body += p(run(t, size: 44, color: ink, bold: true, italic: false), before: 360, after: 200)
            case .meta(let rows):
                var trs: [String] = []
                for (k, v) in rows {
                    trs.append("<w:tr>" + cell(p(run(k, size: 19, color: grey, bold: false, italic: false), after: 0), width: 1800, bottom: nil)
                        + cell(p(run(v, size: 19, color: ink, bold: false, italic: false), after: 0), width: 7560, bottom: nil) + "</w:tr>")
                }
                body += table(rows: trs, widths: [1800, 7560])
                body += p("", after: 200)
            case .summary(let label, let lines):
                body += p(run(label, size: 17, color: grey, bold: true, italic: false), before: 120, after: 40, shade: "F4F4F2", leftBorder: ink, keepNext: true)
                for (i, l) in lines.enumerated() { body += p(runs(l, size: 21, color: ink), after: i == lines.count - 1 ? 240 : 60, shade: "F4F4F2", leftBorder: ink) }
            case .heading(let t):
                body += p(run(t, size: 24, color: ink, bold: true, italic: false), style: "Heading1", before: 360, after: 120, keepNext: true)
            case .subheading(let t):
                body += p(run(t, size: 21, color: ink, bold: true, italic: false), style: "Heading2", before: 200, after: 60, keepNext: true)
            case .paragraph(let t):
                body += p(runs(t, size: 21, color: ink), after: 140, jc: "both")
            case .bullets(let l):
                for s in l { body += p(run("–  ", size: 21, color: light, bold: false, italic: false) + runs(s, size: 21, color: ink), after: 60, indentLeft: 360, hanging: 360) }
                body += p("", after: 80)
            case .numbered(let l):
                for (i, s) in l.enumerated() { body += p(run("\(i + 1).  ", size: 21, color: ink, bold: true, italic: false) + runs(s, size: 21, color: ink), after: 80, indentLeft: 420, hanging: 420) }
            case .qa(let q, let a):
                body += p(run(DocLabels.t("問：", m.header.language), size: 21, color: ink, bold: true, italic: false) + runs(q, size: 21, color: ink, bold: true), before: 160, after: 60, keepNext: true)
                for (i, s) in a.enumerated() { body += p(runs(s, size: 21, color: ink), after: i == a.count - 1 ? 160 : 80, indentLeft: 300, leftBorder: "D9D9D6", jc: "both") }
            case .quote(let t):
                body += p(runs(t, size: 22, color: ink), before: 80, after: 120, indentLeft: 240, shade: "F4F4F2")
            case .todos(let ts):
                let widths = [720, 4680, 1880, 2080]
                var trs: [String] = []
                trs.append("<w:tr>" + zip(["#", DocLabels.t("事項", m.header.language), DocLabels.t("負責人", m.header.language), DocLabels.t("期限", m.header.language)], widths).map { cell(p(run($0.0, size: 18, color: ink, bold: true, italic: false), after: 0), width: $0.1, bottom: ink, bottomSz: 10) }.joined() + "</w:tr>")
                for (i, t) in ts.enumerated() {
                    let c = t.done ? light : ink
                    trs.append("<w:tr>" + cell(p(run("\(i + 1)", size: 20, color: c, bold: false, italic: false), after: 0), width: widths[0])
                        + cell(p(runs(t.item, size: 20, color: c), after: 0), width: widths[1])
                        + cell(p(run(t.owner, size: 20, color: c, bold: false, italic: false), after: 0), width: widths[2])
                        + cell(p(run(t.due, size: 20, color: c, bold: false, italic: false), after: 0), width: widths[3]) + "</w:tr>")
                }
                body += table(rows: trs, widths: widths)
                body += p("", after: 120)
            }
        }
        let sect = "<w:sectPr><w:footerReference w:type=\"default\" r:id=\"rIdFooter\"/><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1300\" w:right=\"1273\" w:bottom=\"1200\" w:left=\"1273\" w:header=\"700\" w:footer=\"600\" w:gutter=\"0\"/></w:sectPr>"
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><w:body>\(body)\(sect)</w:body></w:document>"
    }

    static func footerXML(_ text: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:ftr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" + p(run(text, size: 16, color: "8A8A8A", bold: false, italic: false), after: 0) + "</w:ftr>"
    }
    static let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="PingFang TC" w:hAnsi="PingFang TC" w:eastAsia="PingFang TC"/><w:sz w:val="21"/><w:szCs w:val="21"/><w:lang w:val="zh-TW" w:eastAsia="zh-TW"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="320" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:pBdr><w:bottom w:val="single" w:sz="4" w:space="4" w:color="D9D9D6"/></w:pBdr><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="21"/></w:rPr></w:style>
        </w:styles>
        """

    /// 寫出 .docx；回傳路徑
    public static func write(model m: DocModel, to dest: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("hearby-docx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }   // 成功失敗都清：暫存夾裡是紀錄內容
        try fm.createDirectory(at: tmp.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("word/_rels"), withIntermediateDirectories: true)
        let contentTypes = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
            <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
            </Types>
            """
        let rels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
            </Relationships>
            """
        let docRels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
            <Relationship Id="rIdFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>
            </Relationships>
            """
        try contentTypes.write(to: tmp.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rels.write(to: tmp.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try docRels.write(to: tmp.appendingPathComponent("word/_rels/document.xml.rels"), atomically: true, encoding: .utf8)
        try styles.write(to: tmp.appendingPathComponent("word/styles.xml"), atomically: true, encoding: .utf8)
        try footerXML(m.footer).write(to: tmp.appendingPathComponent("word/footer1.xml"), atomically: true, encoding: .utf8)
        try document(model: m).write(to: tmp.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        let tmpOut = fm.temporaryDirectory.appendingPathComponent("hearby-\(UUID().uuidString).docx")
        defer { try? fm.removeItem(at: tmpOut) }
        let z = runProcess("/usr/bin/zip", ["-r", "-X", "-q", tmpOut.path, "."], timeout: 60, cwd: tmp.path)
        guard z.status == 0, fm.fileExists(atPath: tmpOut.path) else { throw HearbyError("docx 打包失敗：\(z.stderr)") }
        if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: tmpOut) } else { try fm.moveItem(at: tmpOut, to: dest) }
        try? fm.removeItem(at: tmp)
    }
}
