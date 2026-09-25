// Updates — new versions from this project's GitHub releases (Velopack). A minute after start and then twice a day:
// check, download in the background, and tell the user; the new version is put in place the next time Hearby starts, or
// right away with 「現在更新」 (never while recording or organising). Sends nothing but ordinary web requests to GitHub.
using System.Windows.Threading;
using Hearby.Core;
using Velopack;
using Velopack.Sources;

namespace Hearby.App;

static class Updates
{
    const string Repo = "https://github.com/intentionltd888/hearby";
    static UpdateManager? mgr;
    static UpdateInfo? pending;
    static bool checking;
    static DispatcherTimer? timer;
    public static bool Ready => pending != null;
    public static bool ApplyingNow { get; private set; }
    public static string StatusLine { get; private set; } = "還沒檢查";

    static UpdateManager? Manager()
    {
        // HEARBY_UPDATE_FEED=<folder or URL> points at a local release folder instead of GitHub (testing an update, TESTING.md)
        try
        {
            var feed = Environment.GetEnvironmentVariable("HEARBY_UPDATE_FEED");
            return mgr ??= string.IsNullOrEmpty(feed) ? new UpdateManager(new GithubSource(Repo, null, false)) : new UpdateManager(feed);
        }
        catch (Exception e) { HearbyLog.Write($"update manager: {e.Message}"); return null; }
    }

    public static void CheckLater()
    {
        timer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
        timer.Tick += (_, _) =>
        {
            timer.Interval = TimeSpan.FromHours(12);
            if (ConfigStore.Shared.Current.AutoUpdateOn) CheckNow();
        };
        timer.Start();
    }

    public static void CheckNow()
    {
        if (checking) return;
        checking = true;
        Task.Run(async () =>
        {
            try
            {
                var m = Manager();
                if (m == null || !m.IsInstalled) { StatusLine = "這份不是用安裝檔裝的（開發版），不檢查更新"; return; }
                if (m.UpdatePendingRestart is { } ready) { SetReady(null, ready.Version.ToString()); return; }
                var info = await m.CheckForUpdatesAsync();
                if (info == null) { StatusLine = $"已經是最新版（{HearbyVersion.Version}，{DateTime.Now:HH:mm} 檢查）"; return; }
                var ver = info.TargetFullRelease.Version.ToString();
                StatusLine = $"下載新版 {ver} 中…";
                Gui.OnUi(Refresh);
                await m.DownloadUpdatesAsync(info);
                SetReady(info, ver);
                HearbyLog.Write($"update {ver} downloaded");
            }
            catch (Exception e)
            {
                StatusLine = "這次沒查到（可能沒網路），晚點會再試";
                HearbyLog.Write($"update check fail: {e.GetType().Name} {e.Message}");
            }
            finally
            {
                checking = false;
                Gui.OnUi(Refresh);
            }
        });
    }

    static void SetReady(UpdateInfo? info, string ver)
    {
        pending = info;
        readyVersion = ver;
        StatusLine = $"新版 {ver} 已下載好：下次打開 Hearby 就會換新，或按「現在更新」";
        Gui.OnUi(() => { AppState.Shared.Panel.UpdateReady = ver; AppState.Shared.Panel.RaiseChanged(); });
    }
    static string? readyVersion;

    static void Refresh() => Gui.RefreshSettings();

    /// First instance starting (no other Hearby running, nothing being recorded): put a downloaded update in place now.
    /// Returns true when the app is about to restart into the new version.
    public static bool ApplyPendingAtLaunch()
    {
        try
        {
            var m = Manager();
            if (m == null || !m.IsInstalled || m.UpdatePendingRestart is not { } asset) return false;
            HearbyLog.Write($"update apply at launch {asset.Version}");
            m.ApplyUpdatesAndRestart(asset);
            return true;
        }
        catch (Exception e) { HearbyLog.Write($"update apply at launch fail: {e.Message}"); return false; }
    }

    /// Quitting: a downloaded update goes in after this process has exited (no restart)
    public static void ApplyPendingAtExit()
    {
        try
        {
            var m = Manager();
            if (m == null || !m.IsInstalled) return;
            var asset = pending?.TargetFullRelease ?? m.UpdatePendingRestart;
            if (asset == null) return;
            HearbyLog.Write($"update apply at exit {asset.Version}");
            m.WaitExitThenApplyUpdates(asset, silent: true, restart: false);
        }
        catch (Exception e) { HearbyLog.Write($"update apply at exit fail: {e.Message}"); }
    }

    public static void ApplyNow()
    {
        if (AppState.Shared.Busy) { Gui.Toast("正在錄音或整理中：結束後再按「現在更新」"); return; }
        var m = Manager();
        var asset = pending?.TargetFullRelease ?? m?.UpdatePendingRestart;
        if (m == null || asset == null) { Gui.Toast("還沒有下載好的新版"); return; }
        HearbyLog.Write($"update apply {readyVersion}");
        ApplyingNow = true;
        Gui.PrepareForExit();
        m.ApplyUpdatesAndRestart(asset);
    }
}
