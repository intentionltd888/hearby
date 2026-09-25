// Program — Hearby.exe: the transcription child process, installer hooks, command line, then the app itself
// (tray icon + panel + records window + set-up wizard; no main window of its own). Mirrors HearbyApp/main.swift.
using Hearby.Core;
using Velopack;

namespace Hearby.App;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        // The transcription child: nothing else starts (no installer hooks, no windows)
        if (args.Length > 0 && args[0] == "--transcribe-worker") return WhisperWorker.Run(args);
        try
        {
            // Install / update / uninstall hooks of the installer (Velopack): run and exit when called with its arguments
            // A downloaded update is NOT applied here: this may be a second launch while the first Hearby is recording.
            // Gui applies it once it knows no other Hearby is running (Updates.ApplyPendingAtLaunch), or at quit.
            VelopackApp.Build()
                .SetAutoApplyOnStartup(false)
                .OnFirstRun(v => HearbyLog.Write($"first run after install {v}"))
                .Run();
        }
        catch (Exception e) { HearbyLog.Write($"installer hook: {e.Message}"); }
        WinPlatform.Install();
        if (Cli.Dispatch(args) is { } code) return code;
        return Gui.Run();
    }
}
