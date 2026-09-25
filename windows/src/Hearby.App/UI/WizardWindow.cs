// WizardWindow — first launch (mirrors Wizard/WizardView.swift): welcome (poster) → let it hear (microphone / online
// meetings) → who writes the record → try once → done. Windows needs no permission prompt for audio: the only switch is the
// microphone privacy setting, which is checked and linked here.
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Hearby.Core;
using NAudio.CoreAudioApi;

namespace Hearby.App.UI;

public sealed class WizardWindow : NeuWindow
{
    const int Total = 4;
    int step;
    readonly PanelModel panel = AppState.Shared.Panel;
    readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromSeconds(1.5) };
    bool micOk, micBlocked, micMissing;
    string micName = "";
    bool online = ConfigStore.Shared.Current.Online;
    public Action OnFinish = () => { };

    public WizardWindow() : base(480, 660, resizable: false, stage: true)
    {
        ScaleToFit = true;
        FitToScreen();
        step = Math.Clamp(ConfigStore.Shared.Current.WizardStep, 0, Total);
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;
        CheckMic();
        tick.Tick += (_, _) => { var before = (micOk, micBlocked, micMissing); CheckMic(); if (before != (micOk, micBlocked, micMissing) && step == 1) Rebuild(); };
        tick.Start();
        panel.Changed += OnPanelChanged;
        panel.Ticked += OnPanelTick;
        Closed += (_, _) => { tick.Stop(); panel.Changed -= OnPanelChanged; panel.Ticked -= OnPanelTick; };
        Rebuild();
    }

    Border? footerHost;
    void OnPanelTick() { if (IsVisible && footerHost != null) footerHost.Child = Footer(); }
    /// Structural change (phase, model ready): rebuild, except on the providers page where a sign-in may be in progress
    void OnPanelChanged()
    {
        if (!IsVisible || step == 0) return;
        if (step == 2) { OnPanelTick(); return; }
        Rebuild();
    }

    void CheckMic()
    {
        var allowed = DoctorChecks.MicAllowed();
        micBlocked = allowed == false;
        try
        {
            using var en = new MMDeviceEnumerator();
            if (en.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Console)) { using var d = en.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console); micName = d.FriendlyName; micMissing = false; }
            else { micName = ""; micMissing = true; }
        }
        catch { micMissing = false; }
        micOk = !micBlocked && !micMissing;
    }

    public void GoTo(int s) => Go(s);

    void Go(int s)
    {
        step = Math.Clamp(s, 0, Total);
        ConfigStore.Shared.Update(c => c.WizardStep = step);
        Rebuild();
    }

    protected override UIElement BuildContent()
    {
        footerHost = null;
        if (step == 0) return Welcome();
        var root = new DockPanel { Margin = new Thickness(Neu.XL, 8, Neu.XL, Neu.LG), LastChildFill = true };
        var head = new DockPanel { LastChildFill = false, Height = 34 };
        var n = Neu.Text($"{step} / {Total}", Neu.TMicro, Theme.InkSoft, wrap: false); n.FontFamily = Neu.MarkFont; n.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(n, Dock.Left);
        head.Children.Add(n);
        var cap = CaptionButtons();
        DockPanel.SetDock(cap, Dock.Right);
        head.Children.Add(cap);
        var logo = Brand.LogotypeView(15, Theme.InkMid);
        logo.VerticalAlignment = VerticalAlignment.Center; logo.Margin = new Thickness(0, 0, Neu.MD, 0);
        DockPanel.SetDock(logo, Dock.Right);
        head.Children.Add(logo);
        DockPanel.SetDock(head, Dock.Top);
        root.Children.Add(head);
        footerHost = new Border { Child = Footer() };
        DockPanel.SetDock(footerHost, Dock.Bottom);
        root.Children.Add(footerHost);
        FrameworkElement body = step switch { 1 => Permissions(), 2 => ProvidersPage(), 3 => Trial(), _ => Finish() };
        body.Margin = new Thickness(0, Neu.LG, 0, Neu.MD);
        root.Children.Add(body);
        return root;
    }

    FrameworkElement Footer()
    {
        var p = new StackPanel();
        if (panel.DownloadFraction is { } f)
        {
            var row = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, Neu.MD) };
            var t = Neu.Text($"聽打模型 {f * 100:0}%", Neu.TMicro, Theme.InkMid, wrap: false); t.Margin = new Thickness(Neu.SM, 0, 0, 0); t.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(t, Dock.Right);
            row.Children.Add(t);
            row.Children.Add(Neu.Groove(f, 8));
            p.Children.Add(row);
        }
        else if (!panel.ModelReady && panel.DownloadNote.Length > 0)
        {
            var row = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, Neu.MD) };
            var c = Neu.Chip("再試一次", AppState.Shared.DownloadWhisper);
            DockPanel.SetDock(c, Dock.Right);
            row.Children.Add(c);
            row.Children.Add(Neu.Note(panel.DownloadNote));
            p.Children.Add(row);
        }
        p.Children.Add(Brand.PoweredBy(showWordmark: false));
        return p;
    }

    FrameworkElement Nav(string next = "下一步", bool canSkip = false, bool nextEnabled = true, string? reason = null, Action? action = null)
    {
        var p = new StackPanel();
        if (!nextEnabled && reason != null) { var r = Neu.Note(reason); r.Margin = new Thickness(0, 0, 0, Neu.SM); p.Children.Add(r); }
        var d = new DockPanel { LastChildFill = true };
        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (step > 0) left.Children.Add(Neu.IconButton(Neu.IcBack, () => Go(step - 1), 32, "上一步"));
        if (canSkip) { var s = Neu.Chip("先跳過", () => Go(step + 1)); s.Margin = new Thickness(Neu.SM, 3, 5, 6); left.Children.Add(s); }
        DockPanel.SetDock(left, Dock.Left);
        d.Children.Add(left);
        var b = Neu.Capsule(next, action ?? (() => Go(step + 1)), 46, nextEnabled);
        b.Margin = new Thickness(Neu.MD, 0, 0, 0);
        d.Children.Add(b);
        p.Children.Add(d);
        return p;
    }

    static FrameworkElement Heading(string t, MarkView.Mode? mark = MarkView.Mode.Idle)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, Neu.LG) };
        if (mark is { } m) { var mv = new MarkView(m, 15) { Width = 36, Height = 36 }; row.Children.Add(mv); }
        var h = Neu.Text(t, Neu.THero, Theme.InkStrong, semi: true, wrap: false);
        h.VerticalAlignment = VerticalAlignment.Center; h.Margin = new Thickness(Neu.MD, 0, 0, 0);
        row.Children.Add(h);
        return row;
    }

    // 0 welcome: the studio photo as a poster, the logotype on its empty corner, two sentences and 「開始設定」 below.
    // The photo is a light-grey studio shot used in both themes; its text stays dark grey (follows the photo, not the theme).
    FrameworkElement Welcome()
    {
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(412) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var photo = new Grid { ClipToBounds = true };
        if (Brand.WizardHero.Value is { } img) photo.Children.Add(new Image { Source = img, Stretch = Stretch.UniformToFill, VerticalAlignment = VerticalAlignment.Top });
        else photo.Background = Theme.Stage;
        var overlay = new StackPanel { Margin = new Thickness(36, 44, 0, 0), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
        overlay.Children.Add(new TextBlock { Text = "MEETING RECORDER FOR WINDOWS", FontFamily = new FontFamily("Consolas, Cascadia Mono"), FontSize = 10, Foreground = new SolidColorBrush(Color.FromRgb(0x61, 0x61, 0x61)), Margin = new Thickness(0, 0, 0, 12) });
        overlay.Children.Add(Brand.Tinted(Brand.Logotype.Value, 50, new SolidColorBrush(Color.FromRgb(0x1A, 0x1A, 0x1A)), "hearby”"));
        photo.Children.Add(overlay);
        var cap = CaptionButtons();
        cap.HorizontalAlignment = HorizontalAlignment.Right; cap.VerticalAlignment = VerticalAlignment.Top; cap.Margin = new Thickness(0, 8, 12, 0);
        photo.Children.Add(cap);
        grid.Children.Add(photo);
        var bottom = new DockPanel { Background = Theme.Material, LastChildFill = true };
        var inner = new DockPanel { Margin = new Thickness(36, 28, 36, 26), LastChildFill = true };
        var row = new DockPanel { LastChildFill = true };
        var start = Neu.Capsule("開始設定", () =>
        {
            if (!panel.ModelReady && panel.DownloadFraction == null) AppState.Shared.DownloadWhisper();
            Task.Run(() => Providers.AutoPick());
            Go(1);
        }, 46);
        start.Width = 184;
        DockPanel.SetDock(start, Dock.Right);
        row.Children.Add(start);
        var meta = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        meta.Children.Add(Brand.PoweredBy(showWordmark: false));
        var v = Neu.Text(HearbyVersion.Version, Neu.TMicro, Theme.InkSoft, wrap: false); v.FontFamily = Neu.MarkFont; v.Margin = new Thickness(0, 3, 0, 0);
        meta.Children.Add(v);
        row.Children.Add(meta);
        DockPanel.SetDock(row, Dock.Bottom);
        inner.Children.Add(row);
        var words = new StackPanel();
        words.Children.Add(Neu.Text("開會按一下，結束就有一份紀錄。", 20, Theme.InkStrong, semi: true));
        var sub = Neu.Text("錄音、聽寫、整理成紀錄，都在你自己的電腦上完成。", Neu.TBody, Theme.InkMid); sub.Margin = new Thickness(0, 8, 0, 0);
        words.Children.Add(sub);
        inner.Children.Add(words);
        bottom.Children.Add(inner);
        Grid.SetRow(bottom, 1);
        grid.Children.Add(bottom);
        return grid;
    }

    // 1 let it hear: two rows of equal weight
    FrameworkElement Permissions()
    {
        var d = new DockPanel { LastChildFill = false };
        var nav = Nav(nextEnabled: micOk || micBlocked || micMissing, reason: "麥克風打勾之後才能下一步。");
        DockPanel.SetDock(nav, Dock.Bottom);
        d.Children.Add(nav);
        var p = new StackPanel();
        p.Children.Add(Heading("讓它聽得到"));
        var lead = Neu.Text("要錄音，先確定 Windows 讓 Hearby 用麥克風。", Neu.TBody, Theme.InkMid); lead.Margin = new Thickness(0, 0, 0, Neu.LG);
        p.Children.Add(lead);
        string micDetail = micBlocked ? "被 Windows 的隱私權設定關掉了：打開「麥克風存取」與「讓傳統型應用程式存取您的麥克風」。"
            : micMissing ? "找不到麥克風：接上麥克風或耳機，這裡會自己打勾。"
            : "錄下你和同一個房間裡的人講的話。一定要。";
        p.Children.Add(PermRow("麥克風", micDetail, micOk, "可以用", micBlocked ? "打開 Windows 設定" : null, () => Exporters.Open("ms-settings:privacy-microphone"),
            micOk && micName.Length > 0 ? $"現在用：{micName}" : null));
        p.Children.Add(PermRow("線上開會", online ? "用 Meet、Teams、Zoom 開會時，對方講的話也會錄進來。Windows 不需要另外開權限。" : "會用 Meet、Teams、Zoom 這類線上會議嗎？勾了之後對方講的話也會錄進來。只在同一個房間開會就不用。",
            online, "會用", "我會線上開會", () => { online = true; panel.Online = true; ConfigStore.Shared.Update(c => c.Online = true); Rebuild(); }));
        if (online)
        {
            var c = Neu.Chip("改成只在同一個房間", () => { online = false; panel.Online = false; ConfigStore.Shared.Update(x => x.Online = false); Rebuild(); });
            c.HorizontalAlignment = HorizontalAlignment.Right;
            p.Children.Add(c);
        }
        if (micBlocked || micMissing)
            p.Children.Add(Neu.Note("只想整理現成的錄音檔：可以直接下一步，之後用面板上的「匯入音檔」。"));
        d.Children.Add(p);
        return d;
    }

    static FrameworkElement PermRow(string title, string detail, bool ok, string okText, string? actionTitle, Action action, string? extra = null)
    {
        var d = new DockPanel { LastChildFill = true };
        var mark = new MarkView(ok ? MarkView.Mode.Idle : MarkView.Mode.Listening, 11) { Width = 28, Height = 28, VerticalAlignment = VerticalAlignment.Top };
        DockPanel.SetDock(mark, Dock.Left);
        d.Children.Add(mark);
        FrameworkElement right = ok
            ? Neu.Row(6, Neu.Text(okText, Neu.TCaption, Theme.InkMid, wrap: false), Neu.Icon(Neu.IcCheck, 12, Theme.InkStrong))
            : actionTitle != null ? Neu.Chip(actionTitle, action) : new Border();
        right.VerticalAlignment = VerticalAlignment.Top;
        right.Margin = new Thickness(Neu.MD, 0, 0, 0);
        DockPanel.SetDock(right, Dock.Right);
        d.Children.Add(right);
        var t = new StackPanel { Margin = new Thickness(Neu.MD, 0, 0, 0) };
        t.Children.Add(Neu.Text(title, Neu.TBody, Theme.InkStrong, semi: true));
        t.Children.Add(Neu.Text(detail, Neu.TCaption, Theme.InkMid));
        if (extra != null) { var x = Neu.Text(extra, Neu.TMicro, Theme.InkSoft); x.Margin = new Thickness(0, 3, 0, 0); t.Children.Add(x); }
        d.Children.Add(t);
        var inset = Neu.Inset(d, Neu.RCard, 0.9, new Thickness(Neu.LG, Neu.MD, Neu.LG, Neu.MD));
        inset.Margin = new Thickness(0, 0, 0, Neu.LG);
        return inset;
    }

    // 2 who writes the record
    FrameworkElement ProvidersPage()
    {
        var d = new DockPanel { LastChildFill = true };
        var nav = Nav();
        DockPanel.SetDock(nav, Dock.Bottom);
        d.Children.Add(nav);
        var top = new StackPanel();
        top.Children.Add(Heading("紀錄要誰寫"));
        var lead = Neu.Text("錄完會先有一份逐字稿。要變成有摘要、重點、待辦的紀錄，得有人整理。你有付費的 Claude 帳號就交給它，用的是帳號本來就有的額度，不另外收費；沒有就先只要逐字稿，之後隨時可以改。", Neu.TBody, Theme.InkMid);
        lead.Margin = new Thickness(0, 0, 0, Neu.LG);
        top.Children.Add(lead);
        DockPanel.SetDock(top, Dock.Top);
        d.Children.Add(top);
        var s = new StackPanel();
        s.Children.Add(new ProvidersPane(compact: true, showEndpoint: false));
        var n = Neu.Text("有自己裝的本機模型（Ollama、LM Studio）？之後到「設定 → 紀錄要誰寫」接上就好。", Neu.TMicro, Theme.InkSoft); n.Margin = new Thickness(0, Neu.XS, 0, Neu.SM);
        s.Children.Add(n);
        var sc = Neu.Scroll(s);
        sc.Margin = new Thickness(0, 0, 0, Neu.MD);
        d.Children.Add(sc);
        return d;
    }

    // 3 try once
    FrameworkElement Trial()
    {
        var d = new DockPanel { LastChildFill = false };
        var nav = Nav(panel.Phase == Phase.Done ? "最後一頁" : "下一步", canSkip: panel.Phase != Phase.Done);
        DockPanel.SetDock(nav, Dock.Bottom);
        d.Children.Add(nav);
        var p = new StackPanel();
        p.Children.Add(Heading("試一次", panel.Phase == Phase.Recording ? MarkView.Mode.Listening : panel.Phase == Phase.Done ? MarkView.Mode.Flash : MarkView.Mode.Idle));
        p.Children.Add(TrayHint(caption: true));
        var steps = new StackPanel();
        foreach (var t in new[] { "1  按工作列右下角的 ”，會跳出一個小面板", "2  按中間的大圓，隨便講兩句話", "3  再按一次大圓，等一下，紀錄就整理好了" })
        { var x = Neu.Text(t, Neu.TBody, Theme.InkStrong); x.Margin = new Thickness(0, 0, 0, Neu.SM); steps.Children.Add(x); }
        var card = Neu.Inset(steps, Neu.RCard, 0.9, new Thickness(Neu.LG, Neu.LG, Neu.LG, Neu.SM));
        card.Margin = new Thickness(0, Neu.LG, 0, Neu.MD);
        p.Children.Add(card);
        var open = Neu.Chip("現在就打開面板", Gui.ShowPanel, Neu.IcNext);
        open.HorizontalAlignment = HorizontalAlignment.Left;
        p.Children.Add(open);
        if (!panel.ModelReady)
        {
            if (panel.DownloadFraction is { } f) p.Children.Add(Neu.Note($"聽寫模型（把聲音變成文字用的）下載中 {f * 100:0}%，好了才能錄；可以先按下一步。"));
            else p.Children.Add(Neu.Row(Neu.SM, Neu.Note(panel.DownloadNote.Length == 0 ? $"聽寫模型還沒下載（約 {AppState.ModelSizeText}，一次就好）。" : panel.DownloadNote), Neu.Chip("下載", AppState.Shared.DownloadWhisper)));
        }
        switch (panel.Phase)
        {
            case Phase.Recording: p.Children.Add(Neu.Note("聽到了，講吧。講完按停止。")); break;
            case Phase.Processing: p.Children.Add(Neu.Note("整理中：" + panel.StageText)); break;
            case Phase.Done:
                var ok = new StackPanel { Margin = new Thickness(0, Neu.SM, 0, 0) };
                ok.Children.Add(Neu.Text("成功了。", Neu.TTitle, Theme.InkStrong, semi: true));
                foreach (var l in panel.DoneLines) ok.Children.Add(Neu.Text("· " + l, Neu.TCaption, Theme.InkMid));
                p.Children.Add(ok);
                break;
        }
        d.Children.Add(p);
        return d;
    }

    /// A drawing of the taskbar corner: the ” in a circle is Hearby (Windows 11 may keep new icons behind ^)
    public static FrameworkElement TrayHint(bool caption)
    {
        var p = new StackPanel();
        var bar = new Border
        {
            CornerRadius = new CornerRadius(8), Background = Theme.Stage, BorderBrush = Theme.Alpha(Theme.ShadeColor, 0.3), BorderThickness = new Thickness(1),
            Height = 36, Padding = new Thickness(12, 0, 12, 0),
        };
        var row = new DockPanel { LastChildFill = false };
        var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        right.Children.Add(Neu.Icon("", 11, Theme.InkSoft));    // chevron up (the overflow ^)
        var ring = new Grid { Width = 28, Height = 28, Margin = new Thickness(10, 0, 10, 0) };
        ring.Children.Add(new System.Windows.Shapes.Ellipse { Stroke = Theme.InkStrong, StrokeThickness = 1.4 });
        ring.Children.Add(new MarkView(MarkView.Mode.Listening, 10) { Width = 24, Height = 24 });
        right.Children.Add(ring);
        foreach (var g in new[] { "", "", "" }) { var i = Neu.Icon(g, 11, Theme.InkSoft); i.Margin = new Thickness(0, 0, 8, 0); right.Children.Add(i); }
        var clock = new StackPanel { Margin = new Thickness(6, 0, 0, 0) };
        clock.Children.Add(Neu.Text("上午 9:41", 9.5, Theme.InkSoft, wrap: false, align: TextAlignment.Right));
        clock.Children.Add(Neu.Text("2026/9/28", 9.5, Theme.InkSoft, wrap: false, align: TextAlignment.Right));
        right.Children.Add(clock);
        DockPanel.SetDock(right, Dock.Right);
        row.Children.Add(right);
        bar.Child = row;
        p.Children.Add(bar);
        if (caption)
        {
            var t = Neu.Text("螢幕右下角、時間旁邊這一排小圖示裡，圈起來的引號 ” 就是 Hearby。沒看到的話按一下 ^（Windows 11 會把新圖示先收在裡面），把 Hearby 拖到外面來，以後一眼就找得到。", Neu.TCaption, Theme.InkMid);
            t.Margin = new Thickness(0, Neu.SM, 0, 0);
            p.Children.Add(t);
        }
        return p;
    }

    // 4 done
    FrameworkElement Finish()
    {
        var p = Providers.Current();
        ProviderStatus st;
        try { st = p.Check(); } catch { st = new ProviderStatus(ProviderStatus.Levels.Pending, "查不到"); }
        var rows = new List<(string, bool, string)>
        {
            ("麥克風", micOk, micOk ? "可以用" + (micName.Length > 0 ? $"（{micName}）" : "") : micBlocked ? "被 Windows 隱私權設定關掉了" : "找不到麥克風"),
            ("聽寫模型", panel.ModelReady || panel.DownloadFraction != null, panel.ModelReady ? "已下載（把聲音變成文字用的）" : panel.DownloadFraction is { } f ? $"下載中 {f * 100:0}%" : "還沒下載"),
            ("紀錄要誰寫", st.Level == ProviderStatus.Levels.Ready, $"{p.DisplayName}：{st.Text}"),
            ("紀錄存在", true, Paths.Root),
        };
        int missing = rows.Count(r => !r.Item2);
        var d = new DockPanel { LastChildFill = false };
        var done = Neu.Capsule("完成", () =>
        {
            ConfigStore.Shared.Update(c => { c.WizardDone = true; c.WizardStep = 0; });
            OnFinish();
        }, 46);
        DockPanel.SetDock(done, Dock.Bottom);
        d.Children.Add(done);
        var s = new StackPanel();
        s.Children.Add(Heading(missing == 0 ? "好了" : $"還缺 {missing} 樣"));
        var lead = Neu.Text("以後就這樣用：開會前按工作列右下角的 ” 再按大圓，結束再按一次。紀錄會自己存好。", Neu.TBody, Theme.InkMid); lead.Margin = new Thickness(0, 0, 0, Neu.MD);
        s.Children.Add(lead);
        s.Children.Add(TrayHint(caption: false));
        var list = new StackPanel();
        foreach (var (name, ok, text) in rows)
        {
            var r = new DockPanel { LastChildFill = true, Margin = new Thickness(Neu.MD, 6, Neu.MD, 6) };
            var ic = Neu.Icon(ok ? Neu.IcCheck : "", 11, ok ? Theme.InkStrong : Theme.InkSoft); ic.Width = 16;
            DockPanel.SetDock(ic, Dock.Left);
            r.Children.Add(ic);
            var nm = Neu.Text(name, Neu.TCaption, Theme.InkStrong, semi: true, wrap: false); nm.Width = 80; nm.Margin = new Thickness(Neu.SM, 0, 0, 0);
            DockPanel.SetDock(nm, Dock.Left);
            r.Children.Add(nm);
            r.Children.Add(Neu.Text(text, Neu.TMicro, ok ? Theme.InkMid : Theme.InkStrong));
            list.Children.Add(r);
        }
        var box = Neu.Inset(list, Neu.RCard, 0.8, new Thickness(0, Neu.XS, 0, Neu.XS));
        box.Margin = new Thickness(0, Neu.MD, 0, Neu.MD);
        s.Children.Add(box);
        var mem = ConfigStore.Shared.Current.MemoryEnabled;
        s.Children.Add(Neu.Row(Neu.SM,
            Neu.Chip(mem ? "記憶：開 ✓" : "記憶：關", () => { ConfigStore.Shared.Update(c => c.MemoryEnabled = !mem); if (!mem) { try { MemoryStore.Ensure(); EntryFiles.Ensure(); } catch { } } Rebuild(); }),
            Neu.InfoTip("這是給有在用 Claude Code 的人的功能。打開後，每開完一場會，Hearby 會把誰出席、談了什麼、決定了什麼、還沒做完的事，記在紀錄資料夾裡的幾個文字檔。之後你在那個資料夾用 Claude Code 問問題，它就知道你開過哪些會，不用重講一遍。沒在用的話關著就好。"),
            Neu.Note("給有在用 Claude Code 的人；不確定就先關著")));
        var n = Neu.Note("紀錄整理好會跳一個通知；除此之外它不會來吵你。"); n.Margin = new Thickness(0, Neu.SM, 0, 0);
        s.Children.Add(n);
        d.Children.Add(s);
        return d;
    }
}
