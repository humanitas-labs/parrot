import CoreAudio
import Foundation

/// The default input device as Core Audio reports it, read before any
/// capture path touches it.
///
/// With no input device, or one that reports 0 Hz or 0 channels,
/// `AVAudioEngine` raises an Objective-C exception on `installTap` or
/// `start()`, which Swift cannot catch. Checking here turns that into a
/// `CaptureError`.
package struct InputDevice: Equatable {
    package var sampleRate: Double
    package var channels: UInt32
    /// The Core Audio device, or `kAudioObjectUnknown` when not read from one.
    package var id: AudioDeviceID = kAudioObjectUnknown

    /// The input `selection` resolves to now: the chosen microphone if it is
    /// connected, else the system default. Throws `CaptureError.noInputDevice`
    /// if there is none, or `.invalidInputFormat` if it cannot be recorded.
    package static func current(_ selection: InputSelection = InputSelection()) throws -> InputDevice {
        guard let id = selection.resolve()?.id else { throw CaptureError.noInputDevice }
        return try read(id)
    }

    /// `id`'s format now. Throws `.invalidInputFormat` if it cannot be recorded.
    static func read(_ id: AudioDeviceID) throws -> InputDevice {
        let device = InputDevice(sampleRate: nominalSampleRate(id), channels: inputChannels(id), id: id)
        try validate(sampleRate: device.sampleRate, channels: device.channels)
        return device
    }

    /// The device with this Core Audio UID, if it is connected and has an
    /// input to record from.
    package static func id(forUID uid: String) -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id
            )
        }
        guard status == noErr, id != kAudioObjectUnknown, isAlive(id), inputChannels(id) > 0 else { return nil }
        return id
    }

    /// The device's Core Audio UID, stable across reconnects, or nil.
    package static func uid(of id: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, of: id)
    }

    /// A microphone the user can choose.
    package struct Listing: Equatable, Identifiable {
        package var uid: String
        package var name: String
        package var id: String { uid }
    }

    /// Every connected device with an input, by name. Leaves out hidden
    /// devices and Core Audio's private aggregates, which are not
    /// microphones a person would pick.
    package static func inputs() -> [Listing] {
        allDeviceIDs()
            .filter { inputChannels($0) > 0 && isAlive($0) && !isHidden($0) }
            .compactMap { id -> Listing? in
                guard let uid = uid(of: id), !isPrivateAggregate(uid: uid) else { return nil }
                return Listing(uid: uid, name: name(of: id) ?? uid)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Core Audio's own aggregates, made for apps such as FaceTime.
    static func isPrivateAggregate(uid: String) -> Bool {
        uid.hasPrefix("CADefaultDeviceAggregate")
    }

    /// The device's name as the Sound settings show it, or nil.
    package static func name(of id: AudioDeviceID) -> String? {
        stringProperty(kAudioObjectPropertyName, of: id)
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue()
        else { return nil }
        return string as String
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    static func isAlive(_ id: AudioDeviceID) -> Bool {
        uint32Property(kAudioDevicePropertyDeviceIsAlive, of: id) != 0
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        uint32Property(kAudioDevicePropertyIsHidden, of: id) != 0
    }

    private static func uint32Property(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    /// Throws `CaptureError.invalidInputFormat` unless both are positive.
    static func validate(sampleRate: Double, channels: UInt32) throws {
        guard sampleRate > 0, sampleRate.isFinite, channels > 0 else {
            throw CaptureError.invalidInputFormat(sampleRate: sampleRate, channels: channels)
        }
    }

    static func defaultInputID() -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    static func inputChannels(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
    }
}
