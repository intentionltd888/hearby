// FloatingBar — while recording with the panel closed: a small bar that stays on top (mirrors Panel/FloatingBar.swift):
// recording or paused, the time, is the microphone hearing anything, pause and stop. Drag it anywhere; it never takes the
// keyboard away from the meeting app, and it asks Windows to leave it out of screen sharing and recordings
// (SetWindowDisplayAffinity WDA_EXCLUDEFROMCAPTURE, Windows 10 2004 or later).
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Hearby.Core;

namespace Hearby.App.UI;

public sealed class FloatingBar : Window
{
    readonly PanelModel m = AppState.Shared.Panel;
    TextBlock? time, state;
    Waveform? meter;
    bool builtPaused;
    static Point? lastPos;

    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    public FloatingBar()
    {
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        Width = 250; Height = 52;
        Title = "Hearby 錄音中";
        FontFamily = Neu.UIFont;
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            const int GWL_EXSTYLE = -20, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x80;
            SetWindowLong(hwnd, GWL_EXSTYLE, GetWindowLong(hwnd, GWL_EXSTYLE) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
            try { int round = 2; DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int)); } catch { }
            try { Native.SetWindowDisplayAffinity(hwnd, Native.WDA_EXCLUDEFROMCAPTURE); } catch { }
        };
        MouseLeftButtonDown += (_, e) => { if (e.ButtonState == MouseButtonState.Pressed) { try { DragMove(); lastPos = new Point(Left, Top); } catch { } } };
        m.Ticked += Tick;
        m.Changed += () => { if (IsVisible && builtPaused != m.Paused) Build(); };
        Theme.Changed += Build;
        Build();
    }

    public void ShowBar()
    {
        if (IsVisible) return;
        if (lastPos is { } p) { Left = p.X; Top = p.Y; }
        else
        {
            var wa = SystemParameters.WorkArea;
            Left = wa.Left + (wa.Width - Width) / 2;
            Top = wa.Top + 10;
        }
        Build();
        Show();
    }

    public void HideBar() { if (IsVisible) Hide(); }

    void Build()
    {
        builtPaused = m.Paused;
        Background = Theme.Material;
        var root = new DockPanel { LastChildFill = true, Margin = new Thickness(Neu.MD, 0, Neu.SM, 0) };
        var buttons = Neu.Row(2,
            Neu.IconButton(m.Paused ? Neu.IcPlay : Neu.IcPause, () => { if (m.Paused) AppState.Shared.Resume(); else AppState.Shared.Pause(); }, 30, m.Paused ? "繼續錄（接在同一份紀錄）" : "暫停（這段不會存）"),
            Neu.IconButton(Neu.IcStop, AppState.Shared.Stop, 30, "停止並整理"));
        DockPanel.SetDock(buttons, Dock.Right);
        root.Children.Add(buttons);

        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        FrameworkElement sign = m.Paused ? Neu.Icon(Neu.IcPause, 10, Theme.InkMid) : new MarkView(MarkView.Mode.Listening, 7);
        sign.Width = 18; sign.Height = 18;
        left.Children.Add(sign);
        var texts = new StackPanel { Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        state = Neu.Text(m.Paused ? "已暫停・不會存" : "錄音中", 9.5, m.Paused ? Theme.InkStrong : Theme.InkSoft, wrap: false);
        time = new TextBlock { Text = m.ElapsedText, FontFamily = Neu.MarkFont, FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = m.Paused ? Theme.InkMid : Theme.InkStrong };
        System.Windows.Documents.Typography.SetNumeralAlignment(time, FontNumeralAlignment.Tabular);
        texts.Children.Add(state);
        texts.Children.Add(time);
        left.Children.Add(texts);
        var open = new PressButton { Content = new Border { Background = Brushes.Transparent, Child = left }, ToolTip = "打開 Hearby 面板" };
        open.Click += (_, _) => Gui.ShowPanel();
        DockPanel.SetDock(open, Dock.Left);
        root.Children.Add(open);
        meter = new Waveform { Slots = 6, Width = 30, Height = 16, Margin = new Thickness(Neu.SM, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, ToolTip = "麥克風：有在動＝有收到聲音" };
        meter.Set(m.MicHistory.Skip(Math.Max(0, m.MicHistory.Count - 6)).ToList(), m.Paused);
        root.Children.Add(meter);
        Content = new Border
        {
            Background = Theme.Material, BorderBrush = Theme.Alpha(Theme.ShadeColor, 0.35), BorderThickness = new Thickness(1),
            Child = root,
        };
    }

    void Tick()
    {
        if (!IsVisible) return;
        if (time != null) time.Text = m.ElapsedText;
        meter?.Set(m.MicHistory.Skip(Math.Max(0, m.MicHistory.Count - 6)).ToList(), m.Paused);
    }
}
