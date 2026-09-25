// Neu — the soft-relief material on Windows (mirrors Sources/HearbyUI/Neu.swift).
//
// The whole interface is one material: panel and background share a colour and shapes come only from two shadows (light from
// the top left: a highlight up-left, a shadow down-right). Raised = can be pressed; debossed = a container or the selected one.
// Ink in three steps, no colour in the interface itself; at most one "in progress" mark per screen. System fonts only
// (Microsoft JhengHei UI / Segoe UI; no font files are shipped).
// Views are built in code and rebuilt when the theme changes (Theme.Changed), so every colour is read at build time.
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using Microsoft.Win32;

namespace Hearby.App.UI;

public static class Theme
{
    public static bool Dark { get; private set; }
    public static event Action? Changed;
    static string mode = "system";
    static bool initialized;

    /// system / light / dark
    public static void Apply(string m) { mode = m; Refresh(force: true); }

    public static void Refresh(bool force = false)
    {
        bool d = mode == "dark" || (mode == "system" && SystemPrefersDark());
        if (initialized && !force && d == Dark) return;
        bool changed = !initialized || d != Dark;
        initialized = true;
        Dark = d;
        if (changed || force) Changed?.Invoke();
    }

    static int? PersonalizeValue(string name)
    {
        try { return Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")?.GetValue(name) as int?; }
        catch { return null; }
    }
    public static bool SystemPrefersDark() => PersonalizeValue("AppsUseLightTheme") == 0;
    /// Taskbar colour (for the tray icon): light taskbar = dark glyph
    public static bool TaskbarLight() => PersonalizeValue("SystemUsesLightTheme") == 1;

    static Color C(uint rgb) => Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
    static SolidColorBrush B(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }

    public static Color MaterialColor => Dark ? C(0x2B2D33) : C(0xEEEFF2);
    public static Color StageColor => Dark ? C(0x1E1F23) : C(0xE7E8EC);
    public static Color LightColor => Dark ? C(0x3E4149) : C(0xFFFFFF);
    public static Color ShadeColor => Dark ? C(0x0E0F12) : C(0xA3A6AF);
    public static Color InkStrongColor => Dark ? C(0xE8E9EC) : C(0x282A2F);
    public static Color InkMidColor => Dark ? C(0xA6A8B0) : C(0x73767E);
    public static Color InkSoftColor => Dark ? C(0x8E9099) : C(0xA2A5AD);
    public static Color KeyFaceColor => Dark ? C(0x35383F) : C(0xE0E2E6);
    public static Color KeyFaceDeepColor => Dark ? C(0x2A2C32) : C(0xD3D6DB);

    public static Brush Material => B(MaterialColor);
    public static Brush Stage => B(StageColor);
    public static Brush InkStrong => B(InkStrongColor);
    public static Brush InkMid => B(InkMidColor);
    public static Brush InkSoft => B(InkSoftColor);
    public static Brush Alpha(Color c, double a) => B(Color.FromArgb((byte)Math.Round(Math.Clamp(a, 0, 1) * 255), c.R, c.G, c.B));
}

/// A button whose whole look is its content; pressed / hover states are handed to the owner (keyboard + screen readers
/// come with Button)
public class PressButton : Button
{
    static readonly ControlTemplate Bare = MakeTemplate();
    static ControlTemplate MakeTemplate()
    {
        var t = new ControlTemplate(typeof(Button)) { VisualTree = new FrameworkElementFactory(typeof(ContentPresenter)) };
        t.Seal();
        return t;
    }
    public Action<bool, bool>? Visual;   // (hover, pressed)

    public PressButton()
    {
        Template = Bare;
        Cursor = Cursors.Hand;
        FocusVisualStyle = null;
        Background = Brushes.Transparent;
        MouseEnter += (_, _) => Visual?.Invoke(true, IsPressed);
        MouseLeave += (_, _) => Visual?.Invoke(false, false);
    }
    protected override void OnIsPressedChanged(DependencyPropertyChangedEventArgs e)
    {
        base.OnIsPressedChanged(e);
        Visual?.Invoke(IsMouseOver, IsPressed);
    }
}

public static class Neu
{
    // 4 pt grid (same numbers as Neu.swift; WPF units are 1/96 inch like macOS points)
    public const double XS = 4, SM = 8, MD = 12, LG = 16, XL = 24, Hero = 32, Edge = 24;
    public const double THero = 28, TTimer = 40, TTitle = 18, TBody = 14, TCaption = 12.5, TMicro = 11;
    public const double RPanel = 22, RCard = 18, RPill = 999;

    public static readonly FontFamily UIFont = new("Microsoft JhengHei UI, Segoe UI");
    public static readonly FontFamily MarkFont = new("Segoe UI Variable Display, Segoe UI Semibold, Segoe UI");
    public static readonly FontFamily IconFont = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    // Segoe MDL2 / Fluent icon glyphs (both fonts share these code points)
    public const string IcSettings = "", IcLibrary = "", IcHistory = "", IcImport = "", IcDownload = "",
        IcFolder = "", IcBack = "", IcNext = "", IcCheck = "", IcCancel = "", IcEdit = "",
        IcRefresh = "", IcGlobe = "", IcDoc = "", IcChat = "", IcHelp = "", IcPause = "",
        IcPlay = "", IcStop = "", IcMinimize = "", IcMaximize = "", IcRestore = "", IcClose = "",
        IcMic = "", IcWand = "", IcHealth = "", IcColor = "", IcFont = "", IcMore = "",
        IcList = "", IcPerson = "", IcWave = "", IcText = "", IcMemory = "", IcShield = "",
        IcUpdate = "", IcSearch = "", IcQuote = "", IcLink = "";

    // ── text ──

    public static TextBlock Text(string s, double size, Brush? ink = null, bool semi = false, bool wrap = true, TextAlignment align = TextAlignment.Left)
    {
        var t = new TextBlock
        {
            Text = s, FontSize = size, FontFamily = UIFont, Foreground = ink ?? Theme.InkStrong,
            FontWeight = semi ? FontWeights.SemiBold : FontWeights.Normal,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, TextAlignment = align,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        };
        TextOptions.SetTextFormattingMode(t, TextFormattingMode.Display);
        return t;
    }

    /// One line of explanation (micro, mid ink)
    public static TextBlock Note(string s) => Text(s, TMicro, Theme.InkMid);

    public static TextBlock Icon(string glyph, double size, Brush? ink = null) => new()
    {
        Text = glyph, FontFamily = IconFont, FontSize = size, Foreground = ink ?? Theme.InkMid,
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
    };

    // ── material ──

    static void RoundClip(FrameworkElement fe, double r)
    {
        void Update()
        {
            double w = fe.ActualWidth, h = fe.ActualHeight;
            if (w <= 0 || h <= 0) return;
            double rr = Math.Min(r, Math.Min(w, h) / 2);
            fe.Clip = new RectangleGeometry(new Rect(0, 0, w, h), rr, rr);
        }
        fe.SizeChanged += (_, _) => Update();
    }

    /// Debossed: pressed into the material (containers, the selected one, grooves). Inner shadow = a blurred ring outside the
    /// shape, shifted, clipped to the shape.
    public static Grid Inset(UIElement? child, double radius = RCard, double depth = 1, Thickness? padding = null)
    {
        var g = new Grid();
        g.Children.Add(new Border { Background = Theme.Material, CornerRadius = new CornerRadius(radius) });
        Border Ring(Color c, double alpha, double dx) => new()
        {
            BorderBrush = Theme.Alpha(c, alpha), BorderThickness = new Thickness(7), CornerRadius = new CornerRadius(radius + 7),
            Margin = new Thickness(-7), IsHitTestVisible = false,
            RenderTransform = new TranslateTransform(dx, dx), Effect = new BlurEffect { Radius = 7 * depth, KernelType = KernelType.Gaussian },
        };
        g.Children.Add(Ring(Theme.ShadeColor, (Theme.Dark ? 0.9 : 0.42) * depth, 2.5 * depth));
        g.Children.Add(Ring(Theme.LightColor, 0.95 * depth, -2.5 * depth));
        if (child != null)
        {
            var holder = new Border { Padding = padding ?? new Thickness(0), Child = child };
            g.Children.Add(holder);
        }
        RoundClip(g, radius);
        return g;
    }

    /// Raised: pressed out of the material (can be pressed). Returns the container and a setter for the pressed state.
    public static (Grid View, Action<bool, bool> SetState) Raised(UIElement? child, double radius = RCard, double lift = 1, Thickness? padding = null)
    {
        var g = new Grid();
        var lightFx = new DropShadowEffect { Color = Theme.LightColor, Direction = 135, ShadowDepth = 2.4 * lift, BlurRadius = 7 * lift, Opacity = 0.9 };
        var shadeFx = new DropShadowEffect { Color = Theme.ShadeColor, Direction = 315, ShadowDepth = 4 * lift, BlurRadius = 9 * lift, Opacity = Theme.Dark ? 0.8 : 0.45 };
        g.Children.Add(new Border { Background = Theme.Material, CornerRadius = new CornerRadius(radius), Effect = lightFx, IsHitTestVisible = false });
        g.Children.Add(new Border { Background = Theme.Material, CornerRadius = new CornerRadius(radius), Effect = shadeFx, IsHitTestVisible = false });
        var face = new Border { Background = Theme.Material, CornerRadius = new CornerRadius(radius), Padding = padding ?? new Thickness(0), Child = child };
        g.Children.Add(face);
        var scale = new ScaleTransform(1, 1);
        g.RenderTransform = scale;
        g.RenderTransformOrigin = new Point(0.5, 0.5);
        double lightBase = lightFx.Opacity, shadeBase = shadeFx.Opacity;
        void Set(bool hover, bool pressed)
        {
            lightFx.Opacity = pressed ? 0.35 : lightBase;
            shadeFx.Opacity = pressed ? shadeBase * 0.4 : shadeBase;
            scale.ScaleX = scale.ScaleY = pressed ? 0.985 : 1;
            face.Background = hover && !pressed ? Theme.Alpha(Blend(Theme.MaterialColor, Theme.LightColor, 0.25), 1) : Theme.Material;
        }
        return (g, Set);
    }

    static Color Blend(Color a, Color b, double t) => Color.FromRgb((byte)(a.R + (b.R - a.R) * t), (byte)(a.G + (b.G - a.G) * t), (byte)(a.B + (b.B - a.B) * t));

    // ── buttons ──

    static PressButton Wrap(FrameworkElement look, Action<bool, bool> set, Action onClick, bool enabled, string? tip, string? name)
    {
        var b = new PressButton { Content = look, IsEnabled = enabled, Visual = set };
        b.Click += (_, _) => onClick();
        if (tip != null) b.ToolTip = tip;
        if (name != null) AutomationProperties.SetName(b, name);
        if (!enabled) b.Cursor = Cursors.Arrow;
        return b;
    }

    /// Small pill (optionally with an icon)
    public static PressButton Chip(string title, Action onClick, string? icon = null, bool enabled = true, string? tip = null)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        var ink = enabled ? Theme.InkStrong : Theme.InkSoft;
        if (icon != null) { var i = Icon(icon, 12, ink); i.Margin = new Thickness(0, 0, 6, 0); row.Children.Add(i); }
        row.Children.Add(Text(title, TCaption, ink, wrap: false));
        var (view, set) = Raised(row, RPill, 0.6, new Thickness(MD, 0, MD, 0));
        view.Height = 34;
        view.Margin = new Thickness(2, 3, 5, 6);
        return Wrap(view, set, onClick, enabled, tip, title);
    }

    /// Wide capsule (main action of a page)
    public static PressButton Capsule(string title, Action onClick, double height = 46, bool enabled = true, string? tip = null)
    {
        var t = Text(title, TBody, enabled ? Theme.InkStrong : Theme.InkSoft, wrap: false, align: TextAlignment.Center);
        t.HorizontalAlignment = HorizontalAlignment.Center;
        t.VerticalAlignment = VerticalAlignment.Center;
        var (view, set) = Raised(t, RPill, 0.85, new Thickness(LG, 0, LG, 0));
        view.Height = height;
        view.Margin = new Thickness(2, 3, 5, 7);
        return Wrap(view, set, onClick, enabled, tip, title);
    }

    /// Small round icon button; on = a switched-on toggle (debossed, strong ink)
    public static PressButton IconButton(string glyph, Action onClick, double size = 22, string? tip = null, bool on = false, string? name = null)
    {
        var icon = Icon(glyph, size * 0.42, on ? Theme.InkStrong : Theme.InkMid);
        FrameworkElement view;
        Action<bool, bool> set;
        if (on)
        {
            view = Inset(icon, size / 2, 0.7);
            set = (h, p) => icon.Foreground = Theme.InkStrong;
        }
        else
        {
            var (v, s) = Raised(icon, size / 2, 0.45);
            view = v;
            set = (h, p) => { s(h, p); icon.Foreground = h || p ? Theme.InkStrong : Theme.InkMid; };
        }
        view.Width = size; view.Height = size;
        view.Margin = new Thickness(2);
        return Wrap(view, set, onClick, true, tip, name ?? tip);
    }

    /// The deep charcoal round button: the only high-contrast element, only for the recording action (dot = record, square = stop)
    public static PressButton Anchor(bool square, Action onClick, double size = 92, string? name = null)
    {
        var g = new Grid { Width = size + 30, Height = size + 30 };
        var outer = new Ellipse { Width = size + 18, Height = size + 18, Fill = Theme.Material };
        var outerLight = new DropShadowEffect { Color = Theme.LightColor, Direction = 135, ShadowDepth = 5, BlurRadius = 12, Opacity = 0.95 };
        var outer2 = new Ellipse { Width = size + 18, Height = size + 18, Fill = Theme.Material, Effect = new DropShadowEffect { Color = Theme.ShadeColor, Direction = 315, ShadowDepth = 6, BlurRadius = 14, Opacity = Theme.Dark ? 0.85 : 0.5 } };
        outer.Effect = outerLight;
        g.Children.Add(outer2);
        g.Children.Add(outer);
        var face = new Ellipse
        {
            Width = size, Height = size,
            Fill = new LinearGradientBrush(Theme.KeyFaceColor, Theme.KeyFaceDeepColor, new Point(0, 0), new Point(1, 1)),
            Stroke = new LinearGradientBrush(Color.FromArgb(217, Theme.LightColor.R, Theme.LightColor.G, Theme.LightColor.B), Color.FromArgb(115, Theme.ShadeColor.R, Theme.ShadeColor.G, Theme.ShadeColor.B), new Point(0, 0), new Point(1, 1)),
            StrokeThickness = 1,
            Effect = new DropShadowEffect { Color = Theme.ShadeColor, Direction = 300, ShadowDepth = 3, BlurRadius = 8, Opacity = 0.38 },
        };
        g.Children.Add(face);
        FrameworkElement glyph = square
            ? new Rectangle { Width = size * 0.195, Height = size * 0.195, RadiusX = size * 0.055, RadiusY = size * 0.055, Fill = Theme.InkStrong }
            : new Ellipse { Width = size * 0.125, Height = size * 0.125, Fill = Theme.InkStrong };
        g.Children.Add(glyph);
        var scale = new ScaleTransform(1, 1);
        g.RenderTransform = scale;
        g.RenderTransformOrigin = new Point(0.5, 0.5);
        void Set(bool hover, bool pressed)
        {
            double s = pressed ? 0.975 : hover ? 1.012 : 1;
            scale.ScaleX = scale.ScaleY = s;
            outerLight.Opacity = pressed ? 0.4 : 0.95;
        }
        return Wrap(g, Set, onClick, true, null, name ?? (square ? "停止" : "開始錄音"));
    }

    // ── other pieces ──

    /// Segmented choice: the whole strip is debossed, the chosen part raised
    public static FrameworkElement Segmented(IReadOnlyList<string> items, int selected, Action<int> onSelect, IReadOnlyList<string>? icons = null, double height = 40)
    {
        var grid = new Grid { Height = height - 8, Margin = new Thickness(4) };
        for (int i = 0; i < items.Count; i++) grid.ColumnDefinitions.Add(new ColumnDefinition());
        for (int i = 0; i < items.Count; i++)
        {
            int idx = i;
            bool on = i == selected;
            var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            var ink = on ? Theme.InkStrong : Theme.InkMid;
            if (icons != null && i < icons.Count) { var ic = Icon(icons[i], 11, ink); ic.Margin = new Thickness(0, 0, 5, 0); row.Children.Add(ic); }
            row.Children.Add(Text(items[i], TCaption, ink, semi: on, wrap: false));
            FrameworkElement cell;
            if (on)
            {
                var (v, _) = Raised(row, RPill, 0.5);
                cell = v;
            }
            else cell = new Border { Background = Brushes.Transparent, Child = row };
            var b = new PressButton { Content = cell };
            AutomationProperties.SetName(b, items[i]);
            b.Click += (_, _) => onSelect(idx);
            Grid.SetColumn(b, i);
            grid.Children.Add(b);
        }
        var inset = Inset(grid, RPill, 0.85);
        inset.Height = height;
        return inset;
    }

    /// Groove: volume and progress. fill 0…1; null = indeterminate (a piece drifting back and forth)
    public static FrameworkElement Groove(double? fill, double height = 16)
    {
        var track = new Grid { Height = height };
        double inner = Math.Max(2, height - 7);
        var (knob, _) = Raised(null, RPill, 0.35);
        knob.Height = inner;
        knob.HorizontalAlignment = HorizontalAlignment.Left;
        knob.VerticalAlignment = VerticalAlignment.Center;
        knob.Margin = new Thickness(3.5, 0, 0, 0);
        track.Children.Add(knob);
        var tt = new TranslateTransform();
        knob.RenderTransform = tt;
        track.SizeChanged += (_, _) =>
        {
            double w = track.ActualWidth;
            knob.Width = Math.Max(inner, w * Math.Clamp(fill ?? 0.32, 0.04, 1) - 7);
        };
        if (fill == null && SystemParameters.ClientAreaAnimation)
        {
            track.Loaded += (_, _) =>
            {
                var a = new System.Windows.Media.Animation.DoubleAnimation(0, Math.Max(0, track.ActualWidth * 0.62), TimeSpan.FromSeconds(2.2))
                { AutoReverse = true, RepeatBehavior = System.Windows.Media.Animation.RepeatBehavior.Forever, EasingFunction = new System.Windows.Media.Animation.SineEase() };
                tt.BeginAnimation(TranslateTransform.XProperty, a);
            };
            track.Unloaded += (_, _) => tt.BeginAnimation(TranslateTransform.XProperty, null);
        }
        var inset = Inset(track, RPill, 0.9);
        inset.Height = height;
        return inset;
    }

    /// Status tag (ink only): ready = solid dark dot, pending = mid, missing = hollow
    public enum Level { Ready, Pending, Missing }
    public static FrameworkElement StatusTag(Level level, string text)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        var dot = new Ellipse
        {
            Width = 7, Height = 7, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center,
            Fill = level == Level.Ready ? Theme.InkStrong : level == Level.Pending ? Theme.InkMid : Brushes.Transparent,
            Stroke = level == Level.Missing ? Theme.InkSoft : null, StrokeThickness = 1,
        };
        row.Children.Add(dot);
        var t = Text(text, TMicro, level == Level.Missing ? Theme.InkSoft : Theme.InkMid);
        t.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(t);
        return row;
    }

    /// A stage of the processing list: done = tick and paler; active = the breathing mark
    public static FrameworkElement StageRow(string title, bool done, bool active)
    {
        var d = new DockPanel { LastChildFill = true, Margin = new Thickness(LG, 0, LG, 0) };
        FrameworkElement right = done ? Icon(IcCheck, 12, Theme.InkStrong) : active ? new MarkView(MarkView.Mode.Listening, 9) : new Border();
        DockPanel.SetDock(right, Dock.Right);
        d.Children.Add(right);
        var t = Text(title, TBody, done ? Theme.InkSoft : Theme.InkStrong, semi: active, wrap: false);
        t.VerticalAlignment = VerticalAlignment.Center;
        d.Children.Add(t);
        var inset = Inset(d, RPill, done ? 0.7 : 0.95);
        inset.Height = 42;
        inset.Margin = new Thickness(0, 0, 0, SM);
        return inset;
    }

    /// Text input inside a debossed field, with a placeholder
    public static (FrameworkElement View, TextBox Box) Field(string placeholder, string text, Action<string>? onChange = null, bool multiline = false, double radius = RPill, int minLines = 1, int maxLines = 4)
    {
        var box = new TextBox
        {
            Text = text, FontFamily = UIFont, FontSize = TBody, Foreground = Theme.InkStrong, Background = Brushes.Transparent,
            BorderThickness = new Thickness(0), CaretBrush = Theme.InkStrong, VerticalContentAlignment = VerticalAlignment.Center,
            AcceptsReturn = multiline, TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
            SelectionBrush = Theme.InkMid, Padding = new Thickness(0),
        };
        if (multiline)
        {
            box.MinLines = minLines; box.MaxLines = maxLines;
            box.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
            box.VerticalContentAlignment = VerticalAlignment.Top;
        }
        AutomationProperties.SetName(box, placeholder);
        var hint = Text(placeholder, TBody, Theme.InkSoft, wrap: multiline);
        hint.IsHitTestVisible = false;
        hint.Margin = new Thickness(2, multiline ? 1 : 0, 0, 0);
        hint.VerticalAlignment = multiline ? VerticalAlignment.Top : VerticalAlignment.Center;
        hint.Visibility = string.IsNullOrEmpty(text) ? Visibility.Visible : Visibility.Collapsed;
        box.TextChanged += (_, _) =>
        {
            hint.Visibility = string.IsNullOrEmpty(box.Text) ? Visibility.Visible : Visibility.Collapsed;
            onChange?.Invoke(box.Text);
        };
        var g = new Grid();
        g.Children.Add(hint);
        g.Children.Add(box);
        var inset = Inset(g, multiline ? RCard : radius, 0.9, multiline ? new Thickness(MD, SM, MD, SM) : new Thickness(MD, 0, MD, 0));
        if (!multiline) inset.Height = 34;
        return (inset, box);
    }

    /// ⓘ: click for a plain-language explanation
    public static FrameworkElement InfoTip(string text)
    {
        var icon = Icon(IcHelp, 12, Theme.InkMid);
        var b = new PressButton { Content = new Border { Background = Brushes.Transparent, Padding = new Thickness(3), Child = icon } };
        AutomationProperties.SetName(b, "說明");
        var body = Text(text, TBody, Theme.InkStrong);
        body.Width = 300;
        var card = new Border
        {
            Background = Theme.Material, CornerRadius = new CornerRadius(12), Padding = new Thickness(LG), Child = body,
            BorderBrush = Theme.Alpha(Theme.ShadeColor, 0.35), BorderThickness = new Thickness(1),
            Effect = new DropShadowEffect { Color = Colors.Black, Opacity = 0.18, BlurRadius = 16, ShadowDepth = 4, Direction = 290 },
            Margin = new Thickness(8, 4, 12, 16),
        };
        var pop = new Popup { Child = card, PlacementTarget = b, Placement = PlacementMode.Bottom, StaysOpen = false, AllowsTransparency = true, PopupAnimation = PopupAnimation.Fade };
        b.Click += (_, _) => pop.IsOpen = !pop.IsOpen;
        return b;
    }

    /// A settings / wizard card: debossed, icon + title + ⓘ, then content
    public static FrameworkElement Section(string title, string icon, string? tip, params UIElement[] content)
    {
        var s = new StackPanel();
        var head = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, MD) };
        var ic = Icon(icon, 13, Theme.InkMid); ic.Width = 18; ic.Margin = new Thickness(0, 0, 8, 0);
        head.Children.Add(ic);
        var t = Text(title, TBody, Theme.InkStrong, semi: true, wrap: false); t.VerticalAlignment = VerticalAlignment.Center;
        head.Children.Add(t);
        if (tip != null) { var it = InfoTip(tip); it.Margin = new Thickness(4, 0, 0, 0); head.Children.Add(it); }
        s.Children.Add(head);
        foreach (var c in content) s.Children.Add(c);
        var inset = Inset(s, RCard, 0.7, new Thickness(LG));
        inset.Margin = new Thickness(0, 0, 0, MD);
        return inset;
    }

    /// Horizontal row with spacing
    public static StackPanel Row(double spacing, params UIElement[] items)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal };
        for (int i = 0; i < items.Length; i++)
        {
            if (items[i] is FrameworkElement fe && i < items.Length - 1) fe.Margin = new Thickness(fe.Margin.Left, fe.Margin.Top, fe.Margin.Right + spacing, fe.Margin.Bottom);
            if (items[i] is FrameworkElement f2) f2.VerticalAlignment = VerticalAlignment.Center;
            p.Children.Add(items[i]);
        }
        return p;
    }

    /// Wrapping row: items fold onto the next line when they do not fit (never truncated, never squeezed)
    public static WrapPanel Flow(params UIElement[] items)
    {
        var p = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var i in items) p.Children.Add(i);
        return p;
    }

    public static StackPanel Stack(double spacing, params UIElement[] items)
    {
        var p = new StackPanel();
        foreach (var i in items)
        {
            if (i is FrameworkElement fe) fe.Margin = new Thickness(fe.Margin.Left, fe.Margin.Top, fe.Margin.Right, fe.Margin.Bottom + spacing);
            p.Children.Add(i);
        }
        return p;
    }

    /// Clickable plain text (secondary actions like 「回到待命」)
    public static PressButton Link(string text, Action onClick, double size = TCaption, string? icon = null, string? tip = null)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        var t = Text(text, size, Theme.InkMid, wrap: false);
        if (icon != null) { var i = Icon(icon, 11, Theme.InkMid); i.Margin = new Thickness(0, 0, 6, 0); row.Children.Add(i); }
        row.Children.Add(t);
        var b = new PressButton { Content = new Border { Background = Brushes.Transparent, Padding = new Thickness(2, 4, 2, 4), Child = row } };
        b.Visual = (h, p) => t.TextDecorations = h ? TextDecorations.Underline : null;
        b.Click += (_, _) => onClick();
        if (tip != null) b.ToolTip = tip;
        AutomationProperties.SetName(b, text);
        return b;
    }

    /// Scroll area without visible chrome until needed
    public static ScrollViewer Scroll(UIElement content) => new()
    {
        Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Focusable = false, Padding = new Thickness(0, 2, 6, 2),
    };
}

/// Waveform: the last 40 volume readings as thin bars (a track that never moves = something is wrong)
public sealed class Waveform : FrameworkElement
{
    public int Slots { get; init; } = 40;
    float[] levels = [];
    bool dim;
    public void Set(IReadOnlyList<float> l, bool dimmed)
    {
        levels = [.. l];
        dim = dimmed;
        InvalidateVisual();
    }
    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight;
        if (w <= 0 || h <= 0) return;
        var brush = dim ? Theme.InkSoft : Theme.InkStrong;
        double slot = w / Slots, bar = Math.Max(1.5, slot * 0.55);
        for (int i = 0; i < Slots; i++)
        {
            int idx = i - (Slots - levels.Length);
            double v = idx >= 0 && idx < levels.Length ? levels[idx] : 0;
            double bh = Math.Max(2, h * Math.Min(1, v * 1.4));
            double x = i * slot + (slot - bar) / 2, y = (h - bh) / 2;
            dc.DrawRoundedRectangle(brush, null, new Rect(x, y, bar, bh), bar / 2, bar / 2);
        }
    }
}
