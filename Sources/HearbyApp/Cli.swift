// Cli — 旗標分派（先於任何 AppKit 初始化）
//   --doctor [--deep]     七項狀態
//   --version / --selftest
//   --import <檔>         聽打並整理一個音檔／影片（終端機用；沙箱設 HEARBY_OUTPUT_ROOT）
//   --process <工作夾>    對既有錄音工作夾（mic.wav／system.wav）跑整理
//   --repolish <md> "<修正>"  重新整理全篇
//   --translate <md> [--lang en|ja|zh-CN]  翻譯另存
//   --provider none|claude|codex  覆寫這次用的整理方式
//   --export-word <md> [--company X --recorder Y --units Z]  出 Word（.docx；Pages 直接開）
//   --export-html <md> [--company X --recorder Y --units Z]  出版型 HTML（檢視用）
//   --record <秒> [--source room|online] [--no-process]  開發用真錄音
//   --snapshot <資料夾> [--dark]  離線把每個畫面畫成 PNG（設計檢視用，不需要螢幕錄製權限）
import Foundation
import HearbyCore
import HearbyUI

enum Cli {
    /// 這個 app 認得的全部 `--旗標`（含圖形介面自己會讀的 --install／--eject）
    static let known: Set<String> = [
        "--help", "--version", "--selftest", "--check-resources", "--doctor", "--deep", "--import", "--process", "--repolish",
        "--translate", "--lang", "--provider", "--title", "--scene", "--export-word", "--export-html", "--company", "--recorder",
        "--units", "--record", "--source", "--no-process", "--snapshot", "--dark", "--memory-rebuild", "--install", "--eject",
    ]
    /// 後面要接一個值的旗標
    static let takesValue: Set<String> = [
        "--import", "--process", "--repolish", "--translate", "--lang", "--provider", "--title", "--scene", "--export-word",
        "--export-html", "--company", "--recorder", "--units", "--record", "--source", "--snapshot", "--eject",
    ]
    static let usage = """
    Hearby \(HearbyVersion.version) (build \(HearbyVersion.build))
    不帶旗標＝打開 app。命令列：
      --doctor [--deep]            七項狀態體檢
      --import <檔> [--title 標題] [--provider none|claude|codex]   聽打並整理一個音檔／影片
      --process <工作夾>           對既有錄音工作夾跑整理
      --repolish <md> "<修正>"     重新整理全篇
      --translate <md> [--lang en|ja|zh-CN]
      --export-word <md> / --export-html <md> [--company X --recorder Y --units Z]
      --version / --help
    """
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
            return true
        }
        if let bad = flags.first(where: { $0.hasPrefix("--") && !known.contains($0) }) {
            FileHandle.standardError.write(Data("不認得的旗標：\(bad)\n\n\(usage)\n".utf8))
            return 2
        }
        if set.contains("--version") { print("Hearby \(HearbyVersion.version) (build \(HearbyVersion.build))"); return 0 }
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
            while Date().timeIntervalSince(t0) < secs { RunLoop.current.run(until: Date().addingTimeInterval(0.5)); print(String(format: "  mic %.3f  sys %.3f", rec.micLevel, rec.sysLevel)) }
            let got = rec.stop()
            var m = MeetingMeta()
            m.started = t0; m.seconds = got; m.micMax = rec.micMax; m.sysMax = rec.sysMax; m.source = src.rawValue; m.warnings = warns
            m.title = value(after: "--title") ?? "錄音測試"
            Pipeline.saveMeta(m, to: dir)
            print("錄了 \(Fmt.dur(got))：mic max \(rec.micMax) sys max \(rec.sysMax) sysBuffers \(rec.sysBufferCount) → \(dir.path)")
            if set.contains("--no-process") { return 0 }
            return runPipeline(dir: dir, meta: m, provider: provider())
        }
        if let dir = value(after: "--snapshot") { return Snapshot.run(into: URL(fileURLWithPath: dir), dark: set.contains("--dark")) }
        for f in ["--memory-rebuild"] where set.contains(f) { print("\(f)：批 C 接"); return 2 }
        return nil
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
