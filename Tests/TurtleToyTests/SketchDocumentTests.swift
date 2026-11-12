import XCTest
@testable import TurtleToyCore

final class SketchDocumentTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurtleToyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Document identity

    func testPresetDocumentNamingAndDirtyState() {
        let preset = PresetGallery.all[0]
        let doc = SketchDocumentState.preset(preset)

        XCTAssertTrue(doc.isPreset)
        XCTAssertNil(doc.fileURL)
        XCTAssertEqual(doc.displayName, preset.title)
        XCTAssertFalse(doc.isDirty(preset.code))
        XCTAssertEqual(doc.windowTitle(for: preset.code), preset.title)
        XCTAssertTrue(doc.isDirty(preset.code + "\nfd 10"))
        XCTAssertEqual(doc.windowTitle(for: preset.code + "\nfd 10"), "\(preset.title) — Edited")

        // Same naming the PNG export used before documents existed.
        let legacy = preset.title.lowercased().replacingOccurrences(of: " ", with: "_")
        XCTAssertEqual(doc.exportBaseName, legacy)
        XCTAssertEqual(doc.suggestedSaveFilename, "\(legacy).turtle")
    }

    func testUntitledDocumentNaming() {
        let doc = SketchDocumentState.untitled()
        XCTAssertFalse(doc.isPreset)
        XCTAssertEqual(doc.displayName, "Untitled")
        XCTAssertFalse(doc.isDirty(""))
        XCTAssertEqual(doc.windowTitle(for: "fd 1"), "Untitled — Edited")
        XCTAssertEqual(doc.suggestedSaveFilename, "Untitled.turtle")
        XCTAssertEqual(doc.exportBaseName, "untitled")
    }

    func testFileDocumentNaming() {
        let url = URL(fileURLWithPath: "/tmp/sketches/My Spiral.turtle")
        let doc = SketchDocumentState.file(url, savedText: "fd 100")
        XCTAssertEqual(doc.fileURL, url)
        XCTAssertNil(doc.presetID)
        XCTAssertEqual(doc.displayName, "My Spiral.turtle")
        XCTAssertEqual(doc.windowTitle(for: "fd 100"), "My Spiral.turtle")
        XCTAssertEqual(doc.windowTitle(for: "fd 101"), "My Spiral.turtle — Edited")
        XCTAssertEqual(doc.suggestedSaveFilename, "My Spiral.turtle")
        XCTAssertEqual(doc.exportBaseName, "My Spiral")
    }

    // MARK: File IO

    func testWriteThenReadRoundTripsUTF8() throws {
        let url = tempDir.appendingPathComponent("round trip.turtle")
        let text = "// ✨ sparkle 🐢\n@param n 5 1 9 1 \"Größe\"\nfd 100\n"
        try SketchFile.write(text, to: url)
        XCTAssertEqual(try SketchFile.read(from: url), text)
        XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8))
    }

    func testReadStripsByteOrderMark() throws {
        let url = tempDir.appendingPathComponent("bom.turtle")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("fd 10".utf8)).write(to: url)
        XCTAssertEqual(try SketchFile.read(from: url), "fd 10")
    }

    func testReadRejectsNonUTF8() throws {
        let url = tempDir.appendingPathComponent("latin1.turtle")
        try Data([0x66, 0x64, 0x20, 0xFF, 0xFE, 0xE9]).write(to: url)
        XCTAssertThrowsError(try SketchFile.read(from: url)) { error in
            XCTAssertEqual(error as? SketchFileError, .notUTF8("latin1.turtle"))
        }
    }

    func testReadMissingFileThrows() {
        XCTAssertThrowsError(try SketchFile.read(from: tempDir.appendingPathComponent("nope.turtle")))
    }

    func testNormalizedSaveURLAddsExtensionOnlyWhenMissing() {
        XCTAssertEqual(SketchFile.normalizedSaveURL(URL(fileURLWithPath: "/tmp/a")).lastPathComponent, "a.turtle")
        XCTAssertEqual(SketchFile.normalizedSaveURL(URL(fileURLWithPath: "/tmp/a.turtle")).lastPathComponent, "a.turtle")
        XCTAssertEqual(SketchFile.normalizedSaveURL(URL(fileURLWithPath: "/tmp/a.txt")).lastPathComponent, "a.txt")
    }

    // MARK: Session

    func testSessionStoreRoundTripAndClear() throws {
        let suite = "TurtleToyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SketchSessionStore(defaults: defaults)

        XCTAssertNil(store.load())

        let session = SketchSession(text: "fd 100\nrt 90", filePath: "/tmp/x.turtle", presetID: nil)
        store.save(session)
        XCTAssertEqual(store.load(), session)

        store.clear()
        XCTAssertNil(store.load())
    }

    func testSessionStoreIgnoresCorruptData() throws {
        let suite = "TurtleToyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: SketchSessionStore.defaultKey)
        XCTAssertNil(SketchSessionStore(defaults: defaults).load())
    }

    func testSessionCapturesDocumentIdentity() {
        let preset = PresetGallery.all[1]
        XCTAssertEqual(
            SketchSession(text: "a", document: .preset(preset)),
            SketchSession(text: "a", filePath: nil, presetID: preset.id)
        )
        XCTAssertEqual(
            SketchSession(text: "b", document: .file(URL(fileURLWithPath: "/tmp/b.turtle"), savedText: "b")),
            SketchSession(text: "b", filePath: "/tmp/b.turtle", presetID: nil)
        )
        XCTAssertEqual(
            SketchSession(text: "c", document: .untitled()),
            SketchSession(text: "c", filePath: nil, presetID: nil)
        )
    }

    func testRestoreFileSessionUsesDiskContentAsBaseline() throws {
        let url = tempDir.appendingPathComponent("saved.turtle")
        try SketchFile.write("fd 100", to: url)

        let clean = SketchSession(text: "fd 100", filePath: url.path).restore()
        XCTAssertEqual(clean.document.fileURL?.path, url.path)
        XCTAssertFalse(clean.document.isDirty(clean.text))
        XCTAssertNil(clean.preset)

        let edited = SketchSession(text: "fd 250", filePath: url.path).restore()
        XCTAssertEqual(edited.text, "fd 250")
        XCTAssertEqual(edited.document.savedText, "fd 100")
        XCTAssertTrue(edited.document.isDirty(edited.text))
    }

    func testRestoreWithMissingFileKeepsTextAsUntitled() {
        let gone = tempDir.appendingPathComponent("deleted.turtle")
        let restored = SketchSession(text: "fd 42", filePath: gone.path).restore()
        XCTAssertEqual(restored.text, "fd 42")
        XCTAssertEqual(restored.document.origin, .untitled)
        XCTAssertTrue(restored.document.isDirty(restored.text))
    }

    func testRestorePresetSession() {
        let preset = PresetGallery.all[2]
        let pristine = SketchSession(text: preset.code, presetID: preset.id).restore()
        XCTAssertEqual(pristine.preset, preset)
        XCTAssertEqual(pristine.document, .preset(preset))
        XCTAssertFalse(pristine.document.isDirty(pristine.text))

        let tweaked = SketchSession(text: preset.code + "\nfd 1", presetID: preset.id).restore()
        XCTAssertEqual(tweaked.preset, preset)
        XCTAssertTrue(tweaked.document.isDirty(tweaked.text))
    }

    func testRestoreUnknownPresetOrNoIdentityIsUntitled() {
        let unknown = SketchSession(text: "fd 1", presetID: "no_such_preset").restore()
        XCTAssertEqual(unknown.document.origin, .untitled)
        XCTAssertNil(unknown.preset)

        let empty = SketchSession(text: "").restore()
        XCTAssertEqual(empty.document.origin, .untitled)
        XCTAssertFalse(empty.document.isDirty(empty.text))
    }

    func testHeadlessFlagsDisableSession() {
        XCTAssertTrue(SketchSession.isSessionEnabled(arguments: ["/path/TurtleToy"]))
        XCTAssertTrue(SketchSession.isSessionEnabled(arguments: ["/path/TurtleToy", "-NSDocumentRevisionsDebugMode", "YES"]))
        for flag in [
            "--render-showcase", "--render-crawl-frames", "--capture-ide-screenshot",
            "--render-ide-frames", "--screencapture-window", "--auto-crawl"
        ] {
            XCTAssertFalse(
                SketchSession.isSessionEnabled(arguments: ["/path/TurtleToy", flag, "out"]),
                "\(flag) should disable session restore"
            )
        }
    }
}
