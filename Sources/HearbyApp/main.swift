// main — Hearby 殼：CLI 分派 → NSApplication（選單列圖示＋浮動面板＋紀錄視窗＋精靈），沒有 Dock 圖示
import AppKit
import HearbyCore
import HearbyUI
import SwiftUI
import UserNotifications

if let code = Cli.dispatch(CommandLine.arguments) { exit(code) }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBar!
    var mainWindow: NSWindow?
    var wizardWindow: NSWindow?
    var pdfObserver: NSObjectProtocol?
    var themeObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 從磁碟映像直接雙擊＝自己裝：問一次 → 複製到 /Applications → 釘 Dock → 從那裡重開
        if Installer.isRunningFromDiskImage {
            // 防呆：同一版已經裝好了，卻又從映像（或被系統搬移的路徑）開起來——不要再問一次，直接開裝好的那顆
            if Installer.sameBuildAlreadyInstalled, !CommandLine.arguments.contains("--install") {
                HearbyLog.write("same build already in /Applications → open that one")
                let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
                NSWorkspace.shared.openApplication(at: Installer.installedURL, configuration: cfg) { _, _ in DispatchQueue.main.async { exit(0) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
                return
            }
            Installer.offerInstallFromDiskImage(autoYes: CommandLine.arguments.contains("--install"))
            return
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--eject"), i + 1 < args.count { Installer.ejectLater(args[i + 1]) }
        if Installer.isRunningFromApplications, !UserDefaults.standard.bool(forKey: "dockPinned") {
            UserDefaults.standard.set(true, forKey: "dockPinned")
            Dock.ensure(appURL: Installer.installedURL)
        }
        AppearanceMode.apply(AppearanceMode.current)
        do { let made = try Paths.ensure(); if !made.isEmpty { HearbyLog.write("建了資料夾：\(made.map(\.path).joined(separator: ", "))") } }
        catch { HearbyLog.write("建資料夾失敗：\(error)") }
        HearbyLog.write("launch \(HearbyVersion.version) build \(HearbyVersion.build)")
        Clean.seedGlossary()
        EntryFiles.ensure()
        if ConfigStore.shared.current.memoryEnabled { try? MemoryStore.ensure() }
        DispatchQueue.global(qos: .utility).async { _ = Providers.autoPick(); Pipeline.retentionSweep() }

        statusBar = StatusBar()
        statusBar.onOpenWindow = { [weak self] in self?.openMain() }
        statusBar.onWizard = { [weak self] in self?.openWizard() }
        let state = AppState.shared
        state.openWindow = { [weak self] in self?.openMain() }
        state.showWizard = { [weak self] in self?.openWizard() }
        state.onPhase = { [weak self] p in self?.statusBar.setPhase(p) }
        state.showPanel = { [weak self] in self?.statusBar.showPanel() }
        state.presentExport = { [weak self] md in self?.openExport(md) }

        pdfObserver = NotificationCenter.default.addObserver(forName: .hearbyWantsPDF, object: nil, queue: .main) { n in
            if let u = n.object as? URL { Exporters.pdf(mdURL: u, header: nil) { _ in } }
        }
        themeObserver = Theme.shared.$mode.sink { [weak self] _ in DispatchQueue.main.async { self?.recolorWindows() } }
        if !ConfigStore.shared.current.wizardDone { openWizard() } else { statusBar.showPanel() }

        // 測試鉤（TESTING.md「怎麼驗」）：HEARBY_AUTOIMPORT=<檔> 啟動後走跟「匯入音檔」按鈕同一條路
        //（狀態機、面板、轉檔、管線都經過，只差沒有選檔視窗）；HEARBY_AUTOQUIT=1 到「剛完成／出事」就結束並回傳 0／1。
        let env = ProcessInfo.processInfo.environment
        if let f = env["HEARBY_AUTOIMPORT"], !f.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AppState.shared.importMedia(URL(fileURLWithPath: f)) }
        }
    }

    /// 視窗底色跟主題走（標題列透明＋內容延伸，AppKit 的底色要自己塗）
    func recolorWindows() {
        mainWindow?.backgroundColor = Neu.stageNSColor
        wizardWindow?.backgroundColor = Neu.stageNSColor
        exportWindow?.backgroundColor = Neu.materialNSColor
        statusBar.recolor()
    }

    func openMain() {
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Hearby"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.backgroundColor = Neu.stageNSColor
            w.contentView = NSHostingView(rootView: MainWindow(actions: AppState.shared.windowActions()).padding(.top, 22))
            w.minSize = NSSize(width: 700, height: 540)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("HearbyMain")
            w.center()
            mainWindow = w
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 精靈開著的期間讓 app 出現在 Dock 與 ⌘Tab（沒有 Dock 圖示的 app 第一次打開時，對方常以為「沒反應」）；精靈關掉就回選單列常駐
    private func dockVisible(_ on: Bool) {
        NSApp.setActivationPolicy(on ? .regular : .accessory)
        if on { NSApp.activate(ignoringOtherApps: true) }
    }
    private var wizardCloseObserver: NSObjectProtocol?

    func openWizard() {
        HearbyLog.write("wizard open")
        if let w = wizardWindow { dockVisible(true); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = WizardView(
            onFinish: { [weak self] in self?.wizardWindow?.close(); self?.wizardWindow = nil; AppState.shared.refreshIdle(); self?.statusBar.showPanel() },
            onDownloadModel: { AppState.shared.downloadWhisper() },
            panel: AppState.shared.panel)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Hearby"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = Neu.stageNSColor
        w.contentView = NSHostingView(rootView: view)
        w.center()
        w.isReleasedWhenClosed = false
        wizardWindow = w
        if let o = wizardCloseObserver { NotificationCenter.default.removeObserver(o) }
        wizardCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.dockVisible(false)
        }
        dockVisible(true)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        HearbyLog.write("wizard window shown frame=\(w.frame)")
    }

    var exportWindow: NSWindow?
    func openExport(_ md: URL) {
        let view = ExportSheet(mdURL: md, actions: AppState.shared.windowActions()) { [weak self] in self?.exportWindow?.close(); self?.exportWindow = nil }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "匯出"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = Neu.materialNSColor
        w.contentView = NSHostingView(rootView: view.padding(.top, 22))
        w.center(); w.isReleasedWhenClosed = false
        exportWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 已經在跑（選單列裡）時使用者又去 Applications 點兩下：沒有 Dock 圖示的 app 預設什麼都不會發生，
    /// 對方會以為「打不開」。這裡把該出現的東西叫出來：精靈沒走完→精靈；紀錄視窗開著→把它帶回前面；都沒有→面板。
    /// 視窗還開著就回視窗，不要疊面板上去：AI 在跑的時候人會切去別的 app 再點回來，
    /// 這時彈出待命面板會把文件蓋住，看起來像「跳掉」。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        HearbyLog.write("reopen visible=\(flag)")
        if !ConfigStore.shared.current.wizardDone { openWizard() }
        else if let w = mainWindow, w.isVisible { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { statusBar.showPanel(); NSApp.activate(ignoringOtherApps: true) }
        return false
    }

    /// 錄音中或整理中按 ⌘Q：先問一聲。錄到一半被關掉，錄音救得回來，但那場會就斷了
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let phase = AppState.shared.phase
        guard phase == .recording || phase == .processing else { return .terminateNow }
        let a = NSAlert()
        a.messageText = phase == .recording ? "正在錄音，確定要結束 Hearby 嗎？" : "正在整理這場紀錄，確定要結束 Hearby 嗎？"
        a.informativeText = phase == .recording
            ? "結束會停止錄音。已經錄到的部分不會不見，下次打開可以按「補整理」。"
            : "結束會中斷整理。錄音還在，下次打開可以按「補整理」重跑。"
        a.addButton(withTitle: phase == .recording ? "繼續錄" : "繼續整理")
        a.addButton(withTitle: "結束 Hearby")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        HearbyLog.write("terminate phase=\(AppState.shared.phase.rawValue)")
        RunningChildren.terminateAll()   // 卡住的 AI 工具、跑到一半的 whisper 不留孤兒
    }

    /// 主選單「檔案 → 匯入音檔或影片…」（⌘O）：跟面板右下角那顆同一條路
    @objc func importMedia(_ sender: Any?) { AppState.shared.pickImport() }

    /// 主選單「設定…」（⌘,）：跟面板右上角那顆齒輪同一條路
    @objc func openSettings(_ sender: Any?) { openMain(); WindowNav.shared.tab = 1 }
}

// ── 主選單（⌘C／⌘V／⌘X／⌘A／⌘Z／⌘W／⌘Q 要有人接）──
// 選單列 app（LSUIElement）不會把選單畫出來，但鍵盤快捷鍵全靠 mainMenu 派送：
// 沒有「編輯」選單＝整個 app 任何輸入框都不能複製貼上；語音輸入法這類「放剪貼簿再送 ⌘V」的工具送進來的 ⌘V 也沒人接。
@MainActor func makeMainMenu() -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "關於 Hearby", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "設定…", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "隱藏 Hearby", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "結束 Hearby", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let fileItem = NSMenuItem()
    let file = NSMenu(title: "檔案")
    file.addItem(withTitle: "匯入音檔或影片…", action: #selector(AppDelegate.importMedia(_:)), keyEquivalent: "o")
    fileItem.submenu = file
    main.addItem(fileItem)

    let editItem = NSMenuItem()
    let edit = NSMenu(title: "編輯")
    let items: [(String, Selector, String)] = [
        ("復原", Selector(("undo:")), "z"),
        ("重做", Selector(("redo:")), "Z"),
        ("剪下", #selector(NSText.cut(_:)), "x"),
        ("拷貝", #selector(NSText.copy(_:)), "c"),
        ("貼上", #selector(NSText.paste(_:)), "v"),
        ("全選", #selector(NSText.selectAll(_:)), "a"),
    ]
    for (t, s, k) in items { edit.addItem(withTitle: t, action: s, keyEquivalent: k) }
    editItem.submenu = edit
    main.addItem(editItem)

    let windowItem = NSMenuItem()
    let window = NSMenu(title: "視窗")
    window.addItem(withTitle: "關閉視窗", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    window.addItem(withTitle: "縮到最小", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowItem.submenu = window
    main.addItem(windowItem)
    return main
}

// 被系統或終端機用 SIGTERM 結束時也要收子行程（這條路不會經過 applicationWillTerminate）
signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { RunningChildren.terminateAll(); exit(143) }
sigtermSource.resume()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
MainActor.assumeIsolated { app.mainMenu = makeMainMenu() }
app.run()
