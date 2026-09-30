// FluidVoiceEngine — Voices.Engine 的實作：FluidAudio 的離線說話人分段（pyannote 分段＋WeSpeaker 聲紋＋VBx 分群，Core ML，在這台 Mac 上跑）
//
// 模型第一次用的時候從 Hugging Face 下載（FluidInference/speaker-diarization-coreml，約 22 MB，CC-BY-4.0，見 THIRD-PARTY.md），
// 放在 Hearby 支援資料夾的 models/voices/；錄音與聲紋都不離開這台 Mac。
// 每個聲音的聲紋＝分段模型給的說話人中心（256 維）：實測同一個人跨場 0.83–0.94、不同人 ≤ 0.60（Voices.threshold）。
import FluidAudio
import Foundation
import HearbyCore

public final class FluidVoiceEngine: Voices.Engine {
    /// 聲紋是哪個模型算的（換模型要重記）
    public let model = "fluidaudio-offline-0.17"
    private var manager: OfflineDiarizerManager?

    public init() {
        // FluidAudio 預設把 debug 訊息印到終端機：只留警告以上、只進系統記錄
        AppLogger.minimumLevel = .warning
        AppLogger.mirrorsToConsole = false
    }

    static var modelsDir: URL { Paths.support.appendingPathComponent("models/voices", isDirectory: true) }

    public func clusters(of audio: URL, progress: ((String) -> Void)?) async throws -> [Voices.Cluster] {
        let m: OfflineDiarizerManager
        if let x = manager {
            m = x
        } else {
            progress?("準備聲音模型…（第一次要下載約 22 MB）")
            try FileManager.default.createDirectory(at: Self.modelsDir, withIntermediateDirectories: true)
            let x = OfflineDiarizerManager(config: .default)
            try await x.prepareModels(directory: Self.modelsDir)
            manager = x
            m = x
        }
        progress?("認聲音中…（一小時的錄音約一分鐘）")
        let r = try await m.process(audio)
        var spans: [String: [ClosedRange<Double>]] = [:]
        var vectors: [String: [[Float]]] = [:]
        for s in r.segments where s.endTimeSeconds > s.startTimeSeconds {
            spans[s.speakerId, default: []].append(Double(s.startTimeSeconds)...Double(s.endTimeSeconds))
            if !s.embedding.isEmpty { vectors[s.speakerId, default: []].append(s.embedding) }
        }
        let centers = r.speakerDatabase ?? [:]
        return spans.keys.sorted().compactMap { id -> Voices.Cluster? in
            guard let sp = spans[id], let v = centers[id] ?? Self.mean(vectors[id] ?? []) else { return nil }
            return Voices.Cluster(id: id, vector: v, seconds: sp.reduce(0) { $0 + $1.upperBound - $1.lowerBound }, spans: sp)
        }
    }

    static func mean(_ vs: [[Float]]) -> [Float]? {
        guard let n = vs.first?.count, n > 0 else { return nil }
        var out = [Float](repeating: 0, count: n)
        for v in vs where v.count == n { for i in 0..<n { out[i] += v[i] } }
        return out.map { $0 / Float(vs.count) }
    }
}
