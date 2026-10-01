import AppKit
import Foundation

/// Flags for one foreground run of the dictation loop. Never persisted.
public struct DaemonOptions {
    public var skipDoctor: Bool
    public var debugHotkey: Bool
    public var dumpWav: Bool
    public var noOverlay: Bool
    public var model: String?
    /// How transcripts are inserted. Paste unless `--inject-mode` says otherwise.
    public var injectMode: InjectMode
    /// How the microphone is run (#52). The standard mode unless `--capture` says otherwise.
    public var captureMode: CaptureMode
    /// The push-to-talk key for this run only (#42). Nil uses the saved setting.
    public var hotkey: HotkeyKey?

    public init(
        skipDoctor: Bool,
        debugHotkey: Bool,
        dumpWav: Bool,
        noOverlay: Bool,
        model: String?,
        injectMode: InjectMode = .paste,
        captureMode: CaptureMode = .standard,
        hotkey: HotkeyKey? = nil
    ) {
        self.skipDoctor = skipDoctor
        self.debugHotkey = debugHotkey
        self.dumpWav = dumpWav
        self.noOverlay = noOverlay
        self.model = model
        self.injectMode = injectMode
        self.captureMode = captureMode
        self.hotkey = hotkey
    }
}

/// The dictation daemon (`parrot`, `parrot run`): startup checks, then the
/// AppKit run loop with the model loading behind the menu-bar icon. Does not
/// return once running.
public enum Daemon {
    /// Throws `StartupFailure` if the daemon cannot start.
    public static func run(_ options: DaemonOptions) throws {
        // ArgumentParser calls run() on the main thread.
        let settings = MainActor.assumeIsolated { SettingsStore() }
        let savedModel = MainActor.assumeIsolated { settings.current.model.id }
        let chosenModel = try Startup.check(
            modelID: options.model ?? Self.knownModel(savedModel),
            hotkey: options.hotkey,
            skipDoctor: options.skipDoctor
        )

        // Startup has already exited on denied access. If the system has never
        // asked, ask now, without waiting, so the prompt is answered while the
        // model loads rather than on the first press. Parrot.app asks from
        // the onboarding window's Allow instead, never unannounced (#51).
        if !AppLaunch.isApp {
            MicrophoneAccess.requestIfUndetermined()
        }

        let transcriber = WhisperKitTranscriber(model: chosenModel)

        try MainActor.assumeIsolated {
            try runLoop(model: chosenModel, transcriber: transcriber, settings: settings, options: options)
        }
    }

    /// `id` if the registry knows it. A saved id that no longer exists (a
    /// model removed in an update, a typo in a hand edit) falls back to the
    /// recommended model instead of stopping Parrot; `--model` stays strict.
    static func knownModel(_ id: String?) -> String? {
        guard let id else { return nil }
        guard ModelRegistry.find(id) != nil else {
            Log.warning("settings.json: unknown model \"\(id)\"; using the recommended model")
            return nil
        }
        return id
    }

    /// Wires the hotkey, capture and UI to a `DictationController` and runs
    /// the AppKit loop. Returns only if the app terminates.
    @MainActor
    private static func runLoop(
        model: TranscriptionModel,
        transcriber: WhisperKitTranscriber,
        settings: SettingsStore,
        options: DaemonOptions
    ) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(key: options.hotkey ?? settings.current.hotkey.key, debug: options.debugHotkey)
        let capture = AudioCapture(mode: options.captureMode)
        let overlay: RecordingOverlay? = options.noOverlay ? nil : RecordingOverlay()
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        // Before the menu, which shows "Check for Updates…" only when running.
        if AppLaunch.isApp { Updater.start() }
        let menuBar = MenuBarController(modelID: model.id)
        let settingsWindow = SettingsWindow(store: settings)
        menuBar.onOpenSettings = { settingsWindow.show() }
        // Fix Word… (#54). The service works only when macOS knows the
        // bundle, so only in the app role.
        let fixWord = FixWordUI(menuBar: menuBar)
        if AppLaunch.isApp {
            NSApp.servicesProvider = fixWord.service
            NSUpdateDynamicServices()
        }
        menuBar.setHotkey(monitor.key)
        // Parrot.app sets up the hotkey, languages and permissions, and
        // explains each permission before macOS asks (#51).
        OnboardingWindow.startIfNeeded(store: settings, menuBar: menuBar)
        // A model change loads behind the menu bar and swaps in between dictations (#43).
        let switcher = ModelSwitcher(model: model, transcriber: transcriber, menuBar: menuBar)

        // The dictionary (#33): converted once from dictionary.json, created
        // on first run, reloaded when it changes.
        let dictionary = DictionaryStore()
        switch DictionaryMigration.run() {
        case .converted(let examples):
            // The text file has no place for example sentences; they move to
            // settings.json, unless settings already has its own.
            if !examples.isEmpty {
                if settings.current.dictionary.examples.isEmpty {
                    settings.update { $0.dictionary.examples = examples }
                } else {
                    Log.info("dictionary: settings.json already has example sentences; kept those")
                }
            }
        case .nothingToDo:
            dictionary.createIfMissing()
        case .failed:
            // Leave the path empty so the next launch tries again.
            break
        }
        // Read at each release, so a Language change applies at the next press (#43).
        let dictionaryContext = {
            var context = DictionaryContext(
                store: dictionary,
                language: DictionaryContext.language(of: switcher.model, setting: settings.current.language.code),
                examples: settings.current.dictionary.examples
            ).context()
            context.spokenLanguages = settings.current.language.spoken ?? []
            return context
        }

        // Overlay first, then menu bar: the order the UI updated in before.
        var observers: [DictationObserver] = []
        if let overlay { observers.append(overlay) }
        observers.append(menuBar)
        observers.append(LatencyLog())
        let controller = DictationController(
            capture: capture,
            transcriber: transcriber,
            processors: [DictionaryProcessor(store: dictionary)],
            observers: observers,
            dumpWav: options.dumpWav,
            delivery: TextDelivery(mode: options.injectMode),
            context: dictionaryContext
        )
        switcher.controller = controller

        // Each setting applies itself here when it changes, from the window
        // or a hand edit of settings.json (#41). CLI flags only set the
        // starting values of a foreground run.
        settings.observe { old, new in
            if old.hotkey != new.hotkey {
                if options.hotkey != nil {
                    Log.info("hotkey: \(new.hotkey.key.rawValue) saved; --hotkey \(monitor.key.rawValue) stays in effect for this run")
                } else {
                    // The tap stays; it matches the new key from the next event.
                    monitor.setKey(new.hotkey.key)
                    menuBar.setHotkey(new.hotkey.key)
                    Log.info("hotkey: \(new.hotkey.key.rawValue); hold \(new.hotkey.key.shortName) to dictate")
                }
            }
            if old.model != new.model {
                switcher.select(new.model.id)
            }
            if old.language != new.language {
                // Read per dictation by dictionaryContext.
                Log.info("language: \(new.language.code ?? "automatic"); applies at next press")
            }
        }
        settings.startWatching()

        // HotkeyMonitor reports health on the main thread.
        monitor.onHealthChange = { health in
            MainActor.assumeIsolated { menuBar.setHotkeyHealth(health) }
        }
        // Load the model behind the menu-bar icon, so a first launch that
        // downloads it shows "loading model…" instead of nothing. The hotkey
        // starts only once the model is ready, so a press never reaches an
        // unloaded transcriber. A failed load (offline first run) retries
        // with backoff rather than exiting: the login item does not relaunch.
        menuBar.setHotkeyHealth(.modelLoading)
        Task { @MainActor in
            var retryDelay: UInt64 = 30
            while true {
                do {
                    try await transcriber.warmUp()
                    break
                } catch {
                    Log.error("\(StartupFailure.warmupFailed(error).message); retrying in \(retryDelay)s")
                    menuBar.setHotkeyHealth(.modelFailed)
                    try? await Task.sleep(nanoseconds: retryDelay * 1_000_000_000)
                    retryDelay = min(retryDelay * 2, 600)
                    menuBar.setHotkeyHealth(.modelLoading)
                }
            }
            do {
                try startHotkey(monitor, menuBar: menuBar) { event in
                    controller.handle(event)
                }
            } catch {
                Log.error((error as? StartupFailure)?.message ?? "\(error)")
                menuBar.setHotkeyHealth(.tapDisabled)
            }
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            Log.info("\nshutting down")
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        Log.info("model: \(model.id) · inject: \(options.injectMode.rawValue) · ^C to quit")
        app.run()
    }

    /// Starts the hotkey tap, or, without an Accessibility grant, asks for one
    /// and waits. The grant belongs to this binary, not the terminal that ran
    /// `parrot setup`, so the launch-at-login daemon has to ask for itself.
    /// It asks once per launch and keeps running: exiting would make launchd
    /// relaunch it and re-fire the prompt. Polling picks up the grant, so no
    /// restart is needed.
    @MainActor
    private static func startHotkey(
        _ monitor: HotkeyMonitor,
        menuBar: MenuBarController,
        onEvent: @escaping @MainActor (HotkeyMonitor.Event) -> Void
    ) throws {
        func start() throws {
            do {
                // HotkeyMonitor delivers events on the main queue.
                try monitor.start { event in
                    MainActor.assumeIsolated { onEvent(event) }
                }
            } catch {
                throw StartupFailure.hotkeyUnavailable(error)
            }
            menuBar.setHotkeyHealth(.ok)
            Log.info("listening on \(monitor.key.shortName) hold")
        }

        if AXIsProcessTrusted() {
            try start()
            return
        }

        Log.info("accessibility not granted; waiting (System Settings → Privacy & Security → Accessibility → parrot)")
        menuBar.setHotkeyHealth(.accessibilityMissing)
        // Parrot.app leaves the prompt to the onboarding window's Allow (#51).
        if !AppLaunch.isApp {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                Log.info("accessibility granted")
                do {
                    try start()
                } catch {
                    Log.error(StartupFailure.hotkeyUnavailable(error).message)
                    menuBar.setHotkeyHealth(.tapDisabled)
                }
            }
        }
    }
}
