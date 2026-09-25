// Tray — the notification-area icon (mirrors StatusBar.swift + MenuIcon.swift): left click = open/close the panel,
// right click = menu. Five looks drawn from the mark: idle / recording (a dot that blinks) / paused (two bars) /
// processing (hollow dot) / problem (!). Glyph colour follows the taskbar (light taskbar = dark glyph).
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Hearby.Core;
using WinForms = System.Windows.Forms;

namespace Hearby.App.UI;

public sealed class Tray : IDisposable
{
    readonly WinForms.NotifyIcon icon = new();
    readonly DispatcherTimer blinkTimer = new() { Interval = TimeSpan.FromMilliseconds(900) };
    readonly Dictionary<string, System.Drawing.Icon> cache = [];
    Phase phase = Phase.Idle;
    bool paused, blink = true;
    public Action OnToggle = () => { };
    public Action OnOpenPanel = () => { };
    public Action<int> OnOpenWindow = _ => { };
    public Action OnWizard = () => { };
    public Action OnQuit = () => { };

    public Tray()
    {
        icon.Text = "Hearby";
        icon.MouseUp += (_, e) => { if (e.Button == WinForms.MouseButtons.Left) OnToggle(); };
        icon.BalloonTipClicked += (_, _) => OnOpenPanel();
        blinkTimer.Tick += (_, _) => { if (phase == Phase.Recording && !paused) { blink = !blink; Refresh(); } };
        BuildMenu();
        Refresh();
        icon.Visible = true;
    }

    public void SetPhase(Phase p)
    {
        phase = p;
        blink = true;
        if (p == Phase.Recording) blinkTimer.Start(); else blinkTimer.Stop();
        BuildMenu();
        Refresh();
    }

    /// Timer text in the tooltip; the paused look (called every tick while recording, only redraws on change)
    public void SetRecording(string elapsed, bool isPaused)
    {
        if (isPaused != paused) { paused = isPaused; BuildMenu(); Refresh(); }
        var t = phase == Phase.Recording ? (paused ? $"Hearby：已暫停 {elapsed}（這段不會存）" : $"Hearby：錄音中 {elapsed}") : TooltipFor(phase);
        if (icon.Text != t) icon.Text = t.Length > 127 ? t[..127] : t;
    }

    static string TooltipFor(Phase p) => p switch
    {
        Phase.Processing => "Hearby：整理中…",
        Phase.Done => "Hearby：紀錄整理好了",
        Phase.Error => "Hearby：有個問題，點開看看",
        _ => "Hearby",
    };

    public void Refresh()
    {
        bool light = Theme.TaskbarLight();
        var key = $"{phase}-{paused}-{blink}-{light}-{WinForms.SystemInformation.SmallIconSize.Width}";
        if (!cache.TryGetValue(key, out var ic)) cache[key] = ic = Draw(phase, paused, blink, light);
        icon.Icon = ic;
        if (phase != Phase.Recording) icon.Text = TooltipFor(phase);
    }

    public void Notify(string title, string body)
    {
        try { icon.ShowBalloonTip(8000, title, body.Length > 200 ? body[..200] : body, WinForms.ToolTipIcon.None); } catch { }
    }

    void BuildMenu()
    {
        var m = new WinForms.ContextMenuStrip { ShowImageMargin = false };
        var st = AppState.Shared;
        if (phase == Phase.Recording)
        {
            m.Items.Add(paused ? "繼續錄" : "暫停（這段不會存）", null, (_, _) => { if (paused) st.Resume(); else st.Pause(); });
            m.Items.Add("停止並整理", null, (_, _) => st.Stop());
            m.Items.Add(new WinForms.ToolStripSeparator());
        }
        m.Items.Add("打開 Hearby 面板", null, (_, _) => OnOpenPanel());
        m.Items.Add("紀錄", null, (_, _) => OnOpenWindow(0));
        m.Items.Add("設定", null, (_, _) => OnOpenWindow(1));
        m.Items.Add("設定精靈", null, (_, _) => OnWizard());
        m.Items.Add(new WinForms.ToolStripSeparator());
        m.Items.Add("結束 Hearby", null, (_, _) => OnQuit());
        var old = icon.ContextMenuStrip;
        icon.ContextMenuStrip = m;
        old?.Dispose();
    }

    /// The mark + a state sign, drawn at the tray's icon size
    static System.Drawing.Icon Draw(Phase phase, bool paused, bool blink, bool lightTaskbar)
    {
        int px = Math.Max(16, WinForms.SystemInformation.SmallIconSize.Width);
        double s = px / 16.0;
        var ink = lightTaskbar ? Color.FromRgb(0x1A, 0x1A, 0x1A) : Color.FromRgb(0xFF, 0xFF, 0xFF);
        var brush = new SolidColorBrush(ink); brush.Freeze();
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            bool sign = phase != Phase.Idle;
            double markH = (sign ? 12.5 : 14) * s;
            double markW = markH * Brand.BoxWidth / Brand.BoxHeight;
            double x0 = sign ? 0.5 * s : (px - markW) / 2, y0 = (px - markH) / 2 - (sign ? 0.8 * s : 0);
            var g = Brand.Geometry.Clone();
            var tg = new TransformGroup();
            tg.Children.Add(new ScaleTransform(markW / Brand.BoxWidth, markH / Brand.BoxHeight));
            tg.Children.Add(new TranslateTransform(x0, y0));
            g.Transform = tg;
            dc.DrawGeometry(brush, null, g);
            double r = 2.6 * s, cx = px - r - 0.3 * s, cy = px - r - 0.3 * s;
            switch (phase)
            {
                case Phase.Recording when paused:
                    dc.DrawRectangle(brush, null, new Rect(px - 6.2 * s, px - 6.5 * s, 1.8 * s, 6 * s));
                    dc.DrawRectangle(brush, null, new Rect(px - 2.6 * s, px - 6.5 * s, 1.8 * s, 6 * s));
                    break;
                case Phase.Recording:
                    var b2 = new SolidColorBrush(Color.FromArgb((byte)(blink ? 255 : 90), ink.R, ink.G, ink.B)); b2.Freeze();
                    dc.DrawEllipse(b2, null, new Point(cx, cy), r, r);
                    break;
                case Phase.Processing:
                    dc.DrawEllipse(null, new Pen(brush, 1.1 * s), new Point(cx, cy), r - 0.5 * s, r - 0.5 * s);
                    break;
                case Phase.Done:
                    dc.DrawEllipse(brush, null, new Point(cx, cy), r, r);
                    break;
                case Phase.Error:
                    dc.DrawRectangle(brush, null, new Rect(px - 3.4 * s, px - 9 * s, 1.8 * s, 5.6 * s));
                    dc.DrawRectangle(brush, null, new Rect(px - 3.4 * s, px - 2.4 * s, 1.8 * s, 1.8 * s));
                    break;
            }
        }
        var rtb = new RenderTargetBitmap(px, px, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(dv);
        var pixels = new byte[px * px * 4];
        rtb.CopyPixels(pixels, px * 4, 0);
        using var bmp = new System.Drawing.Bitmap(px, px, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        var data = bmp.LockBits(new System.Drawing.Rectangle(0, 0, px, px), System.Drawing.Imaging.ImageLockMode.WriteOnly, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        System.Runtime.InteropServices.Marshal.Copy(pixels, 0, data.Scan0, pixels.Length);
        bmp.UnlockBits(data);
        var h = bmp.GetHicon();
        return System.Drawing.Icon.FromHandle(h);
    }

    public void Dispose()
    {
        blinkTimer.Stop();
        icon.Visible = false;
        icon.Dispose();
    }
}
