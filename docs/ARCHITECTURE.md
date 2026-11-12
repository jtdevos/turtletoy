# TurtleToy Architecture & Rendering Pipeline

**TurtleToy** is a native macOS Apple Silicon (M-series) creative coding "toy IDE" built with **Swift 6**, **AppKit/SwiftUI**, and a custom **multi-pass Metal 2D Signed Distance Field (SDF) + HDR Bloom** engine.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        TurtleToy Native macOS App                       │
├───────────────────────────────────┬─────────────────────────────────────┤
│         Left Pane (IDE)           │        Right Pane (120Hz Metal)     │
│  • Preset Showcase Carousel       │  • InteractiveMTKView (ProMotion)   │
│  • TurtleCodeTextView (AppKit)    │  • Pass 1: Procedural Backdrop      │
│    - Syntax Highlighting          │    + Polygon Fills + Instanced SDF  │
│    - Option-Drag Number Scrubbing │    Brushes + GPU Particles +        │
│    - Active Step Line Highlight   │    SDF Cyber-Turtle Avatar          │
│  • @param Live Slider Deck        │  • Pass 2: HDR Brightness Threshold │
│  • Quick Snippet Drawer           │  • Pass 3: Separable Gaussian Pyramid│
│                                   │  • Pass 4: ACES Filmic Composite    │
└───────────────────────────────────┴─────────────────────────────────────┘
```

## 1. Custom Language & VM (`Sources/TurtleToyCore`)
- **[`Lexer.swift`](../Sources/TurtleToyCore/Lexer.swift)**: Single-pass tokenizer supporting Logo-style (`fd 100`, `:var`) and modern C/Swift-style (`for i in 1..20 { ... }`, `tree(80, 5)`) syntax, `#RRGGBB` color literals, `@param` slider directives, and `Lexer.findNumberAt(utf16Offset:in:)` for live inline number scrubbing in the code editor.
- **[`Parser.swift`](../Sources/TurtleToyCore/Parser.swift)**: Precedence-climbing expression parser and recursive-descent statement parser with forward procedure arity pre-scanning so `to name ...` procedures can be called anywhere.
- **[`Interpreter.swift`](../Sources/TurtleToyCore/Interpreter.swift)**:
  - Evaluates the AST into a GPU-ready [`TurtleScene`](../Sources/TurtleToyCore/TurtleScene.swift) in `< 1 ms` for typical programs.
  - Supports `branch { ... }` (state push/pop), `spawn { ... }` (sub-turtle creation), and native `lsystem { ... }` string rewriting + custom symbol drawing blocks.
  - Automatically expands rotational and mirror kaleidoscope symmetry (`symmetry` / `kaleidoscope`) into instanced GPU primitives while grouping them into logical `TurtleStepRecord`s for step-by-step playback.

## 2. Metal 2D SDF + HDR Rendering Pipeline (`Sources/TurtleToy`)
- **[`MetalShaderSource.swift`](../Sources/TurtleToy/MetalShaderSource.swift)** & **[`MetalRenderer.swift`](../Sources/TurtleToy/MetalRenderer.swift)**:
  - **Offscreen `RGBA16Float` HDR Target**: Allows colors and glow intensities `> 1.0` to accumulate without clipping.
  - **Analytical SDF Capsule Strokes (`stroke_vertex` / `stroke_fragment`)**: Every stroke segment is expanded into a screen-aligned bounding quad in the vertex shader and evaluated analytically in the fragment shader using `fwidth` screen-space derivatives for razor-sharp edges at any zoom level (`0.15x` to `14x`).
  - **8 Procedural Brush Shaders**:
    1. `neon` — White-hot inner core + HDR plasma aura
    2. `laser` — Ultra-crisp coherent beam with chromatic edge dispersion
    3. `watercolor` — Multi-octave FBM noise edge deckle + coffee-ring pigment pooling
    4. `calligraphy` — Chisel-nib thickness modulation based on stroke heading angle + bristle texture
    5. `rainbow` — Continuous HSL spectral prism along cumulative path distance
    6. `electric` — Animated dual-strand jagged high-voltage lightning arcs
    7. `stardust` — Twinkling 4-point star glints and constellation beads along the path
    8. `ribbon` — 3D cylindrical normal shading with specular highlights and iridescent rim
  - **Sub-Step Scrubber Interpolation**: During animated playback or timeline scrubbing, the active step's stroke endpoints, widths, and cumulative distances are smoothly interpolated in the vertex shader (`u.partialStepFraction`), while the procedural SDF Cyber-Turtle avatar glides and paddles along the active segment.
