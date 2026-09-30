// MainWindow — 唯一的視窗：紀錄（清單／單場）／設定／檢查
import HearbyCore
import SwiftUI

public struct MainWindow: View {
    @State private var tab: Int
    @ObservedObject private var theme = Theme.shared
    @ObservedObject private var nav = WindowNav.shared
    let actions: WindowActions
    public init(actions: WindowActions, initialTab: Int = 0) { self.actions = actions; _tab = State(initialValue: initialTab) }

    public var body: some View {
        VStack(alignment: .leading, spacing: NeuSpace.lg) {
            // 標題列：左字標、右三個分頁（圖示＋字）；版本號移到底列
            HStack(alignment: .center) {
                HearbyLogotype(height: 16, color: Neu.inkStrong)
                Spacer()
                NeuSegmented(items: ["紀錄", "設定", "檢查"], selection: $tab, icons: ["list.bullet.rectangle.portrait", "gearshape", "checkmark.shield"], height: 36)
                    .frame(width: 330)
            }
            Group {
                switch tab {
                case 0: RecordsPane(actions: actions)
                case 1: SettingsPane(actions: actions)
                default: StatusPane(actions: actions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: NeuSpace.sm) {
                PoweredBy(showWordmark: false)
                Spacer()
                Text("\(HearbyVersion.version) build \(HearbyVersion.build)").font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkSoft)
            }
        }
        .padding(NeuSpace.edge)
        .frame(minWidth: 700, minHeight: 540)
        .background(Neu.stage)
        .id(theme.mode)
        .onReceive(nav.$openRecord) { u in if u != nil { tab = 0 } }
        .onReceive(nav.$tab) { t in if let t { tab = t; nav.tab = nil } }
    }
}

// MARK: 紀錄清單 ＋ 單場頁

struct RecordsPane: View {
    let actions: WindowActions
    @State private var items: [MeetingItem] = []
    @State private var query = ""
    @State private var hits: [(item: MeetingItem, line: String)] = []
    @State private var selected: MeetingItem? = nil
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    // 改標題：滑過哪一場（出現筆）、正在改哪一場、打到一半的字、改名中、改完的一句話
    @State private var hovered: String? = nil
    @State private var renaming: MeetingItem? = nil
    @State private var renameDraft = ""
    @State private var renameBusy = false
    @State private var renameMsg = ""
    @FocusState private var renameFocus: Bool

    @ObservedObject private var nav = WindowNav.shared

    var body: some View {
        Group {
            if let s = selected { MeetingDetail(item: s, actions: actions) { selected = nil; reload() } } else { list }
        }
        .onAppear { reload(); openPending(); applyListDemo() }
        // 正在改標題的時候不重掃：清單照修改時間排，重掃會讓那一列跳走
        .onReceive(tick) { _ in if selected == nil, renaming == nil { reload() } }
        .onReceive(nav.$openRecord) { _ in openPending() }
    }
    /// 面板「打開這份紀錄」／「上一場」：選中那一場
    private func openPending() {
        guard let u = nav.openRecord else { return }
        reload()
        if let it = items.first(where: { $0.mdURL == u || $0.dir == u.deletingLastPathComponent() }) { selected = it }
        nav.openRecord = nil
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: NeuSpace.md) {
            HStack(spacing: NeuSpace.sm) {
                TextField("搜某句話或某個人名（會翻整份逐字稿，不只搜標題）", text: $query)
                    .textFieldStyle(.plain).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong)
                    .padding(.horizontal, NeuSpace.md).frame(height: 34)
                    .neuDebossed(NeuRadius.pill, depth: 0.9)
                    .onSubmit { hits = MeetingIndex.search(query) }
                NeuChip(title: "搜") { hits = MeetingIndex.search(query) }
                NeuChip(title: "打開資料夾") { actions.revealDir(Paths.meetings) }
            }
            if !renameMsg.isEmpty { NeuNote(text: renameMsg) }
            if !query.isEmpty, !hits.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(hits.enumerated()), id: \.offset) { _, h in
                            HStack(alignment: .top, spacing: NeuSpace.sm) {
                                Text(h.item.title).font(NeuFont.ui(NeuType.caption, true)).foregroundColor(Neu.inkStrong).frame(width: 160, alignment: .leading).lineLimit(1)
                                Text(h.line).font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid).lineLimit(2)
                                Spacer()
                            }
                            .contentShape(Rectangle()).onTapGesture { selected = h.item }.padding(.vertical, 3)
                        }
                    }
                }
            } else if items.isEmpty {
                NeuInset {
                    VStack(alignment: .leading, spacing: NeuSpace.sm) {
                        Text("還沒有紀錄").font(NeuFont.ui(NeuType.title, true)).foregroundColor(Neu.inkStrong)
                        NeuNote(text: "按選單列（螢幕最上面那一列）右邊的 ” 圖示開錄，結束就會出現在這裡。所有檔案都在：\(Paths.meetings.path)")
                    }
                    .padding(NeuSpace.lg).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                ScrollView {
                    VStack(spacing: NeuSpace.sm) {
                        ForEach(items) { it in
                            if renaming?.id == it.id { renameRow(it) } else { row(it) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// 一場一列：點了進單場頁；滑過右邊出現筆（改標題），右鍵也有
    private func row(_ it: MeetingItem) -> some View {
        ZStack(alignment: .trailing) {
            Button { selected = it } label: {
                HStack(alignment: .top, spacing: NeuSpace.md) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(it.title).font(NeuFont.ui(NeuType.body, true)).foregroundColor(Neu.inkStrong).lineLimit(1)
                        Text([it.dateText, it.durText].filter { !$0.isEmpty }.joined(separator: "　")).font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkSoft)
                        if !it.gist.isEmpty { Text(it.gist).font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid).lineLimit(1) }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundColor(Neu.inkSoft)
                }
                .padding(NeuSpace.md).frame(maxWidth: .infinity, alignment: .leading)
                .neuRaised(NeuRadius.card, lift: 0.6)
            }
            .buttonStyle(.plain)
            if hovered == it.id {
                NeuIconButton(systemName: "pencil", size: 26) { beginRename(it) }
                    .help("改標題（資料夾、檔名、記憶裡的這一場會一起改）")
                    .padding(.trailing, NeuSpace.md + 20)
            }
        }
        .onHover { inside in if inside { hovered = it.id } else if hovered == it.id { hovered = nil } }
        .contextMenu {
            Button("改標題…") { beginRename(it) }
            Button("在 Finder 裡顯示") { actions.revealDir(it.dir) }
        }
    }

    /// 正在改標題的那一列：原地變成輸入框（Enter 改好、Esc 取消）
    private func renameRow(_ it: MeetingItem) -> some View {
        VStack(alignment: .leading, spacing: NeuSpace.sm) {
            HStack(spacing: NeuSpace.sm) {
                TextField("新的標題", text: $renameDraft)
                    .textFieldStyle(.plain).font(NeuFont.ui(NeuType.body, true)).foregroundColor(Neu.inkStrong)
                    .padding(.horizontal, NeuSpace.md).frame(height: 34)
                    .neuDebossed(NeuRadius.pill, depth: 0.9)
                    .focused($renameFocus)
                    .disabled(renameBusy)
                    .onSubmit { commitRename(it) }
                    .onExitCommand { cancelRename() }
                NeuChip(title: renameBusy ? "改名中…" : "改好", systemImage: "checkmark", enabled: !renameBusy) { commitRename(it) }
                NeuChip(title: "取消", systemImage: "xmark", enabled: !renameBusy) { cancelRename() }
            }
            Text([it.dateText, it.durText].filter { !$0.isEmpty }.joined(separator: "　")).font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkSoft)
                .padding(.leading, NeuSpace.md)
            NeuNote(text: "按 Enter 改好、Esc 取消。這一場的資料夾、裡面的檔名、紀錄上的標題、記憶裡的這一場（有設副本資料夾的話連副本）會一起改；日期和時間不變。")
        }
        .padding(NeuSpace.md).frame(maxWidth: .infinity, alignment: .leading)
        .neuDebossed(NeuRadius.card, depth: 0.7)
    }

    private func beginRename(_ it: MeetingItem) {
        renaming = it
        renameDraft = it.title
        renameMsg = ""
        hovered = nil
        DispatchQueue.main.async { renameFocus = true }
    }

    private func cancelRename() {
        guard !renameBusy else { return }
        renaming = nil
        renameDraft = ""
    }

    private func commitRename(_ it: MeetingItem) {
        guard !renameBusy else { return }
        guard !MeetingRename.oneLine(renameDraft).isEmpty else { renameMsg = "標題不能是空的"; return }
        renameBusy = true
        actions.renameMeeting(it.dir, renameDraft) { r in
            renameBusy = false
            switch r {
            case .success(let rep):
                renaming = nil
                renameDraft = ""
                renameMsg = rep.unchanged ? "" : Self.summary(rep, from: it.title)
                reload()
            case .failure(let e):
                renameMsg = e.localizedDescription
            }
        }
    }

    /// 改完的一句話：改成什麼、記憶與副本有沒有跟著換、哪裡沒做成
    static func summary(_ r: MeetingRename.Report, from old: String) -> String {
        var s = "改好了：「\(old)」→「\(MeetingIndex.split(folderName: r.newID).1)」"
        if !r.memory.isEmpty { s += "；記憶裡的這一場跟著換了" + (r.backups.isEmpty ? "" : "（改之前留了備份）") }
        if !r.mirror.isEmpty { s += "；副本資料夾也改了" }
        if !r.warnings.isEmpty { s += "。沒做成的：" + r.warnings.joined(separator: "；") }
        return s
    }

    /// 設計檢視（--snapshot）：擺成滑過某一場、或正在改某一場的標題
    private func applyListDemo() {
        guard let d = nav.listDemo else { return }
        let key = { (u: URL) in u.standardizedFileURL.path }
        if let h = d.hovered { hovered = items.first { key($0.dir) == key(h) }?.id }
        if let u = d.renaming, let it = items.first(where: { key($0.dir) == key(u) }) { renaming = it; renameDraft = d.draft.isEmpty ? it.title : d.draft }
    }

    private func reload() { items = MeetingIndex.scan() }
}

struct MeetingDetail: View {
    let item: MeetingItem
    let actions: WindowActions
    let onBack: () -> Void
    @State private var md = ""
    @State private var editing = false
    @State private var draft = ""
    @State private var mode = 0
    @State private var oneLine = false
    @State private var msg = ""
    @State private var busy = false
    @State private var aiSection = "重點"
    @State private var aiInstruction = ""
    @State private var aiPreview: String? = nil
    @State private var corrections = ""
    @State private var showRepolish = false
    @State private var showAI = false
    @State private var showExport = false
    @State private var current: URL? = nil        // 現在看的是哪個檔（原文或翻譯）
    @State private var askNames: [NameLedger.Question] = []   // 這一場 AI 沒把握、沒改的名字（名字確認帳「要確認」）；答一次就不再問
    @State private var translations: [String] = []  // 已有的翻譯語言
    @State private var showTranslate = false
    @State private var showVoices = false             // 認聲音（實驗，macOS 15 以上）
    @State private var stage = ""                  // AI 在跑的時候給人看的一行（重新整理要跑一兩分鐘，沒有進度字會以為壞了）

    /// 可以請 AI 改的節＝這份紀錄真的有的 `## ` 節（會議／訪談／筆記各不同；逐字稿與機器節不列）
    private var sectionNames: [String] {
        let skip = ["逐字稿", "修正紀錄", "會前重點對照", "參考連結"]
        var names: [String] = []
        for line in md.components(separatedBy: "\n") {
            guard line.hasPrefix("## ") else { continue }
            let n = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if n == "逐字稿" { break }
            if !skip.contains(where: { n.contains($0) }), !names.contains(n) { names.append(n) }
        }
        return names.isEmpty ? ["AI 會議摘要", "與會者", "重點", "決議", "待辦"] : names
    }
    /// 正在自己改（有沒存的草稿）或 AI 在跑的時候，不能再叫 AI——否則跑完會把你打到一半的字蓋掉
    private var aiAllowed: Bool { !editing && !busy }
    private var aiBlockedHelp: String { editing ? "正在自己改：先按「存檔」或「取消」，才能請 AI 改" : (busy ? "AI 正在跑，等它做完" : "") }

    var body: some View {
        VStack(alignment: .leading, spacing: NeuSpace.md) {
            HStack(spacing: NeuSpace.sm) {
                NeuBackHeader(title: item.title, onBack: onBack)
                NeuIconButton(systemName: "folder", size: 26) { actions.revealDir(item.dir) }.help("打開這一場的資料夾（錄音、紀錄、匯出的檔都在裡面）")
            }
            HStack(spacing: NeuSpace.sm) {
                NeuSegmented(items: ["紀錄", "逐字稿"], selection: $mode, icons: ["doc.text", "text.quote"], height: 34).frame(width: 220)
                if mode == 1 { NeuChip(title: oneLine ? "分塊" : "一句一行", systemImage: "text.alignleft") { oneLine.toggle() } }
                Spacer(minLength: 0)
            }
            if item.mdURL != nil {
                FlowLayout(spacing: NeuSpace.sm) {
                    if editing {
                        NeuChip(title: "存檔", systemImage: "checkmark") { save() }
                        NeuChip(title: "取消", systemImage: "xmark") { editing = false; draft = "" }
                    } else {
                        NeuChip(title: "自己改", systemImage: "pencil", enabled: !busy) { draft = md; editing = true; showAI = false; showRepolish = false; showTranslate = false; msg = "" }
                            .help("直接改文字（可以用鍵盤 ⌘C／⌘V，也可以用語音輸入）；按「存檔」才會存，原版會留備份")
                    }
                    NeuChip(title: "請 AI 改一段", systemImage: "wand.and.stars", enabled: aiAllowed) { showAI.toggle(); showRepolish = false; showTranslate = false }
                        .help(aiAllowed ? "挑一節、用一句話說要改什麼，AI 改好先給你看，按確認才寫入" : aiBlockedHelp)
                    NeuChip(title: "重新整理全篇", systemImage: "arrow.clockwise", enabled: aiAllowed) { showRepolish.toggle(); showAI = false; showTranslate = false }
                        .help(aiAllowed ? "整份紀錄交給 AI 照逐字稿重寫一次（不是重新載入畫面）；大約 1 到 2 分鐘" : aiBlockedHelp)
                    NeuChip(title: "翻譯", systemImage: "globe", enabled: aiAllowed) { showTranslate.toggle(); showAI = false; showRepolish = false }
                        .help(aiAllowed ? "翻成英文／日文／簡中，另存一份，原文不動" : aiBlockedHelp)
                    NeuChip(title: "存成 PDF／Word", systemImage: "doc.richtext") { showExport = true }
                    NeuChip(title: "跟 Claude 討論", systemImage: "bubble.left.and.text.bubble.right") { if let u = item.mdURL { actions.continueClaude(u) } }
                    if Voices.supported {
                        NeuChip(title: "認聲音", systemImage: "person.wave.2") { showVoices.toggle() }
                            .help("找出這場錄音裡有哪些聲音，幫認識的人取名字（本人同意才記；聲紋只存在這台 Mac）")
                    }
                }
                if editing { NeuNote(text: "正在自己改：下面的字可以直接打、貼上或用語音輸入。改完按「存檔」；要請 AI 改的話先存檔或取消。") }
                if !askNames.isEmpty, !editing {
                    VStack(alignment: .leading, spacing: NeuSpace.xs) {
                        NeuNote(text: "這一場有 \(askNames.count) 個名字 AI 沒把握、沒有改（紀錄裡標了 [[?]]）。答一次就記住，之後的會議不會再問。")
                        ForEach(askNames.prefix(8), id: \.heard) { q in
                            HStack(spacing: NeuSpace.sm) {
                                Text("「\(q.heard)」是「\(q.name)」嗎？").font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong)
                                NeuChip(title: "是", systemImage: "checkmark") { answerName(q, yes: true) }
                                NeuChip(title: "不是", systemImage: "xmark") { answerName(q, yes: false) }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            if showVoices, let u = item.mdURL { VoicesPanel(mdURL: u) }
            if !translations.isEmpty, let orig = item.mdURL {
                HStack(spacing: NeuSpace.sm) {
                    Text("看哪一版").font(NeuFont.ui(NeuType.caption, true)).foregroundColor(Neu.inkMid)
                    NeuChip(title: "原文" + (current == orig ? " ✓" : "")) { current = orig; load() }
                    ForEach(translations, id: \.self) { l in
                        let u = translatedURL(l)
                        NeuChip(title: DocLabels.name(l) + (current == u ? " ✓" : "")) { current = u; load() }
                    }
                    Spacer()
                }
            }
            if showTranslate, let mdURL = item.mdURL {
                VStack(alignment: .leading, spacing: NeuSpace.sm) {
                    NeuNote(text: "把這份紀錄翻成別的語言，另存一份（原文不動、逐字稿不翻）。要有接上 Claude 或 ChatGPT 才能翻。")
                    HStack(spacing: NeuSpace.sm) {
                        ForEach(["en", "ja", "zh-CN"], id: \.self) { l in
                            NeuCapsuleButton(title: "翻成\(DocLabels.name(l))", height: 36, enabled: !busy) {
                                busy = true; msg = ""
                                stage = "翻成\(DocLabels.name(l))中…（整份交給 AI 翻，通常 1 分鐘上下；翻好會另存一份、自動切過去看）"
                                actions.translate(mdURL, l) { r in
                                    busy = false; stage = ""
                                    switch r {
                                    case .success(let u): translations = findTranslations(); current = u; load(); showTranslate = false; msg = "翻好了，現在看的是\(DocLabels.name(l))版（\(u.lastPathComponent)）；要回原文按上面的「原文」"
                                    case .failure(let e): msg = e.localizedDescription
                                    }
                                }
                            }
                        }
                        Spacer()
                    }
                }
                .padding(NeuSpace.md).neuDebossed(NeuRadius.card, depth: 0.7)
            }
            if !msg.isEmpty { NeuNote(text: msg) }
            if busy {
                // AI 在跑：一條會動的凹槽＋一行說現在在做什麼、大概多久（沒有這行，人會以為壞了去點別的）
                HStack(spacing: NeuSpace.md) {
                    NeuGroove(fill: nil, height: 8).frame(width: 140)
                    Text(stage.isEmpty ? "處理中…" : stage).font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(NeuSpace.md).neuDebossed(NeuRadius.card, depth: 0.7)
            }
            if showAI, let mdURL = item.mdURL {
                VStack(alignment: .leading, spacing: NeuSpace.sm) {
                    HStack(spacing: NeuSpace.sm) {
                        Text("改哪一節").font(NeuFont.ui(NeuType.caption, true)).foregroundColor(Neu.inkMid)
                        ForEach(sectionNames, id: \.self) { s in NeuChip(title: s + (aiSection == s ? " ✓" : "")) { aiSection = s } }
                    }
                    TextField("用一句話說哪裡不對、要改成什麼（例：這條的負責人是小華不是小明）", text: $aiInstruction, axis: .vertical)
                        .textFieldStyle(.plain).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong).lineLimit(1...3)
                        .padding(NeuSpace.md).neuDebossed(NeuRadius.card, depth: 0.9)
                    HStack(spacing: NeuSpace.sm) {
                        NeuCapsuleButton(title: "請 AI 改這一節", height: 38, enabled: !aiInstruction.isEmpty && !busy) {
                            busy = true; aiPreview = nil; msg = ""
                            stage = "AI 改「\(aiSection)」中…（會對照逐字稿，通常半分鐘到 1 分鐘；改好先並排給你看，按「確認寫入」才會存）"
                            actions.sectionEdit(mdURL, aiSection, aiInstruction) { r in
                                busy = false; stage = ""
                                switch r { case .success(let t): aiPreview = t; case .failure(let e): msg = e.localizedDescription }
                            }
                        }
                        if let p = aiPreview {
                            NeuChip(title: "確認寫入") {
                                do { try Repolish.replaceSection(mdURL: mdURL, sectionName: aiSection, with: p); load(); aiPreview = nil; showAI = false; msg = "已寫入，原版備份成 _舊版" }
                                catch { msg = error.localizedDescription }
                            }
                            NeuChip(title: "不要") { aiPreview = nil }
                        }
                    }
                    if let p = aiPreview {
                        HStack(alignment: .top, spacing: NeuSpace.md) {
                            column("原本", originalText(aiSection))
                            column("AI 改後", p)
                        }
                    }
                }
                .padding(NeuSpace.md).neuDebossed(NeuRadius.card, depth: 0.7)
            }
            if showRepolish, let mdURL = item.mdURL {
                VStack(alignment: .leading, spacing: NeuSpace.sm) {
                    NeuNote(text: "整份紀錄交給 AI 照逐字稿重寫一次（錄音不用重聽）。可以先寫更正（例：「Kevien」應為「Kevin」，或「負責人是小華」），它會照著改。按下去大約 1 到 2 分鐘，跑完會直接換成新版；原來那版會留一份備份。")
                    TextField("更正（一行一條，可空白）", text: $corrections, axis: .vertical)
                        .textFieldStyle(.plain).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong).lineLimit(1...4)
                        .padding(NeuSpace.md).neuDebossed(NeuRadius.card, depth: 0.9)
                    NeuCapsuleButton(title: busy ? "AI 重新整理中…" : "開始重新整理（約 1 到 2 分鐘）", height: 38, enabled: !busy) {
                        busy = true; msg = ""; stage = "AI 重新整理中…"
                        actions.repolish(mdURL, corrections, { t in
                            stage = t.contains("AI") ? t + "（整份重寫，通常 1 到 2 分鐘；可以先去做別的事，跑完會直接換成新版）" : t
                        }) { r in
                            busy = false; stage = ""
                            switch r {
                            case .success: msg = "重新整理好了，下面就是新版；原來那版備份成 _舊版，在這一場的資料夾裡"; load(); showRepolish = false; corrections = ""
                            case .failure(let e): msg = e.localizedDescription
                            }
                        }
                    }
                }
                .padding(NeuSpace.md).neuDebossed(NeuRadius.card, depth: 0.7)
            }
            if editing {
                TextEditor(text: $draft).font(NeuFont.ui(NeuType.body)).scrollContentBackground(.hidden)
                    .padding(NeuSpace.sm).neuDebossed(NeuRadius.card, depth: 0.9)
            } else if mode == 0 {
                DocView(md: displayText, language: DocLabels.language(of: current ?? item.mdURL ?? item.dir))
            } else {
                ScrollView {
                    Text(displayText).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(NeuSpace.md)
                }
                .neuDebossed(NeuRadius.card, depth: 0.9)
            }
        }
        .onAppear(perform: load)
        .sheet(isPresented: $showExport) {
            if let u = current ?? item.mdURL { ExportSheet(mdURL: u, actions: actions) { showExport = false } }
        }
    }

    /// 並排預覽左邊那欄：這一節現在的內容。待辦解析時不放在一般段落裡（另收在 todos），要自己組回來，不然永遠是空的
    private func originalText(_ section: String) -> String {
        let rec = RecordMD.parse(md: md)
        if section.contains("待辦") { return rec.todos.map { "\($0.item)｜\($0.owner)｜\($0.due)" }.joined(separator: "\n") }
        return (rec.section(section) ?? []).joined(separator: "\n")
    }
    private func column(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(NeuFont.ui(NeuType.micro, true)).foregroundColor(Neu.inkSoft)
            ScrollView { Text(text).font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkStrong).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
        }
        .frame(maxWidth: .infinity)
    }
    private var displayText: String {
        let parts = md.components(separatedBy: "\n## 逐字稿")
        if mode == 0 { return parts.first ?? md }
        var t = parts.count > 1 ? parts[1] : "（沒有逐字稿）"
        if oneLine {
            t = t.components(separatedBy: "\n").flatMap { line -> [String] in
                guard line.hasPrefix("- [") else { return [line] }
                let pieces = line.components(separatedBy: CharacterSet(charactersIn: "。？！"))
                return pieces.count > 1 ? pieces.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.enumerated().map { $0.offset == 0 ? $0.element : "    " + $0.element } : [line]
            }.joined(separator: "\n")
        }
        return t
    }
    private func translatedURL(_ lang: String) -> URL? {
        guard let o = item.mdURL else { return nil }
        return o.deletingLastPathComponent().appendingPathComponent(o.deletingPathExtension().lastPathComponent + ".\(lang).md")
    }
    private func findTranslations() -> [String] {
        ["en", "ja", "zh-CN"].filter { l in translatedURL(l).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    }
    private func load() {
        let first = current == nil
        if current == nil { current = item.mdURL; translations = findTranslations() }
        if let u = item.mdURL { askNames = NameLedger.pending(meeting: u.deletingPathExtension().lastPathComponent) }
        if let u = current, let s = try? String(contentsOf: u, encoding: .utf8) { md = s }
        // 只有逐字稿（沒接 AI 整理）的紀錄：打開直接看逐字稿，不要給人一頁空白
        if first, RecordMD.parse(md: md).sections.allSatisfy({ $0.lines.allSatisfy { $0.hasPrefix("（") || $0 == "---" || $0 == "無" || $0.isEmpty } }) { mode = 1 }
        // 「請 AI 改一段」預設選的節要是這份真的有的（筆記沒有「重點」，之前預設「重點」→ 按確認寫入會說找不到）
        if !sectionNames.contains(aiSection) { aiSection = sectionNames.first ?? aiSection }
        // 設計檢視（--snapshot）才有：直接擺成「自己改」或「請 AI 改一段＋並排預覽」
        if first, let d = WindowNav.shared.demo {
            if d.editing { draft = md; editing = true }
            if let sec = d.aiSection { aiSection = sec; showAI = true }
            if let ins = d.aiInstruction { aiInstruction = ins }
            if let pv = d.aiPreview { aiPreview = pv }
        }
    }
    /// 答「要確認」的名字：寫進名字確認帳（是＝下一場照這個認；不是＝不要換）
    private func answerName(_ q: NameLedger.Question, yes: Bool) {
        do {
            try NameLedger.answer(heard: q.heard, name: q.name, yes: yes)
            askNames.removeAll { $0 == q }
            msg = yes ? "記住了：「\(q.heard)」是「\(q.name)」，下一場照這個認" : "記住了：「\(q.heard)」不是「\(q.name)」，之後不會這樣改"
        } catch { msg = error.localizedDescription }
    }

    private func save() {
        guard let u = current ?? item.mdURL else { return }
        RecordMD.backupIfExists(u)
        do {
            let before = md
            try draft.write(to: u, atomically: true, encoding: .utf8); try? Mirror.copy(u); md = draft; editing = false; msg = "已存檔，原版備份成 _舊版"
            // 改了名字：記進名字確認帳（下一場自己就對）；翻譯檔不算
            if MemoryStore.isMainRecord(u) {
                let learned = NameLedger.learn(old: before, new: draft, who: "你在 Hearby 改的", mdURL: u)
                if !learned.isEmpty { msg += "；記住 \(learned.count) 個名字（" + learned.prefix(3).map { "\($0.heard)→\($0.name)" }.joined(separator: "、") + (learned.count > 3 ? "…" : "") + "），下一場自己就對" }
            }
            // 自己改了紀錄（例如人名）：記憶跟著換；翻譯檔不進記憶（sync 自己會略過）
            _ = try? MemoryStore.sync(mdURL: u)
        } catch { msg = error.localizedDescription }
    }
}

// MARK: 設定

struct SettingsPane: View {
    let actions: WindowActions
    @State private var appearance = AppearanceMode.current
    @State private var provider = ConfigStore.shared.current.provider
    @State private var memory = ConfigStore.shared.current.memoryEnabled
    @State private var autoPDF = ConfigStore.shared.current.autoPDF
    @State private var floatingBar = ConfigStore.shared.current.floatingBarOn
    @State private var mirror = ConfigStore.shared.current.mirrorDir ?? ""
    @State private var glossary = Clean.localGlossary() ?? ""
    @State private var company = ConfigStore.shared.current.docCompany ?? ""
    @State private var recorder = ConfigStore.shared.current.docRecorder ?? ""
    @State private var msg = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NeuSpace.md) {
                section("紀錄要誰寫", icon: "person.text.rectangle", tip: "錄完會先有一份逐字稿（誰講了什麼、幾分幾秒）。要變成有摘要、重點、待辦的紀錄，得有人整理。交給你付費的 Claude 或 ChatGPT，用的是帳號本來就有的額度，不另外收費，也不用申請什麼金鑰。沒有帳號就先只要逐字稿。") {
                    ProvidersPane(selected: $provider)
                }
                section("外觀", icon: "circle.lefthalf.filled", tip: "跟隨系統、淺色、深色。只影響這個 app 的長相。") {
                    HStack(spacing: NeuSpace.sm) {
                        ForEach(AppearanceMode.allCases, id: \.self) { m in
                            NeuChip(title: m.label + (appearance == m ? " ✓" : "")) { appearance = m; AppearanceMode.set(m) }
                        }
                    }
                }
                section("錄音中", icon: "waveform", tip: "面板收起來的時候，螢幕上方會有一條小狀態列：看得到在錄還是暫停、錄了幾分幾秒、麥克風有沒有收到聲音，也能直接暫停或停止。拖得動，放哪裡它會記住。選單列的 Hearby 圖示旁邊也會顯示計時。") {
                    HStack(spacing: NeuSpace.sm) {
                        NeuChip(title: floatingBar ? "螢幕上的小狀態列：開著 ✓" : "螢幕上的小狀態列：關著") {
                            floatingBar.toggle(); try? ConfigStore.shared.update { $0.floatingBar = floatingBar }
                        }
                        NeuNote(text: floatingBar ? "面板收起來就會出現；面板打開就收掉" : "只看選單列圖示旁邊的計時")
                    }
                }
                section("紀錄存在哪", icon: "folder", tip: "每一場的錄音、逐字稿、紀錄、匯出的文件，都在這個資料夾裡，一場一個子資料夾。副本資料夾＝每份紀錄再多存一份到你指定的地方（例如 iCloud 或 Dropbox 同步夾，或給你的 AI 助理讀的資料夾）。") {
                    HStack(spacing: NeuSpace.sm) {
                        Text(Paths.root.path).font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        NeuChip(title: "打開", systemImage: "folder") { actions.revealDir(Paths.root) }
                    }
                    HStack(spacing: NeuSpace.sm) {
                        field("副本資料夾（選填，貼路徑）", $mirror)
                        NeuChip(title: "存") { try? ConfigStore.shared.update { $0.mirrorDir = mirror.isEmpty ? nil : mirror }; msg = mirror.isEmpty ? "副本資料夾已清掉" : "副本資料夾已存：每份紀錄會多存一份到那裡" }
                    }
                }
                section("匯出文件（PDF、Word、Pages）", icon: "doc.richtext", tip: "要給別人看的時候用。文件是你們公司的，不會有 Hearby 的標誌。這裡填的公司名和記錄人會先填好在每次匯出的表頭，匯出前還能改。") {
                    HStack(spacing: NeuSpace.sm) {
                        field("公司名稱", $company)
                        field("記錄人", $recorder)
                        NeuChip(title: "存") { try? ConfigStore.shared.update { $0.docCompany = company.isEmpty ? nil : company; $0.docRecorder = recorder.isEmpty ? nil : recorder }; msg = "表頭預設已存" }
                    }
                    HStack(spacing: NeuSpace.sm) {
                        NeuChip(title: autoPDF ? "每場自動出 PDF ✓" : "PDF 要的時候再按") { autoPDF.toggle(); try? ConfigStore.shared.update { $0.autoPDF = autoPDF } }
                        NeuNote(text: "Word 檔（.docx）Word 和 Pages 都能直接開")
                    }
                }
                section("常用詞", icon: "textformat.abc", tip: "常出現的人名、公司名、產品名。聽寫有時會把名字寫錯，寫在這裡的會被自動改回正確寫法。") {
                    TextField("例：Kevin、Hearby、專案代號（頓號或換行分隔）", text: $glossary, axis: .vertical).textFieldStyle(.plain).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong).lineLimit(2...5)
                        .padding(NeuSpace.md).neuDebossed(NeuRadius.card, depth: 0.9)
                    HStack { NeuChip(title: "存常用詞") { do { try Clean.saveGlossary(glossary); msg = "常用詞已存" } catch { msg = "常用詞沒有存成：\(error.localizedDescription)" } }; Spacer() }
                }
                section("記憶（給有在用 Claude Code 的人）", icon: "brain", tip: "打開後，每開完一場會，Hearby 會把誰出席、談了什麼、決定了什麼、還沒做完的事，記在紀錄資料夾裡的幾個文字檔。之後你在那個資料夾用 Claude Code 問問題，它就知道你開過哪些會，不用重講一遍；下一場開錄前也會把上次沒做完的事列出來。沒在用 Claude Code 的話關著就好，紀錄照樣存。") {
                    HStack(spacing: NeuSpace.sm) {
                        NeuChip(title: memory ? "開著 ✓" : "關著") {
                            memory.toggle(); try? ConfigStore.shared.update { $0.memoryEnabled = memory }
                            if memory { try? MemoryStore.ensure(); EntryFiles.ensure() }
                        }
                        NeuNote(text: memory ? "開完會會自動記；上次沒做完的事會出現在開錄前" : "現在不記；紀錄照樣存")
                    }
                }
                section("認聲音（實驗）", icon: "person.wave.2", tip: "整理前先分出錄音裡誰在講話；記住過的人（要本人同意）會標出名字，紀錄的摘要、與會者、誰說了什麼就寫對人。聲紋只存在這台 Mac 的 Hearby 資料夾，不進紀錄、不上傳；隨時可以忘記。要 macOS 15 以上。") {
                    VoicesSettings()
                }
                section("其他", icon: "ellipsis.circle", tip: "怪怪的時候：先到「檢查」看哪一項不對；還是不行就匯出診斷檔，把桌面那個 txt 傳給我們。") {
                    HStack(spacing: NeuSpace.sm) {
                        NeuChip(title: "重新跑一次設定精靈", systemImage: "sparkles") { actions.rerunWizard() }
                        NeuChip(title: "匯出診斷檔到桌面", systemImage: "stethoscope") { if let u = actions.exportDiagnostics() { msg = "診斷檔：\(u.path)" } else { msg = "診斷檔寫不出來" } }
                    }
                }
                if !msg.isEmpty { NeuNote(text: msg).padding(.horizontal, NeuSpace.sm) }
            }
            .padding(.vertical, 2)
        }
    }

    private func field(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text).textFieldStyle(.plain).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong)
            .padding(.horizontal, NeuSpace.md).frame(height: 34).neuDebossed(NeuRadius.pill, depth: 0.9)
    }
    /// 一段設定＝一張凹陷卡：圖示＋標題＋ⓘ，下面是內容
    @ViewBuilder private func section<C: View>(_ title: String, icon: String, tip: String?, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: NeuSpace.md) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundColor(Neu.inkMid).frame(width: 18)
                Text(title).font(NeuFont.ui(NeuType.body, true)).foregroundColor(Neu.inkStrong)
                if let t = tip { InfoTip(t) }
                Spacer(minLength: 0)
            }
            c()
        }
        .padding(NeuSpace.lg).frame(maxWidth: .infinity, alignment: .leading)
        .neuDebossed(NeuRadius.card, depth: 0.7)
    }
}

/// 三排：Claude／ChatGPT／只要逐字稿，每排＝選用點、名稱、狀態、主動作
public struct ProvidersPane: View {
    @Binding var selected: String
    var compact = false
    /// 精靈只放三排（兩種訂閱＋只要逐字稿）；本機模型是延伸選項，只在設定頁出現
    var showEndpoint = true
    @State private var refreshing = false
    @ObservedObject private var cInstall = ClaudeInstall.shared
    @ObservedObject private var cLogin = ClaudeLogin.shared
    @ObservedObject private var xInstall = CodexInstall.shared
    @ObservedObject private var xLogin = CodexLogin.shared
    @State private var status: [String: ProviderStatus] = [:]
    @State private var code = ""
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    public init(selected: Binding<String>, compact: Bool = false, showEndpoint: Bool = true) {
        self._selected = selected; self.compact = compact; self.showEndpoint = showEndpoint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NeuSpace.sm) {
            row("claude", title: "交給我的 Claude 整理", sub: "要有 Claude 的付費帳號（Pro 或 Max）。按下去會幫你裝好、開瀏覽器登入。")
            row("codex", title: "交給我的 ChatGPT 整理", sub: "要有 ChatGPT 的付費帳號（Plus 或 Pro）。按下去會幫你裝好、開瀏覽器登入。")
            if showEndpoint {
                row("endpoint", title: "交給本機模型整理（Ollama／LM Studio）", sub: "不用帳號、內容不離開這台電腦：用你自己裝的模型，建議 16 GB 以上記憶體。整理得比 Claude／ChatGPT 簡略，決議與待辦請自己再看一次。")
                if selected == "endpoint" { EndpointForm(onSaved: refresh) }
            }
            row("none", title: "先只要逐字稿", sub: "不用任何帳號。有誰講了什麼、幾分幾秒；之後想改隨時可以。")
            flowLine
        }
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }

    private func row(_ id: String, title: String, sub: String) -> some View {
        let st = status[id] ?? ProviderStatus(.pending, "檢查中…")
        let on = selected == id
        let dot = ZStack {
            Circle().strokeBorder(on ? Neu.inkStrong : Neu.inkSoft, lineWidth: 1.2).frame(width: 18, height: 18)
            if on { Circle().fill(Neu.inkStrong).frame(width: 9, height: 9) }
        }
        let text = VStack(alignment: .leading, spacing: 2) {
            Text(title).font(NeuFont.ui(NeuType.body, on)).foregroundColor(Neu.inkStrong)
            Text(sub).font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkMid).fixedSize(horizontal: false, vertical: true)
        }
        return Group {
            if compact {
                // 窄版（精靈 480）：兩行——第一行點＋名稱，第二行狀態＋動作
                VStack(alignment: .leading, spacing: NeuSpace.sm) {
                    HStack(alignment: .top, spacing: NeuSpace.md) { dot.padding(.top, 2); text; Spacer(minLength: 0) }
                    HStack(spacing: NeuSpace.sm) {
                        NeuStatusTag(level: level(st.level), text: st.text)
                        Spacer(minLength: 0)
                        if let a = st.action { NeuChip(title: a) { perform(id, st) } }
                    }
                    .padding(.leading, 18 + NeuSpace.md)
                }
            } else {
                HStack(alignment: .center, spacing: NeuSpace.md) {
                    dot; text
                    Spacer(minLength: NeuSpace.md)
                    NeuStatusTag(level: level(st.level), text: st.text).frame(width: 200, alignment: .trailing)
                    if let a = st.action { NeuChip(title: a) { perform(id, st) }.frame(width: 110) } else { Color.clear.frame(width: 110, height: 1) }
                }
            }
        }
        .padding(.horizontal, NeuSpace.lg).padding(.vertical, NeuSpace.md)
        .contentShape(Rectangle())
        .onTapGesture { select(id) }
        .modifier(RowSurface(on: on))
    }
    private struct RowSurface: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View { Group { if on { content.neuDebossed(NeuRadius.card, depth: 0.9) } else { content.neuRaised(NeuRadius.card, lift: 0.5) } } }
    }
    private func level(_ l: ProviderStatus.Level) -> NeuStatusTag.Level {
        switch l { case .ready: return .ready; case .pending: return .pending; case .missing: return .missing }
    }
    private func select(_ id: String) {
        selected = id
        Connect.select(id)
        if let st = status[id], st.level != .ready, id != "none" { perform(id, st) }
    }
    private func perform(_ id: String, _ st: ProviderStatus) {
        switch (id, st.level) {
        case ("claude", .missing): if !ClaudeInstall.shared.start() { _ = Connect.runInTerminal(Connect.claudeInstallCommand) }
        case ("claude", .pending): ClaudeCLI.resetAuthCache(); if !ClaudeLogin.shared.start() { _ = Connect.runInTerminal("\(EntryFiles.shellQuote(ClaudeCLI.binaryPath() ?? "claude")) auth login") }
        case ("codex", .missing): _ = CodexInstall.shared.start()
        case ("codex", .pending): CodexCLI.resetLoginCache(); _ = CodexLogin.shared.start()
        default: break
        }
    }
    @ViewBuilder private var flowLine: some View {
        let line: String? = {
            if cInstall.running || cInstall.failed { return cInstall.note }
            if cLogin.running || !cLogin.note.isEmpty { return cLogin.note }
            if xInstall.running || xInstall.failed { return xInstall.note }
            if xLogin.running || !xLogin.note.isEmpty { return xLogin.note }
            return nil
        }()
        if let l = line {
            VStack(alignment: .leading, spacing: NeuSpace.sm) {
                Text(l).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong).fixedSize(horizontal: false, vertical: true)
                if cInstall.running || xInstall.running { NeuGroove(fill: xInstall.running ? CGFloat(xInstall.fraction) : nil, height: 10) }
                HStack(spacing: NeuSpace.sm) {
                    if cLogin.running, cLogin.needsCode {
                        TextField("貼上網頁給的代碼", text: $code).textFieldStyle(.plain).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong)
                            .padding(.horizontal, NeuSpace.md).frame(height: 32).neuDebossed(NeuRadius.pill, depth: 0.9)
                        NeuChip(title: "送出") { cLogin.submit(code: code) }
                    }
                    if cLogin.running, cLogin.url != nil { NeuChip(title: "瀏覽器沒開？再開一次") { cLogin.openBrowserAgain() } }
                    if xLogin.running, xLogin.url != nil { NeuChip(title: "瀏覽器沒開？再開一次") { xLogin.openBrowserAgain() } }
                    if cInstall.running { NeuChip(title: "取消") { cInstall.cancel() } }
                    if cLogin.running { NeuChip(title: "取消") { cLogin.cancel() } }
                    if xInstall.running { NeuChip(title: "取消") { xInstall.cancel() } }
                    if xLogin.running { NeuChip(title: "取消") { xLogin.cancel() } }
                    Spacer()
                }
            }
            .padding(NeuSpace.md).neuDebossed(NeuRadius.card, depth: 0.7)
        }
    }
    private func refresh() {
        // 每 3 秒一輪；上一輪還沒查完（本機模型要連網路問）就不疊上去。本機模型沒選就不去連
        guard !refreshing else { return }
        refreshing = true
        let wantEndpoint = showEndpoint && selected == "endpoint"
        DispatchQueue.global(qos: .userInitiated).async {
            var s: [String: ProviderStatus] = [:]
            for p in Providers.all where p.id != "endpoint" || wantEndpoint { s[p.id] = p.check() }
            if s["endpoint"] == nil { s["endpoint"] = ProviderStatus(.pending, "點一下設定位址與模型") }
            let cur = ConfigStore.shared.current.provider
            DispatchQueue.main.async { status = s; refreshing = false; if selected != cur { selected = cur } }
        }
    }
}

/// 本機模型：位址＋從端點讀到的模型清單＋存。還沒裝的人給一句怎麼裝
struct EndpointForm: View {
    var onSaved: () -> Void
    @State private var url = ConfigStore.shared.current.endpointURL ?? LocalEndpoint.defaultURL
    @State private var model = ConfigStore.shared.current.endpointModel ?? ""
    @State private var models: [String] = []
    @State private var msg = ""
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: NeuSpace.sm) {
            HStack(spacing: NeuSpace.sm) {
                TextField("位址（Ollama：http://127.0.0.1:11434；LM Studio：http://127.0.0.1:1234）", text: $url)
                    .textFieldStyle(.plain).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong)
                    .padding(.horizontal, NeuSpace.md).frame(height: 34).neuDebossed(NeuRadius.pill, depth: 0.9)
                NeuChip(title: loading ? "讀取中…" : "讀取模型", systemImage: "arrow.clockwise", enabled: !loading) { load() }
            }
            HStack(spacing: NeuSpace.sm) {
                Menu {
                    ForEach(models, id: \.self) { m in Button(m) { model = m } }
                } label: {
                    Text(model.isEmpty ? (models.isEmpty ? "先按「讀取模型」" : "選一個模型") : model)
                        .font(NeuFont.ui(NeuType.body)).foregroundColor(model.isEmpty ? Neu.inkMid : Neu.inkStrong).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .disabled(models.isEmpty)
                .padding(.horizontal, NeuSpace.md).frame(height: 34).frame(maxWidth: .infinity, alignment: .leading)
                .neuDebossed(NeuRadius.pill, depth: 0.9)
                NeuChip(title: "存", enabled: !model.isEmpty) { save() }
            }
            NeuNote(text: msg.isEmpty ? Self.hint : msg)
        }
        .padding(.horizontal, NeuSpace.lg).padding(.vertical, NeuSpace.sm)
        .onAppear { load() }
    }

    static var hint: String {
        var t = "還沒裝的話：到 ollama.com 下載 Ollama，再在終端機打「ollama pull \(LocalEndpoint.suggestedModel)」（約 2.5 GB），回來按「讀取模型」。"
        if LocalEndpoint.memoryIsTight { t += "這台電腦的記憶體不到 16 GB：本機模型會跑得很慢，開會時最好不要讓它同時整理。" }
        return t
    }

    private func load() {
        loading = true
        let u = url
        DispatchQueue.global(qos: .userInitiated).async {
            let bad = LocalEndpoint.urlProblem(u)
            let r = bad == nil ? LocalEndpoint.listModels(u, timeout: 3) : nil
            DispatchQueue.main.async {
                loading = false
                if let bad { msg = bad; models = []; return }
                guard let r else { msg = "連不上 \(u)——Ollama 或 LM Studio 有開著嗎？"; models = []; return }
                models = r.models
                if model.isEmpty || !r.models.contains(model) {
                    model = r.models.first(where: { $0 == LocalEndpoint.suggestedModel }) ?? r.models.first ?? ""
                }
                msg = r.models.isEmpty ? "連上了，但裡面還沒有模型。" + Self.hint : "連上了（\(r.flavor == .ollama ? "Ollama" : "OpenAI 相容端點")），有 \(r.models.count) 個模型。選好按「存」。"
            }
        }
    }

    private func save() {
        if let bad = LocalEndpoint.urlProblem(url) { msg = bad; return }
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        try? ConfigStore.shared.update { $0.endpointURL = u == LocalEndpoint.defaultURL ? nil : u; $0.endpointModel = model }
        msg = "已存：之後的會議交給「\(model)」整理。"
        onSaved()
    }
}

// MARK: 檢查

struct StatusPane: View {
    let actions: WindowActions
    @State private var report: DoctorReport? = nil
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: NeuSpace.md) {
            HStack {
                Text("現在正不正常").font(NeuFont.ui(NeuType.title, true)).foregroundColor(Neu.inkStrong)
                Spacer()
                NeuChip(title: busy ? "檢查中…" : "重新檢查", enabled: !busy) {
                    busy = true
                    DispatchQueue.global(qos: .userInitiated).async { let r = actions.runDoctorDeep(); DispatchQueue.main.async { report = r; busy = false } }
                }
            }
            if let r = report {
                VStack(alignment: .leading, spacing: NeuSpace.sm) {
                    ForEach(Array(r.items.enumerated()), id: \.offset) { _, i in NeuStatusTag(level: level(i.status), text: "\(i.name)：\(i.detail)") }
                }
                .padding(NeuSpace.md).frame(maxWidth: .infinity, alignment: .leading).neuDebossed(NeuRadius.card, depth: 0.9)
            } else { NeuNote(text: "按「重新檢查」") }
            NeuNote(text: "紀錄檔：\(HearbyLog.file.path)")
        }
        .onAppear { if report == nil { report = Doctor.run(deep: false) } }
    }
    private func level(_ s: DoctorItem.Status) -> NeuStatusTag.Level {
        switch s { case .ok: return .ready; case .warn, .unknown: return .pending; case .missing: return .missing }
    }
}
