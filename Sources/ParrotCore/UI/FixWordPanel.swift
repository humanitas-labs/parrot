import AppKit
import SwiftUI

/// The Fix Word… panel (#54): what the model wrote, what it should be, and
/// whether to replace the misheard form in every dictation. Opened from the
/// menu bar or the "Fix Word in Parrot" service, with the selected text.
@MainActor
final class FixWordPanel {
    private var panel: NSPanel?
    /// Called with the fix to write. Returns an error message, or nil when
    /// the dictionary was written.
    var onAdd: ((FixWord) -> String?)?

    func show(heard: String) {
        panel?.close()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Fix Word"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FixWordView(
            heard: heard,
            onCancel: { [weak panel] in panel?.close() },
            onAdd: { [weak self, weak panel] fix in
                guard let self else { return "Parrot isn't ready" }
                let error = self.onAdd?(fix)
                if error == nil { panel?.close() }
                return error
            }
        ))
        panel.center()
        self.panel = panel
        // An accessory app is never active on its own; without this the
        // panel opens behind the app the user is in.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

struct FixWordView: View {
    @State var heard: String
    @State private var word = ""
    @State private var replace = true
    @State private var error: String?
    let onCancel: () -> Void
    let onAdd: (FixWord) -> String?

    private var fix: FixWord { FixWord(heard: heard, word: word, replace: replace) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Parrot wrote").foregroundStyle(.secondary)
                    TextField("the misheard word", text: $heard)
                }
                GridRow {
                    Text("Should be").foregroundStyle(.secondary)
                    TextField("your spelling", text: $word)
                        .onSubmit(add)
                }
            }
            .textFieldStyle(.roundedBorder)

            Toggle(isOn: $replace) {
                Text(fix.canReplace ? "Replace “\(fix.cleanHeard)” in every dictation" : "Replace the misheard word in every dictation")
            }
            .toggleStyle(.checkbox)
            .disabled(!fix.canReplace)

            if !fix.cleanWord.isEmpty {
                Text(replace && fix.canReplace
                    ? "Adds the row “\(fix.cleanWord)  \(fix.cleanHeard)” to your dictionary."
                    : "Adds “\(fix.cleanWord)” to your dictionary, so Parrot keeps this spelling.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(fix.warnings(), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!FixWord.fits(word))
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            word = heard
            replace = FixWord.suggestsReplace(heard: heard)
        }
        .onChange(of: heard) {
            error = nil
            replace = FixWord.suggestsReplace(heard: heard)
        }
        .onChange(of: word) { error = nil }
    }

    private func add() {
        guard FixWord.fits(word) else { return }
        error = onAdd(fix)
    }
}
