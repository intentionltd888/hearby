// Cli — 旗標分派（先於任何 AppKit 初始化）
//   --doctor [--deep]     七項狀態
//   --version / --selftest
//   --import <檔>         聽打並整理一個音檔／影片（終端機用；沙箱設 HEARBY_OUTPUT_ROOT）
//   --process <工作夾>    對既有錄音工作夾（mic.wav／system.wav）跑整理
//   --repolish <md> "<修正>"  重新整理全篇
//   --translate <md> [--lang en|ja|zh-CN]  翻譯另存
//   --memory-rebuild [<md>]  記憶（MEETINGS／OPEN／PEOPLE／index.json）同步成紀錄現在的樣子；不給檔＝每一場
//   --rename <md 或資料夾> "<新標題>"  改一場的標題：資料夾、夾裡的檔名、紀錄表頭、meta.json、記憶裡的 id、副本一起換
//   --provider none|claude|codex|endpoint  覆寫這次用的整理方式（endpoint＝設定裡的本機模型）
//   --export-word <md> [--company X --recorder Y --units Z]  出 Word（.docx；Pages 直接開）
//   --export-html <md> [--company X --recorder Y --units Z]  出版型 HTML（檢視用）
//   --export-pdf <md> [--company X --recorder Y --units Z]   出 PDF（跟 app 內「存成 PDF」同一條，排完才結束）
//   --record <秒> [--source room|online] [--pause-at 秒 --resume-at 秒] [--reopen-mic-at 秒] [--stall-mic-at 秒] [--no-process]  開發用真錄音（可中途暫停、強制重開麥克風、讓麥克風斷音；秒數算牆上時間）
//   --snapshot <資料夾> [--dark] [--scale N]  離線把每個畫面畫成 PNG（設計檢視用，不需要螢幕錄製權限；N 倍像素）
//   --voices  列出這台 Mac 記得的聲音；--voices-scan <md|音檔> 看一場有哪些聲音、認得誰（不存任何東西；md＝分軌還在就分軌切）
//   --voice-remember <md|音檔> --voice mic:S1 --name 名字 --consent  記住這個聲音（要本人同意）；--voice-forget <名字> 忘記
import AppKit
import Foundation
import HearbyCore
import HearbyUI

enum Cli {
    /// 這個 app 認得的全部 `--旗標`（含圖形介面自己會讀的 --install／--eject）
    static let known: Set<String> = [
        "--help", "--version", "--selftest", "--check-resources", "--doctor", "--deep", "--import", "--process", "--repolish",
        "--translate", "--lang", "--provider", "--title", "--scene", "--export-word", "--export-html", "--company", "--recorder",
        "--units", "--record", "--source", "--no-process", "--snapshot", "--dark", "--memory-rebuild", "--install", "--eject",
        "--pause-at", "--resume-at", "--export-pdf", "--scale", "--reopen-mic-at", "--stall-mic-at",
        "--voices", "--voices-scan", "--voice-remember", "--voice", "--name", "--consent", "--voice-forget", "--rename",
    ]
    /// 後面要接一個值的旗標
    static let takesValue: Set<String> = [
        "--import", "--process", "--repolish", "--translate", "--lang", "--provider", "--title", "--scene", "--export-word",
        "--export-html", "--company", "--recorder", "--units", "--record", "--source", "--snapshot", "--eject",
        "--pause-at", "--resume-at", "--export-pdf", "--scale", "--reopen-mic-at", "--stall-mic-at",
        "--voices-scan", "--voice-remember", "--voice", "--name", "--voice-forget", "--rename",
    ]
    static let usage = """
    Hearby \(HearbyVersion.version) (build \(HearbyVersion.build))
    不帶旗標＝打開 app。命令列：
      --doctor [--deep]            七項狀態體檢
      --import <檔> [--title 標題] [--provider none|claude|codex|endpoint]   聽打並整理一個音檔／影片
      --process <工作夾>           對既有錄音工作夾跑整理
      --repolish <md> "<修正>"     重新整理全篇
      --translate <md> [--lang en|ja|zh-CN]
      --memory-rebuild [<md>]      記憶同步成紀錄現在的樣子（改過紀錄之後跑；不給檔＝每一場）
      --rename <md 或資料夾> "<新標題>"   改一場的標題（資料夾、檔名、紀錄表頭、記憶、副本一起換；不要自己改資料夾名）
      --export-word <md> / --export-html <md> / --export-pdf <md> [--company X --recorder Y --units Z]
      --snapshot <資料夾> [--dark] [--scale N]   每個畫面畫成 PNG（設計檢視；N 倍像素）
      --voices / --voices-scan <md|音檔>   認聲音（實驗，macOS 15 以上）：記得誰／這場有哪些聲音
      --voice-remember <md|音檔> --voice mic:S1 --name 名字 --consent   記住一個聲音（本人同意才加 --consent）
      --voice-forget <名字>        忘記這個人的聲音
      --version / --help
    """
    /// 認聲音的命令列（見檔頭）
    static func voices(_ value: (String) -> String?) -> Int32 {
        func mmss(_ t: Double) -> String { let s = Int(t); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60) }
        /// 紀錄 md＝這場的音源（分軌還在就分軌）；音檔＝那一個檔（mic.wav／system.wav 認得出是哪一軌）
        func sources(_ p: String) -> [Voices.Source] {
            let u = URL(fileURLWithPath: p)
            if u.pathExtension == "md" { return Voices.sources(meetingDir: u.deletingLastPathComponent(), m4a: Repolish.audioURL(mdURL: u, audioLine: "")) }
            guard FileManager.default.fileExists(atPath: u.path) else { return [] }
            let t = u.lastPathComponent == "mic.wav" ? "mic" : (u.lastPathComponent == "system.wav" ? "system" : "mix")
            return [Voices.Source(url: u, track: t)]
        }
        if let n = value("--voice-forget") {
            do { print(try Voices.forget(n) ? "ok  忘記了「\(n)」的聲音" : "這台 Mac 沒有記「\(n)」的聲音"); return 0 }
            catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); return 1 }
        }
        guard Voices.supported, let e = Voices.engine else {
            FileHandle.standardError.write(Data("認聲音要 macOS 15 以上\n".utf8))
            return 1
        }
        let ps = Voices.people()
        if value("--voices-scan") == nil, value("--voice-remember") == nil {
            print(ps.isEmpty ? "這台 Mac 還沒記住任何人的聲音" : ps.map { "- \($0.name)｜\(Voices.trackName($0.track))｜\(Int($0.seconds / 60)) 分鐘的聲音｜\($0.sources.count) 場｜\($0.consent)" }.joined(separator: "\n"))
            print(ConfigStore.shared.current.voicesEnabled ? "整理時認聲音：開著" : "整理時認聲音：關著（設定裡打開）")
            return 0
        }
        let arg = value("--voices-scan") ?? value("--voice-remember")!
        let srcs = sources(arg)
        guard !srcs.isEmpty else { FileHandle.standardError.write(Data("找不到錄音：\(arg)\n".utf8)); return 1 }
        let meeting = URL(fileURLWithPath: arg).pathExtension == "md" ? URL(fileURLWithPath: arg).deletingPathExtension().lastPathComponent : URL(fileURLWithPath: arg).deletingLastPathComponent().lastPathComponent
        do {
            print("音源：" + srcs.map { Voices.trackName($0.track) }.joined(separator: "、"))
            let cl = try Voices.clusters(of: srcs, engine: e) { print("  \($0)") }
            let m = Voices.match(cl, ps, model: e.model)
            if let id = value("--voice-remember") != nil ? value("--voice") : nil {
                guard let name = value("--name"), CommandLine.arguments.contains("--consent") else {
                    FileHandle.standardError.write(Data("記住聲音要 --name 名字，而且本人同意才加 --consent\n".utf8)); return 2
                }
                guard let c = cl.first(where: { $0.id == id }) else { FileHandle.standardError.write(Data("這場沒有 \(id) 這個聲音（先跑 --voices-scan 看）\n".utf8)); return 1 }
                let p = try Voices.remember(name: name, cluster: c, model: e.model, source: meeting)
                print("ok  記住「\(p.name)」的聲音（\(Voices.trackName(p.track))；累計 \(Int(p.seconds / 60)) 分鐘、\(p.sources.count) 場；\(p.consent)）")
                return 0
            }
            print("這場有 \(cl.filter { $0.seconds >= Voices.minSeconds }.count) 個聲音（\(Int(Voices.minSeconds)) 秒以下的不算）")
            for c in cl.sorted(by: { $0.seconds > $1.seconds }) where c.seconds >= Voices.minSeconds {
                let who = m[c.id].map { "認得：\($0.name)（像 \(String(format: "%.2f", $0.score))）" } ?? "沒認出"
                let eg = c.spans.filter { $0.upperBound - $0.lowerBound >= 3 }.prefix(3).map { "[\(mmss($0.lowerBound))]" }.joined(separator: " ")
                print("- \(c.id)｜\(Voices.trackName(c.track))｜\(c.seconds < 60 ? "不到 1" : String(Int(c.seconds / 60))) 分鐘｜\(who)｜例：\(eg)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("認聲音失敗：\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func dispatch(_ args: [String]) -> Int32? {
        let a = Array(args.dropFirst())
        let set = Set(a)
        if !a.isEmpty { setvbuf(stdout, nil, _IOLBF, 0) }
        func value(after flag: String) -> String? {
            guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
            return a[i + 1]
        }
        if set.contains("--help") || set.contains("-h") { print(usage); return 0 }
        // 不認得的 `--旗標`：印用法、結束。以前會一路落到最後的 return nil＝把圖形介面開起來而且不返回，
        // 在腳本或終端機裡打錯一個字就多開一個 app。單一破折號的（-psn_…、-NSxxx、-AppleLanguages）是系統給的，不管。
        // 旗標後面接的「值」不檢查（`--title "--第一季"` 的第二個字串是標題，不是旗標）
        var skip = 0
        let flags = a.filter { x in
            if skip > 0 { skip -= 1; return false }
            skip = takesValue.contains(x) ? 1 : 0
            // --repolish 後面接兩個值（檔案、修正內容）；第二個若其實是已知旗標就不吞
            if x == "--repolish", let j = a.firstIndex(of: x), a.count > j + 2, !known.contains(a[j + 2]) { skip = 2 }
            // --memory-rebuild 的檔可給可不給
            if x == "--memory-rebuild", let j = a.firstIndex(of: x), a.count > j + 1, !known.contains(a[j + 1]) { skip = 1 }
            // --rename 後面接兩個值（那一場、新標題）；新標題長得像旗標（「--第一季」）也照樣是標題
            if x == "--rename", let j = a.firstIndex(of: x), a.count > j + 2, !known.contains(a[j + 2]) { skip = 2 }
            return true
        }
        if let bad = flags.first(where: { $0.hasPrefix("--") && !known.contains($0) }) {
            FileHandle.standardError.write(Data("不認得的旗標：\(bad)\n\n\(usage)\n".utf8))
            return 2
        }
        // 要接值卻沒給（`--record` 後面沒秒數）：跟打錯字一樣，不能落到最後把圖形介面開起來
        for (i, x) in a.enumerated() where takesValue.contains(x) && (i + 1 >= a.count || known.contains(a[i + 1])) {
            FileHandle.standardError.write(Data("\(x) 後面要接一個值\n\n\(usage)\n".utf8))
            return 2
        }
        if set.contains("--version") { print("Hearby \(HearbyVersion.version) (build \(HearbyVersion.build))"); return 0 }
        if set.contains("--voices") || set.contains("--voices-scan") || set.contains("--voice-remember") || set.contains("--voice-forget") {
            return voices(value)
        }
        // 出貨閘（build.sh 會跑）：品牌資源包必須能從 app 自己的路徑找到，不能靠開發機的 .build
        if set.contains("--check-resources") {
            if let b = Brand.resourceBundle, Brand.logotype != nil { print("ok  資源包：\(b.bundleURL.path)"); return 0 }
            print("✗ 找不到品牌資源包（hearby-mac_HearbyUI.bundle）——app 會退成文字字標"); return 1
        }
        if set.contains("--doctor") {
            let r = Doctor.run(deep: set.contains("--deep"))
            print(r.text, terminator: "")
            return r.allOK ? 0 : 1
        }
        if set.contains("--selftest") {
            do {
                let made = try Paths.ensure()
                try ConfigStore.shared.update { $0.scene = "meeting" }
                ConfigStore.shared.reset()
                guard ConfigStore.shared.current.scene == "meeting" else { print("✗ config 往返失敗"); return 1 }
                print("ok  資料夾：\(Paths.root.path)（新建 \(made.count) 個）")
                print("ok  config：\(ConfigStore.shared.url.path)")
                print("ok  log：\(HearbyLog.file.path)")
                return 0
            } catch { print("✗ \(error)"); return 1 }
        }
        let providerOverride = value(after: "--provider")
        func provider() -> Provider { providerOverride.map { Providers.make($0) } ?? Providers.current() }

        if let dir = value(after: "--process") {
            let d = URL(fileURLWithPath: dir)
            var m = Pipeline.loadMeta(d) ?? MeetingMeta()
            if m.seconds <= 0 { m.seconds = Double(WavIO.durationMs(of: d.appendingPathComponent("mic.wav")) ?? 0) / 1000 }
            m.micMax = 1; m.sysMax = 1
            if let t = value(after: "--title") { m.title = t }
            if let sc = value(after: "--scene") { m.scene = sc }
            return runPipeline(dir: d, meta: m, provider: provider())
        }
        if let file = value(after: "--import") {
            let src = URL(fileURLWithPath: file)
            // 沒有聽打模型就先講，不要把整個檔轉完才失敗（還會留一個沒人要的工作夾）
            guard SharedPaths.installedModel() != nil else {
                print("✗ 還沒有聽打模型（\(SharedPaths.whisperModelFile)，約 1.6 GB）。打開 Hearby 一次，它會自己下載；下載好再回來跑這個指令。")
                return 1
            }
            guard let dir = (try? Pipeline.newWorkDir())?.dir else { print("✗ 建不了工作夾（\(Pipeline.recordingsDir.path) 寫不進去）"); return 1 }
            let sem = DispatchSemaphore(value: 0)
            var result: Int32 = 1
            Task {
                do {
                    let probe = try await MediaImporter.probe(src)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    print("轉檔中…（\(Fmt.dur(probe.seconds))）")
                    let secs = try await MediaImporter.transcode(probe, to: dir.appendingPathComponent("mic.wav")) { _ in }
                    var m = MeetingMeta()
                    m.started = Date(); m.imported = true; m.sourceFile = src.path
                    m.title = value(after: "--title") ?? src.deletingPathExtension().lastPathComponent
                    m.seconds = secs; m.micMax = 1; m.sysMax = 0
                    Pipeline.saveMeta(m, to: dir)
                    result = runPipeline(dir: dir, meta: m, provider: provider())
                } catch {
                    print("✗ \(error.localizedDescription)")
                    // 匯入失敗的工作夾不要變成「還沒整理的錄音」：來源檔還在，要重來就再匯入一次
                    try? "import-failed".write(to: dir.appendingPathComponent(".ignored"), atomically: true, encoding: .utf8)
                    result = 1
                }
                sem.signal()
            }
            sem.wait()
            return result
        }
        if let md = value(after: "--translate") {
            let lang = value(after: "--lang") ?? "en"
            do { let u = try Repolish.translate(mdURL: URL(fileURLWithPath: md), language: lang, provider: provider()); print("ok  \(u.path)"); return 0 }
            catch { print("✗ \(error.localizedDescription)"); return 1 }
        }
        if let md = value(after: "--repolish") {
            // 第二個值是修正內容；沒給、或給的其實是下一個旗標（--provider…）就當作沒有修正內容，不要把旗標名寫進修正紀錄
            let i = a.firstIndex(of: "--repolish")!
            let next = a.count > i + 2 ? a[i + 2] : ""
            let corr = known.contains(next) ? "" : next
            do {
                let (u, s) = try Repolish.whole(mdURL: URL(fileURLWithPath: md), corrections: corr, provider: provider()) { print("  \($0)") }
                print("ok  \(u.path)\n\(s)")
                return 0
            } catch { print("✗ \(error.localizedDescription)"); return 1 }
        }
        if let md = value(after: "--export-html") {
            guard let raw = try? String(contentsOf: URL(fileURLWithPath: md), encoding: .utf8) else { print("✗ 讀不到"); return 1 }
            var h = DocHeader.prefill(md: raw, language: DocLabels.language(of: URL(fileURLWithPath: md)))
            if let c = value(after: "--company") { h.company = c }
            if let r = value(after: "--recorder") { h.recorder = r }
            if let u = value(after: "--units") { h.units = u }
            let out = URL(fileURLWithPath: md).deletingPathExtension().appendingPathExtension("html")
            do { try Html.render(md: RecordMD.clientVersion(md: raw), header: h).write(to: out, atomically: true, encoding: .utf8); print("ok  \(out.path)"); return 0 } catch { print("✗ \(error)"); return 1 }
        }
        if let md = value(after: "--export-word") {
            var h = DocHeader.prefill(md: (try? String(contentsOf: URL(fileURLWithPath: md), encoding: .utf8)) ?? "", language: DocLabels.language(of: URL(fileURLWithPath: md)))
            if let c = value(after: "--company") { h.company = c }
            if let r = value(after: "--recorder") { h.recorder = r }
            if let u = value(after: "--units") { h.units = u }
            switch Exporters.word(mdURL: URL(fileURLWithPath: md), header: h) {
            case .success(let u): print("ok  \(u.path)"); return 0
            case .failure(let e): print("✗ \(e.localizedDescription)"); return 1
            }
        }
        if let md = value(after: "--export-pdf") {
            let u = URL(fileURLWithPath: md)
            var h = DocHeader.prefill(md: (try? String(contentsOf: u, encoding: .utf8)) ?? "", language: DocLabels.language(of: u))
            if let c = value(after: "--company") { h.company = c }
            if let r = value(after: "--recorder") { h.recorder = r }
            if let x = value(after: "--units") { h.units = x }
            return MainActor.assumeIsolated { exportPDF(u, header: h) }
        }
        if let secsText = value(after: "--record"), let secs = Double(secsText) {
            // 開發用：真的錄 N 秒（麥克風；--source online 加系統聲），再跑整理
            let src = AudioSource(rawValue: value(after: "--source") ?? "room") ?? .room
            guard let dir = (try? Pipeline.newWorkDir())?.dir else { print("✗ 建不了工作夾（\(Pipeline.recordingsDir.path) 寫不進去）"); return 1 }
            let rec = DualRecorder(dir: dir, source: src)
            let sem = DispatchSemaphore(value: 0)
            var warns: [String] = []
            var failed: String?
            Task {
                do { warns = try await rec.start() } catch { failed = error.localizedDescription }
                sem.signal()
            }
            sem.wait()
            if let f = failed { print("✗ \(f)"); return 1 }
            print("錄音中 \(Int(secs)) 秒（\(src.label)，系統聲：\(rec.systemAudioActive ? rec.systemAudioMode : "無")）…")
            for w in warns { print("⚠ \(w)") }
            let t0 = Date()
            // 中途暫停（測暫停用）：第 pauseAt 秒按暫停、第 resumeAt 秒按繼續；只按一次
            let pauseAt = value(after: "--pause-at").flatMap(Double.init)
            let resumeAt = value(after: "--resume-at").flatMap(Double.init)
            // 強制重開麥克風一次（測「換裝置」那條路：裝置沒換也照樣停掉、重開，量交界少了多少）
            let reopenAt = value(after: "--reopen-mic-at").flatMap(Double.init)
            var reopened = false
            // 讓麥克風斷音一次（測「幾秒沒收到任何一格就重開」：裝置被拔、系統音訊服務重啟的樣子）
            let stallAt = value(after: "--stall-mic-at").flatMap(Double.init)
            var stalled = false
            while Date().timeIntervalSince(t0) < secs {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                let t = Date().timeIntervalSince(t0)
                if let p = pauseAt, t >= p, rec.pauses.isEmpty, rec.pause() { print(String(format: "  ⏸ 暫停（第 %.1f 秒，已錄 %.1f 秒）", t, rec.recordedSeconds)) }
                if let r = resumeAt, t >= r, rec.isPaused, rec.resume() { print(String(format: "  ▶ 繼續（第 %.1f 秒）", t)) }
                if let r = reopenAt, t >= r, !reopened { reopened = true; rec.reopenMicForTesting(); print(String(format: "  ↻ 重開麥克風（第 %.1f 秒）", t)) }
                if let st = stallAt, t >= st, !stalled { stalled = true; rec.stallMicForTesting(); print(String(format: "  ✂ 麥克風斷音（第 %.1f 秒）", t)) }
                print(String(format: "  mic %.3f  sys %.3f%@", rec.micLevel, rec.sysLevel, rec.isPaused ? "  （暫停中）" : ""))
            }
            let got = rec.stop()
            var m = MeetingMeta()
            m.started = t0; m.seconds = got; m.micMax = rec.micMax; m.sysMax = rec.sysMax; m.source = src.rawValue; m.warnings = warns
            m.pauses = rec.pauses.isEmpty ? nil : rec.pauses
            m.title = value(after: "--title") ?? "錄音測試"
            Pipeline.saveMeta(m, to: dir)
            print("錄了 \(Fmt.dur(got))：mic max \(rec.micMax) sys max \(rec.sysMax) sysBuffers \(rec.sysBufferCount) → \(dir.path)")
            for p in rec.pauses { print(String(format: "  暫停：在第 %.1f 秒（錄到的時間），停了 %.1f 秒", p.atSeconds, p.seconds ?? -1)) }
            if set.contains("--no-process") { return 0 }
            return runPipeline(dir: dir, meta: m, provider: provider())
        }
        if let dir = value(after: "--snapshot") {
            let scale = value(after: "--scale").flatMap(Double.init).map { CGFloat($0) } ?? 1
            return Snapshot.run(into: URL(fileURLWithPath: dir), dark: set.contains("--dark"), scale: scale)
        }
        if set.contains("--memory-rebuild") { return memoryRebuild(value(after: "--memory-rebuild").flatMap { known.contains($0) ? nil : $0 }) }
        if let target = value(after: "--rename") {
            let i = a.firstIndex(of: "--rename")!
            guard a.count > i + 2, !known.contains(a[i + 2]) else {
                FileHandle.standardError.write(Data("--rename 後面要接兩個值：那一場的 md（或資料夾）、新標題\n\n\(usage)\n".utf8))
                return 2
            }
            return rename(target, to: a[i + 2])
        }
        return nil
    }

    /// --rename <md 或資料夾> "<新標題>"：改一場的標題。資料夾、夾裡以舊名開頭的檔、紀錄表頭、meta.json、記憶裡的 id、副本一起換
    static func rename(_ target: String, to title: String) -> Int32 {
        var u = URL(fileURLWithPath: target)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { print("✗ 找不到：\(target)"); return 1 }
        if !isDir.boolValue { u = u.deletingLastPathComponent() }
        guard u.deletingLastPathComponent().resolvingSymlinksInPath().path == Paths.meetings.resolvingSymlinksInPath().path else {
            print("✗ \(u.path) 不在 \(Paths.meetings.path) 底下：只改 Hearby 的會議")
            return 1
        }
        do {
            let r = try MeetingRename.rename(dir: u, to: title)
            if r.unchanged { print("（標題一樣，沒有要改的）"); return 0 }
            print("ok  會議/\(r.newID)/（原本：\(r.oldID)）")
            if !r.renamed.isEmpty { print("  夾裡改名：\(r.renamed.count) 個檔") }
            if !ConfigStore.shared.current.memoryEnabled {
                print("  記憶是關的，沒有動")
            } else if !r.memory.isEmpty {
                print("  記憶：\(r.memory.joined(separator: "、"))" + (r.backups.isEmpty ? "" : "（改之前留了 \(r.backups.map(\.lastPathComponent).joined(separator: "、"))）"))
            }
            if !r.mirror.isEmpty { print("  副本：\(r.mirror.map(\.lastPathComponent).joined(separator: "、"))") }
            for w in r.warnings { print("⚠ \(w)") }
            return r.warnings.isEmpty ? 0 : 1
        } catch { print("✗ \(error.localizedDescription)"); return 1 }
    }

    /// --memory-rebuild [<md>]：記憶同步成紀錄現在的樣子。Hearby 寫的、沒人動過的行換成新版；使用者改過的不動；改到既有的行前先留 .bak-日期
    static func memoryRebuild(_ target: String?) -> Int32 {
        guard ConfigStore.shared.current.memoryEnabled else { print("✗ 記憶是關的，這次沒有寫。到設定打開「記憶」再跑。"); return 1 }
        var urls: [URL]
        if let t = target {
            let u = URL(fileURLWithPath: t)
            guard FileManager.default.fileExists(atPath: u.path) else { print("✗ 找不到：\(t)"); return 1 }
            guard MemoryStore.isMainRecord(u) else { print("✗ \(u.lastPathComponent) 不是一場的主紀錄（翻譯檔、_舊版 備份不進記憶）"); return 1 }
            urls = [u]
        } else {
            urls = MemoryStore.allRecords()
            if urls.isEmpty { print("（\(Paths.meetings.path) 裡還沒有紀錄）"); return 0 }
        }
        var failed = false
        // 單一場、被別的程式改過：跟 Hearby 上次寫的那一版比，改過的名字記進名字確認帳（memory/NAMES.md）
        if target != nil, let u = urls.first {
            if let learned = NameLedger.learnFromEdit(mdURL: u) {
                for e in learned { print("記住名字：\(e.heard) → \(e.name)（\(e.how)）") }
            } else {
                print("（這份跟 Hearby 上次寫的不一樣，但找不到上次那一版的備份，改過的名字沒學到；下次改之前先留 .bak）")
            }
        }
        for r in MemoryStore.sync(urls) {
            let id = r.url.deletingPathExtension().lastPathComponent
            if let e = r.error { print("✗ \(id)：\(e)"); failed = true; continue }
            guard let rep = r.report else { print("—  \(id)：略過"); continue }
            var line = "ok  \(id)：" + (rep.changed.isEmpty ? "已經是最新" : rep.isNew ? "第一次寫進記憶" : "更新 " + rep.changed.joined(separator: "、"))
            if rep.kept > 0 { line += "；你改過或加的 \(rep.kept) 行照舊" }
            print(line)
            for b in rep.backups { print("    備份：\(b.lastPathComponent)") }
        }
        return failed ? 1 : 0
    }

    /// PDF 要 WebKit 排版＋印表，得有 app 的事件迴圈：跑到排完（或 90 秒）就停
    @MainActor static func exportPDF(_ md: URL, header: DocHeader) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var result: Int32 = 1
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            app.stop(nil)
            // stop 要等到下一個事件才生效：塞一個空事件叫醒它
            if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { app.postEvent(e, atStart: false) }
        }
        DispatchQueue.main.async {
            Exporters.pdf(mdURL: md, header: header) { r in
                switch r {
                case .success(let u): print("ok  \(u.path)"); result = 0
                case .failure(let e): print("✗ \(e.localizedDescription)")
                }
                finish()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { if !finished { print("✗ PDF 逾時"); finish() } }
        app.run()
        return result
    }

    static func runPipeline(dir: URL, meta: MeetingMeta, provider: Provider) -> Int32 {
        let p = Pipeline()
        p.onStage = { print("  \($0)") }
        do {
            let out = try p.process(dir: dir, meta: meta, provider: provider)
            print("ok  \(out.mdURL.path)")
            print(out.summary)
            if let e = out.polishErr { print("⚠ 整理：\(e)") }
            return 0
        } catch { print("✗ \(error.localizedDescription)"); return 1 }
    }
}
