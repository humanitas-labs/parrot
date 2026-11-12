import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Capture through a Core Audio AUHAL input unit (#52), without
/// `AVAudioEngine`'s graph on top.
///
/// Per press the unit is bound to the input `selection` resolves to (the
/// microphone chosen in Settings, else the default input), set to deliver Float32
/// at the device's own rate, and started; `AudioCapture` converts to 16 kHz.
/// On release it is stopped and, unless `keepsPrepared`, disposed.
///
/// With `keepsPrepared` the unit stays built and initialized between presses
/// but never started: the device is not running, no callback fires, and the
/// microphone indicator is off. A press only starts it. The unit is rebuilt
/// on the next press if the selected input or its format changed meanwhile.
///
/// The #39 guarantees hold without an Objective-C exception to guard
/// against: every Core Audio call returns a status, and 0 Hz, 0 channel and
/// non-finite formats are refused before the unit is configured with them.
/// Mid-recording, the selected input moving to another device or the device
/// going away is reported through the sink, so the recording is discarded
/// instead of returned partial. A new rate or channel count on the same
/// device is followed instead: AUHAL does not resample input, so the unit is
/// restarted in the new format and the recording continues, missing only the
/// few tens of milliseconds the restart takes.
///
/// `start`, `stop` and every reaction to a device change run on one private
/// queue, so a change arriving during a release cannot race it.
final class HALInput: CaptureInput {
    /// What a device notification means for a unit built for one input.
    enum Change: Equatable {
        /// Nothing the unit depends on changed.
        case none
        /// The same device now runs at this rate or channel count.
        case format(InputDevice)
        /// The selection now resolves to another device, the device went
        /// away, or it now reports a format that cannot be recorded.
        case route
    }

    let keepsPrepared: Bool
    let selection: InputSelection

    private let control = DispatchQueue(label: "parrot.capture.hal")
    // Everything below is touched only on `control`.
    private var unit: AudioUnit?
    /// The device as the unit was built or last re-formatted for.
    private var built: InputDevice?
    /// What the unit delivers.
    private var delivering: InputDevice?
    private var context: RenderContext?
    private var watcher: DeviceWatcher?
    /// The input changed while idle; rebuild before the next start.
    private var stale = false

    init(keepsPrepared: Bool, selection: InputSelection = InputSelection()) {
        self.keepsPrepared = keepsPrepared
        self.selection = selection
    }

    deinit {
        // Nothing else holds this now, so nothing runs on `control` for it;
        // and deinit may itself run there, where a sync would deadlock.
        teardown()
    }

    /// Builds and initializes the unit for the selected input without
    /// starting it. Does nothing if it is already built for that device.
    func prepare() throws {
        let device = try InputDevice.current(selection)
        try control.sync { try prepare(device: device) }
    }

    /// With `keepsPrepared`, builds the unit ahead of the first press so a
    /// press only has to start it. Never starts the device. Skipped until
    /// microphone access is granted.
    func prepareIdle() {
        guard keepsPrepared, MicrophoneAccess.status == .authorized else { return }
        do {
            try prepare()
        } catch {
            Log.info("capture: input not prepared ahead of the press: \(error)")
        }
    }

    func start(device: InputDevice, sink: InputSink) throws -> InputDevice {
        try control.sync {
            try prepare(device: device)
            guard let unit, let context, let delivering else { throw CaptureError.noInputDevice }

            context.begin(sink)
            let status = AudioOutputUnitStart(unit)
            guard status == noErr else {
                context.end()
                teardown()
                throw CaptureError.engineStartFailed(Self.error(status, "AudioOutputUnitStart"))
            }
            return delivering
        }
    }

    func stop() {
        control.sync {
            guard let unit, let context else { return }
            if context.isRecording {
                // Returns once the device's IO has stopped: no callback after it.
                AudioOutputUnitStop(unit)
                context.end()
            }
            if !keepsPrepared { teardown() }
        }
    }

    /// Builds the unit for `device` unless it is already built for it and
    /// nothing has changed since. On `control`.
    private func prepare(device: InputDevice) throws {
        if unit != nil, !stale, built.map({ Self.sameInput($0, device) }) == true {
            return
        }
        teardown()

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptureError.engineStartFailed(Self.error(-1, "AudioComponentFindNext"))
        }
        var instance: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &instance), "AudioComponentInstanceNew")
        guard let unit = instance else { throw CaptureError.engineStartFailed(Self.error(-1, "AudioComponentInstanceNew")) }

        do {
            let format = try Self.configure(unit, device: device)
            let context = RenderContext(unit: unit, pcm: try Self.buffer(for: unit, format: format))
            var callback = AURenderCallbackStruct(
                inputProc: halInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
            )
            try Self.check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ), "SetInputCallback")
            try Self.check(AudioUnitInitialize(unit), "AudioUnitInitialize")

            self.unit = unit
            self.context = context
            self.built = device
            self.delivering = InputDevice(sampleRate: format.sampleRate, channels: format.channelCount, id: device.id)
            self.stale = false
            let control = self.control
            self.watcher = DeviceWatcher(device: device.id) { [weak self] in
                control.async { self?.inputChanged() }
            }
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    /// A device notification arrived. On `control`.
    private func inputChanged() {
        guard let built else { return }
        let recording = context?.isRecording == true
        switch Self.classify(built: built, current: DeviceWatcher.snapshot(of: built.id, selection: selection)) {
        case .none:
            return
        case .route:
            stale = true
            if recording { context?.routeChanged() }
        case .format(let now):
            if recording {
                reformat(to: now)
            } else {
                stale = true
            }
        }
    }

    /// Restarts the running unit in the device's new format, keeping the
    /// recording. If that fails, the recording is discarded as a route
    /// change. On `control`.
    private func reformat(to device: InputDevice) {
        guard let unit, let context else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        do {
            let format = try Self.configure(unit, device: device)
            context.replace(try Self.buffer(for: unit, format: format))
            try Self.check(AudioUnitInitialize(unit), "AudioUnitInitialize")
            try Self.check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
            built = device
            delivering = InputDevice(sampleRate: format.sampleRate, channels: format.channelCount, id: device.id)
            Log.info(String(
                format: "  capture: input changed to %.0f Hz × %u mid-recording; continuing",
                format.sampleRate, format.channelCount
            ))
        } catch {
            Log.error("capture: could not follow the input's new format: \(error)")
            stale = true
            context.routeChanged()
        }
    }

    /// Enables input only, binds the device, and sets the client format:
    /// Float32, non-interleaved, at the device's rate (AUHAL does not
    /// resample input), with at most two channels. Returns that format.
    private static func configure(_ unit: AudioUnit, device: InputDevice) throws -> AVAudioFormat {
        var on: UInt32 = 1
        var off: UInt32 = 0
        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, flagSize), "EnableIO input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flagSize), "EnableIO output")
        var id = device.id
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        ), "CurrentDevice")

        // What the device delivers into the unit.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "input format")
        guard let client = clientFormat(sampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame) else {
            throw CaptureError.invalidInputFormat(sampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame)
        }
        var asbd = client.streamDescription.pointee
        try check(AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ), "client format")
        return client
    }

    /// A render buffer in `format` large enough for any slice the unit asks for.
    private static func buffer(for unit: AudioUnit, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        var maxFrames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &size)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(maxFrames, 8192)) else {
            throw CaptureError.invalidInputFormat(sampleRate: format.sampleRate, channels: format.channelCount)
        }
        return pcm
    }

    /// The format the unit delivers for an input at `sampleRate` with
    /// `channels`, or nil if that input cannot be recorded (0 Hz, 0 channels,
    /// not finite). Channels past the second are dropped.
    static func clientFormat(sampleRate: Double, channels: UInt32) -> AVAudioFormat? {
        guard (try? InputDevice.validate(sampleRate: sampleRate, channels: channels)) != nil else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(min(channels, 2)),
            interleaved: false
        )
    }

    /// Whether a unit built for `built` can record `current` as is.
    static func sameInput(_ built: InputDevice, _ current: InputDevice) -> Bool {
        built.id == current.id && built.sampleRate == current.sampleRate && built.channels == current.channels
    }

    /// What `current`, a fresh read of the input, means for a unit built for
    /// `built`.
    static func classify(built: InputDevice, current: DeviceWatcher.Snapshot) -> Change {
        guard current.selected == built.id, current.isAlive else { return .route }
        if sameInput(built, current.device) { return .none }
        guard (try? InputDevice.validate(sampleRate: current.device.sampleRate, channels: current.device.channels)) != nil else {
            return .route
        }
        return .format(current.device)
    }

    /// Stops and disposes of the unit. On `control`.
    private func teardown() {
        watcher = nil
        if let unit {
            if context?.isRecording == true {
                AudioOutputUnitStop(unit)
                context?.end()
            }
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        context = nil
        built = nil
        delivering = nil
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status != noErr else { return }
        throw CaptureError.engineStartFailed(error(status, step))
    }

    private static func error(_ status: OSStatus, _ step: String) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: step])
    }
}

/// What the render callback needs, shared between the realtime thread and
/// the control queue.
private final class RenderContext: @unchecked Sendable {
    let unit: AudioUnit
    private let lock = NSLock()
    private var pcm: AVAudioPCMBuffer
    private var sink: InputSink?

    init(unit: AudioUnit, pcm: AVAudioPCMBuffer) {
        self.unit = unit
        self.pcm = pcm
    }

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sink != nil
    }

    func begin(_ sink: InputSink) {
        lock.lock()
        defer { lock.unlock() }
        self.sink = sink
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        sink = nil
    }

    /// A buffer in the unit's new format. Only while the unit is stopped.
    func replace(_ pcm: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        self.pcm = pcm
    }

    /// Discards the recording in progress, if any.
    func routeChanged() {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        sink?.routeChanged()
    }

    func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timestamp: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32,
        _ frames: UInt32
    ) -> OSStatus {
        let now = HostClock.now()
        lock.lock()
        let sink = self.sink
        let pcm = self.pcm
        lock.unlock()
        guard let sink else { return noErr }
        guard frames <= pcm.frameCapacity else {
            sink.inputFailed()
            return noErr
        }
        pcm.frameLength = frames
        let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for i in 0..<buffers.count {
            buffers[i].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
        }
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, pcm.mutableAudioBufferList)
        guard status == noErr else {
            sink.inputFailed()
            return status
        }
        let stamp = timestamp.pointee
        let firstFrame = stamp.mFlags.contains(.hostTimeValid)
            ? HostClock.nanoseconds(fromHostTime: stamp.mHostTime)
            : now &- UInt64(Double(frames) / pcm.format.sampleRate * 1_000_000_000)
        sink.deliver(pcm, firstFrame, now)
        return noErr
    }
}

private let halInputCallback: AURenderCallback = { refCon, flags, timestamp, bus, frames, _ in
    Unmanaged<RenderContext>.fromOpaque(refCon).takeUnretainedValue().render(flags, timestamp, bus, frames)
}

/// Listens for the changes that matter to a built unit: the default input
/// switching (which moves "Same as System", or brings back a chosen device
/// that was missing), the device's rate or input channels changing, or the
/// device disappearing, and calls `changed`, which re-reads and decides.
/// Listeners are removed when this is released.
final class DeviceWatcher {
    /// A fresh read of the input a unit was built for.
    struct Snapshot: Equatable {
        /// What the selection resolves to now: the chosen device if it is
        /// connected, else the default input.
        var selected: AudioDeviceID?
        var isAlive: Bool
        var device: InputDevice
    }

    private let queue = DispatchQueue(label: "parrot.capture.device-watcher")
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(device: AudioDeviceID, changed: @escaping () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        let system = AudioObjectID(kAudioObjectSystemObject)
        add(system, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, block)
        add(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, block)
        add(device, kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput, block)
        add(device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, block)
    }

    deinit {
        for (object, address, block) in registrations {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
    }

    private func add(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            registrations.append((object, address, block))
        }
    }

    /// Reads the selected input and `id`'s presence, rate and channels now.
    static func snapshot(of id: AudioDeviceID, selection: InputSelection) -> Snapshot {
        Snapshot(
            selected: selection.resolve()?.id,
            isAlive: InputDevice.isAlive(id),
            device: InputDevice(
                sampleRate: InputDevice.nominalSampleRate(id),
                channels: InputDevice.inputChannels(id),
                id: id
            )
        )
    }
}
