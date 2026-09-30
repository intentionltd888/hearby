// VoicesView — 認聲音（實驗，macOS 15 以上）：紀錄頁「這場有哪些聲音」（聽一段、取名字、本人同意才記），設定頁「記得的聲音」（開關、忘記）
// 規則在 HearbyCore 的 Voices：這裡只管畫面。一場會的分段結果只在這個畫面的記憶體裡，關掉就沒了；只有按「記住」的那一個聲音會存。
import AVFoundation
import HearbyCore
import SwiftUI

/// 播一小段錄音（聽聽看這個聲音是誰）
final class VoiceClipPlayer: ObservableObject {
    private var player: AVAudioPlayer?
    private var stop: DispatchWorkItem?
    @Published var playing: String? = nil

    func play(_ url: URL, id: String, from: Double, seconds: Double = 8) {
        halt()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.currentTime = max(0, from)
        p.play()
        player = p
        playing = id
        let w = DispatchWorkItem { [weak self] in self?.halt() }
        stop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func halt() {
        stop?.cancel(); stop = nil
        player?.stop(); player = nil
        playing = nil
    }
}

/// 紀錄頁：這場有哪些聲音
struct VoicesPanel: View {
    let mdURL: URL
    var onClose: () -> Void = {}
    @State private var busy = false
    @State private var stage = ""
    @State private var clusters: [Voices.Cluster]? = nil
    @State private var matched: [String: (name: String, score: Float)] = [:]
    @State private var names: [String: String] = [:]
    @State private var consent: Set<String> = []
    @State private var msg = ""
    @StateObject private var player = VoiceClipPlayer()

    /// 這場的音源：分軌還在（30 天內）就分開認，不然用混好的 m4a
    private var sources: [Voices.Source] { Voices.sources(meetingDir: mdURL.deletingLastPathComponent(), m4a: Repolish.audioURL(mdURL: mdURL, audioLine: "")) }
    private var model: String { Voices.engine?.model ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: NeuSpace.sm) {
            NeuNote(text: "找出這場錄音裡有哪些聲音，幫認識的人取名字。要本人同意才記；聲紋只存在這台 Mac，隨時可以在設定裡忘記。")
            if !Voices.supported {
                NeuNote(text: "認聲音要 macOS 15 以上。")
            } else if sources.isEmpty {
                NeuNote(text: "這場找不到錄音檔，沒辦法認聲音。")
            } else if let cl = clusters {
                let big = cl.filter { $0.seconds >= Voices.minSeconds }.sorted { $0.seconds > $1.seconds }
                let tags = Voices.tags(cl, matched: matched)
                if big.isEmpty { NeuNote(text: "這場沒有講超過 \(Int(Voices.minSeconds)) 秒的聲音。") }
                ForEach(big, id: \.id) { c in row(c, tag: tags[c.id] ?? c.id) }
                if !ConfigStore.shared.current.voicesEnabled, !Voices.people().isEmpty {
                    HStack(spacing: NeuSpace.sm) {
                        NeuNote(text: "整理時認聲音現在是關著的：記住的聲音要打開才會標出來。")
                        NeuChip(title: "打開", systemImage: "checkmark") { try? ConfigStore.shared.update { $0.voicesEnabled = true }; msg = "打開了：之後整理（或按「重新整理全篇」）會標出認得的人" }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                HStack(spacing: NeuSpace.sm) {
                    NeuCapsuleButton(title: busy ? "找聲音中…" : "找這場有哪些聲音", height: 36, enabled: !busy) { scan() }
                    if busy { Text(stage).font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid) }
                    Spacer(minLength: 0)
                }
            }
            if !msg.isEmpty { NeuNote(text: msg) }
        }
        .padding(NeuSpace.md).neuDebossed(NeuRadius.card, depth: 0.7)
        .onDisappear { player.halt() }
    }

    @ViewBuilder private func row(_ c: Voices.Cluster, tag: String) -> some View {
        VStack(alignment: .leading, spacing: NeuSpace.xs) {
            HStack(spacing: NeuSpace.sm) {
                Text(tag).font(NeuFont.ui(NeuType.body, true)).foregroundColor(Neu.inkStrong)
                Text("\(Voices.trackName(c.track))｜" + (c.seconds < 60 ? "不到 1 分鐘" : "講了 \(Int(c.seconds / 60)) 分鐘")).font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid)
                NeuChip(title: player.playing == c.id ? "停" : "聽一段", systemImage: player.playing == c.id ? "stop.fill" : "play.fill") {
                    if player.playing == c.id { player.halt() } else if let a = sources.first(where: { $0.track == c.track })?.url { player.play(a, id: c.id, from: sample(c)) }
                }
                if let m = matched[c.id] {
                    NeuStatusTag(level: .ready, text: "認得：\(m.name)（像 \(Int(m.score * 100))%）")
                }
                Spacer(minLength: 0)
            }
            if matched[c.id] == nil {
                HStack(spacing: NeuSpace.sm) {
                    TextField("這是誰？（名字）", text: Binding(get: { names[c.id] ?? "" }, set: { names[c.id] = $0 }))
                        .textFieldStyle(.plain).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong)
                        .padding(.horizontal, NeuSpace.md).frame(width: 180, height: 34).neuDebossed(NeuRadius.pill, depth: 0.9)
                    NeuChip(title: consent.contains(c.id) ? "本人同意 ✓" : "本人同意？", systemImage: consent.contains(c.id) ? "checkmark.shield" : "shield") {
                        if consent.contains(c.id) { consent.remove(c.id) } else { consent.insert(c.id) }
                    }
                    .help("他本人同意 Hearby 在這台 Mac 記住他的聲音（聲紋不離開這台 Mac、可以隨時忘記）")
                    NeuChip(title: "記住", systemImage: "person.wave.2", enabled: consent.contains(c.id) && !(names[c.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty) {
                        remember(c)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 聽哪一段：最長的那段講話（太長從中間往前一點開始）
    private func sample(_ c: Voices.Cluster) -> Double {
        guard let s = c.spans.max(by: { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }) else { return 0 }
        return s.upperBound - s.lowerBound > 20 ? s.lowerBound + 5 : s.lowerBound
    }

    private func scan() {
        let srcs = sources
        guard !srcs.isEmpty, let e = Voices.engine else { return }
        // 重找一次，代號（mic:S1…）可能換了人：上一輪的「本人同意」與取的名字不能沿用
        clusters = nil; matched = [:]; names = [:]; consent = []
        busy = true; msg = ""; stage = "準備中…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try Voices.clusters(of: srcs, engine: e) { s in DispatchQueue.main.async { stage = s } } }
            DispatchQueue.main.async {
                busy = false; stage = ""
                switch r {
                case .success(let cl):
                    clusters = cl
                    matched = Voices.match(cl, Voices.people(), model: model)
                case .failure(let err):
                    msg = "找聲音失敗：\(err.localizedDescription)"
                }
            }
        }
    }

    private func remember(_ c: Voices.Cluster) {
        let name = (names[c.id] ?? "").trimmingCharacters(in: .whitespaces)
        guard consent.contains(c.id), !name.isEmpty else { return }
        do {
            let p = try Voices.remember(name: name, cluster: c, model: model, source: mdURL.deletingPathExtension().lastPathComponent)
            matched[c.id] = (p.name, 1)
            msg = "記住了「\(p.name)」的聲音（\(Voices.trackName(p.track))，\(p.consent)）。之後整理（或按「重新整理全篇」）就會認出來；同一個人在另一軌（例如這次現場、下次線上）要再記一次。"
        } catch { msg = error.localizedDescription }
    }
}

/// 設定頁：整理時認聲音、記得的聲音
struct VoicesSettings: View {
    @State private var on = ConfigStore.shared.current.voicesEnabled
    @State private var people = Voices.people()
    @State private var msg = ""
    private var names: [String] { people.reduce(into: [String]()) { if !$0.contains($1.name) { $0.append($1.name) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: NeuSpace.sm) {
            if !Voices.supported {
                NeuNote(text: "認聲音要 macOS 15 以上。")
            } else {
                HStack(spacing: NeuSpace.sm) {
                    NeuChip(title: on ? "整理時認聲音：開著 ✓" : "整理時認聲音：關著") {
                        on.toggle(); try? ConfigStore.shared.update { $0.voicesEnabled = on }
                    }
                    NeuNote(text: on ? "每場整理前先分出誰在講話（一小時的錄音約一分鐘），認得的標名字" : "現在不認；打開後，第一次會下載聲音模型（約 22 MB）")
                }
                if people.isEmpty {
                    NeuNote(text: "還沒記住任何人的聲音：到一場紀錄按「認聲音」，幫認識的人取名字（要本人同意）。")
                } else {
                    ForEach(names, id: \.self) { n in
                        let ps = people.filter { $0.name == n }
                        HStack(spacing: NeuSpace.sm) {
                            Text(n).font(NeuFont.ui(NeuType.body, true)).foregroundColor(Neu.inkStrong)
                            NeuNote(text: ps.map { "\(Voices.trackName($0.track)) \(Int($0.seconds / 60)) 分鐘" }.joined(separator: "、") + "｜\(ps.first?.consent ?? "")")
                            Spacer(minLength: 0)
                            NeuChip(title: "忘記", systemImage: "trash") {
                                do { try Voices.forget(n); people = Voices.people(); msg = "忘記了「\(n)」的聲音（這台 Mac 上不留任何一份）" }
                                catch { msg = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            if !msg.isEmpty { NeuNote(text: msg) }
        }
    }
}
