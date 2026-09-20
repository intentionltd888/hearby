// Appearance — 外觀三選：跟隨系統／淺色／深色（都是軟浮雕材質）
import AppKit
import Combine
import HearbyCore
import SwiftUI

public enum AppearanceMode: String, CaseIterable {
    case system, light, dark
    public var label: String {
        switch self {
        case .system: return "跟隨系統"
        case .light: return "淺色"
        case .dark: return "深色"
        }
    }
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    public static var current: AppearanceMode { AppearanceMode(rawValue: ConfigStore.shared.current.appearance) ?? .system }

    @MainActor public static func apply(_ m: AppearanceMode) {
        NSApp.appearance = m.nsAppearance
        Theme.shared.mode = m
    }
    @MainActor public static func set(_ m: AppearanceMode) {
        try? ConfigStore.shared.update { $0.appearance = m.rawValue }
        apply(m)
    }
}

/// 全域主題（根畫面觀察它，換外觀整棵重畫）
public final class Theme: ObservableObject {
    public static let shared = Theme()
    @Published public var mode: AppearanceMode = AppearanceMode.current
    /// 現在畫面是不是深色（跟隨系統時看 effectiveAppearance）
    @MainActor public var isDark: Bool {
        if mode == .dark { return true }
        if mode == .light { return false }
        return NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
