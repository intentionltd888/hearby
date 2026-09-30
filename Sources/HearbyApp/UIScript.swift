// UIScript — 測試鉤：環境變數 HEARBY_UI_SCRIPT 給一串步驟，照順序對圖形介面的狀態機下指令（跟面板按鈕走同一條路）
//   例：HEARBY_UI_SCRIPT="start 3 hide 3 pause 4 resume 3 stop"＋HEARBY_AUTOQUIT=1＋沙箱兩個資料夾（HEARBY_OUTPUT_ROOT／HEARBY_SUPPORT_DIR）
//       → 開錄、收起面板（浮動小條出現）、暫停、繼續、停止、整理完自己結束。每一步寫進 hearby.log（uiscript: …）。
//   步驟：start／pause／resume／stop／hide（收起面板）／show（打開面板）；數字＝等幾秒。
import AppKit
import HearbyCore

@MainActor
enum UIScript {
    static func run(_ script: String, statusBar: StatusBar) {
        let steps = script.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        HearbyLog.write("uiscript: \(steps.joined(separator: " "))")
        next(steps[...], statusBar: statusBar)
    }

    private static func next(_ rest: ArraySlice<String>, statusBar: StatusBar) {
        guard let step = rest.first else { HearbyLog.write("uiscript: done"); return }
        let more = rest.dropFirst()
        if let secs = Double(step) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { next(more, statusBar: statusBar) }
            return
        }
        let s = AppState.shared
        HearbyLog.write("uiscript: \(step) phase=\(s.phase.rawValue) paused=\(s.panel.paused) elapsed=\(s.panel.elapsedText)")
        switch step {
        case "start": s.panel.onStart()
        case "pause": s.panel.onPause()
        case "resume": s.panel.onResume()
        case "stop": s.panel.onStop()
        case "hide": statusBar.hidePanel()
        case "show": statusBar.showPanel()
        default: HearbyLog.write("uiscript: 不認得的步驟 \(step)")
        }
        DispatchQueue.main.async { next(more, statusBar: statusBar) }
    }
}
