// StatusBar — 選單列那顆圖示（NSStatusItem）＋浮動小面板（NSPanel：Apple 內建框、可拖可縮、點外面不消失）
// 左鍵＝開關面板；右鍵＝選單（紀錄與設定／設定精靈／結束）。錄音中圖示的點會閃、旁邊顯示計時；暫停中換成兩條直線、計時停住。
// 錄音中面板收起來＝螢幕上出現浮動小條（FloatingBarWindow），面板打開就收掉，一個畫面只留一個狀態。
import AppKit
import Combine
import HearbyCore
import HearbyUI
import SwiftUI

@MainActor
final class StatusBar: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: NSPanel?
    private var blinkTimer: Timer?
    private var blink = false
    private var phase: Phase = .idle
    private var paused = false
    private let floating = FloatingBarWindow()
    private var subs = Set<AnyCancellable>()
    var onOpenWindow: () -> Void = {}
    var onWizard: () -> Void = {}

    override init() {
        super.init()
        guard let b = item.button else { return }
        b.image = MenuIcon.image(for: .idle)
        b.imagePosition = .imageOnly
        b.target = self
        b.action = #selector(clicked)
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        b.toolTip = "Hearby"
        let pm = AppState.shared.panel
        pm.onExpand = { [weak self] in self?.showPanel() }
        // 計時與暫停狀態跟著面板的資料走（AppState 每 0.1 秒寫一次，字變了才重畫）
        pm.$elapsedText.removeDuplicates().combineLatest(pm.$paused.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] t, p in self?.refreshRecordingLook(time: t, paused: p) }
            .store(in: &subs)
    }

    func setPhase(_ p: Phase) {
        phase = p
        blinkTimer?.invalidate(); blinkTimer = nil
        if p == .recording {
            blink = true
            // Timer 在主執行緒的 run loop 上觸發
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tickBlink() } }
        }
        item.button?.image = MenuIcon.image(for: p, blink: true, paused: paused)
        refreshRecordingLook(time: AppState.shared.panel.elapsedText, paused: AppState.shared.panel.paused)
    }

    /// 錄音中那顆點一閃一閃；暫停中不閃（停在兩條直線）
    private func tickBlink() {
        guard phase == .recording, !paused else { return }
        blink.toggle()
        item.button?.image = MenuIcon.image(for: .recording, blink: blink)
    }

    /// 錄音中：圖示旁邊放計時（等寬數字，不會跳來跳去）；暫停換圖示。不在錄＝只剩圖示。順便決定浮動小條要不要出現
    private func refreshRecordingLook(time: String, paused p: Bool) {
        guard let b = item.button else { return }
        let recording = phase == .recording
        if recording {
            if p != paused {
                paused = p
                b.image = MenuIcon.image(for: .recording, blink: true, paused: p)
            }
            b.imagePosition = .imageLeading
            b.attributedTitle = NSAttributedString(string: " " + time, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
            b.toolTip = p ? "Hearby：已暫停（這段不會存）" : "Hearby：錄音中"
        } else {
            paused = false
            if !b.title.isEmpty { b.title = "" }
            b.imagePosition = .imageOnly
            b.toolTip = "Hearby"
        }
        updateFloating()
    }

    /// 浮動小條：錄音中＋面板沒開＋設定沒關
    private func updateFloating() {
        let want = phase == .recording && !(panel?.isVisible ?? false) && ConfigStore.shared.current.floatingBarOn
        if want { floating.show() } else { floating.hide() }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        togglePanel()
    }

    private func showMenu() {
        let m = NSMenu()
        if phase == .recording {
            let pm = AppState.shared.panel
            m.addItem(withTitle: pm.paused ? "繼續錄" : "暫停（這段不會存）", action: #selector(togglePause), keyEquivalent: "").target = self
            m.addItem(withTitle: "停止並整理", action: #selector(stopRecording), keyEquivalent: "").target = self
            m.addItem(.separator())
        }
        m.addItem(withTitle: "紀錄與設定", action: #selector(openWindow), keyEquivalent: "").target = self
        m.addItem(withTitle: "設定精靈", action: #selector(openWizard), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "結束 Hearby", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }
    @objc private func togglePause() { let pm = AppState.shared.panel; pm.paused ? pm.onResume() : pm.onPause() }
    @objc private func stopRecording() { AppState.shared.panel.onStop() }
    @objc private func openWindow() { onOpenWindow() }
    @objc private func openWizard() { onWizard() }
    @objc private func quit() { NSApp.terminate(nil) }

    func togglePanel() {
        let p = ensurePanel()
        if p.isVisible { p.orderOut(nil); updateFloating(); return }
        showPanel()
    }
    func hidePanel() {
        panel?.orderOut(nil)
        updateFloating()
    }
    func showPanel() {
        let p = ensurePanel()
        if !p.isVisible, p.frameAutosaveName.isEmpty || !p.setFrameUsingName("HearbyPanel") {
            // 第一次：貼在選單列圖示下方
            if let b = item.button, let w = b.window {
                let r = w.convertToScreen(b.convert(b.bounds, to: nil))
                let x = min(r.midX - p.frame.width / 2, (w.screen?.visibleFrame.maxX ?? r.maxX) - p.frame.width - 8)
                p.setFrameTopLeftPoint(NSPoint(x: max(8, x), y: r.minY - 6))
            }
        }
        p.makeKeyAndOrderFront(nil)
        updateFloating()
    }
    func recolor() { panel?.backgroundColor = Neu.materialNSColor }

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 560),
                        styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = "Hearby"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.backgroundColor = Neu.materialNSColor
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.minSize = NSSize(width: 320, height: 420)
        p.contentView = NSHostingView(rootView: PanelView(model: AppState.shared.panel).padding(.top, 22))
        p.setFrameAutosaveName("HearbyPanel")
        // 按左上角紅點關掉面板＝收起來：錄音中的話浮動小條接手
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.updateFloating() }
        }
        panel = p
        return p
    }
}

/// 浮動小條的視窗：無框、永遠在最上層、每個桌面都在、可拖、記得位置；不搶焦點（按了不會把正在打字的 app 切走）。
/// sharingType = .none：請系統不要把它放進螢幕分享與錄影畫面（實際效果依 macOS 版本與分享的 app 而定，見 TESTING.md）。
@MainActor
final class FloatingBarWindow {
    private var window: NSPanel?

    func show() {
        let w = ensure()
        if !w.isVisible { w.orderFrontRegardless() }
    }
    func hide() {
        guard let w = window, w.isVisible else { return }
        w.orderOut(nil)
    }

    private func ensure() -> NSPanel {
        if let w = window { return w }
        let size = FloatingBarView.size
        let w = KeyablePanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = true
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.becomesKeyOnlyIfNeeded = true
        w.sharingType = .none
        w.contentView = FirstMouseHostingView(rootView: FloatingBarView(model: AppState.shared.panel))
        w.setFrameAutosaveName("HearbyFloatingBar")
        if !w.setFrameUsingName("HearbyFloatingBar"), let s = NSScreen.main?.visibleFrame {
            // 第一次：螢幕上緣正中間（選單列下方），不擋通知（右上）也不擋 Dock
            w.setFrameOrigin(NSPoint(x: s.midX - size.width / 2, y: s.maxY - size.height - 10))
        }
        window = w
        return w
    }
}

/// 無框視窗預設不能變成 key；讓它可以（不會啟動 app，只是讓按鈕第一下就收得到）
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 第一下點擊就算數：不用先點一下「叫醒」視窗才按得到按鈕
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
