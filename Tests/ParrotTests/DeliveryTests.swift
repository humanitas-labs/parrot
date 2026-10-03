import AppKit
import ApplicationServices
import XCTest
@testable import ParrotCore

final class DeliveryTests: XCTestCase {
    private func element(_ pid: pid_t) -> FocusedElement {
        FocusedElement(AXUIElementCreateApplication(pid))
    }

    private func focus(pid: pid_t? = 100, element: FocusedElement? = nil, secure: Bool = false, selection: NSRange? = nil) -> FocusSnapshot {
        FocusSnapshot(pid: pid, element: element, isSecure: secure, selection: selection)
    }

    func testUnchangedFocusInjects() {
        let start = focus(element: element(1))
        XCTAssertEqual(DeliveryDecision.decide(start: start, now: focus(element: element(1))), .inject)
    }

    func testSecureFieldAtStartOrDeliveryDiscards() {
        XCTAssertEqual(DeliveryDecision.decide(start: focus(secure: true), now: focus()), .discardSecure)
        XCTAssertEqual(DeliveryDecision.decide(start: focus(), now: focus(secure: true)), .discardSecure)
        XCTAssertEqual(DeliveryDecision.decide(start: nil, now: focus(secure: true)), .discardSecure)
    }

    /// Secure wins over drift: a password field never gets the clipboard.
    func testSecureFieldAfterDriftStillDiscards() {
        XCTAssertEqual(DeliveryDecision.decide(start: focus(pid: 1), now: focus(pid: 2, secure: true)), .discardSecure)
    }

    func testAppSwitchCopiesToClipboard() {
        XCTAssertEqual(DeliveryDecision.decide(start: focus(pid: 1), now: focus(pid: 2)), .copyToClipboard)
        XCTAssertEqual(DeliveryDecision.decide(start: focus(pid: 1), now: focus(pid: nil)), .copyToClipboard)
    }

    func testElementChangeInSameAppCopiesToClipboard() {
        let start = focus(element: element(1))
        XCTAssertEqual(DeliveryDecision.decide(start: start, now: focus(element: element(2))), .copyToClipboard)
    }

    func testCursorMovedInSameFieldCopiesToClipboard() {
        let start = focus(element: element(1), selection: NSRange(location: 3, length: 0))
        let now = focus(element: element(1), selection: NSRange(location: 9, length: 0))
        XCTAssertEqual(DeliveryDecision.decide(start: start, now: now), .copyToClipboard)
    }

    func testSelectionChangedAtSameLocationCopiesToClipboard() {
        let start = focus(element: element(1), selection: NSRange(location: 3, length: 0))
        let now = focus(element: element(1), selection: NSRange(location: 3, length: 4))
        XCTAssertEqual(DeliveryDecision.decide(start: start, now: now), .copyToClipboard)
    }

    func testUnchangedSelectionInjects() {
        let start = focus(element: element(1), selection: NSRange(location: 3, length: 4))
        XCTAssertEqual(DeliveryDecision.decide(start: start, now: start), .inject)
    }

    func testUnknownSelectionPreservesExistingFallback() {
        let known = focus(element: element(1), selection: NSRange(location: 3, length: 0))
        let unknown = focus(element: element(1))
        XCTAssertEqual(DeliveryDecision.decide(start: known, now: unknown), .inject)
        XCTAssertEqual(DeliveryDecision.decide(start: unknown, now: known), .inject)
    }

    func testSecureFieldWinsOverSelectionChange() {
        let start = focus(element: element(1), selection: NSRange(location: 3, length: 0))
        let now = focus(element: element(1), secure: true, selection: NSRange(location: 9, length: 0))
        XCTAssertEqual(DeliveryDecision.decide(start: start, now: now), .discardSecure)
    }

    /// Electron builds its Accessibility tree lazily, so an element seen at
    /// only one end is not drift.
    func testElementSeenOnlyOnceIsNotDrift() {
        XCTAssertEqual(DeliveryDecision.decide(start: focus(), now: focus(element: element(1))), .inject)
        XCTAssertEqual(DeliveryDecision.decide(start: focus(element: element(1)), now: focus()), .inject)
    }

    func testNoStartSnapshotInjects() {
        XCTAssertEqual(DeliveryDecision.decide(start: nil, now: focus(pid: 7)), .inject)
    }

    func testUserMessagesNeverCarryText() {
        XCTAssertEqual(DeliveryError.secureField.userMessage, "password field, transcript discarded")
        XCTAssertEqual(DeliveryError.focusChanged.userMessage, "focus changed, transcript copied")
    }
}

final class SpacingTests: XCTestCase {
    private func spaced(_ text: String, after before: TextBeforeCursor = .unknown) -> String {
        Spacing.spaced(text, before: before)
    }

    func testTrailingSpaceAlways() {
        XCTAssertEqual(spaced("Hello world."), "Hello world. ")
        XCTAssertEqual(spaced("hello"), "hello ")
        XCTAssertEqual(spaced("Next", after: .start), "Next ")
    }

    func testNoTrailingSpaceAfterWhitespace() {
        XCTAssertEqual(spaced("Hello. "), "Hello. ")
        XCTAssertEqual(spaced("Hello\n"), "Hello\n")
    }

    /// A word typed by hand before the cursor.
    func testLeadingSpaceAfterAWordOrPunctuation() {
        XCTAssertEqual(spaced("world", after: .character("o")), " world ")
        XCTAssertEqual(spaced("apples", after: .character("3")), " apples ")
        XCTAssertEqual(spaced("Next", after: .character(".")), " Next ")
        XCTAssertEqual(spaced("next", after: .character(")")), " next ")
    }

    /// After a dictation the cursor follows its trailing space: no double space.
    func testNoLeadingSpaceAfterWhitespaceTheStartOrUnknown() {
        XCTAssertEqual(spaced("Next", after: .character(" ")), "Next ")
        XCTAssertEqual(spaced("Next", after: .character("\n")), "Next ")
        XCTAssertEqual(spaced("Next", after: .character("\t")), "Next ")
        XCTAssertEqual(spaced("Next", after: .start), "Next ")
        XCTAssertEqual(spaced("Next", after: .unknown), "Next ")
    }

    func testNoLeadingSpaceAfterAnOpener() {
        for opener: Character in ["(", "[", "\"", "“", "¿", "/", "@"] {
            XCTAssertEqual(spaced("next", after: .character(opener)), "next ", "after \(opener)")
        }
    }

    func testNoLeadingSpaceBeforePunctuationThatAttaches() {
        XCTAssertEqual(spaced(", and then", after: .character("o")), ", and then ")
        XCTAssertEqual(spaced("?", after: .character("o")), "? ")
        XCTAssertEqual(spaced(" already", after: .character("o")), " already ")
    }

    func testNoSpacesInChineseOrJapanese() {
        XCTAssertEqual(spaced("你好。", after: .character("。")), "你好。")
        XCTAssertEqual(spaced("こんにちは", after: .character("す")), "こんにちは")
        XCTAssertEqual(spaced("你好", after: .character("a")), "你好")
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(spaced("", after: .character("o")), "")
    }
}

final class PasteboardSessionTests: XCTestCase {
    private final class FakePasteboard: PasteboardAccess {
        var changeCount = 0
        var contents = PasteboardSnapshot(items: [])
        var writes: [(text: String, markers: [String])] = []

        func snapshot() -> PasteboardSnapshot { contents }

        func restore(_ snapshot: PasteboardSnapshot) {
            contents = snapshot
            changeCount += 1
        }

        func write(_ text: String, markers: [String]) {
            writes.append((text, markers))
            contents = PasteboardSnapshot(items: [
                [PasteboardRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))]
                    + markers.map { PasteboardRepresentation(type: $0, data: Data()) },
            ])
            changeCount += 1
        }

        /// Another app or the user copies something.
        func externalCopy(_ text: String) {
            contents = PasteboardSnapshot(items: [[PasteboardRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))]])
            changeCount += 1
        }
    }

    private var pasteboard: FakePasteboard!
    private var pending: [() -> Void] = []
    private var pastes = 0
    private var session: PasteboardSession!

    private let original = PasteboardSnapshot(items: [
        [
            PasteboardRepresentation(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47])),
            PasteboardRepresentation(type: "public.tiff", data: Data([0x4D, 0x4D])),
        ],
        [PasteboardRepresentation(type: "public.file-url", data: Data("file:///tmp/a".utf8))],
    ])

    override func setUp() {
        pasteboard = FakePasteboard()
        pasteboard.contents = original
        pending = []
        pastes = 0
        session = PasteboardSession(
            pasteboard: pasteboard,
            settleDelay: 0.25,
            postPaste: { [unowned self] in self.pastes += 1 },
            schedule: { [unowned self] _, work in self.pending.append(work) }
        )
    }

    private func runPending() {
        let work = pending
        pending = []
        work.forEach { $0() }
    }

    func testPasteWritesMarkedTextPostsOnceAndRestores() {
        session.paste("hello")
        XCTAssertEqual(pastes, 1)
        XCTAssertEqual(pasteboard.writes.first?.text, "hello")
        XCTAssertEqual(
            pasteboard.writes.first?.markers,
            ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType"]
        )
        XCTAssertTrue(session.isRestorePending)
        runPending()
        XCTAssertEqual(pasteboard.contents, original)
        XCTAssertFalse(session.isRestorePending)
    }

    func testSecondPasteInsideSettleWindowDoesNotResnapshot() {
        session.paste("one")
        session.paste("two")
        XCTAssertEqual(pastes, 2)
        runPending()
        XCTAssertEqual(pasteboard.contents, original)
    }

    func testOnlyTheLatestRestoreRuns() {
        session.paste("one")
        let first = pending.removeFirst()
        session.paste("two")
        first()
        // The first window's restore is stale; "two" may not be read yet.
        XCTAssertEqual(pasteboard.writes.last?.text, "two")
        XCTAssertNotEqual(pasteboard.contents, original)
        runPending()
        XCTAssertEqual(pasteboard.contents, original)
    }

    func testExternalCopyDuringWindowIsKept() {
        session.paste("one")
        pasteboard.externalCopy("user copied this")
        let theirs = pasteboard.contents
        runPending()
        XCTAssertEqual(pasteboard.contents, theirs)
        XCTAssertFalse(session.isRestorePending)
    }

    func testNextPasteAfterRestoreSnapshotsAgain() {
        session.paste("one")
        runPending()
        pasteboard.externalCopy("new clipboard")
        let newer = pasteboard.contents
        session.paste("two")
        runPending()
        XCTAssertEqual(pasteboard.contents, newer)
    }

    func testCopyStaysAndCancelsPendingRestore() {
        session.paste("one")
        session.copy("fallback")
        XCTAssertEqual(pasteboard.writes.last?.markers, ["org.nspasteboard.ConcealedType"])
        runPending()
        XCTAssertEqual(pasteboard.writes.last?.text, "fallback")
        XCTAssertNotEqual(pasteboard.contents, original)
        XCTAssertFalse(session.isRestorePending)
    }

    func testEmptyClipboardRestoresEmpty() {
        pasteboard.contents = PasteboardSnapshot(items: [])
        session.paste("one")
        runPending()
        XCTAssertEqual(pasteboard.contents, PasteboardSnapshot(items: []))
    }
}

/// Round trip through a real, privately named `NSPasteboard`; the user's
/// clipboard is not touched.
final class SystemPasteboardTests: XCTestCase {
    func testSnapshotRestoresEveryRepresentationOfEveryItem() {
        let named = NSPasteboard(name: NSPasteboard.Name("parrot-test-\(UUID().uuidString)"))
        defer { named.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("hello", forType: .string)
        first.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.custom"))
        let second = NSPasteboardItem()
        second.setString("file:///tmp/a", forType: .fileURL)
        named.clearContents()
        named.writeObjects([first, second])

        let pasteboard = SystemPasteboard(named)
        let saved = pasteboard.snapshot()
        XCTAssertEqual(saved.items.count, 2)

        pasteboard.write("transcript", markers: PasteboardSession.transientMarkers)
        XCTAssertEqual(named.string(forType: .string), "transcript")
        XCTAssertNotNil(named.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))

        pasteboard.restore(saved)
        XCTAssertEqual(pasteboard.snapshot(), saved)
        XCTAssertEqual(named.pasteboardItems?.first?.data(forType: NSPasteboard.PasteboardType("com.example.custom")), Data([1, 2, 3]))
        XCTAssertEqual(named.pasteboardItems?.last?.string(forType: .fileURL), "file:///tmp/a")
    }
}
