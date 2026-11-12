# TurtleToy

Native macOS (14+, Apple Silicon) turtle-graphics toy IDE. Pure SwiftPM, no Xcode project, no third-party dependencies.

## Commands

- `swift test` — unit tests (XCTest, core only; ~10s cold)
- `make run` — launch the IDE (`swift run -c release TurtleToy`)
- `make app` — build `TurtleToy.app` (gitignored; Info.plist is generated inline in the Makefile)
- `make showcase` — headlessly re-render every preset to `showcase_renders/<preset id>.png`. Fastest way to verify renderer/shader/interpreter changes without opening a window; read the PNGs to check the result.

Other headless flags (parsed in `TurtleToyApp.swift`): `--export-animation <presetId> <out.mp4|out.gif> [--frames N] [--fps N] [--size N|WxH] [--mode crawl|time]`, `--render-crawl-frames <presetId> <dir> <n>`, `--capture-ide-screenshot <png>`, `--render-ide-frames <dir> <n>`, `--screencapture-window <png>` (real window, needs screen-recording permission), `--auto-crawl`.

## Layout

- `Sources/TurtleToyCore` — UI-free library: `Lexer` → `Parser` → `Interpreter` → `TurtleScene`. Only Foundation + simd, so it is the testable part.
- `Sources/TurtleToy` — SwiftUI/AppKit app + Metal renderer. Not covered by tests.
- `docs/LANGUAGE_GUIDE.md`, `docs/ARCHITECTURE.md` — user-facing reference; keep in sync when the language or pipeline changes.

## How it fits together

- `Interpreter.compileAndRun(source:parameterOverrides:colorOverrides:timeSeconds:)` is the single entry point. It re-lexes, re-parses and re-runs the whole program on every edit, slider move, and (if the program reads `t`) every frame, on the main thread. It never throws: errors come back in `scene.diagnostics`, and runaway programs are cut off by budgets (250k instructions, 180k strokes, call depth 180).
- `TurtleScene` is the whole contract between core and renderer: flat arrays of GPU-ready strokes/fill vertices, plus `steps` (`TurtleStepRecord`) that map ranges of those arrays back to a source line. Turtle Crawl playback is just the renderer drawing up to `playbackStepCursor`; nothing is re-interpreted.
- Symmetry is expanded in the interpreter (`emitSymmetricStrokes`), so one step may own many strokes.
- The editor's contents have a document identity, `IDEViewModel.document` (`SketchDocumentState`: preset, untitled, or a `.turtle` file), separate from `selectedPreset`. Pure document/session logic is in `TurtleToyCore/SketchDocument.swift` (tested); menus, panels and window glue are in `SketchDocumentSupport.swift`.
- Animation export (`AnimationExporter.swift`) renders on its own `MetalRenderer` off the main thread; `AnimationExportView.swift` holds the button, options popover and progress state.
- `IDEViewModel` (`@MainActor`) owns the `MetalRenderer` and all UI state; views are in `TurtleToyApp.swift` (main layout) and `IDEPanels.swift`.

## Gotchas

- **Shaders live in a Swift string** (`MetalShaderSource.swift`), compiled at launch with `makeLibrary(source:)`. There is no `.metal` file despite comments saying "Shaders.metal". Shader errors surface only at runtime — run `make showcase` after touching them.
- **GPU struct layouts are duplicated by hand**: `StrokeInstanceGPU`, `FillVertexGPU`, `ParticleGPU` in `TurtleScene.swift` and the uniforms in `MetalRenderer.swift` must match the MSL structs field-for-field (order, size, alignment).
- **Adding a brush or backdrop** touches: the enum + `from(string:)` aliases in `TurtleScene.swift`, the matching branch in the shader string, and the language guide. The raw value is the shader's switch index.
- **Adding a command** touches: `executeCommand` in `Interpreter.swift` *and* `expectedMaxArity(for:)` in `Parser.swift` (commands take paren-less args, so the parser needs the arity to know where a statement ends).
- **`IDESnapshotCompositeView`** (`TurtleToyApp.swift`) is a hand-drawn SwiftUI replica of the IDE used only for the headless README screenshot/GIF. It does not update itself when the real UI changes.
- **Session restore**: the last buffer is written to UserDefaults on every text change and restored in `IDEViewModel.init`. It is skipped for the headless flags listed in `SketchSession.headlessLaunchFlags`; add any new flag that constructs an `IDEViewModel` to that set.
- **Exports embed the sketch source** in file metadata (PNG Description chunk, MP4 comment/description, GIF XMP). `make showcase` does this too, so the gallery PNGs carry their preset code.
- The interactive UI has no automated tests and agents should not launch the GUI unasked; verify through the headless flags and say what was left for a manual check.
- Language semantics: angles are degrees, heading 0 = north (+Y up), `rt` is clockwise; identifiers and command names are case-insensitive; booleans are numbers.
- `let` inside a procedure writes a **global** unless the name is one of that procedure's parameters (`setVariable` in `Interpreter.swift`), so recursive procedures share their "locals".
- Targets use Swift 5 language mode on the 6.0 toolchain (no strict concurrency checking).
- Preset ids in `PresetGallery.swift` are also the showcase PNG filenames referenced by the README.
