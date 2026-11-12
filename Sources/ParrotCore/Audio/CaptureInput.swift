import AVFoundation
import Foundation

/// How `AudioCapture` gets samples from the microphone (#52). Every mode
/// runs the input only while the hotkey is held.
public enum CaptureMode: String, CaseIterable, Sendable {
    /// A fresh `AVAudioEngine` per press, released on release (#39). The
    /// default before #52; kept selectable for one release.
    case engine
    /// A Core Audio AUHAL input unit, built per press and disposed on release.
    case hal
    /// The AUHAL unit built and initialized ahead of the press, and kept so
    /// between presses, but started only by a press and stopped on release:
    /// the device does not run between presses.
    case prepared

    /// The mode a run uses unless told otherwise.
    public static let standard: CaptureMode = .hal

    /// The input that implements this mode, recording from `selection`.
    /// The engine mode records from the system default whatever is chosen.
    func makeInput(selection: InputSelection = InputSelection()) -> CaptureInput {
        switch self {
        case .engine: return EngineInput()
        case .hal: return HALInput(keepsPrepared: false, selection: selection)
        case .prepared: return HALInput(keepsPrepared: true, selection: selection)
        }
    }

    /// Whether this mode records from the microphone chosen in Settings.
    /// `AVAudioEngine`'s input node follows the system default only (#44).
    var followsSelection: Bool { self != .engine }
}

/// Where an input delivers what it captures. Called on the input's own
/// realtime thread.
struct InputSink {
    /// One buffer at the input's own format, the host time its first frame
    /// was captured, and the host time of the callback (`HostClock`
    /// nanoseconds).
    var deliver: (_ pcm: AVAudioPCMBuffer, _ firstFrame: UInt64, _ now: UInt64) -> Void
    /// The input route changed; the recording must be discarded.
    var routeChanged: () -> Void
    /// The input failed to produce a buffer it was due.
    var inputFailed: () -> Void
}

/// One way of running the microphone for a single recording. `AudioCapture`
/// owns the checks before it and the conversion and bookkeeping after it.
///
/// `start` and `stop` are called in pairs on one thread. Between them the
/// input delivers to the sink; after `stop` returns it delivers nothing and
/// the device is no longer running for this process.
protocol CaptureInput: AnyObject {
    /// Starts the input on `device` (already validated). Throws
    /// `CaptureError`; on a throw nothing is left running. Returns the
    /// format the input delivers.
    func start(device: InputDevice, sink: InputSink) throws -> InputDevice
    /// Stops the input. Safe to call when not started.
    func stop()
    /// Does whatever setup can happen before a press without running the
    /// device. Best effort: `start` redoes whatever this could not.
    func prepareIdle()
}

extension CaptureInput {
    func prepareIdle() {}
}
