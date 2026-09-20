// PolishGuards — 整理輸出的確定性守門：舉證驗真、名單過濾、負責人／期限守門、範例剝除
import Foundation

public enum PolishGuards {

    /// 舉證守門（配合 prompt 的「每行標來源 [mm:ss]」）。
    /// 把任務從「寫摘要」換成「舉證」是為了讓模型寫不出評語——它得指出來源，而評語沒有來源。
    /// 但標得出來不代表標得對：**幻覺出來的引用比沒有引用更糟**，因為它讓假話看起來可查證。
    /// 這裡逐一比對逐字稿真實出現過的時間戳，對不上的把標記拿掉、內容留著交人判斷。
    /// 不丟整行的理由：4B 偶爾內容對、時間標錯，丟行會連真話一起丟（寧可少一個索引，不要少一條事實）。
    /// 回傳 (清理後的 md, 被拿掉的標記數)。逐字稿本身沒有時間戳（舊檔）時直接放行不驗。
    /// 模型輸出進紀錄之前的第一道清理。回 nil＝這份輸出不能用（沒有任何一個 `## ` 節）。
    ///   ・終端機色碼（ANSI）與 ```markdown 圍欄拿掉；
    ///   ・第一個 `## ` 之前的東西（升級提示、「好的，以下是…」開場白）拿掉；
    ///   ・輸出裡出現 `## 逐字稿` 就從那裡截斷：逐字稿由 Hearby 自己接在後面，模型（或逐字稿裡的注入句）不可以偽造一段，
    ///     否則下次「重新整理全篇」會把偽造的句子當成真的逐字稿、永久併進去。
    public static func sanitizeModelOutput(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        s = s.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.joined(separator: "\n")
        if let cut = s.range(of: "## 逐字稿") {
            s = String(s[..<cut.lowerBound])
            while s.hasSuffix("\n") || s.hasSuffix("-") || s.hasSuffix(" ") { s.removeLast() }   // 連同它前面的 --- 分隔線
        }
        guard let first = s.range(of: "(?m)^## ", options: .regularExpression) else { return nil }
        s = String(s[first.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    public static func verifyCitations(notesMD: String, transcript: String) -> (String, Int) {
        let pattern = #"\[((?:\d{1,2}:)?\d{1,3}:[0-5]\d)\]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return (notesMD, 0) }
        func stamps(in s: String) -> [String] {
            let ns = s as NSString
            return re.matches(in: s, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) }
        }
        let real = Set(transcript.components(separatedBy: "\n").flatMap { stamps(in: $0) })
        guard !real.isEmpty else { return (notesMD, 0) }
        var bad = 0
        let cleaned = notesMD.components(separatedBy: "\n").map { line -> String in
            let ghosts = stamps(in: line).filter { !real.contains($0) }
            guard !ghosts.isEmpty else { return line }
            bad += ghosts.count
            var out = line
            for g in ghosts { out = out.replacingOccurrences(of: g, with: "") }
            return out.replacingOccurrences(
                of: #"[ \t]+$"#, with: "", options: .regularExpression)
        }.joined(separator: "\n")
        return (cleaned, bad)
    }

    /// 「X」應為「Y」型修正的確定性預替換：模型看不到錯字，比 in-context 指令可靠（4B 套用不全）。
    /// 支援「A」應為「B」／「A」是「B」的錯譯／「A」改成「B」；回傳 (替換後逐字稿, 剩餘語義修正行)。
    public static func applyMechanicalCorrections(transcript: String, corrections: String)
        -> (String, String)
    {
        var t = transcript
        var semantic: [String] = []
        let pattern = #"「([^「」]{1,40})」\s*(?:應為|应为|是|改成|改為)\s*「([^「」]{1,40})」"#
        let re = try? NSRegularExpression(pattern: pattern)
        for line in corrections.components(separatedBy: CharacterSet(charactersIn: "\n;；")) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { continue }
            let ns = l as NSString
            let matches = re?.matches(in: l, range: NSRange(location: 0, length: ns.length)) ?? []
            var residual = l
            for m in matches where m.numberOfRanges == 3 {
                let wrong = ns.substring(with: m.range(at: 1))
                let right = ns.substring(with: m.range(at: 2))
                // 剎車：單一字元的錯字（「他」應為「她」這類）機械替換會掃射全文——交給 in-context
                guard wrong.count >= 2, wrong != right, t.contains(wrong) else { continue }
                t = t.replacingOccurrences(of: wrong, with: right)
                residual = residual.replacingOccurrences(
                    of: ns.substring(with: m.range(at: 0)), with: "")
            }
            // 該行去掉已吃掉的「X」應為「Y」片段後，若還有實質內容（語義修正混在同一行）→ 整行照留
            // 進 in-context，避免「同行其餘修正被吞掉」（實測 4B 需要）
            let leftover = residual.trimmingCharacters(
                in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",，。、；;")))
            if !leftover.isEmpty { semantic.append(l) }
        }
        return (t, semantic.joined(separator: "；"))
    }

    /// 與會者段落過濾（有名單時的硬保證）：只留名單內的人、去重；名單外行刪掉。
    /// 名單項「王小明（Ming）」＝本名或暱稱命中都算同一人。
    public static func filterAttendees(notesMD: String, attendeeList: String) -> String {
        let names = attendeeList.components(separatedBy: CharacterSet(charactersIn: "、,，"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return notesMD }
        // 每個名單項展開成別名集合：整項＋括號外本名＋括號內暱稱。
        // 括號內容只有「全名單唯一」才收作別名——單位是多人共享的（甲（某公司）、
        // 乙（某公司）），拿去當人名比對會把同單位第二人整行誤判成重複
        var bases: [String] = []
        var inners: [String?] = []
        var innerCount: [String: Int] = [:]
        for n in names {
            var base = n
            var inner: String? = nil
            if let l = n.firstIndex(where: { $0 == "（" || $0 == "(" }) {
                base = String(n[..<l]).trimmingCharacters(in: .whitespaces)
                let iv = String(n[n.index(after: l)...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "）) "))
                if !iv.isEmpty {
                    inner = iv
                    innerCount[iv, default: 0] += 1
                }
            }
            bases.append(base)
            inners.append(inner)
        }
        var aliasSets: [[String]] = []
        for (i, n) in names.enumerated() {
            var aliases = [n]
            if !bases[i].isEmpty, bases[i] != n { aliases.append(bases[i]) }
            if let iv = inners[i], innerCount[iv] == 1 { aliases.append(iv) }
            aliasSets.append(aliases)
        }
        var out: [String] = []
        var seen = Set<Int>()
        var inSection = false
        for line in notesMD.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                inSection = line.contains("與會者")
                out.append(line)
                continue
            }
            guard inSection, line.trimmingCharacters(in: .whitespaces).hasPrefix("-") else {
                out.append(line)
                continue
            }
            // 與會者條目行：找第一個命中的名單項；沒命中或重複 → 丟
            var hit: Int? = nil
            for (i, aliases) in aliasSets.enumerated()
            where aliases.contains(where: { line.contains($0) }) {
                hit = i
                break
            }
            if let i = hit, !seen.contains(i) {
                seen.insert(i)
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    /// 待辦負責人守門：負責人欄不是名單／與會者內的人 → 清空（含近似錯字 snap：距離 1 修回）。
    public static func sanitizeTodoOwners(notesMD: String, attendeeList: String) -> String {
        let names = attendeeList.components(separatedBy: CharacterSet(charactersIn: "、,，"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return notesMD }
        // 括號內容只收「全名單唯一」的當別名（同 filterAttendees 8/10 修訂）：
        // 共享單位字串當別名會讓裸單位名通過負責人守門
        var innerCount: [String: Int] = [:]
        var parsed: [(full: String, base: String, inner: String?)] = []
        for n in names {
            var base = n
            var inner: String? = nil
            if let l = n.firstIndex(where: { $0 == "（" || $0 == "(" }) {
                base = String(n[..<l]).trimmingCharacters(in: .whitespaces)
                let iv = String(n[n.index(after: l)...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "）) "))
                if !iv.isEmpty {
                    inner = iv
                    innerCount[iv, default: 0] += 1
                }
            }
            parsed.append((n, base, inner))
        }
        var aliases: [String] = []
        for p in parsed {
            aliases.append(p.full)
            if !p.base.isEmpty, p.base != p.full { aliases.append(p.base) }
            if let iv = p.inner, innerCount[iv] == 1 { aliases.append(iv) }
        }
        func editDistance1(_ a: String, _ b: String) -> Bool {
            let x = Array(a), y = Array(b)
            if abs(x.count - y.count) > 1 { return false }
            var diff = 0
            if x.count == y.count {
                for i in 0..<x.count where x[i] != y[i] { diff += 1 }
                return diff == 1
            }
            let (s, l) = x.count < y.count ? (x, y) : (y, x)
            var i = 0, j = 0
            while i < s.count && j < l.count {
                if s[i] == l[j] { i += 1 } else { diff += 1; if diff > 1 { return false } }
                j += 1
            }
            return true
        }
        func fixOwner(_ owner: String) -> String {
            let o = owner.trimmingCharacters(in: .whitespaces)
            if o.isEmpty { return "" }
            // 多人（頓號分隔）逐一檢查
            let parts = o.components(separatedBy: CharacterSet(charactersIn: "、,，"))
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var fixed: [String] = []
            for p in parts {
                if aliases.contains(where: { p.contains($0) || $0.contains(p) }) {
                    fixed.append(p)
                } else if let snap = aliases.first(where: { editDistance1(p, $0) }) {
                    fixed.append(snap)  // 差一個字的錯字修回名單寫法
                }
                // 都不是 → 丟（余童修這類 ASR 噪音名）
            }
            return fixed.joined(separator: "、")
        }
        var out: [String] = []
        var inTodo = false
        for line in notesMD.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { inTodo = line.contains("待辦") }
            guard inTodo, line.contains("- [ ]"), line.contains("｜") else {
                out.append(line)
                continue
            }
            var cols = line.components(separatedBy: "｜")
            if cols.count >= 2 {
                cols[1] = fixOwner(cols[1])
                while cols.count < 3 { cols.append("") }  // 補滿三欄（模型偶爾漏尾欄）
                out.append(cols[0...2].joined(separator: "｜"))
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    /// 範例守門：prompt 裡的格式範例「範例事項」被 4B 抄成真待辦（小逐字稿實測）→ 整行拿掉；
    /// 拿掉後待辦段空了就補「- 無」。
    public static func stripExampleTodos(notesMD: String) -> String {
        var out: [String] = []
        var inTodo = false
        var todoHeaderIdx: Int? = nil
        var todoCount = 0
        for line in notesMD.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                inTodo = line.contains("待辦")
                if inTodo { todoHeaderIdx = out.count }
            }
            if inTodo, line.contains("- [ ]") {  // 單欄待辦（無｜）也要計數，否則會誤補「- 無」
                let item = line.components(separatedBy: "｜")[0]
                    .replacingOccurrences(of: "- [ ]", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if item == "範例事項" { continue }
                todoCount += 1
            }
            out.append(line)
        }
        if let h = todoHeaderIdx, todoCount == 0,
            !out[h...].contains(where: { $0.trimmingCharacters(in: .whitespaces) == "- 無" })
        {
            out.insert("- 無", at: h + 1)
        }
        return out.joined(separator: "\n")
    }

    /// 空值標記正規化：prompt 範例引用造成的「- - 無明確決議」雙破折號 → 單一
    public static func normalizeEmptyMarkers(notesMD: String) -> String {
        notesMD.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- - 無") { return String(t.dropFirst(2)) }
            return line
        }.joined(separator: "\n")
    }

    /// 待辦人讀化：負責人與期限都空的「事項｜｜」尾巴拿掉——
    /// 匯出解析 todoParts 本就相容無欄位行，人看的 md 不必裸露空欄雙直線。
    public static func tidyTodoRendering(notesMD: String) -> String {
        var out: [String] = []
        var inTodo = false
        for line in notesMD.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { inTodo = line.contains("待辦") }
            if inTodo, line.contains("- [ ]"), line.contains("｜") {
                let cols = line.components(separatedBy: "｜").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if cols.count >= 2, cols[1...].allSatisfy({ $0.isEmpty }) {
                    out.append(cols[0])
                    continue
                }
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// 範例人名守門：prompt 名單規則的示範假名會被小模型抄進輸出（摘要尾巴出現示範名）
    /// → 全文剝除＋收乾淨殘留頓號
    public static func stripExampleNames(notesMD: String) -> String {
        var s = notesMD
        for token in ["示例甲（Alpha）", "示例甲(Alpha)", "示例乙（單位甲）", "示例乙(單位甲)", "示例甲", "示例乙", "單位甲"] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        for (bad, good) in [("、、", "、"), ("（、", "（"), ("、）", "）"), ("、。", "。"), ("：、", "：")] {
            s = s.replacingOccurrences(of: bad, with: good)
        }
        return s
    }

    /// 單麥多人註記：與會者段標頭下插入提示（程式插入＝不受名單過濾影響）。
    /// scenario nil＝舊檔 onsite fallback，措辭照舊。
    public static func insertOnsiteNote(
        notesMD: String, scenario: MeetingScenario? = nil, onsiteCount: Int? = nil
    ) -> String {
        let countText = onsiteCount.map { $0 >= 5 ? "現場 5 人以上，" : "現場 \($0) 人，" } ?? ""
        let note: String
        switch scenario {
        case .phoneSpeaker:
            note = "> 電話擴音錄音：\(countText)單支麥克風同時收現場與電話那頭，發言歸屬僅供參考"
        case .onsite:
            note = "> 現場錄音：\(countText)全場單支麥克風收音，發言歸屬僅供參考"
        default:
            note = "> 現場錄音：全場單支麥克風收音，發言歸屬僅供參考"
        }
        var out: [String] = []
        var inserted = false
        for line in notesMD.components(separatedBy: "\n") {
            out.append(line)
            if !inserted, line.hasPrefix("## "), line.contains("與會者") {
                out.append(note)
                inserted = true
            }
        }
        return out.joined(separator: "\n")
    }

    /// 期限守門：期限欄的日期字串必須在（逐字稿＋修正）出現過，否則清空（4B 會捏造期限）。
    public static func sanitizeTodoDues(notesMD: String, sourceText: String) -> String {
        var out: [String] = []
        var inTodo = false
        for line in notesMD.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { inTodo = line.contains("待辦") }
            guard inTodo, line.contains("- [ ]"), line.contains("｜") else {
                out.append(line)
                continue
            }
            var cols = line.components(separatedBy: "｜")
            if cols.count >= 3 {
                let due = cols[2].trimmingCharacters(in: .whitespaces)
                if !due.isEmpty && !sourceText.contains(due) {
                    cols[2] = ""
                    out.append(cols.joined(separator: "｜"))
                    continue
                }
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}
