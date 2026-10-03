import AppKit
import ApplicationServices
import Foundation

/// What had keyboard focus at one moment: the frontmost app, its focused
/// element, and whether that element is a secure (password) field.
///
/// Taken at recording start and again right before delivery, over
/// Accessibility, so delivery needs no watch on keystrokes or clicks.
struct FocusSnapshot {
    /// The frontmost app, if any.
    var pid: pid_t?
    /// The focused element, if the app exposes one over Accessibility.
    var element: FocusedElement?
    /// The focused element is a secure text field or reports protected content.
    var isSecure: Bool
    /// Insertion point or selection, in UTF-16 units, when the field exposes it.
    /// Metadata only: taking a snapshot does not read the field's text.
    var selection: NSRange? = nil

    /// Upper bound on each Accessibility call, so a hung app cannot stall
    /// the main thread (and with it the hotkey tap).
    private static let messagingTimeout: Float = 0.25

    @MainActor
    static func capture() -> FocusSnapshot {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let systemWide = AXUIElementCreateSystemWide()
        // On the system-wide element, this sets the timeout for every element.
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return FocusSnapshot(pid: pid, element: nil, isSecure: false)
        }
        let element = value as! AXUIElement
        let secure = isSecure(element)
        let focused = FocusedElement(element)
        return FocusSnapshot(
            pid: pid, element: focused, isSecure: secure,
            selection: secure ? nil : focused.selectedRange
        )
    }

    /// Whether focus moved from `self` to `now`. The app must match. The
    /// element must match when both snapshots saw one; an element seen only
    /// once is not a change, because Chromium and Electron apps build their
    /// Accessibility tree lazily and may expose nothing at recording start.
    func hasChanged(to now: FocusSnapshot) -> Bool {
        if pid != now.pid { return true }
        if let element, let other = now.element {
            if element != other { return true }
            // Moving the cursor or selecting other text within the same field
            // changes the destination too. Unknown ranges keep the existing
            // fallback for apps that do not expose selection metadata.
            if let selection, let otherSelection = now.selection,
               selection != otherSelection { return true }
        }
        return false
    }

    /// Secure only when the element says so. An element that cannot be read
    /// is not treated as secure, or every app without Accessibility support
    /// would lose its dictation.
    private static func isSecure(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let subrole = subrole as? String,
           subrole == kAXSecureTextFieldSubrole as String {
            return true
        }
        var protected: CFTypeRef?
        let attribute = NSAccessibility.Attribute.containsProtectedContent.rawValue as CFString
        if AXUIElementCopyAttributeValue(element, attribute, &protected) == .success,
           let protected = protected as? Bool {
            return protected
        }
        return false
    }
}

/// An Accessibility element compared by identity (`CFEqual`).
struct FocusedElement: Equatable {
    let ref: AXUIElement

    init(_ ref: AXUIElement) {
        self.ref = ref
    }

    static func == (lhs: FocusedElement, rhs: FocusedElement) -> Bool {
        CFEqual(lhs.ref, rhs.ref)
    }

    /// Selection metadata only; do not call on a secure field.
    var selectedRange: NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0, range.location < Int.max, range.length >= 0,
              range.length <= Int.max - range.location else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// The character before the insertion point, for `Spacing`. Reads the
    /// selected range, then the text just before it. Ranges count UTF-16
    /// units, so two are read and the last character kept: one alone could
    /// be half an emoji. Falls back to the whole value for apps without
    /// `AXStringForRange`. Call after `FocusSnapshot.capture()`, which sets
    /// the timeout, and never on a secure field.
    func textBeforeCursor() -> TextBeforeCursor {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return .unknown }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0 else { return .unknown }
        // Terminals such as Ghostty report position 0 wherever the cursor
        // is, so 0 is the start only in a field that is empty.
        if range.location == 0 { return characterCount() == 0 ? .start : .unknown }

        let length = min(range.location, 2)
        var before = CFRange(location: range.location - length, length: length)
        var text: CFTypeRef?
        if let query = AXValueCreate(.cfRange, &before),
           AXUIElementCopyParameterizedAttributeValue(ref, kAXStringForRangeParameterizedAttribute as CFString, query, &text) == .success,
           let character = (text as? String)?.last {
            return .character(character)
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, kAXValueAttribute as CFString, &value) == .success,
              let value = value as? String else { return .unknown }
        let units = value.utf16
        guard range.location <= units.count else { return .unknown }
        let end = units.index(units.startIndex, offsetBy: range.location)
        let start = units.index(end, offsetBy: -length)
        return String(units[start..<end]).flatMap { $0.last }.map(TextBeforeCursor.character) ?? .unknown
    }

    /// The field's length in UTF-16 units, from `AXNumberOfCharacters` or
    /// else the value; nil when the app says neither.
    private func characterCount() -> Int? {
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(ref, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let count = count as? Int {
            return count
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(ref, kAXValueAttribute as CFString, &value) == .success,
           let value = value as? String {
            return value.utf16.count
        }
        return nil
    }
}
