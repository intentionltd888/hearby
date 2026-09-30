// WizardView — 首次打開：歡迎（海報式）→ 讓它聽得到（麥克風／線上開會，兩列同層級）→ 紀錄要誰寫（三排）→ 試一次 → 好了
import AVFoundation
import AppKit
import HearbyCore
import SwiftUI
import UserNotifications

public struct WizardView: View {
    let onFinish: () -> Void
    let onDownloadModel: () -> Void
    @ObservedObject var panel: PanelModel
    @ObservedObject private var theme = Theme.shared
    @State private var step: Int
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    /// 授權狀態要放進 @State：按了「不允許」之後狀態從 notDetermined 變 denied，畫面要跟著換按鈕（不然永遠停在沒反應的「允許」）
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var online = ConfigStore.shared.current.online
    @State private var provider = ConfigStore.shared.current.provider
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    static let total = 4

    public init(onFinish: @escaping () -> Void, onDownloadModel: @escaping () -> Void, panel: PanelModel) {
        self.onFinish = onFinish; self.onDownloadModel = onDownloadModel; self.panel = panel
        _step = State(initialValue: min(Self.total, max(0, ConfigStore.shared.current.wizardStep)))
    }

    public var body: some View {
        Group {
            if step == 0 { welcome } else {
                VStack(alignment: .leading, spacing: NeuSpace.lg) {
                    header
                    Group {
                        switch step {
                        case 1: permissions
                        case 2: providers
                        case 3: trial
                        default: finish
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    footer
                }
                .padding(NeuSpace.xl)
                .background(Neu.stage)
            }
        }
        .frame(width: 480, height: 640, alignment: .top)
        .id(theme.mode)
        .onChange(of: step) { _, s in try? ConfigStore.shared.update { $0.wizardStep = s } }
        .onReceive(tick) { _ in
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            micGranted = micStatus == .authorized
        }
    }

    private var header: some View {
        HStack {
            Text("\(step) / \(Self.total)").font(NeuFont.mark(NeuType.micro, false)).foregroundColor(Neu.inkSoft)
            Spacer()
            HearbyLogotype(height: 15, color: Neu.inkMid)
        }
    }
    private var footer: some View {
        VStack(spacing: NeuSpace.md) {
            if let f = panel.downloadFraction {
                HStack(spacing: NeuSpace.sm) {
                    NeuGroove(fill: CGFloat(f), height: 8)
                    Text(String(format: "聽打模型 %.0f%%", f * 100)).font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkMid)
                }
            } else if !panel.modelReady, !panel.downloadNote.isEmpty {
                // 下載失敗或在等網路：原因要看得到、要有一顆能再試的鈕（以前進度條直接消失，什麼都不說）
                HStack(spacing: NeuSpace.sm) {
                    NeuNote(text: panel.downloadNote)
                    NeuChip(title: "再試一次") { onDownloadModel() }
                }
            }
            PoweredBy(showWordmark: false)
        }
    }
    private func nav(next: String = "下一步", canSkip: Bool = false, nextEnabled: Bool = true, reason: String? = nil, action: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: NeuSpace.sm) {
            if !nextEnabled, let r = reason { NeuNote(text: r) }
            HStack(spacing: NeuSpace.md) {
                if step > 0 { NeuIconButton(systemName: "chevron.left", size: 30) { withAnimation(NeuMotion.ui) { step -= 1 } } }
                if canSkip { NeuChip(title: "先跳過") { withAnimation(NeuMotion.ui) { step += 1 } } }
                NeuCapsuleButton(title: next, enabled: nextEnabled) { if let a = action { a() } else { withAnimation(NeuMotion.ui) { step += 1 } } }
            }
        }
    }
    private func heading(_ t: String, mark: HearbyMark.Mode? = .idle) -> some View {
        HStack(spacing: NeuSpace.md) {
            if let m = mark { HearbyMark(mode: m, size: 15).frame(width: 34, height: 34) }
            Text(t).font(NeuFont.ui(NeuType.hero, true)).foregroundColor(Neu.inkStrong)
        }
    }

    // 0 歡迎：照片海報（棚拍底圖）——上 400pt 照片滿版（字標蓋在左上空白處），下 240pt 材料塊放兩句話與「開始設定」。
    // 照片是淺灰棚拍，深淺外觀都直接用；字標與小字的顏色固定深灰（跟照片走，不跟主題走）。
    private var welcome: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let img = Brand.wizardHero {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 480, height: 400, alignment: .top).clipped()
                } else {
                    Neu.stage.frame(width: 480, height: 400)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("MEETING RECORDER FOR MACOS").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(Color(white: 0.38)).tracking(1)
                    HearbyLogotype(height: 50, color: Color(white: 0.10))
                }
                .padding(.leading, 36).padding(.top, 42)
            }
            .frame(width: 480, height: 400)
            VStack(alignment: .leading, spacing: 0) {
                Text("開會按一下，結束就有一份紀錄。").font(NeuFont.ui(20, true)).foregroundColor(Neu.inkStrong)
                Spacer().frame(height: 8)
                Text("錄音、聽寫、整理成紀錄，都在你自己的電腦上完成。").font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkMid).fixedSize(horizontal: false, vertical: true)
                Spacer()
                HStack(alignment: .center, spacing: NeuSpace.md) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text("Powered by").font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkSoft)
                            IntentionWordmark(height: 8.5)
                        }
                        Text(HearbyVersion.version).font(NeuFont.mark(NeuType.micro, false)).foregroundColor(Neu.inkSoft)
                    }
                    Spacer()
                    NeuCapsuleButton(title: "開始設定", height: 46) {
                        if !panel.modelReady, panel.downloadFraction == nil { onDownloadModel() }
                        DispatchQueue.global(qos: .userInitiated).async { _ = Providers.autoPick() }
                        withAnimation(NeuMotion.ui) { step = 1 }
                    }
                    .frame(width: 180)
                }
            }
            .padding(.horizontal, 36).padding(.top, 30).padding(.bottom, 28)
            .frame(width: 480, height: 240, alignment: .topLeading)
            .background(Neu.material)
        }
        .frame(width: 480, height: 640)
        .background(Neu.material)
    }

    // 1 讓它聽得到：兩列同層級
    private var permissions: some View {
        let status = micStatus
        let micBlocked = status == .denied || status == .restricted
        return VStack(alignment: .leading, spacing: NeuSpace.lg) {
            heading("讓它聽得到")
            Text("要錄音，先讓它用麥克風。").font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkMid)
            permRow(title: "麥克風", detail: "錄下你和同一個房間裡的人講的話。一定要。", ok: micGranted, okText: "已允許",
                    actionTitle: status == .notDetermined ? "允許" : "去系統設定") {
                if status == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
                else if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
            }
            permRow(title: "線上開會", detail: online ? "用 Meet、Teams、Zoom 開會時，對方講的話也會錄進來。第一次用系統會問一次「系統聲音」，按允許就好。" : "會用 Meet、Teams、Zoom 這類線上會議嗎？勾了之後對方講的話也會錄進來。只在同一個房間開會就不用。",
                    ok: online, okText: "會用", actionTitle: "我會線上開會") {
                online = true; try? ConfigStore.shared.update { $0.online = true }
            }
            if online {
                HStack { Spacer(); NeuChip(title: "改成只在同一個房間") { online = false; try? ConfigStore.shared.update { $0.online = false } } }
            }
            // 拒絕過麥克風也要有路走：只想整理現成錄音的人用不到麥克風；精靈走不完的話每次打開都只會再看到精靈
            if micBlocked {
                NeuNote(text: "麥克風目前是關的。要錄音：按「去系統設定」打開 Hearby，再回來。只想整理現成的錄音檔：可以直接下一步，之後用「匯入音檔」。")
            }
            Spacer()
            nav(nextEnabled: micGranted || micBlocked, reason: "麥克風打勾之後才能下一步。")
        }
    }
    private func permRow(title: String, detail: String, ok: Bool, okText: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: NeuSpace.md) {
            HearbyMark(mode: ok ? .idle : .listening, size: 11).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(NeuFont.ui(NeuType.body, true)).foregroundColor(Neu.inkStrong)
                Text(detail).font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: NeuSpace.md)
            if ok {
                HStack(spacing: 6) {
                    Text(okText).font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid)
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .medium)).foregroundColor(Neu.inkStrong)
                }
            } else { NeuChip(title: actionTitle, action: action) }
        }
        .padding(.horizontal, NeuSpace.lg).padding(.vertical, NeuSpace.md)
        .neuDebossed(NeuRadius.card, depth: 0.9)
    }

    // 2 紀錄要誰寫：三排
    private var providers: some View {
        VStack(alignment: .leading, spacing: NeuSpace.lg) {
            heading("紀錄要誰寫")
            Text("錄完會先有一份逐字稿。要變成有摘要、重點、待辦的紀錄，得有人整理。你有付費的 Claude 或 ChatGPT 帳號就交給它，用的是帳號本來就有的額度，不另外收費；沒有就先只要逐字稿，之後隨時可以改。")
                .font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkMid).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                ProvidersPane(selected: $provider, compact: true, showEndpoint: false)
                Text("有自己裝的本機模型（Ollama、LM Studio）？之後到「設定 → 紀錄要誰寫」接上就好。")
                    .font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkSoft).frame(maxWidth: .infinity, alignment: .leading).padding(.top, NeuSpace.xs)
            }
            nav()
        }
    }

    // 3 試一次
    private var trial: some View {
        VStack(alignment: .leading, spacing: NeuSpace.lg) {
            heading("試一次", mark: panel.phase == .recording ? .listening : (panel.phase == .done ? .flash : .idle))
            MenuBarHint()
            VStack(alignment: .leading, spacing: NeuSpace.sm) {
                Text("1  按選單列的 ”，會跳出一個小面板").font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong)
                Text("2  按中間的大圓，隨便講兩句話").font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong)
                Text("3  再按一次大圓，等半分鐘，紀錄就整理好了").font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong)
            }
            .padding(NeuSpace.lg).frame(maxWidth: .infinity, alignment: .leading).neuDebossed(NeuRadius.card, depth: 0.9)
            if !panel.modelReady {
                if let f = panel.downloadFraction { NeuNote(text: String(format: "聽寫模型（把聲音變成文字用的）下載中 %.0f%%，好了才能錄；可以先按下一步。", f * 100)) }
                else { HStack(spacing: NeuSpace.sm) { NeuNote(text: panel.downloadNote.isEmpty ? "聽寫模型還沒下載（1.6 GB，一次就好）。" : panel.downloadNote); NeuChip(title: "下載") { onDownloadModel() } } }
            }
            switch panel.phase {
            case .recording: NeuNote(text: "聽到了，講吧。講完按停止。")
            case .processing: NeuNote(text: "整理中：\(panel.stageText)")
            case .done:
                VStack(alignment: .leading, spacing: 4) {
                    Text("成功了。").font(NeuFont.ui(NeuType.title, true)).foregroundColor(Neu.inkStrong)
                    ForEach(panel.doneLines, id: \.self) { Text("· " + $0).font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid) }
                }
            default: EmptyView()
            }
            Spacer()
            nav(next: panel.phase == .done ? "最後一頁" : "下一步", canSkip: panel.phase != .done)
        }
    }

    // 好了
    private var readiness: [(String, Bool, String)] {
        let p = Providers.current()
        let st = p.check()
        return [
            ("麥克風", micGranted, micGranted ? "已允許" : "沒允許：聽不到你"),
            ("聽寫模型", panel.modelReady || panel.downloadFraction != nil, panel.modelReady ? "已下載（把聲音變成文字用的）" : (panel.downloadFraction.map { String(format: "下載中 %.0f%%", $0 * 100) } ?? "還沒下載")),
            ("紀錄要誰寫", st.level == .ready, "\(p.displayName)：\(st.text)"),
            ("紀錄存在", true, Paths.root.path),
        ]
    }
    private var finish: some View {
        let rows = readiness
        let missing = rows.filter { !$0.1 }.count
        return VStack(alignment: .leading, spacing: NeuSpace.lg) {
            heading(missing == 0 ? "好了" : "還缺 \(missing) 樣")
            Text("以後就這樣用：開會前按選單列的 ” 再按大圓，結束再按一次。紀錄會自己存好。").font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkMid).fixedSize(horizontal: false, vertical: true)
            MenuBarHint(caption: false)
            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .center, spacing: NeuSpace.sm) {
                        Image(systemName: r.1 ? "checkmark" : "minus").font(.system(size: 11, weight: .semibold)).foregroundColor(r.1 ? Neu.inkStrong : Neu.inkSoft).frame(width: 14)
                        Text(r.0).font(NeuFont.ui(NeuType.caption, true)).foregroundColor(Neu.inkStrong).frame(width: 76, alignment: .leading)
                        Text(r.2).font(NeuFont.ui(NeuType.micro)).foregroundColor(r.1 ? Neu.inkMid : Neu.inkStrong).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, NeuSpace.md).padding(.vertical, 6)
                }
            }
            .padding(.vertical, NeuSpace.xs).neuDebossed(NeuRadius.card, depth: 0.8)
            HStack(spacing: NeuSpace.sm) {
                NeuChip(title: ConfigStore.shared.current.memoryEnabled ? "記憶：開 ✓" : "記憶：關") {
                    try? ConfigStore.shared.update { $0.memoryEnabled.toggle() }
                    if ConfigStore.shared.current.memoryEnabled { try? MemoryStore.ensure(); EntryFiles.ensure() }
                }
                InfoTip("這是給有在用 Claude Code 的人的功能。打開後，每開完一場會，Hearby 會把誰出席、談了什麼、決定了什麼、還沒做完的事，記在紀錄資料夾裡的幾個文字檔。之後你在那個資料夾用 Claude Code 問問題，它就知道你開過哪些會，不用重講一遍。沒在用的話關著就好。")
                NeuNote(text: "給有在用 Claude Code 的人；不確定就先關著")
            }
            NeuNote(text: "紀錄整理好會跳一個通知；除此之外它不會來吵你。")
            Spacer()
            NeuCapsuleButton(title: "完成") {
                try? ConfigStore.shared.update { $0.wizardDone = true; $0.wizardStep = 0 }
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                onFinish()
            }
        }
    }
}

/// 選單列示意：一條仿 macOS 選單列，右邊那顆 ” 就是 Hearby——沒聽過「選單列」的人看圖就認得
public struct MenuBarHint: View {
    public var caption = true
    public init(caption: Bool = true) { self.caption = caption }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("\u{F8FF}").font(.system(size: 13)).foregroundColor(Neu.inkMid)
                Text("Finder").font(.system(size: 12, weight: .semibold)).foregroundColor(Neu.inkMid)
                Text("檔案").font(.system(size: 12)).foregroundColor(Neu.inkSoft)
                Text("編輯").font(.system(size: 12)).foregroundColor(Neu.inkSoft)
                Text("顯示方式").font(.system(size: 12)).foregroundColor(Neu.inkSoft)
                Spacer()
                ZStack {
                    Circle().stroke(Neu.inkStrong, lineWidth: 1.4).frame(width: 26, height: 26)
                    HearbyMark(mode: .listening, size: 11)
                }
                Image(systemName: "wifi").font(.system(size: 11)).foregroundColor(Neu.inkSoft)
                Image(systemName: "battery.100").font(.system(size: 11)).foregroundColor(Neu.inkSoft)
                Text("週一 9:41").font(.system(size: 11)).foregroundColor(Neu.inkSoft)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Neu.stage))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Neu.shade.opacity(0.3), lineWidth: 1))
            if caption {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundColor(Neu.inkMid).padding(.top, 3)
                    Text("螢幕最上面這一列叫「選單列」。Hearby 就是右邊那個圈起來的引號 ”，按它就會跳出小面板。").font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
