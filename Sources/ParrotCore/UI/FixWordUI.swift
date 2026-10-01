import AppKit

/// Fix Word… (#54), wired to the menu bar and to the "Fix Word in Parrot"
/// service: opens the panel with the selected text, writes the dictionary
/// through `DictionaryWriter`, and keeps the last fix so the menu can undo
/// it. Nothing is stored beyond the dictionary itself.
@MainActor
final class FixWordUI {
    private let menuBar: MenuBarController
    private let panel = FixWordPanel()
    private let writer: DictionaryWriter
    /// The service provider; `NSApp.servicesProvider` holds it weakly, so
    /// this keeps it alive.
    let service = FixWordService()
    /// The word of the last fix and the edit that takes it back, in memory.
    private var last: (word: String, undo: DictionaryEdit)?

    init(menuBar: MenuBarController, writer: DictionaryWriter = DictionaryWriter()) {
        self.menuBar = menuBar
        self.writer = writer
        panel.onAdd = { [weak self] fix in self?.add(fix) ?? "Parrot isn't ready" }
        service.onText = { [weak self] text in self?.panel.show(heard: text) }
        menuBar.onFixWord = { [weak self] in self?.showForSelection() }
        menuBar.onUndoFixWord = { [weak self] in self?.undo() }
    }

    /// Opens the panel with the selection of the app the user is in. The
    /// menu is open over that app, so its focused element still holds the
    /// selection.
    func showForSelection() {
        panel.show(heard: FocusSnapshot.selectedWords() ?? "")
    }

    private func add(_ fix: FixWord) -> String? {
        do {
            let hadRow = Self.words(in: writer.file).contains(fix.cleanWord)
            try writer.apply([fix.edit])
            // The log names no word: what the user dictates stays out of it.
            Log.info("fix word: dictionary updated")
            last = fix.undo(createdRow: !hadRow).map { (fix.cleanWord, $0) }
            menuBar.setUndoFixWord(last?.word)
            return nil
        } catch {
            return "Not added: \(error)"
        }
    }

    private func undo() {
        guard let last else { return }
        do {
            try writer.apply([last.undo])
            Log.info("fix word: undone")
        } catch {
            Log.warning("fix word: undo failed: \(error)")
        }
        self.last = nil
        menuBar.setUndoFixWord(nil)
    }

    /// The words of the dictionary file, or none when it is missing or
    /// doesn't parse.
    nonisolated static func words(in file: URL) -> [String] {
        guard let data = try? Data(contentsOf: file), let dictionary = try? UserDictionary.parse(data) else { return [] }
        return dictionary.terms
    }
}

/// The "Fix Word in Parrot" service (Info.plist `NSServices`): the user
/// selects a word in any app and picks the service, or its shortcut from
/// System Settings → Keyboard → Keyboard Shortcuts → Services. No event tap.
final class FixWordService: NSObject {
    var onText: ((String) -> Void)?

    @objc(fixWord:userData:error:)
    func fixWord(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let words = FixWord.fits(text) ? text : ""
        DispatchQueue.main.async { self.onText?(words) }
    }
}
