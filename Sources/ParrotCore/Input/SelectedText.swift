import ApplicationServices
import Foundation

extension FocusSnapshot {
    /// The text selected in the focused element, for Fix Word… (#54). Read
    /// only when the user chooses Fix Word. Nil in a secure field, when
    /// nothing is selected, when the app doesn't say, or when the selection
    /// is longer than a few words.
    @MainActor
    static func selectedWords() -> String? {
        let focus = capture()
        guard !focus.isSecure, let element = focus.element?.ref else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              FixWord.fits(text) else { return nil }
        return text
    }
}
