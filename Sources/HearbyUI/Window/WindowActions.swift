// WindowActions — 視窗要叫殼做的事（匯出、重整理、改一段、開終端機）
import Foundation
import HearbyCore

/// 視窗導航：面板或完成頁要「打開這份紀錄」時，叫視窗切到紀錄分頁並選中那一場（不再丟給外部 app 開 .md）
public final class WindowNav: ObservableObject {
    public static let shared = WindowNav()
    @Published public var openRecord: URL? = nil
    @Published public var tab: Int? = nil
    /// 設計檢視（--snapshot）專用：單場頁一打開就擺成指定狀態。一般使用永遠是 nil
    public var demo: DetailDemo? = nil
    /// 設計檢視（--snapshot）專用：清單一打開就擺成「滑過某一場」或「正在改某一場的標題」。一般使用永遠是 nil
    public var listDemo: ListDemo? = nil
}

/// 清單的展示狀態：滑鼠停在哪一場（出現改標題的筆）、正在改哪一場的標題（打到一半的字）
public struct ListDemo: Equatable {
    public var hovered: URL? = nil
    public var renaming: URL? = nil
    public var draft = ""
    public init(hovered: URL? = nil, renaming: URL? = nil, draft: String = "") { self.hovered = hovered; self.renaming = renaming; self.draft = draft }
}

/// 單場頁的展示狀態：「自己改」或「請 AI 改一段」（含並排預覽）
public struct DetailDemo: Equatable {
    public var editing = false
    public var aiSection: String? = nil
    public var aiInstruction: String? = nil
    public var aiPreview: String? = nil
    public init(editing: Bool = false, aiSection: String? = nil, aiInstruction: String? = nil, aiPreview: String? = nil) {
        self.editing = editing; self.aiSection = aiSection; self.aiInstruction = aiInstruction; self.aiPreview = aiPreview
    }
}

public struct WindowActions {
    public var openMD: (URL) -> Void = { _ in }
    public var revealDir: (URL) -> Void = { _ in }
    public var exportWord: (URL, DocHeader, @escaping (Result<URL, Error>) -> Void) -> Void = { _, _, _ in }
    public var exportPDF: (URL, DocHeader, @escaping (Result<URL, Error>) -> Void) -> Void = { _, _, _ in }
    public var exportPages: (URL, DocHeader, @escaping (Result<URL, Error>) -> Void) -> Void = { _, _, _ in }
    public var continueClaude: (URL) -> Void = { _ in }
    /// 重新整理全篇：(md, 更正, 階段回報, 完成)。階段回報在主執行緒叫，畫面用它顯示「AI 重新整理中…」這類進度字
    public var repolish: (URL, String, @escaping (String) -> Void, @escaping (Result<String, Error>) -> Void) -> Void = { _, _, _, _ in }
    public var sectionEdit: (URL, String, String, @escaping (Result<String, Error>) -> Void) -> Void = { _, _, _, _ in }
    public var translate: (URL, String, @escaping (Result<URL, Error>) -> Void) -> Void = { _, _, _ in }
    /// 改標題：(這一場的資料夾, 新標題, 完成)。資料夾、檔名、紀錄表頭、記憶、副本一起換（MeetingRename）
    public var renameMeeting: (URL, String, @escaping (Result<MeetingRename.Report, Error>) -> Void) -> Void = { _, _, _ in }
    public var runDoctorDeep: () -> DoctorReport = { Doctor.run(deep: true) }
    public var exportDiagnostics: () -> URL? = { nil }
    public var rerunWizard: () -> Void = {}
    public init() {}
}

/// 匯出表單：中性文件的表頭（會議名稱、公司、與會單位、記錄人、日期、與會者）
import SwiftUI
public struct ExportSheet: View {
    let mdURL: URL
    let actions: WindowActions
    let onClose: () -> Void
    @State private var h: DocHeader
    @State private var busy = false
    @State private var msg = ""
    @ObservedObject private var theme = Theme.shared

    public init(mdURL: URL, actions: WindowActions, onClose: @escaping () -> Void) {
        self.mdURL = mdURL; self.actions = actions; self.onClose = onClose
        let md = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""
        _h = State(initialValue: DocHeader.prefill(md: md, language: DocLabels.language(of: mdURL)))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NeuSpace.md) {
            HStack {
                Text("匯出文件").font(NeuFont.ui(NeuType.title, true)).foregroundColor(Neu.inkStrong)
                Spacer()
                NeuNote(text: "文件是你們公司的，不會有 Hearby 的標誌；沒填的欄位不會印出來。")
            }
            field("標題", $h.title, "會議名稱")
            field("公司", $h.company, "你們公司的名稱")
            field("與會單位", $h.units, "例：行銷部、甲方採購")
            field("記錄", $h.recorder, "記錄人")
            field("日期", $h.date, "yyyy-MM-dd HH:mm")
            field("與會者", $h.attendees, "頓號分隔")
            if !msg.isEmpty { NeuNote(text: msg) }
            if busy { NeuGroove(fill: nil, height: 8) }
            HStack(spacing: NeuSpace.sm) {
                NeuCapsuleButton(title: "出 PDF", height: 38, enabled: !busy) { run { actions.exportPDF(mdURL, h, $0) } }
                NeuCapsuleButton(title: "出 Word", height: 38, enabled: !busy) { run { actions.exportWord(mdURL, h, $0) } }
                NeuCapsuleButton(title: "在 Pages 打開", height: 38, enabled: !busy) { run { actions.exportPages(mdURL, h, $0) } }
                NeuChip(title: "關閉") { onClose() }
            }
        }
        .padding(NeuSpace.xl)
        .frame(width: 560)
        .background(Neu.material)
        .id(theme.mode)
    }
    private func field(_ label: String, _ text: Binding<String>, _ placeholder: String) -> some View {
        HStack(spacing: NeuSpace.sm) {
            Text(label).font(NeuFont.ui(NeuType.caption, true)).foregroundColor(Neu.inkMid).frame(width: 64, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.plain).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong)
                .padding(.horizontal, NeuSpace.md).frame(height: 32).neuDebossed(NeuRadius.pill, depth: 0.9)
        }
    }
    private func run(_ f: (@escaping (Result<URL, Error>) -> Void) -> Void) {
        busy = true
        try? ConfigStore.shared.update { $0.docCompany = h.company.isEmpty ? nil : h.company; $0.docRecorder = h.recorder.isEmpty ? nil : h.recorder }
        f { r in
            busy = false
            switch r { case .success(let u): msg = "已存到：\(u.lastPathComponent)"; case .failure(let e): msg = e.localizedDescription }
        }
    }
}
