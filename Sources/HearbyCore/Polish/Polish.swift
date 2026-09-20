// Polish — 潤稿→組稿→算摘要（首整理與重整理共用）；守門全在 PolishGuards
import Foundation

public enum Polish {
    /// 對照節（會前重點）的確定性重建
    public static func normalizeBriefLedger(notesMD: String, brief: [String], extraRows: String? = nil) -> String {
        var modelRows: [String] = extraRows.map { $0.components(separatedBy: "\n") } ?? []
        var body = notesMD
        if let start = notesMD.range(of: "## 會前重點對照") {
            let after = notesMD[start.upperBound...]
            if let end = after.range(of: "\n## ")?.lowerBound {
                modelRows += after[..<end].components(separatedBy: "\n")
                body = String(notesMD[..<start.lowerBound]) + String(after[end...])
            } else {
                modelRows += after.components(separatedBy: "\n")
                body = String(notesMD[..<start.lowerBound])
            }
        }
        func outcome(for item: String) -> String? {
            let prefix = String(item.prefix(8))
            for raw in modelRows {
                var t = raw.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("-") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
                guard t.hasPrefix(prefix) else { continue }
                for sep in [" → ", "→", "｜"] {
                    if let r = t.range(of: sep) { let o = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces); return o.isEmpty ? nil : o }
                }
            }
            return nil
        }
        let rows = brief.map { "- \($0) → \(outcome(for: $0) ?? "（模型未交代此條，重整理可再問）")" }
        return body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n## 會前重點對照\n" + rows.joined(separator: "\n")
    }

    public struct Input {
        public var transcript: String
        public var title: String
        public var attendees: String
        public var dateStr: String
        public var durStr: String
        public var warnings: [String]
        public var audioLine: String
        public var links: [String] = []
        public var corrections: String? = nil
        public var onsite: Bool = false
        public var scenario: MeetingScenario? = nil
        public var onsiteCount: Int? = nil
        public var brief: [String] = []
        public var baseline: String? = nil
        public var history: [String] = []
        /// 情境（決定 prompt 與組稿）
        public var scene: RecordScene = .meeting
        public var isNote: Bool { scene == .note }
        public init(transcript: String, title: String, attendees: String, dateStr: String, durStr: String, warnings: [String], audioLine: String) {
            self.transcript = transcript; self.title = title; self.attendees = attendees; self.dateStr = dateStr; self.durStr = durStr; self.warnings = warnings; self.audioLine = audioLine
        }
    }

    /// provider nil＝只出逐字稿版
    public static func buildNotes(_ i: Input, provider: Provider?) -> (md: String, summary: String, polishErr: String?) {
        var extras = ""
        if !i.links.isEmpty { extras += "\n參考連結（會後補充，不必臆測內容）：\n" + i.links.map { "- \($0)" }.joined(separator: "\n") }
        var correctionSection = ""
        if let c = i.corrections?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            correctionSection = "\n\n使用者對前一版的更正（最高優先，凌駕逐字稿裡的原始寫法）：\n\(c)\n套用規則：這些是使用者確認的正確寫法／內容，務必在這一版的每個段落——摘要、與會者、重點、決議、待辦——全部一致套用，同一個名稱在整份紀錄裡只能有一種寫法，不得只改部分段落。期限只能是逐字稿明說的；修正沒提到期限就留空。"
        }
        var baselineSection = ""
        if let b = i.baseline?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty {
            let historyBlock = i.history.isEmpty ? "" : "\n\n這份紀錄過去被要求修正過（全部仍然有效，不要退回修正前的說法）：\n" + i.history.map { "- \($0)" }.joined(separator: "\n")
            baselineSection = "\n\n前一版的整理結果（**這是基準**）：\n\(b)\(historyBlock)\n套用規則：以上是已經確認過的判斷。除了下方「更正」明確要求改的地方，其餘一律沿用原判斷——不要重新詮釋、不要因為換句話說而改變事實、不要把已經寫明「尚未定案」的事寫成已定案。逐字稿仍是事實來源，但當你的新解讀與基準衝突而更正沒提到這點時，以基準為準。"
        }
        let briefItems = i.brief.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var briefRules = ""
        var briefLedger = ""
        if !briefItems.isEmpty {
            let list = briefItems.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            briefRules = "\n\n會前重點（使用者開會前寫下這場要處理的事）：\n\(list)\n會前重點規則：\n- 整理「## 重點」時，與會前重點相關的討論優先保留具體細節與數字。\n- 會前重點不是事實來源——它只是使用者的待辦清單，嚴禁把其中字句當成會中講過的話；逐字稿沒出現的內容一律不寫。\n- 會前重點與與會者判斷無關——不要因為重點提到某人就把他列為與會者。"
            briefLedger = "\n\n另外在「## 待辦」之後加最後一節「## 會前重點對照」，恰好 \(briefItems.count) 行、每行對應會前重點清單的一條、順序照清單：行首「- 」接該條原文（逐字照抄清單，一個字不改），接「 → 」，接下落。下落三選一：會中有結論→一到兩句具體結論（含數字）；有討論但沒結論→「討論中」＋一句現況；逐字稿完全沒提到→只寫「本場未討論」。嚴禁編造，禁止出現清單以外的行。"
        }
        let llmTranscript = Transcriber.mergedForLLM(i.transcript)
        let metaBlock = """
            會議日期：\(i.dateStr)
            使用者提供的標題：\(i.title.isEmpty ? "（未提供）" : i.title)
            使用者提供的與會者名單（人名以此為權威寫法）：\(i.attendees.isEmpty ? "（未提供，請自行判斷）" : i.attendees)
            時長：\(i.durStr)
            \(i.warnings.isEmpty ? "" : "備註：" + i.warnings.joined(separator: "；"))\(extras)\(correctionSection)
            """
        let userMsg = metaBlock + baselineSection + "\n\n逐字稿：\n" + llmTranscript

        var notes: String?
        var polishErr: String?
        if let p = provider, p.id != "none" {
            let sys: String
            switch i.scene {
            case .note: sys = Prompt.note()
            case .interview: sys = Prompt.interview()
            case .meeting: sys = Prompt.system(scenario: i.scenario, onsiteCount: i.onsiteCount, onsite: i.onsite) + briefRules + briefLedger
            }
            let (raw, err) = p.complete(system: sys, user: userMsg)
            // 沒有任何 `## ` 節的輸出（只回一句開場白之類）不算數：當成失敗，既有紀錄不會被它蓋掉
            let out0 = raw.flatMap { PolishGuards.sanitizeModelOutput($0) }
            let shapeErr: String? = (raw?.isEmpty == false && out0 == nil) ? "AI 回的內容不是一份紀錄（沒有任何小節），這次沒有採用——可以按「重新整理全篇」再跑一次" : nil
            if var out = out0, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if i.scene == .meeting { out = PolishGuards.filterAttendees(notesMD: out, attendeeList: i.attendees) }
                out = PolishGuards.sanitizeTodoOwners(notesMD: out, attendeeList: i.attendees)
                out = PolishGuards.sanitizeTodoDues(notesMD: out, sourceText: llmTranscript + (i.corrections ?? ""))
                out = PolishGuards.stripExampleTodos(notesMD: out)
                out = PolishGuards.stripExampleNames(notesMD: out)
                out = PolishGuards.normalizeEmptyMarkers(notesMD: out)
                out = PolishGuards.tidyTodoRendering(notesMD: out)
                let (verified, ghosts) = PolishGuards.verifyCitations(notesMD: out, transcript: llmTranscript)
                if ghosts > 0 { HearbyLog.write("polish: \(ghosts) ghost citations removed") }
                notes = verified
            } else {
                polishErr = err ?? shapeErr ?? "模型回了空白內容（可按「重新整理全篇」再跑）"
            }
        }
        let sharedMic = i.scenario == .onsite || i.scenario == .phoneSpeaker || (i.scenario == nil && i.onsite)
        if sharedMic, let n = notes { notes = PolishGuards.insertOnsiteNote(notesMD: n, scenario: i.scenario, onsiteCount: i.onsiteCount) }
        if !briefItems.isEmpty, let n = notes { notes = normalizeBriefLedger(notesMD: n, brief: briefItems) }

        // 組稿（格式一字不改）
        var md = "# \(i.scene.mdTitle) \(i.dateStr)\n\n"
        var headline = "> Hearby 錄音｜時長 \(i.durStr)"
        let oneLineTitle = i.title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !oneLineTitle.isEmpty { headline += "｜\(oneLineTitle)" }
        md += headline + "\n"
        md += "> 音檔：\(i.audioLine)\n"
        if !i.attendees.isEmpty, i.scene != .note { md += "> 與會者（你填的）：\(i.attendees)\n" }
        if let sc = i.scenario, i.scene == .meeting {
            md += "> 本場情境：\(sc.displayName)（依聲音訊號自動判定）" + (i.onsiteCount.map { "｜現場人數 \($0 >= 5 ? "5+" : String($0))" } ?? "") + "\n"
        }
        if !briefItems.isEmpty { md += "> 會前重點：\(briefItems.count) 條（下落見文末「會前重點對照」）\n" }
        for w in i.warnings { md += "> ⚠ \(w)\n" }
        md += "\n"
        if let notes {
            md += notes.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        } else if let polishErr {
            md += "## \(summaryHeading(i.scene))\n（AI 整理失敗：\(polishErr)；逐字稿完整保留於下，可稍後用「重新整理全篇」重跑）\n"
        } else {
            md += "## \(summaryHeading(i.scene))\n（只有逐字稿：這場沒有接 AI 整理。逐字稿完整保留於下；到設定選「用我的訂閱」後，可用「重新整理全篇」補整理）\n"
        }
        if notes == nil, !briefItems.isEmpty {
            md += "\n## 會前重點對照\n" + briefItems.map { "- \($0) → （AI 整理未執行，重整理時會對照）" }.joined(separator: "\n") + "\n"
        }
        if !i.links.isEmpty { md += "\n## 參考連結\n" + i.links.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        md += "\n---\n\n## 逐字稿\n" + i.transcript + "\n"

        var summary = "已存檔。"
        if let notes, let range = notes.range(of: "## " + summaryHeading(i.scene)) {
            let after = notes[range.upperBound...]
            let cut = after.range(of: "\n## ").map { after[..<$0.lowerBound] } ?? after
            summary = cut.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let polishErr {
            summary = "逐字稿已存檔，但 AI 整理失敗（\(polishErr)）。"
        } else if notes == nil {
            summary = "逐字稿已存檔（未整理）。"
        }
        return (md, summary, polishErr)
    }

    static func summaryHeading(_ s: RecordScene) -> String {
        switch s { case .meeting: return "AI 會議摘要"; case .interview: return "摘要"; case .note: return "一句話" }
    }

    /// 三行重點（完成頁用）：摘要前三句，或重點前三條
    public static func threeLines(md: String) -> [String] {
        let rec = RecordMD.parse(md: md)
        if md.hasPrefix("# 訪談") {
            let q = (rec.section("引言") ?? []).filter { $0 != "無" }
            if !q.isEmpty { return Array(q.prefix(3)).map { $0.replacingOccurrences(of: #"\s*\[(?:\d{1,2}:)?\d{1,3}:[0-5]\d\]"#, with: "", options: .regularExpression) } }
            let s = rec.summaryText
            return s.isEmpty ? [] : s.components(separatedBy: "。").filter { !$0.isEmpty }.prefix(3).map { $0 + "。" }
        }
        if md.hasPrefix("# 筆記") {
            let heads = (rec.section("內容") ?? []).filter { $0.hasPrefix("**") }.map { $0.replacingOccurrences(of: "**", with: "") }
            if !heads.isEmpty { return Array(heads.prefix(3)) }
            let one = (rec.section("一句話") ?? []).joined(separator: " ")
            return one.isEmpty ? [] : [one]
        }
        let hi = (rec.section("重點") ?? []).filter { !$0.hasPrefix("**") }
        if hi.count >= 2 { return Array(hi.prefix(3)).map { $0.replacingOccurrences(of: #"\s*\[(?:\d{1,2}:)?\d{1,3}:[0-5]\d\]"#, with: "", options: .regularExpression) } }
        let s = rec.summaryText
        if !s.isEmpty { return s.components(separatedBy: "。").filter { !$0.isEmpty }.prefix(3).map { $0 + "。" } }
        return []
    }
}
