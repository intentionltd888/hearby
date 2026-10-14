// TaigiSettings — 設定頁「聽得懂台語（國台混講）」：開關＋台語模型下載（約 1.1 GB，可續傳、會校驗）
import HearbyCore
import SwiftUI

/// 下載狀態放在單例：設定頁關掉再打開，下載照跑、進度接得上
final class TaigiModelDownloader: ObservableObject {
    static let shared = TaigiModelDownloader()
    @Published var fraction: Double? = nil
    @Published var note = ""
    @Published var installed = Taigi.modelURL != nil
    private var job: ModelDownload?
    private var timer: Timer?

    func start() {
        guard job == nil, !installed else { return }
        fraction = 0; note = ""
        let d = ModelDownload.start(ModelCatalog.taigi) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.timer?.invalidate(); self.timer = nil; self.job = nil; self.fraction = nil
                switch r {
                case .success: self.installed = true; self.note = "台語模型下載好了：之後整理（或按「重新整理全篇」）就會聽台語"
                case .failure(let e): self.note = e.localizedDescription
                }
            }
        }
        job = d
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.fraction = d.fraction }
    }
}

struct TaigiSettings: View {
    @State private var on = ConfigStore.shared.current.taigiEnabled
    @ObservedObject private var dl = TaigiModelDownloader.shared

    var body: some View {
        VStack(alignment: .leading, spacing: NeuSpace.sm) {
            HStack(spacing: NeuSpace.sm) {
                NeuChip(title: on ? "聽得懂台語：開著 ✓" : "聽得懂台語：關著") {
                    on.toggle(); try? ConfigStore.shared.update { $0.taigiEnabled = on }
                    if on { dl.start() }
                }
                NeuNote(text: status)
            }
            if !dl.note.isEmpty { NeuNote(text: dl.note) }
        }
        .onAppear { if on, !dl.installed { dl.start() } }   // 上次開著但沒下完：接著下
    }

    private var status: String {
        if let f = dl.fraction { return String(format: "台語模型下載中 %.0f%%（約 1.1 GB；關掉視窗也會繼續）", f * 100) }
        if !on { return dl.installed ? "現在不聽台語（模型已在，打開就生效）" : "現在不聽台語；打開後會先下載台語模型（約 1.1 GB）" }
        return dl.installed ? "原本的模型沒把握或漏聽的地方，會再用台語模型聽一次；台語寫成華語用字" : "還沒有台語模型"
    }
}
