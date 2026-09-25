// ExportWindow — fill in the document header, then PDF or Word (mirrors ExportSheet in WindowActions.swift).
// The document belongs to the user's company: no Hearby branding; empty fields are simply not printed.
using System.Windows;
using System.Windows.Controls;
using Hearby.Core;

namespace Hearby.App.UI;

public sealed class ExportWindow : NeuWindow
{
    readonly string mdPath;
    readonly DocHeader h;
    bool busy;
    string msg = "";
    string? lastFile;

    public ExportWindow(string mdPath) : base(600, 520, resizable: false, stage: false)
    {
        ScaleToFit = true;
        FitToScreen();
        this.mdPath = mdPath;
        string md = ""; try { md = RecordMD.Read(mdPath); } catch { }
        h = DocHeader.Prefill(md, DocLabels.LanguageOf(mdPath));
        Title = "匯出";
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Rebuild();
    }

    protected override UIElement BuildContent()
    {
        var p = new StackPanel { Margin = new Thickness(Neu.XL, 8, Neu.XL, Neu.XL) };
        var head = new DockPanel { LastChildFill = true, Height = 34, Margin = new Thickness(0, 0, 0, Neu.SM) };
        var cap = CaptionButtons(minimize: false);
        DockPanel.SetDock(cap, Dock.Right);
        head.Children.Add(cap);
        var t = Neu.Text("匯出文件", Neu.TTitle, Theme.InkStrong, semi: true, wrap: false); t.VerticalAlignment = VerticalAlignment.Center;
        head.Children.Add(t);
        p.Children.Add(head);
        p.Children.Add(Neu.Note("文件是你們公司的，不會有 Hearby 的標誌；沒填的欄位不會印出來。"));
        var fields = new StackPanel { Margin = new Thickness(0, Neu.MD, 0, Neu.SM) };
        fields.Children.Add(Field("標題", h.Title, "會議名稱", v => h.Title = v));
        fields.Children.Add(Field("公司", h.Company, "你們公司的名稱", v => h.Company = v));
        fields.Children.Add(Field("與會單位", h.Units, "例：行銷部、甲方採購", v => h.Units = v));
        fields.Children.Add(Field("記錄", h.Recorder, "記錄人", v => h.Recorder = v));
        fields.Children.Add(Field("日期", h.Date, "yyyy-MM-dd HH:mm", v => h.Date = v));
        fields.Children.Add(Field("與會者", h.Attendees, "頓號分隔", v => h.Attendees = v));
        p.Children.Add(fields);
        if (msg.Length > 0) { var n = Neu.Note(msg); n.Margin = new Thickness(0, 0, 0, Neu.SM); p.Children.Add(n); }
        if (busy) { var g = Neu.Groove(null, 8); g.Margin = new Thickness(0, 0, 0, Neu.SM); p.Children.Add(g); }
        var row = new UniformGrid2(lastFile != null ? 4 : 3);
        row.Add(Neu.Capsule("出 PDF", () => Run(true), 38, !busy));
        row.Add(Neu.Capsule("出 Word", () => Run(false), 38, !busy));
        if (lastFile != null) row.Add(Neu.Capsule("打開", () => Exporters.Open(lastFile), 38));
        row.Add(Neu.Capsule("關閉", Close, 38));
        p.Children.Add(row.View);
        return p;
    }

    static FrameworkElement Field(string label, string value, string placeholder, Action<string> set)
    {
        var d = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, Neu.SM) };
        var l = Neu.Text(label, Neu.TCaption, Theme.InkMid, semi: true, wrap: false);
        l.Width = 72; l.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(l, Dock.Left);
        d.Children.Add(l);
        var (f, _) = Neu.Field(placeholder, value, set);
        d.Children.Add(f);
        return d;
    }

    void Run(bool pdf)
    {
        busy = true; msg = ""; Rebuild();
        ConfigStore.Shared.Update(c => { c.DocCompany = h.Company.Length == 0 ? null : h.Company; c.DocRecorder = h.Recorder.Length == 0 ? null : h.Recorder; });
        var header = h;
        Task.Run(() =>
        {
            try
            {
                var outPath = pdf ? Exporters.Pdf(mdPath, header) : Exporters.Word(mdPath, header);
                Gui.OnUi(() => { busy = false; lastFile = outPath; msg = $"已存到：{Path.GetFileName(outPath)}（在這一場的資料夾裡）"; Rebuild(); Exporters.Reveal(outPath); });
            }
            catch (Exception e) { Gui.OnUi(() => { busy = false; msg = e.Message; Rebuild(); }); }
        });
    }
}
