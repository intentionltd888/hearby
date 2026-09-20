// PanelModel — 面板要看的東西（殼寫、畫面讀）；動作用閉包接回殼
import Combine
import Foundation
import HearbyCore
import SwiftUI

public final class PanelModel: ObservableObject {
    @Published public var phase: Phase = .idle
    @Published public var scene: Int = 0   // 0 會議／1 筆記
    @Published public var online: Bool = false
    @Published public var brief: String = ""
    @Published public var elapsedText = "00:00"
    @Published public var micHistory: [Float] = []
    @Published public var sysHistory: [Float] = []
    @Published public var sysActive = false
    @Published public var alerts: [String] = []
    @Published public var noticeLine: String? = nil   // 開錄那秒的事前文案，3 秒淡掉
    @Published public var stageText = ""
    @Published public var partial = ""
    @Published public var doneTitle = ""
    @Published public var doneLines: [String] = []
    @Published public var doneMD: URL? = nil
    @Published public var doneNote = ""
    @Published public var errorText = ""
    @Published public var lastMeeting: MeetingItem? = nil
    @Published public var modelReady = true
    @Published public var downloadFraction: Double? = nil
    @Published public var downloadNote = ""
    @Published public var pendingRecoveries: [Pipeline.RecoveryItem] = []
    @Published public var suggestedBrief: [String] = []
    @Published public var claudeReady = false

    public var onStart: () -> Void = {}
    public var onStop: () -> Void = {}
    public var onOpenWindow: () -> Void = {}
    public var onOpenSettings: () -> Void = {}
    public var onDismiss: () -> Void = {}
    public var onOpenMD: (URL) -> Void = { _ in }
    public var onExportWord: (URL) -> Void = { _ in }
    public var onContinueClaude: (URL) -> Void = { _ in }
    public var onDownloadModel: () -> Void = {}
    public var onRecover: (Pipeline.RecoveryItem) -> Void = { _ in }
    public var onIgnoreRecovery: (Pipeline.RecoveryItem) -> Void = { _ in }
    public var onImport: () -> Void = {}
    public var onExportPDF: (URL) -> Void = { _ in }

    public init() {}
    public static let waveSlots = 40
}
