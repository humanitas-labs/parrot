import Combine
import CoreAudio
import Foundation

/// The microphones connected now and the system's default input, kept
/// current as devices come and go or the default changes, for the Settings
/// picker and the menu bar (#44).
@MainActor
final class InputDeviceList: ObservableObject {
    static let shared = InputDeviceList()

    @Published private(set) var inputs: [InputDevice.Listing] = []
    /// The system default input's name, for "Same as System".
    @Published private(set) var defaultName: String?

    private var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private init() {
        refresh()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
                registrations.append((address, block))
            }
        }
    }

    func refresh() {
        let inputs = InputDevice.inputs()
        let defaultName = InputDevice.defaultInputID().flatMap(InputDevice.name(of:))
        if inputs != self.inputs { self.inputs = inputs }
        if defaultName != self.defaultName { self.defaultName = defaultName }
    }
}
