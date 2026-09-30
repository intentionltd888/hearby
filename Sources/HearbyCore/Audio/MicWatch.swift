// MicWatch — 麥克風健康：沒暫停卻連續兩分鐘幾乎沒聲音＝多半選錯麥克風或被靜音了（有聲音就收回提醒）。
// 純邏輯、時間由外面給；門檻跟「這一軌算不算有聲音」同一個（Pipeline.silence）。
// 一般房間的底噪（冷氣、風扇）就在門檻之上，所以只有真的收不到聲音（靜音、錯的裝置）才會響。
import Foundation

public struct MicWatch {
    public static let silentSeconds: TimeInterval = 120
    public enum Event: Equatable { case silent, recovered }

    public private(set) var lastHeard: Date
    public private(set) var alerting = false

    public init(now: Date) { lastHeard = now }

    /// 暫停後繼續、剛開錄：從現在重新算
    public mutating func reset(now: Date) { lastHeard = now }

    /// 每一格音量進來一次；回 .silent＝該提醒了、.recovered＝可以收掉提醒
    public mutating func update(level: Float, now: Date) -> Event? {
        if level >= Pipeline.silence {
            lastHeard = now
            if alerting { alerting = false; return .recovered }
            return nil
        }
        if !alerting, now.timeIntervalSince(lastHeard) >= Self.silentSeconds {
            alerting = true
            return .silent
        }
        return nil
    }
}
