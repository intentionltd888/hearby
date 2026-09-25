// Gui — the app itself (mirrors HearbyApp/main.swift + StatusBar.swift): one instance per user; a tray icon, the panel,
// the floating bar while recording, the records window, the set-up wizard. No main window of its own: closing windows
// keeps Hearby running in the tray; 「結束 Hearby」 in the tray menu quits (asking first while recording or organising).
using System.Windows;
using System.Windows.Threading;
using Hearby.App.UI;
using Hearby.Core;
using Microsoft.Win32;

namespace Hearby.App;

static class Gui
{
    static Application? app;
    static Tray? tray;
    static PanelWindow? panel;
    static MainWindow? main;
    static WizardWindow? wizard;
    static FloatingBar? bar;
    static Dispatcher? ui;
    public static bool Quitting { get; private set; }
    const string InstanceName = @"Local\HearbyApp.Instance", ShowEventName = @"Local\HearbyApp.Show";

    public static void OnUi(Action a)
    {
        var d = ui ?? Application.Current?.Dispatcher;
        if (d == null || d.CheckAccess()) { a(); return; }
        d.BeginInvoke(a);
    }

    public static int Run()
    {
        using var mutex = new Mutex(true, InstanceName, out bool first);
        if (!first)
        {
            // already running (in the tray): bring the right thing forward there, and leave
            try { using var ev = EventWaitHandle.OpenExisting(ShowEventName); ev.Set(); } catch { }
            return 0;
        }
        // the only Hearby running: a downloaded update can go in now (nothing is being recorded)
        if (Updates.ApplyPendingAtLaunch()) return 0;
        using var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        ui = app.Dispatcher;
        var waiter = new Thread(() =>
        {
            while (true)
            {
                try { showEvent.WaitOne(); } catch { return; }
                OnUi(Reopen);
            }
        }) { IsBackground = true, Name = "hearby-show" };
        waiter.Start();
        app.DispatcherUnhandledException += (_, e) =>
        {
            HearbyLog.Write($"ui error: {e.Exception.GetType().Name} {e.Exception.Message}\n{e.Exception.StackTrace}");
            e.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) => HearbyLog.Write($"fatal: {e.ExceptionObject}");
        app.SessionEnding += (_, _) => { HearbyLog.Write("windows session ending"); PrepareForExit(); };
        app.Startup += (_, _) => Startup();
        int code = app.Run();
        tray?.Dispose();
        return code;
    }

    static void Startup()
    {
        try { var made = Paths.Ensure(); if (made.Count > 0) HearbyLog.Write($"建了資料夾：{string.Join(", ", made)}"); }
        catch (Exception e) { HearbyLog.Write($"建資料夾失敗：{e.Message}"); }
        HearbyLog.Write($"launch {HearbyVersion.Version} build {HearbyVersion.Build} (windows, core {HearbyVersion.CoreParity}) {Environment.OSVersion.VersionString} {System.Runtime.InteropServices.RuntimeInformation.OSArchitecture}");
        try { Clean.SeedGlossary(); } catch { }
        EntryFiles.Ensure();
        if (ConfigStore.Shared.Current.MemoryEnabled) { try { MemoryStore.Ensure(); } catch { } }
        Task.Run(() => { try { Providers.AutoPick(); Pipeline.RetentionSweep(); } catch (Exception e) { HearbyLog.Write($"startup chores: {e.Message}"); } });

        Theme.Apply(ConfigStore.Shared.Current.Appearance);
        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.Color or UserPreferenceCategory.VisualStyle)
                OnUi(() => { Theme.Refresh(); tray?.Refresh(); });
        };

        tray = new Tray
        {
            OnToggle = TogglePanel,
            OnOpenPanel = ShowPanel,
            OnOpenWindow = OpenWindow,
            OnWizard = OpenWizard,
            OnQuit = AskQuit,
        };
        var st = AppState.Shared;
        st.OpenWindowTab = OpenWindow;
        st.OpenRecord = OpenRecord;
        st.ShowPanel = ShowPanel;
        st.ShowWizard = OpenWizard;
        st.OnPhase = p => { tray?.SetPhase(p); PanelVisibilityChanged(); };
        st.Notify = (t, b) => tray?.Notify(t, b);
        st.PresentExport = OpenExport;
        st.Panel.Ticked += () => { if (st.Phase == Phase.Recording) tray?.SetRecording(st.Panel.ElapsedText, st.Panel.Paused); };
        st.Panel.Changed += () => { if (st.Phase == Phase.Recording) tray?.SetRecording(st.Panel.ElapsedText, st.Panel.Paused); };
        st.RefreshIdle();

        if (!ConfigStore.Shared.Current.WizardDone) OpenWizard(); else ShowPanel();
        Updates.CheckLater();

        // test hooks (TESTING.md): HEARBY_AUTOIMPORT=<file> takes the same road as 「匯入音檔」; HEARBY_UI_SCRIPT="start 3 hide 3
        // pause 4 resume 3 stop" drives the state machine like the panel buttons; HEARBY_AUTOQUIT=1 quits at done/error (exit 0/1)
        if (Environment.GetEnvironmentVariable("HEARBY_AUTOIMPORT") is { Length: > 0 } f)
            After(1, () => st.ImportMedia(f));
        if (Environment.GetEnvironmentVariable("HEARBY_UI_SCRIPT") is { Length: > 0 } script)
            After(1, () => UiScript(script.Split([' ', ','], StringSplitOptions.RemoveEmptyEntries), 0));
    }

    static void After(double seconds, Action a)
    {
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        t.Tick += (_, _) => { t.Stop(); a(); };
        t.Start();
    }

    static void UiScript(string[] steps, int i)
    {
        if (i >= steps.Length) { HearbyLog.Write("uiscript: done"); return; }
        var step = steps[i];
        if (double.TryParse(step, System.Globalization.CultureInfo.InvariantCulture, out var secs)) { After(secs, () => UiScript(steps, i + 1)); return; }
        var s = AppState.Shared;
        HearbyLog.Write($"uiscript: {step} phase={s.Phase} paused={s.Panel.Paused} elapsed={s.Panel.ElapsedText}");
        switch (step)
        {
            case "start": s.Start(); break;
            case "pause": s.Pause(); break;
            case "resume": s.Resume(); break;
            case "stop": s.Stop(); break;
            case "hide": HidePanel(); break;
            case "show": ShowPanel(); break;
            case "online": s.Panel.Online = true; s.Panel.RaiseChanged(); break;
            case "room": s.Panel.Online = false; s.Panel.RaiseChanged(); break;
            case "records": OpenWindow(0); break;
            case "settings": OpenWindow(1); break;
            case "status": OpenWindow(2); break;
            case "wizard": OpenWizard(); break;
            case "screenshot": Screenshot(); break;
            case "dark": Theme.Apply("dark"); break;
            case "light": Theme.Apply("light"); break;
            case "wstep0" or "wstep1" or "wstep2" or "wstep3" or "wstep4": OpenWizard(); wizard?.GoTo(step[^1] - '0'); break;
            case "export": if (AppState.Shared.Panel.LastMeeting?.MdPath is { } lm) OpenExport(lm); break;
            case "claudelogin": ClaudeLogin.Shared.Start(); OpenWindow(1); break;
            case "claudecancel": ClaudeLogin.Shared.Cancel(); break;
            case "updatecheck": Updates.CheckNow(); break;
            case "updateapply": Updates.ApplyNow(); break;
            case "lastrecord": if (AppState.Shared.Panel.LastMeeting?.MdPath is { } lr) OpenRecord(lr); break;
            case "quit": Quit(0); break;
            default: HearbyLog.Write($"uiscript: 不認得的步驟 {step}"); break;
        }
        OnUi(() => UiScript(steps, i + 1));
    }

    /// Test aid: every visible Hearby window as a PNG in the logs folder (layout review in the test machine)
    static void Screenshot()
    {
        foreach (Window w in Application.Current.Windows)
        {
            if (!w.IsVisible || w.Content is not FrameworkElement fe || fe.ActualWidth < 1) continue;
            try
            {
                var dpi = System.Windows.Media.VisualTreeHelper.GetDpi(w);
                var rtb = new System.Windows.Media.Imaging.RenderTargetBitmap((int)(fe.ActualWidth * dpi.DpiScaleX), (int)(fe.ActualHeight * dpi.DpiScaleY), 96 * dpi.DpiScaleX, 96 * dpi.DpiScaleY, System.Windows.Media.PixelFormats.Pbgra32);
                rtb.Render(fe);
                var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
                enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(rtb));
                var path = Path.Combine(Paths.Logs, $"shot-{w.GetType().Name}-{DateTime.Now:HHmmss}.png");
                using var fs = File.Create(path);
                enc.Save(fs);
                HearbyLog.Write($"uiscript: screenshot {path}");
            }
            catch (Exception e) { HearbyLog.Write($"uiscript: screenshot fail {e.Message}"); }
        }
    }

    /// Hearby started again while already running: show what should be seen (wizard not finished → wizard;
    /// records window open → bring it forward; otherwise the panel)
    static void Reopen()
    {
        HearbyLog.Write("reopen");
        if (!ConfigStore.Shared.Current.WizardDone) OpenWizard();
        else if (main is { IsVisible: true }) Activate(main);
        else ShowPanel();
    }

    static void Activate(Window w)
    {
        if (!w.IsVisible) w.Show();
        if (w.WindowState == WindowState.Minimized) w.WindowState = WindowState.Normal;
        w.Activate();
        w.Topmost = true; w.Topmost = w is PanelWindow;   // come to the front even when another app has focus
        w.Focus();
    }

    // ── panel & floating bar ──

    static PanelWindow EnsurePanel()
    {
        if (panel != null) return panel;
        panel = new PanelWindow { Topmost = true };
        var wa = SystemParameters.WorkArea;
        panel.Left = wa.Right - panel.Width - 16;
        panel.Top = wa.Bottom - panel.Height - 16;
        panel.IsVisibleChanged += (_, _) => PanelVisibilityChanged();
        return panel;
    }

    public static void ShowPanel()
    {
        var p = EnsurePanel();
        Activate(p);
        PanelVisibilityChanged();
    }

    public static void HidePanel()
    {
        panel?.Hide();
        PanelVisibilityChanged();
    }

    static void TogglePanel()
    {
        if (panel is { IsVisible: true } && panel.WindowState != WindowState.Minimized) HidePanel();
        else ShowPanel();
    }

    /// Floating bar: recording + panel not open + setting on
    public static void PanelVisibilityChanged()
    {
        bool panelOpen = panel is { IsVisible: true } && panel.WindowState != WindowState.Minimized;
        bool want = AppState.Shared.Phase == Phase.Recording && !panelOpen && ConfigStore.Shared.Current.FloatingBarOn;
        if (want) (bar ??= new FloatingBar()).ShowBar();
        else bar?.HideBar();
    }

    // ── windows ──

    public static void OpenWindow(int tab)
    {
        main ??= new MainWindow();
        main.ShowTab(tab);
        TuckPanel();
        Activate(main);
    }

    public static void OpenRecord(string md)
    {
        main ??= new MainWindow();
        main.OpenRecord(md);
        TuckPanel();
        Activate(main);
    }

    /// Going to the records window: the panel (always on top) steps aside instead of covering it; while recording the
    /// floating bar takes over. The tray icon brings it back.
    static void TuckPanel()
    {
        if (panel is { IsVisible: true }) HidePanel();
    }

    public static void RefreshSettings() { if (main is { IsVisible: true }) main.Rebuild(); }

    public static void OpenWizard()
    {
        HearbyLog.Write("wizard open");
        if (wizard != null) { Activate(wizard); return; }
        wizard = new WizardWindow();
        wizard.OnFinish = () =>
        {
            wizard?.Close();
            AppState.Shared.RefreshIdle();
            ShowPanel();
        };
        wizard.Closed += (_, _) => wizard = null;
        Activate(wizard);
    }

    public static void OpenExport(string md)
    {
        var w = new ExportWindow(md);
        Activate(w);
    }

    /// A short message where the user will see it (tray notification)
    public static void Toast(string text) => tray?.Notify("Hearby", text);

    // ── quitting ──

    static void AskQuit()
    {
        var phase = AppState.Shared.Phase;
        if (phase is Phase.Recording or Phase.Processing)
        {
            var msg = phase == Phase.Recording
                ? "正在錄音，確定要結束 Hearby 嗎？\n\n結束會停止錄音。已經錄到的部分不會不見，下次打開可以按「補整理」。"
                : "正在整理這場紀錄，確定要結束 Hearby 嗎？\n\n結束會中斷整理。錄音還在，下次打開可以按「補整理」重跑。";
            var r = MessageBox.Show(msg, "Hearby", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
            if (r != MessageBoxResult.Yes) return;
        }
        Quit(0);
    }

    public static void PrepareForExit()
    {
        if (Quitting) return;
        Quitting = true;
        AppState.Shared.Shutdown();
        tray?.Dispose();
    }

    public static void Quit(int code)
    {
        PrepareForExit();
        if (!Updates.ApplyingNow) Updates.ApplyPendingAtExit();
        app?.Shutdown(code);
    }
}
