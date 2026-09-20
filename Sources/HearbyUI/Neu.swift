// Neu — 軟浮雕（neumorphism）設計系統（材質層與元件）
//
// 世界觀：整個介面是**一塊材料**，面板與背景同色，形狀只由「雙向陰影」造出來
// （光源固定左上：亮高光在左上、暗影在右下）。凸起＝可按；凹陷＝容器或已選。
//
// 這套材質與姊妹 app Talky 共用（同一份 Neu.swift），只把身份件換掉——Hearby 的身份件在 Brand.swift（引號標記、點陣字標）。
// ・色票全部是「跟系統外觀走」的動態色：淺色＝白材料，深色＝#2B2D33 材料；外觀三選在 Appearance.swift。
// ・介面主體不用藍：只有墨三階；每畫面最多一顆「正在進行」的光點（HearbyMark）。品牌藍只給精靈歡迎海報。
// ・字型走系統字（開源版不散布任何字型檔）；標記與字標是圖檔（見 Resources/Brand/TRADEMARK.md）。
// ・兩邊各有一份，改了要手動同步（或之後抽成共用 package）。

import AppKit
import SwiftUI

// MARK: - 動態色（淺／深各一組，跟系統外觀切換）

private func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    return Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
        })
}

public enum Neu {
    /// 品牌藍 #003CFF：只給精靈歡迎海報（藍底白，同 DMG 背景）；介面主體不用
    public static let brandBlue = Color(red: 0, green: 60 / 255, blue: 1)

    /// 材料本色：面板與背景同一個色，靠陰影分層
    public static var material: Color { dyn(0xEEEFF2, 0x2B2D33) }
    /// 舞台底（比材料再暗一點點，讓面板浮起來）
    public static var stage: Color { dyn(0xE7E8EC, 0x1E1F23) }
    /// 左上高光／右下影
    public static var light: Color { dyn(0xFFFFFF, 0x3E4149) }
    public static var shade: Color { dyn(0xA3A6AF, 0x0E0F12) }
    /// 墨三階
    public static var inkStrong: Color { dyn(0x282A2F, 0xE8E9EC) }
    public static var inkMid: Color { dyn(0x73767E, 0xA6A8B0) }
    public static var inkSoft: Color { dyn(0xA2A5AD, 0x8E9099) }
    /// 主行動鈕的面
    public static var keyFace: Color { dyn(0xE0E2E6, 0x35383F) }
    public static var keyFaceDeep: Color { dyn(0xD3D6DB, 0x2A2C32) }

    private static var isDarkNow: Bool {
        Theme.shared.mode == .dark || (Theme.shared.mode == .system && NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
    /// 給 AppKit 視窗底色用
    public static var stageNSColor: NSColor {
        isDarkNow ? NSColor(srgbRed: 0x1E / 255, green: 0x1F / 255, blue: 0x23 / 255, alpha: 1) : NSColor(srgbRed: 0xE7 / 255, green: 0xE8 / 255, blue: 0xEC / 255, alpha: 1)
    }
    public static var materialNSColor: NSColor {
        isDarkNow ? NSColor(srgbRed: 0x2B / 255, green: 0x2D / 255, blue: 0x33 / 255, alpha: 1) : NSColor(srgbRed: 0xEE / 255, green: 0xEF / 255, blue: 0xF2 / 255, alpha: 1)
    }
}

/// 4pt 網格
public enum NeuSpace {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let hero: CGFloat = 32
    /// 面板內縮
    public static let edge: CGFloat = 24
}

/// 字級
public enum NeuType {
    public static let hero: CGFloat = 28  // 精靈頁大標
    public static let timer: CGFloat = 40
    public static let title: CGFloat = 18
    public static let body: CGFloat = 14
    public static let caption: CGFloat = 12.5
    public static let micro: CGFloat = 11
}

public enum NeuRadius {
    public static let panel: CGFloat = 22
    public static let card: CGFloat = 18
    public static let pill: CGFloat = 999
}

public enum NeuMotion {
    public static let press = Animation.easeOut(duration: 0.14)
    public static let ui = Animation.spring(response: 0.34, dampingFraction: 0.84)
    public static let pulse = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)
}

// MARK: - 材質修飾器

/// 凸起：從材料裡壓出來，可按。光源左上。
public struct NeuRaised: ViewModifier {
    public var radius: CGFloat = NeuRadius.card
    public var lift: CGFloat = 1
    public var pressed: Bool = false
    public init(radius: CGFloat = NeuRadius.card, lift: CGFloat = 1, pressed: Bool = false) { self.radius = radius; self.lift = lift; self.pressed = pressed }

    public func body(content: Content) -> some View {
        let blur = 7 * lift
        let offset = 4 * lift
        // 亮高光只留一半的暈（小膠囊的亮暈會跑到凹框的邊線外，看起來沒對齊；
        // 深影在右下較不顯眼，維持）
        let lightBlur = blur * 0.5
        let lightOffset = offset * 0.6
        return content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Neu.material)
                    .shadow(
                        color: Neu.light.opacity(pressed ? 0.35 : 0.9),
                        radius: lightBlur, x: -lightOffset, y: -lightOffset
                    )
                    .shadow(
                        color: Neu.shade.opacity(pressed ? 0.18 : 0.45),
                        radius: blur * 1.15, x: offset, y: offset
                    )
            )
            .scaleEffect(pressed ? 0.985 : 1)
            // 凸起件整體右移 2pt：亮暈往左外溢的量，讓「看起來的左邊」跟凹框的左邊對齊
            .padding(.leading, 2)
    }
}

/// 凹陷：壓進材料裡。容器、已選、槽。
public struct NeuDebossed: ViewModifier {
    public var radius: CGFloat = NeuRadius.card
    public var depth: CGFloat = 1
    public init(radius: CGFloat = NeuRadius.card, depth: CGFloat = 1) { self.radius = radius; self.depth = depth }

    public func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    Neu.material
                        .shadow(
                            .inner(
                                color: Neu.shade.opacity(0.42 * depth), radius: 4 * depth,
                                x: 2.5 * depth, y: 2.5 * depth)
                        )
                        .shadow(
                            .inner(
                                color: Neu.light.opacity(0.95 * depth), radius: 4 * depth,
                                x: -2.5 * depth, y: -2.5 * depth))
                )
        )
    }
}

public extension View {
    func neuRaised(_ radius: CGFloat = NeuRadius.card, lift: CGFloat = 1, pressed: Bool = false)
        -> some View
    {
        modifier(NeuRaised(radius: radius, lift: lift, pressed: pressed))
    }
    func neuDebossed(_ radius: CGFloat = NeuRadius.card, depth: CGFloat = 1) -> some View {
        modifier(NeuDebossed(radius: radius, depth: depth))
    }
}

public enum NeuFont {
    /// 中文與一般介面字（系統字：跟著使用者的語言設定走，不綁任何字型檔）
    public static func ui(_ size: CGFloat, _ semi: Bool = false) -> Font {
        .system(size: size, weight: semi ? .semibold : .regular)
    }
    /// 字標與數字
    public static func mark(_ size: CGFloat, _ semi: Bool = true) -> Font {
        .system(size: size, weight: semi ? .semibold : .regular, design: .rounded)
    }
}

// MARK: - 元件

/// 深炭錨圓鈕：全畫面唯一高對比元素，只給錄音主行動
public struct NeuAnchorButton: View {
    enum Glyph { case dot, square }
    var glyph: Glyph = .dot
    var size: CGFloat = 108
    var action: () -> Void = {}

    @State private var pressed = false
    @State private var hovering = false

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Neu.material)
                    .frame(width: size + 18, height: size + 18)
                    .shadow(color: Neu.light.opacity(pressed ? 0.4 : 0.95), radius: 8, x: -5, y: -5)
                    .shadow(color: Neu.shade.opacity(pressed ? 0.2 : 0.5), radius: 9, x: 5, y: 5)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Neu.keyFace, Neu.keyFaceDeep],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        Circle().stroke(
                            LinearGradient(
                                colors: [Neu.light.opacity(0.85), Neu.shade.opacity(0.45)],
                                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    )
                    .shadow(color: Neu.shade.opacity(0.38), radius: 4, x: 2, y: 3)
                switch glyph {
                case .dot:
                    Circle().fill(Neu.inkStrong)
                        .frame(width: size * 0.125, height: size * 0.125)
                case .square:
                    RoundedRectangle(cornerRadius: size * 0.055, style: .continuous)
                        .fill(Neu.inkStrong)
                        .frame(width: size * 0.195, height: size * 0.195)
                }
            }
            .scaleEffect(pressed ? 0.975 : (hovering ? 1.012 : 1))
            .animation(NeuMotion.press, value: pressed)
            .animation(NeuMotion.press, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}

/// 寬膠囊主鈕；leadingAnchor = 左端那顆深炭圓（＝這顆鈕會開始錄音）
public struct NeuCapsuleButton: View {
    let title: String
    var leadingAnchor: Bool = false
    var height: CGFloat = 46
    var enabled: Bool = true
    var action: () -> Void = {}

    @State private var pressed = false
    @State private var hovering = false

    public var body: some View {
        Button(action: { if enabled { action() } }) {
            ZStack {
                Text(title)
                    .font(NeuFont.ui(NeuType.body))
                    .foregroundColor(enabled ? Neu.inkStrong : Neu.inkSoft)
                if leadingAnchor {
                    HStack {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Neu.keyFace, Neu.keyFaceDeep],
                                        startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                                .overlay(
                                    Circle().stroke(Neu.light.opacity(0.7), lineWidth: 0.8)
                                )
                            Circle().fill(Neu.inkStrong)
                                .frame(width: (height - 16) * 0.28, height: (height - 16) * 0.28)
                        }
                        .frame(width: height - 16, height: height - 16)
                        .padding(.leading, 8)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .neuRaised(NeuRadius.pill, lift: 0.85, pressed: pressed)
            .brightness(hovering && !pressed && enabled ? 0.012 : 0)
            .animation(NeuMotion.press, value: pressed)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if enabled { pressed = true } }
                .onEnded { _ in pressed = false }
        )
    }
}

/// 小圓形圖示鈕；on＝開關鈕的「開」狀態：常亮墨色＋凹陷（已按下）
public struct NeuIconButton: View {
    let systemName: String
    var size: CGFloat = 22
    var on: Bool = false
    var action: () -> Void = {}
    @State private var pressed = false
    @State private var hovering = false

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundColor(hovering || on ? Neu.inkStrong : Neu.inkMid)
                .frame(width: size, height: size)
                .background {
                    if pressed || on {
                        Circle().fill(Neu.material)
                            .neuDebossed(NeuRadius.pill, depth: 0.7)
                    } else {
                        Circle().fill(Neu.material)
                            .shadow(color: Neu.light.opacity(0.95), radius: 2.5, x: -1.5, y: -1.5)
                            .shadow(color: Neu.shade.opacity(0.45), radius: 3, x: 1.5, y: 1.5)
                    }
                }
                .animation(NeuMotion.press, value: pressed)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}

/// 統一返回頭列
public struct NeuBackHeader: View {
    let title: String
    var onBack: () -> Void

    public var body: some View {
        HStack(spacing: NeuSpace.md) {
            NeuIconButton(systemName: "chevron.left", size: 26) { onBack() }
            Text(title)
                .font(NeuFont.ui(NeuType.title, true))
                .foregroundColor(Neu.inkStrong)
                .lineLimit(1)
            Spacer()
        }
    }
}

/// 小膠囊（可帶 SF Symbol 圖示，阿嬤看圖也認得）
public struct NeuChip: View {
    let title: String
    var systemImage: String? = nil
    var enabled: Bool = true
    var action: () -> Void = {}
    @State private var pressed = false
    @State private var hovering = false

    public var body: some View {
        Button(action: { if enabled { action() } }) {
            HStack(spacing: 6) {
                if let i = systemImage { Image(systemName: i).font(.system(size: 12, weight: .medium)) }
                Text(title).lineLimit(1).fixedSize()
            }
                .font(NeuFont.ui(NeuType.caption))
                .foregroundColor(enabled ? Neu.inkStrong : Neu.inkSoft)
                .padding(.horizontal, NeuSpace.md)
                .frame(height: 34)
                .neuRaised(NeuRadius.pill, lift: 0.6, pressed: pressed)
                .brightness(hovering && !pressed && enabled ? 0.012 : 0)
                .animation(NeuMotion.press, value: pressed)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if enabled { pressed = true } }
                .onEnded { _ in pressed = false }
        )
    }
}

/// 狀態小標（只用墨三階，不用彩色）：ready＝深墨實心點、pending＝中灰、missing＝淺灰空心
public struct NeuStatusTag: View {
    public enum Level { case ready, pending, missing }
    let level: Level
    let text: String
    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(level == .missing ? Neu.inkSoft : .clear, lineWidth: 1)
                .background(
                    Circle().fill(
                        level == .ready ? Neu.inkStrong : (level == .pending ? Neu.inkMid : .clear)))
                .frame(width: 7, height: 7)
            Text(text).font(NeuFont.ui(NeuType.micro))
                .foregroundColor(level == .missing ? Neu.inkSoft : Neu.inkMid)
        }
    }
}

/// 分段選擇：整條是凹陷容器，選中那格凸起（icons 給了就在字前面放一個小圖示）
public struct NeuSegmented: View {
    let items: [String]
    @Binding var selection: Int
    var icons: [String]? = nil
    var height: CGFloat = 40
    @Namespace private var ns

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let on = i == selection
                HStack(spacing: 5) {
                    if let ic = icons, i < ic.count { Image(systemName: ic[i]).font(.system(size: 11, weight: .medium)) }
                    Text(items[i])
                }
                    .font(NeuFont.ui(NeuType.caption, on))
                    .foregroundColor(on ? Neu.inkStrong : Neu.inkMid)
                    .frame(maxWidth: .infinity)
                    .frame(height: height - 8)
                    .background {
                        if on {
                            Capsule()
                                .fill(Neu.material)
                                .shadow(color: Neu.light.opacity(0.95), radius: 3, x: -2, y: -2)
                                .shadow(color: Neu.shade.opacity(0.42), radius: 4, x: 2, y: 2)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(NeuMotion.ui) { selection = i } }
            }
        }
        .padding(4)
        .frame(height: height)
        .neuDebossed(NeuRadius.pill, depth: 0.85)
    }
}

/// 凹槽：音量條與進度條共用。fill 0…1；nil＝不確定型（一段在跑）
public struct NeuGroove: View {
    var fill: CGFloat?
    var height: CGFloat = 16
    @State private var drift: CGFloat = 0

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let inner = max(2, height - 7)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Neu.material)
                    .frame(width: max(inner, w * max(0.04, min(1, fill ?? 0.32)) - 6), height: inner)
                    .shadow(color: Neu.light.opacity(0.9), radius: 2.5, x: -1.5, y: -1.5)
                    .shadow(color: Neu.shade.opacity(0.4), radius: 3, x: 1.5, y: 1.5)
                    .padding(.leading, 3.5)
                    .offset(x: fill == nil ? drift * (w * 0.62) : 0)
                    .animation(fill == nil ? nil : .linear(duration: 0.08), value: fill)
            }
            .frame(width: w, height: height, alignment: .leading)
            .onAppear { setDrift(running: fill == nil) }
            .onDisappear { setDrift(running: false) }
            // 同一顆 NeuGroove 從「不確定型」換成有進度值時，SwiftUI 可能沿用同一個 view
            // identity——不明講就停不下來，動畫看不見卻照跑（見下面 setDrift 的註解）。
            .onChange(of: fill == nil) { _, indeterminate in setDrift(running: indeterminate) }
        }
        .frame(height: height)
        .neuDebossed(NeuRadius.pill, depth: 0.9)
    }

    /// `.repeatForever` 不會自己結束：view 只是被藏起來（視窗 orderOut、或被 if 換掉）時，
    /// 動畫仍掛在 view graph 上，每個顯示週期都逼一次重排＝主執行緒永久空轉。
    /// 停的方法是用一個有限動畫覆寫同一個屬性，把它從 graph 上換掉。
    private func setDrift(running: Bool) {
        if running {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { drift = 1 }
        } else {
            withAnimation(.linear(duration: 0.01)) { drift = 0 }
        }
    }
}

/// 凹陷卡：內容容器
public struct NeuInset<Content: View>: View {
    var radius: CGFloat = NeuRadius.card
    @ViewBuilder var content: Content
    public var body: some View {
        content.neuDebossed(radius, depth: 0.95)
    }
}

/// 處理中的階段列：done＝打勾且字變淡；active＝米字呼吸
public struct NeuStageRow: View {
    let title: String
    var done: Bool = false
    var active: Bool = false

    public var body: some View {
        HStack {
            Text(title)
                .font(NeuFont.ui(NeuType.body, active))
                .foregroundColor(done ? Neu.inkSoft : Neu.inkStrong)
            Spacer()
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Neu.inkStrong)
            } else if active {
                HearbyMark(mode: .listening, size: 9)
            }
        }
        .padding(.horizontal, NeuSpace.lg)
        .frame(height: 42)
        .neuDebossed(NeuRadius.pill, depth: done ? 0.7 : 0.95)
    }
}

/// 自動換行的工具列：放不下就折到下一行（不截字、不擠）
public struct FlowLayout: Layout {
    public var spacing: CGFloat = NeuSpace.sm
    public init(spacing: CGFloat = NeuSpace.sm) { self.spacing = spacing }
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 10_000
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > w { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: w == 10_000 ? x : w, height: y + rowH)
    }
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

/// 一行說明字（micro，中灰；軟浮雕低對比→不用淺灰）
public struct NeuNote: View {
    let text: String
    public var body: some View {
        Text(text)
            .font(NeuFont.ui(NeuType.micro))
            .foregroundColor(Neu.inkMid)
            .fixedSize(horizontal: false, vertical: true)
    }
}
