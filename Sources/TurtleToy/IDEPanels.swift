import SwiftUI
import simd
import TurtleToyCore

// MARK: - Interactive Parameter Deck (@param Sliders & Color Pickers)

public struct ParameterDeckView: View {
    @ObservedObject public var viewModel: IDEViewModel

    public var body: some View {
        if !viewModel.scene.parameters.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("LIVE PARAMETERS", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.25, green: 0.95, blue: 0.85))
                    Spacer()
                    Button(action: { viewModel.randomizeParameters() }) {
                        Label("Surprise Me", systemImage: "dice.fill")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.purple)

                    Button(action: { viewModel.resetParametersToDefaults() }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reset parameters to defaults")
                }

                VStack(spacing: 8) {
                    ForEach(viewModel.scene.parameters) { param in
                        parameterRow(for: param)
                    }
                }
            }
            .padding(12)
            .background(Color(red: 0.08, green: 0.09, blue: 0.14))
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(Color.white.opacity(0.08)),
                alignment: .top
            )
        }
    }

    @ViewBuilder
    private func parameterRow(for param: ProgramParameter) -> some View {
        switch param.control {
        case .slider(let minVal, let maxVal, let step):
            let currentVal = viewModel.parameterValues[param.name] ?? param.defaultValue
            HStack(spacing: 10) {
                Text(param.label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 118, alignment: .leading)
                    .lineLimit(1)

                Slider(
                    value: Binding(
                        get: { currentVal },
                        set: { newVal in
                            if let s = step, s > 0 {
                                let snapped = (newVal / s).rounded() * s
                                viewModel.updateParameter(param.name, value: snapped)
                            } else {
                                viewModel.updateParameter(param.name, value: newVal)
                            }
                        }
                    ),
                    in: minVal...max(minVal + 0.001, maxVal)
                )
                .tint(Color(red: 0.0, green: 0.96, blue: 0.83))

                Text(formatParamValue(currentVal, step: step))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.35))
                    .frame(width: 48, alignment: .trailing)
            }

        case .color:
            let simdCol = viewModel.colorParameterValues[param.name] ?? param.defaultColor ?? SIMD4<Float>(0.1, 0.95, 0.85, 1.0)
            HStack {
                Text(param.label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
                ColorPicker(
                    "",
                    selection: Binding(
                        get: {
                            Color(
                                red: Double(simdCol.x),
                                green: Double(simdCol.y),
                                blue: Double(simdCol.z),
                                opacity: Double(simdCol.w)
                            )
                        },
                        set: { newCol in
                            if let cg = newCol.cgColor, let comps = cg.components, comps.count >= 3 {
                                let r = Float(comps[0])
                                let g = Float(comps[1])
                                let b = Float(comps[2])
                                let a = comps.count >= 4 ? Float(comps[3]) : 1.0
                                viewModel.updateColorParameter(param.name, color: SIMD4<Float>(r, g, b, a))
                            }
                        }
                    )
                )
                .labelsHidden()
            }

        case .toggle:
            let currentVal = (viewModel.parameterValues[param.name] ?? param.defaultValue) != 0
            Toggle(isOn: Binding(
                get: { currentVal },
                set: { viewModel.updateParameter(param.name, value: $0 ? 1.0 : 0.0) }
            )) {
                Text(param.label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
        }
    }

    private func formatParamValue(_ val: Double, step: Double?) -> String {
        if let s = step, s >= 1.0 && val.rounded() == val {
            return String(Int(val))
        }
        if abs(val - val.rounded()) < 0.005 {
            return String(Int(val.rounded()))
        }
        return String(format: "%.1f", val)
    }
}

// MARK: - Playback & Timeline Scrubber Transport Bar

public struct TransportBarView: View {
    @ObservedObject public var viewModel: IDEViewModel

    public var body: some View {
        HStack(spacing: 14) {
            // Mode Picker (Live 120Hz vs Turtle Crawl)
            Picker("", selection: $viewModel.executionMode) {
                ForEach(ExecutionMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 195)

            Divider().frame(height: 20)

            // Transport Buttons
            HStack(spacing: 6) {
                Button(action: { viewModel.startAnimatedCrawl() }) {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Restart animated turtle crawl from step 0")

                Button(action: { viewModel.stepBackward() }) {
                    Image(systemName: "backward.frame.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Step backward 1 turtle command")

                Button(action: { viewModel.togglePlayPause() }) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.0, green: 0.82, blue: 0.72))
                .controlSize(.small)
                .help(viewModel.isPlaying ? "Pause" : "Play")

                Button(action: { viewModel.stepForward() }) {
                    Image(systemName: "forward.frame.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Step forward 1 turtle command")
            }

            // Interactive Timeline Scrubber
            let totalSteps = max(1.0, Double(viewModel.scene.steps.count))
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: {
                            viewModel.executionMode == .live ? totalSteps : min(viewModel.stepCursor, totalSteps)
                        },
                        set: { newStep in
                            viewModel.scrub(to: newStep)
                        }
                    ),
                    in: 0...totalSteps
                )
                .tint(Color(red: 1.0, green: 0.45, blue: 0.78))

                let currentStepDisplay = viewModel.executionMode == .live ? viewModel.scene.steps.count : Int(viewModel.stepCursor)
                Text("\(currentStepDisplay) / \(viewModel.scene.steps.count) steps")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 115, alignment: .trailing)
            }

            Divider().frame(height: 20)

            // Speed Multiplier Menu
            Menu {
                ForEach([0.25, 0.5, 1.0, 2.0, 5.0, 15.0, 30.0], id: \.self) { spd in
                    Button("\(spd == floor(spd) ? String(Int(spd)) : String(spd))x Speed") {
                        viewModel.playbackSpeed = spd
                    }
                }
            } label: {
                Label("\(viewModel.playbackSpeed == floor(viewModel.playbackSpeed) ? String(Int(viewModel.playbackSpeed)) : String(viewModel.playbackSpeed))x", systemImage: "gauge.with.needle")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)
            .frame(width: 72)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .background(Color(red: 0.05, green: 0.06, blue: 0.11).opacity(0.88))
    }
}

// MARK: - Floating Canvas HUD & FX Inspector

public struct CanvasHUDView: View {
    @ObservedObject public var viewModel: IDEViewModel

    public var body: some View {
        VStack {
            // Top HUD bar over the Metal canvas
            HStack(spacing: 10) {
                // Telemetry Pill
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                        Text("\(viewModel.fps) FPS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    Text("•")
                        .foregroundStyle(.white.opacity(0.35))
                    Text("\(viewModel.scene.strokes.count) SDF strokes")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text("•")
                        .foregroundStyle(.white.opacity(0.35))
                    Text(String(format: "%.1f ms", viewModel.scene.executionTimeMs))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(red: 0.35, green: 0.95, blue: 0.85))
                }
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))

                Spacer()

                // Quick FX & Camera Controls
                HStack(spacing: 8) {
                    Toggle(isOn: $viewModel.showTurtleAvatar) {
                        Label("Turtle", systemImage: "tortoise.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .fixedSize()
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)

                    Toggle(isOn: $viewModel.showGrid) {
                        Label("Grid", systemImage: "grid")
                            .font(.system(size: 11, weight: .semibold))
                            .fixedSize()
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)

                    Menu {
                        Button("Program Default (\(viewModel.scene.backdrop.displayName))") {
                            viewModel.backdropOverride = nil
                        }
                        Divider()
                        ForEach(BackdropKind.allCases, id: \.rawValue) { bg in
                            Button(bg.displayName) {
                                viewModel.backdropOverride = bg
                            }
                        }
                    } label: {
                        Label("Backdrop", systemImage: "sparkles.rectangle.stack")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .controlSize(.small)
                    .frame(width: 98)

                    HStack(spacing: 4) {
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                        Slider(value: $viewModel.bloomIntensity, in: 0.0...2.2)
                            .frame(width: 68)
                    }
                    .help("HDR Bloom Intensity")

                    Button(action: { viewModel.resetCamera() }) {
                        Image(systemName: "viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reset Camera Zoom & Pan (Double-click canvas for stardust burst!)")

                    Button(action: { viewModel.exportHighResArtwork() }) {
                        Label("Export 4K", systemImage: "camera.aperture")
                            .font(.system(size: 11, weight: .bold))
                            .fixedSize()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                }
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            }
            .padding(12)

            if let banner = viewModel.exportStatusBanner {
                Text(banner)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.green.opacity(0.85), in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()

            // Bottom subtle hint pill
            HStack {
                Spacer()
                Text("Tip: Option-drag any number in code to scrub live • Scroll/Pinch to Pan & Zoom • Double-click or Right-click canvas for particle ripples")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.35), in: Capsule())
                    .padding(.bottom, 8)
                Spacer()
            }
        }
    }
}

// MARK: - Interactive Quick Reference / Snippet Cheat Sheet

public struct CheatSheetView: View {
    @ObservedObject public var viewModel: IDEViewModel

    private let snippets: [(title: String, desc: String, code: String)] = [
        ("Forward & Turn", "Move turtle forward & rotate", "fd 80\nrt 60"),
        ("Arc & Circle", "Smooth curved SDF segments", "arc 60, 90\ncircle 40"),
        ("Polygon & Star", "Filled luminous shapes", "star 5, 65, 28"),
        ("Branch Block", "Save & pop turtle state for trees", "branch {\n    lt 30\n    fd 50\n}"),
        ("Spawn Turtle", "Spawn an independent sub-turtle", "spawn {\n    rt 45\n    brush \"electric\"\n    fd 120\n}"),
        ("Kaleidoscope", "N-fold rotational + mirror symmetry", "kaleidoscope 8, 1"),
        ("L-System", "Declarative fractal rewriting engine", "lsystem {\n    axiom: \"F\"\n    generations: 3\n    angle: 25\n    size: 12\n    rule \"F\" -> \"F[+F]F[-F]F\"\n}"),
        ("Brushes", "neon, laser, watercolor, calligraphy, rainbow, electric, stardust, ribbon", "brush \"electric\"\nglow 2.0"),
        ("Live Slider", "Auto-generates an IDE slider", "@param my_angle 45 0 180 1 \"Turn Angle\"")
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("TURTLETOY QUICK SNIPPETS (CLICK TO INSERT)", systemImage: "wand.and.stars")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.32))
                Spacer()
                Button(action: { viewModel.showCheatSheet = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(snippets, id: \.title) { item in
                        Button(action: { viewModel.insertSnippet(item.code) }) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text(item.desc)
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(red: 0.09, green: 0.10, blue: 0.16))
    }
}
