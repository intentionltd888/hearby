// Brand — Hearby 身份件：標記（向量 HearbyMarkShape）、字標 hearby”（貼圖）、Powered by
// 圖檔在 Resources/Brand（商標，不在 MIT 範圍，見 TRADEMARK.md）；介面走 template 渲染，顏色跟墨階走。
import AppKit
import SwiftUI

public enum Brand {
    /// 資源包（hearby-mac_HearbyUI.bundle）在哪——**不用 SwiftPM 的 `Bundle.module`**：
    /// `swift build` 產生的存取器只找「app 根目錄」與「開發機上的 .build 絕對路徑」，找不到就 fatalError；
    /// build.sh 把包放在 Contents/Resources，所以在別人的機器上一畫 Logo 就閃退，
    /// 而建置的那台機器上 .build 那條路徑存在，所以自己永遠測不出來。
    /// 這裡自己找：Contents/Resources → app 根 → 可執行檔旁（swift build 直接跑）；都沒有就退成文字，永不 fatalError。
    public static let resourceBundle: Bundle? = {
        let name = "hearby-mac_HearbyUI.bundle"
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(name)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(name))
        if let x = Bundle.main.executableURL { candidates.append(x.deletingLastPathComponent().appendingPathComponent(name)) }
        for u in candidates where FileManager.default.fileExists(atPath: u.path) {
            if let b = Bundle(url: u) { return b }
        }
        return nil
    }()

    /// 精靈歡迎頁底圖（棚拍照，960×1280 @2x）
    public static let wizardHero: NSImage? = resourceBundle?.url(forResource: "hearby_wizard_hero", withExtension: "jpg", subdirectory: "Brand").flatMap { NSImage(contentsOf: $0) }

    private static func image(_ name: String, template: Bool) -> NSImage? {
        guard let url = resourceBundle?.url(forResource: name, withExtension: "png", subdirectory: "Brand") else { return nil }
        let img = NSImage(contentsOf: url)
        img?.isTemplate = template
        return img
    }
    /// 字標 hearby”（含引號；template）
    public static let logotype = image("hearby_logotype", template: true)
    /// 純字 hearby（旁邊已有大標記時用，避免引號出現兩次）
    public static let logotypeWord = image("hearby_logotype_word", template: true)
    public static let intention = image("intention_wordmark", template: true)

    /// 程式畫的標記（任何尺寸都準）：point 高，黑 template
    public static func markImage(height: CGFloat, dot: Bool = false) -> NSImage {
        let w = height * (HearbyMarkShape.box.width / HearbyMarkShape.box.height)
        let size = NSSize(width: w + (dot ? 5 : 0), height: height)
        let img = NSImage(size: size, flipped: true) { rect in
            let path = HearbyMarkShape().path(in: CGRect(x: 0, y: 0, width: w, height: height))
            NSColor.black.setFill()
            NSBezierPath(cgPath: path.cgPath).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// 標記光點：每畫面恰一顆，只標「正在進行／剛完成」。四態同 Talky 米字：idle／listening（呼吸光暈）／working／flash。
public struct HearbyMark: View {
    public enum Mode: Equatable { case idle, listening, working, flash }
    public var mode: Mode = .idle
    public var size: CGFloat = 16
    public var color: Color = Neu.inkStrong
    @State private var breathe = false
    @State private var flashOn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(mode: Mode = .idle, size: CGFloat = 16, color: Color = Neu.inkStrong) { self.mode = mode; self.size = size; self.color = color }

    public var body: some View {
        let w = size * (HearbyMarkShape.box.width / HearbyMarkShape.box.height)
        ZStack {
            if mode == .listening || mode == .working {
                HearbyMarkShape().fill(color).frame(width: w, height: size).blur(radius: size * 0.45).opacity(breathe ? 0.8 : 0.3)
            }
            if mode == .flash {
                Circle().stroke(color.opacity(flashOn ? 0 : 0.9), lineWidth: 1.2)
                    .frame(width: size * (flashOn ? 2.3 : 1.2), height: size * (flashOn ? 2.3 : 1.2))
            }
            HearbyMarkShape().fill(color).frame(width: w, height: size)
                .scaleEffect(mode == .listening && breathe ? 1.06 : 1)
                .offset(y: mode == .working && breathe && !reduceMotion ? -1 : 0)
        }
        .frame(width: size * 2.4, height: size * 2.4)
        .accessibilityLabel("Hearby")
        .onAppear { apply(mode) }
        .onChange(of: mode) { _, m in apply(m) }
        .onDisappear { apply(.idle) }
    }
    private func apply(_ m: Mode) {
        switch m {
        case .listening, .working: withAnimation(NeuMotion.pulse) { breathe = true }
        default: withAnimation(.easeOut(duration: 0.3)) { breathe = false }
        }
        if m == .flash { flashOn = false; withAnimation(.easeOut(duration: 0.55)) { flashOn = true } } else { flashOn = false }
    }
}

/// 字標 hearby”（貼圖，template）；缺圖退成文字不破版
public struct HearbyLogotype: View {
    public var height: CGFloat = 14
    public var color: Color = Neu.inkSoft
    public var wordOnly = false
    public init(height: CGFloat = 14, color: Color = Neu.inkSoft, wordOnly: Bool = false) { self.height = height; self.color = color; self.wordOnly = wordOnly }
    public var body: some View {
        if let img = wordOnly ? Brand.logotypeWord : Brand.logotype {
            Image(nsImage: img).renderingMode(.template).resizable().scaledToFit().frame(height: height).foregroundColor(color).accessibilityLabel("Hearby")
        } else {
            Text("hearby”").font(.system(size: height * 1.3, weight: .black)).foregroundColor(color)
        }
    }
}
public struct IntentionWordmark: View {
    public var height: CGFloat = 9
    public var color: Color = Neu.inkSoft
    public init(height: CGFloat = 9, color: Color = Neu.inkSoft) { self.height = height; self.color = color }
    public var body: some View {
        if let img = Brand.intention {
            Image(nsImage: img).renderingMode(.template).resizable().scaledToFit().frame(height: height).foregroundColor(color).accessibilityLabel("INTENTION")
        } else {
            Text("INTENTION®").font(NeuFont.mark(height + 1)).tracking(1.5).foregroundColor(color)
        }
    }
}

/// 頁尾：「Powered by ＋ INTENTION 字標」左、hearby” 右
public struct PoweredBy: View {
    public var showWordmark = true
    public init(showWordmark: Bool = true) { self.showWordmark = showWordmark }
    public var body: some View {
        HStack(spacing: NeuSpace.sm) {
            Text("Powered by").font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkSoft)
            IntentionWordmark(height: 8.5)
            Spacer(minLength: 0)
            if showWordmark { HearbyLogotype(height: 12) }
        }
    }
}

/// ⓘ 說明：點開一段白話
public struct InfoTip: View {
    let text: String
    @State private var open = false
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "questionmark.circle").font(.system(size: 12, weight: .medium)).foregroundColor(Neu.inkMid)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Text(text).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong)
                .fixedSize(horizontal: false, vertical: true)
                .padding(NeuSpace.lg).frame(width: 300, alignment: .leading)
                .background(Neu.material)
        }
        .accessibilityLabel("說明")
    }
}
