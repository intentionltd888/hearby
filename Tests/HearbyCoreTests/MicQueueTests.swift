// MicQueueTests — 麥克風一軌的零件：等待上限、s16 音量尺度、s16 原樣寫檔（全部沙箱、不開音訊裝置）
import Foundation
import XCTest
@testable import HearbyCore

final class MicQueueTests: XCTestCase {
    // MARK: 等待上限

    func testBoundedReturnsResultWhenWorkIsFast() throws {
        let r = Bounded.run(1) { 42 }
        XCTAssertEqual(try r?.get(), 42)
    }

    func testBoundedGivesUpAtTimeoutAndDoesNotWaitForWork() {
        let t0 = Date()
        let r = Bounded.run(0.3) { Thread.sleep(forTimeInterval: 3); return 1 }
        let waited = Date().timeIntervalSince(t0)
        XCTAssertNil(r, "卡住的工作＝逾時回 nil")
        XCTAssertLessThan(waited, 1.0, "等的一方只等到上限，不陪著卡")
    }

    func testBoundedPassesThrownErrors() {
        let r = Bounded.run(1) { () throws -> Int in throw HearbyError("壞了") }
        XCTAssertThrowsError(try r?.get()) { XCTAssertEqual($0.localizedDescription, "壞了") }
    }

    // MARK: s16 的音量跟錄音電平表、WavIO.blockLevels 同尺度

    func testInt16LevelMatchesBlockLevels() {
        let pcm: [Int16] = (0..<1600).map { Int16(8000 * sin(Double($0) * 2 * .pi * 440 / 16000)) }
        let direct = pcm.withUnsafeBufferPointer { rmsLevel($0) }
        let block = WavIO.blockLevels(pcm, blockMs: 100)
        XCTAssertEqual(block.count, 1)
        XCTAssertEqual(direct, block[0], accuracy: 0.0001)
        XCTAssertGreaterThan(direct, Pipeline.silence, "正常講話音量在「有聲音」門檻之上")
        XCTAssertEqual([Int16]().withUnsafeBufferPointer { rmsLevel($0) }, 0)
        let loud = [Int16](repeating: .min, count: 160)
        XCTAssertEqual(loud.withUnsafeBufferPointer { rmsLevel($0) }, 1, "封頂 1")
    }

    // MARK: s16 原樣寫檔

    func testWriterWritesInt16SamplesAsIs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hearby-mic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mic.wav")
        let w = try CrashSafeWavWriter(url: url)
        let chunk: [Int16] = (0..<1600).map { Int16(truncatingIfNeeded: $0 * 37 - 30000) }
        for _ in 0..<60 { XCTAssertTrue(chunk.withUnsafeBufferPointer { w.write(samples: $0) }) }  // 6 秒：跨過一次每 5 秒的表頭回填
        XCTAssertTrue([Int16]().withUnsafeBufferPointer { w.write(samples: $0) }, "空的一格不算失敗")
        w.close()
        XCTAssertEqual(WavIO.durationMs(of: url), 6000)
        XCTAssertEqual(WavIO.readPCM(url, fromMs: 0, toMs: 100), chunk, "位元組原樣、little-endian")
        XCTAssertEqual(WavIO.readPCM(url, fromMs: 5900, toMs: 6000), chunk)
        // 表頭的長度欄在關檔時補對：不靠檔尾推算也讀得到
        let head = try Data(contentsOf: url).prefix(44)
        let dataLen = head[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: dataLen), 6 * 32000)
    }
}
