// FloatingBar — 面板收起來時，錄音中螢幕上那一條小狀態列：在錄還是暫停、幾分幾秒、麥克風有沒有聲音、暫停與停止
// 視窗本身（永遠在最上層、可拖、不進螢幕分享）在殼的 FloatingBarWindow；這裡只畫內容，跟面板讀同一個 PanelModel。
import HearbyCore
import SwiftUI

public struct FloatingBarView: View {
    @ObservedObject var m: PanelModel
    @ObservedObject private var theme = Theme.shared
    public init(model: PanelModel) { self.m = model }
    public static let size = CGSize(width: 244, height: 50)

    public var body: some View {
        HStack(spacing: NeuSpace.sm) {
            Button { m.onExpand() } label: {
                HStack(spacing: 6) {
                    ZStack {
                        if m.paused {
                            Image(systemName: "pause.fill").font(.system(size: 10, weight: .semibold)).foregroundColor(Neu.inkMid)
                        } else {
                            HearbyMark(mode: .listening, size: 7)
                        }
                    }
                    .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(m.paused ? "已暫停・不會存" : "錄音中").font(NeuFont.ui(9)).foregroundColor(m.paused ? Neu.inkStrong : Neu.inkSoft)
                        Text(m.elapsedText).font(NeuFont.mark(15)).monospacedDigit()
                            .foregroundColor(m.paused ? Neu.inkMid : Neu.inkStrong)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打開 Hearby 面板")
            MiniMeter(levels: Array(m.micHistory.suffix(MiniMeter.slots)), dim: m.paused)
                .frame(width: 26, height: 16)
                .help("麥克風：有在動＝有收到聲音")
            Spacer(minLength: 0)
            NeuIconButton(systemName: m.paused ? "play.fill" : "pause.fill", size: 28) { m.paused ? m.onResume() : m.onPause() }
                .help(m.paused ? "繼續錄（接在同一份紀錄）" : "暫停（這段不會存）")
            NeuIconButton(systemName: "stop.fill", size: 28) { m.onStop() }
                .help("停止並整理")
        }
        .padding(.horizontal, NeuSpace.md)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Capsule(style: .continuous).fill(Neu.material))
        .overlay(Capsule(style: .continuous).stroke(Neu.shade.opacity(0.3), lineWidth: 0.5))
        .id(theme.mode)
    }
}

/// 迷你音量：最近幾格的細條（麥克風有沒有收到聲音，一眼看得到）
struct MiniMeter: View {
    static let slots = 6
    var levels: [Float]
    var dim: Bool
    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<Self.slots, id: \.self) { i in
                    let idx = i - (Self.slots - levels.count)
                    let v = idx >= 0 && idx < levels.count ? CGFloat(levels[idx]) : 0
                    Capsule().fill(dim ? Neu.inkSoft : Neu.inkStrong)
                        .frame(width: 2.5, height: max(2, geo.size.height * min(1, v * 1.4)))
                        .animation(.linear(duration: 0.1), value: v)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
