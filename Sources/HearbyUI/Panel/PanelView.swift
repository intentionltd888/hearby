// PanelView — 浮動小面板（Apple 內建視窗框，可拖可縮）；四態各回答一個問題
//   待命：這場是會議還是筆記、線上還是同一個房間、開始、上一場、會前準備
//   錄音中：兩條波形、計時、停止、只在出事時才出現的一行
//   處理中：階段＋逐字稿邊轉邊出
//   剛完成：標題、三行重點、三顆鈕
import HearbyCore
import SwiftUI

public struct PanelView: View {
    @ObservedObject var m: PanelModel
    @ObservedObject private var theme = Theme.shared

    public init(model: PanelModel) { self.m = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: NeuSpace.lg) {
            header
            Group {
                switch m.phase {
                case .idle: idle
                case .recording: recording
                case .processing: processing
                case .done: done
                case .error: errorView
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
            PoweredBy(showWordmark: false)
        }
        .padding(NeuSpace.edge)
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity, alignment: .top)
        .background(Neu.material)
        .id(theme.mode)
    }

    private var header: some View {
        HStack {
            HearbyLogotype(height: 13, color: Neu.inkMid)
            Spacer()
            if m.phase == .recording { HearbyMark(mode: .listening, size: 9).frame(width: 20, height: 20) }
            Text(m.phase.label).font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkSoft)
            // 兩顆各管一件事：疊片＝紀錄、齒輪＝設定（只有疊片一顆時，找不到設定在哪）
            NeuIconButton(systemName: "rectangle.stack", size: 24) { m.onOpenWindow() }
                .help("看以前的紀錄")
            NeuIconButton(systemName: "gearshape", size: 24) { m.onOpenSettings() }
                .help("設定")
        }
    }

    // MARK: 待命
    // 版面：① 情境三段 ② 線上／同房一列 ③ 這場要談什麼（一個輸入框，永遠在）④ 大圓鈕居中
    // ⑤ 底部一列次要動作：上一場（左，文字）／匯入（右，圖示）
    private var idle: some View {
        VStack(alignment: .leading, spacing: NeuSpace.md) {
            NeuSegmented(items: RecordScene.allCases.map(\.label), selection: $m.scene)
            HStack(spacing: NeuSpace.sm) {
                NeuChip(title: m.online ? "線上會議 ✓" : "同一個房間 ✓") { m.online.toggle() }
                Text(m.online ? "也會錄對方講的話" : "只錄麥克風").font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkSoft)
                Spacer(minLength: 0)
                InfoTip(m.online ? "用 Meet、Teams、Zoom 這類線上會議時選這個：除了你的麥克風，電腦裡對方講的話也會錄進來。第一次用系統會問一次「系統聲音」，按允許就好。" : "大家都在同一個房間就選這個：只用麥克風，不需要任何別的權限。點一下可以切換成線上會議。")
            }
            briefField
            if !m.modelReady {
                if let f = m.downloadFraction {
                    HStack(spacing: NeuSpace.sm) {
                        NeuGroove(fill: CGFloat(f), height: 8)
                        Text(String(format: "聽打模型 %.0f%%", f * 100)).font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkMid)
                    }
                    if !m.downloadNote.isEmpty { NeuNote(text: m.downloadNote) }
                } else {
                    HStack(spacing: NeuSpace.sm) {
                        NeuNote(text: m.downloadNote.isEmpty ? "聽打模型還沒下載（1.6 GB，一次就好）" : m.downloadNote)
                        NeuChip(title: "下載") { m.onDownloadModel() }
                    }
                }
            }
            Spacer(minLength: NeuSpace.sm)
            HStack { Spacer(); NeuAnchorButton(glyph: .dot, size: 92) { m.onStart() }; Spacer() }
            Text(RecordScene.allCases[min(max(m.scene, 0), RecordScene.allCases.count - 1)].hint)
                .font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkSoft).frame(maxWidth: .infinity)
            Spacer(minLength: NeuSpace.sm)
            if !m.pendingRecoveries.isEmpty {
                let r = m.pendingRecoveries[0]
                HStack(spacing: NeuSpace.sm) {
                    NeuNote(text: "有 \(m.pendingRecoveries.count) 場錄音還沒整理（\(Fmt.dur(r.seconds))）")
                    Spacer(minLength: 0)
                    NeuChip(title: "補整理") { m.onRecover(r) }
                    NeuChip(title: "略過") { m.onIgnoreRecovery(r) }
                }
            }
            HStack(spacing: NeuSpace.sm) {
                if let last = m.lastMeeting {
                    Button { if let u = last.mdURL { m.onOpenMD(u) } else { m.onOpenWindow() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .medium))
                            Text("上一場　\(last.title)").lineLimit(1)
                        }
                        .font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid)
                    }
                    .buttonStyle(.plain)
                    .help("打開上一場的紀錄")
                }
                Spacer(minLength: NeuSpace.sm)
                // 匯入：字＋圓鈕，跟右上角「待命＋圓鈕」同一個句型（平的字、凸的鈕）；字也能按。
                // 只有圖示時看不出這顆是匯入，
                // 而聽打備註寫的就是「可用『匯入音檔』重跑」——畫面上要找得到這四個字。
                // fixedSize＝上一場的標題再長也是它截斷，匯入不被擠。
                HStack(spacing: NeuSpace.sm) {
                    Button { m.onImport() } label: {
                        Text("匯入音檔").font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid)
                    }
                    .buttonStyle(.plain)
                    NeuIconButton(systemName: "square.and.arrow.down", size: 26) { m.onImport() }
                }
                .fixedSize()
                .help("已經有錄好的音檔或影片？丟進來一樣能整理")
            }
        }
    }

    /// 這場要談什麼：一個永遠在的輸入框；有上次沒完成的事就在下面列「帶入」
    private var briefField: some View {
        VStack(alignment: .leading, spacing: NeuSpace.sm) {
            HStack(alignment: .top, spacing: NeuSpace.sm) {
                TextField(m.scene == 2 ? "這篇要講什麼？（可不填；第一行會變成標題）" : m.scene == 1 ? "這場採訪的主題？（可不填；第一行會變成標題）" : "這場要談什麼？（可不填；第一行會變成標題）", text: $m.brief, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4)
                    .font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong)
                InfoTip("可以不填。寫了的話，第一行會變成這份紀錄的標題，整理時也會特別留意跟它有關的內容。一行一件事。")
            }
            .padding(.horizontal, NeuSpace.md).padding(.vertical, NeuSpace.sm)
            .neuDebossed(NeuRadius.card, depth: 0.9)
            if !m.suggestedBrief.isEmpty {
                ForEach(m.suggestedBrief.prefix(3), id: \.self) { s in
                    HStack(spacing: 6) {
                        Text("· " + s).font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid).lineLimit(1)
                        Spacer()
                        NeuChip(title: "帶入") { m.brief += (m.brief.isEmpty ? "" : "\n") + s }
                    }
                }
            }
        }
    }

    // MARK: 錄音中（版面：上下置中——計時器居中、兩條聲音、出事才出現的一行、停止鈕＋一句說明）
    private var recording: some View {
        VStack(spacing: NeuSpace.lg) {
            Spacer(minLength: 0)
            VStack(spacing: NeuSpace.xs) {
                HearbyMark(mode: .listening, size: 11).frame(width: 26, height: 26)
                Text(m.elapsedText).font(NeuFont.mark(48)).foregroundColor(Neu.inkStrong)
                    .contentTransition(.numericText()).animation(NeuMotion.ui, value: m.elapsedText)
                Text("正在錄").font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkSoft)
            }
            VStack(spacing: NeuSpace.sm) {
                waveRow(label: "麥克風", data: m.micHistory, dim: false)
                if m.online { waveRow(label: "電腦裡", data: m.sysHistory, dim: !m.sysActive) }
            }
            if let n = m.noticeLine {
                Text(n).font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid).multilineTextAlignment(.center).transition(.opacity)
            }
            ForEach(m.alerts, id: \.self) { a in
                Text(a).font(NeuFont.ui(NeuType.caption, true)).foregroundColor(Neu.inkStrong)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(NeuSpace.md).frame(maxWidth: .infinity).neuDebossed(NeuRadius.card, depth: 0.8)
            }
            Spacer(minLength: 0)
            VStack(spacing: NeuSpace.sm) {
                NeuAnchorButton(glyph: .square, size: 84) { m.onStop() }
                Text("按一下停止，接著會自動整理").font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkSoft)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
    private func waveRow(label: String, data: [Float], dim: Bool) -> some View {
        HStack(spacing: NeuSpace.sm) {
            Text(label).font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkSoft).frame(width: 44, alignment: .leading)
            Waveform(levels: data, dim: dim).frame(height: 22)
        }
    }

    // MARK: 處理中
    private var processing: some View {
        VStack(alignment: .leading, spacing: NeuSpace.sm) {
            ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                NeuStageRow(title: s, done: i < currentStage, active: i == currentStage)
            }
            if !m.stageText.isEmpty { NeuNote(text: m.stageText) }
            if !m.partial.isEmpty {
                Text(m.partial).font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkMid)
                    .lineLimit(6).fixedSize(horizontal: false, vertical: true)
                    .padding(NeuSpace.md).frame(maxWidth: .infinity, alignment: .leading)
                    .neuDebossed(NeuRadius.card, depth: 0.8)
                    .animation(NeuMotion.ui, value: m.partial)
            }
            NeuNote(text: "整理中不要闔上筆電：闔上就暫停，打開才會繼續。可以先關掉這個視窗去做別的事，整理好會跳通知。")
        }
    }
    private let stages = ["聽打", "清理", "整理", "存檔"]
    private var currentStage: Int {
        let t = m.stageText
        if t.contains("存檔") { return 3 }
        if t.contains("整理") { return 2 }
        if t.contains("壓製") || t.contains("逐字稿版") { return 1 }
        return 0
    }

    // MARK: 剛完成（版面：人看的標題＋日期、三行重點卡、主鈕「打開這份紀錄」、兩顆次要鈕、底下一行回到待命）
    private var done: some View {
        let (dateText, human) = MeetingIndex.split(folderName: m.doneTitle)
        return VStack(alignment: .leading, spacing: NeuSpace.lg) {
            HStack(alignment: .top, spacing: NeuSpace.sm) {
                HearbyMark(mode: .flash, size: 12).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(human.isEmpty ? (m.doneTitle.isEmpty ? "整理好了" : m.doneTitle) : human)
                        .font(NeuFont.ui(NeuType.title, true)).foregroundColor(Neu.inkStrong).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(dateText.isEmpty ? "整理好了" : "整理好了　\(dateText)").font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkSoft)
                }
            }
            if !m.doneLines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(m.doneLines, id: \.self) { l in
                        Text("· " + l).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(NeuSpace.lg).frame(maxWidth: .infinity, alignment: .leading)
                .neuDebossed(NeuRadius.card, depth: 0.9)
            }
            if !m.doneNote.isEmpty { NeuNote(text: m.doneNote) }
            if let md = m.doneMD {
                VStack(spacing: NeuSpace.sm) {
                    NeuCapsuleButton(title: "打開這份紀錄", height: 44) { m.onOpenMD(md) }
                    HStack(spacing: NeuSpace.sm) {
                        NeuCapsuleButton(title: "存成 PDF／Word", height: 40) { m.onExportPDF(md) }
                        if m.claudeReady { NeuCapsuleButton(title: "接著跟 Claude 討論", height: 40) { m.onContinueClaude(md) } }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack { Spacer(); Button { m.onDismiss() } label: { Text("回到待命").font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid) }.buttonStyle(.plain); Spacer() }
        }
    }

    private var errorView: some View {
        VStack(alignment: .leading, spacing: NeuSpace.md) {
            Text("有個問題").font(NeuFont.ui(NeuType.title, true)).foregroundColor(Neu.inkStrong)
            Text(m.errorText).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong).fixedSize(horizontal: false, vertical: true)
                .padding(NeuSpace.lg).frame(maxWidth: .infinity, alignment: .leading).neuDebossed(NeuRadius.card, depth: 0.9)
            if m.errorText.contains("麥克風") {
                NeuCapsuleButton(title: "打開系統設定的麥克風", height: 40) {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
                }
            }
            NeuCapsuleButton(title: "我知道了", height: 40) { m.onDismiss() }
            Spacer(minLength: 0)
        }
    }
}

/// 波形：最近 40 格音量的細長條（房間裡／電腦裡各一條；沒動就是出事）
public struct Waveform: View {
    public var levels: [Float]
    public var dim = false
    public init(levels: [Float], dim: Bool = false) { self.levels = levels; self.dim = dim }
    public var body: some View {
        GeometryReader { geo in
            let n = PanelModel.waveSlots
            let w = geo.size.width / CGFloat(n)
            HStack(alignment: .center, spacing: 0) {
                ForEach(0..<n, id: \.self) { i in
                    let idx = i - (n - levels.count)
                    let v = idx >= 0 && idx < levels.count ? CGFloat(levels[idx]) : 0
                    Capsule().fill(dim ? Neu.inkSoft : Neu.inkStrong)
                        .frame(width: max(1.5, w * 0.55), height: max(2, geo.size.height * min(1, v * 1.4)))
                        .frame(width: w)
                        .animation(.linear(duration: 0.1), value: v)
                }
            }
            .frame(height: geo.size.height)
        }
        .padding(.horizontal, NeuSpace.sm).padding(.vertical, 3)
        .neuDebossed(NeuRadius.pill, depth: 0.8)
    }
}
