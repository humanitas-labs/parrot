import AVFoundation
import CoreAudio
import XCTest
@testable import ParrotCore

final class HALInputTests: XCTestCase {
    private let mic = InputDevice(sampleRate: 48_000, channels: 1, id: 42)

    // MARK: Formats

    func testClientFormatRefusesFormatsThatCannotBeRecorded() {
        for (rate, channels) in [(0.0, UInt32(1)), (48_000, 0), (0, 0), (.nan, 1), (.infinity, 2), (-44_100, 1)] {
            XCTAssertNil(HALInput.clientFormat(sampleRate: rate, channels: channels), "\(rate) Hz × \(channels)")
        }
    }

    func testClientFormatIsFloatAtTheDeviceRateWithAtMostTwoChannels() throws {
        let mono = try XCTUnwrap(HALInput.clientFormat(sampleRate: 44_100, channels: 1))
        XCTAssertEqual(mono.sampleRate, 44_100)
        XCTAssertEqual(mono.channelCount, 1)
        XCTAssertEqual(mono.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(mono.isInterleaved)

        XCTAssertEqual(HALInput.clientFormat(sampleRate: 24_000, channels: 2)?.channelCount, 2)
        XCTAssertEqual(HALInput.clientFormat(sampleRate: 96_000, channels: 8)?.channelCount, 2)
    }

    func testEveryClientFormatConvertsToSixteenKilohertzMono() throws {
        let cache = ConverterCache(targetFormat: AudioCapture.targetFormat)
        for (rate, channels) in [(8_000.0, UInt32(1)), (16_000, 1), (24_000, 1), (44_100, 1), (48_000, 2), (96_000, 4)] {
            let format = try XCTUnwrap(HALInput.clientFormat(sampleRate: rate, channels: channels))
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
            pcm.frameLength = 512
            var out = 0
            XCTAssertTrue(cache.convert(pcm) { out += $0.count }, "\(rate) Hz × \(channels)")
        }
    }

    // MARK: Changes to the input

    private func classify(selected: AudioDeviceID?, isAlive: Bool = true, _ device: InputDevice) -> HALInput.Change {
        HALInput.classify(built: mic, current: DeviceWatcher.Snapshot(selected: selected, isAlive: isAlive, device: device))
    }

    func testANotificationThatChangesNothingKeepsTheRecording() {
        XCTAssertEqual(classify(selected: 42, mic), .none)
    }

    func testAnotherDeviceOrAMissingOneIsARouteChange() {
        XCTAssertEqual(classify(selected: 43, mic), .route)
        XCTAssertEqual(classify(selected: nil, mic), .route)
        XCTAssertEqual(classify(selected: 42, isAlive: false, mic), .route)
    }

    func testANewRateOrChannelCountOnTheSameDeviceIsFollowed() {
        var changed = mic
        changed.sampleRate = 44_100
        XCTAssertEqual(classify(selected: 42, changed), .format(changed))
        changed = mic
        changed.channels = 2
        XCTAssertEqual(classify(selected: 42, changed), .format(changed))
    }

    func testAnUnrecordableNewFormatIsARouteChange() {
        for (rate, channels) in [(0.0, UInt32(1)), (48_000, 0), (.nan, 1)] {
            let changed = InputDevice(sampleRate: rate, channels: channels, id: 42)
            XCTAssertEqual(classify(selected: 42, changed), .route, "\(rate) Hz × \(channels)")
        }
    }

    func testAPreparedUnitIsReusedOnlyForTheSameInput() {
        XCTAssertTrue(HALInput.sameInput(mic, mic))
        XCTAssertFalse(HALInput.sameInput(mic, InputDevice(sampleRate: 48_000, channels: 1, id: 7)))
        XCTAssertFalse(HALInput.sameInput(mic, InputDevice(sampleRate: 44_100, channels: 1, id: 42)))
        XCTAssertFalse(HALInput.sameInput(mic, InputDevice(sampleRate: 48_000, channels: 2, id: 42)))
    }

    // MARK: Failure without hardware

    func testStartingOnADeviceThatDoesNotExistThrowsInsteadOfCrashing() {
        let sink = InputSink(deliver: { _, _, _ in XCTFail("no audio expected") }, routeChanged: {}, inputFailed: {})
        for keepsPrepared in [false, true] {
            let input = HALInput(keepsPrepared: keepsPrepared)
            let missing = InputDevice(sampleRate: 48_000, channels: 1, id: 0xDEAD)
            XCTAssertThrowsError(try input.start(device: missing, sink: sink)) { error in
                guard error is CaptureError else { return XCTFail("expected a CaptureError, got \(error)") }
            }
            input.stop()
        }
    }

    func testTheHALModesRecordFromTheSelectionAndTheEngineDoesNot() {
        let selection = InputSelection(uid: "usb-mic")
        XCTAssertTrue((CaptureMode.hal.makeInput(selection: selection) as? HALInput)?.selection === selection)
        XCTAssertTrue((CaptureMode.prepared.makeInput(selection: selection) as? HALInput)?.selection === selection)
        XCTAssertTrue(CaptureMode.hal.followsSelection)
        XCTAssertTrue(CaptureMode.prepared.followsSelection)
        XCTAssertFalse(CaptureMode.engine.followsSelection)
    }

    func testOnlyThePreparedModeKeepsTheUnitBetweenPresses() {
        XCTAssertTrue(CaptureMode.engine.makeInput() is EngineInput)
        XCTAssertEqual((CaptureMode.hal.makeInput() as? HALInput)?.keepsPrepared, false)
        XCTAssertEqual((CaptureMode.prepared.makeInput() as? HALInput)?.keepsPrepared, true)
        XCTAssertEqual(CaptureMode(rawValue: "prepared"), .prepared)
        XCTAssertEqual(CaptureMode.standard, .hal)
    }

    func testStopWithoutStartIsSafe() {
        HALInput(keepsPrepared: false).stop()
        HALInput(keepsPrepared: true).stop()
    }
}
