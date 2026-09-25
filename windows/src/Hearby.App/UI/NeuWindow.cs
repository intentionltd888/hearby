// NeuWindow — a window made of the material: our own title strip (drag anywhere on it, Windows snap still works), the
// caption buttons drawn as Neu icon buttons, rounded corners on Windows 11. Views rebuild themselves when the theme changes.
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shell;

namespace Hearby.App.UI;

public abstract class NeuWindow : Window
{
    readonly Border frame = new();
    protected bool Stage;   // background: stage (records window, wizard) or material (panel)
    public bool HideOnClose;

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    /// Design size; fixed-layout windows (wizard, export) are scaled down as a whole when the screen is smaller
    readonly double designWidth, designHeight;
    protected bool ScaleToFit;
    double scale = 1;

    protected NeuWindow(double width, double height, bool resizable, bool stage)
    {
        Stage = stage;
        designWidth = width; designHeight = height;
        Width = width; Height = height;
        Title = "Hearby";
        FontFamily = Neu.UIFont;
        UseLayoutRounding = true;
        SnapsToDevicePixels = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        try { Icon = BitmapFrame.Create(new Uri("pack://application:,,,/Hearby;component/Assets/hearby.ico", UriKind.Absolute)); } catch { }
        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = 34, ResizeBorderThickness = resizable ? new Thickness(6) : new Thickness(0),
            GlassFrameThickness = new Thickness(0), CornerRadius = new CornerRadius(0), UseAeroCaptionButtons = false,
        });
        ResizeMode = resizable ? ResizeMode.CanResize : ResizeMode.CanMinimize;
        Content = frame;
        SourceInitialized += (_, _) =>
        {
            try
            {
                var hwnd = new WindowInteropHelper(this).Handle;
                int round = 2; // DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND (Windows 11; ignored on 10)
                DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));
            }
            catch { }
        };
        StateChanged += (_, _) => frame.Padding = WindowState == WindowState.Maximized ? new Thickness(7) : new Thickness(0);
        Theme.Changed += OnTheme;
        Closed += (_, _) => Theme.Changed -= OnTheme;
        Closing += (_, e) => { if (HideOnClose && !Gui.Quitting) { e.Cancel = true; Hide(); OnHidden(); } };
    }

    void OnTheme() { Paint(); Rebuild(); }

    protected virtual void OnHidden() { }

    void Paint()
    {
        var bg = Stage ? Theme.Stage : Theme.Material;
        Background = bg;
        frame.Background = bg;
    }

    /// Build the whole content (called at start and on theme change)
    protected abstract UIElement BuildContent();

    /// Keep the window on the screen: resizable windows shrink to the work area, fixed ones scale as a whole.
    /// (HEARBY_UI_NOFIT=1 keeps design sizes: layout review in a small test screen, see TESTING.md)
    protected void FitToScreen()
    {
        if (Environment.GetEnvironmentVariable("HEARBY_UI_NOFIT") == "1") return;
        var wa = SystemParameters.WorkArea;
        double maxW = Math.Max(300, wa.Width - 16), maxH = Math.Max(300, wa.Height - 16);
        if (ScaleToFit)
        {
            scale = Math.Min(1, Math.Min(maxW / designWidth, maxH / designHeight));
            Width = designWidth * scale; Height = designHeight * scale;
        }
        else
        {
            if (MinWidth > maxW) MinWidth = maxW;
            if (MinHeight > maxH) MinHeight = maxH;
            if (Width > maxW) Width = maxW;
            if (Height > maxH) Height = maxH;
        }
    }

    public void Rebuild()
    {
        Paint();
        var content = BuildContent();
        if (ScaleToFit && scale < 1 && content is FrameworkElement fe)
        {
            fe.Width = designWidth; fe.Height = designHeight;
            frame.Child = new Viewbox { Stretch = Stretch.Uniform, Child = fe };
        }
        else frame.Child = content;
    }

    /// Caption buttons (minimise, close); they must take clicks inside the title strip
    protected FrameworkElement CaptionButtons(bool minimize = true, bool maximize = false)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        void Add(FrameworkElement b) { WindowChrome.SetIsHitTestVisibleInChrome(b, true); b.Margin = new Thickness(4, 0, 0, 0); row.Children.Add(b); }
        if (minimize) Add(Neu.IconButton(Neu.IcMinimize, () => WindowState = WindowState.Minimized, 24, "縮到最小"));
        if (maximize) Add(Neu.IconButton(WindowState == WindowState.Maximized ? Neu.IcRestore : Neu.IcMaximize, () => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized, 24, "放大"));
        Add(Neu.IconButton(Neu.IcClose, Close, 24, "關閉"));
        return row;
    }

    /// Anything placed in the title strip that should be clickable
    protected static T Clickable<T>(T e) where T : FrameworkElement { WindowChrome.SetIsHitTestVisibleInChrome(e, true); return e; }
}
