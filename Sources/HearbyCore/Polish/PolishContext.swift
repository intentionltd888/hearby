// PolishContext — 整理會議時多帶的三樣背景：名冊（memory/ROSTER.md）、已定案（THREADS.md）、還沒完成的待辦（OPEN.md）
//
// 只有「記憶開著、而且 memory/ROSTER.md 或 NAMES.md（名字確認帳，見 NameLedger）在」才帶；都沒有＝整理跟以前一模一樣。
// NAMES.md 確認過的名字放在名冊最前面（太長從後面截，這幾行一定帶到）。
// memory/STATE.md（現況：案子做到哪、還沒完成的待辦、最近定案、還沒定的事；公司的同步程式或你的 AI 寫的）在的話，
// 待辦用它的（不用 OPEN.md）、定案用它的（沒有才用 THREADS.md），另外帶案子現況與還沒定的事。格式：
//   ## 案子 ／ ## 還沒完成的待辦 ／ ## 最近定案 ／ ## 還沒定的事   ← 節名裡有這幾個詞就認
//   - 一行一件（欄位用｜分，內容照寫）
// ROSTER.md 是使用者自己（或他的 AI、他公司的同步程式）放進來的，Hearby 只讀不寫。格式：
//   ## 人                                                  ← 分節，節名隨意
//   - 正名｜別名、簡稱｜常被聽錯的寫法｜是誰／什麼｜讀音       ← 一行一個，後面幾欄可空；別名＝也可以這樣寫，聽錯的＝要改掉；
//                                                           寫法後面加「（看上下文）」＝一般詞或不只一個人，上下文講得通才換
// 「# 」大標、說明文字、HTML 註解不帶。太長就從後面截：常出現的寫前面。
// 本機小模型（endpoint）、訪談、筆記不帶（見 Polish.buildNotes）。
import Foundation

public struct PolishContext: Equatable {
    /// 帶給模型的名冊（只留「## 」與「- 」行，截過長度）
    public var roster: String
    /// THREADS.md 裡看起來已經定案的行：「【議題】內容」，每條議題最後幾行
    public var decided: [String]
    /// OPEN.md 還沒打勾的待辦（不含這一場自己的）：「事項｜負責人｜期限｜會議日期」
    public var openTodos: [String]
    /// 名冊裡對的寫法（正名＋別名；聽錯的不算）：「名字更正」只能改成含這些名字的字
    public var names: [String]
    /// STATE.md 的案子現況（開會前記的）
    public var projects: [String] = []
    /// STATE.md 的還沒定的事
    public var undecided: [String] = []

    public static let rosterLimit = 12_000
    public static let decidedLimit = 3_000
    public static let openLimit = 3_000
    public static let projectLimit = 3_000
    public static let undecidedLimit = 2_000

    public init(roster: String, decided: [String] = [], openTodos: [String] = [], names: [String] = [], projects: [String] = [], undecided: [String] = []) {
        self.roster = roster; self.decided = decided; self.openTodos = openTodos; self.names = names; self.projects = projects; self.undecided = undecided
    }

    /// 從記憶夾讀；記憶關著、或沒有名冊（或名冊一行都沒有）＝nil。meetingID＝這一場（它自己的待辦不算「之前的」）
    public static func load(excluding meetingID: String? = nil) -> PolishContext? {
        guard ConfigStore.shared.current.memoryEnabled else { return nil }
        func read(_ n: String) -> String? { try? String(contentsOf: Paths.memory.appendingPathComponent(n), encoding: .utf8) }
        let roster = read("ROSTER.md"), names = read(NameLedger.file), state = read("STATE.md")
        guard roster != nil || names != nil || state != nil else { return nil }
        return make(roster: roster ?? "", threads: read("THREADS.md"), open: read("OPEN.md"), excluding: meetingID, names: names, state: state)
    }

    /// 純函式（合約夾具用）；limit＝名冊最多帶幾個字
    public static func make(roster raw: String, threads: String?, open: String?, excluding meetingID: String?, limit: Int = rosterLimit,
                            names: String? = nil, state: String? = nil) -> PolishContext? {
        let ledger = names.map { NameLedger.parse($0) }
        let lines = (ledger.map { NameLedger.contextLines($0.entries, $0.questions) } ?? []) + Clean.stripHTMLComments(raw).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("## ") || $0.hasPrefix("- ") }
        let st = stateSections(state ?? "")
        let hasState = st.values.contains { !$0.isEmpty }
        guard lines.contains(where: { $0.hasPrefix("- ") }) || hasState else { return nil }
        var kept: [String] = []
        var used = 0
        var cut = 0
        for (i, l) in lines.enumerated() {
            if used + l.count + 1 > limit { cut = lines[i...].filter { $0.hasPrefix("- ") }.count; break }
            kept.append(l)
            used += l.count + 1
        }
        while let last = kept.last, last.hasPrefix("## ") { kept.removeLast() }   // 截在標題後面＝那一節一行都沒帶
        if cut > 0 { kept.append("- …（名冊太長，後面 \(cut) 行沒帶）") }
        guard hasState else {
            return PolishContext(roster: kept.joined(separator: "\n"), decided: decidedLines(threads ?? ""),
                                 openTodos: openLines(open ?? "", excluding: meetingID), names: rosterNames(kept))
        }
        let decided = st["定案"]!.isEmpty ? decidedLines(threads ?? "") : capped(st["定案"]!, decidedLimit)
        return PolishContext(roster: kept.joined(separator: "\n"), decided: decided, openTodos: capped(st["待辦"]!, openLimit),
                             names: rosterNames(kept), projects: capped(st["案子"]!, projectLimit), undecided: capped(st["還沒定"]!, undecidedLimit))
    }

    /// 名冊裡對的寫法：有「｜」的行的第一欄（正名）與第二欄（別名），去掉「（看上下文）」這類括號註記；
    /// 第三欄起（聽錯的寫法、說明）不算；第二欄帶「：」的是說明、不是別名
    static func rosterNames(_ lines: [String]) -> [String] {
        var out: [String] = []
        func add(_ s: String) {
            let t = s.replacingOccurrences(of: #"（[^）]*）"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !out.contains(t) { out.append(t) }
        }
        for l in lines where l.hasPrefix("- ") && l.contains("｜") {
            let cols = String(l.dropFirst(2)).components(separatedBy: "｜")
            add(cols[0])
            if cols.count > 1, !cols[1].contains("：") { Clean.splitTerms(cols[1]).forEach(add) }
        }
        return out
    }

    static let decidedWords = ["定案", "決定", "決議", "確定", "結論", "上線", "同意"]
    static let undecidedWords = ["待決定", "待定", "還沒", "未定", "不確定", "等你", "待確認", "要不要", "再定", "[[?]]"]

    /// THREADS.md：「## 議題」底下有定案字眼（定案、決定、確定…）、又沒有「待決定、還沒…」的行，每條議題取最後 3 行；
    /// 總長有上限，超過就從前面（舊的議題）丟
    static func decidedLines(_ text: String) -> [String] {
        var groups: [[String]] = []
        var title = ""
        var cur: [String] = []
        func flush() {
            if !cur.isEmpty { groups.append(cur.suffix(3).map { "【\(clip(title, 20))】\($0)" }) }
            cur = []
        }
        for raw in Clean.stripHTMLComments(text).components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("## ") { flush(); title = String(l.dropFirst(3)).trimmingCharacters(in: .whitespaces); continue }
            guard !title.isEmpty, l.hasPrefix("- ") else { continue }
            let t = String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard decidedWords.contains(where: { t.contains($0) }), !undecidedWords.contains(where: { t.contains($0) }) else { continue }
            cur.append(clip(t, 120))
        }
        flush()
        var picked: [[String]] = []
        var used = 0
        for g in groups.reversed() {
            let n = g.reduce(0) { $0 + $1.count + 1 }
            if used + n > decidedLimit { break }
            picked.insert(g, at: 0)
            used += n
        }
        return picked.flatMap { $0 }
    }

    /// OPEN.md 還沒打勾的待辦（「- [ ] 事項｜負責人｜期限｜會議id」），不含這一場的；超過上限留最新的（檔尾）
    static func openLines(_ text: String, excluding meetingID: String?) -> [String] {
        var rows: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("- [ ] ") else { continue }
            let cols = String(l.dropFirst(6)).components(separatedBy: "｜").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !cols[0].isEmpty else { continue }
            let meeting = cols.count >= 4 ? cols[cols.count - 1] : ""
            if let id = meetingID, !id.isEmpty, meeting == id { continue }
            let owner = cols.count > 1 ? cols[1] : "", due = cols.count > 2 ? cols[2] : ""
            let day = String(meeting.prefix(10))
            rows.append("\(cols[0])｜\(owner)｜\(due)" + (day.isEmpty ? "" : "｜\(day)"))
        }
        var picked: [String] = []
        var used = 0
        for r in rows.reversed() {
            if used + r.count + 1 > openLimit { break }
            picked.insert(r, at: 0)
            used += r.count + 1
        }
        return picked
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n - 1)) + "…" }

    /// STATE.md 的四節（節名裡有「案子」「待辦」「定案」「還沒定」就認，「還沒定」先認）：每節的「- 」行（去掉「- 」）
    static func stateSections(_ text: String) -> [String: [String]] {
        var out: [String: [String]] = ["案子": [], "待辦": [], "定案": [], "還沒定": []]
        var cur: String? = nil
        for raw in Clean.stripHTMLComments(text).components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("## ") { cur = ["還沒定", "案子", "待辦", "定案"].first { l.contains($0) }; continue }
            guard let c = cur, l.hasPrefix("- ") else { continue }
            let t = String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out[c]!.append(t) }
        }
        return out
    }

    /// 從前面算起放得下幾行就帶幾行（寫的人把重要的放前面）
    static func capped(_ lines: [String], _ limit: Int) -> [String] {
        var out: [String] = []
        var used = 0
        for l in lines {
            if used + l.count + 1 > limit { break }
            out.append(l); used += l.count + 1
        }
        return out
    }
}
