// SoundAlike — 讀音比對：逐字稿裡唸起來像名冊名字、字卻不一樣的片段（「隱形」像「尹馨」、「郁婷」像「昱廷」）
//
// 只是候選，Hearby 自己不照它改任何字：大多是一般詞（「諮詢」像「姿均」），帶給整理的 AI 看上下文決定（Prompt.memoryBlock 的一節），
// AI 認得出來才列進「## 名字更正」。另一個用途：AI 把字改成名冊名字的一段（簡稱：亞特蘭提斯→「亞特」）時，
// 原字要唸起來像它才算（NameFixes.known）。
// 比對規則（Pinyin）：每個字「差一點」都要對得上，而且最多一個字只是差一點（其他要聽起來一樣）；長度一樣，2–6 個字。
// 名冊第 3 欄（已知的聽錯寫法）交給名冊那條規則處理，這裡先遮掉不再列；原字裡有「的、是、有、一…」這類字的不列（幾乎都是一般詞）。
import Foundation

public enum SoundAlike {
    /// rank＝名冊第幾行（名冊照重要性排：自己人、案子、公司、產品、其他）
    public struct Target: Equatable {
        public var name: String
        public var syllables: [String]
        public var rank: Int
        public init(name: String, syllables: [String], rank: Int) { self.name = name; self.syllables = syllables; self.rank = rank }
    }

    public struct Hit: Equatable {
        public var heard: String
        public var names: [String]
        public var count: Int
        public var stamps: [String]
        public var rank: Int
        public init(heard: String, names: [String], count: Int, stamps: [String], rank: Int) {
            self.heard = heard; self.names = names; self.count = count; self.stamps = stamps; self.rank = rank
        }
    }

    /// 原字裡有這些字就不列（「有人」像「佑任」、「是為」像「思緯」這種一般詞最多）
    static let stop: Set<Character> = Set("的了是在我你他她它們這那個就都也要會說很不沒嗎呢吧啊喔哦呀嗯欸耶有一")
    /// 三個字、第一個字是常見的姓：另外拿後兩個字比（講話常只叫名字：吳昱廷→昱廷）
    static let surnames: Set<Character> = Set("陳林黃張李王吳劉蔡楊許鄭謝郭洪曾邱廖賴周徐蘇葉莊呂江何蕭羅高潘簡朱鍾游彭詹胡施沈余盧梁趙顏柯翁魏孫戴范方宋鄧杜傅侯曹薛丁卓阮馬董溫唐藍蔣石古紀姚連馮歐程湯田康姜汪白鄒尤巫鐘黎涂龔嚴韓袁金童陸夏柳邵錢伍倪于譚駱熊任甘秦顧毛章史官萬俞雷粘饒闕凌崔尹孔辛武辜陶段龍韋葛池孟褚殷麥賀賈莫文管關向包丘梅華利裴樊房全佘左花")
    /// 帶給 AI 最多幾組
    public static let listLimit = 60

    /// 名冊 → 比對目標（正名、別名裡 2–6 個漢字的段；第 5 欄的讀音蓋過表）與已知的聽錯寫法（第 3 欄、「「X」可能是／不是…」那種行的 X）
    public static func targets(roster: String) -> (targets: [Target], heard: [String]) {
        var targets: [Target] = []
        var names = Set<String>()
        var heard: [String] = []
        func strip(_ s: String) -> String {
            s.replacingOccurrences(of: #"（[^）]*）"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        func addHeard(_ s: String) {
            let t = strip(s)
            if t.count >= 2, !heard.contains(t) { heard.append(t) }
        }
        var rank = 0
        func add(_ run: [Character], _ reading: [Character: String]) {
            let name = String(run)
            guard (2...6).contains(run.count), !names.contains(name) else { return }
            var syl: [String] = []
            for ch in run {
                guard let p = reading[ch] ?? Pinyin.of(ch) else { return }
                syl.append(p)
            }
            names.insert(name)
            targets.append(Target(name: name, syllables: syl, rank: rank))
        }
        for raw in Clean.stripHTMLComments(roster).components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("- ") else { continue }
            guard l.contains("｜") else {
                // 「- 「品博」可能是 黃品柏：看上下文才換」「- 「星核」不是星河：不要換」
                if let a = l.range(of: "「"), let b = l.range(of: "」", range: a.upperBound..<l.endIndex) { addHeard(String(l[a.upperBound..<b.lowerBound])) }
                continue
            }
            let cols = String(l.dropFirst(2)).components(separatedBy: "｜")
            var reading: [Character: String] = [:]
            if cols.count > 4 {
                let r = Array(cols[4])
                for (j, c) in r.enumerated() where c == "＝" && j > 0 && Pinyin.isHan(r[j - 1]) {
                    var k = j + 1
                    var z = ""
                    while k < r.count, isZhuyin(r[k]) { z.append(r[k]); k += 1 }
                    if let p = Pinyin.fromZhuyin(z) { reading[r[j - 1]] = p }
                }
            }
            var list = [strip(cols[0])]
            if cols.count > 1, !cols[1].contains("：") { list += Clean.splitTerms(cols[1]).map(strip) }
            for n in list {
                for run in hanRuns(n) {
                    add(run, reading)
                    if run.count == 3, surnames.contains(run[0]) { add(Array(run.dropFirst()), reading) }
                }
            }
            if cols.count > 2 { Clean.splitTerms(cols[2]).forEach(addHeard) }
            rank += 1
        }
        return (targets, heard)
    }

    static func isZhuyin(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else { return false }
        return (0x3105...0x312F).contains(v) || Pinyin.tones.contains(c)
    }

    /// 連續漢字的段
    static func hanRuns(_ s: String) -> [[Character]] {
        var out: [[Character]] = []
        var cur: [Character] = []
        for ch in s {
            if Pinyin.isHan(ch) { cur.append(ch) } else if !cur.isEmpty { out.append(cur); cur = [] }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// 逐字稿（一行一句「- [mm:ss][誰] 內容」）裡唸起來像目標、字卻不一樣的片段；
    /// 排序：像的名字在名冊越前面越前（自己人先），同一行的名字出現多的先，再照先出現的
    public static func scan(_ transcript: String, targets: [Target], heard: [String]) -> [Hit] {
        guard !targets.isEmpty else { return [] }
        var index: [String: [Int]] = [:]
        for (i, t) in targets.enumerated() { index[t.syllables.map(Pinyin.coarse).joined(separator: " "), default: []].append(i) }
        let lengths = Set(targets.map { $0.syllables.count }).sorted()
        let names = Set(targets.map(\.name))
        let known = Set(heard)
        let masks = heard.enumerated().sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }.map(\.element)
        struct Found { var heard: String; var names: [String]; var start: Int; var len: Int; var rank: Int }
        var order: [String] = []
        var agg: [String: Hit] = [:]
        for line in transcript.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("- ["), let tsEnd = l.range(of: "]["), let whoEnd = l.range(of: "] ", range: tsEnd.upperBound..<l.endIndex) else { continue }
            let stamp = String(l[l.index(l.startIndex, offsetBy: 3)..<tsEnd.lowerBound])
            var text = String(l[whoEnd.upperBound...])
            for h in masks where text.contains(h) { text = text.replacingOccurrences(of: h, with: String(repeating: " ", count: h.count)) }
            var found: [Found] = []
            var offset = 0
            for run in hanRunsWithOffsets(text) {
                offset = run.offset
                let chars = run.chars
                let py = chars.map { Pinyin.of($0) }
                let co = py.map { $0.map(Pinyin.coarse) }
                let ky = py.map { $0.map(Pinyin.key) }
                for n in lengths where n <= chars.count {
                    for i in 0...(chars.count - n) {
                        let cs = co[i..<(i + n)]
                        guard !cs.contains(where: { $0 == nil }), let cands = index[cs.map { $0! }.joined(separator: " ")] else { continue }
                        let w = String(chars[i..<(i + n)])
                        guard !names.contains(w), !known.contains(w), !w.contains(where: { stop.contains($0) }) else { continue }
                        var hit: [String] = []
                        var best = Int.max
                        for c in cands {
                            let t = targets[c]
                            var diff = 0
                            for (k, s) in t.syllables.enumerated() where ky[i + k]! != Pinyin.key(s) { diff += 1 }
                            if diff <= 1 { hit.append(t.name); best = min(best, t.rank) }
                        }
                        if !hit.isEmpty { found.append(Found(heard: w, names: hit, start: offset + i, len: n, rank: best)) }
                    }
                }
            }
            // 長的蓋住短的（「流星雨→劉芯妤」裡的「星雨→芯妤」）：短的不列
            let kept = found.filter { a in
                !found.contains { b in
                    b.len > a.len && b.start <= a.start && b.start + b.len >= a.start + a.len && a.names.contains { n in b.names.contains { $0.contains(n) } }
                }
            }
            for f in kept {
                if var h = agg[f.heard] {
                    h.count += 1
                    for n in f.names where !h.names.contains(n) { h.names.append(n) }
                    if !h.stamps.contains(stamp) { h.stamps.append(stamp) }
                    h.rank = min(h.rank, f.rank)
                    agg[f.heard] = h
                } else {
                    agg[f.heard] = Hit(heard: f.heard, names: f.names, count: 1, stamps: [stamp], rank: f.rank)
                    order.append(f.heard)
                }
            }
        }
        return order.enumerated().sorted { a, b in
            let x = agg[a.element]!, y = agg[b.element]!
            if x.rank != y.rank { return x.rank < y.rank }
            return x.count != y.count ? x.count > y.count : a.offset < b.offset
        }.map { agg[$0.element]! }
    }

    static func hanRunsWithOffsets(_ s: String) -> [(offset: Int, chars: [Character])] {
        var out: [(offset: Int, chars: [Character])] = []
        var cur: [Character] = []
        var start = 0
        for (i, ch) in s.enumerated() {
            if Pinyin.isHan(ch) {
                if cur.isEmpty { start = i }
                cur.append(ch)
            } else if !cur.isEmpty { out.append((start, cur)); cur = [] }
        }
        if !cur.isEmpty { out.append((start, cur)) }
        return out
    }

    /// 帶給 AI 的行（最多 listLimit 組）：「- 原字 → 名字？×次數 [mm:ss]…」（時間戳最多三個）
    public static func lines(_ hits: [Hit]) -> [String] {
        hits.prefix(listLimit).map { h in
            "- \(h.heard) → \(h.names.joined(separator: "／"))？" + (h.count > 1 ? "×\(h.count)" : "") + " "
                + h.stamps.prefix(3).map { "[\($0)]" }.joined(separator: " ")
        }
    }

    /// 原字唸起來像不像正名（AI 改成名冊名字的一段時用）：一樣長、都在表裡，一半以上的字差一點以內
    public static func close(_ heard: String, _ name: String) -> Bool {
        let a = Array(heard), b = Array(name)
        guard a.count == b.count, a.count >= 2 else { return false }
        var same = 0
        for (x, y) in zip(a, b) {
            guard let p = Pinyin.of(x), let q = Pinyin.of(y) else { return false }
            if Pinyin.coarse(p) == Pinyin.coarse(q) { same += 1 }
        }
        return same * 2 >= a.count
    }
}
