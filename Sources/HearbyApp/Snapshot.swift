// Snapshot — 離線把每個畫面畫成 PNG（設計檢視用）：面板四態＋出事、精靈五頁、紀錄視窗三分頁、匯出表單
import AppKit
import HearbyCore
import HearbyUI
import SwiftUI

enum Snapshot {
    static func run(into dir: URL, dark: Bool) -> Int32 { MainActor.assumeIsolated { runMain(into: dir, dark: dark) } }
    @MainActor static func runMain(into dir: URL, dark: Bool) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        Theme.shared.mode = dark ? .dark : .light
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var n = 0
        func shoot<V: View>(_ name: String, _ v: V, size: NSSize) {
            let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height).background(Neu.material))
            host.appearance = app.appearance
            host.frame = NSRect(origin: .zero, size: size)
            // 放進一個離屏視窗，SwiftUI 才會真的做 layout
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            w.appearance = app.appearance
            w.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
                n += 1
            }
            w.orderOut(nil)
        }
        let panelSize = NSSize(width: 340, height: 560)
        // 面板：五態（假資料）
        let m = PanelModel()
        m.modelReady = true
        m.lastMeeting = MeetingIndex.scan().first
        shoot("panel-idle", PanelView(model: m).padding(.top, 22), size: panelSize)
        m.phase = .recording
        m.online = true; m.sysActive = true
        m.elapsedText = "12:34"
        m.micHistory = (0..<40).map { Float(0.15 + 0.5 * abs(sin(Double($0) / 3))) }
        m.sysHistory = (0..<40).map { Float(0.1 + 0.3 * abs(cos(Double($0) / 4))) }
        m.noticeLine = "錄音中不要闔上筆電，闔上就沒有聲音了"
        shoot("panel-recording", PanelView(model: m).padding(.top, 22), size: panelSize)
        m.phase = .processing
        m.stageText = "聽打房間裡（麥克風） 2/5・約剩 3分10秒"
        m.partial = "[00:12] 那我們今天先把上次的預算表看一下\n[00:20] 好，Kevin 你先講\n[00:31] 第一季的數字已經對過了"
        shoot("panel-processing", PanelView(model: m).padding(.top, 22), size: panelSize)
        m.phase = .done
        m.doneTitle = "2026-09-13_2110_第三季預算"
        m.doneLines = ["第一季數字已對過，第二季預算下修一成", "行銷案改由 Kevin 負責，月底前給草案", "下週三再開一次確認"]
        m.doneMD = URL(fileURLWithPath: "/tmp/x.md")
        m.claudeReady = true
        shoot("panel-done", PanelView(model: m).padding(.top, 22), size: panelSize)
        m.phase = .error
        m.errorText = "麥克風權限未授權：系統設定 → 隱私權與安全性 → 麥克風 → 開啟 Hearby"
        shoot("panel-error", PanelView(model: m).padding(.top, 22), size: panelSize)
        // 精靈五頁
        for step in 0...4 {
            try? ConfigStore.shared.update { $0.wizardStep = step }
            shoot("wizard-\(step)", WizardView(onFinish: {}, onDownloadModel: {}, panel: m), size: NSSize(width: 480, height: 640))
        }
        try? ConfigStore.shared.update { $0.wizardStep = 0 }
        // 紀錄視窗
        let actions = AppState.shared.windowActions()
        let winSize = NSSize(width: 840, height: 660)
        shoot("window", MainWindow(actions: actions).padding(.top, 22), size: winSize)
        shoot("window-settings", MainWindow(actions: actions, initialTab: 1).padding(.top, 22), size: winSize)
        shoot("window-check", MainWindow(actions: actions, initialTab: 2).padding(.top, 22), size: winSize)
        if let md = MeetingIndex.scan().first(where: { $0.mdURL != nil })?.mdURL {
            WindowNav.shared.openRecord = md
            shoot("window-detail", MainWindow(actions: actions).padding(.top, 22), size: NSSize(width: 840, height: 760))
        }
        shoot("export", ExportSheet(mdURL: URL(fileURLWithPath: "/tmp/x.md"), actions: actions, onClose: {}), size: NSSize(width: 560, height: 420))
        print("ok  \(n) 張 → \(dir.path)")
        return 0
    }
}
