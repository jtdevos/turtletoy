import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TurtleToyCore

// Save / Open / New for `.turtle` sketch files, last-session restore, the
// document-aware window title and the File menu. The pure logic (naming, dirty
// state, file IO, session encoding) lives in TurtleToyCore/SketchDocument.swift.

// MARK: - Document actions on the view model

extension IDEViewModel {
    /// `.turtle`. Resolves to the type exported in the app bundle's Info.plist,
    /// or to a dynamic type with the same extension under `swift run`.
    static var sketchContentType: UTType {
        UTType(filenameExtension: SketchDocumentState.fileExtension, conformingTo: .plainText) ?? .plainText
    }

    /// False for the headless render / screenshot launch flags, which expect a pristine first preset.
    static var isSessionEnabled: Bool {
        SketchSession.isSessionEnabled(arguments: CommandLine.arguments)
    }

    public var hasUnsavedChanges: Bool {
        document.isDirty(sourceCode)
    }

    public var windowTitle: String {
        document.windowTitle(for: sourceCode)
    }

    /// Base name for exported artwork: the file name for a saved sketch, otherwise the preset title.
    public var exportBaseName: String {
        document.exportBaseName
    }

    // MARK: Session

    /// Called once from `init`. Brings back the last buffer and its identity.
    func restoreLastSession() {
        guard Self.isSessionEnabled, let session = SketchSessionStore().load() else { return }
        let restored = session.restore()
        if let preset = restored.preset {
            selectedPreset = preset
        }
        replaceBuffer(with: restored.text, document: restored.document)
    }

    func persistSession() {
        guard Self.isSessionEnabled else { return }
        SketchSessionStore().save(SketchSession(text: sourceCode, document: document))
    }

    // MARK: New / Open / Save

    /// Preset buttons go through here so unsaved work is not silently replaced.
    public func requestPreset(_ preset: PresetProgram) {
        guard confirmDiscardingUnsavedChanges() else { return }
        selectPreset(preset)
        persistSession()
    }

    public func newDocument() {
        guard confirmDiscardingUnsavedChanges() else { return }
        replaceBuffer(with: "", document: .untitled())
        persistSession()
    }

    public func openDocument() {
        guard confirmDiscardingUnsavedChanges() else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Sketch"
        panel.allowedContentTypes = [Self.sketchContentType, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadDocument(at: url)
    }

    /// Opens a sketch handed to the app from outside (Finder, `open`, drag onto the Dock icon).
    public func openDocument(at url: URL) {
        guard url.isFileURL else { return }
        if url.standardizedFileURL == document.fileURL?.standardizedFileURL { return }
        guard confirmDiscardingUnsavedChanges() else { return }
        loadDocument(at: url)
    }

    private func loadDocument(at url: URL) {
        do {
            let text = try SketchFile.read(from: url)
            replaceBuffer(with: text, document: .file(url, savedText: text))
            persistSession()
        } catch {
            presentDocumentError(error, title: "The sketch “\(url.lastPathComponent)” could not be opened.")
        }
    }

    /// Saves to the current file, or asks for a location if there isn't one yet.
    /// Returns false if the user cancelled or the write failed.
    @discardableResult
    public func saveDocument() -> Bool {
        guard let url = document.fileURL else { return saveDocumentAs() }
        return write(to: url)
    }

    @discardableResult
    public func saveDocumentAs() -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save Sketch"
        panel.allowedContentTypes = [Self.sketchContentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = document.suggestedSaveFilename
        if let current = document.fileURL {
            panel.directoryURL = current.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: SketchFile.normalizedSaveURL(url))
    }

    private func write(to url: URL) -> Bool {
        let text = sourceCode
        do {
            try SketchFile.write(text, to: url)
        } catch {
            presentDocumentError(error, title: "The sketch could not be saved to “\(url.lastPathComponent)”.")
            return false
        }
        // Only the source text is saved; slider / colour-picker overrides are not part of the file.
        document = .file(url, savedText: text)
        persistSession()
        return true
    }

    // MARK: Unsaved changes

    /// Asks what to do with unsaved changes before they are replaced or closed.
    /// Returns true when it is fine to go ahead (nothing to lose, saved, or the user chose Don't Save).
    public func confirmDiscardingUnsavedChanges() -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes made to “\(document.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: document.fileURL == nil ? "Save…" : "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don't Save")
        dontSave.hasDestructiveAction = true
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = [.command]

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveDocument()
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    /// Used when the window closes or the app quits. On "Don't Save" the buffer goes
    /// back to its saved state, so the discarded edits are not restored on next launch.
    func confirmClosingDocument() -> Bool {
        guard confirmDiscardingUnsavedChanges() else { return false }
        if hasUnsavedChanges {
            sourceCode = document.savedText
        }
        persistSession()
        return true
    }

    // MARK: Helpers

    private func replaceBuffer(with text: String, document newDocument: SketchDocumentState) {
        parameterValues.removeAll()
        colorParameterValues.removeAll()
        backdropOverride = nil
        document = newDocument
        sourceCode = text
        compileProgram(resetAnimationIfNeeded: true)
    }

    private func presentDocumentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

// MARK: - File menu

/// The view model the menu bar acts on. The app is a single window with one
/// view model, which registers itself here when its view appears.
@MainActor
enum SketchCommandTarget {
    static weak var viewModel: IDEViewModel?
}

/// File ▸ New / Open… / Save / Save As… (⌘N, ⌘O, ⌘S, ⇧⌘S).
/// Replaces the default "New Window" item: the app stays single-window.
struct SketchFileCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { SketchCommandTarget.viewModel?.newDocument() }
                .keyboardShortcut("n", modifiers: [.command])
            Button("Open…") { SketchCommandTarget.viewModel?.openDocument() }
                .keyboardShortcut("o", modifiers: [.command])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { SketchCommandTarget.viewModel?.saveDocument() }
                .keyboardShortcut("s", modifiers: [.command])
            Button("Save As…") { SketchCommandTarget.viewModel?.saveDocumentAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Window integration

/// Attach to the main IDE view: document name + "Edited" in the title bar,
/// session persistence on every change, the close-window confirmation, and
/// opening `.turtle` files handed to the app.
struct SketchDocumentWindowModifier: ViewModifier {
    @ObservedObject var viewModel: IDEViewModel

    func body(content: Content) -> some View {
        content
            .navigationTitle(viewModel.windowTitle)
            .background(
                SketchWindowAccessor(
                    viewModel: viewModel,
                    isEdited: viewModel.hasUnsavedChanges,
                    fileURL: viewModel.document.fileURL
                )
            )
            .onAppear { SketchCommandTarget.viewModel = viewModel }
            .onChange(of: viewModel.sourceCode) { viewModel.persistSession() }
            .onChange(of: viewModel.document) { viewModel.persistSession() }
            .onOpenURL { viewModel.openDocument(at: $0) }
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }
}

/// Reaches the hosting `NSWindow` to set the edited dot / proxy icon and to
/// intercept closing while there are unsaved changes.
private struct SketchWindowAccessor: NSViewRepresentable {
    let viewModel: IDEViewModel
    let isEdited: Bool
    let fileURL: URL?

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.viewModel = viewModel
        view.isEdited = isEdited
        view.fileURL = fileURL
        return view
    }

    func updateNSView(_ view: WindowProbeView, context: Context) {
        view.isEdited = isEdited
        view.fileURL = fileURL
        view.applyToWindow()
    }

    final class WindowProbeView: NSView {
        weak var viewModel: IDEViewModel?
        var isEdited = false
        var fileURL: URL?
        private var closeGuard: SketchWindowCloseGuard?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            if !(window.delegate is SketchWindowCloseGuard) {
                let closeGuard = SketchWindowCloseGuard(wrapping: window.delegate) { [weak self] in
                    self?.viewModel?.confirmClosingDocument() ?? true
                }
                self.closeGuard = closeGuard
                window.delegate = closeGuard
            }
            applyToWindow()
        }

        func applyToWindow() {
            guard let window else { return }
            window.isDocumentEdited = isEdited
            window.representedURL = fileURL
        }
    }
}

/// Sits in front of SwiftUI's own window delegate: answers `windowShouldClose`
/// itself and forwards every other delegate message untouched.
final class SketchWindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var wrapped: NSWindowDelegate?
    private let shouldClose: @MainActor () -> Bool

    init(wrapping wrapped: NSWindowDelegate?, shouldClose: @escaping @MainActor () -> Bool) {
        self.wrapped = wrapped
        self.shouldClose = shouldClose
    }

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose() else { return false }
        return wrapped?.windowShouldClose?(sender) ?? true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (wrapped?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        wrapped
    }
}

// MARK: - Quit

extension AppDelegate {
    /// ⌘Q with unsaved changes asks the same question as closing the window.
    @MainActor
    @objc public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel = SketchCommandTarget.viewModel else { return .terminateNow }
        return viewModel.confirmClosingDocument() ? .terminateNow : .terminateCancel
    }
}
