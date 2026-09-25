// Export — record .md → documents for other people (Word .docx and a print layout in HTML, turned into PDF by the shell).
// Neutral documents: the company's name, no Hearby branding. Mirrors Export/DocLabels.swift, DocBuilder.swift, Docx.swift,
// Html.swift (DocHeader). Fonts: Microsoft JhengHei (every Windows 10/11 has it) instead of PingFang TC.
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace Hearby.Core;

public static class DocLabels
{
    static readonly Dictionary<string, string> En = new()
    {
        ["會議紀錄"] = "Meeting Minutes", ["會議記錄"] = "Meeting Minutes", ["訪談"] = "Interview", ["筆記"] = "Notes",
        ["摘要"] = "Summary", ["一句話"] = "In one line", ["決議"] = "Decisions", ["待辦"] = "Action items", ["重點"] = "Key points",
        ["內容"] = "Content", ["待確認"] = "Open questions", ["引言"] = "Quotes", ["會前重點下落"] = "Pre-meeting items", ["參考連結"] = "Links",
        ["日期"] = "Date", ["時長"] = "Duration", ["與會單位"] = "Parties", ["與會者"] = "Attendees", ["受訪者"] = "Interviewee", ["單位"] = "Organization",
        ["主題"] = "Topic", ["記錄"] = "Recorded by", ["訪談／記錄"] = "Interviewer / notes", ["事項"] = "Item", ["負責人"] = "Owner", ["期限"] = "Due", ["問："] = "Q: ",
    };
    static readonly Dictionary<string, string> Ja = new()
    {
        ["會議紀錄"] = "議事録", ["會議記錄"] = "議事録", ["訪談"] = "インタビュー", ["筆記"] = "ノート",
        ["摘要"] = "要約", ["一句話"] = "ひとことで", ["決議"] = "決定事項", ["待辦"] = "アクション", ["重點"] = "要点",
        ["內容"] = "内容", ["待確認"] = "未確認事項", ["引言"] = "引用", ["會前重點下落"] = "事前項目", ["參考連結"] = "リンク",
        ["日期"] = "日付", ["時長"] = "所要時間", ["與會單位"] = "参加組織", ["與會者"] = "出席者", ["受訪者"] = "回答者", ["單位"] = "組織",
        ["主題"] = "テーマ", ["記錄"] = "記録", ["訪談／記錄"] = "聞き手／記録", ["事項"] = "項目", ["負責人"] = "担当", ["期限"] = "期限", ["問："] = "Q：",
    };

    public static string T(string key, string lang) => lang switch
    {
        "en" => En.GetValueOrDefault(key, key),
        "ja" => Ja.GetValueOrDefault(key, key),
        _ => key,
    };

    /// Duration 「1分10秒」 in the document's language
    public static string Duration(string zh, string lang) => lang switch
    {
        "en" => Str.TrimWS(zh.Rep("小時", "h ").Rep("分", "m ").Rep("秒", "s")),
        "ja" => zh.Rep("小時", "時間"),
        _ => zh,
    };

    public static string Name(string lang) => lang switch { "en" => "英文", "ja" => "日文", "zh-CN" => "簡體中文", _ => lang };

    /// Language from the file name: xxx.en.md → en
    public static string LanguageOf(string path)
    {
        var b = Path.GetFileNameWithoutExtension(path);
        foreach (var l in new[] { "en", "ja", "zh-CN" }) if (b.Ends("." + l)) return l;
        return "zh";
    }
}

public sealed class DocHeader
{
    public string Title = "", Company = "", Units = "", Recorder = "", Date = "", Attendees = "", Language = "zh";

    public static DocHeader Prefill(string md, string language = "zh")
    {
        var rec = RecordMD.Parse(md);
        var p = rec.Parts;
        var h = new DocHeader { Language = language };
        h.Title = p.Custom.Length == 0 ? DocLabels.T(rec.Scene.MdTitle(), language) : p.Custom;
        h.Date = p.Date;
        h.Attendees = string.Join("、", rec.People.Select(n =>
        {
            var t = n;
            foreach (var m in new[] { "我方", "遠端", "現場", "電話端", "推測", "訪談者", "受訪者" }) t = t.Rep($"（{m}）", "").Rep($"({m})", "");
            return Str.TrimWS(t);
        }).Where(t => t.Length > 0 && t != "訪談者"));
        var c = ConfigStore.Shared.Current;
        h.Company = c.DocCompany ?? "";
        h.Recorder = c.DocRecorder ?? "";
        return h;
    }
}

public abstract record DocBlock
{
    public sealed record Title(string Text) : DocBlock;
    public sealed record Meta(List<(string Key, string Value)> Rows) : DocBlock;
    public sealed record Summary(string Label, List<string> Lines) : DocBlock;
    public sealed record Heading(string Text) : DocBlock;
    public sealed record Subheading(string Text) : DocBlock;
    public sealed record Paragraph(string Text) : DocBlock;
    public sealed record Bullets(List<string> Items) : DocBlock;
    public sealed record Numbered(List<string> Items) : DocBlock;
    public sealed record QA(string Question, List<string> Answers) : DocBlock;
    public sealed record Quote(string Text) : DocBlock;
    public sealed record Todos(List<Todo> Items) : DocBlock;
}

public sealed record DocModel(RecordScene Scene, DocHeader Header, string Doctype, List<DocBlock> Blocks, string Footer);

public static class DocBuilder
{
    static readonly Regex Ts = new(@"\s*\[(?:\d{1,2}:)?\d{1,3}:[0-5]\d\]", RegexOptions.CultureInvariant);
    public static string Strip(string s) => Ts.Replace(s, "");

    public static DocModel Build(string md, DocHeader? h = null)
    {
        var rec = RecordMD.Parse(md);
        var header = h ?? DocHeader.Prefill(md);
        var scene = rec.Scene;
        var L = header.Language;
        string T(string k) => DocLabels.T(k, L);
        var blocks = new List<DocBlock> { new DocBlock.Title(header.Title) };
        var meta = new List<(string, string)>();
        if (header.Date.Length > 0) meta.Add((T("日期"), header.Date));
        if (rec.Parts.Dur.Length > 0) meta.Add((T("時長"), DocLabels.Duration(rec.Parts.Dur, L)));
        switch (scene)
        {
            case RecordScene.Meeting:
                if (header.Units.Length > 0) meta.Add((T("與會單位"), header.Units));
                if (header.Attendees.Length > 0) meta.Add((T("與會者"), header.Attendees));
                break;
            case RecordScene.Interview:
                if (header.Units.Length > 0) meta.Add((T("單位"), header.Units));
                if (header.Attendees.Length > 0) meta.Add((T("受訪者"), header.Attendees));
                break;
            case RecordScene.Note:
                if (header.Units.Length > 0) meta.Add((T("主題"), header.Units));
                break;
        }
        if (header.Recorder.Length > 0) meta.Add((T(scene == RecordScene.Interview ? "訪談／記錄" : "記錄"), header.Recorder));
        blocks.Add(new DocBlock.Meta(meta));

        var rawSummary = (rec.Section("摘要") ?? rec.Section("一句話") ?? []).Where(l => l != "---" && l.Length > 0).ToList();
        var summary = rawSummary.Where(l => !l.Starts("（")).ToList();
        if (summary.Count > 0) blocks.Add(new DocBlock.Summary(T(scene == RecordScene.Note ? "一句話" : "摘要"), summary));
        else if (rawSummary.FirstOrDefault(l => l.Starts("（")) is { } note) blocks.Add(new DocBlock.Paragraph(note));

        switch (scene)
        {
            case RecordScene.Meeting:
                if (rec.Section("決議") is { Count: > 0 } d && !(d.Count == 1 && (d[0].Has("無明確決議") || d[0].ToLowerInvariant().Has("no explicit decision") || d[0].Has("明確な決定"))))
                { blocks.Add(new DocBlock.Heading(T("決議"))); blocks.Add(new DocBlock.Numbered(d)); }
                if (rec.Todos.Count > 0) { blocks.Add(new DocBlock.Heading(T("待辦"))); blocks.Add(new DocBlock.Todos(rec.Todos)); }
                if (rec.Section("重點") is { Count: > 0 } kp) { blocks.Add(new DocBlock.Heading(T("重點"))); blocks.AddRange(Grouped(kp, false)); }
                if (rec.Section("開放問題") is { Count: > 0 } q && !(q.Count == 1 && q[0] == "無")) { blocks.Add(new DocBlock.Heading(T("待確認"))); blocks.Add(new DocBlock.Bullets(q)); }
                if (rec.Section("會前重點對照") is { Count: > 0 } b) { blocks.Add(new DocBlock.Heading(T("會前重點下落"))); blocks.Add(new DocBlock.Bullets(b)); }
                break;
            case RecordScene.Interview:
                if (rec.Section("內容") is { Count: > 0 } lines)
                {
                    blocks.Add(new DocBlock.Heading(T("內容")));
                    string? question = null;
                    var answers = new List<string>();
                    void Flush() { if (question != null) blocks.Add(new DocBlock.QA(question, answers)); question = null; answers = []; }
                    foreach (var l in lines)
                    {
                        var t = Str.TrimWS(l);
                        if (t.Starts("**問") && t.Ends("**")) { Flush(); question = t.Rep("**", "").Rep("問：", ""); continue; }
                        if (t.Starts("**") && t.Ends("**")) { Flush(); blocks.Add(new DocBlock.Subheading(t.Rep("**", ""))); continue; }
                        var a = t;
                        if (a.Starts("答：")) a = Str.DropFirst(a, 2);
                        if (question == null) blocks.Add(new DocBlock.Paragraph(a)); else answers.Add(a);
                    }
                    Flush();
                }
                if (rec.Section("引言") is { Count: > 0 } qs && !(qs.Count == 1 && qs[0] == "無"))
                {
                    blocks.Add(new DocBlock.Heading(T("引言")));
                    foreach (var l in qs) blocks.Add(new DocBlock.Quote(l));
                }
                if (rec.Todos.Count > 0) { blocks.Add(new DocBlock.Heading(T("待辦"))); blocks.Add(new DocBlock.Todos(rec.Todos)); }
                break;
            case RecordScene.Note:
                if (rec.Section("內容") is { Count: > 0 } nl) { blocks.Add(new DocBlock.Heading(T("內容"))); blocks.AddRange(Grouped(nl, true)); }
                if (rec.Todos.Count > 0) { blocks.Add(new DocBlock.Heading(T("待辦"))); blocks.Add(new DocBlock.Todos(rec.Todos)); }
                break;
        }
        if (rec.Section("參考連結") is { Count: > 0 } links) { blocks.Add(new DocBlock.Heading(T("參考連結"))); blocks.Add(new DocBlock.Bullets(links)); }
        var footer = string.Join("　·　", new[] { header.Company, header.Title, header.Date }.Where(s => s.Length > 0));
        return new DocModel(scene, header, T(scene.MdTitle()), blocks, footer);
    }

    /// 「**subheading**」 + the lines under it
    static List<DocBlock> Grouped(List<string> lines, bool asParagraph)
    {
        var outList = new List<DocBlock>();
        var buf = new List<string>();
        void Flush()
        {
            if (buf.Count == 0) return;
            if (asParagraph) outList.AddRange(buf.Select(p => (DocBlock)new DocBlock.Paragraph(p))); else outList.Add(new DocBlock.Bullets(buf));
            buf = [];
        }
        foreach (var l in lines)
        {
            if (l.Starts("**") && l.Ends("**")) { Flush(); outList.Add(new DocBlock.Subheading(l.Rep("**", ""))); }
            else buf.Add(l);
        }
        Flush();
        return outList;
    }
}

public static class Docx
{
    const string Font = "Microsoft JhengHei";
    static readonly Regex Bold = new(@"\*\*([^*]+)\*\*", RegexOptions.CultureInvariant);

    /// XML 1.0 legal characters only (Word refuses a whole file with U+FFFE/U+FFFF or control characters)
    static string X(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var r in s.EnumerateRunes())
        {
            int v = r.Value;
            if ((v < 0x20 && v != '\t' && v != '\n') || v == 0xFFFE || v == 0xFFFF) continue;
            sb.Append(r.ToString());
        }
        return sb.ToString().Rep("&", "&amp;").Rep("<", "&lt;").Rep(">", "&gt;").Rep("\"", "&quot;");
    }

    static string Runs(string s, int size = 21, string? color = null, bool bold = false, bool italic = false)
    {
        var o = new StringBuilder();
        var text = DocBuilder.Strip(s);
        int pos = 0;
        foreach (Match m in Bold.Matches(text))
        {
            if (m.Index > pos) o.Append(Run(text[pos..m.Index], size, color, bold, italic));
            o.Append(Run(m.Groups[1].Value, size, color, true, italic));
            pos = m.Index + m.Length;
        }
        if (pos < text.Length) o.Append(Run(text[pos..], size, color, bold, italic));
        return o.ToString();
    }

    static string Run(string s, int size, string? color, bool bold, bool italic)
    {
        var rpr = $"<w:rFonts w:ascii=\"{Font}\" w:hAnsi=\"{Font}\" w:eastAsia=\"{Font}\"/>";
        if (bold) rpr += "<w:b/>";
        if (italic) rpr += "<w:i/>";
        if (color != null) rpr += $"<w:color w:val=\"{color}\"/>";
        rpr += $"<w:sz w:val=\"{size}\"/><w:szCs w:val=\"{size}\"/>";
        return $"<w:r><w:rPr>{rpr}</w:rPr><w:t xml:space=\"preserve\">{X(s)}</w:t></w:r>";
    }

    static string P(string content, string? style = null, int before = 0, int after = 120, int? indentLeft = null, int? hanging = null,
        string? shade = null, string? leftBorder = null, bool keepNext = false, string? jc = null)
    {
        var ppr = new StringBuilder();
        if (style != null) ppr.Append($"<w:pStyle w:val=\"{style}\"/>");
        if (keepNext) ppr.Append("<w:keepNext/>");
        if (leftBorder != null) ppr.Append($"<w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"{leftBorder}\"/></w:pBdr>");
        if (shade != null) ppr.Append($"<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"{shade}\"/>");
        ppr.Append($"<w:spacing w:before=\"{before}\" w:after=\"{after}\" w:line=\"320\" w:lineRule=\"auto\"/>");
        if (indentLeft is { } l) ppr.Append($"<w:ind w:left=\"{l}\"" + (hanging is { } hg ? $" w:hanging=\"{hg}\"" : "") + "/>");
        if (jc != null) ppr.Append($"<w:jc w:val=\"{jc}\"/>");
        return $"<w:p><w:pPr>{ppr}</w:pPr>{content}</w:p>";
    }

    static string Cell(string content, int width, string? fill = null, string? bottom = "E2E2DF", int bottomSz = 4)
    {
        var tcpr = $"<w:tcW w:w=\"{width}\" w:type=\"dxa\"/>";
        tcpr += bottom != null
            ? $"<w:tcBorders><w:top w:val=\"nil\"/><w:left w:val=\"nil\"/><w:right w:val=\"nil\"/><w:bottom w:val=\"single\" w:sz=\"{bottomSz}\" w:color=\"{bottom}\"/></w:tcBorders>"
            : "<w:tcBorders><w:top w:val=\"nil\"/><w:left w:val=\"nil\"/><w:right w:val=\"nil\"/><w:bottom w:val=\"nil\"/></w:tcBorders>";
        if (fill != null) tcpr += $"<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"{fill}\"/>";
        tcpr += "<w:tcMar><w:top w:w=\"80\" w:type=\"dxa\"/><w:bottom w:w=\"80\" w:type=\"dxa\"/><w:left w:w=\"100\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tcMar>";
        return $"<w:tc><w:tcPr>{tcpr}</w:tcPr>{content}</w:tc>";
    }

    static string Table(IEnumerable<string> rows, int[] widths)
    {
        var grid = string.Concat(widths.Select(w => $"<w:gridCol w:w=\"{w}\"/>"));
        return $"<w:tbl><w:tblPr><w:tblW w:w=\"{widths.Sum()}\" w:type=\"dxa\"/><w:tblLayout w:type=\"fixed\"/><w:tblBorders><w:top w:val=\"nil\"/><w:left w:val=\"nil\"/><w:bottom w:val=\"nil\"/><w:right w:val=\"nil\"/><w:insideH w:val=\"nil\"/><w:insideV w:val=\"nil\"/></w:tblBorders></w:tblPr><w:tblGrid>{grid}</w:tblGrid>" + string.Concat(rows) + "</w:tbl>";
    }

    public static string Document(DocModel m)
    {
        var body = new StringBuilder();
        const string ink = "1A1A1A", grey = "6B6B6B", light = "8A8A8A";
        body.Append(Table(["<w:tr>" + Cell(P(Run(m.Header.Company, 22, ink, true, false), after: 0), 6000, bottom: ink, bottomSz: 12)
            + Cell(P(Run(m.Doctype, 18, grey, false, false), after: 0, jc: "right"), 3360, bottom: ink, bottomSz: 12) + "</w:tr>"], [6000, 3360]));
        foreach (var b in m.Blocks)
        {
            switch (b)
            {
                case DocBlock.Title t: body.Append(P(Run(t.Text, 44, ink, true, false), before: 360, after: 200)); break;
                case DocBlock.Meta mt:
                    body.Append(Table(mt.Rows.Select(r => "<w:tr>" + Cell(P(Run(r.Key, 19, grey, false, false), after: 0), 1800, bottom: null)
                        + Cell(P(Run(r.Value, 19, ink, false, false), after: 0), 7560, bottom: null) + "</w:tr>"), [1800, 7560]));
                    body.Append(P("", after: 200));
                    break;
                case DocBlock.Summary s:
                    body.Append(P(Run(s.Label, 17, grey, true, false), before: 120, after: 40, shade: "F4F4F2", leftBorder: ink, keepNext: true));
                    for (int i = 0; i < s.Lines.Count; i++) body.Append(P(Runs(s.Lines[i], 21, ink), after: i == s.Lines.Count - 1 ? 240 : 60, shade: "F4F4F2", leftBorder: ink));
                    break;
                case DocBlock.Heading h: body.Append(P(Run(h.Text, 24, ink, true, false), style: "Heading1", before: 360, after: 120, keepNext: true)); break;
                case DocBlock.Subheading sh: body.Append(P(Run(sh.Text, 21, ink, true, false), style: "Heading2", before: 200, after: 60, keepNext: true)); break;
                case DocBlock.Paragraph p: body.Append(P(Runs(p.Text, 21, ink), after: 140, jc: "both")); break;
                case DocBlock.Bullets bl:
                    foreach (var s in bl.Items) body.Append(P(Run("–  ", 21, light, false, false) + Runs(s, 21, ink), after: 60, indentLeft: 360, hanging: 360));
                    body.Append(P("", after: 80));
                    break;
                case DocBlock.Numbered nb:
                    for (int i = 0; i < nb.Items.Count; i++) body.Append(P(Run($"{i + 1}.  ", 21, ink, true, false) + Runs(nb.Items[i], 21, ink), after: 80, indentLeft: 420, hanging: 420));
                    break;
                case DocBlock.QA qa:
                    body.Append(P(Run(DocLabels.T("問：", m.Header.Language), 21, ink, true, false) + Runs(qa.Question, 21, ink, true), before: 160, after: 60, keepNext: true));
                    for (int i = 0; i < qa.Answers.Count; i++) body.Append(P(Runs(qa.Answers[i], 21, ink), after: i == qa.Answers.Count - 1 ? 160 : 80, indentLeft: 300, leftBorder: "D9D9D6", jc: "both"));
                    break;
                case DocBlock.Quote q: body.Append(P(Runs(q.Text, 22, ink), before: 80, after: 120, indentLeft: 240, shade: "F4F4F2")); break;
                case DocBlock.Todos ts:
                    int[] widths = [720, 4680, 1880, 2080];
                    var L = m.Header.Language;
                    var head = new[] { "#", DocLabels.T("事項", L), DocLabels.T("負責人", L), DocLabels.T("期限", L) };
                    var trs = new List<string> { "<w:tr>" + string.Concat(head.Select((h2, i) => Cell(P(Run(h2, 18, ink, true, false), after: 0), widths[i], bottom: ink, bottomSz: 10))) + "</w:tr>" };
                    for (int i = 0; i < ts.Items.Count; i++)
                    {
                        var t = ts.Items[i];
                        var c = t.Done ? light : ink;
                        trs.Add("<w:tr>" + Cell(P(Run($"{i + 1}", 20, c, false, false), after: 0), widths[0])
                            + Cell(P(Runs(t.Item, 20, c), after: 0), widths[1])
                            + Cell(P(Run(t.Owner, 20, c, false, false), after: 0), widths[2])
                            + Cell(P(Run(t.Due, 20, c, false, false), after: 0), widths[3]) + "</w:tr>");
                    }
                    body.Append(Table(trs, widths));
                    body.Append(P("", after: 120));
                    break;
            }
        }
        const string sect = "<w:sectPr><w:footerReference w:type=\"default\" r:id=\"rIdFooter\"/><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1300\" w:right=\"1273\" w:bottom=\"1200\" w:left=\"1273\" w:header=\"700\" w:footer=\"600\" w:gutter=\"0\"/></w:sectPr>";
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><w:body>" + body + sect + "</w:body></w:document>";
    }

    static string FooterXml(string text) =>
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:ftr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" + P(Run(text, 16, "8A8A8A", false, false), after: 0) + "</w:ftr>";

    static readonly string Styles =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
        "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\n" +
        $"<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"{Font}\" w:hAnsi=\"{Font}\" w:eastAsia=\"{Font}\"/><w:sz w:val=\"21\"/><w:szCs w:val=\"21\"/><w:lang w:val=\"zh-TW\" w:eastAsia=\"zh-TW\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"120\" w:line=\"320\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>\n" +
        "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style>\n" +
        "<w:style w:type=\"paragraph\" w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:keepNext/><w:pBdr><w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"4\" w:color=\"D9D9D6\"/></w:pBdr><w:outlineLvl w:val=\"0\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"24\"/></w:rPr></w:style>\n" +
        "<w:style w:type=\"paragraph\" w:styleId=\"Heading2\"><w:name w:val=\"heading 2\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:keepNext/><w:outlineLvl w:val=\"1\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"21\"/></w:rPr></w:style>\n" +
        "</w:styles>";

    const string ContentTypes =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\n" +
        "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\n<Default Extension=\"xml\" ContentType=\"application/xml\"/>\n" +
        "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>\n" +
        "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>\n" +
        "<Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>\n</Types>";
    const string Rels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n" +
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>\n</Relationships>";
    const string DocRels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n" +
        "<Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>\n" +
        "<Relationship Id=\"rIdFooter\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/>\n</Relationships>";

    /// Write the .docx (built next to the destination, then moved into place: never a half-written file)
    public static void Write(DocModel m, string dest)
    {
        var tmp = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(dest))!, $".{Path.GetFileNameWithoutExtension(dest)}.{Guid.NewGuid():N}.docx.tmp");
        try
        {
            using (var fs = new FileStream(tmp, FileMode.CreateNew))
            using (var zip = new ZipArchive(fs, ZipArchiveMode.Create))
            {
                void Add(string name, string content)
                {
                    var e = zip.CreateEntry(name, CompressionLevel.Optimal);
                    using var w = new StreamWriter(e.Open(), new UTF8Encoding(false));
                    w.Write(content);
                }
                Add("[Content_Types].xml", ContentTypes);
                Add("_rels/.rels", Rels);
                Add("word/_rels/document.xml.rels", DocRels);
                Add("word/styles.xml", Styles);
                Add("word/footer1.xml", FooterXml(m.Footer));
                Add("word/document.xml", Document(m));
            }
            File.Move(tmp, dest, overwrite: true);
        }
        finally { try { if (File.Exists(tmp)) File.Delete(tmp); } catch { } }
    }
}

public static class Html
{
    public static string Escape(string s) => s.Rep("&", "&amp;").Rep("<", "&lt;").Rep(">", "&gt;");
    static readonly Regex BoldRe = new(@"\*\*([^*]+)\*\*", RegexOptions.CultureInvariant);
    static readonly Regex CodeRe = new(@"`([^`]+)`", RegexOptions.CultureInvariant);

    public static string Inline(string s)
    {
        var t = Escape(DocBuilder.Strip(s));
        t = BoldRe.Replace(t, "<b>$1</b>");
        t = CodeRe.Replace(t, "<code>$1</code>");
        return t;
    }

    public static string? TemplatePath(string name)
    {
        var c = new List<string> { Path.Combine(Paths.UserTemplates, name) };
        if (Environment.GetEnvironmentVariable("HEARBY_TEMPLATES_DIR") is { Length: > 0 } e) c.Add(Path.Combine(e, name));
        c.Add(Path.Combine(AppContext.BaseDirectory, "templates", name));
        return c.FirstOrDefault(File.Exists);
    }

    public static string Render(string md, DocHeader? h = null) => Render(DocBuilder.Build(md, h));

    public static string Render(DocModel m)
    {
        string title = "", meta = "";
        var body = new StringBuilder();
        foreach (var b in m.Blocks)
        {
            switch (b)
            {
                case DocBlock.Title t: title = Escape(t.Text); break;
                case DocBlock.Meta mt: meta = "<table class=\"meta\">" + string.Concat(mt.Rows.Select(r => $"<tr><th>{Escape(r.Key)}</th><td>{Escape(r.Value)}</td></tr>")) + "</table>"; break;
                case DocBlock.Summary s: body.Append($"<section class=\"summary\"><h2>{Escape(s.Label)}</h2>" + string.Concat(s.Lines.Select(l => $"<p>{Inline(l)}</p>")) + "</section>"); break;
                case DocBlock.Heading h: body.Append($"<h2>{Escape(h.Text)}</h2>"); break;
                case DocBlock.Subheading sh: body.Append($"<h3>{Escape(sh.Text)}</h3>"); break;
                case DocBlock.Paragraph p: body.Append($"<p class=\"para\">{Inline(p.Text)}</p>"); break;
                case DocBlock.Bullets bl: body.Append("<ul>" + string.Concat(bl.Items.Select(l => $"<li>{Inline(l)}</li>")) + "</ul>"); break;
                case DocBlock.Numbered nb: body.Append("<ol class=\"decisions\">" + string.Concat(nb.Items.Select(l => $"<li>{Inline(l)}</li>")) + "</ol>"); break;
                case DocBlock.QA qa: body.Append($"<div class=\"qa\"><p class=\"q\">{Escape(DocLabels.T("問：", m.Header.Language))}{Inline(qa.Question)}</p>" + string.Concat(qa.Answers.Select(a => $"<p class=\"a\">{Inline(a)}</p>")) + "</div>"); break;
                case DocBlock.Quote q: body.Append($"<blockquote>{Inline(q.Text)}</blockquote>"); break;
                case DocBlock.Todos ts:
                    var L = m.Header.Language;
                    body.Append($"<table class=\"todo\"><thead><tr><th style=\"width:8%\">#</th><th style=\"width:50%\">{DocLabels.T("事項", L)}</th><th style=\"width:20%\">{DocLabels.T("負責人", L)}</th><th style=\"width:22%\">{DocLabels.T("期限", L)}</th></tr></thead><tbody>");
                    for (int i = 0; i < ts.Items.Count; i++)
                    {
                        var t = ts.Items[i];
                        body.Append($"<tr{(t.Done ? " class=\"done\"" : "")}><td>{i + 1}</td><td>{Inline(t.Item)}</td><td>{Escape(t.Owner)}</td><td>{Escape(t.Due)}</td></tr>");
                    }
                    body.Append("</tbody></table>");
                    break;
            }
        }
        string tpl;
        try { tpl = TemplatePath("pdf.html") is { } tp ? File.ReadAllText(tp, Encoding.UTF8) : Builtin; } catch { tpl = Builtin; }
        var values = new Dictionary<string, string>
        {
            ["company"] = Escape(m.Header.Company), ["doctype"] = Escape(m.Doctype), ["title"] = title, ["meta"] = meta, ["body"] = body.ToString(), ["footer"] = Escape(m.Footer),
        };
        var o = new StringBuilder();
        int pos = 0;
        while (true)
        {
            int open = tpl.IndexOf("{{", pos, StringComparison.Ordinal);
            if (open < 0) { o.Append(tpl, pos, tpl.Length - pos); break; }
            o.Append(tpl, pos, open - pos);
            int close = tpl.IndexOf("}}", open + 2, StringComparison.Ordinal);
            if (close < 0) { o.Append(tpl, open, tpl.Length - open); break; }
            var key = tpl[(open + 2)..close];
            o.Append(values.TryGetValue(key, out var v) ? v : tpl[open..(close + 2)]);   // unknown placeholders stay as they are
            pos = close + 2;
        }
        return o.ToString();
    }

    public const string Builtin = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>
        *{margin:0;padding:0;box-sizing:border-box;-webkit-print-color-adjust:exact;print-color-adjust:exact}
        @page{size:A4;margin:16mm 17mm 16mm 17mm}
        html,body{background:#FFFFFF}
        body{font-family:"Microsoft JhengHei","PingFang TC","Noto Sans TC","Segoe UI",sans-serif;color:#1A1A1A;font-size:10.5pt;line-height:1.7}
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
        code{font-family:Consolas,"Cascadia Mono",monospace;font-size:9pt;background:#F1F1EF;padding:0 3px;border-radius:2px}
        footer{margin-top:36px;padding-top:8px;border-top:1px solid #D9D9D6;font-size:8pt;color:#8A8A8A}
        </style></head><body>
        <div class="top"><span class="company">{{company}}</span><span class="doctype">{{doctype}}</span></div>
        <h1>{{title}}</h1>
        {{meta}}
        {{body}}
        <footer>{{footer}}</footer>
        </body></html>
        """;
}
