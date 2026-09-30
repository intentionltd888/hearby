// WavIO — 崩潰安全的 wav 寫入器＋切片讀取（長會議穩健化）
//
// 為什麼自己寫 wav：AVAudioFile 的長度欄只在關檔那一刻寫入——錄音中崩潰、被結束、關機，
// 整檔讀起來就是 0 秒。這裡：標準 44-byte header，每 5 秒音訊回填一次長度欄；
// 崩潰最多丟最後 5 秒的「長度資訊」（資料都在，repairHeader 會補到檔尾）。
// 切片直接讀 PCM 位元組區段、自帶乾淨 header——不依賴原檔 header 正不正確。

import AVFoundation
import Foundation

public let kSampleRate: Double = 16000

public let kWavSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: kSampleRate,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
]

public func rmsLevel(_ buf: AVAudioPCMBuffer) -> Float {
    guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return 0 }
    var sum: Float = 0
    for f in 0..<Int(buf.frameLength) { sum += ch[f] * ch[f] }
    return min(1.0, sqrt(sum / Float(buf.frameLength)) * 4)
}

/// 同一個尺度給 s16（麥克風那一軌）：÷32768、RMS×4、封頂 1（跟 WavIO.blockLevels 一樣）
public func rmsLevel(_ pcm: UnsafeBufferPointer<Int16>) -> Float {
    guard !pcm.isEmpty else { return 0 }
    var sum: Float = 0
    for v in pcm { let f = Float(v) / 32768; sum += f * f }
    return min(1.0, sqrt(sum / Float(pcm.count)) * 4)
}

public enum WavIO {
    public static let sampleRate = 16000
    public static let bytesPerSecond = 32000  // 16 kHz × mono × s16

    public static func header(dataBytes: UInt64) -> Data {
        var d = Data(capacity: 44)
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(truncatingIfNeeded: 36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(bytesPerSecond))
        u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8))
        u32(UInt32(truncatingIfNeeded: dataBytes))
        return d
    }

    /// PCM 區段：(起點, 位元組數)。長度一律以「檔尾 − 起點」為準，不信 header 長度欄。
    public static func pcmRange(of url: URL) -> (start: UInt64, bytes: UInt64)? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > 44 else { return nil }
        try? fh.seek(toOffset: 0)
        let head = (try? fh.read(upToCount: 8192)) ?? Data()
        guard let r = head.range(of: Data("data".utf8)) else { return nil }
        let start = UInt64(r.lowerBound + 8)
        guard size > start else { return nil }
        return (start, (size - start) & ~UInt64(1))
    }

    public static func durationMs(of url: URL) -> Int? {
        guard let r = pcmRange(of: url) else { return nil }
        return Int(r.bytes * 1000 / UInt64(bytesPerSecond))
    }

    public static func readPCM(_ url: URL, fromMs: Int, toMs: Int) -> [Int16] {
        guard let r = pcmRange(of: url), toMs > fromMs, let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        let a = min(r.bytes, UInt64(max(0, fromMs)) * UInt64(bytesPerSecond) / 1000 & ~UInt64(1))
        let b = min(r.bytes, UInt64(toMs) * UInt64(bytesPerSecond) / 1000 & ~UInt64(1))
        guard b > a else { return [] }
        try? fh.seek(toOffset: r.start + a)
        guard let d = try? fh.read(upToCount: Int(b - a)), !d.isEmpty else { return [] }
        let n = d.count / 2
        var out = [Int16](repeating: 0, count: n)
        _ = out.withUnsafeMutableBytes { d.copyBytes(to: $0, count: n * 2) }
        return out
    }

    /// 每 100 ms 一格的音量（與錄音電平表同尺度）
    public static func blockLevels(_ pcm: [Int16], blockMs: Int = 100) -> [Float] {
        let n = max(1, sampleRate * blockMs / 1000)
        var out: [Float] = []
        out.reserveCapacity(pcm.count / n + 1)
        var i = 0
        while i < pcm.count {
            let e = min(pcm.count, i + n)
            var sum: Float = 0
            for k in i..<e { let v = Float(pcm[k]) / 32768; sum += v * v }
            out.append(min(1, sqrt(sum / Float(e - i)) * 4))
            i = e
        }
        return out
    }

    public static func writeSlice(from src: URL, fromMs: Int, toMs: Int, to dst: URL) -> Bool {
        guard let r = pcmRange(of: src), toMs > fromMs, let inFH = try? FileHandle(forReadingFrom: src) else { return false }
        defer { try? inFH.close() }
        let a = min(r.bytes, UInt64(max(0, fromMs)) * UInt64(bytesPerSecond) / 1000 & ~UInt64(1))
        let b = min(r.bytes, UInt64(toMs) * UInt64(bytesPerSecond) / 1000 & ~UInt64(1))
        guard b > a else { return false }
        guard FileManager.default.createFile(atPath: dst.path, contents: header(dataBytes: b - a)),
            let outFH = try? FileHandle(forWritingTo: dst)
        else { return false }
        defer { try? outFH.close() }
        _ = try? outFH.seekToEnd()
        try? inFH.seek(toOffset: r.start + a)
        var left = b - a
        let chunk: UInt64 = 4 * 1024 * 1024
        while left > 0 {
            guard let d = try? inFH.read(upToCount: Int(min(chunk, left))), !d.isEmpty else { return false }
            do { try outFH.write(contentsOf: d) } catch { return false }
            left -= UInt64(d.count)
        }
        return true
    }

    /// 整段乘上倍數後寫成 wav（小聲片放大聽打用）；超出範圍的取樣夾在 ±32767，不回捲
    public static func writePCM(_ pcm: [Int16], gain: Float, to dst: URL) -> Bool {
        guard !pcm.isEmpty else { return false }
        var out = [Int16](repeating: 0, count: pcm.count)
        for i in 0..<pcm.count { out[i] = Int16(max(-32767, min(32767, (Float(pcm[i]) * gain).rounded()))) }
        var d = header(dataBytes: UInt64(out.count * 2))
        out.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return FileManager.default.createFile(atPath: dst.path, contents: d)
    }

    /// 崩潰救援：wav header 未 finalize 時依實際檔案大小修復
    public static func repairHeader(_ url: URL) {
        guard let fh = try? FileHandle(forUpdating: url) else { return }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > 44 else { return }
        try? fh.seek(toOffset: 4)
        var riff = UInt32(truncatingIfNeeded: Int(size) - 8).littleEndian
        try? fh.write(contentsOf: Data(bytes: &riff, count: 4))   // 磁碟滿時舊式 write 會丟例外當機
        try? fh.seek(toOffset: 0)
        let head = (try? fh.read(upToCount: 8192)) ?? Data()
        if let r = head.range(of: Data("data".utf8)) {
            var dsize = UInt32(truncatingIfNeeded: Int(size) - r.lowerBound - 8).littleEndian
            try? fh.seek(toOffset: UInt64(r.lowerBound + 4))
            try? fh.write(contentsOf: Data(bytes: &dsize, count: 4))
        }
    }
}

/// 崩潰安全 wav 寫入器：單一執行緒使用
public final class CrashSafeWavWriter {
    public let url: URL
    private let fh: FileHandle
    public private(set) var dataBytes: UInt64 = 0
    private var sinceHeader: UInt64 = 0
    private let headerEvery: UInt64 = UInt64(WavIO.bytesPerSecond) * 5

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 同秒重錄防吞：既有檔先改名保留，兩段都活著
        if FileManager.default.fileExists(atPath: url.path) {
            let aside = url.deletingPathExtension().appendingPathExtension("prev-\(Int(Date().timeIntervalSince1970)).wav")
            try? FileManager.default.moveItem(at: url, to: aside)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: WavIO.header(dataBytes: 0))
        else { throw HearbyError("無法建立錄音檔：\(url.lastPathComponent)") }
        fh = try FileHandle(forUpdating: url)
        try fh.seekToEnd()
        self.url = url
    }

    @discardableResult
    public func write(_ buf: AVAudioPCMBuffer) -> Bool {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return true }
        let n = Int(buf.frameLength)
        var pcm = [Int16](repeating: 0, count: n)
        for i in 0..<n { pcm[i] = Int16(max(-1, min(1, ch[i])) * 32767) }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        do { try fh.write(contentsOf: data) } catch { return false }
        dataBytes += UInt64(data.count)
        sinceHeader += UInt64(data.count)
        if sinceHeader >= headerEvery { sinceHeader = 0; patchHeader() }
        return true
    }

    /// 麥克風那一軌：AudioQueue 直接給 16 kHz 單聲道 s16，原樣寫（不經過浮點）
    @discardableResult
    public func write(samples: UnsafeBufferPointer<Int16>) -> Bool {
        guard let base = samples.baseAddress, !samples.isEmpty else { return true }
        let data = Data(bytes: base, count: samples.count * 2)
        do { try fh.write(contentsOf: data) } catch { return false }
        dataBytes += UInt64(data.count)
        sinceHeader += UInt64(data.count)
        if sinceHeader >= headerEvery { sinceHeader = 0; patchHeader() }
        return true
    }

    private func patchHeader() {
        var riff = UInt32(truncatingIfNeeded: 36 + dataBytes).littleEndian
        var dsz = UInt32(truncatingIfNeeded: dataBytes).littleEndian
        do {
            try fh.seek(toOffset: 4); try fh.write(contentsOf: Data(bytes: &riff, count: 4))
            try fh.seek(toOffset: 40); try fh.write(contentsOf: Data(bytes: &dsz, count: 4))
            fsync(fh.fileDescriptor)
            try fh.seek(toOffset: 44 + dataBytes)
        } catch { _ = try? fh.seekToEnd() }
    }

    private var closed = false
    public func close() {
        guard !closed else { return }
        closed = true
        patchHeader()
        try? fh.close()
    }
    deinit { close() }
}
