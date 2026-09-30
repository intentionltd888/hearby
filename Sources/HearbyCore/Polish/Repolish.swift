// Repolish — 重新整理全篇／請 AI 改一段（不重錄、不重跑 whisper，只重跑模型）
import Foundation

public enum Repolish {
    /// 從既有 md 反解 → 帶修正重跑 → 原地覆寫（覆寫前留 _舊版N.md）；回傳 (md 路徑, 摘要)
    public static func whole(mdURL: URL, corrections: String, provider: Provider, onStage: ((String) -> Void)? = nil) throws -> (URL, String) {
        // 這三件事都要 AI。沒接（none）就明講、不動檔案——以前只有圖形介面擋，命令列會把整理好的內容洗成「只有逐字稿」還印 ok
        guard provider.id != "none" else { throw HearbyError("這個動作要用 AI 整理，但現在的整理方式是「只要逐字稿」。先到設定選「用我的訂閱」，或在命令列加 --provider claude（或 codex）。") }
        MeetingBusy.begin(mdURL.deletingLastPathComponent())
        defer { MeetingBusy.end(mdURL.deletingLastPathComponent()) }
        onStage?("讀取原紀錄…")
        guard let oldMD = try? String(contentsOf: mdURL, encoding: .utf8) else { throw HearbyError("讀不到原紀錄：\(mdURL.lastPathComponent)") }
        guard let transcript = RecordMD.transcript(of: oldMD) else { throw HearbyError("原紀錄裡找不到逐字稿段，無法重新整理") }
        let rec = RecordMD.parse(md: oldMD)
        let parts = rec.parts
        let dateStr = parts.date.isEmpty ? rec.title : parts.date
        let audioLine = oldMD.components(separatedBy: "\n").first(where: { $0.hasPrefix("> 音檔：") }).map { String($0.dropFirst("> 音檔：".count)) } ?? "（沿用原音檔）"
        let links = rec.section("參考連結") ?? []
        let warnings = oldMD.components(separatedBy: "\n").filter { $0.hasPrefix("> ⚠ ") }.map { String($0.dropFirst("> ⚠ ".count)) }
        var attendees = realAttendees(rec.people).joined(separator: "、")
        if attendees.isEmpty { attendees = rec.declaredAttendees }

        var baseline = ""
        let baselineNames: [String]
        switch RecordScene.from(mdTitle: oldMD) {
        case .note: baselineNames = ["內容", "待辦"]
        case .interview: baselineNames = ["內容", "引言", "待辦"]
        case .meeting: baselineNames = ["重點", "決議", "開放問題", "待辦"]
        }
        for name in baselineNames {
            guard let lines = rec.section(name), !lines.isEmpty else { continue }
            baseline += "## \(name)\n" + lines.joined(separator: "\n") + "\n\n"
        }
        var history = (rec.section("修正紀錄") ?? []).map { l -> String in
            var t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("-") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return t
        }.filter { !$0.isEmpty }
        history += oldMD.components(separatedBy: "\n").filter { $0.hasPrefix("> 已依") }.map { String($0.dropFirst(2)) }

        onStage?("AI 重新整理中…")
        let (fixedTranscript, semantic) = PolishGuards.applyMechanicalCorrections(transcript: transcript, corrections: corrections)
        let (fixedAttendees, _) = PolishGuards.applyMechanicalCorrections(transcript: attendees, corrections: corrections)
        var scenario: MeetingScenario? = nil
        var onsiteCount: Int? = nil
        if let scLine = oldMD.components(separatedBy: "\n").first(where: { $0.hasPrefix("> 本場情境：") }) {
            scenario = MeetingScenario.allCases.first { scLine.contains($0.displayName) }
            if let r = scLine.range(of: #"現場人數 (\d+)"#, options: .regularExpression) { onsiteCount = Int(String(scLine[r]).filter(\.isNumber)) }
        }
        let brief: [String] = (rec.section("會前重點對照") ?? []).compactMap { line in
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("-") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard !t.isEmpty, !t.allSatisfy({ "-—─".contains($0) }) else { return nil }
            var found = false
            for sep in [" → ", "→", "｜"] where !found { if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]); found = true } }
            guard found else { return nil }
            t = t.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        let onsite = scenario == nil && !fixedTranscript.contains("[遠端]")
        let displayTranscript = Clean.normalizePunct(onsite ? fixedTranscript.replacingOccurrences(of: "[我方]", with: "[現場]") : fixedTranscript)
        var input = Polish.Input(transcript: Transcriber.mergedForLLM(displayTranscript), title: parts.custom, attendees: fixedAttendees, dateStr: dateStr, durStr: parts.dur, warnings: warnings, audioLine: audioLine)
        input.links = links
        input.corrections = semantic.isEmpty ? nil : semantic
        input.onsite = onsite
        input.scenario = scenario
        input.onsiteCount = onsiteCount
        input.brief = brief
        input.pauseNote = oldMD.components(separatedBy: "\n").first(where: { $0.hasPrefix("> ⏸ ") }).map { String($0.dropFirst("> ⏸ ".count)) }
        input.baseline = baseline.trimmingCharacters(in: .whitespacesAndNewlines)
        input.history = history
        input.scene = RecordScene.from(mdTitle: oldMD)
        input.context = PolishContext.load(excluding: mdURL.deletingPathExtension().lastPathComponent)
        // 認聲音（實驗；macOS 15 以上、設定打開才跑）：分軌還在就分開切，不然用這場的 m4a；出錯只記 log，不擋整理
        let voiceSources = Voices.sources(meetingDir: mdURL.deletingLastPathComponent(), m4a: audioURL(mdURL: mdURL, audioLine: audioLine))
        if let v = Voices.recognize(sources: voiceSources, transcript: input.transcript, onStage: onStage) {
            input.voiceTags = v.tags; input.voiceLine = v.line
        }
        var (md, summary, err) = Polish.buildNotes(input, provider: provider)
        if let e = err { throw HearbyError(e) }
        md = restoreTodoChecks(md: md, oldTodos: rec.todos)
        let corrLine = corrections.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "；")
        if !corrLine.isEmpty {
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.calendar = Calendar(identifier: .gregorian); df.dateFormat = "yyyy-MM-dd"
            let block = "## 修正紀錄\n" + (history + ["\(df.string(from: Date()))：\(corrLine)"]).map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            if let tr = md.range(of: "## 逐字稿") { md.replaceSubrange(tr.lowerBound..<tr.lowerBound, with: block) } else { md += "\n\n" + block }
        }
        md = Clean.toTraditional(md, keep: input.context?.names ?? [])   // 名冊上的名字不簡轉繁（「涂」不是「塗」）
        summary = Clean.toTraditional(summary, keep: input.context?.names ?? [])
        onStage?("存檔中…")
        RecordMD.backupIfExists(mdURL)
        try md.write(to: mdURL, atomically: true, encoding: .utf8)
        try? Mirror.copy(mdURL)
        NameLedger.learn(corrections: corrections, mdURL: mdURL)   // 你寫的「A」應為「B」是名字的，記進名字確認帳
        // 記憶跟著新版走：Hearby 寫的、沒人動過的行換成新版，使用者改過的不動
        _ = try? MemoryStore.sync(mdURL: mdURL)
        return (mdURL, summary)
    }

    /// 這場的錄音：表頭「> 音檔：」寫的那個 m4a 還在就用它，不然找紀錄旁邊同名的 .m4a
    public static func audioURL(mdURL: URL, audioLine: String) -> URL? {
        let fm = FileManager.default
        if audioLine.hasSuffix(".m4a"), fm.fileExists(atPath: audioLine) { return URL(fileURLWithPath: audioLine) }
        let side = mdURL.deletingPathExtension().appendingPathExtension("m4a")
        return fm.fileExists(atPath: side.path) ? side : nil
    }

    /// 舊紀錄「## 與會者」裡真的算名字的：去掉「（推測）」這類註記，
    /// 並剔除 AI 認不出人時填的佔位標籤（現場A／遠端B／電話端／我方／受訪者／訪談者…）。
    /// 佔位標籤不是名單：第一版與會者若是「現場A／B／C（推測）」，重新整理時把它們當成「使用者提供的名單」
    /// 回灌給模型，名單規則會把假名鎖死、永遠改不回真名；要留給模型重新判斷或讓人自己填。
    public static func realAttendees(_ people: [String]) -> [String] {
        let placeholders = ["現場", "遠端", "電話端", "我方", "受訪者", "訪談者", "發言者", "Speaker", "Remote", "Interviewee", "Interviewer"]
        return people.map { n -> String in
            var t = n
            for m in ["我方", "遠端", "現場", "電話端", "推測"] { t = t.replacingOccurrences(of: "（\(m)）", with: "").replacingOccurrences(of: "(\(m))", with: "") }
            return t.trimmingCharacters(in: .whitespaces)
        }.filter { t in
            guard !t.isEmpty else { return false }
            for p in placeholders where t.hasPrefix(p) {
                let rest = t.dropFirst(p.count).trimmingCharacters(in: .whitespaces)
                // 「現場A」「遠端 2」「Speaker B」＝佔位；「現場經理王小明」這種後面還有真字的不算
                if rest.isEmpty || (rest.count <= 2 && rest.allSatisfy { $0.isLetter || $0.isNumber }) { return false }
            }
            return true
        }
    }

    /// 翻譯成指定語言：另存 <base>.<lang>.md（逐字稿不翻，指回原檔）；回傳新檔
    public static func translate(mdURL: URL, language: String, provider: Provider) throws -> URL {
        // 這三件事都要 AI。沒接（none）就明講、不動檔案——以前只有圖形介面擋，命令列會把整理好的內容洗成「只有逐字稿」還印 ok
        guard provider.id != "none" else { throw HearbyError("這個動作要用 AI 整理，但現在的整理方式是「只要逐字稿」。先到設定選「用我的訂閱」，或在命令列加 --provider claude（或 codex）。") }
        MeetingBusy.begin(mdURL.deletingLastPathComponent())
        defer { MeetingBusy.end(mdURL.deletingLastPathComponent()) }
        guard let md = try? String(contentsOf: mdURL, encoding: .utf8) else { throw HearbyError("讀不到原紀錄") }
        let parts = md.components(separatedBy: "\n---\n\n## 逐字稿")
        let record = parts[0]
        let (out, err) = provider.complete(system: Prompt.translate(to: language), user: record)
        guard var t = out?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { throw HearbyError(err ?? "模型沒有回應") }
        // 守門：節名（##）與分隔線要跟原檔一樣（解析靠中文節名；顯示與匯出時再依語言換字）。
        // 一級標題：文件種類那個詞（會議紀錄／訪談／筆記）還原成中文給解析用，後面的日期與自訂標題用翻譯後的。
        // 表頭只還原「> Hearby 錄音｜時長」與「> 音檔」兩行（時長要解析），其他 > 提醒行照翻。
        let srcLines = record.components(separatedBy: "\n")
        var outLines = t.components(separatedBy: "\n")
        let firstHeading = srcLines.firstIndex { $0.hasPrefix("## ") } ?? srcLines.count
        func restoredTitle(_ src: String, _ out: String) -> String {
            let scene = RecordScene.from(mdTitle: src)
            let rest = out.hasPrefix("# ") ? String(out.dropFirst(2)) : out
            // 模型可能把「Notes 2026-09-13 22:17 xxx」整行翻了：去掉它翻出來的種類詞，保留日期與自訂標題
            var tail = rest
            // 舊檔的標題是「會議記錄」（言部）：一樣要剝得掉，不然會變成「# 會議紀錄 會議記錄 2026-…」
            for w in [DocLabels.t(scene.mdTitle, language), scene.mdTitle] + RecordScene.legacyMdTitles where tail.hasPrefix(w) { tail = String(tail.dropFirst(w.count)).trimmingCharacters(in: .whitespaces) }
            return "# \(scene.mdTitle)" + (tail.isEmpty ? "" : " " + tail)
        }
        if outLines.count == srcLines.count {
            for (i, l) in srcLines.enumerated() {
                if l.hasPrefix("# ") { outLines[i] = restoredTitle(l, outLines[i]) }
                else if l.hasPrefix("## ") || l == "---" { outLines[i] = l }
                else if i < firstHeading, l.hasPrefix("> 音檔") { outLines[i] = l }
                else if i < firstHeading, l.hasPrefix("> "), l.contains("時長") {
                    // 「Hearby 錄音｜時長 1分10秒｜自訂標題」：前兩段還原（解析時長），第三段起用翻譯後的（那是這場的標題）
                    let src = l.components(separatedBy: "｜"), out = outLines[i].components(separatedBy: "｜")
                    outLines[i] = (src.count > 2 && out.count > 2) ? (src.prefix(2) + out.dropFirst(2)).joined(separator: "｜") : l
                }
            }
            t = outLines.joined(separator: "\n")
        } else {
            // 行數對不上：至少把節名修回來
            let heads = srcLines.filter { $0.hasPrefix("## ") }
            var k = 0
            outLines = outLines.map { l in
                if l.hasPrefix("## "), k < heads.count { defer { k += 1 }; return heads[k] }
                return l
            }
            if let i = outLines.firstIndex(where: { $0.hasPrefix("# ") }), let s = srcLines.first(where: { $0.hasPrefix("# ") }) { outLines[i] = restoredTitle(s, outLines[i]) }
            else if let s = srcLines.first(where: { $0.hasPrefix("# ") }) { outLines.insert(s, at: 0) }
            t = outLines.joined(separator: "\n")
        }
        let base = mdURL.deletingPathExtension().lastPathComponent
        let dest = mdURL.deletingLastPathComponent().appendingPathComponent("\(base).\(language).md")
        let body = t + "\n\n---\n\n## 逐字稿\n（原文逐字稿見 \(mdURL.lastPathComponent)）\n"
        RecordMD.backupIfExists(dest)
        try body.write(to: dest, atomically: true, encoding: .utf8)
        try? Mirror.copy(dest)
        HearbyLog.write("translate \(base) → \(language)")
        return dest
    }

    /// 只改一節：回傳修改後的該節文字（呼叫端並排顯示、按確認才寫）
    public static func section(mdURL: URL, sectionName: String, instruction: String, provider: Provider) throws -> String {
        // 這三件事都要 AI。沒接（none）就明講、不動檔案——以前只有圖形介面擋，命令列會把整理好的內容洗成「只有逐字稿」還印 ok
        guard provider.id != "none" else { throw HearbyError("這個動作要用 AI 整理，但現在的整理方式是「只要逐字稿」。先到設定選「用我的訂閱」，或在命令列加 --provider claude（或 codex）。") }
        guard let md = try? String(contentsOf: mdURL, encoding: .utf8) else { throw HearbyError("讀不到原紀錄") }
        let rec = RecordMD.parse(md: md)
        let original: String
        if sectionName.contains("待辦") { original = rec.todos.map { "- [\($0.done ? "x" : " ")] \($0.item)｜\($0.owner)｜\($0.due)" }.joined(separator: "\n") }
        else { original = (rec.section(sectionName) ?? []).map { "- \($0)" }.joined(separator: "\n") }
        let transcript = RecordMD.transcript(of: md) ?? ""
        let user = "## \(sectionName)（原文）\n\(original)\n\n逐字稿：\n\(Transcriber.mergedForLLM(transcript))"
        let (out, err) = provider.complete(system: Prompt.sectionEdit(sectionName: sectionName, instruction: instruction), user: user)
        guard let o = out else { throw HearbyError(err ?? "模型沒有回應") }
        return Clean.toTraditional(o.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 把一節換成新內容並存檔（覆寫前備份）
    public static func replaceSection(mdURL: URL, sectionName: String, with newBody: String) throws {
        guard let md = try? String(contentsOf: mdURL, encoding: .utf8) else { throw HearbyError("讀不到原紀錄") }
        var lines = md.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## ") && $0.contains(sectionName) }) else { throw HearbyError("找不到「\(sectionName)」這一節") }
        var end = lines.count
        for i in (start + 1)..<lines.count where lines[i].hasPrefix("## ") || lines[i] == "---" { end = i; break }
        lines.replaceSubrange((start + 1)..<end, with: newBody.components(separatedBy: "\n") + [""])
        RecordMD.backupIfExists(mdURL)
        try lines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)
        try? Mirror.copy(mdURL)
        _ = try? MemoryStore.sync(mdURL: mdURL)
    }

    static func restoreTodoChecks(md: String, oldTodos: [(item: String, owner: String, due: String, done: Bool)]) -> String {
        let doneItems = Set(oldTodos.filter { $0.done }.map { $0.item.trimmingCharacters(in: .whitespaces) })
        guard !doneItems.isEmpty else { return md }
        return md.components(separatedBy: "\n").map { line -> String in
            guard line.hasPrefix("- [ ] ") else { return line }
            let body = String(line.dropFirst(6))
            let item = (body.components(separatedBy: "｜").first ?? body).trimmingCharacters(in: .whitespaces)
            return doneItems.contains(item) ? "- [x] " + body : line
        }.joined(separator: "\n")
    }
}

/// 第二落點（設定 mirrorDir）：每次寫 md 都多寫一份
public enum Mirror {
    public static func copy(_ md: URL) throws {
        guard let m = Paths.mirror else { return }
        try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
        let dst = m.appendingPathComponent(md.lastPathComponent)
        let data = try Data(contentsOf: md)
        try data.write(to: dst, options: .atomic)
    }

    /// 一場改了名字：副本資料夾裡這一場的檔（<舊 id>.md、翻譯 <舊 id>.en.md…）跟著改名。
    /// 新名字已經有檔＝不覆寫、舊的留著（skipped 列出來）。沒設副本資料夾＝什麼都不做
    public static func rename(from old: String, to new: String) -> (moved: [URL], skipped: [String]) {
        let fm = FileManager.default
        guard let m = Paths.mirror, old != new, let names = try? fm.contentsOfDirectory(atPath: m.path) else { return ([], []) }
        var moved: [URL] = [], skipped: [String] = []
        for n in names.sorted() where n.hasPrefix(old + ".") {
            let src = m.appendingPathComponent(n)
            let dst = m.appendingPathComponent(new + n.dropFirst(old.count))
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            if fm.fileExists(atPath: dst.path), dst.lastPathComponent.lowercased() != n.lowercased() { skipped.append(n); continue }
            do { try MeetingRename.move(src, to: dst); moved.append(dst) } catch { skipped.append(n) }
        }
        return (moved, skipped)
    }
}
