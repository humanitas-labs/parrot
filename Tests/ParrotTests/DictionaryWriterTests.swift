import XCTest
@testable import ParrotCore

final class DictionaryTextTests: XCTestCase {
    private let file = """
        # My words. Keep this comment.

        Word          Replaces
        Vercel        Versailles, Vercell
        Parakeet

        # Work
        PostHog   post hog

        """

    func testAddingAnItemToARowChangesOnlyThatLine() throws {
        let result = try DictionaryText.applying([.add(word: "Vercel", replaces: ["ver cell"])], to: file)
        XCTAssertEqual(result, file.replacingOccurrences(of: "Versailles, Vercell", with: "Versailles, Vercell, ver cell"))
    }

    func testAddingToARowWithoutItemsAlignsWithTheHeader() throws {
        let result = try DictionaryText.applying([.add(word: "Parakeet", replaces: ["parakeets"])], to: file)
        XCTAssertTrue(result.contains("\nParakeet      parakeets\n"), result)
    }

    func testANewWordGoesIntoTheAddedSection() throws {
        let once = try DictionaryText.applying([.add(word: "Qwilbo", replaces: ["Kwilbo"])], to: file)
        XCTAssertTrue(once.hasPrefix(file), "earlier lines stay as they were")
        XCTAssertTrue(once.hasSuffix("\n\(DictionaryText.addedSection)\nQwilbo        Kwilbo\n"), once)

        let twice = try DictionaryText.applying([.add(word: "Zorblink", replaces: [])], to: once)
        XCTAssertTrue(twice.hasSuffix("\(DictionaryText.addedSection)\nQwilbo        Kwilbo\nZorblink\n"), twice)
    }

    func testAddingWhatIsThereChangesNothing() throws {
        XCTAssertEqual(try DictionaryText.applying([.add(word: "Vercel", replaces: ["versailles"])], to: file), file)
        XCTAssertEqual(try DictionaryText.applying([.add(word: "Parakeet", replaces: [])], to: file), file)
    }

    func testRemovingAnItemOrARow() throws {
        let fewer = try DictionaryText.applying([.remove(word: "Vercel", replaces: ["Vercell"])], to: file)
        XCTAssertEqual(fewer, file.replacingOccurrences(of: "Versailles, Vercell", with: "Versailles"))

        let gone = try DictionaryText.applying([.remove(word: "PostHog", replaces: [])], to: file)
        XCTAssertEqual(gone, file.replacingOccurrences(of: "PostHog   post hog\n", with: ""))

        let last = try DictionaryText.applying([.remove(word: "PostHog", replaces: ["post hog"])], to: file)
        XCTAssertTrue(last.contains("\nPostHog\n"), last)
    }

    func testUndoRestoresTheFile() throws {
        let added = try DictionaryText.applying([.add(word: "Qwilbo", replaces: ["Kwilbo"])], to: file)
        let undone = try DictionaryText.applying([.remove(word: "Qwilbo", replaces: [])], to: added)
        XCTAssertEqual(undone, file + "\n\(DictionaryText.addedSection)\n")
    }

    func testConflictsAreRefused() {
        XCTAssertThrowsError(try DictionaryText.applying([.add(word: "vercel", replaces: [])], to: file)) {
            XCTAssertEqual($0 as? DictionaryWriteError, .wordInOtherCase(line: 4))
        }
        XCTAssertThrowsError(try DictionaryText.applying([.add(word: "Qwilbo", replaces: ["versailles"])], to: file)) {
            XCTAssertEqual($0 as? DictionaryWriteError, .itemInOtherRow(line: 4))
        }
        XCTAssertThrowsError(try DictionaryText.applying([.add(word: "Qwilbo", replaces: ["Parakeet"])], to: file)) {
            XCTAssertEqual($0 as? DictionaryWriteError, .itemInOtherRow(line: 5))
        }
        XCTAssertThrowsError(try DictionaryText.applying([.add(word: "a, b", replaces: [])], to: file))
        XCTAssertThrowsError(try DictionaryText.applying([.add(word: "#tag", replaces: [])], to: file))
    }

    func testLineEndsTabsAndAByteOrderMarkSurvive() throws {
        let crlf = "\u{FEFF}# note\r\nWord\tReplaces\r\nVercel\tVersailles\r\n"
        let result = try DictionaryText.applying([.add(word: "Vercel", replaces: ["Vercell"]), .add(word: "Qwilbo", replaces: [])], to: crlf)
        XCTAssertEqual(result, "\u{FEFF}# note\r\nWord\tReplaces\r\nVercel\tVersailles, Vercell\r\n\r\n\(DictionaryText.addedSection)\r\nQwilbo\r\n")
    }

    func testAFileWithoutAFinalNewlineKeepsItsShape() throws {
        let result = try DictionaryText.applying([.add(word: "Vercel", replaces: ["Vercell"])], to: "Vercel  Versailles")
        XCTAssertEqual(result, "Vercel  Versailles, Vercell")
    }

    func testANewFileHasTheHeader() throws {
        let result = try DictionaryText.applying([.add(word: "Qwilbo", replaces: ["Kwilbo"])], to: DictionaryText.newFile)
        XCTAssertTrue(result.hasPrefix(UserDictionary.preamble + "Word          Replaces\n"))
        XCTAssertEqual(try UserDictionary.parse(Data(result.utf8)).replacements, [.init(from: ["Kwilbo"], to: "Qwilbo")])
    }

    /// Random edits never change a row they don't name.
    func testRandomEditsKeepEveryOtherRow() throws {
        var generator = SystemRandomNumberGenerator()
        let words = ["Alpha", "Bravo", "Charlie", "Delta", "Echo"]
        let items = ["one", "two", "three", "four"]
        var text = file
        for _ in 0..<200 {
            let word = words.randomElement(using: &generator)!
            let picked = Array(items.shuffled(using: &generator).prefix(Int.random(in: 0...2, using: &generator)))
            let edit: DictionaryEdit = Bool.random(using: &generator) ? .add(word: word, replaces: picked.map { "\(word) \($0)" }) : .remove(word: word, replaces: picked.map { "\(word) \($0)" })
            text = try DictionaryText.applying([edit], to: text)
            XCTAssertTrue(text.hasPrefix(file), "the rows above the added section never change")
        }
    }
}

final class DictionaryWriterTests: XCTestCase {
    private var dir: TemporaryDirectory!

    override func setUpWithError() throws {
        dir = try TemporaryDirectory()
    }

    override func tearDown() {
        dir = nil
    }

    private func writer(_ name: String = "dictionary") -> DictionaryWriter {
        DictionaryWriter(file: dir.url.appendingPathComponent(name), lock: dir.url.appendingPathComponent("dictionary.lock"))
    }

    func testCreatesAMissingFileOwnerOnly() throws {
        let w = writer("new-dictionary")
        XCTAssertTrue(try w.apply([.add(word: "Qwilbo", replaces: ["Kwilbo"])]))
        let attributes = try FileManager.default.attributesOfItem(atPath: w.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try UserDictionary.parse(Data(contentsOf: w.file)).terms, ["Qwilbo"])
    }

    func testAnEditThatChangesNothingDoesNotWrite() throws {
        let w = writer()
        try w.apply([.add(word: "Qwilbo", replaces: [])])
        let before = try FileManager.default.attributesOfItem(atPath: w.file.path)[.modificationDate] as? Date
        XCTAssertFalse(try w.apply([.add(word: "Qwilbo", replaces: [])]))
        let after = try FileManager.default.attributesOfItem(atPath: w.file.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    func testWritesThroughASymlinkAndKeepsTheLink() throws {
        let target = dir.url.appendingPathComponent("dotfiles-dictionary")
        try "Vercel  Versailles\n".write(to: target, atomically: true, encoding: .utf8)
        let link = dir.url.appendingPathComponent("dictionary")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try writer().apply([.add(word: "Vercel", replaces: ["Vercell"])])
        XCTAssertEqual(Paths.fileType(link.path), .typeSymbolicLink)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Vercel  Versailles, Vercell\n")
    }

    func testRefusesAFileThatIsTooLarge() throws {
        let file = dir.url.appendingPathComponent("dictionary")
        try String(repeating: "# padding line\n", count: DictionaryStore.maxBytes / 15 + 10).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try writer().apply([.add(word: "Qwilbo", replaces: [])]))
    }

    func testLeavesNoTemporaryFiles() throws {
        try writer().apply([.add(word: "Qwilbo", replaces: ["Kwilbo"])])
        try writer().apply([.remove(word: "Qwilbo", replaces: [])])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        XCTAssertEqual(Set(names), ["dictionary", "dictionary.lock"])
    }
}
