import AppKit
import SwiftUI

/// The Settings window (#41), opened from the menu bar's Settings… (⌘,).
/// One instance: opening it again brings the same window to the front, and
/// closing it leaves Parrot running.
@MainActor
final class SettingsWindow {
    private let store: SettingsStore
    private var window: NSWindow?

    init(store: SettingsStore) {
        self.store = store
    }

    func show() {
        let window = self.window ?? make()
        self.window = window
        // An accessory app is never active on its own; without this the
        // window opens behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Parrot Settings"
        // The header inside says it; the title still names the window in
        // Mission Control and the window switcher.
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: SettingsView(store: store))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}


/// Every setting on one scrolling page. Controls write straight through to
/// `settings.json` via `SettingsStore`, and a hand edit of the file updates
/// the controls, so the window and the file never disagree. The window holds
/// no state of its own (ADR-002).
///
/// Laid out by hand rather than as a grouped `Form`, whose row boxes can't
/// be removed on macOS: rows sit on the window background and the pills
/// carry the style, as in the onboarding window.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsHeader()
                    .padding(.bottom, 8)
                Divider()
                SettingsGroup("General") {
                    PillRow("Config") {
                        Button("Open Config File") {
                            store.createIfMissing()
                            NSWorkspace.shared.open(store.file)
                        }
                        .buttonStyle(.pill)
                    }
                    HotkeyRow(store: store)
                    MicrophoneRow(store: store)
                    LaunchAtLoginRow()
                    PillRow("Reset") {
                        Button("Reset to Defaults") { store.write(Settings()) }
                            .buttonStyle(.pill)
                    }
                }
                Divider()
                TranscriptionSection(store: store)
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)
            .padding(.bottom, 32)
        }
        // Escape and ⌘W close the window: an accessory app has no menu bar
        // of its own to carry Close. Behind the page, so it takes no row.
        .background {
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .frame(width: 460)
        .frame(minHeight: 420, idealHeight: 560)
        .onExitCommand { NSApp.keyWindow?.performClose(nil) }
    }
}

/// A titled group of rows, such as General.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            content()
        }
    }
}

/// The Parrot bird, with the title and version centered under it.
private struct SettingsHeader: View {
    var body: some View {
        VStack(spacing: 4) {
            BirdBadge()
                .padding(.bottom, 12)
            Text("Parrot · Settings")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Version \(AppBundle.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Launch at login through `SMAppService`. Read live, since the user can
/// change it in System Settings while Parrot runs; not stored in
/// `settings.json`.
private struct LaunchAtLoginRow: View {
    @State private var isOn = LoginItem.isEnabled

    var body: some View {
        if LoginItem.isAvailable {
            // Outside a Form a toggle is a checkbox; this keeps the switch
            // on the right, like the other controls.
            PillRow("Launch at login") {
                Toggle("Launch at login", isOn: Binding(
                get: { isOn },
                set: { on in
                    do {
                        try LoginItem.setEnabled(on)
                    } catch {
                        Log.warning("couldn't change launch at login: \(error)")
                    }
                    isOn = LoginItem.isEnabled
                }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                isOn = LoginItem.isEnabled
            }
        } else {
            Text("Launch at login is available when Parrot runs from Parrot.app.")
                .foregroundStyle(.secondary)
        }
    }
}
