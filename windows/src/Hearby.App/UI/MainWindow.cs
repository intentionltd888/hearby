// MainWindow — the one window: records (list / one record), settings, status (mirrors Window/MainWindow.swift).
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Hearby.Core;

namespace Hearby.App.UI;

public sealed class MainWindow : NeuWindow
{
    int tab;
    readonly RecordsView records = new();
    public MainWindow() : base(900, 700, resizable: true, stage: true)
    {
        MinWidth = 720; MinHeight = 560;
        FitToScreen();
        HideOnClose = true;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Rebuild();
    }

    public void ShowTab(int t)
    {
        tab = t;
        if (t == 0) records.Reload();
        Rebuild();
    }

    public void OpenRecord(string md)
    {
        tab = 0;
        records.Open(md);
        Rebuild();
    }

    protected override UIElement BuildContent()
    {
        var root = new DockPanel { Margin = new Thickness(Neu.Edge, 8, Neu.Edge, Neu.MD), LastChildFill = true };
        var head = new DockPanel { LastChildFill = false, Height = 44 };
        var logo = Brand.LogotypeView(16, Theme.InkStrong);
        logo.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(logo, Dock.Left);
        head.Children.Add(logo);
        var caption = CaptionButtons(minimize: true, maximize: true);
        DockPanel.SetDock(caption, Dock.Right);
        head.Children.Add(caption);
        var seg = Clickable(Neu.Segmented(["紀錄", "設定", "檢查"], tab, i => { tab = i; if (i == 0) records.Reload(); Rebuild(); }, [Neu.IcList, Neu.IcSettings, Neu.IcHealth], 36));
        seg.Width = 330; seg.Margin = new Thickness(0, 0, Neu.LG, 0); seg.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(seg, Dock.Right);
        head.Children.Add(seg);
        DockPanel.SetDock(head, Dock.Top);
        root.Children.Add(head);

        var foot = new DockPanel { LastChildFill = false, Margin = new Thickness(0, Neu.MD, 0, 0) };
        var pb = Brand.PoweredBy(showWordmark: false);
        DockPanel.SetDock(pb, Dock.Left);
        foot.Children.Add(pb);
        var ver = Neu.Text($"{HearbyVersion.Version} build {HearbyVersion.Build}（Windows）", Neu.TMicro, Theme.InkSoft, wrap: false);
        DockPanel.SetDock(ver, Dock.Right);
        foot.Children.Add(ver);
        DockPanel.SetDock(foot, Dock.Bottom);
        root.Children.Add(foot);

        FrameworkElement body = tab switch { 1 => new SettingsView(), 2 => new StatusView(), _ => records };
        if (body.Parent is Panel old) old.Children.Remove(body);
        body.Margin = new Thickness(0, Neu.LG, 0, 0);
        root.Children.Add(body);
        return root;
    }
}

// ── records: list + one record ──

public sealed class RecordsView : ContentControl
{
    List<MeetingItem> items = [];
    string query = "";
    List<(MeetingItem Item, string Line)> hits = [];
    MeetingItem? selected;
    // rename: the meeting being renamed, the text typed so far, renaming in progress, the one line after it
    MeetingItem? renaming;
    string renameDraft = "", renameMsg = "";
    bool renameBusy;
    readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromSeconds(5) };

    public RecordsView()
    {
        // no rescans while a title is being edited: the list is sorted by modification time and the row would jump away
        tick.Tick += (_, _) => { if (selected == null && renaming == null && IsVisible) Reload(); };
        Theme.Changed += Build;
        Loaded += (_, _) => tick.Start();
        Unloaded += (_, _) => tick.Stop();
        Reload();
    }

    public void Reload()
    {
        Task.Run(() =>
        {
            var list = MeetingIndex.Scan();
            Gui.OnUi(() =>
            {
                bool same = list.Count == items.Count && list.Zip(items).All(p => p.First.Dir == p.Second.Dir && p.First.Modified == p.Second.Modified);
                items = list;
                if (!same && selected == null && renaming == null) Build();
            });
        });
        if (Content == null) Build();
    }

    public void Open(string md)
    {
        var list = MeetingIndex.Scan();
        items = list;
        selected = list.FirstOrDefault(i => string.Equals(i.MdPath, md, StringComparison.OrdinalIgnoreCase) || string.Equals(i.Dir, Path.GetDirectoryName(md), StringComparison.OrdinalIgnoreCase));
        Build();
    }

    void Build()
    {
        if (selected is { } s) { Content = new MeetingDetail(s, () => { selected = null; Reload(); Build(); }); return; }
        var p = new DockPanel { LastChildFill = true };
        var bar = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, Neu.MD) };
        var chips = Neu.Row(Neu.XS, Neu.Chip("搜", Search), Neu.Chip("打開資料夾", () => Exporters.Reveal(Paths.Meetings), Neu.IcFolder));
        DockPanel.SetDock(chips, Dock.Right);
        bar.Children.Add(chips);
        var (field, box) = Neu.Field("搜某句話或某個人名（會翻整份逐字稿，不只搜標題）", query, t => query = t);
        box.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) Search(); };
        field.Margin = new Thickness(0, 3, Neu.SM, 0);
        bar.Children.Add(field);
        DockPanel.SetDock(bar, Dock.Top);
        p.Children.Add(bar);
        if (renameMsg.Length > 0)
        {
            var note = Neu.Note(renameMsg);
            note.Margin = new Thickness(0, 0, 0, Neu.SM);
            DockPanel.SetDock(note, Dock.Top);
            p.Children.Add(note);
        }
        if (query.Length > 0 && hits.Count > 0)
        {
            var list = new StackPanel();
            foreach (var (item, line) in hits)
            {
                var row = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 3, 0, 3) };
                var title = Neu.Text(item.Title, Neu.TCaption, Theme.InkStrong, semi: true, wrap: false);
                title.Width = 180;
                DockPanel.SetDock(title, Dock.Left);
                row.Children.Add(title);
                row.Children.Add(Neu.Text(line, Neu.TCaption, Theme.InkMid));
                var b = new PressButton { Content = new Border { Background = Brushes.Transparent, Child = row } };
                var it = item;
                b.Click += (_, _) => { selected = it; Build(); };
                list.Children.Add(b);
            }
            p.Children.Add(Neu.Scroll(list));
        }
        else if (items.Count == 0)
        {
            var s2 = new StackPanel();
            s2.Children.Add(Neu.Text("還沒有紀錄", Neu.TTitle, Theme.InkStrong, semi: true));
            var n = Neu.Note($"按工作列右下角的 Hearby 圖示（引號 ”）開錄，結束就會出現在這裡。所有檔案都在：{Paths.Meetings}");
            n.Margin = new Thickness(0, Neu.SM, 0, 0);
            s2.Children.Add(n);
            var empty = Neu.Inset(s2, Neu.RCard, 0.95, new Thickness(Neu.LG));
            empty.VerticalAlignment = VerticalAlignment.Top;
            p.Children.Add(empty);
        }
        else
        {
            var list = new StackPanel { Margin = new Thickness(0, 2, 0, 2) };
            foreach (var it in items)
            {
                if (renaming != null && renaming.Dir == it.Dir) { list.Children.Add(RenameRow(it)); continue; }
                var row = new DockPanel { LastChildFill = true };
                var chev = Neu.Icon(Neu.IcNext, 11, Theme.InkSoft);
                DockPanel.SetDock(chev, Dock.Right);
                row.Children.Add(chev);
                var t = new StackPanel();
                t.Children.Add(Neu.Text(it.Title, Neu.TBody, Theme.InkStrong, semi: true, wrap: false));
                t.Children.Add(Neu.Text(string.Join("　", new[] { it.DateText, it.DurText }.Where(x => x.Length > 0)), Neu.TMicro, Theme.InkSoft, wrap: false));
                if (it.Gist.Length > 0) t.Children.Add(Neu.Text(it.Gist, Neu.TCaption, Theme.InkMid, wrap: false));
                row.Children.Add(t);
                var (card, set) = Neu.Raised(row, Neu.RCard, 0.6, new Thickness(Neu.MD));
                var b = new PressButton { Content = card, Visual = set, Margin = new Thickness(2, 2, 8, Neu.SM + 2) };
                System.Windows.Automation.AutomationProperties.SetName(b, it.Title);
                var item = it;
                b.Click += (_, _) => { selected = item; Build(); };
                // rename: a pencil on the right while the mouse is over the row, and the same in the right-click menu
                var pencil = Neu.IconButton(Neu.IcEdit, () => BeginRename(item), 26, "改標題（資料夾、檔名、記憶裡的這一場會一起改）", name: "改標題");
                pencil.Visibility = Visibility.Hidden;
                pencil.HorizontalAlignment = HorizontalAlignment.Right;
                pencil.VerticalAlignment = VerticalAlignment.Center;
                pencil.Margin = new Thickness(0, 0, 8 + Neu.MD + 22, Neu.SM);
                var menu = new ContextMenu();
                var rename = new MenuItem { Header = "改標題…" };
                rename.Click += (_, _) => BeginRename(item);
                var reveal = new MenuItem { Header = "在檔案總管顯示" };
                reveal.Click += (_, _) => Exporters.Reveal(item.Dir);
                menu.Items.Add(rename);
                menu.Items.Add(reveal);
                b.ContextMenu = menu;
                var cell = new Grid();
                cell.Children.Add(b);
                cell.Children.Add(pencil);
                cell.MouseEnter += (_, _) => pencil.Visibility = Visibility.Visible;
                cell.MouseLeave += (_, _) => pencil.Visibility = Visibility.Hidden;
                list.Children.Add(cell);
            }
            p.Children.Add(Neu.Scroll(list));
        }
        Content = p;
    }

    /// The row being renamed turns into a text box in place (Enter = done, Esc = cancel)
    FrameworkElement RenameRow(MeetingItem it)
    {
        var s = new StackPanel();
        var line = new DockPanel { LastChildFill = true };
        var chips = Neu.Row(Neu.XS, Neu.Chip(renameBusy ? "改名中…" : "改好", () => CommitRename(it), Neu.IcCheck, !renameBusy), Neu.Chip("取消", CancelRename, Neu.IcCancel, !renameBusy));
        DockPanel.SetDock(chips, Dock.Right);
        line.Children.Add(chips);
        var (field, box) = Neu.Field("新的標題", renameDraft, t => renameDraft = t);
        field.Margin = new Thickness(0, 3, Neu.SM, 0);
        box.IsEnabled = !renameBusy;
        box.KeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Enter) { CommitRename(it); e.Handled = true; }
            else if (e.Key == System.Windows.Input.Key.Escape) { CancelRename(); e.Handled = true; }
        };
        box.Loaded += (_, _) => { System.Windows.Input.Keyboard.Focus(box); box.SelectAll(); };
        line.Children.Add(field);
        s.Children.Add(line);
        var date = Neu.Text(string.Join("　", new[] { it.DateText, it.DurText }.Where(x => x.Length > 0)), Neu.TMicro, Theme.InkSoft, wrap: false);
        date.Margin = new Thickness(Neu.MD, Neu.XS, 0, Neu.XS);
        s.Children.Add(date);
        s.Children.Add(Neu.Note("按 Enter 改好、Esc 取消。這一場的資料夾、裡面的檔名、紀錄上的標題、記憶裡的這一場（有設副本資料夾的話連副本）會一起改；日期和時間不變。"));
        var card = Neu.Inset(s, Neu.RCard, 0.7, new Thickness(Neu.MD));
        card.Margin = new Thickness(2, 2, 8, Neu.SM + 2);
        return card;
    }

    void BeginRename(MeetingItem it)
    {
        renaming = it;
        renameDraft = it.Title;
        renameMsg = "";
        Build();
    }

    void CancelRename()
    {
        if (renameBusy) return;
        renaming = null;
        renameDraft = "";
        Build();
    }

    void CommitRename(MeetingItem it)
    {
        if (renameBusy) return;
        if (MeetingRename.OneLine(renameDraft).Length == 0) { renameMsg = "標題不能是空的"; Build(); return; }
        renameBusy = true;
        Build();
        var title = renameDraft;
        Task.Run(() =>
        {
            try
            {
                var r = MeetingRename.Rename(it.Dir, title);
                Gui.OnUi(() =>
                {
                    renameBusy = false;
                    renaming = null;
                    renameDraft = "";
                    renameMsg = r.Unchanged ? "" : Summary(r, it.Title);
                    AppState.Shared.Renamed(it.Dir, r);
                    Reload();
                    Build();
                });
            }
            catch (Exception e) { Gui.OnUi(() => { renameBusy = false; renameMsg = e.Message; Build(); }); }
        });
    }

    /// The one line after a rename: what it is called now, whether memory and the mirror followed, what did not work out
    static string Summary(MeetingRename.Report r, string old)
    {
        var s = $"改好了：「{old}」→「{MeetingIndex.Split(r.NewId).Title}」";
        if (r.Memory.Count > 0) s += "；記憶裡的這一場跟著換了" + (r.Backups.Count == 0 ? "" : "（改之前留了備份）");
        if (r.Mirror.Count > 0) s += "；副本資料夾也改了";
        if (r.Warnings.Count > 0) s += "。沒做成的：" + string.Join("；", r.Warnings);
        return s;
    }

    void Search()
    {
        var q = query;
        Task.Run(() => { var h = MeetingIndex.Search(q); Gui.OnUi(() => { hits = h; Build(); }); });
    }
}

public sealed class MeetingDetail : ContentControl
{
    readonly MeetingItem item;
    readonly Action onBack;
    string md = "";
    bool editing, oneLine, busy, showAI, showRepolish, showTranslate;
    int mode;
    string msg = "", stage = "", aiSection = "重點", aiInstruction = "", corrections = "", draft = "";
    string? aiPreview, current;
    List<string> translations = [];
    TextBox? editor;

    public MeetingDetail(MeetingItem item, Action onBack)
    {
        this.item = item;
        this.onBack = onBack;
        Load(first: true);
        Build();
    }

    List<string> SectionNames
    {
        get
        {
            var skip = new[] { "逐字稿", "修正紀錄", "會前重點對照", "參考連結" };
            var names = new List<string>();
            foreach (var line in Str.Lines(md))
            {
                if (!line.Starts("## ")) continue;
                var n = Str.TrimWS(line[3..]);
                if (n == "逐字稿") break;
                if (!skip.Any(n.Has) && !names.Contains(n)) names.Add(n);
            }
            return names.Count == 0 ? ["AI 會議摘要", "與會者", "重點", "決議", "待辦"] : names;
        }
    }

    bool AIAllowed => !editing && !busy;
    string AIBlockedHelp => editing ? "正在自己改：先按「存檔」或「取消」，才能請 AI 改" : busy ? "AI 正在跑，等它做完" : "";

    string? TranslatedPath(string lang) => item.MdPath is { } o ? Path.Combine(Path.GetDirectoryName(o)!, Path.GetFileNameWithoutExtension(o) + "." + lang + ".md") : null;
    List<string> FindTranslations() => new[] { "en", "ja", "zh-CN" }.Where(l => TranslatedPath(l) is { } p && File.Exists(p)).ToList();

    void Load(bool first = false)
    {
        if (current == null) { current = item.MdPath; translations = FindTranslations(); }
        try { if (current != null) md = RecordMD.Read(current); } catch { md = ""; }
        // transcript-only record: open straight on the transcript, not an empty page
        if (first && RecordMD.Parse(md).Sections.Where(s => s.Name != "逐字稿").All(s => s.Lines.All(l => l.Starts("（") || l == "---" || l == "無" || l.Length == 0))) mode = 1;
        if (!SectionNames.Contains(aiSection)) aiSection = SectionNames.FirstOrDefault() ?? aiSection;
    }

    string DisplayText
    {
        get
        {
            int i = md.IndexOf("\n## 逐字稿", StringComparison.Ordinal);
            if (mode == 0) return i >= 0 ? md[..i] : md;
            var t = i >= 0 ? md[(i + "\n## 逐字稿".Length)..] : "（沒有逐字稿）";
            if (oneLine)
                t = string.Join("\n", Str.Lines(t).SelectMany(line =>
                {
                    if (!line.Starts("- [")) return new[] { line };
                    var pieces = line.Split(['。', '？', '！']).Where(x => Str.TrimWS(x).Length > 0).ToList();
                    return pieces.Count > 1 ? pieces.Select((x, k) => k == 0 ? x : "    " + x).ToArray() : [line];
                }));
            return Str.TrimWSNL(t);
        }
    }

    void Build()
    {
        var root = new DockPanel { LastChildFill = true };
        var top = new StackPanel();
        // header: back, title, folder
        var head = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, Neu.MD) };
        var back = Neu.IconButton(Neu.IcBack, onBack, 28, "回到清單");
        DockPanel.SetDock(back, Dock.Left);
        head.Children.Add(back);
        var folder = Neu.IconButton(Neu.IcFolder, () => Exporters.Reveal(item.MdPath ?? item.Dir), 28, "打開這一場的資料夾（錄音、紀錄、匯出的檔都在裡面）");
        DockPanel.SetDock(folder, Dock.Right);
        head.Children.Add(folder);
        var title = Neu.Text(item.Title, Neu.TTitle, Theme.InkStrong, semi: true, wrap: false);
        title.VerticalAlignment = VerticalAlignment.Center; title.Margin = new Thickness(Neu.MD, 0, Neu.MD, 0);
        head.Children.Add(title);
        top.Children.Add(head);
        // mode + one-line
        var modeRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, Neu.SM) };
        var seg = Neu.Segmented(["紀錄", "逐字稿"], mode, i => { mode = i; Build(); }, [Neu.IcDoc, Neu.IcQuote], 34);
        seg.Width = 220;
        modeRow.Children.Add(seg);
        if (mode == 1) { var c = Neu.Chip(oneLine ? "分塊" : "一句一行", () => { oneLine = !oneLine; Build(); }, Neu.IcText); c.Margin = new Thickness(Neu.SM, 3, 5, 6); modeRow.Children.Add(c); }
        top.Children.Add(modeRow);
        if (item.MdPath != null)
        {
            var flow = new WrapPanel();
            if (editing)
            {
                flow.Children.Add(Neu.Chip("存檔", Save, Neu.IcCheck));
                flow.Children.Add(Neu.Chip("取消", () => { editing = false; draft = ""; Build(); }, Neu.IcCancel));
            }
            else flow.Children.Add(Neu.Chip("自己改", () => { draft = md; editing = true; showAI = showRepolish = showTranslate = false; msg = ""; Build(); }, Neu.IcEdit, !busy, "直接改文字（可以 Ctrl+C／Ctrl+V，也可以用語音輸入）；按「存檔」才會存，原版會留備份"));
            flow.Children.Add(Neu.Chip("請 AI 改一段", () => { showAI = !showAI; showRepolish = showTranslate = false; Build(); }, Neu.IcWand, AIAllowed, AIAllowed ? "挑一節、用一句話說要改什麼，AI 改好先給你看，按確認才寫入" : AIBlockedHelp));
            flow.Children.Add(Neu.Chip("重新整理全篇", () => { showRepolish = !showRepolish; showAI = showTranslate = false; Build(); }, Neu.IcRefresh, AIAllowed, AIAllowed ? "整份紀錄交給 AI 照逐字稿重寫一次（不是重新載入畫面）；大約 1 到 2 分鐘" : AIBlockedHelp));
            flow.Children.Add(Neu.Chip("翻譯", () => { showTranslate = !showTranslate; showAI = showRepolish = false; Build(); }, Neu.IcGlobe, AIAllowed, AIAllowed ? "翻成英文／日文／簡中，另存一份，原文不動" : AIBlockedHelp));
            flow.Children.Add(Neu.Chip("存成 PDF／Word", () => Gui.OpenExport(current ?? item.MdPath!), Neu.IcDoc));
            flow.Children.Add(Neu.Chip("跟 Claude 討論", () => { if (!Exporters.ContinueWithClaude(item.MdPath!)) { msg = "打不開 Claude：到「設定 → 紀錄要誰寫」確認 Claude Code 裝好、登入了"; Build(); } }, Neu.IcChat));
            top.Children.Add(flow);
            if (editing) top.Children.Add(Neu.Note("正在自己改：下面的字可以直接打、貼上或用語音輸入。改完按「存檔」；要請 AI 改的話先存檔或取消。"));
            // names the AI was not sure of and did not change (name ledger 「要確認」): answer once, never asked again
            var ask = item.MdPath is { } askPath && !editing ? NameLedger.Pending(Path.GetFileNameWithoutExtension(askPath)) : [];
            if (ask.Count > 0)
            {
                top.Children.Add(Neu.Note($"這一場有 {ask.Count} 個名字 AI 沒把握、沒有改（紀錄裡標了 [[?]]）。答一次就記住，之後的會議不會再問。"));
                foreach (var q in ask.Take(8))
                {
                    var row = new WrapPanel();
                    row.Children.Add(Neu.Text($"「{q.Heard}」是「{q.Name}」嗎？", Neu.TBody, Theme.InkStrong));
                    row.Children.Add(Neu.Chip("是", () => AnswerName(q, true), Neu.IcCheck));
                    row.Children.Add(Neu.Chip("不是", () => AnswerName(q, false), Neu.IcCancel));
                    top.Children.Add(row);
                }
            }
        }
        if (translations.Count > 0 && item.MdPath is { } orig)
        {
            var row = new WrapPanel { Margin = new Thickness(0, Neu.XS, 0, 0) };
            var lab = Neu.Text("看哪一版", Neu.TCaption, Theme.InkMid, semi: true, wrap: false); lab.VerticalAlignment = VerticalAlignment.Center; lab.Margin = new Thickness(0, 0, Neu.SM, 0);
            row.Children.Add(lab);
            row.Children.Add(Neu.Chip("原文" + (current == orig ? " ✓" : ""), () => { current = orig; Load(); Build(); }));
            foreach (var l in translations)
            {
                var u = TranslatedPath(l);
                row.Children.Add(Neu.Chip(DocLabels.Name(l) + (current == u ? " ✓" : ""), () => { current = u; Load(); Build(); }));
            }
            top.Children.Add(row);
        }
        if (showTranslate && item.MdPath is { } mdPath) top.Children.Add(TranslatePanel(mdPath));
        if (msg.Length > 0) { var n = Neu.Note(msg); n.Margin = new Thickness(0, Neu.XS, 0, Neu.XS); top.Children.Add(n); }
        if (busy)
        {
            var row = new DockPanel { LastChildFill = true };
            var g = Neu.Groove(null, 8); g.Width = 140;
            DockPanel.SetDock(g, Dock.Left);
            row.Children.Add(g);
            var t = Neu.Text(stage.Length == 0 ? "處理中…" : stage, Neu.TCaption, Theme.InkMid); t.Margin = new Thickness(Neu.MD, 0, 0, 0); t.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(t);
            var box = Neu.Inset(row, Neu.RCard, 0.7, new Thickness(Neu.MD));
            box.Margin = new Thickness(0, Neu.XS, 0, Neu.XS);
            top.Children.Add(box);
        }
        if (showAI && item.MdPath is { } mp) top.Children.Add(AIPanel(mp));
        if (showRepolish && item.MdPath is { } rp) top.Children.Add(RepolishPanel(rp));
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(top);

        FrameworkElement content;
        if (editing)
        {
            editor = new TextBox
            {
                Text = draft, AcceptsReturn = true, AcceptsTab = false, TextWrapping = TextWrapping.Wrap, FontFamily = Neu.UIFont, FontSize = Neu.TBody,
                Foreground = Theme.InkStrong, Background = Brushes.Transparent, BorderThickness = new Thickness(0), CaretBrush = Theme.InkStrong,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto, SelectionBrush = Theme.InkMid,
            };
            editor.TextChanged += (_, _) => draft = editor.Text;
            content = Neu.Inset(editor, Neu.RCard, 0.9, new Thickness(Neu.MD));
        }
        else if (mode == 0) content = DocView.Build(DisplayText, DocLabels.LanguageOf(current ?? item.MdPath ?? item.Dir));
        else
        {
            var tb = new TextBox
            {
                Text = DisplayText, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontFamily = Neu.UIFont, FontSize = Neu.TBody,
                Foreground = Theme.InkStrong, Background = Brushes.Transparent, BorderThickness = new Thickness(0),
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto, SelectionBrush = Theme.InkMid,
            };
            content = Neu.Inset(tb, Neu.RCard, 0.9, new Thickness(Neu.MD));
        }
        content.Margin = new Thickness(0, Neu.SM, 0, 0);
        root.Children.Add(content);
        Content = root;
    }

    FrameworkElement TranslatePanel(string mdPath)
    {
        var p = new StackPanel();
        p.Children.Add(Neu.Note("把這份紀錄翻成別的語言，另存一份（原文不動、逐字稿不翻）。要有接上 Claude 或本機模型才能翻。"));
        var row = new WrapPanel { Margin = new Thickness(0, Neu.SM, 0, 0) };
        foreach (var l in new[] { "en", "ja", "zh-CN" })
        {
            var lang = l;
            var b = Neu.Capsule("翻成" + DocLabels.Name(l), () =>
            {
                busy = true; msg = ""; stage = $"翻成{DocLabels.Name(lang)}中…（整份交給 AI 翻，通常 1 分鐘上下；翻好會另存一份、自動切過去看）";
                Build();
                var provider = Providers.Current();
                Task.Run(() =>
                {
                    try
                    {
                        var u = Repolish.Translate(mdPath, lang, provider);
                        Gui.OnUi(() => { busy = false; stage = ""; translations = FindTranslations(); current = u; Load(); showTranslate = false; msg = $"翻好了，現在看的是{DocLabels.Name(lang)}版（{Path.GetFileName(u)}）；要回原文按上面的「原文」"; Build(); });
                    }
                    catch (Exception e) { Gui.OnUi(() => { busy = false; stage = ""; msg = e.Message; Build(); }); }
                });
            }, 36, !busy);
            b.Width = 150;
            row.Children.Add(b);
        }
        p.Children.Add(row);
        var box = Neu.Inset(p, Neu.RCard, 0.7, new Thickness(Neu.MD));
        box.Margin = new Thickness(0, Neu.XS, 0, Neu.XS);
        return box;
    }

    FrameworkElement AIPanel(string mdPath)
    {
        var p = new StackPanel();
        var secRow = new WrapPanel();
        var lab = Neu.Text("改哪一節", Neu.TCaption, Theme.InkMid, semi: true, wrap: false); lab.VerticalAlignment = VerticalAlignment.Center; lab.Margin = new Thickness(0, 0, Neu.SM, 0);
        secRow.Children.Add(lab);
        foreach (var s in SectionNames) { var sec = s; secRow.Children.Add(Neu.Chip(s + (aiSection == s ? " ✓" : ""), () => { aiSection = sec; Build(); })); }
        p.Children.Add(secRow);
        var (field, _) = Neu.Field("用一句話說哪裡不對、要改成什麼（例：這條的負責人是小華不是小明）", aiInstruction, t => aiInstruction = t, multiline: true, maxLines: 3);
        field.Margin = new Thickness(0, Neu.SM, 0, Neu.SM);
        p.Children.Add(field);
        var actions = new WrapPanel();
        var go = Neu.Capsule("請 AI 改這一節", () =>
        {
            if (Str.TrimWSNL(aiInstruction).Length == 0) { msg = "先寫一句要改什麼"; Build(); return; }
            busy = true; aiPreview = null; msg = "";
            stage = $"AI 改「{aiSection}」中…（會對照逐字稿，通常半分鐘到 1 分鐘；改好先並排給你看，按「確認寫入」才會存）";
            Build();
            var provider = Providers.Current(); var sec = aiSection; var ins = aiInstruction;
            Task.Run(() =>
            {
                try { var t = Repolish.Section(mdPath, sec, ins, provider); Gui.OnUi(() => { busy = false; stage = ""; aiPreview = t; Build(); }); }
                catch (Exception e) { Gui.OnUi(() => { busy = false; stage = ""; msg = e.Message; Build(); }); }
            });
        }, 38, !busy);
        go.Width = 180;
        actions.Children.Add(go);
        if (aiPreview is { } pv)
        {
            actions.Children.Add(Neu.Chip("確認寫入", () =>
            {
                try { Repolish.ReplaceSection(mdPath, aiSection, pv); Load(); aiPreview = null; showAI = false; msg = "已寫入，原版備份成 _舊版"; }
                catch (Exception e) { msg = e.Message; }
                Build();
            }));
            actions.Children.Add(Neu.Chip("不要", () => { aiPreview = null; Build(); }));
        }
        p.Children.Add(actions);
        if (aiPreview is { } preview)
        {
            var cols = new Grid { Margin = new Thickness(0, Neu.SM, 0, 0) };
            cols.ColumnDefinitions.Add(new ColumnDefinition());
            cols.ColumnDefinitions.Add(new ColumnDefinition());
            var a = Column("原本", OriginalText(aiSection)); Grid.SetColumn(a, 0); a.Margin = new Thickness(0, 0, Neu.MD, 0);
            var b = Column("AI 改後", preview); Grid.SetColumn(b, 1);
            cols.Children.Add(a); cols.Children.Add(b);
            p.Children.Add(cols);
        }
        var box = Neu.Inset(p, Neu.RCard, 0.7, new Thickness(Neu.MD));
        box.Margin = new Thickness(0, Neu.XS, 0, Neu.XS);
        return box;
    }

    static FrameworkElement Column(string title, string text)
    {
        var s = new StackPanel();
        s.Children.Add(Neu.Text(title, Neu.TMicro, Theme.InkSoft, semi: true));
        var sv = new ScrollViewer { MaxHeight = 160, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = Neu.Text(text, Neu.TCaption, Theme.InkStrong) };
        s.Children.Add(sv);
        return s;
    }

    string OriginalText(string section)
    {
        var rec = RecordMD.Parse(md);
        if (section.Has("待辦")) return string.Join("\n", rec.Todos.Select(t => $"{t.Item}｜{t.Owner}｜{t.Due}"));
        return string.Join("\n", rec.Section(section) ?? []);
    }

    FrameworkElement RepolishPanel(string mdPath)
    {
        var p = new StackPanel();
        p.Children.Add(Neu.Note("整份紀錄交給 AI 照逐字稿重寫一次（錄音不用重聽）。可以先寫更正（例：「Kevien」應為「Kevin」，或「負責人是小華」），它會照著改。按下去大約 1 到 2 分鐘，跑完會直接換成新版；原來那版會留一份備份。"));
        var (field, _) = Neu.Field("更正（一行一條，可空白）", corrections, t => corrections = t, multiline: true, maxLines: 4);
        field.Margin = new Thickness(0, Neu.SM, 0, Neu.SM);
        p.Children.Add(field);
        p.Children.Add(Neu.Capsule(busy ? "AI 重新整理中…" : "開始重新整理（約 1 到 2 分鐘）", () =>
        {
            busy = true; msg = ""; stage = "AI 重新整理中…";
            Build();
            var provider = Providers.Current(); var corr = corrections;
            Task.Run(() =>
            {
                try
                {
                    Repolish.Whole(mdPath, corr, provider, t => Gui.OnUi(() => { stage = t.Has("AI") ? t + "（整份重寫，通常 1 到 2 分鐘；可以先去做別的事，跑完會直接換成新版）" : t; Build(); }));
                    Gui.OnUi(() => { busy = false; stage = ""; msg = "重新整理好了，下面就是新版；原來那版備份成 _舊版，在這一場的資料夾裡"; Load(); showRepolish = false; corrections = ""; Build(); });
                }
                catch (Exception e) { Gui.OnUi(() => { busy = false; stage = ""; msg = e.Message; Build(); }); }
            });
        }, 38, !busy));
        var box = Neu.Inset(p, Neu.RCard, 0.7, new Thickness(Neu.MD));
        box.Margin = new Thickness(0, Neu.XS, 0, Neu.XS);
        return box;
    }

    /// Answer a 「要確認」 name: into the name ledger (yes = recognise it this way next time; no = do not change it)
    void AnswerName(NameLedger.Question q, bool yes)
    {
        try
        {
            NameLedger.Answer(q.Heard, q.Name, yes);
            msg = yes ? $"記住了：「{q.Heard}」是「{q.Name}」，下一場照這個認" : $"記住了：「{q.Heard}」不是「{q.Name}」，之後不會這樣改";
        }
        catch (Exception e) { msg = e.Message; }
        Build();
    }

    void Save()
    {
        if ((current ?? item.MdPath) is not { } u) return;
        try
        {
            RecordMD.BackupIfExists(u);
            var before = md;
            RecordMD.Write(u, draft);
            try { Mirror.Copy(u); } catch { }
            msg = "已存檔，原版備份成 _舊版";
            // a name changed: into the name ledger (the next meeting gets it right); translations do not count
            if (MemoryStore.IsMainRecord(u))
            {
                var learned = NameLedger.Learn(before, draft, "你在 Hearby 改的", u);
                if (learned.Count > 0) msg += $"；記住 {learned.Count} 個名字（{string.Join("、", learned.Take(3).Select(e => $"{e.Heard}→{e.Name}"))}{(learned.Count > 3 ? "…" : "")}），下一場自己就對";
            }
            // Edited the record by hand (a name, say): memory follows; translations are skipped by Sync itself
            try { MemoryStore.Sync(u); } catch { }
            md = draft; editing = false;
        }
        catch (Exception e) { msg = e.Message; }
        Build();
    }
}

// ── settings ──

public sealed class SettingsView : ContentControl
{
    string msg = "";
    public SettingsView() { Build(); }

    void Build()
    {
        var c = ConfigStore.Shared.Current;
        var p = new StackPanel();
        p.Children.Add(Neu.Section("紀錄要誰寫", Neu.IcPerson, "錄完會先有一份逐字稿（誰講了什麼、幾分幾秒）。要變成有摘要、重點、待辦的紀錄，得有人整理。交給你付費的 Claude，用的是帳號本來就有的額度，不另外收費，也不用申請什麼金鑰。沒有帳號就先只要逐字稿。", new ProvidersPane()));

        var appear = new WrapPanel();
        foreach (var (id, label) in new[] { ("system", "跟隨系統"), ("light", "淺色"), ("dark", "深色") })
            appear.Children.Add(Neu.Chip(label + (c.Appearance == id ? " ✓" : ""), () => { ConfigStore.Shared.Update(x => x.Appearance = id); Theme.Apply(id); }));
        p.Children.Add(Neu.Section("外觀", Neu.IcColor, "跟隨系統、淺色、深色。只影響這個 app 的長相。", appear));

        var fb = c.FloatingBarOn;
        p.Children.Add(Neu.Section("錄音中", Neu.IcWave, "面板收起來的時候，螢幕上方會有一條小狀態列：看得到在錄還是暫停、錄了幾分幾秒、麥克風有沒有收到聲音，也能直接暫停或停止。拖得動。螢幕分享時它不會出現在對方畫面上。工作列右下角的 Hearby 圖示也看得到錄音狀態。",
            Neu.Row(Neu.SM, Neu.Chip(fb ? "螢幕上的小狀態列：開著 ✓" : "螢幕上的小狀態列：關著", () => { ConfigStore.Shared.Update(x => x.FloatingBar = !fb); Gui.PanelVisibilityChanged(); Build(); }),
                Neu.Note(fb ? "面板收起來就會出現；面板打開就收掉" : "只看工作列圖示"))));

        var gpu = c.UseGPUOn;
        p.Children.Add(Neu.Section("聽打", Neu.IcMic, "聽打（把聲音變成文字）全在這台電腦上跑，不上網。有獨立顯示卡或較新的內建顯示晶片時，用顯示卡會快很多；遇到顯示卡驅動程式有問題，關掉這個就改用處理器。",
            Neu.Row(Neu.SM, Neu.Chip(gpu ? "用顯示卡加速：開著 ✓" : "用顯示卡加速：關著", () => { ConfigStore.Shared.Update(x => x.UseGPU = !gpu); Build(); }),
                Neu.Note(ModelCatalog.InstalledModel() is { } mm ? $"模型：{Path.GetFileName(mm)}" : $"模型還沒下載（約 {AppState.ModelSizeText}）"))));

        var mirror = c.MirrorDir ?? "";
        var rootRow = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, Neu.SM) };
        var openRoot = Neu.Chip("打開", () => Exporters.Reveal(Paths.Root), Neu.IcFolder);
        DockPanel.SetDock(openRoot, Dock.Right);
        rootRow.Children.Add(openRoot);
        var rootText = Neu.Text(Paths.Root, Neu.TCaption, Theme.InkMid, wrap: false); rootText.VerticalAlignment = VerticalAlignment.Center;
        rootRow.Children.Add(rootText);
        var mirrorRow = new DockPanel { LastChildFill = true };
        var (mf, mbox) = Neu.Field("副本資料夾（選填，貼路徑，例：OneDrive 裡的一個資料夾）", mirror);
        var saveMirror = Neu.Chip("存", () =>
        {
            var v = Str.TrimWSNL(mbox.Text);
            ConfigStore.Shared.Update(x => x.MirrorDir = v.Length == 0 ? null : v);
            msg = v.Length == 0 ? "副本資料夾已清掉" : "副本資料夾已存：每份紀錄會多存一份到那裡"; Build();
        });
        DockPanel.SetDock(saveMirror, Dock.Right);
        mirrorRow.Children.Add(saveMirror);
        mf.Margin = new Thickness(0, 3, Neu.SM, 0);
        mirrorRow.Children.Add(mf);
        p.Children.Add(Neu.Section("紀錄存在哪", Neu.IcFolder, "每一場的錄音、逐字稿、紀錄、匯出的文件，都在這個資料夾裡，一場一個子資料夾。副本資料夾＝每份紀錄再多存一份到你指定的地方（例如 OneDrive 或 Dropbox 同步夾，或給你的 AI 助理讀的資料夾）。", rootRow, mirrorRow));

        var docRow = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, Neu.SM) };
        var (cf, cbox) = Neu.Field("公司名稱", c.DocCompany ?? "");
        var (rf, rbox) = Neu.Field("記錄人", c.DocRecorder ?? "");
        var saveDoc = Neu.Chip("存", () => { var co = Str.TrimWSNL(cbox.Text); var re = Str.TrimWSNL(rbox.Text); ConfigStore.Shared.Update(x => { x.DocCompany = co.Length == 0 ? null : co; x.DocRecorder = re.Length == 0 ? null : re; }); msg = "表頭預設已存"; Build(); });
        DockPanel.SetDock(saveDoc, Dock.Right);
        docRow.Children.Add(saveDoc);
        var fields = new Grid();
        fields.ColumnDefinitions.Add(new ColumnDefinition());
        fields.ColumnDefinitions.Add(new ColumnDefinition());
        cf.Margin = new Thickness(0, 3, Neu.SM, 0); rf.Margin = new Thickness(0, 3, Neu.SM, 0);
        Grid.SetColumn(rf, 1);
        fields.Children.Add(cf); fields.Children.Add(rf);
        docRow.Children.Add(fields);
        var ap = c.AutoPDF;
        p.Children.Add(Neu.Section("匯出文件（PDF、Word）", Neu.IcDoc, "要給別人看的時候用。文件是你們公司的，不會有 Hearby 的標誌。這裡填的公司名和記錄人會先填好在每次匯出的表頭，匯出前還能改。",
            docRow, Neu.Row(Neu.SM, Neu.Chip(ap ? "每場自動出 PDF ✓" : "PDF 要的時候再按", () => { ConfigStore.Shared.Update(x => x.AutoPDF = !ap); Build(); }), Neu.Note("Word 檔（.docx）用 Word 就能直接開"))));

        var (gf, gbox) = Neu.Field("例：Kevin、Hearby、專案代號（頓號或換行分隔）", Clean.LocalGlossary() ?? "", multiline: true, maxLines: 5);
        gf.Margin = new Thickness(0, 0, 0, Neu.SM);
        p.Children.Add(Neu.Section("常用詞", Neu.IcFont, "常出現的人名、公司名、產品名。聽寫有時會把名字寫錯，寫在這裡的會被自動改回正確寫法。",
            gf, Neu.Chip("存常用詞", () => { try { Clean.SaveGlossary(gbox.Text); msg = "常用詞已存"; } catch (Exception e) { msg = $"常用詞沒有存成：{e.Message}"; } Build(); })));

        var mem = c.MemoryEnabled;
        p.Children.Add(Neu.Section("記憶（給有在用 Claude Code 的人）", Neu.IcMemory, "打開後，每開完一場會，Hearby 會把誰出席、談了什麼、決定了什麼、還沒做完的事，記在紀錄資料夾裡的幾個文字檔。之後你在那個資料夾用 Claude Code 問問題，它就知道你開過哪些會，不用重講一遍；下一場開錄前也會把上次沒做完的事列出來。沒在用 Claude Code 的話關著就好，紀錄照樣存。",
            Neu.Row(Neu.SM, Neu.Chip(mem ? "開著 ✓" : "關著", () =>
            {
                ConfigStore.Shared.Update(x => x.MemoryEnabled = !mem);
                if (!mem) { try { MemoryStore.Ensure(); EntryFiles.Ensure(); } catch { } }
                Build();
            }), Neu.Note(mem ? "開完會會自動記；上次沒做完的事會出現在開錄前" : "現在不記；紀錄照樣存"))));

        var upd = Updates.StatusLine;
        p.Children.Add(Neu.Section("更新", Neu.IcUpdate, "Hearby 會在背景看 GitHub 上有沒有新版；有的話先下載好，下次打開 Hearby（或按「現在更新」）就會換成新版。錄音和紀錄不受影響。",
            Neu.Row(Neu.SM, Neu.Chip("檢查更新", () => { Updates.CheckNow(); msg = "檢查中…"; Build(); }), Updates.Ready ? Neu.Chip("現在更新", Updates.ApplyNow) : new Border(),
                Neu.Chip(c.AutoUpdateOn ? "自動檢查：開著 ✓" : "自動檢查：關著", () => { var on = ConfigStore.Shared.Current.AutoUpdateOn; ConfigStore.Shared.Update(x => x.AutoUpdate = !on); Build(); })),
            Neu.Note(upd)));

        p.Children.Add(Neu.Section("其他", Neu.IcMore, "怪怪的時候：先到「檢查」看哪一項不對；還是不行就匯出診斷檔，把桌面那個 txt 傳給我們。",
            Neu.Flow(Neu.Chip("重新跑一次設定精靈", Gui.OpenWizard, Neu.IcWand), Neu.Chip("匯出診斷檔到桌面", () => { msg = Exporters.Diagnostics() is { } u ? $"診斷檔：{u}" : "診斷檔寫不出來"; Build(); }, Neu.IcHealth),
                Neu.Chip("打開紀錄檔資料夾", () => Exporters.Reveal(Paths.Logs), Neu.IcFolder))));
        if (msg.Length > 0) { var n = Neu.Note(msg); n.Margin = new Thickness(Neu.SM, 0, 0, Neu.SM); p.Children.Insert(0, n); }
        Content = Neu.Scroll(p);
    }
}

// ── status ──

public sealed class StatusView : ContentControl
{
    DoctorReport? report;
    bool busy;
    public StatusView()
    {
        Build();
        Task.Run(() => { var r = Doctor.Run(false); Gui.OnUi(() => { report ??= r; Build(); }); });
    }

    void Build()
    {
        var p = new StackPanel();
        var head = new DockPanel { LastChildFill = false, Margin = new Thickness(0, 0, 0, Neu.MD) };
        var t = Neu.Text("現在正不正常", Neu.TTitle, Theme.InkStrong, semi: true, wrap: false);
        DockPanel.SetDock(t, Dock.Left);
        head.Children.Add(t);
        var again = Neu.Chip(busy ? "檢查中…" : "重新檢查", () =>
        {
            busy = true; Build();
            Task.Run(() => { var r = Doctor.Run(true); Gui.OnUi(() => { report = r; busy = false; Build(); }); });
        }, enabled: !busy);
        DockPanel.SetDock(again, Dock.Right);
        head.Children.Add(again);
        p.Children.Add(head);
        if (report is { } r)
        {
            var list = new StackPanel();
            foreach (var i in r.Items)
            {
                var tag = Neu.StatusTag(i.State switch { DoctorItem.Status.Ok => Neu.Level.Ready, DoctorItem.Status.Missing => Neu.Level.Missing, _ => Neu.Level.Pending }, $"{i.Name}：{i.Detail}");
                tag.Margin = new Thickness(0, 0, 0, Neu.SM);
                list.Children.Add(tag);
            }
            p.Children.Add(Neu.Inset(list, Neu.RCard, 0.9, new Thickness(Neu.MD, Neu.MD, Neu.MD, Neu.XS)));
        }
        else p.Children.Add(Neu.Note("檢查中…"));
        var logLine = Neu.Note($"紀錄檔：{HearbyLog.File}");
        logLine.Margin = new Thickness(0, Neu.MD, 0, 0);
        p.Children.Add(logLine);
        Content = Neu.Scroll(p);
    }
}
