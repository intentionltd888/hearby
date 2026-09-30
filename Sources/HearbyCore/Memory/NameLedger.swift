// NameLedger — memory/NAMES.md：改過一次的名字記在這裡，下一場 Hearby 自己就對（越開會越記得）
//
// 誰會記進來（記憶開著才記）：
//   1. 在 Hearby 裡「自己改」紀錄、存檔：比對改前改後，找出「一個名字換成另一個名字」的地方
//   2. 「重新整理全篇」時寫的「A」應為「B」
//   3. 別的程式（你的 AI、編輯器）改了紀錄，再跑 --memory-rebuild <那份 md>：跟 Hearby 上次寫的那一版比（改之前要留 .bak）
//   4. 帶名冊整理時 AI 沒把握、沒改的名字 →「要確認」；在那一行最後一欄寫「是」或「不是」就算答了，同一題不再問
// 怎麼用：確認過的名字放在帶給 AI 的名冊最前面；換法「一律」的在聽打完就直接換（跟 GLOSSARY.md 的別名一樣）。
// 換法怎麼定（撞名檢查）：原字至少兩個字、別場逐字稿沒出現過、也不是名冊上別的名字的一部分＝一律；不然＝看上下文。
// 寫入紀律：只在那一節尾巴加行；改到既有的行（答題）之前先留 NAMES.md.bak-日期。
import CryptoKit
import Foundation

public enum NameLedger {
    public static let file = "NAMES.md"
    /// 每一場 Hearby 上次寫出去的紀錄長什麼樣（雜湊）：--memory-rebuild 時找「改之前那一版」用
    public static let stateFile = ".hearby-names.json"
    public static let always = "一律", byContext = "看上下文", never = "不換"

    public struct Entry: Equatable {
        public var heard, name, how, who, date, meeting: String
        public init(heard: String, name: String, how: String, who: String = "", date: String = "", meeting: String = "") {
            self.heard = heard; self.name = name; self.how = how; self.who = who; self.date = date; self.meeting = meeting
        }
    }

    public struct Question: Equatable {
        public var heard, name, meeting, answer: String
        public init(heard: String, name: String, meeting: String = "", answer: String = "") {
            self.heard = heard; self.name = name; self.meeting = meeting; self.answer = answer
        }
        /// 答了「是」／「對」
        public var yes: Bool { ["是", "對", "yes", "Yes"].contains(answer) }
        /// 答了「不是」／「不對」／「否」
        public var no: Bool { ["不是", "不對", "否", "no", "No"].contains(answer) }
    }

    public static let header = """
        # 名字確認帳（改過一次的名字記在這裡，下一場 Hearby 自己就對）

        <!-- Hearby 會自己記：在 Hearby 裡自己改紀錄、重新整理時寫的「A」應為「B」、別的程式改了紀錄後跑 --memory-rebuild（改之前要留 .bak）。
             一行一筆：- 聽到 → 正名｜換法｜誰改的｜日期｜哪一場
             換法：一律＝聽打完直接換（別場逐字稿沒出現過、不是別的名字的一部分）；看上下文＝交給 AI 看上下文才換；不換＝這不是聽錯。
             「換法」可以直接改；刪掉一行＝忘掉這筆。「要確認」那一節在最後一欄寫「是」或「不是」就算答了，同一題不再問。 -->

        ## 名字

        ## 要確認

        """

    // MARK: 讀

    public static func parse(_ text: String) -> (entries: [Entry], questions: [Question]) {
        var entries: [Entry] = []
        var qs: [Question] = []
        var asking = false
        for raw in Clean.stripHTMLComments(text).components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("## ") { asking = l.contains("要確認"); continue }
            guard l.hasPrefix("- ") else { continue }
            let cols = String(l.dropFirst(2)).components(separatedBy: "｜").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let (h, n0) = pair(cols[0]) else { continue }
            func col(_ i: Int) -> String { i < cols.count ? cols[i] : "" }
            if asking {
                var n = n0
                while n.hasSuffix("？") || n.hasSuffix("?") { n.removeLast() }
                n = n.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty, n != h { qs.append(Question(heard: h, name: n, meeting: col(1), answer: col(2))) }
            } else {
                let how = [always, byContext, never].contains(col(1)) ? col(1) : byContext
                entries.append(Entry(heard: h, name: n0, how: how, who: col(2), date: col(3), meeting: col(4)))
            }
        }
        return (entries, qs)
    }

    /// 「聽到 → 正名」（箭頭也認 -> =>；引號拿掉）；兩邊一樣或有一邊空＝nil
    static func pair(_ s: String) -> (String, String)? {
        guard let r = ["→", "->", "=>"].lazy.compactMap({ s.range(of: $0) }).first else { return nil }
        let q = CharacterSet(charactersIn: " 「」『』\"'“”")
        let h = String(s[..<r.lowerBound]).trimmingCharacters(in: q), n = String(s[r.upperBound...]).trimmingCharacters(in: q)
        return h.isEmpty || n.isEmpty || h == n ? nil : (h, n)
    }

    static func read() -> String? { try? String(contentsOf: Paths.memory.appendingPathComponent(file), encoding: .utf8) }

    // MARK: 寫（純函式：文字進、文字出）

    /// 在「名字」「要確認」兩節尾巴加行（沒有檔＝從表頭建）；已經有同一組（聽到→正名）的不再加，問過或記過的不再問
    public static func adding(entries new: [Entry] = [], questions newQs: [Question] = [], to text: String?) -> String {
        var lines = (text ?? header).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let (have, asked) = parse(lines.joined(separator: "\n"))
        let known = Set(have.map { $0.heard + "→" + $0.name })
        var addE: [String] = []
        var seen = known
        for e in new where !seen.contains(e.heard + "→" + e.name) {
            seen.insert(e.heard + "→" + e.name)
            addE.append("- \(e.heard) → \(e.name)｜\(e.how)｜\(e.who)｜\(e.date)｜\(e.meeting)")
        }
        var addQ: [String] = []
        var askedKeys = Set(asked.map { $0.heard + "→" + $0.name })
        for q in newQs where !seen.contains(q.heard + "→" + q.name) && !askedKeys.contains(q.heard + "→" + q.name) {
            askedKeys.insert(q.heard + "→" + q.name)
            addQ.append("- \(q.heard) → \(q.name)？｜\(q.meeting)｜\(q.answer)")
        }
        if !addE.isEmpty { insert(addE, under: "## 名字", into: &lines) }
        if !addQ.isEmpty { insert(addQ, under: "## 要確認", into: &lines) }
        return lines.joined(separator: "\n")
    }

    /// 把行放在那一節的尾巴（尾巴的空行之前）；沒有那一節就在檔尾開一節
    static func insert(_ add: [String], under heading: String, into lines: inout [String]) {
        guard let h = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }) else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines += ["", heading] + add + [""]
            return
        }
        var e = lines[(h + 1)...].firstIndex(where: { $0.hasPrefix("## ") || $0.hasPrefix("# ") }) ?? lines.count
        while e > h + 1, lines[e - 1].trimmingCharacters(in: .whitespaces).isEmpty { e -= 1 }
        lines.insert(contentsOf: add, at: e)
    }

    /// 答「要確認」的一題：那一行最後一欄寫上答案（找不到那一題＝原樣）
    public static func answering(heard: String, name: String, answer: String, in text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var asking = false
        for i in lines.indices {
            let l = lines[i].trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("## ") { asking = l.contains("要確認"); continue }
            guard asking, l.hasPrefix("- ") else { continue }
            let cols = String(l.dropFirst(2)).components(separatedBy: "｜").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let (h, n0) = pair(cols[0]) else { continue }
            var n = n0
            while n.hasSuffix("？") || n.hasSuffix("?") { n.removeLast() }
            guard h == heard, n.trimmingCharacters(in: .whitespaces) == name else { continue }
            lines[i] = "- \(heard) → \(name)？｜\(cols.count > 1 ? cols[1] : "")｜\(answer)"
            break
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 用

    /// 帶進整理的名冊行（放在名冊最前面）：確認過的名字；確認過不是聽錯的
    public static func contextLines(_ entries: [Entry], _ qs: [Question]) -> [String] {
        var order: [String] = []
        var heards: [String: [String]] = [:]
        var nots: [String] = []
        func add(_ name: String, _ h: String) {
            if heards[name] == nil { order.append(name); heards[name] = [] }
            if !heards[name]!.contains(h) { heards[name]!.append(h) }
        }
        for e in entries {
            if e.how == never { nots.append("- 「\(e.heard)」不是\(e.name)：不要換") }
            else { add(e.name, e.how == always ? e.heard : e.heard + "（看上下文）") }
        }
        for q in qs {
            if q.yes { add(q.name, q.heard + "（看上下文）") }
            else if q.no { nots.append("- 「\(q.heard)」不是\(q.name)：不要換") }
        }
        var out: [String] = []
        if !order.isEmpty { out += ["## 確認過的名字"] + order.map { "- \($0)｜｜\(heards[$0]!.joined(separator: "、"))｜確認過｜" } }
        if !nots.isEmpty { out += ["## 確認過不是聽錯"] + nots }
        return out
    }

    /// 換法「一律」的：聽打完直接換（Clean.aliasTable 讀）
    public static func aliasPairs(_ entries: [Entry]) -> [(alias: String, canonical: String)] {
        entries.filter { $0.how == always && $0.heard.count >= 2 }.map { ($0.heard, $0.name) }
    }

    // MARK: 學

    /// 撞名檢查：原字至少兩個字、別場逐字稿沒出現過、也不是名冊上別的名字的一部分＝一律；不然看上下文
    public static func classify(heard: String, meeting: String, others: [(id: String, transcript: String)], known: [String]) -> String {
        guard heard.count >= 2 else { return byContext }
        if known.contains(where: { $0 != heard && $0.contains(heard) }) { return byContext }
        if others.contains(where: { $0.id != meeting && $0.transcript.contains(heard) }) { return byContext }
        return always
    }

    static let numerals = CharacterSet(charactersIn: "0123456789０１２３４５６７８９〇一二三四五六七八九十百千萬万億亿兩两零")

    /// 像不像名字：正名裡有名冊上的名字；或兩邊都不長（6 個字以內）、沒有數字
    static func nameLike(_ heard: String, _ name: String, known: [String]) -> Bool {
        if known.contains(where: { $0.count >= 2 && name.contains($0) }) { return true }
        let num = { (s: String) in s.unicodeScalars.contains { numerals.contains($0) } }
        return heard.count <= 6 && name.count <= 6 && !num(heard) && !num(name)
    }

    /// 基本的樣子：兩邊都有字、不一樣、不超過 12 個字、沒有一邊包含另一邊（那是加字刪字，不是聽錯）
    static func plausible(_ heard: String, _ name: String) -> Bool {
        let word = { (s: String) in s.contains { isWordChar($0) } }
        return !heard.isEmpty && !name.isEmpty && heard != name && heard.count <= 12 && name.count <= 12
            && !heard.contains(name) && !name.contains(heard) && word(heard) && word(name)
    }

    static func isWordChar(_ c: Character) -> Bool {
        guard let u = c.unicodeScalars.first else { return false }
        let v = u.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v) || isLatin(c)
    }
    static func isLatin(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let u = c.unicodeScalars.first else { return false }
        return (0x41...0x5A).contains(u.value) || (0x61...0x7A).contains(u.value) || (0x30...0x39).contains(u.value)
    }

    /// 重新整理時寫的「A」應為「B」（同 PolishGuards.applyMechanicalCorrections 的寫法）→ 像名字的配對
    public static func pairs(fromCorrections corrections: String, known: [String]) -> [(heard: String, name: String)] {
        let pattern = #"「([^「」]{1,40})」\s*(?:應為|应为|是|改成|改為)\s*「([^「」]{1,40})」"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = corrections as NSString
        var out: [(String, String)] = []
        for m in re.matches(in: corrections, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges == 3 {
            let h = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let n = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard h.count >= 2, plausible(h, n), nameLike(h, n, known: known), !out.contains(where: { $0 == (h, n) }) else { continue }
            out.append((h, n))
        }
        return out
    }

    /// 改前改後比對，找出「一個名字換成另一個名字」的地方（行對行、行內逐字對）。留下的條件：
    ///   ・樣子對（plausible）、像名字（nameLike）
    ///   ・名冊蓋不住的一個字改動：同一組在這次改動裡出現兩次以上才算（「畫部→劃部」改一次不算）
    ///   ・有英文的：正名裡要有名冊上的名字（「Cloud→Claud」這種半個字不算）
    ///   ・改在紀錄（摘要、重點…）裡的：正名剛好是名冊上的名字、或逐字稿也改了同一組、或同一組改了兩次以上
    public static func pairs(old: String, new: String, known: [String]) -> [(heard: String, name: String)] {
        let a = old.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let b = new.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let tb = b.firstIndex { $0.hasPrefix("## 逐字稿") } ?? b.count
        var raw: [(heard: String, name: String, transcript: Bool, alts: [(String, String)])] = []
        var dels: [Int] = [], ins: [Int] = []
        func flush() {
            if !dels.isEmpty, dels.count == ins.count {
                for (x, y) in zip(dels, ins) {
                    for h in hunks(a[x], b[y], known: known) { raw.append((h.old, h.new, y > tb, h.alts)) }
                }
            }
            dels = []; ins = []
        }
        for (i, j) in align(a, b) {
            switch (i, j) {
            case let (x?, nil): dels.append(x)
            case let (nil, y?): ins.append(y)
            default: flush()
            }
        }
        flush()
        // 一個字的改動：每一處可能的寫法各算一次
        var altCount: [String: Int] = [:]
        for r in raw where !r.alts.isEmpty {
            var seen = Set<String>()
            for c in r.alts where seen.insert(c.0 + "→" + c.1).inserted { altCount[c.0 + "→" + c.1, default: 0] += 1 }
        }
        var found: [(heard: String, name: String, transcript: Bool, repeated: Bool)] = []
        for r in raw {
            if r.alts.isEmpty { found.append((r.heard, r.name, r.transcript, false)); continue }
            // 出現最多次的寫法（「曉安」每一處都有，「由曉安」只有兩處）；一樣多挑最具體的（alts 由最具體排起）
            var pick: (String, String)? = nil
            var most = 1
            for c in r.alts where (altCount[c.0 + "→" + c.1] ?? 0) > most { pick = c; most = altCount[c.0 + "→" + c.1]! }
            if let c = pick { found.append((c.0, c.1, r.transcript, true)) }
        }
        let latin = { (s: String) in s.contains(where: isLatin) }
        var out: [(heard: String, name: String)] = []
        for f in found {
            guard plausible(f.heard, f.name), nameLike(f.heard, f.name, known: known) else { continue }
            let knownName = known.contains { $0.count >= 2 && f.name.contains($0) }
            if latin(f.heard) || latin(f.name) { guard knownName else { continue } }
            let times = found.filter { $0.heard == f.heard && $0.name == f.name }.count
            if !f.transcript, !f.repeated {
                guard known.contains(f.name) || times >= 2 || found.contains(where: { $0.transcript && $0.heard == f.heard && $0.name == f.name }) else { continue }
            }
            guard !out.contains(where: { $0 == (f.heard, f.name) }) else { continue }
            out.append((f.heard, f.name))
        }
        return out
    }

    /// 一行裡改了哪些地方：逐字對齊；中文改動之間只隔一個中文字的併成一處（「甲乙→丙乙丁」），隔標點或中英交界不併。
    /// 有英文的補到整個英文字；重疊的併成一處；再往外補到名冊上最長、蓋得住這一處的名字（「曉明→小明」→「王曉明→王小明」、
    /// 「Cloud→Claude」→「Cloud Code→Claude Code」）。中文補不到名字又只有一個字的：alts＝前後各補、只補右、只補左三種寫法
    /// （由最具體排起），pairs() 挑這次改動裡出現最多次（至少兩次）的那一個，一樣多挑最具體的
    static func hunks(_ x: String, _ y: String, known: [String]) -> [(old: String, new: String, alts: [(String, String)])] {
        let a = Array(x), b = Array(y)
        struct H { var a0, a1, b0, b1: Int; var cjk: Bool }
        var hs: [H] = []
        var cur: H? = nil
        var gap = 0   // 這一處最後一個改動之後，連續幾個一樣的字
        var ai = 0, bi = 0
        for (i, j) in align(a, b) {
            if i != nil, j != nil {
                if cur != nil {
                    gap += 1
                    if gap > 1 || !isCJK(a[ai]) || !cur!.cjk { hs.append(cur!); cur = nil; gap = 0 }
                }
                ai += 1; bi += 1
                continue
            }
            let ch = i != nil ? a[ai] : b[bi]
            if let c = cur, gap == 1, !isCJK(ch) || !c.cjk { hs.append(c); cur = nil }
            if cur == nil { cur = H(a0: ai, a1: ai, b0: bi, b1: bi, cjk: true) }
            gap = 0
            if !isCJK(ch) { cur!.cjk = false }
            if i != nil { ai += 1 } else { bi += 1 }
            cur!.a1 = ai; cur!.b1 = bi
        }
        if let c = cur { hs.append(c) }
        func mergeOverlaps(_ list: [H]) -> [H] {
            var out: [H] = []
            for h in list {
                if var last = out.last, h.a0 < last.a1 || h.b0 < last.b1 {
                    last.a0 = min(last.a0, h.a0); last.b0 = min(last.b0, h.b0); last.a1 = max(last.a1, h.a1); last.b1 = max(last.b1, h.b1); last.cjk = last.cjk && h.cjk
                    out[out.count - 1] = last
                } else { out.append(h) }
            }
            return out
        }
        // 往外補到名冊上最長、蓋得住這一處的名字（補上去的前後字兩邊要一樣）
        func expandKnown(_ h: inout H) -> Bool {
            var best: (s: Int, e: Int)? = nil
            for kn in known where kn.count >= 2 {
                let kc = Array(kn)
                guard kc.count > (best.map { $0.e - $0.s } ?? 0), kc.count <= b.count, kc.count >= h.b1 - h.b0 else { continue }
                var st = max(0, h.b1 - kc.count)
                while st <= min(h.b0, b.count - kc.count) {
                    let en = st + kc.count, la = h.a0 - (h.b0 - st), ra = h.a1 + (en - h.b1)
                    if la >= 0, ra <= a.count, Array(b[st..<en]) == kc, a[la..<h.a0] == b[st..<h.b0], a[h.a1..<ra] == b[h.b1..<en] {
                        best = (st, en)
                        break
                    }
                    st += 1
                }
            }
            guard let kb = best else { return false }
            h.a0 -= h.b0 - kb.s; h.a1 += kb.e - h.b1; h.b0 = kb.s; h.b1 = kb.e
            return true
        }
        for k in hs.indices where !hs[k].cjk {
            var h = hs[k]
            while h.a0 > 0, h.b0 > 0, a[h.a0 - 1] == b[h.b0 - 1], isLatin(a[h.a0 - 1]) { h.a0 -= 1; h.b0 -= 1 }
            while h.a1 < a.count, h.b1 < b.count, a[h.a1] == b[h.b1], isLatin(a[h.a1]) { h.a1 += 1; h.b1 += 1 }
            hs[k] = h
        }
        hs = mergeOverlaps(hs)
        var shortOnes = Set<Int>()
        for k in hs.indices {
            var h = hs[k]
            if !expandKnown(&h), h.cjk, h.a1 - h.a0 < 2 || h.b1 - h.b0 < 2 { shortOnes.insert(k) }
            hs[k] = h
        }
        var out: [(old: String, new: String, alts: [(String, String)])] = []
        for (k, h) in hs.enumerated() {
            let o = String(a[h.a0..<h.a1]).trimmingCharacters(in: .whitespaces), n = String(b[h.b0..<h.b1]).trimmingCharacters(in: .whitespaces)
            guard !o.isEmpty || !n.isEmpty, o != n else { continue }
            var alts: [(String, String)] = []
            if shortOnes.contains(k) {
                let l = h.a0 > 0 && h.b0 > 0 && a[h.a0 - 1] == b[h.b0 - 1] && isCJK(a[h.a0 - 1])
                let r = h.a1 < a.count && h.b1 < b.count && a[h.a1] == b[h.b1] && isCJK(a[h.a1])
                func span(_ dl: Int, _ dr: Int) -> (String, String) { (String(a[(h.a0 - dl)..<(h.a1 + dr)]), String(b[(h.b0 - dl)..<(h.b1 + dr)])) }
                if l && r { alts.append(span(1, 1)) }
                if r { alts.append(span(0, 1)) }
                if l { alts.append(span(1, 0)) }
                if alts.isEmpty { continue }
            }
            if o.isEmpty || n.isEmpty, alts.isEmpty { continue }
            out.append((o, n, alts))
        }
        return out
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let u = c.unicodeScalars.first else { return false }
        let v = u.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    /// 最長共同子序列的對齊（兩邊依序走完）：(a 的位置, b 的位置)，一邊是 nil＝那一邊多出來的。
    /// 頭尾一樣的先剝掉再算；同分時先走 a（刪）。Windows 版一步一步照做，結果一樣
    static func align<T: Equatable>(_ a: [T], _ b: [T]) -> [(Int?, Int?)] {
        var pre = 0
        while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        let n = a.count - pre - suf, m = b.count - pre - suf
        var dp = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[pre + i] == b[pre + j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var out: [(Int?, Int?)] = (0..<pre).map { ($0, $0) }
        var i = 0, j = 0
        while i < n, j < m {
            if a[pre + i] == b[pre + j] { out.append((pre + i, pre + j)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { out.append((pre + i, nil)); i += 1 }
            else { out.append((nil, pre + j)); j += 1 }
        }
        while i < n { out.append((pre + i, nil)); i += 1 }
        while j < m { out.append((nil, pre + j)); j += 1 }
        for k in 0..<suf { out.append((a.count - suf + k, b.count - suf + k)) }
        return out
    }

    /// 紀錄表頭「> 名字更正：…沒改：A→B？、C→D？（…）」→ 要確認的題目
    public static func questions(fromRecord md: String, meeting: String) -> [Question] {
        guard let line = md.components(separatedBy: "\n").first(where: { $0.hasPrefix("> 名字更正：") }),
              let r = line.range(of: "沒改：") else { return [] }
        var rest = String(line[r.upperBound...])
        if let p = rest.range(of: "（沒把握") { rest = String(rest[..<p.lowerBound]) }
        if let p = rest.range(of: "…等") { rest = String(rest[..<p.lowerBound]) }
        return rest.components(separatedBy: "、").compactMap { item -> Question? in
            var t = item.trimmingCharacters(in: .whitespaces)
            while t.hasSuffix("？") || t.hasSuffix("?") { t.removeLast() }
            guard let (h, n) = pair(t) else { return nil }
            return Question(heard: h, name: n, meeting: meeting)
        }
    }

    // MARK: 檔案

    /// 名冊（ROSTER.md）與這本帳裡的名字：撞名檢查與「像不像名字」用
    static func knownNames(entries: [Entry]) -> [String] {
        var out = entries.filter { $0.how != never }.map(\.name)
        if let r = try? String(contentsOf: Paths.memory.appendingPathComponent("ROSTER.md"), encoding: .utf8) {
            let lines = Clean.stripHTMLComments(r).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            out += PolishContext.rosterNames(lines.filter { $0.hasPrefix("- ") })
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// 記進 NAMES.md（記憶開著才記；已經有的不再記）；回新記下的
    @discardableResult
    public static func record(_ pairs: [(heard: String, name: String)], who: String, mdURL: URL, now: Date = Date()) -> [Entry] {
        guard ConfigStore.shared.current.memoryEnabled, !pairs.isEmpty else { return [] }
        let text = read()
        let have = parse(text ?? "").entries
        let id = mdURL.deletingPathExtension().lastPathComponent
        let known = knownNames(entries: have)
        let others = MemoryStore.allRecords().compactMap { u -> (id: String, transcript: String)? in
            let rid = u.deletingPathExtension().lastPathComponent
            guard rid != id, let md = try? String(contentsOf: u, encoding: .utf8) else { return nil }
            return (rid, RecordMD.transcript(of: md) ?? "")
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: now)
        // 同一個聽錯寫法對到兩個以上的正名（「梅玲」→陳美玲／林美玲）＝一詞多人：看上下文
        let targets = Dictionary(grouping: pairs.map { ($0.heard, $0.name) } + have.filter { $0.how != never }.map { ($0.heard, $0.name) }, by: { $0.0 }).mapValues { Set($0.map { $0.1 }) }
        let new = pairs.filter { p in !have.contains { $0.heard == p.heard && $0.name == p.name } }.map {
            Entry(heard: $0.heard, name: $0.name,
                  how: (targets[$0.heard]?.count ?? 0) > 1 ? byContext : classify(heard: $0.heard, meeting: id, others: others, known: known),
                  who: who, date: day, meeting: id)
        }
        guard !new.isEmpty else { return [] }
        do {
            try FileManager.default.createDirectory(at: Paths.memory, withIntermediateDirectories: true)
            try adding(entries: new, to: text).write(to: Paths.memory.appendingPathComponent(file), atomically: true, encoding: .utf8)
            HearbyLog.write("names: +\(new.count) (\(who)) \(id)")
        } catch { HearbyLog.write("names: 寫不進 \(file)：\(error)"); return [] }
        return new
    }

    /// 自己改紀錄前後：記下改過的名字
    @discardableResult
    public static func learn(old: String, new: String, who: String, mdURL: URL) -> [Entry] {
        guard ConfigStore.shared.current.memoryEnabled else { return [] }
        return record(pairs(old: old, new: new, known: knownNames(entries: parse(read() ?? "").entries)), who: who, mdURL: mdURL)
    }

    /// 重新整理時寫的「A」應為「B」：記下像名字的
    @discardableResult
    public static func learn(corrections: String, mdURL: URL) -> [Entry] {
        guard ConfigStore.shared.current.memoryEnabled else { return [] }
        return record(pairs(fromCorrections: corrections, known: knownNames(entries: parse(read() ?? "").entries)), who: "重新整理時的更正", mdURL: mdURL)
    }

    /// --memory-rebuild：紀錄被別的程式改過（跟 Hearby 上次寫的不一樣），拿「上次寫的那一版」（.bak／_舊版）比對、記下改過的名字。
    /// 找不到那一版（改之前沒留備份）＝學不到，回 nil
    public static func learnFromEdit(mdURL: URL) -> [Entry]? {
        guard ConfigStore.shared.current.memoryEnabled, let md = try? String(contentsOf: mdURL, encoding: .utf8) else { return [] }
        let id = mdURL.deletingPathExtension().lastPathComponent
        guard let last = loadState()[id] else { return [] }
        guard hash(md) != last else { return [] }
        guard let base = MemoryStore.olderVersions(of: mdURL).last(where: { hash($0) == last }) else { return nil }
        return learn(old: base, new: md, who: "改紀錄時改的", mdURL: mdURL)
    }

    /// 記憶同步完：記下這一版長什麼樣（下次找得到「上次寫的」）、把 AI 沒把握的名字放進「要確認」
    static func afterSync(mdURL: URL, md: String) {
        let id = mdURL.deletingPathExtension().lastPathComponent
        var st = loadState()
        let h = hash(md)
        if st[id] != h {
            st[id] = h
            saveState(st)
        }
        let qs = questions(fromRecord: md, meeting: id)
        guard !qs.isEmpty else { return }
        let text = read()
        let out = adding(questions: qs, to: text)
        if out != (text ?? header) || text == nil {
            if (try? out.write(to: Paths.memory.appendingPathComponent(file), atomically: true, encoding: .utf8)) != nil {
                HearbyLog.write("names: 要確認 +\(qs.count) \(id)")
            }
        }
    }

    /// 答一題（在 app 裡按「是／不是」）：先留 NAMES.md.bak-日期 再寫
    public static func answer(heard: String, name: String, yes: Bool) throws {
        guard let text = read() else { throw HearbyError("找不到 \(file)") }
        let out = answering(heard: heard, name: name, answer: yes ? "是" : "不是", in: text)
        guard out != text else { return }
        try MemoryStore.Backups().before(Paths.memory.appendingPathComponent(file))
        try out.write(to: Paths.memory.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    /// 這一場還沒答的題目（app 在紀錄頁列出來）
    public static func pending(meeting: String) -> [Question] {
        parse(read() ?? "").questions.filter { $0.meeting == meeting && !$0.yes && !$0.no }
    }

    /// 一場改了名字：「上次寫出去那一版」的記錄換到新 id 名下（NAMES.md 裡提到的 id 由 MemoryStore 一起換）
    static func renameMeeting(from old: String, to new: String) {
        var st = loadState()
        guard old != new, let h = st[old] else { return }
        st[old] = nil
        st[new] = h
        saveState(st)
    }

    static func saveState(_ st: [String: String]) {
        let obj: [String: Any] = ["schemaVersion": 1, "written": st]
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: Paths.memory.appendingPathComponent(stateFile), options: .atomic)
        }
    }

    static func loadState() -> [String: String] {
        guard let d = try? Data(contentsOf: Paths.memory.appendingPathComponent(stateFile)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o["written"] as? [String: String] ?? [:]
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
