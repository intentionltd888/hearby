// MenuIcon — 選單列圖示五態（程式畫，template）：待命／錄音中（點，會閃）／暫停中（兩條直線，不閃）／處理中（空心點）／出事（！）
import AppKit
import HearbyCore
import HearbyUI

enum MenuIcon {
    static var cache: [String: NSImage] = [:]
    static func image(for phase: Phase, blink: Bool = false, paused: Bool = false) -> NSImage {
        let isPaused = paused && phase == .recording
        let key = "\(phase.rawValue)-\(blink)-\(isPaused)"
        if let c = cache[key] { return c }
        let mark = Brand.markImage(height: 15)
        let mw = mark.size.width
        let size = NSSize(width: mw + (phase == .idle ? 0 : 7), height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            mark.draw(in: NSRect(x: 0, y: 1.5, width: mw, height: 15))
            NSColor.black.setFill()
            switch phase {
            case .recording where isPaused:
                NSBezierPath(rect: NSRect(x: mw + 2, y: 1.5, width: 1.8, height: 6)).fill()
                NSBezierPath(rect: NSRect(x: mw + 5.2, y: 1.5, width: 1.8, height: 6)).fill()
            case .recording:
                NSColor.black.withAlphaComponent(blink ? 1 : 0.35).setFill()
                NSBezierPath(ovalIn: NSRect(x: mw + 2, y: 1.5, width: 5, height: 5)).fill()
            case .processing:
                let p = NSBezierPath(ovalIn: NSRect(x: mw + 2.5, y: 2, width: 4, height: 4)); p.lineWidth = 1; NSColor.black.setStroke(); p.stroke()
            case .error:
                NSBezierPath(rect: NSRect(x: mw + 3.5, y: 5, width: 1.6, height: 8)).fill()
                NSBezierPath(rect: NSRect(x: mw + 3.5, y: 1.5, width: 1.6, height: 1.6)).fill()
            case .done:
                NSBezierPath(ovalIn: NSRect(x: mw + 2, y: 1.5, width: 5, height: 5)).fill()
            default: break
            }
            return true
        }
        img.isTemplate = true
        cache[key] = img
        return img
    }
}
