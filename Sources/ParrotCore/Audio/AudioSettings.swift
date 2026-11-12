/// Input device preferences (#44).
///
/// The `settings.json` field for this feature; see `Settings`. Give each new
/// field a default and decode it in `init(from:)` with
/// `decodeIfPresent(…) ?? default`, so older files and `{}` still load.
struct AudioSettings: Codable, Equatable {
    /// The Core Audio UID of the microphone to record from, or nil for the
    /// system's default input ("Same as System"). A UID, not an
    /// `AudioDeviceID`, which changes each time a device reconnects.
    var inputDevice: String?
    /// The chosen device's name when it was chosen, so Settings can name it
    /// while it is not connected. Display only.
    var inputDeviceName: String?

    init(inputDevice: String? = nil, inputDeviceName: String? = nil) {
        self.inputDevice = inputDevice
        self.inputDeviceName = inputDeviceName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputDevice = try c.decodeIfPresent(String.self, forKey: .inputDevice)
        inputDeviceName = try c.decodeIfPresent(String.self, forKey: .inputDeviceName)
    }
}
