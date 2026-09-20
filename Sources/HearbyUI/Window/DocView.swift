// DocView — 單場頁的「紀錄」畫面：不給人看 markdown 原始碼，照文件區塊（DocBuilder，跟 PDF／Word 同一份）排版
//   標題／表頭欄位／摘要卡／小標／條列／問答／引言／待辦（勾選框）；翻譯版依語言換欄位名。
import HearbyCore
import SwiftUI

public struct DocView: View {
    let model: DocModel
    let warnings: [String]

    public init(md: String, language: String) {
        model = DocBuilder.build(md: md, header: DocHeader.prefill(md: md, language: language))
        // 表頭裡的 ⚠ 提醒（系統聲全程無聲之類）另外列
        warnings = md.components(separatedBy: "\n").prefix(while: { !$0.hasPrefix("## ") })
            .filter { $0.hasPrefix("> ") && ($0.contains("⚠") || $0.contains("⚠️")) }
            .map { $0.dropFirst(2).replacingOccurrences(of: "⚠️", with: "").replacingOccurrences(of: "⚠", with: "").trimmingCharacters(in: .whitespaces) }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NeuSpace.lg) {
                ForEach(Array(model.blocks.enumerated()), id: \.offset) { _, b in block(b) }
                if !warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(warnings, id: \.self) { w in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.circle").font(.system(size: 11, weight: .medium)).foregroundColor(Neu.inkMid).padding(.top, 2)
                                Text(w).font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, NeuSpace.sm)
                }
            }
            .padding(NeuSpace.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .textSelection(.enabled)
        }
        .neuDebossed(NeuRadius.card, depth: 0.9)
    }

    @ViewBuilder private func block(_ b: DocBlock) -> some View {
        switch b {
        case .title(let t):
            VStack(alignment: .leading, spacing: 4) {
                Text(model.doctype).font(NeuFont.ui(NeuType.micro, true)).foregroundColor(Neu.inkSoft).tracking(1)
                Text(t.isEmpty ? model.doctype : t).font(NeuFont.ui(24, true)).foregroundColor(Neu.inkStrong).fixedSize(horizontal: false, vertical: true)
            }
        case .meta(let rows):
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        HStack(alignment: .top, spacing: NeuSpace.md) {
                            Text(r.0).font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkSoft).frame(width: 72, alignment: .leading)
                            Text(r.1).font(NeuFont.ui(NeuType.caption)).foregroundColor(Neu.inkMid).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        case .summary(let label, let lines):
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(NeuFont.ui(NeuType.micro, true)).foregroundColor(Neu.inkSoft).tracking(1)
                ForEach(lines, id: \.self) { l in
                    Text(l).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                }
            }
            .padding(NeuSpace.lg).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NeuRadius.card, style: .continuous).fill(Neu.stage))
        case .heading(let h):
            Text(h).font(NeuFont.ui(NeuType.title, true)).foregroundColor(Neu.inkStrong).padding(.top, NeuSpace.sm)
        case .subheading(let h):
            Text(h).font(NeuFont.ui(NeuType.body, true)).foregroundColor(Neu.inkStrong).padding(.top, 2)
        case .paragraph(let p):
            rich(p).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, l in
                    HStack(alignment: .top, spacing: NeuSpace.sm) {
                        Circle().fill(Neu.inkMid).frame(width: 5, height: 5).padding(.top, 7)
                        rich(l).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, l in
                    HStack(alignment: .top, spacing: NeuSpace.sm) {
                        Text("\(i + 1).").font(NeuFont.mark(NeuType.body)).foregroundColor(Neu.inkMid).frame(width: 22, alignment: .trailing)
                        rich(l).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                    }
                }
            }
        case .qa(let q, let answers):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: NeuSpace.sm) {
                    Text("Q").font(NeuFont.mark(NeuType.body)).foregroundColor(Neu.inkMid).frame(width: 22, alignment: .trailing)
                    Text(q).font(NeuFont.ui(NeuType.body, true)).foregroundColor(Neu.inkStrong).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(answers.enumerated()), id: \.offset) { _, a in
                    HStack(alignment: .top, spacing: NeuSpace.sm) {
                        Text("A").font(NeuFont.mark(NeuType.body)).foregroundColor(Neu.inkSoft).frame(width: 22, alignment: .trailing)
                        rich(a).font(NeuFont.ui(NeuType.body)).foregroundColor(Neu.inkStrong).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                    }
                }
            }
        case .quote(let q):
            HStack(alignment: .top, spacing: NeuSpace.md) {
                RoundedRectangle(cornerRadius: 2).fill(Neu.inkSoft).frame(width: 3)
                rich(q).font(NeuFont.ui(NeuType.body)).italic().foregroundColor(Neu.inkMid).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4)
        case .todos(let todos):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(todos.enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .top, spacing: NeuSpace.sm) {
                        Image(systemName: t.done ? "checkmark.square.fill" : "square").font(.system(size: 14, weight: .regular)).foregroundColor(t.done ? Neu.inkMid : Neu.inkSoft).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.item).font(NeuFont.ui(NeuType.body)).foregroundColor(t.done ? Neu.inkMid : Neu.inkStrong).strikethrough(t.done, color: Neu.inkSoft).fixedSize(horizontal: false, vertical: true)
                            let tail = [t.owner, t.due].filter { !$0.isEmpty }.joined(separator: "　·　")
                            if !tail.isEmpty { Text(tail).font(NeuFont.ui(NeuType.micro)).foregroundColor(Neu.inkSoft) }
                        }
                    }
                }
            }
        }
    }

    /// 行內的 **粗體** 與 [mm:ss] 時間戳：粗體照排、時間戳變淡
    private func rich(_ s: String) -> Text {
        var out = Text("")
        var rest = Substring(s)
        while !rest.isEmpty {
            if let r = rest.range(of: #"\*\*[^*]+\*\*|\[(?:\d{1,2}:)?\d{1,3}:[0-5]\d\]"#, options: .regularExpression) {
                if r.lowerBound > rest.startIndex { out = out + Text(String(rest[rest.startIndex..<r.lowerBound])) }
                let tok = String(rest[r])
                if tok.hasPrefix("**") { out = out + Text(tok.dropFirst(2).dropLast(2)).fontWeight(.semibold) }
                else { out = out + Text(" " + tok).font(NeuFont.mark(NeuType.micro, false)).foregroundColor(Neu.inkSoft) }
                rest = rest[r.upperBound...]
            } else {
                out = out + Text(String(rest)); break
            }
        }
        return out
    }
}
