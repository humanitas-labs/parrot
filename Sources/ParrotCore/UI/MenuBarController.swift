import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
///
/// The menu has named slots, top to bottom: `statusLine`, `modelLine`,
/// `grantPermissionsItem`, `fixWordItem`, `undoFixWordItem`, `settingsItem`,
/// `checkForUpdatesItem`, `quitItem`. Features update a slot rather than
/// rebuilding the menu.
@MainActor
final class MenuBarController {
    private static func readyStatus(_ key: HotkeyKey) -> String { "idle · hold \(key.shortName) to dictate" }

    private let statusItem: NSStatusItem
    /// Slot: what the dictation loop is doing. Driven as a `DictationObserver`.
    let statusLine: NSMenuItem
    /// Slot: the loaded model.
    let modelLine: NSMenuItem
    /// Slot: reopens the onboarding window (#51). Shown in Parrot.app while
    /// a permission is missing.
    let grantPermissionsItem: NSMenuItem
    /// What `grantPermissionsItem` does; set by `OnboardingWindow`.
    var onGrantPermissions: (() -> Void)?
    /// Slot: Fix Word… (#54): the selected word and what it should be.
    let fixWordItem: NSMenuItem
    var onFixWord: (() -> Void)?
    /// Slot: takes back the last Fix Word. Hidden until there is one.
    let undoFixWordItem: NSMenuItem
    var onUndoFixWord: (() -> Void)?
    /// Slot: opens the Settings window (#41) through `onOpenSettings`.
    let settingsItem: NSMenuItem
    /// Called by Settings…; set by the daemon, which owns the window.
    var onOpenSettings: (() -> Void)?
    /// Slot: asks Sparkle to check now. Hidden unless the updater is running,
    /// which it is only in Parrot.app's release builds.
    let checkForUpdatesItem: NSMenuItem
    /// Slot: quits parrot.
    let quitItem: NSMenuItem

    /// A degraded hotkey tap replaces the idle line, so the menu bar does not
    /// claim fn works when it does not (#37).
    private var hotkeyHealth: HotkeyHealth = .ok
    /// The key the idle line tells the user to hold (#42).
    private var hotkey: HotkeyKey = .fn
    private var isIdle = true
    private var idleStatus: String { hotkeyHealth.statusText ?? Self.readyStatus(hotkey) }

    init(modelID: String) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        statusLine = NSMenuItem(title: Self.readyStatus(.fn), action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        modelLine = NSMenuItem(title: "model: \(modelID)", action: nil, keyEquivalent: "")
        modelLine.isEnabled = false
        menu.addItem(modelLine)

        grantPermissionsItem = NSMenuItem(
            title: "Grant Permissions…",
            action: #selector(grantPermissionsClicked),
            keyEquivalent: ""
        )
        grantPermissionsItem.isHidden = true
        menu.addItem(grantPermissionsItem)

        menu.addItem(.separator())

        fixWordItem = NSMenuItem(title: "Fix Word…", action: #selector(fixWordClicked), keyEquivalent: "")
        menu.addItem(fixWordItem)
        undoFixWordItem = NSMenuItem(title: "Undo Fix Word", action: #selector(undoFixWordClicked), keyEquivalent: "")
        undoFixWordItem.isHidden = true
        menu.addItem(undoFixWordItem)

        settingsItem = NSMenuItem(title: "Settings…", action: #selector(settingsClicked), keyEquivalent: ",")
        menu.addItem(settingsItem)

        checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesClicked),
            keyEquivalent: ""
        )
        checkForUpdatesItem.isHidden = !Updater.isRunning
        menu.addItem(checkForUpdatesItem)

        quitItem = NSMenuItem(
            title: "Quit parrot",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
        quitItem.target = self
        settingsItem.target = self
        checkForUpdatesItem.target = self
        grantPermissionsItem.target = self
        fixWordItem.target = self
        undoFixWordItem.target = self
        configureButton()
    }

    func setStatus(_ text: String) {
        statusLine.title = text
    }

    /// Offers Undo for the word Fix Word added last, or hides it.
    func setUndoFixWord(_ word: String?) {
        undoFixWordItem.title = word.map { "Undo Fix Word “\($0)”" } ?? "Undo Fix Word"
        undoFixWordItem.isHidden = word == nil
    }

    func setHotkeyHealth(_ health: HotkeyHealth) {
        hotkeyHealth = health
        if isIdle { setStatus(idleStatus) }
    }

    func setHotkey(_ key: HotkeyKey) {
        hotkey = key
        if isIdle { setStatus(idleStatus) }
    }

    func setModel(_ modelID: String) {
        modelLine.title = "model: \(modelID)"
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = Self.birdImage()
        image?.isTemplate = true
        button.image = image
    }

    // Inlined Lucide bird SVG. Keeping it in source means the executable has
    // no separate resource bundle to install alongside it — true single-binary.
    static let birdSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M16 7h.01"/>\
    <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
    <path d="m20 7 2 .5-2 .5"/>\
    <path d="M10 18v3"/>\
    <path d="M14 17.75V21"/>\
    <path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
    </svg>
    """

    private static func birdImage() -> NSImage? {
        guard let data = birdSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func settingsClicked() {
        onOpenSettings?()
    }

    @objc private func grantPermissionsClicked() {
        onGrantPermissions?()
    }

    @objc private func checkForUpdatesClicked() {
        Updater.checkForUpdates()
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    @objc private func fixWordClicked() {
        onFixWord?()
    }

    @objc private func undoFixWordClicked() {
        onUndoFixWord?()
    }
}

extension MenuBarController: DictationObserver {
    func dictationStarted() {
        isIdle = false
        setStatus("● recording")
    }

    func dictationTranscribing() {
        isIdle = false
        setStatus("transcribing…")
    }

    func dictationFinished(_ result: DictationResult) {
        isIdle = true
        setStatus(idleStatus)
    }

    func dictationFailed(_ error: Error) {
        isIdle = true
        setStatus(idleStatus)
    }
}
