// DocView — the record page (mirrors Window/DocView.swift): never the raw markdown; laid out from the same document blocks
// as the PDF and Word files (DocBuilder). Title, header fields, summary card, headings, bullets, Q&A, quotes, to-dos with
// check boxes; a translated record uses that language's field names. Selectable and copyable (FlowDocument).
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using Hearby.Core;

namespace Hearby.App.UI;

public static class DocView
{
    static readonly Regex Token = new(@"\*\*[^*]+\*\*|\[(?:\d{1,2}:)?\d{1,3}:[0-5]\d\]", RegexOptions.CultureInvariant);

    public static FrameworkElement Build(string md, string language)
    {
        var model = DocBuilder.Build(md, DocHeader.Prefill(md, language));
        var warnings = Str.Lines(md).TakeWhile(l => !l.Starts("## "))
            .Where(l => l.Starts("> ") && (l.Has("⚠")))
            .Select(l => Str.TrimWS(l[2..].Replace("⚠️", "").Replace("⚠", ""))).ToList();
        var doc = new FlowDocument
        {
            FontFamily = Neu.UIFont, FontSize = Neu.TBody, Foreground = Theme.InkStrong, Background = Brushes.Transparent,
            PagePadding = new Thickness(Neu.XL), ColumnWidth = 100000, TextAlignment = TextAlignment.Left, LineHeight = 23,
        };
        foreach (var b in model.Blocks) Add(doc, b, model);
        if (warnings.Count > 0)
        {
            var sec = new Section { Margin = new Thickness(0, Neu.SM, 0, 0) };
            foreach (var w in warnings)
            {
                var wp = new Paragraph { FontSize = Neu.TCaption, Foreground = Theme.InkMid, Margin = new Thickness(0, 0, 0, 4) };
                wp.Inlines.Add(new Run("\uE946  ") { FontFamily = Neu.IconFont, FontSize = 11 });
                wp.Inlines.Add(new Run(w));
                sec.Blocks.Add(wp);
            }
            doc.Blocks.Add(sec);
        }
        var viewer = new FlowDocumentScrollViewer
        {
            Document = doc, IsToolBarVisible = false, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Focusable = true, Background = Brushes.Transparent,
            SelectionBrush = Theme.InkMid,
        };
        return Neu.Inset(viewer, Neu.RCard, 0.9);
    }

    static void Add(FlowDocument doc, DocBlock b, DocModel m)
    {
        switch (b)
        {
            case DocBlock.Title t:
                doc.Blocks.Add(new Paragraph(new Run(m.Doctype)) { FontSize = Neu.TMicro, FontWeight = FontWeights.SemiBold, Foreground = Theme.InkSoft, Margin = new Thickness(0, 0, 0, 4) });
                doc.Blocks.Add(new Paragraph(new Run(t.Text.Length == 0 ? m.Doctype : t.Text)) { FontSize = 24, FontWeight = FontWeights.SemiBold, LineHeight = 32, Margin = new Thickness(0, 0, 0, Neu.LG) });
                break;
            case DocBlock.Meta meta when meta.Rows.Count > 0:
                var table = new Table { CellSpacing = 0, Margin = new Thickness(0, 0, 0, Neu.LG) };
                table.Columns.Add(new TableColumn { Width = new GridLength(80) });
                table.Columns.Add(new TableColumn { Width = GridLength.Auto });
                var rg = new TableRowGroup();
                foreach (var (k, v) in meta.Rows)
                {
                    var row = new TableRow();
                    row.Cells.Add(new TableCell(new Paragraph(new Run(k)) { FontSize = Neu.TCaption, Foreground = Theme.InkSoft, Margin = new Thickness(0, 0, 0, 5) }));
                    row.Cells.Add(new TableCell(new Paragraph(new Run(v)) { FontSize = Neu.TCaption, Foreground = Theme.InkMid, Margin = new Thickness(0, 0, 0, 5) }));
                    rg.Rows.Add(row);
                }
                table.RowGroups.Add(rg);
                doc.Blocks.Add(table);
                break;
            case DocBlock.Summary s:
                var sec = new Section { Background = Theme.Stage, Padding = new Thickness(Neu.LG), Margin = new Thickness(0, 0, 0, Neu.LG) };
                sec.Blocks.Add(new Paragraph(new Run(s.Label)) { FontSize = Neu.TMicro, FontWeight = FontWeights.SemiBold, Foreground = Theme.InkSoft, Margin = new Thickness(0, 0, 0, 6) });
                foreach (var l in s.Lines) sec.Blocks.Add(Rich(l, new Thickness(0, 0, 0, 4)));
                doc.Blocks.Add(sec);
                break;
            case DocBlock.Heading h:
                doc.Blocks.Add(new Paragraph(new Run(h.Text)) { FontSize = Neu.TTitle, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, Neu.SM, 0, Neu.SM) });
                break;
            case DocBlock.Subheading sh:
                doc.Blocks.Add(new Paragraph(new Run(sh.Text)) { FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 2, 0, 6) });
                break;
            case DocBlock.Paragraph p:
                doc.Blocks.Add(Rich(p.Text, new Thickness(0, 0, 0, Neu.MD)));
                break;
            case DocBlock.Bullets bl:
                var list = new List { MarkerStyle = TextMarkerStyle.Disc, Foreground = Theme.InkStrong, Margin = new Thickness(0, 0, 0, Neu.MD), Padding = new Thickness(18, 0, 0, 0) };
                foreach (var l in bl.Items) list.ListItems.Add(new ListItem(Rich(l, new Thickness(0, 0, 0, 5))));
                doc.Blocks.Add(list);
                break;
            case DocBlock.Numbered nb:
                var ol = new List { MarkerStyle = TextMarkerStyle.Decimal, Foreground = Theme.InkStrong, Margin = new Thickness(0, 0, 0, Neu.MD), Padding = new Thickness(24, 0, 0, 0) };
                foreach (var l in nb.Items) ol.ListItems.Add(new ListItem(Rich(l, new Thickness(0, 0, 0, 5))));
                doc.Blocks.Add(ol);
                break;
            case DocBlock.QA qa:
                var q = new Paragraph { Margin = new Thickness(0, Neu.SM, 0, 4) };
                q.Inlines.Add(new Run("Q   ") { Foreground = Theme.InkMid, FontFamily = Neu.MarkFont });
                q.Inlines.Add(new Run(qa.Question) { FontWeight = FontWeights.SemiBold });
                doc.Blocks.Add(q);
                foreach (var a in qa.Answers)
                {
                    var ap = Rich(a, new Thickness(0, 0, 0, 4));
                    ap.Inlines.InsertBefore(ap.Inlines.FirstInline, new Run("A   ") { Foreground = Theme.InkSoft, FontFamily = Neu.MarkFont });
                    doc.Blocks.Add(ap);
                }
                break;
            case DocBlock.Quote qt:
                var qp = Rich(qt.Text, new Thickness(0, 0, 0, Neu.MD));
                qp.FontStyle = FontStyles.Italic; qp.Foreground = Theme.InkMid;
                qp.BorderBrush = Theme.InkSoft; qp.BorderThickness = new Thickness(3, 0, 0, 0); qp.Padding = new Thickness(Neu.MD, 0, 0, 0);
                doc.Blocks.Add(qp);
                break;
            case DocBlock.Todos ts:
                foreach (var t in ts.Items)
                {
                    var tp = new Paragraph { Margin = new Thickness(0, 0, 0, 8) };
                    tp.Inlines.Add(new Run(t.Done ? "☑  " : "☐  ") { Foreground = t.Done ? Theme.InkMid : Theme.InkSoft });
                    var item = new Run(t.Item) { Foreground = t.Done ? Theme.InkMid : Theme.InkStrong };
                    if (t.Done) item.TextDecorations = TextDecorations.Strikethrough;
                    tp.Inlines.Add(item);
                    var tail = string.Join("　·　", new[] { t.Owner, t.Due }.Where(x => x.Length > 0));
                    if (tail.Length > 0)
                    {
                        tp.Inlines.Add(new LineBreak());
                        tp.Inlines.Add(new Run("     " + tail) { FontSize = Neu.TMicro, Foreground = Theme.InkSoft });
                    }
                    doc.Blocks.Add(tp);
                }
                break;
        }
    }

    /// Inline **bold** and [mm:ss] timestamps: bold stays bold, timestamps fade
    static Paragraph Rich(string s, Thickness margin)
    {
        var p = new Paragraph { Margin = margin };
        int pos = 0;
        foreach (Match mt in Token.Matches(s))
        {
            if (mt.Index > pos) p.Inlines.Add(new Run(s[pos..mt.Index]));
            var tok = mt.Value;
            if (tok.StartsWith("**", StringComparison.Ordinal)) p.Inlines.Add(new Run(tok[2..^2]) { FontWeight = FontWeights.SemiBold });
            else p.Inlines.Add(new Run(" " + tok) { FontSize = Neu.TMicro, Foreground = Theme.InkSoft, FontFamily = Neu.MarkFont });
            pos = mt.Index + mt.Length;
        }
        if (pos < s.Length) p.Inlines.Add(new Run(s[pos..]));
        if (p.Inlines.Count == 0) p.Inlines.Add(new Run(""));
        return p;
    }
}
