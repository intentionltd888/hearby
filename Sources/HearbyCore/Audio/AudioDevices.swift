// AudioDevices — 預設輸入／輸出裝置：代號（錄音器綁 IO 單元、跑輸出保活）與名字（診斷用：hearby.log 記「錄到的是哪支麥」——遠端排錯第一題）
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
