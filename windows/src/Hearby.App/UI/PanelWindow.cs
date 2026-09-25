// PanelWindow — the small panel (mirrors Panel/PanelView.swift): each state answers one question.
//   idle: meeting / interview / note, online or same room, start, the last one, what this meeting is about
//   recording: two waveforms, the timer, stop; a line appears only when something is wrong
//   processing: the stages and the transcript as it comes
//   done: title, three key lines, three buttons
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Hearby.Core;

namespace Hearby.App.UI;

public sealed class PanelWindow : NeuWindow
{
    readonly PanelModel m = AppState.Shared.Panel;
    readonly AppState s = AppState.Shared;
    // live pieces of the recording page (updated on every tick without rebuilding)
    TextBlock? elapsed, statusLine, downloadPct;
    Waveform? micWave, sysWave;
    FrameworkElement? downloadGroove;
    TextBlock? stageNote;
    Phase builtFor = (Phase)(-1);

    public PanelWindow() : base(340, 580, resizable: true, stage: false)
    {
        MinWidth = 320; MinHeight = 440;
        FitToScreen();
        HideOnClose = true;
        ShowInTaskbar = true;
        m.Changed += RebuildKeepingFocus;
        m.Ticked += OnTick;
        Rebuild();
        // drop an audio or video file on the panel = import it
        AllowDrop = true;
        DragOver += (_, e) => { e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) && m.Phase is Phase.Idle or Phase.Done ? DragDropEffects.Copy : DragDropEffects.None; e.Handled = true; };
        Drop += (_, e) =>
        {
            if (e.Data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files) s.ImportMedia(files[0]);
        };
    }

    TextBox? briefBox;
    /// Rebuild without throwing the user out of the text they are typing
    void RebuildKeepingFocus()
    {
        bool typing = briefBox is { IsKeyboardFocused: true };
        int caret = briefBox?.CaretIndex ?? 0;
        Rebuild();
        if (typing && briefBox != null)
        {
            briefBox.Focus();
            briefBox.CaretIndex = Math.Min(caret, briefBox.Text.Length);
        }
    }

    protected override void OnHidden() => Gui.PanelVisibilityChanged();

    void OnTick()
    {
        if (!IsVisible) return;
        if (m.Phase == Phase.Recording && builtFor == Phase.Recording)
        {
            if (elapsed != null) { elapsed.Text = m.ElapsedText; elapsed.Foreground = m.Paused ? Theme.InkMid : Theme.InkStrong; }
            if (statusLine != null) statusLine.Text = StatusText();
            micWave?.Set(m.MicHistory, m.Paused);
            sysWave?.Set(m.SysHistory, m.Paused || !m.SysActive);
        }
        if (m.DownloadFraction is { } f && downloadPct != null) downloadPct.Text = $"聽打模型 {f * 100:0}%";
        if (m.DownloadFraction is { } f2 && downloadGroove != null) UpdateGroove(f2);
        if (stageNote != null && m.Phase == Phase.Processing) stageNote.Text = m.StageText;
    }

    FrameworkElement? grooveHost;
    void UpdateGroove(double f)
    {
        if (grooveHost is Border b) b.Child = downloadGroove = Neu.Groove(f, 8);
    }

    string StatusText() => m.Paused ? $"已暫停 {m.PausedText}・這段不會存" : (m.MicName.Length == 0 ? "正在錄" : $"正在錄・{m.MicName}");

    protected override UIElement BuildContent()
    {
        elapsed = statusLine = downloadPct = stageNote = null; micWave = sysWave = null; downloadGroove = null; grooveHost = null; briefBox = null;
        builtFor = m.Phase;
        var root = new DockPanel { Margin = new Thickness(Neu.Edge, 10, Neu.Edge, Neu.Edge - 4), LastChildFill = true };
        var header = Header();
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);
        var foot = Brand.PoweredBy(showWordmark: false);
        foot.Margin = new Thickness(0, Neu.SM, 0, 0);
        DockPanel.SetDock(foot, Dock.Bottom);
        root.Children.Add(foot);
        FrameworkElement body = m.Phase switch
        {
            Phase.Recording => Recording(),
            Phase.Processing => Processing(),
            Phase.Done => Done(),
            Phase.Error => ErrorView(),
            _ => Idle(),
        };
        body.Margin = new Thickness(0, Neu.LG, 0, 0);
        root.Children.Add(body);
        return root;
    }

    FrameworkElement Header()
    {
        var d = new DockPanel { LastChildFill = false, Height = 30 };
        var logo = Brand.LogotypeView(13, Theme.InkMid);
        logo.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(logo, Dock.Left);
        d.Children.Add(logo);
        var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (m.Phase == Phase.Recording && !m.Paused) right.Children.Add(new MarkView(MarkView.Mode.Listening, 8) { Width = 20, Height = 20 });
        var label = Neu.Text(m.Phase == Phase.Recording && m.Paused ? "已暫停" : m.Phase.Label(), Neu.TMicro, Theme.InkSoft, wrap: false);
        label.VerticalAlignment = VerticalAlignment.Center;
        label.Margin = new Thickness(4, 0, 6, 0);
        right.Children.Add(label);
        right.Children.Add(Clickable(Neu.IconButton(Neu.IcLibrary, () => Gui.OpenWindow(0), 26, "看以前的紀錄")));
        right.Children.Add(Clickable(Neu.IconButton(Neu.IcSettings, () => Gui.OpenWindow(1), 26, "設定")));
        var close = Clickable(Neu.IconButton(Neu.IcClose, Close, 26, "收起面板（Hearby 還在工作列右下角）"));
        close.Margin = new Thickness(6, 0, 0, 0);
        right.Children.Add(close);
        DockPanel.SetDock(right, Dock.Right);
        d.Children.Add(right);
        return d;
    }

    // ── idle ──
    FrameworkElement Idle()
    {
        var scenes = RecordSceneExt.All;
        var scene = scenes[Math.Clamp(m.Scene, 0, scenes.Length - 1)];
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var top = new StackPanel();
        var seg = Neu.Segmented(scenes.Select(x => x.Label()).ToList(), m.Scene, i => { m.Scene = i; m.RaiseChanged(); });
        seg.Margin = new Thickness(0, 0, 0, Neu.MD);
        top.Children.Add(seg);
        var onlineRow = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, Neu.MD) };
        var chip = Neu.Chip(m.Online ? "線上會議 ✓" : "同一個房間 ✓", () => { m.Online = !m.Online; ConfigStore.Shared.Update(c => c.Online = m.Online); m.RaiseChanged(); });
        DockPanel.SetDock(chip, Dock.Left);
        onlineRow.Children.Add(chip);
        var tip = Neu.InfoTip(m.Online
            ? "用 Meet、Teams、Zoom 這類線上會議時選這個：除了你的麥克風，電腦裡對方講的話也會錄進來。Windows 不需要另外開權限。"
            : "大家都在同一個房間就選這個：只用麥克風。點一下可以切換成線上會議。");
        DockPanel.SetDock(tip, Dock.Right);
        onlineRow.Children.Add(tip);
        var hint = Neu.Text(m.Online ? "也會錄對方講的話" : "只錄麥克風", Neu.TMicro, Theme.InkSoft, wrap: false);
        hint.VerticalAlignment = VerticalAlignment.Center; hint.Margin = new Thickness(Neu.SM, 0, 0, 0);
        onlineRow.Children.Add(hint);
        top.Children.Add(onlineRow);
        top.Children.Add(BriefField());
        if (!m.ModelReady) top.Children.Add(ModelLine());
        if (m.UpdateReady is { } ver)
        {
            var up = Neu.Row(Neu.SM, Neu.Note($"新版 {ver} 已下載好"), Neu.Chip("現在更新", () => Updates.ApplyNow()));
            up.Margin = new Thickness(0, Neu.SM, 0, 0);
            top.Children.Add(up);
        }
        Grid.SetRow(top, 0);
        grid.Children.Add(top);

        var center = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        var anchor = Neu.Anchor(false, s.Start, 92);
        anchor.HorizontalAlignment = HorizontalAlignment.Center;
        center.Children.Add(anchor);
        var sh = Neu.Text(scene.Hint(), Neu.TMicro, Theme.InkSoft, align: TextAlignment.Center);
        sh.HorizontalAlignment = HorizontalAlignment.Center;
        center.Children.Add(sh);
        Grid.SetRow(center, 2);
        grid.Children.Add(center);

        var bottom = new StackPanel();
        if (m.PendingRecoveries.Count > 0)
        {
            var r = m.PendingRecoveries[0];
            var line = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, Neu.SM) };
            var chips = Neu.Row(Neu.XS, Neu.Chip("補整理", () => s.Recover(r)), Neu.Chip("略過", () => s.IgnoreRecovery(r)));
            DockPanel.SetDock(chips, Dock.Right);
            line.Children.Add(chips);
            var n = Neu.Note($"有 {m.PendingRecoveries.Count} 場錄音還沒整理（{Fmt.Dur(r.Seconds)}）");
            n.VerticalAlignment = VerticalAlignment.Center;
            line.Children.Add(n);
            bottom.Children.Add(line);
        }
        var foot = new DockPanel { LastChildFill = true };
        var import = Neu.Row(Neu.SM, Neu.Link("匯入音檔", s.PickImport), Neu.IconButton(Neu.IcImport, s.PickImport, 26, "已經有錄好的音檔或影片？丟進來一樣能整理"));
        DockPanel.SetDock(import, Dock.Right);
        foot.Children.Add(import);
        if (m.LastMeeting is { } last)
        {
            var l = Neu.Link($"上一場　{last.Title}", () => { if (last.MdPath != null) Gui.OpenRecord(last.MdPath); else Gui.OpenWindow(0); }, icon: Neu.IcHistory, tip: "打開上一場的紀錄");
            l.HorizontalAlignment = HorizontalAlignment.Left;
            foot.Children.Add(l);
        }
        bottom.Children.Add(foot);
        Grid.SetRow(bottom, 4);
        grid.Children.Add(bottom);
        return grid;
    }

    FrameworkElement BriefField()
    {
        var p = new StackPanel { Margin = new Thickness(0, 0, 0, Neu.SM) };
        var ph = m.Scene == 2 ? "這篇要講什麼？（可不填；第一行會變成標題）" : m.Scene == 1 ? "這場採訪的主題？（可不填；第一行會變成標題）" : "這場要談什麼？（可不填；第一行會變成標題）";
        var (field, box) = Neu.Field(ph, m.Brief, t => m.Brief = t, multiline: true, minLines: 1, maxLines: 4);
        briefBox = box;
        var row = new DockPanel { LastChildFill = true };
        var tip = Neu.InfoTip("可以不填。寫了的話，第一行會變成這份紀錄的標題，整理時也會特別留意跟它有關的內容。一行一件事。");
        tip.VerticalAlignment = VerticalAlignment.Top; tip.Margin = new Thickness(4, 8, 0, 0);
        DockPanel.SetDock(tip, Dock.Right);
        row.Children.Add(tip);
        row.Children.Add(field);
        p.Children.Add(row);
        foreach (var sug in m.SuggestedBrief.Take(3))
        {
            var line = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 4, 0, 0) };
            var c = Neu.Chip("帶入", () => { m.Brief += (m.Brief.Length == 0 ? "" : "\n") + sug; box.Text = m.Brief; });
            DockPanel.SetDock(c, Dock.Right);
            line.Children.Add(c);
            var t = Neu.Text("· " + sug, Neu.TCaption, Theme.InkMid, wrap: false); t.VerticalAlignment = VerticalAlignment.Center;
            line.Children.Add(t);
            p.Children.Add(line);
        }
        return p;
    }

    FrameworkElement ModelLine()
    {
        var p = new StackPanel { Margin = new Thickness(0, Neu.SM, 0, 0) };
        if (m.DownloadFraction is { } f)
        {
            var row = new DockPanel { LastChildFill = true };
            downloadPct = Neu.Text($"聽打模型 {f * 100:0}%", Neu.TMicro, Theme.InkMid, wrap: false);
            downloadPct.VerticalAlignment = VerticalAlignment.Center; downloadPct.Margin = new Thickness(Neu.SM, 0, 0, 0);
            DockPanel.SetDock(downloadPct, Dock.Right);
            row.Children.Add(downloadPct);
            var host = new Border();
            grooveHost = host;
            host.Child = downloadGroove = Neu.Groove(f, 8);
            row.Children.Add(host);
            p.Children.Add(row);
            if (m.DownloadNote.Length > 0) p.Children.Add(Neu.Note(m.DownloadNote));
        }
        else
        {
            var row = new DockPanel { LastChildFill = true };
            var c = Neu.Chip("下載", s.DownloadWhisper);
            DockPanel.SetDock(c, Dock.Right);
            row.Children.Add(c);
            var n = Neu.Note(m.DownloadNote.Length == 0 ? $"聽打模型還沒下載（約 {AppState.ModelSizeText}，一次就好）" : m.DownloadNote);
            n.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(n);
            p.Children.Add(row);
        }
        return p;
    }

    // ── recording ──
    FrameworkElement Recording()
    {
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var mid = new StackPanel();
        var mark = new MarkView(m.Paused ? MarkView.Mode.Idle : MarkView.Mode.Listening, 11) { HorizontalAlignment = HorizontalAlignment.Center };
        mid.Children.Add(mark);
        elapsed = new TextBlock
        {
            Text = m.ElapsedText, FontFamily = Neu.MarkFont, FontSize = 48, FontWeight = FontWeights.SemiBold,
            Foreground = m.Paused ? Theme.InkMid : Theme.InkStrong, HorizontalAlignment = HorizontalAlignment.Center,
        };
        System.Windows.Documents.Typography.SetNumeralAlignment(elapsed, FontNumeralAlignment.Tabular);
        mid.Children.Add(elapsed);
        statusLine = Neu.Text(StatusText(), Neu.TMicro, m.Paused ? Theme.InkStrong : Theme.InkSoft, semi: m.Paused, wrap: false, align: TextAlignment.Center);
        statusLine.HorizontalAlignment = HorizontalAlignment.Center;
        statusLine.ToolTip = m.Paused ? "暫停時麥克風沒有關，只是這段不存；按繼續就馬上接著錄，不用重新接裝置。" : null;
        mid.Children.Add(statusLine);
        var waves = new StackPanel { Margin = new Thickness(0, Neu.LG, 0, 0) };
        waves.Children.Add(WaveRow("麥克風", out micWave));
        micWave.Set(m.MicHistory, m.Paused);
        if (m.Online)
        {
            var r = WaveRow("電腦裡", out sysWave);
            r.Margin = new Thickness(0, Neu.SM, 0, 0);
            waves.Children.Add(r);
            sysWave.Set(m.SysHistory, m.Paused || !m.SysActive);
        }
        mid.Children.Add(waves);
        if (m.NoticeLine is { } n)
        {
            var t = Neu.Text(n, Neu.TCaption, Theme.InkMid, align: TextAlignment.Center);
            t.Margin = new Thickness(0, Neu.MD, 0, 0);
            mid.Children.Add(t);
        }
        foreach (var a in m.Alerts)
        {
            var t = Neu.Text(a, Neu.TCaption, Theme.InkStrong, semi: true, align: TextAlignment.Center);
            var card = Neu.Inset(t, Neu.RCard, 0.8, new Thickness(Neu.MD));
            card.Margin = new Thickness(0, Neu.MD, 0, 0);
            mid.Children.Add(card);
        }
        Grid.SetRow(mid, 1);
        grid.Children.Add(mid);

        var controls = new StackPanel();
        var row = new Grid { HorizontalAlignment = HorizontalAlignment.Center };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(72) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(72) });
        FrameworkElement side = m.Paused
            ? SideButton(Neu.IcStop, "停止並整理", "不錄了：現在就停止，接著自動整理", s.Stop)
            : SideButton(Neu.IcPause, "暫停", "中途休息時用：暫停的這段不會存，按「繼續」會接在同一份紀錄", s.Pause);
        Grid.SetColumn(side, 0);
        row.Children.Add(side);
        var anchor = m.Paused ? Neu.Anchor(false, s.Resume, 84, "繼續錄") : Neu.Anchor(true, s.Stop, 84, "停止並整理");
        Grid.SetColumn(anchor, 1);
        row.Children.Add(anchor);
        controls.Children.Add(row);
        var hint = Neu.Text(m.Paused ? "按一下繼續錄，接在同一份紀錄" : "按一下停止，接著會自動整理", Neu.TMicro, Theme.InkSoft, align: TextAlignment.Center);
        hint.HorizontalAlignment = HorizontalAlignment.Center;
        controls.Children.Add(hint);
        Grid.SetRow(controls, 3);
        grid.Children.Add(controls);
        return grid;
    }

    static FrameworkElement SideButton(string glyph, string title, string help, Action act)
    {
        var p = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, ToolTip = help };
        var b = Neu.IconButton(glyph, act, 44, name: title);
        b.HorizontalAlignment = HorizontalAlignment.Center;
        p.Children.Add(b);
        var t = Neu.Text(title, Neu.TMicro, Theme.InkMid, wrap: false, align: TextAlignment.Center);
        t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(0, 4, 0, 0);
        p.Children.Add(t);
        return p;
    }

    static FrameworkElement WaveRow(string label, out Waveform wave)
    {
        var d = new DockPanel { LastChildFill = true };
        var l = Neu.Text(label, Neu.TMicro, Theme.InkSoft, wrap: false);
        l.Width = 44; l.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(l, Dock.Left);
        d.Children.Add(l);
        wave = new Waveform { Height = 22, Margin = new Thickness(Neu.SM, 3, Neu.SM, 3) };
        var inset = Neu.Inset(wave, Neu.RPill, 0.8);
        d.Children.Add(inset);
        return d;
    }

    // ── processing ──
    static readonly string[] Stages = ["聽打", "清理", "整理", "存檔"];
    int CurrentStage
    {
        get
        {
            var t = m.StageText;
            if (t.Contains("存檔")) return 3;
            if (t.Contains("整理") && !t.Contains("補整理")) return 2;
            if (t.Contains("壓製") || t.Contains("逐字稿版")) return 1;
            return 0;
        }
    }

    FrameworkElement Processing()
    {
        var p = new StackPanel();
        int cur = CurrentStage;
        for (int i = 0; i < Stages.Length; i++) p.Children.Add(Neu.StageRow(Stages[i], i < cur, i == cur));
        if (m.StageText.Length > 0) { stageNote = Neu.Note(m.StageText); stageNote.Margin = new Thickness(0, 0, 0, Neu.SM); p.Children.Add(stageNote); }
        if (m.Partial.Length > 0)
        {
            var t = Neu.Text(m.Partial, Neu.TMicro, Theme.InkMid);
            t.MaxHeight = 110;
            var box = Neu.Inset(t, Neu.RCard, 0.8, new Thickness(Neu.MD));
            box.Margin = new Thickness(0, 0, 0, Neu.SM);
            p.Children.Add(box);
        }
        p.Children.Add(Neu.Note("整理中不要闔上筆電：闔上就暫停，打開才會繼續。可以先關掉這個面板去做別的事，整理好會跳通知。"));
        return Neu.Scroll(p);
    }

    // ── done ──
    FrameworkElement Done()
    {
        var (dateText, human) = MeetingIndex.Split(m.DoneTitle);
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var p = new StackPanel();
        var head = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, Neu.LG) };
        var mark = new MarkView(MarkView.Mode.Flash, 12) { VerticalAlignment = VerticalAlignment.Top };
        DockPanel.SetDock(mark, Dock.Left);
        head.Children.Add(mark);
        var titles = new StackPanel { Margin = new Thickness(Neu.SM, 2, 0, 0) };
        titles.Children.Add(Neu.Text(human.Length == 0 ? (m.DoneTitle.Length == 0 ? "整理好了" : m.DoneTitle) : human, Neu.TTitle, Theme.InkStrong, semi: true));
        titles.Children.Add(Neu.Text(dateText.Length == 0 ? "整理好了" : $"整理好了　{dateText}", Neu.TMicro, Theme.InkSoft));
        head.Children.Add(titles);
        p.Children.Add(head);
        if (m.DoneLines.Count > 0)
        {
            var lines = new StackPanel();
            foreach (var l in m.DoneLines) { var t = Neu.Text("· " + l, Neu.TBody, Theme.InkStrong); t.Margin = new Thickness(0, 0, 0, 6); lines.Children.Add(t); }
            var card = Neu.Inset(lines, Neu.RCard, 0.9, new Thickness(Neu.LG, Neu.LG, Neu.LG, Neu.LG - 6));
            card.Margin = new Thickness(0, 0, 0, Neu.LG);
            p.Children.Add(card);
        }
        if (m.DoneNote.Length > 0) { var n = Neu.Note(m.DoneNote); n.Margin = new Thickness(0, 0, 0, Neu.MD); p.Children.Add(n); }
        if (m.DoneMD is { } md)
        {
            p.Children.Add(Neu.Capsule("打開這份紀錄", () => Gui.OpenRecord(md), 44));
            var row = new UniformGrid2(m.ClaudeReady ? 2 : 1);
            row.Add(Neu.Capsule("存成 PDF／Word", () => Gui.OpenExport(md), 40));
            if (m.ClaudeReady) row.Add(Neu.Capsule("接著跟 Claude 討論", () => { if (!Exporters.ContinueWithClaude(md)) Gui.Toast("打不開 Claude：到設定那列確認 Claude Code 裝好、登入了"); }, 40));
            row.View.Margin = new Thickness(0, Neu.XS, 0, 0);
            p.Children.Add(row.View);
        }
        grid.Children.Add(Neu.Scroll(p));
        var back = Neu.Link("回到待命", s.Dismiss);
        back.HorizontalAlignment = HorizontalAlignment.Center;
        Grid.SetRow(back, 1);
        grid.Children.Add(back);
        return grid;
    }

    // ── error ──
    FrameworkElement ErrorView()
    {
        var p = new StackPanel();
        var t = Neu.Text("有個問題", Neu.TTitle, Theme.InkStrong, semi: true);
        t.Margin = new Thickness(0, 0, 0, Neu.MD);
        p.Children.Add(t);
        var box = Neu.Inset(Neu.Text(m.ErrorText, Neu.TBody, Theme.InkStrong), Neu.RCard, 0.9, new Thickness(Neu.LG));
        box.Margin = new Thickness(0, 0, 0, Neu.MD);
        p.Children.Add(box);
        if (m.ErrorText.Contains("麥克風"))
            p.Children.Add(Neu.Capsule("打開 Windows 的麥克風設定", () => Exporters.Open("ms-settings:privacy-microphone"), 40));
        p.Children.Add(Neu.Capsule("我知道了", s.Dismiss, 40));
        return Neu.Scroll(p);
    }
}

/// Equal-width columns for a row of capsules
public sealed class UniformGrid2
{
    public readonly Grid View = new();
    int n;
    public UniformGrid2(int columns) { for (int i = 0; i < columns; i++) View.ColumnDefinitions.Add(new ColumnDefinition()); }
    public void Add(FrameworkElement e) { Grid.SetColumn(e, n++); View.Children.Add(e); }
}
