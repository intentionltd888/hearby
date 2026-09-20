// Installer.swift — 從 DMG 直接雙擊也能裝：自己搬進「應用程式」、加進 Dock、從那裡重新打開
//
// DMG 是唯讀映像，拖曳過程不會執行任何程式，所以「拖完自動做事」做不到；能做的是兩條路：
//   ① 使用者直接雙擊 DMG 裡的 Hearby → 這裡接手：問一次 → 複製到 /Applications → 加進 Dock → 從新位置打開 → 退出舊的、退出磁碟映像
//   ② 使用者照舊拖進「應用程式」再打開 → 第一次從 /Applications 啟動時把自己加進 Dock（只做一次，見 main.swift）
// 權限（麥克風、螢幕錄製）綁的是「路徑＋簽名」，所以一定要先落在 /Applications 才開始要權限。
// Hearby 平常是選單列 app（.accessory，跑起來沒有 Dock 圖示）；釘在 Dock 的那顆是「打開它的入口」。
import AppKit
import HearbyCore

enum Installer {
    static let appName = "Hearby"
    static var installedURL: URL { URL(fileURLWithPath: "/Applications/\(appName).app") }

    /// 從磁碟映像跑（含 macOS 對「下載回來的 app」套的 App Translocation 隨機路徑）
    static var isRunningFromDiskImage: Bool {
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Volumes/") || p.contains("/AppTranslocation/")
    }
    static var isRunningFromApplications: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    /// 「應用程式」裡已經有同一顆、同一版的 Hearby（bundle id 與 build 都相同）
    static var sameBuildAlreadyInstalled: Bool {
        guard let there = Bundle(url: installedURL), let mine = Bundle.main.bundleIdentifier, there.bundleIdentifier == mine else { return false }
        let b = { (x: Bundle) in x.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
        return b(there) != nil && b(there) == b(Bundle.main)
    }

    /// DMG 裡雙擊的入口。問一次；同意就自己裝好並從 /Applications 重開（本行程隨後 exit），拒絕就教他拖然後 exit。
    /// autoYes＝命令列 `--install`（測試鉤），不跳問句直接裝。
    @MainActor static func offerInstallFromDiskImage(autoYes: Bool = false) {
        NSApp.setActivationPolicy(.regular)  // 選單列 app 預設不露臉，問句要跳到前面來
        NSApp.activate(ignoringOtherApps: true)
        var yes = autoYes
        if !yes {
            let a = NSAlert()
            a.messageText = "把 Hearby 放進「應用程式」？"
            a.informativeText = "Hearby 會自己複製到「應用程式」、加進 Dock，然後從那裡打開。之後直接點 Dock 上的圖示就好。"
            a.addButton(withTitle: "放進應用程式並打開")
            a.addButton(withTitle: "我自己拖")
            yes = a.runModal() == .alertFirstButtonReturn
        }
        guard yes else {
            let a = NSAlert()
            a.messageText = "先安裝再打開"
            a.informativeText = "請把 Hearby 拖進「應用程式」資料夾，再從那裡打開。"
            a.runModal()
            exit(0)
        }
        do {
            try install()
        } catch {
            HearbyLog.write("install failed: \(error)")
            let a = NSAlert()
            a.messageText = "沒辦法自動放進「應用程式」"
            a.informativeText = "\(error.localizedDescription)\n\n請把 Hearby 拖進「應用程式」資料夾，再從那裡打開。"
            a.runModal()
            exit(1)
        }
        // 從新位置重開；把磁碟映像路徑傳過去，讓新的那顆在我們退出後把它退出
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        // 同 bundle id 已在跑時，openApplication 只會「切到」正在跑的這顆（就是 DMG 裡的自己）；要明講開新實例
        cfg.createsNewApplicationInstance = true
        if let v = diskImageVolume() { cfg.arguments = ["--eject", v] }
        NSWorkspace.shared.openApplication(at: installedURL, configuration: cfg) { _, err in
            if let err { HearbyLog.write("relaunch failed: \(err)") }
            DispatchQueue.main.async { exit(0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }  // 保險：completion 沒回也退
    }

    /// 複製到 /Applications（舊版先請它退出、丟垃圾桶可還原，不 rm），再釘進 Dock
    static func install() throws {
        let fm = FileManager.default
        let src = Bundle.main.bundleURL
        let dst = installedURL
        let me = ProcessInfo.processInfo.processIdentifier
        // 不寫死 bundle id 當後備：install() 只會從 .app 裡跑（DMG 雙擊），取不到 id 就沒有「同一顆 app 的舊行程」可找
        let others = Bundle.main.bundleIdentifier
            .map { NSRunningApplication.runningApplications(withBundleIdentifier: $0).filter { $0.processIdentifier != me } } ?? []
        // 舊的那顆正在錄音就不裝——裝＝把它結束掉，會切斷進行中的會議。錄音檔每幾秒寫一次：最近 15 秒有寫＝正在錄
        if !others.isEmpty, let dirs = try? fm.contentsOfDirectory(at: Pipeline.recordingsDir, includingPropertiesForKeys: nil) {
            let recording = dirs.contains { d in
                guard let m = (try? fm.attributesOfItem(atPath: d.appendingPathComponent("mic.wav").path))?[.modificationDate] as? Date else { return false }
                return Date().timeIntervalSince(m) < 15
            }
            if recording { throw HearbyError("另一個 Hearby 正在錄音。請先停止那一場，再回來安裝。") }
        }
        for r in others { r.terminate() }
        let deadline = Date().addingTimeInterval(6)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        for r in others where !r.isTerminated { r.forceTerminate() }
        if fm.fileExists(atPath: dst.path) {
            // /Applications/Hearby.app 已經有東西：是同一個 app（bundle id 相同）才換掉；別人的同名 app 不碰
            let theirs = Bundle(url: dst)?.bundleIdentifier
            if let mine = Bundle.main.bundleIdentifier, let theirs, theirs != mine {
                throw HearbyError("「應用程式」裡已經有另一個叫 Hearby 的 app（\(theirs)），沒有覆蓋它。請先把它改名或移走。")
            }
            var trashed: NSURL?
            try fm.trashItem(at: dst, resultingItemURL: &trashed)
        }
        try fm.copyItem(at: src, to: dst)
        // 從瀏覽器下載的 DMG 帶隔離標記，copyItem 會原樣帶過去：不拿掉的話，從 /Applications 重開時系統再警告一次，
        // 還可能再被 App Translocation 搬到隨機路徑＝又判成「從磁碟映像跑」＝同一個安裝問句無限重複。
        // 第一次打開時 Gatekeeper 已經驗過這顆（公證＋簽名），這裡拿掉標記是這類自裝流程的標準做法。
        let x = Process()
        x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        x.arguments = ["-dr", "com.apple.quarantine", dst.path]
        x.standardOutput = FileHandle.nullDevice; x.standardError = FileHandle.nullDevice
        try? x.run(); x.waitUntilExit()
        HearbyLog.write("installed to \(dst.path) from \(src.path)")
        Dock.ensure(appURL: dst)
    }

    /// 正在跑的這顆若在 /Volumes/<名稱>/ 底下就回那個掛載點；被 App Translocation 搬走的話找 /Volumes/Hearby
    static func diskImageVolume() -> String? {
        let p = Bundle.main.bundlePath
        if p.hasPrefix("/Volumes/") {
            let parts = p.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2 { return "/Volumes/\(parts[1])" }
        }
        let guess = "/Volumes/\(appName)"
        if FileManager.default.fileExists(atPath: "\(guess)/\(appName).app") { return guess }
        return nil
    }

    /// `--eject /Volumes/Hearby`：從 /Applications 重開後把磁碟映像退出（舊行程要先走完，所以延後；忙碌就再試一次 -force）
    static func ejectLater(_ volume: String) {
        // 只退出「/Volumes 底下、裡面真的有 Hearby.app」的映像：這個參數誰都能從命令列給，不能拿來卸別人的磁碟
        let v = URL(fileURLWithPath: volume).standardizedFileURL.path
        guard v.hasPrefix("/Volumes/"), v.dropFirst("/Volumes/".count).contains("/") == false,
              FileManager.default.fileExists(atPath: v + "/Hearby.app") else {
            HearbyLog.write("eject refused: \(volume)")
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            func detach(_ force: Bool) -> Bool {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                p.arguments = ["detach", volume] + (force ? ["-force"] : [])
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { return false }
                p.waitUntilExit()
                return p.terminationStatus == 0
            }
            if !detach(false) {
                Thread.sleep(forTimeInterval: 3)
                _ = detach(true)
            }
            HearbyLog.write("ejected \(volume)")
        }
    }
}

enum Dock {
    /// 把 app 釘進 Dock（已經在就不動）。改的是 com.apple.dock 的 persistent-apps，重啟 Dock 才會顯示（閃一下，只此一次）。
    @discardableResult static func ensure(appURL: URL) -> Bool {
        let domain = "com.apple.dock" as CFString
        let key = "persistent-apps" as CFString
        // 讀不到或型別不對就收手：拿空陣列寫回去＝整條 Dock 只剩這一顆
        guard var apps = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] else { return false }
        let want = appURL.standardizedFileURL.path
        let already = apps.contains { tile in
            guard let td = tile["tile-data"] as? [String: Any],
                  let fd = td["file-data"] as? [String: Any],
                  let s = fd["_CFURLString"] as? String,
                  let u = URL(string: s) else { return false }
            return u.standardizedFileURL.path == want
        }
        if already { return false }
        apps.append([
            "tile-data": ["file-data": ["_CFURLString": "file://\(want)/", "_CFURLStringType": 15]],
            "tile-type": "file-tile",
        ])
        CFPreferencesSetAppValue(key, apps as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
        HearbyLog.write("dock: pinned \(want)")
        return true
    }
}
