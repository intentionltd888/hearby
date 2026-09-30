// Snapshot — 離線把每個畫面畫成 PNG（設計檢視用）：面板四態＋暫停＋出事、浮動小條、精靈五頁、紀錄視窗（含清單改標題、單場「自己改」「請 AI 改一段」）、匯出表單
// 資料：HEARBY_OUTPUT_ROOT 裡最新一場有紀錄的會議（沒有才用寫死的假字）；那場資料夾若有 snapshot.json
//   {"aiSection":"待辦","aiInstruction":"…","aiPreview":"…"} 就多拍一張「請 AI 改一段」的並排預覽。
// --scale N：輸出 N 倍像素（例：社群圖要 3 倍）。
import AppKit
import HearbyCore
import HearbyUI
import SwiftUI

enum Snapshot {
    static func run(into dir: URL, dark: Bool, scale: CGFloat = 1) -> Int32 { MainActor.assumeIsolated { runMain(into: dir, dark: dark, scale: max(1, scale)) } }
    /// snapshot.json（放在示範那場的資料夾）
    struct AIDemo: Decodable { var aiSection: String; var aiInstruction: String; var aiPreview: String }
    @MainActor static func runMain(into dir: URL, dark: Bool, scale: CGFloat) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        Theme.shared.mode = dark ? .dark : .light
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 精靈那幾張要改設定檔的步數：拍完還原（沒設沙箱時才不會把使用者的精靈進度洗掉）
        let savedStep = ConfigStore.shared.current.wizardStep
        defer { try? ConfigStore.shared.update { $0.wizardStep = savedStep } }
        let latest = MeetingIndex.scan().first(where: { $0.mdURL != nil })
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
            let px = scale == 1 ? host.bitmapImageRepForCachingDisplay(in: host.bounds)
                : NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            guard let rep = px else { return }
            rep.size = size   // 點數不變、像素放大＝同一個畫面更清楚
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
        m.micName = "MacBook Pro 的麥克風"
        shoot("panel-recording", PanelView(model: m).padding(.top, 22), size: panelSize)
        shoot("floating-bar", FloatingBarView(model: m).padding(8), size: NSSize(width: FloatingBarView.size.width + 16, height: FloatingBarView.size.height + 16))
        // 暫停中：計時停住、波形平掉、大圓鈕換成繼續
        m.paused = true
        m.pausedText = "03:12"
        m.noticeLine = nil
        m.micHistory = Array(m.micHistory.prefix(28)) + Array(repeating: 0, count: 12)
        m.sysHistory = Array(m.sysHistory.prefix(28)) + Array(repeating: 0, count: 12)
        shoot("panel-paused", PanelView(model: m).padding(.top, 22), size: panelSize)
        shoot("floating-bar-paused", FloatingBarView(model: m).padding(8), size: NSSize(width: FloatingBarView.size.width + 16, height: FloatingBarView.size.height + 16))
        // 錄音中出事：麥克風兩分鐘沒聲音
        m.paused = false
        m.micHistory = Array(repeating: 0.004, count: 40)
        m.alerts = ["\(AppState.micSilentAlertPrefix)：是不是選錯麥克風，或被靜音了？"]
        shoot("panel-recording-silent", PanelView(model: m).padding(.top, 22), size: panelSize)
        m.alerts = []
        m.phase = .processing
        m.stageText = "聽打房間裡（麥克風） 2/5・約剩 3分10秒"
        m.partial = "[00:12] 那我們今天先把上次的預算表看一下\n[00:20] 好，Kevin 你先講\n[00:31] 第一季的數字已經對過了"
        shoot("panel-processing", PanelView(model: m).padding(.top, 22), size: panelSize)
        m.phase = .done
        m.doneTitle = "2026-09-13_2110_第三季預算"
        m.doneLines = ["第一季數字已對過，第二季預算下修一成", "行銷案改由 Kevin 負責，月底前給草案", "下週三再開一次確認"]
        m.doneMD = URL(fileURLWithPath: "/tmp/x.md")
        // 有真紀錄就用最新那場：標題、日期、三行＝「## 決議」前三條（去時間戳；沒有決議才退回重點／摘要）
        if let it = latest, let u = it.mdURL, let md = try? String(contentsOf: u, encoding: .utf8) {
            let strip = { (t: String) in t.replacingOccurrences(of: #"\s*\[(?:\d{1,2}:)?\d{1,3}:[0-5]\d\]"#, with: "", options: .regularExpression) }
            let decisions = (RecordMD.parse(md: md).section("決議") ?? []).filter { $0 != "無" && !$0.contains("無明確決議") }
            m.doneTitle = it.dir.lastPathComponent
            m.doneLines = decisions.isEmpty ? Polish.threeLines(md: md) : Array(decisions.prefix(3)).map(strip)
            m.doneMD = u
        }
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
        // 清單改標題：滑過最新那場（出現筆）、正在改它的標題
        if let it = latest {
            WindowNav.shared.listDemo = ListDemo(hovered: it.dir)
            shoot("window-hover", MainWindow(actions: actions).padding(.top, 22), size: winSize)
            WindowNav.shared.listDemo = ListDemo(renaming: it.dir, draft: "第三季預算檢討")
            shoot("window-rename", MainWindow(actions: actions).padding(.top, 22), size: winSize)
            WindowNav.shared.listDemo = nil
        }
        if let it = latest, let md = it.mdURL {
            let detailSize = NSSize(width: 840, height: 1000)   // 1000pt：待辦整節拍得進來，也剛好是 4:5 構圖
            WindowNav.shared.openRecord = md
            shoot("window-detail", MainWindow(actions: actions).padding(.top, 22), size: detailSize)
            // 「自己改」
            WindowNav.shared.demo = DetailDemo(editing: true)
            WindowNav.shared.openRecord = md
            shoot("window-detail-edit", MainWindow(actions: actions).padding(.top, 22), size: detailSize)
            // 「請 AI 改一段」＋並排預覽（那場資料夾有 snapshot.json 才拍）
            if let d = try? Data(contentsOf: it.dir.appendingPathComponent("snapshot.json")), let ai = try? JSONDecoder().decode(AIDemo.self, from: d) {
                WindowNav.shared.demo = DetailDemo(aiSection: ai.aiSection, aiInstruction: ai.aiInstruction, aiPreview: ai.aiPreview)
                WindowNav.shared.openRecord = md
                shoot("window-detail-ai", MainWindow(actions: actions).padding(.top, 22), size: detailSize)
            }
            WindowNav.shared.demo = nil
        }
        // 匯出表單：吃最新那場（公司／記錄人照設定預填、與會者從紀錄帶）
        shoot("export", ExportSheet(mdURL: latest?.mdURL ?? URL(fileURLWithPath: "/tmp/x.md"), actions: actions, onClose: {}), size: NSSize(width: 560, height: 420))
        print("ok  \(n) 張 → \(dir.path)")
        return 0
    }
}
