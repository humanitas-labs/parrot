import Foundation

/// One change to a dictionary table (#54).
enum DictionaryEdit: Equatable, Sendable {
    /// Adds `replaces` to the row for `word`, and adds the row if it is
    /// missing. With no items, only makes sure the row exists.
    case add(word: String, replaces: [String])
    /// Removes `replaces` from the row for `word`. With no items, removes
    /// the row.
    case remove(word: String, replaces: [String])
}

/// Why an edit was refused. Descriptions give line numbers and never quote
/// the file.
enum DictionaryWriteError: Error, Equatable, CustomStringConvertible {
    /// The word or an item has a comma, starts with `#`, or is empty.
    case unwritable
    /// The file has the word in another casing, on this line.
    case wordInOtherCase(line: Int)
    /// An item already belongs to another row, as a word or an item.
    case itemInOtherRow(line: Int)
    /// The file isn't UTF-8 text.
    case notText
    /// The file can't be used; the message names the path, not the content.
    case unusable(String)
    /// The file kept changing while Parrot tried to write it.
    case changedDuringWrite
    /// The result did not parse to the old dictionary plus the edit.
    case failedCheck

    var description: String {
        switch self {
        case .unwritable: return "a word or item has a comma, starts with #, or is empty"
        case .wordInOtherCase(let line): return "line \(line) has the word in another casing"
        case .itemInOtherRow(let line): return "line \(line) already has that item"
        case .notText: return "not UTF-8 text"
        case .unusable(let message): return message
        case .changedDuringWrite: return "the file changed while Parrot wrote it; nothing was written"
        case .failedCheck: return "the edit did not give the expected dictionary; nothing was written"
        }
    }
}

/// Line edits on the dictionary's text (#54). Every line an edit does
/// not touch stays byte for byte: comments, spacing, order, a byte order
/// mark and CRLF line ends. `UserDictionary.text()` rewrites the whole
/// file and drops comments, so it is never used for these edits. Pure.
enum DictionaryText {
    /// The comment line above the rows Parrot adds, such as Fix Word's, so
    /// they stay apart from the rows the user wrote.
    static let addedSection = "# Added by Parrot"

    /// The text of a dictionary file that doesn't exist yet.
    static let newFile = UserDictionary.preamble + "Word          Replaces\n"

    static func applying(_ edits: [DictionaryEdit], to text: String) throws -> String {
        let before = try parse(text)
        var table = Table(text)
        for edit in edits { try table.apply(edit) }
        let result = table.text
        // The result must parse to the old rows plus exactly these edits.
        var expected = rows(before)
        for edit in edits { expected.apply(edit) }
        guard rows(try parse(result)) == expected else { throw DictionaryWriteError.failedCheck }
        return result
    }

    private static func parse(_ text: String) throws -> UserDictionary {
        do {
            return try UserDictionary.parse(Data(text.utf8))
        } catch {
            throw DictionaryWriteError.unusable("the dictionary doesn't parse: \(error)")
        }
    }

    /// Each word with its items, lowercased, for the check.
    private static func rows(_ dictionary: UserDictionary) -> [String: Set<String>] {
        var rows: [String: Set<String>] = [:]
        for term in dictionary.terms { rows[term, default: []].formUnion([]) }
        for replacement in dictionary.replacements { rows[replacement.to, default: []].formUnion(replacement.from.map { $0.lowercased() }) }
        return rows
    }

    /// Collapses runs of whitespace to one space, as the parser reads them.
    static func clean(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isWritable(_ s: String) -> Bool {
        !s.isEmpty && !s.contains(",") && !s.hasPrefix("#")
    }

    /// The file as lines, with what each row holds.
    private struct Table {
        struct Row {
            var word: String
            var items: [String]
        }

        var lines: [String]
        let newline: String
        let byteOrderMark: Bool
        let endsWithNewline: Bool
        /// Where the header's Replaces column starts, to align new rows.
        var replacesColumn: Int?

        init(_ text: String) {
            newline = text.contains("\r\n") ? "\r\n" : "\n"
            var body = text
            byteOrderMark = body.hasPrefix("\u{FEFF}")
            if byteOrderMark { body.removeFirst() }
            endsWithNewline = body.isEmpty || body.hasSuffix(newline)
            lines = body.isEmpty ? [] : body.components(separatedBy: newline)
            if endsWithNewline, lines.last == "" { lines.removeLast() }
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let (word, replaces) = UserDictionary.columns(trimmed)
                if UserDictionary.isHeader(word: word, replaces: replaces),
                   let range = line.range(of: "Replaces", options: .caseInsensitive) {
                    replacesColumn = line.distance(from: line.startIndex, to: range.lowerBound)
                }
            }
        }

        var text: String {
            (byteOrderMark ? "\u{FEFF}" : "") + lines.joined(separator: newline) + (endsWithNewline && !lines.isEmpty ? newline : "")
        }

        func row(_ index: Int) -> Row? {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let (word, replaces) = UserDictionary.columns(trimmed)
            guard !UserDictionary.isHeader(word: word, replaces: replaces) else { return nil }
            let items = replaces?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
            return Row(word: clean(word), items: items)
        }

        mutating func apply(_ edit: DictionaryEdit) throws {
            switch edit {
            case .add(let rawWord, let rawItems):
                let word = clean(rawWord)
                let items = rawItems.map(clean)
                guard isWritable(word), items.allSatisfy(isWritable) else { throw DictionaryWriteError.unwritable }
                var own: Int?
                for index in lines.indices {
                    guard let row = row(index) else { continue }
                    if row.word == word {
                        own = index
                    } else if row.word.caseInsensitiveCompare(word) == .orderedSame {
                        throw DictionaryWriteError.wordInOtherCase(line: index + 1)
                    }
                }
                // An item that is another row's word or item would compete with it.
                for index in lines.indices where index != own {
                    guard let row = row(index) else { continue }
                    let taken = Set(([row.word] + row.items).map { $0.lowercased() })
                    if items.contains(where: { taken.contains($0.lowercased()) }) {
                        throw DictionaryWriteError.itemInOtherRow(line: index + 1)
                    }
                }
                let existing = own.flatMap { row($0) }?.items ?? []
                let known = Set((existing + [word]).map { $0.lowercased() })
                var additions: [String] = []
                for item in items where !known.contains(item.lowercased()) && !additions.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) {
                    additions.append(item)
                }
                if let own {
                    guard !additions.isEmpty else { return }
                    lines[own] = rewrite(own, word: word, items: existing + additions)
                } else {
                    insertAdded(format(word, additions))
                }

            case .remove(let rawWord, let rawItems):
                let word = clean(rawWord)
                guard let index = lines.indices.first(where: { row($0)?.word == word }), let row = row(index) else { return }
                if rawItems.isEmpty {
                    lines.remove(at: index)
                    return
                }
                let drop = Set(rawItems.map { clean($0).lowercased() })
                let kept = row.items.filter { !drop.contains($0.lowercased()) }
                guard kept.count != row.items.count else { return }
                lines[index] = rewrite(index, word: word, items: kept)
            }
        }

        /// The row at `index` with `items`, keeping its indent and separator.
        private func rewrite(_ index: Int, word: String, items: [String]) -> String {
            let line = lines[index]
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            let afterIndent = line.dropFirst(indent.count)
            // The word as written, then the whitespace that separates it.
            let (writtenWord, _) = UserDictionary.columns(afterIndent.trimmingCharacters(in: .whitespaces))
            let rest = afterIndent.dropFirst(writtenWord.count)
            let separator = String(rest.prefix(while: { $0 == " " || $0 == "\t" }))
            guard !items.isEmpty else { return indent + writtenWord }
            let gap = separator.count >= 2 || separator.contains("\t") ? separator : padding(after: indent + writtenWord)
            return indent + writtenWord + gap + items.joined(separator: ", ")
        }

        private func format(_ word: String, _ items: [String]) -> String {
            items.isEmpty ? word : word + padding(after: word) + items.joined(separator: ", ")
        }

        /// Spaces that reach the header's Replaces column, and at least two.
        private func padding(after text: String) -> String {
            let target = max((replacesColumn ?? 0) - text.count, 2)
            return String(repeating: " ", count: target)
        }

        /// Adds `line` at the end of the added section, creating the
        /// section at the end of the file when it is missing.
        private mutating func insertAdded(_ line: String) {
            if let section = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == DictionaryText.addedSection }) {
                var end = section
                for index in lines.indices where index > section {
                    let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("#") { break }
                    if !trimmed.isEmpty { end = index }
                }
                lines.insert(line, at: end + 1)
                return
            }
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
            lines.append(DictionaryText.addedSection)
            lines.append(line)
        }
    }
}

private extension Dictionary where Key == String, Value == Set<String> {
    /// What `DictionaryText.applying` must produce, for its check.
    mutating func apply(_ edit: DictionaryEdit) {
        switch edit {
        case .add(let word, let items):
            let key = DictionaryText.clean(word)
            let added = Set(items.map { DictionaryText.clean($0).lowercased() }).subtracting([key.lowercased()])
            self[key, default: []].formUnion(added)
        case .remove(let word, let items):
            let key = DictionaryText.clean(word)
            guard self[key] != nil else { return }
            if items.isEmpty {
                self[key] = nil
            } else {
                self[key]?.subtract(items.map { DictionaryText.clean($0).lowercased() })
            }
        }
    }
}

/// Writes edits to a dictionary file on disk (#54).
///
/// Holds `lock` with `flock`, so two writers never interleave.
/// Reads the file, applies the edits with `DictionaryText`, writes a
/// temporary file beside it, checks that nobody changed the file in
/// between, and renames the temporary file over it. A symlinked file is
/// written at its target, as `SettingsStore` does, after the same checks
/// `DictionaryStore` makes before it reads.
struct DictionaryWriter {
    let file: URL
    let lock: URL

    init(file: URL = Paths.dictionaryFile, lock: URL = Paths.dictionaryLock) {
        self.file = file
        self.lock = lock
    }

    /// Applies `edits`. Returns false when they changed nothing.
    @discardableResult
    func apply(_ edits: [DictionaryEdit]) throws -> Bool {
        try withLock {
            for _ in 0..<3 {
                let current = try read()
                let updated = try DictionaryText.applying(edits, to: current.text ?? DictionaryText.newFile)
                if let text = current.text, updated == text { return false }
                do {
                    try write(updated, to: current.target, expecting: current.stamp)
                    return true
                } catch DictionaryWriteError.changedDuringWrite {
                    continue
                }
            }
            throw DictionaryWriteError.changedDuringWrite
        }
    }

    // MARK: - Files

    private struct Stamp: Equatable {
        var device: Int32
        var inode: UInt64
        var size: Int64
        var seconds: Int
        var nanoseconds: Int

        init(_ st: stat) {
            device = st.st_dev
            inode = st.st_ino
            size = st.st_size
            seconds = st.st_mtimespec.tv_sec
            nanoseconds = st.st_mtimespec.tv_nsec
        }
    }

    /// The file's text and identity, or nil text when it doesn't exist.
    private func read() throws -> (text: String?, stamp: Stamp?, target: URL) {
        guard Paths.fileType(file.path) != nil else { return (nil, nil, file) }
        let target = file.resolvingSymlinksInPath()
        let fd = open(target.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw DictionaryWriteError.unusable("couldn't open \(target.path): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw DictionaryWriteError.unusable("couldn't read \(target.path)") }
        if let problem = DictionaryStore.problem(with: st, at: target.path) { throw DictionaryWriteError.unusable(problem) }
        let data = try handle.readToEnd() ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { throw DictionaryWriteError.notText }
        return (text, Stamp(st), target)
    }

    private func write(_ text: String, to target: URL, expecting stamp: Stamp?) throws {
        let dir = target.deletingLastPathComponent()
        if Paths.fileType(dir.path) == nil {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let temporary = dir.appendingPathComponent(".\(target.lastPathComponent).\(getpid()).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DictionaryWriteError.unusable("couldn't create \(temporary.path): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(text.utf8))
            try handle.synchronize()
            try handle.close()
            // Nobody may have changed the file since it was read.
            var st = stat()
            let exists = stat(target.path, &st) == 0
            guard exists ? stamp == Stamp(st) : stamp == nil else { throw DictionaryWriteError.changedDuringWrite }
            guard rename(temporary.path, target.path) == 0 else {
                throw DictionaryWriteError.unusable("couldn't replace \(target.path): \(String(cString: strerror(errno)))")
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let dir = lock.deletingLastPathComponent()
        if Paths.fileType(dir.path) == nil {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let fd = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DictionaryWriteError.unusable("couldn't open \(lock.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw DictionaryWriteError.unusable("couldn't lock \(lock.path)") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
