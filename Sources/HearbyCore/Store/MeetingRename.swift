// MeetingRename — 改一場的標題。清單顯示的標題就是資料夾名（<日期_時間_標題>），這一場的 id 是主紀錄的檔名，
// 記憶（index.json、MEETINGS、OPEN、PEOPLE…）全部用 id 找這一場——所以改標題＝這些一起換，只改資料夾名路徑就斷了：
//   1. 資料夾：保留原本的「日期_時間_」，標題換新的（取名規則同開完會：Paths.safeTitle；撞名加 -2、-3）
//   2. 夾裡以舊名開頭的檔（.md .m4a .pdf .docx .srt、_舊版N.md、.md.bak-*、翻譯 .en.md…）跟著改名；別的檔不動
//   3. 主紀錄表頭「> Hearby 錄音｜時長 …｜標題」換成新標題；「> 音檔：」指向這一場的檔就換成新路徑。內文不動
//   4. meta.json（這一場的、錄音工作夾的）：title、outName 換新的——之後重新整理照樣寫回這個夾
//   5. 記憶開著：用到舊 id 的地方換成新 id（改到的檔先留 .bak-日期），再照紀錄同步一次（標題行、index 的 title）
//   6. 副本資料夾（設定 mirrorDir）：以舊 id 開頭的副本跟著改名，再寫一次新版
// 正在整理、重新整理、翻譯、匯出的那一場不能改（做完才寫回去的檔會找不到資料夾）。
import Foundation

public enum MeetingRename {
    public struct Report {
        public var oldID = ""
        public var newID = ""
        public var dir: URL
        public var mdURL: URL?
        /// 夾裡改了名字的檔（新名）
        public var renamed: [String] = []
        /// 動到的記憶檔
        public var memory: [String] = []
        /// 記憶檔改之前留的備份
        public var backups: [URL] = []
        /// 副本資料夾裡改了名字（或重寫）的檔
        public var mirror: [URL] = []
        /// 沒做成的（夾裡某個檔改不了名、記憶寫不進去…）；資料夾本身改好了才會走到這裡
        public var warnings: [String] = []
        /// 標題一樣、也沒有要補改的：什麼都沒動
        public var unchanged = false
    }

    /// 標題收成一行（換行變空白、頭尾空白去掉）——跟紀錄表頭寫標題的方式一樣
    public static func oneLine(_ title: String) -> String {
        title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// 夾名開頭的「yyyy-MM-dd_HHmm_」；不是這個格式的夾（使用者自己放進來的）＝沒有前綴
    public static func prefix(of folderName: String) -> String {
        guard let r = folderName.range(of: #"^\d{4}-\d{2}-\d{2}_\d{4}_"#, options: .regularExpression) else { return "" }
        return String(folderName[r])
    }

    /// 改了標題之後的夾名（還沒處理撞名）
    public static func folderName(current: String, title: String) -> String {
        prefix(of: current) + Paths.safeTitle(oneLine(title))
    }

    /// 夾裡的主紀錄：<夾名>.md；沒有就夾裡唯一一份主紀錄（夾名被改過、檔名沒跟上的時候）
    public static func mainRecord(in dir: URL) -> URL? {
        let fm = FileManager.default
        let named = dir.appendingPathComponent(dir.lastPathComponent + ".md")
        if fm.fileExists(atPath: named.path) { return named }
        let mains = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter(MemoryStore.isMainRecord)
        return mains.count == 1 ? mains[0] : nil
    }

    /// 夾裡一個檔改名後叫什麼：以舊 id（或舊夾名）開頭、後面接「.」「_」或什麼都沒有的，開頭換成新名；其他檔＝nil（不動）
    static func renamed(_ name: String, oldID: String, folder: String, newName: String) -> String? {
        for base in [oldID, folder] where !base.isEmpty && name.hasPrefix(base) {
            let rest = name.dropFirst(base.count)
            if rest.isEmpty || rest.hasPrefix(".") || rest.hasPrefix("_") { return newName + rest }
        }
        return nil
    }

    /// 改標題。dir＝這一場的資料夾（會議/ 底下）；title＝新標題
    public static func rename(dir: URL, to title: String) throws -> Report {
        let fm = FileManager.default
        let t = oneLine(title)
        guard !t.isEmpty else { throw HearbyError("標題不能是空的") }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { throw HearbyError("找不到這一場的資料夾：\(dir.path)") }
        guard !MeetingBusy.contains(dir) else { throw HearbyError("這一場正在整理（或重新整理、翻譯、匯出），等它做完再改標題") }
        let folder = dir.lastPathComponent
        let parent = dir.deletingLastPathComponent()
        let md = mainRecord(in: dir)
        let oldID = md?.deletingPathExtension().lastPathComponent ?? folder
        let oldText = md.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let header = oldText.map { RecordMD.parse(md: $0).parts.custom }

        // 新夾名：撞到別場（別的夾、或記憶裡還有同名的一場）就加 -2、-3…；只差大小寫的同一個夾不算撞
        let taken = Set(MemoryStore.knownIDs()).subtracting([oldID, folder])
        func free(_ n: String) -> Bool {
            if n.lowercased() == folder.lowercased() || n == oldID { return true }
            return !taken.contains(n) && !fm.fileExists(atPath: parent.appendingPathComponent(n).path)
        }
        let base = folderName(current: folder, title: t)
        var newName = base
        var k = 2
        while !free(newName) { newName = "\(base)-\(k)"; k += 1 }

        var report = Report(oldID: oldID, newID: newName, dir: dir, mdURL: md)
        let shown = MeetingIndex.split(folderName: folder).1
        if newName == folder, oldID == folder, header == nil || header == t || (header == "" && shown == t) {
            report.unchanged = true
            return report
        }

        // 1. 資料夾
        var newDir = dir
        if newName != folder {
            newDir = parent.appendingPathComponent(newName, isDirectory: true)
            try move(dir, to: newDir)
        }
        report.dir = newDir

        // 2. 夾裡以舊名開頭的檔
        for name in ((try? fm.contentsOfDirectory(atPath: newDir.path)) ?? []).sorted() {
            guard let to = renamed(name, oldID: oldID, folder: folder, newName: newName), to != name else { continue }
            let dst = newDir.appendingPathComponent(to)
            if fm.fileExists(atPath: dst.path), to.lowercased() != name.lowercased() { report.warnings.append("\(name) 沒改名：夾裡已經有 \(to)"); continue }
            do { try move(newDir.appendingPathComponent(name), to: dst); report.renamed.append(to) }
            catch { report.warnings.append("\(name) 沒改名：\(error.localizedDescription)") }
        }
        let newMD = md.map { newDir.appendingPathComponent(renamed($0.lastPathComponent, oldID: oldID, folder: folder, newName: newName) ?? $0.lastPathComponent) }
        report.mdURL = newMD

        // 3. 紀錄表頭：標題、音檔路徑
        if let u = newMD, let text = oldText {
            let out = RecordMD.retitled(md: text, title: t, audio: { path in
                audioPath(path, oldDirs: [dir.path, parent.appendingPathComponent(oldID).path], newDir: newDir, oldID: oldID, folder: folder, newName: newName)
            })
            if out != text {
                do { try out.write(to: u, atomically: true, encoding: .utf8) } catch { report.warnings.append("紀錄表頭沒改到：\(error.localizedDescription)") }
            }
        }

        // 4. meta.json：這一場的、錄音工作夾的
        if var m = Pipeline.loadMeta(newDir) {
            let workID = m.id
            m.title = t; m.outName = newName
            Pipeline.saveMeta(m, to: newDir)
            if let w = workID, !w.isEmpty {
                let work = Pipeline.recordingsDir.appendingPathComponent(w, isDirectory: true)
                if var wm = Pipeline.loadMeta(work), wm.outName == nil || [folder, oldID].contains(wm.outName!) {
                    wm.title = t; wm.outName = newName
                    Pipeline.saveMeta(wm, to: work)
                }
            }
        }

        // 5. 記憶
        if ConfigStore.shared.current.memoryEnabled, fm.fileExists(atPath: Paths.memory.path) {
            let backups = MemoryStore.Backups()
            do {
                report.memory = try MemoryStore.renameMeeting(from: oldID, to: newName, backups: backups)
                if let u = newMD, let r = try MemoryStore.sync(mdURL: u, backups: backups) {
                    for f in r.changed where !report.memory.contains(f) { report.memory.append(f) }
                }
            } catch { report.warnings.append("記憶沒改完：\(error.localizedDescription)（可以再跑一次 --memory-rebuild）") }
            report.backups = backups.made
        }

        // 6. 副本資料夾
        let mr = Mirror.rename(from: oldID, to: newName)
        report.mirror = mr.moved
        for n in mr.skipped { report.warnings.append("副本資料夾的 \(n) 沒改名（那裡已經有新名字的檔）") }
        if let u = newMD, let m = Paths.mirror {
            do {
                try Mirror.copy(u)
                let c = m.appendingPathComponent(u.lastPathComponent)
                if !report.mirror.contains(c) { report.mirror.append(c) }
            } catch { report.warnings.append("副本沒寫成：\(error.localizedDescription)") }
        }

        HearbyLog.write("rename: \(oldID) → \(newName) files=\(report.renamed.count) memory=\(report.memory.joined(separator: ",")) mirror=\(report.mirror.count) warnings=\(report.warnings.count)")
        return report
    }

    /// 搬／改名（不覆寫）。只差大小寫（不分大小寫的磁碟上兩個名字是同一個檔）：先換成暫時的名字再換回來
    static func move(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        guard src.lastPathComponent != dst.lastPathComponent, src.lastPathComponent.lowercased() == dst.lastPathComponent.lowercased() else {
            try fm.moveItem(at: src, to: dst)
            return
        }
        let tmp = src.deletingLastPathComponent().appendingPathComponent(".hearby-rename-\(UUID().uuidString)")
        try fm.moveItem(at: src, to: tmp)
        do { try fm.moveItem(at: tmp, to: dst) } catch { try? fm.moveItem(at: tmp, to: src); throw error }
    }

    /// 「> 音檔：」的路徑是這一場舊資料夾裡的檔：換成新資料夾裡、改過名的那個檔；指到別的地方（例如錄音工作夾）＝不動
    static func audioPath(_ path: String, oldDirs: [String], newDir: URL, oldID: String, folder: String, newName: String) -> String? {
        let p = path as NSString
        let parent = p.deletingLastPathComponent
        guard oldDirs.contains(parent) else { return nil }
        let name = p.lastPathComponent
        return newDir.appendingPathComponent(renamed(name, oldID: oldID, folder: folder, newName: newName) ?? name).path
    }
}

/// 正在被整理、重新整理、翻譯、匯出的場（資料夾）：這些事做完才寫檔，做到一半改了資料夾名，寫回去就找不到地方。
/// 跨程式也要擋（app 在整理、命令列 `--rename` 同一場）：忙的期間對支援資料夾 `locks/` 裡這一場的鎖檔持有 flock，
/// 別的程式試鎖不到＝忙。程式結束（含當掉）系統就放掉鎖；鎖檔本身留著不刪
public enum MeetingBusy {
    private static let lock = NSLock()
    private static var dirs: [String: Int] = [:]
    private static var fds: [String: Int32] = [:]

    static func key(_ u: URL) -> String { u.standardizedFileURL.path }

    /// 這一場的鎖檔（路徑雜湊當檔名）
    static func lockFile(_ k: String) -> URL {
        var h: UInt64 = 0xcbf29ce484222325
        for b in k.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Paths.support.appendingPathComponent("locks", isDirectory: true).appendingPathComponent(String(format: "%016llx.lock", h))
    }

    static func open(_ k: String) -> Int32 {
        let u = lockFile(k)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        return Darwin.open(u.path, O_RDWR | O_CREAT, 0o600)
    }

    public static func begin(_ dir: URL) {
        lock.lock(); defer { lock.unlock() }
        let k = key(dir)
        dirs[k, default: 0] += 1
        guard dirs[k] == 1 else { return }
        let fd = open(k)
        if fd >= 0 {
            _ = flock(fd, LOCK_EX | LOCK_NB)   // 拿不到（別的程式也在忙這一場）也照做：這裡只負責讓別人知道
            fds[k] = fd
        }
    }

    public static func end(_ dir: URL) {
        lock.lock(); defer { lock.unlock() }
        let k = key(dir)
        guard let n = dirs[k] else { return }
        dirs[k] = n > 1 ? n - 1 : nil
        if n == 1, let fd = fds.removeValue(forKey: k) { flock(fd, LOCK_UN); close(fd) }
    }

    public static func contains(_ dir: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let k = key(dir)
        if dirs[k] != nil { return true }
        // 這個程式沒在忙：試鎖一下，鎖不到＝別的程式正在忙這一場
        guard FileManager.default.fileExists(atPath: lockFile(k).path) else { return false }
        let fd = open(k)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return errno == EWOULDBLOCK
    }
}
