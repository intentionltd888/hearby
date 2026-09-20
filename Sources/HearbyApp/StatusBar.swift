// StatusBar — 選單列那顆圖示（NSStatusItem）＋浮動小面板（NSPanel：Apple 內建框、可拖可縮、點外面不消失）
// 左鍵＝開關面板；右鍵＝選單（紀錄與設定／設定精靈／結束）。錄音中圖示的點會閃。
import AppKit
import HearbyCore
import HearbyUI
import SwiftUI

@MainActor
final class StatusBar: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: NSPanel?
    private var blinkTimer: Timer?
    private var blink = false
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
    }

    func setPhase(_ p: Phase) {
        blinkTimer?.invalidate(); blinkTimer = nil
        if p == .recording {
            blink = true
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.blink.toggle()
                self.item.button?.image = MenuIcon.image(for: .recording, blink: self.blink)
            }
        }
        item.button?.image = MenuIcon.image(for: p, blink: true)
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        togglePanel()
    }

    private func showMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "紀錄與設定", action: #selector(openWindow), keyEquivalent: "").target = self
        m.addItem(withTitle: "設定精靈", action: #selector(openWizard), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "結束 Hearby", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }
    @objc private func openWindow() { onOpenWindow() }
    @objc private func openWizard() { onWizard() }
    @objc private func quit() { NSApp.terminate(nil) }

    func togglePanel() {
        let p = ensurePanel()
        if p.isVisible { p.orderOut(nil); return }
        showPanel()
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
        panel = p
        return p
    }
}
