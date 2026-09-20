// MediaImporter — 匯入音檔／影片 → 16k mono s16 wav（v1.4，8/11：Podcast 後製與剪輯師場景）
// 走 AVAssetReader＋AudioMixOutput：唯一能直出 wav 目標格式的路徑（ExportSession 的音訊
// preset 只有 AAC）；多音軌螢幕錄影（OBS 這類）自動混進單軌、任意取樣率自動降混；
// 逐 buffer 串流解碼＝2 小時錄影也是 O(1) 記憶體。

import AVFoundation
import Foundation

public enum MediaImporter {
    public static let audioExts = ["m4a", "mp3", "wav", "aiff", "aif"]
    public static let videoExts = ["mp4", "mov"]
    public static var allExts: [String] { audioExts + videoExts }

    public struct Probe {
        public let asset: AVURLAsset
        public let tracks: [AVAssetTrack]
        public let seconds: Double
    }

    /// 前置檢查：DRM／無聲軌／損毀在建工作夾之前就擋下，不留半成品
    public static func probe(_ url: URL) async throws -> Probe {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw HearbyError("找不到這個檔案：\(url.lastPathComponent)") }
        if isDir.boolValue { throw HearbyError("「\(url.lastPathComponent)」是資料夾，請選裡面的音檔或影片") }
        let type = (try? fm.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.type] as? FileAttributeType
        guard type == .typeRegular else { throw HearbyError("「\(url.lastPathComponent)」不是一般的檔案，無法匯入") }
        guard fm.isReadableFile(atPath: url.path) else { throw HearbyError("沒有權限讀取「\(url.lastPathComponent)」") }
        let asset = AVURLAsset(
            url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration: CMTime
        let protected: Bool
        do {
            (duration, protected) = try await asset.load(.duration, .hasProtectedContent)
        } catch {
            throw HearbyError("「\(url.lastPathComponent)」無法讀取（檔案損壞或格式不支援）")
        }
        if protected {
            throw HearbyError("這個檔案受 DRM 保護，無法讀取聲音。請改用無保護的來源檔")
        }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw HearbyError("檔案裡沒有聲音軌（純畫面的錄影無法轉逐字稿）")
        }
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw HearbyError("檔案無法讀取或已損壞") }
        return Probe(asset: asset, tracks: tracks, seconds: duration.seconds)
    }

    /// 串流轉碼成 16k mono s16 wav；回傳實寫秒數（比 asset 時長可信）。
    /// 支援 Task 取消（迴圈內 checkCancellation，reader 隨作用域收掉）。
    public static func transcode(
        _ p: Probe, to dest: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Double {
        let reader = try AVAssetReader(asset: p.asset)
        var settings = kWavSettings
        settings[AVLinearPCMIsNonInterleaved] = false
        let output = AVAssetReaderAudioMixOutput(audioTracks: p.tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw HearbyError("這個檔案的聲音格式無法轉換") }
        reader.add(output)
        // 4 參數 init＝processing format 直接是 int16 interleaved，跟 reader 輸出一致，零轉換器
        let file = try AVAudioFile(
            forWriting: dest, settings: kWavSettings,
            commonFormat: .pcmFormatInt16, interleaved: true)
        guard reader.startReading() else {
            throw HearbyError("讀取失敗：\(reader.error?.localizedDescription ?? "編碼格式不支援")")
        }
        var lastFrac = -1.0
        while let sb = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // 與 Recorder 的 SCK handler 同款寫法（實戰驗證過）：ABL 原地包成 PCMBuffer 直寫，
            // 不自己搬資料（CMSampleBufferCopyPCMData 那條路實測會整批靜默失敗＝空 wav）
            try sb.withAudioBufferList { abl, _ in
                guard var absd = sb.formatDescription?.audioStreamBasicDescription,
                    let fmt = AVAudioFormat(streamDescription: &absd),
                    let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: abl.unsafePointer)
                else { return }
                try file.write(from: buf)
            }
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if p.seconds > 0 {
                let frac = min(1, t / p.seconds)
                if frac - lastFrac >= 0.01 {
                    lastFrac = frac
                    progress(frac)
                }
            }
        }
        if reader.status == .failed {
            throw HearbyError(
                "讀取失敗（編碼格式不支援或檔案損壞）：\(reader.error?.localizedDescription ?? "")")
        }
        return Double(file.length) / kSampleRate
    }
}
