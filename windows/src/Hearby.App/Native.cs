// Native — the few Win32 calls the shell needs.
using System.Runtime.InteropServices;

namespace Hearby.App;

static partial class Native
{
    // ── Traditional Chinese (LCMapStringEx) ──
    public const uint LCMAP_TRADITIONAL_CHINESE = 0x04000000;

    [LibraryImport("kernel32.dll", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    public static partial int LCMapStringEx(string lpLocaleName, uint dwMapFlags, string lpSrcStr, int cchSrc,
        [Out] char[]? lpDestStr, int cchDest, IntPtr lpVersionInformation, IntPtr lpReserved, IntPtr sortHandle);

    // ── keep awake ──
    public const uint ES_CONTINUOUS = 0x80000000, ES_SYSTEM_REQUIRED = 0x00000001;

    [LibraryImport("kernel32.dll")]
    public static partial uint SetThreadExecutionState(uint esFlags);

    // ── floating bar: not shown in screen sharing (Windows 10 2004+; older versions show a black box) ──
    public const uint WDA_NONE = 0, WDA_EXCLUDEFROMCAPTURE = 0x11;

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);

    // ── console for command-line use (the app is a GUI program) ──
    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool AttachConsole(int dwProcessId);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool FreeConsole();

    // ── recycle bin (SHFileOperation, FOF_ALLOWUNDO) ──
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEOPSTRUCT
    {
        public IntPtr hwnd;
        public uint wFunc;
        [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
        [MarshalAs(UnmanagedType.LPWStr)] public string? pTo;
        public ushort fFlags;
        [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpszProgressTitle;
    }
    public const uint FO_DELETE = 3;
    public const ushort FOF_SILENT = 0x4, FOF_NOCONFIRMATION = 0x10, FOF_ALLOWUNDO = 0x40, FOF_NOERRORUI = 0x400;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHFileOperation(ref SHFILEOPSTRUCT lpFileOp);

    // ── CPU topology: performance cores (Intel hybrid: P-cores have the highest EfficiencyClass) ──
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetLogicalProcessorInformationEx(int relationshipType, IntPtr buffer, ref uint returnedLength);

    // ── window flash / foreground ──
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetForegroundWindow(IntPtr hWnd);
}
