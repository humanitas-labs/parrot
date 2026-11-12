import CoreAudio
import XCTest
@testable import ParrotCore

/// Choosing the microphone (#44) and noticing a dead one (#56), without
/// hardware.
final class InputSelectionTests: XCTestCase {
    private let connected: [String: AudioDeviceID] = ["usb-mic": 7, "webcam": 9]
    private func lookup(_ uid: String) -> AudioDeviceID? { connected[uid] }

    // MARK: Resolving the selection

    func testSameAsSystemRecordsFromTheDefaultInput() {
        XCTAssertEqual(
            InputSelection.resolve(uid: nil, lookup: lookup, defaultInput: 82),
            InputSelection.Resolution(id: 82, fellBack: false)
        )
    }

    func testAConnectedChoiceWinsOverTheDefault() {
        // The clamshell case: the default stays on the built-in mic (82),
        // the chosen USB mic is recorded instead.
        XCTAssertEqual(
            InputSelection.resolve(uid: "usb-mic", lookup: lookup, defaultInput: 82),
            InputSelection.Resolution(id: 7, fellBack: false)
        )
    }

    func testAMissingChoiceFallsBackToTheDefaultAndSaysSo() {
        XCTAssertEqual(
            InputSelection.resolve(uid: "airpods", lookup: lookup, defaultInput: 82),
            InputSelection.Resolution(id: 82, fellBack: true)
        )
    }

    func testNoInputAtAllResolvesToNothing() {
        XCTAssertNil(InputSelection.resolve(uid: nil, lookup: lookup, defaultInput: nil))
        XCTAssertNil(InputSelection.resolve(uid: "airpods", lookup: lookup, defaultInput: nil))
    }

    func testTheChoiceCanChangeWhileShared() {
        let selection = InputSelection()
        XCTAssertNil(selection.uid)
        selection.uid = "usb-mic"
        XCTAssertEqual(selection.uid, "usb-mic")
    }

    func testAnUnknownUIDIsNotFound() {
        XCTAssertNil(InputDevice.id(forUID: "no-such-device-\(UUID().uuidString)"))
    }

    func testPrivateAggregatesAreNotListed() {
        XCTAssertTrue(InputDevice.isPrivateAggregate(uid: "CADefaultDeviceAggregate-1234-0"))
        XCTAssertFalse(InputDevice.isPrivateAggregate(uid: "BuiltInMicrophoneDevice"))
    }

    // MARK: A silent microphone

    private func stats(sound: TimeInterval?) -> CaptureBuffer.Stats {
        var stats = CaptureBuffer.Stats()
        stats.firstSoundDelay = sound
        return stats
    }

    func testARecordingOfOnlyZerosIsReported() {
        guard case .silentInput(let device)? = AudioCapture.silenceError(
            stats: stats(sound: nil), held: 2, device: "MacBook Pro Microphone"
        ) else { return XCTFail("expected silentInput") }
        XCTAssertEqual(device, "MacBook Pro Microphone")
    }

    func testAnyNonZeroSampleIsNotSilence() {
        XCTAssertNil(AudioCapture.silenceError(stats: stats(sound: 0.05), held: 2, device: nil))
    }

    func testAShortRecordingIsNotJudged() {
        // A Bluetooth mic can send zeros while it settles.
        XCTAssertNil(AudioCapture.silenceError(stats: stats(sound: nil), held: 0.4, device: nil))
    }

    func testTheSilenceMessageNamesTheDeviceAndTheFix() {
        XCTAssertEqual(
            CaptureError.silentInput(device: "MacBook Pro Microphone").userMessage,
            "MacBook Pro Microphone heard nothing: choose a microphone in Parrot Settings"
        )
        XCTAssertTrue(CaptureError.silentInput(device: nil).userMessage.hasPrefix("microphone heard nothing"))
    }

    // MARK: Settings and the menu bar

    func testTheChoiceDecodesAndDefaultsToSameAsSystem() throws {
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).audio, AudioSettings())
        let settings = try JSONDecoder().decode(
            Settings.self,
            from: Data(#"{"audio": {"inputDevice": "usb-mic", "inputDeviceName": "USB Mic"}}"#.utf8)
        )
        XCTAssertEqual(settings.audio.inputDevice, "usb-mic")
        XCTAssertEqual(settings.audio.inputDeviceName, "USB Mic")
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), settings)
    }

    @MainActor
    func testTheMenuBarNamesTheMicrophoneAndAMissingChoice() {
        XCTAssertEqual(MenuBarController.inputTitle("Logitech StreamCam", missing: nil), "microphone: Logitech StreamCam")
        XCTAssertEqual(
            MenuBarController.inputTitle("MacBook Pro Microphone", missing: "USB Mic"),
            "microphone: MacBook Pro Microphone · USB Mic not connected"
        )
        XCTAssertEqual(MenuBarController.inputTitle(nil, missing: nil), "microphone: none")
    }
}
