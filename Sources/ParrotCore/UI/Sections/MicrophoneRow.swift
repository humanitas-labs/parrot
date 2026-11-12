import SwiftUI

/// The microphone to record from (#44), a row in the General section:
/// "Same as System" or a connected device. A chosen device that is not
/// connected stays listed, so the choice is visible and can be changed.
struct MicrophoneRow: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var devices = InputDeviceList.shared

    private var chosenUID: String? { store.current.audio.inputDevice }

    var body: some View {
        PillRow("Microphone") {
            PillMenu(title: title) {
                Toggle(sameAsSystemLabel, isOn: Binding(
                    get: { chosenUID == nil },
                    set: { on in if on { store.update { $0.audio = AudioSettings() } } }
                ))
                Divider()
                ForEach(devices.inputs) { device in
                    Toggle(device.name, isOn: Binding(
                        get: { chosenUID == device.uid },
                        set: { on in
                            if on {
                                store.update { $0.audio = AudioSettings(inputDevice: device.uid, inputDeviceName: device.name) }
                            }
                        }
                    ))
                }
                if let missing = missingChoice {
                    Toggle("\(missing) (not connected)", isOn: .constant(true))
                        .disabled(true)
                }
            }
        }
        .onAppear { devices.refresh() }
    }

    private var sameAsSystemLabel: String {
        devices.defaultName.map { "Same as System (\($0))" } ?? "Same as System"
    }

    private var title: String {
        guard let uid = chosenUID else { return "Same as System" }
        if let device = devices.inputs.first(where: { $0.uid == uid }) { return device.name }
        return "\(store.current.audio.inputDeviceName ?? "Chosen microphone") (not connected)"
    }

    /// The chosen device's name when it is not connected now.
    private var missingChoice: String? {
        guard let uid = chosenUID, !devices.inputs.contains(where: { $0.uid == uid }) else { return nil }
        return store.current.audio.inputDeviceName ?? "Chosen microphone"
    }
}
