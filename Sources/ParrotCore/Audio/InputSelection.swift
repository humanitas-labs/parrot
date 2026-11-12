import CoreAudio
import Foundation

/// Which microphone a recording uses (#44): the one chosen in Settings, by
/// its Core Audio UID, or the system default when none is chosen or the
/// chosen one is not connected.
///
/// Shared by `AudioCapture` and the input it runs, and resolved afresh at
/// every press and device notification, so a change of choice, or the
/// chosen device coming or going, applies without a restart. Safe to read
/// and write from any thread.
package final class InputSelection: @unchecked Sendable {
    /// The device a recording will use now.
    package struct Resolution: Equatable {
        package var id: AudioDeviceID
        /// A device was chosen but is not connected, so this is the system
        /// default instead.
        package var fellBack: Bool
    }

    private let lock = NSLock()
    private var chosen: String?

    /// `uid` is the chosen device, or nil for the system default.
    package init(uid: String? = nil) {
        self.chosen = uid
    }

    /// The chosen device's UID, or nil for "Same as System".
    package var uid: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return chosen
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            chosen = newValue
        }
    }

    /// The device to record from now, or nil if there is no input at all.
    package func resolve() -> Resolution? {
        Self.resolve(uid: uid, lookup: InputDevice.id(forUID:), defaultInput: InputDevice.defaultInputID())
    }

    /// The rule, without Core Audio: the chosen device if `lookup` finds it
    /// connected, else the default input, marked as a fallback when a device
    /// was chosen.
    static func resolve(
        uid: String?,
        lookup: (String) -> AudioDeviceID?,
        defaultInput: @autoclosure () -> AudioDeviceID?
    ) -> Resolution? {
        if let uid, let id = lookup(uid) {
            return Resolution(id: id, fellBack: false)
        }
        guard let fallback = defaultInput() else { return nil }
        return Resolution(id: fallback, fellBack: uid != nil)
    }
}
