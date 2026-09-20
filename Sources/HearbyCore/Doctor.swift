// Doctor — 七項狀態，一次看完（CLI --doctor 與設定頁「檢查現在正不正常」共用）
//
// 七項：①系統 ②麥克風 ③系統聲 ④聽打模型 ⑤整理方式 ⑥磁碟 ⑦資料夾
// 每項一行：ok／warn／missing／unknown＋一句人話。不猜、不裝死：查不到就寫 unknown 與原因。

import AVFoundation
import Foundation

public struct DoctorItem: Equatable {
    public enum Status: String { case ok, warn, missing, unknown }
    public let name: String
    public let status: Status
    public let detail: String
    public init(_ name: String, _ status: Status, _ detail: String) {
        self.name = name; self.status = status; self.detail = detail
    }
}

public struct DoctorReport {
    public let items: [DoctorItem]
    public var allOK: Bool { items.allSatisfy { $0.status == .ok } }

    /// 終端機格式
    public var text: String {
        var out = "Hearby doctor\n"
        for i in items {
            let tag: String
            switch i.status {
            case .ok: tag = "  ok  "
            case .warn: tag = "  警  "
            case .missing: tag = "  缺  "
            case .unknown: tag = "  ？  "
            }
            out += "\(tag) \(i.name)：\(i.detail)\n"
        }
        return out
    }
}

public enum Doctor {
    public static func run(deep: Bool = false) -> DoctorReport {
        DoctorReport(items: [
            system(), microphone(), systemAudio(), model(), provider(deep: deep), disk(), folder(),
        ])
    }

    // ① 系統：macOS 14+、Apple Silicon
    static func system() -> DoctorItem {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let ver = "\(v.majorVersion).\(v.minorVersion)"
        var uts = utsname(); uname(&uts)
        let arch = withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        if arch != "arm64" { return DoctorItem("系統", .missing, "macOS \(ver)，\(arch)——只支援 Apple Silicon") }
        if v.majorVersion < 14 { return DoctorItem("系統", .missing, "macOS \(ver)——需要 14 以上") }
        return DoctorItem("系統", .ok, "macOS \(ver)，Apple Silicon")
    }

    // ② 麥克風
    static func microphone() -> DoctorItem {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return DoctorItem("麥克風", .ok, "已允許")
        case .notDetermined: return DoctorItem("麥克風", .missing, "還沒問過——第一次錄音會問，按「允許」")
        case .denied: return DoctorItem("麥克風", .missing, "被拒絕——系統設定 › 隱私權與安全性 › 麥克風 › Hearby 打開")
        case .restricted: return DoctorItem("麥克風", .missing, "受管理限制")
        @unknown default: return DoctorItem("麥克風", .unknown, "狀態不明")
        }
    }

    // ③ 系統聲：14.4+ 走 Core Audio process tap（不是螢幕錄製那類權限）；14.0–14.3 退路 ScreenCaptureKit
    static func systemAudio() -> DoctorItem {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let tap = v.majorVersion > 14 || (v.majorVersion == 14 && v.minorVersion >= 4)
        if tap {
            return DoctorItem("系統聲", .ok, "可用（process tap）；只在「線上會議」情境才會要求權限")
        }
        return DoctorItem("系統聲", .warn, "macOS \(v.majorVersion).\(v.minorVersion) 走螢幕錄製退路，每次更新可能要重給權限")
    }

    // ④ 聽打模型
    static func model() -> DoctorItem {
        if let m = SharedPaths.installedModel() {
            let size = (try? FileManager.default.attributesOfItem(atPath: m.resolvingSymlinksInPath().path)[.size] as? Int64) ?? 0
            let gb = Double(size) / 1_073_741_824
            let want = ModelCatalog.whisper.bytes
            if m.lastPathComponent == ModelCatalog.whisper.file, want > 0, size != want {
                return DoctorItem("聽打模型", .warn, String(format: "檔案大小不對（%.2f GB，應該是 %.2f GB）——可能沒下載完。把它移走後重開 Hearby 會重新下載：%@", gb, Double(want) / 1_073_741_824, m.path))
            }
            return DoctorItem("聽打模型", .ok, String(format: "已在（%.1f GB）%@", gb, m.deletingLastPathComponent().path))
        }
        return DoctorItem("聽打模型", .missing, "還沒下載（1.6 GB）——精靈第一頁按「開始設定」就會在背景下")
    }

    // ⑤ 整理方式：none／claude／codex；deep＝真的問 CLI 有沒有登入
    static func provider(deep: Bool) -> DoctorItem {
        let p = Providers.current()
        if p.id == "none" { return DoctorItem("整理方式", .ok, "只要逐字稿（不用帳號）") }
        if !deep {
            let bin = p.id == "claude" ? ClaudeCLI.binaryPath() : CodexCLI.binaryPath()
            guard let b = bin else { return DoctorItem("整理方式", .missing, "\(p.displayName)：還沒裝——設定頁那列按「安裝」") }
            return DoctorItem("整理方式", .ok, "\(p.displayName)（\(b)）；登入狀態加 --deep 才查")
        }
        let st = p.check()
        switch st.level {
        case .ready: return DoctorItem("整理方式", .ok, "\(p.displayName)：\(st.text)")
        case .pending: return DoctorItem("整理方式", .missing, "\(p.displayName)：\(st.text)")
        case .missing: return DoctorItem("整理方式", .missing, "\(p.displayName)：\(st.text)")
        }
    }

    // ⑥ 磁碟：家目錄所在卷剩多少
    static func disk() -> DoctorItem {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        let gb = Double(free) / 1_073_741_824
        if gb < 3 { return DoctorItem("磁碟", .missing, String(format: "只剩 %.1f GB——模型 1.6 GB 加錄音放不下", gb)) }
        if gb < 10 { return DoctorItem("磁碟", .warn, String(format: "剩 %.0f GB", gb)) }
        return DoctorItem("磁碟", .ok, String(format: "剩 %.0f GB", gb))
    }

    // ⑦ 資料夾
    static func folder() -> DoctorItem {
        let r = Paths.root
        if Paths.isWritable(r) {
            var d = r.path
            if !FileManager.default.fileExists(atPath: r.path) { d += "（第一次啟動會建立）" }
            if let m = Paths.mirror { d += "（副本→\(m.path)）" }
            return DoctorItem("資料夾", .ok, d)
        }
        return DoctorItem("資料夾", .missing, "\(r.path) 寫不進去")
    }

    // MARK: helpers

    /// 找執行檔：PATH 之外再看幾個使用者常見的安裝位置（app 從 Finder 啟動時 PATH 很窄）
    public static func which(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                 Paths.support.appendingPathComponent("bin").path]
        for d in dirs {
            let p = "\(d)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// 跑一支指令收 stdout+stderr；逾時回 nil
    public static func run(_ bin: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
