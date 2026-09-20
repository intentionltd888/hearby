// Srt — 字幕（匯入檔用）：過長段落依標點拆行、時間按字數比例分
import Foundation

public enum Srt {
    public static func build(_ segs: [Segment]) -> String {
        func t(_ ms: Int) -> String { String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000) }
        var rows: [(Int, Int, String)] = []
        for s in segs {
            let end = max(s.toMs, s.fromMs + 500)
            let dur = end - s.fromMs
            let chars = s.text.count
            guard dur > 12000 || chars > 60, chars > 12 else { rows.append((s.fromMs, end, s.text)); continue }
            let want = max(2, min(6, Int(ceil(Double(max(dur / 8000, chars / 40))))))
            let target = chars / want
            var piece = ""
            var pieces: [String] = []
            for ch in s.text {
                piece.append(ch)
                if piece.count >= target, "，。？！、,.?!；;".contains(ch) { pieces.append(piece); piece = "" }
            }
            if !piece.isEmpty { if pieces.isEmpty { pieces.append(piece) } else { pieces[pieces.count - 1] += piece } }
            var cursor = s.fromMs
            for (k, p) in pieces.enumerated() {
                let share = Double(p.count) / Double(max(1, chars))
                let stop = k == pieces.count - 1 ? end : min(end, cursor + Int(Double(dur) * share))
                rows.append((cursor, max(stop, cursor + 400), p))
                cursor = stop
            }
        }
        return rows.enumerated().map { i, r in "\(i + 1)\n\(t(r.0)) --> \(t(r.1))\n\(r.2)" }.joined(separator: "\n\n") + "\n"
    }
}
