// AudioDevices — 預設輸入／輸出裝置：代號與 UID（麥克風佇列綁裝置、跑輸出保活）與名字（診斷用：hearby.log 記「錄到的是哪支麥」——遠端排錯第一題）
import CoreAudio
import Foundation

public enum AudioDevices {
    public static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    public static func defaultInputID() -> AudioDeviceID? { systemDevice(kAudioHardwarePropertyDefaultInputDevice) }
    public static func defaultOutputID() -> AudioDeviceID? { systemDevice(kAudioHardwarePropertyDefaultOutputDevice) }
    public static func defaultInputName() -> String? { defaultInputID().flatMap(name) }

    public static func name(_ deviceID: AudioDeviceID) -> String? {
        var nAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var nSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &nAddr, 0, nil, &nSize, &name) == noErr
        else { return nil }
        return name as String
    }

    /// 裝置的 UID（AudioQueue 綁裝置用 UID，不用代號）
    public static func uid(_ deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?  // 拿到的是 +1 的 CFString，要自己放掉
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uid) == noErr, let uid
        else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
                == noErr, deviceID != 0
        else { return nil }
        return deviceID
    }
}
