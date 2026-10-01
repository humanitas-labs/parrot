import XCTest
@testable import ParrotCore

// Made-up words only.

final class FixWordTests: XCTestCase {
    private let common = FixedCommonWords(words: ["link", "deck", "dev", "printer"])

    func testAFixWritesTheWordAndWhatTheModelWrote() {
        XCTAssertEqual(FixWord(heard: " Kwilbo ", word: "Qwilbo", replace: true).edit, .add(word: "Qwilbo", replaces: ["Kwilbo"]))
        XCTAssertEqual(FixWord(heard: "Kwilbo", word: "Qwilbo", replace: false).edit, .add(word: "Qwilbo", replaces: []))
        XCTAssertEqual(FixWord(heard: "zor  blink", word: "Zorblink", replace: true).edit, .add(word: "Zorblink", replaces: ["zor blink"]))
        // The word in another case needs no item: the row fixes the case.
        XCTAssertEqual(FixWord(heard: "qwilbo", word: "Qwilbo", replace: true).edit, .add(word: "Qwilbo", replaces: []))
    }

    func testUndoTakesBackOnlyWhatTheFixAdded() {
        let fix = FixWord(heard: "Kwilbo", word: "Qwilbo", replace: true)
        XCTAssertEqual(fix.undo(createdRow: true), .remove(word: "Qwilbo", replaces: []))
        XCTAssertEqual(fix.undo(createdRow: false), .remove(word: "Qwilbo", replaces: ["Kwilbo"]))
        XCTAssertNil(FixWord(heard: "qwilbo", word: "Qwilbo", replace: true).undo(createdRow: false))
    }

    func testUndoRestoresTheUsersRow() throws {
        let file = "Word          Replaces\nQwilbo        Qilbo\n"
        let fix = FixWord(heard: "Kwilbo", word: "Qwilbo", replace: true)
        let added = try DictionaryText.applying([fix.edit], to: file)
        XCTAssertEqual(added, "Word          Replaces\nQwilbo        Qilbo, Kwilbo\n")
        XCTAssertEqual(try DictionaryText.applying([try XCTUnwrap(fix.undo(createdRow: false))], to: added), file)
    }

    func testReplaceStartsOffForAnEverydayWord() {
        XCTAssertTrue(FixWord.suggestsReplace(heard: "Kwilbo", common: common))
        XCTAssertFalse(FixWord.suggestsReplace(heard: "Link", common: common))
        XCTAssertFalse(FixWord.suggestsReplace(heard: "  ", common: common))
    }

    func testWarningsNameWhatTheRowWouldChange() {
        XCTAssertEqual(FixWord(heard: "Link", word: "Zorblink", replace: true).warnings(common: common),
                       ["Every “Link” in every dictation becomes “Zorblink”."])
        XCTAssertEqual(FixWord(heard: "deck", word: "dev", replace: false).warnings(common: common),
                       ["Every “dev”, in any case, becomes “dev”."])
        XCTAssertEqual(FixWord(heard: "zorp", word: "zorpe", replace: true).warnings(common: common),
                       ["Every capitalized “Zorpe” becomes “zorpe”, even at the start of a sentence."])
        XCTAssertEqual(FixWord(heard: "Kwilbo", word: "Qwilbo", replace: true).warnings(common: common), [])
    }

    func testOnlyAFewWordsFit() {
        XCTAssertTrue(FixWord.fits("Zorbex Labs"))
        XCTAssertFalse(FixWord.fits("this is far too long to be one name"))
        XCTAssertFalse(FixWord.fits("   "))
        XCTAssertFalse(FixWord.fits(String(repeating: "x", count: 65)))
    }

    func testShapes() {
        XCTAssertTrue(FixWord.hasShape("Qwilbo"))
        XCTAssertTrue(FixWord.hasShape("qx7"))
        XCTAssertTrue(FixWord.hasShape("zor-blink"))
        XCTAssertFalse(FixWord.hasShape("zorblink"))
    }

    func testTheWriterCreatesTheRowAndUndoRemovesIt() throws {
        let dir = try TemporaryDirectory()
        let writer = DictionaryWriter(file: dir.url.appendingPathComponent("dictionary"), lock: dir.url.appendingPathComponent("dictionary.lock"))
        try "# mine\nWord          Replaces\nVercel        Versailles\n".write(to: writer.file, atomically: true, encoding: .utf8)
        let fix = FixWord(heard: "Kwilbo", word: "Qwilbo", replace: true)
        let hadRow = FixWordUI.words(in: writer.file).contains(fix.cleanWord)
        XCTAssertFalse(hadRow)
        try writer.apply([fix.edit])
        XCTAssertEqual(try UserDictionary.parse(Data(contentsOf: writer.file)).replacements.last, .init(from: ["Kwilbo"], to: "Qwilbo"))
        try writer.apply([try XCTUnwrap(fix.undo(createdRow: !hadRow))])
        XCTAssertFalse(FixWordUI.words(in: writer.file).contains("Qwilbo"))
        XCTAssertTrue(try String(contentsOf: writer.file, encoding: .utf8).hasPrefix("# mine\nWord          Replaces\nVercel        Versailles\n"))
    }
}
