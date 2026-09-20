// HearbyLog — 一行一事的檔案 log（~/Library/Logs/Hearby/hearby.log）
// 系統 log 在這版 macOS 會把 NSLog 內容遮成 <private>，查證靠自己的檔。

import Foundation

public enum HearbyLog {
    private static let lock = NSLock()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static var file: URL { Paths.logs.appendingPathComponent("hearby.log") }

    public static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
            // 輪替：超過 5 MB 就把現在這份改名成 hearby.log.1（蓋掉上一份），重新開始
            if let sz = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, sz > 5_000_000 {
                let old = file.appendingPathExtension("1")
                _ = try? FileManager.default.replaceItemAt(old, withItemAt: file)
            }
            if let h = try? FileHandle(forWritingTo: file) {
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: file)
            }
        } catch {
            // log 寫不進去不擋任何事
        }
        #if DEBUG
        FileHandle.standardError.write(Data(line.utf8))
        #endif
    }
}
