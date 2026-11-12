import SwiftUI
import AppKit
import TurtleToyCore

public struct MainIDEView: View {
    @StateObject private var viewModel = IDEViewModel()

    public init() {}

    public var body: some View {
        HSplitView {
            // LEFT PANE: Preset Gallery + Code Editor + Cheat Sheet + Live @param Deck
            VStack(spacing: 0) {
                topEditorHeader
                presetCarouselStrip

                if viewModel.showCheatSheet {
                    CheatSheetView(viewModel: viewModel)
                }

                // Native Scrubbable Syntax-Highlighted Editor
                ZStack(alignment: .bottom) {
                    CodeEditorView(
                        text: $viewModel.sourceCode,
                        activeLine: viewModel.activeSourceLine,
                        diagnostics: viewModel.scene.diagnostics
                    )

                    if !viewModel.scene.diagnostics.isEmpty {
                        diagnosticsOverlay
                    }
                }

                // Auto-Generated Interactive Sliders & Color Pickers from `@param`
                ParameterDeckView(viewModel: viewModel)
            }
            .frame(minWidth: 420, idealWidth: 490, maxWidth: 640)
            .background(Color(red: 0.055, green: 0.062, blue: 0.10))

            // RIGHT PANE: 120Hz Metal HDR SDF Canvas + HUD + Playback Scrubber Bar
            VStack(spacing: 0) {
                ZStack {
                    MetalCanvasView(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    CanvasHUDView(viewModel: viewModel)
                }

                TransportBarView(viewModel: viewModel)
            }
            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    private var topEditorHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "tortoise.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.0, green: 0.96, blue: 0.83), Color(red: 1.0, green: 0.42, blue: 0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("TurtleToy")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("METAL 2D SDF STUDIO")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1), in: Capsule())
                    .foregroundStyle(Color(red: 0.45, green: 0.92, blue: 1.0))
            }

            Spacer()

            Button(action: { viewModel.showCheatSheet.toggle() }) {
                Label("Snippets", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: { viewModel.startAnimatedCrawl() }) {
                Label("Watch Crawl", systemImage: "figure.walk.motion")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.95, green: 0.35, blue: 0.68))
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.07, green: 0.08, blue: 0.13))
    }

    private var presetCarouselStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PresetGallery.all) { preset in
                    let isSelected = preset.id == viewModel.selectedPreset.id
                    Button(action: { viewModel.selectPreset(preset) }) {
                        HStack(spacing: 7) {
                            Image(systemName: preset.iconName)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(isSelected ? .white : Color(red: 0.25, green: 0.95, blue: 0.85))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.title)
                                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text(preset.badge)
                                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.68))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(
                                    isSelected
                                        ? LinearGradient(
                                            colors: [Color(red: 0.15, green: 0.55, blue: 0.72), Color(red: 0.45, green: 0.22, blue: 0.68)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                        : LinearGradient(
                                            colors: [Color.white.opacity(0.06), Color.white.opacity(0.04)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(isSelected ? Color(red: 0.25, green: 0.95, blue: 0.85) : Color.white.opacity(0.1), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(red: 0.065, green: 0.072, blue: 0.115))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.white.opacity(0.08)),
            alignment: .bottom
        )
    }

    private var diagnosticsOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewModel.scene.diagnostics.prefix(3)) { diag in
                HStack(spacing: 6) {
                    Image(systemName: diag.severity == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(diag.severity == .error ? Color.red : Color.yellow)
                    Text("Line \(diag.line): \(diag.message)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(Color(red: 0.22, green: 0.06, blue: 0.10).opacity(0.94))
    }
}

// MARK: - Pure SwiftUI IDE Snapshot Renderer (For Documentation / README Screenshot)

public struct IDESnapshotCompositeView: View {
    @ObservedObject public var viewModel: IDEViewModel
    public var metalSnapshot: NSImage?
    public var stepProgressFraction: Double = 0.92

    public var body: some View {
        VStack(spacing: 0) {
            // Fake macOS Dark Window Titlebar for authentic full-window presentation
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 0.15, green: 0.78, blue: 0.25)).frame(width: 12, height: 12)
                }
                .padding(.leading, 14)

                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "tortoise.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.0, green: 0.96, blue: 0.83))
                    Text("TurtleToy — Whimsical Metal 2D SDF Toy IDE")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Spacer().frame(width: 60)
            }
            .frame(height: 32)
            .background(Color(red: 0.08, green: 0.09, blue: 0.14))
            .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1), alignment: .bottom)

            HStack(spacing: 0) {
                // LEFT PANE (530px)
                VStack(spacing: 0) {
                    // Header
                    HStack(spacing: 10) {
                        HStack(spacing: 7) {
                            Image(systemName: "tortoise.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [Color(red: 0.0, green: 0.96, blue: 0.83), Color(red: 1.0, green: 0.42, blue: 0.78)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Text("TurtleToy")
                                .font(.system(size: 15, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                            Text("METAL 2D SDF STUDIO")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.1), in: Capsule())
                                .foregroundStyle(Color(red: 0.45, green: 0.92, blue: 1.0))
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text("Snippets")
                        }
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.white)

                        HStack(spacing: 4) {
                            Image(systemName: "figure.walk.motion")
                            Text("Watch Crawl")
                        }
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.95, green: 0.35, blue: 0.68), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(red: 0.07, green: 0.08, blue: 0.13))

                    // Preset Strip
                    HStack(spacing: 8) {
                        ForEach(PresetGallery.all.prefix(3)) { preset in
                            let isSelected = preset.id == viewModel.selectedPreset.id
                            HStack(spacing: 7) {
                                Image(systemName: preset.iconName)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(isSelected ? .white : Color(red: 0.25, green: 0.95, blue: 0.85))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(preset.title)
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(preset.badge)
                                        .font(.system(size: 9, weight: .medium, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.68))
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(
                                        isSelected
                                            ? LinearGradient(
                                                colors: [Color(red: 0.15, green: 0.55, blue: 0.72), Color(red: 0.45, green: 0.22, blue: 0.68)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                            : LinearGradient(
                                                colors: [Color.white.opacity(0.06), Color.white.opacity(0.04)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isSelected ? Color(red: 0.25, green: 0.95, blue: 0.85) : Color.white.opacity(0.1), lineWidth: 1)
                            )
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(red: 0.065, green: 0.072, blue: 0.115))
                    .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1), alignment: .bottom)

                    // Syntax-Highlighted Code Listing with Line Numbers & Active Step Highlight
                    VStack(alignment: .leading, spacing: 1.5) {
                        let lines = viewModel.sourceCode.components(separatedBy: "\n").prefix(29)
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, lineText in
                            let lineNum = idx + 1
                            let isActive = (lineNum == viewModel.activeSourceLine)
                            HStack(spacing: 10) {
                                Text(String(format: "%2d", lineNum))
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(isActive ? Color(red: 0.0, green: 0.96, blue: 0.83) : .white.opacity(0.28))
                                    .frame(width: 22, alignment: .trailing)

                                syntaxColoredLine(lineText)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                            .background(isActive ? Color(red: 0.0, green: 0.96, blue: 0.83).opacity(0.18) : Color.clear)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.055, green: 0.062, blue: 0.10))

                    // Pure SwiftUI Parameter Deck
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("LIVE PARAMETERS", systemImage: "slider.horizontal.3")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 0.25, green: 0.95, blue: 0.85))
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "dice.fill")
                                Text("Surprise Me")
                            }
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.purple.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(.white)

                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10.5, weight: .semibold))
                                .padding(4)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                                .foregroundStyle(.white)
                        }

                        drawSliderRow(label: "Symmetry Fold", valueText: "12", progress: 0.40)
                        drawSliderRow(label: "Petal Radius", valueText: "210", progress: 0.58)
                        drawSliderRow(label: "Spiral Curl", valueText: "108", progress: 0.54)
                        drawSliderRow(label: "Neon Intensity", valueText: "1.3", progress: 0.39)

                        HStack {
                            Text("Inner Core Color")
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.88))
                            Spacer()
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(red: 0.0, green: 0.96, blue: 0.83))
                                .frame(width: 42, height: 18)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.4), lineWidth: 1))
                        }
                    }
                    .padding(12)
                    .background(Color(red: 0.08, green: 0.09, blue: 0.14))
                    .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1), alignment: .top)
                }
                .frame(width: 530)
                .background(Color(red: 0.055, green: 0.062, blue: 0.10))

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1)

                // RIGHT PANE (829px)
                VStack(spacing: 0) {
                    ZStack {
                        if let img = metalSnapshot {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 829, height: 760)
                                .clipped()
                        }

                        // Pure SwiftUI Top & Bottom Canvas HUD
                        VStack {
                            HStack(spacing: 10) {
                                HStack(spacing: 8) {
                                    Circle().fill(Color.green).frame(width: 7, height: 7)
                                    Text("120 FPS")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    Text("•").foregroundStyle(.white.opacity(0.35))
                                    Text("\(viewModel.scene.strokes.count) SDF strokes")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    Text("•").foregroundStyle(.white.opacity(0.35))
                                    Text("0.5 ms")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Color(red: 0.35, green: 0.95, blue: 0.85))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(red: 0.07, green: 0.08, blue: 0.14).opacity(0.86), in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))

                                Spacer()

                                HStack(spacing: 6) {
                                    hudPill(icon: "tortoise.fill", text: "Turtle", active: true)
                                    hudPill(icon: "grid", text: "Grid", active: false)
                                    hudPill(icon: "sparkles.rectangle.stack", text: "Void", active: false)
                                    HStack(spacing: 4) {
                                        Image(systemName: "sun.max.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.yellow)
                                        miniProgressTrack(progress: 0.55, width: 48, color: .yellow)
                                    }
                                    HStack(spacing: 4) {
                                        Image(systemName: "camera.aperture")
                                        Text("Export 4K")
                                    }
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    .fixedSize()
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Color.purple, in: Capsule())
                                    .foregroundStyle(.white)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color(red: 0.07, green: 0.08, blue: 0.14).opacity(0.86), in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
                            }
                            .padding(12)

                            Spacer()

                            Text("Tip: Option-drag any number in code to scrub live • Scroll/Pinch to Pan & Zoom • Double-click canvas for particle ripples")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.65))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.45), in: Capsule())
                                .padding(.bottom, 8)
                        }
                    }
                    .frame(width: 829, height: 760)

                    // Pure SwiftUI Transport Bar
                    HStack(spacing: 14) {
                        HStack(spacing: 0) {
                            Text("Live 120Hz")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.65))
                                .frame(width: 92, height: 22)
                            Text("Turtle Crawl")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 96, height: 22)
                                .background(Color(red: 0.22, green: 0.25, blue: 0.36), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .padding(2)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))

                        HStack(spacing: 6) {
                            transportButton(icon: "backward.end.fill", prominent: false)
                            transportButton(icon: "backward.frame.fill", prominent: false)
                            transportButton(icon: "pause.fill", prominent: true)
                            transportButton(icon: "forward.frame.fill", prominent: false)
                        }

                        miniProgressTrack(progress: stepProgressFraction, width: 280, color: Color(red: 1.0, green: 0.45, blue: 0.78))

                        let totalSteps = viewModel.scene.steps.count
                        let curStep = Int(Double(totalSteps) * stepProgressFraction)
                        Text("\(curStep) / \(totalSteps) steps")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8))
                            .fixedSize()

                        Spacer()

                        HStack(spacing: 4) {
                            Image(systemName: "gauge.with.needle")
                            Text("2x")
                        }
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(Color(red: 0.06, green: 0.07, blue: 0.12))
                    .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1), alignment: .top)
                }
                .frame(width: 829)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.18), lineWidth: 1))
    }

    private func drawSliderRow(label: String, valueText: String, progress: Double) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 115, alignment: .leading)

            miniProgressTrack(progress: progress, width: 315, color: Color(red: 0.0, green: 0.96, blue: 0.83))

            Text(valueText)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.35))
                .frame(width: 45, alignment: .trailing)
        }
    }

    private func miniProgressTrack(progress: Double, width: CGFloat, color: Color) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.14))
                .frame(width: width, height: 5)
            Capsule()
                .fill(color)
                .frame(width: max(8, width * CGFloat(progress)), height: 5)
            Circle()
                .fill(Color.white)
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                .offset(x: max(0, min(width - 13, width * CGFloat(progress) - 6.5)))
        }
        .frame(width: width, height: 14)
    }

    private func hudPill(icon: String, text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(active ? Color(red: 0.0, green: 0.82, blue: 0.72).opacity(0.35) : Color.white.opacity(0.08), in: Capsule())
        .foregroundStyle(active ? Color(red: 0.25, green: 0.98, blue: 0.88) : .white.opacity(0.8))
    }

    private func transportButton(icon: String, prominent: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 11, weight: .bold))
            .frame(width: 26, height: 22)
            .background(
                prominent ? Color(red: 0.0, green: 0.82, blue: 0.72) : Color.white.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .foregroundStyle(.white)
    }

    private func syntaxColoredLine(_ line: String) -> Text {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") {
            return Text(line)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(red: 0.45, green: 0.52, blue: 0.66))
        }
        if trimmed.hasPrefix("@param") {
            return Text(line)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.35, green: 0.82, blue: 1.0))
        }
        if trimmed.hasPrefix("for ") || trimmed.hasPrefix("let ") || trimmed == "}" {
            return Text(line)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 1.0, green: 0.44, blue: 0.78))
        }
        if trimmed.hasPrefix("backdrop") || trimmed.hasPrefix("kaleidoscope") || trimmed.hasPrefix("glow") || trimmed.hasPrefix("color") || trimmed.hasPrefix("brush") || trimmed.hasPrefix("width") || trimmed.hasPrefix("palette") || trimmed.hasPrefix("sparkle") {
            return Text(line)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(red: 0.72, green: 0.52, blue: 1.0))
        }
        return Text(line)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color(red: 0.15, green: 0.95, blue: 0.85))
    }
}

// MARK: - Application Entry Point & Headless Self-Test CLI Support

@main
public struct TurtleToyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    public init() {
        // Support `--render-showcase <outputDir>` for automated headless verification & gallery export!
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--render-showcase"), idx + 1 < args.count {
            let outDir = URL(fileURLWithPath: args[idx + 1])
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            guard let renderer = MetalRenderer() else {
                print("Failed to initialize MetalRenderer")
                exit(1)
            }
            for preset in PresetGallery.all {
                let scene = Interpreter.compileAndRun(source: preset.code, timeSeconds: 1.25)
                renderer.scene = scene
                renderer.isLiveMode = true
                let fileURL = outDir.appendingPathComponent("\(preset.id).png")
                let ok = renderer.exportHighResPNG(to: fileURL, size: 1024)
                print("Rendered \(preset.id): \(ok ? "OK" : "FAILED") (\(scene.strokes.count) strokes) -> \(fileURL.path)")
            }
            exit(0)
        }

        // Support `--render-crawl-frames <presetId> <outputDir> <frameCount>` for animated GIF/MP4 generation!
        if let idx = args.firstIndex(of: "--render-crawl-frames"), idx + 3 < args.count {
            let presetId = args[idx + 1]
            let outDir = URL(fileURLWithPath: args[idx + 2])
            let frameCount = max(10, Int(args[idx + 3]) ?? 72)
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            guard let renderer = MetalRenderer(),
                  let preset = PresetGallery.all.first(where: { $0.id == presetId }) ?? PresetGallery.all.first else {
                exit(1)
            }
            let scene = Interpreter.compileAndRun(source: preset.code, timeSeconds: 0.6)
            renderer.scene = scene
            renderer.isLiveMode = false
            renderer.showTurtleAvatar = true
            renderer.resetParticlesTracker()

            let totalSteps = Double(max(1, scene.steps.count))
            for f in 0..<frameCount {
                let progress = Double(f) / Double(frameCount - 12) // Hold completed frame for last 12 frames
                renderer.playbackStepCursor = min(totalSteps, max(0.0, progress * totalSteps))
                renderer.stepSimulationForExport(dt: 1.0 / 30.0)
                let frameFile = outDir.appendingPathComponent(String(format: "frame_%03d.png", f))
                _ = renderer.exportHighResPNG(to: frameFile, size: 720, drawAvatar: f < frameCount - 8, explicitTime: Float(f) * (1.0 / 30.0))
            }
            print("Rendered \(frameCount) crawl frames for \(preset.id) -> \(outDir.path)")
            exit(0)
        }
    }

    public var body: some Scene {
        WindowGroup("TurtleToy — Whimsical Metal 2D SDF Toy IDE") {
            MainIDEView()
                .frame(minWidth: 1080, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--capture-ide-screenshot"), idx + 1 < args.count {
            let outPath = args[idx + 1]
            let viewModel = IDEViewModel()
            viewModel.showCheatSheet = false
            // Set cursor near 99.6% of crawl so the full outer lotus & stardust ring are drawn AND the Cyber-Turtle is visible on the outer ring!
            viewModel.executionMode = .animated
            viewModel.isPlaying = false
            viewModel.stepCursor = Double(viewModel.scene.steps.count) * 0.996
            viewModel.activeSourceLine = 26
            viewModel.syncRendererPlaybackMode()

            if let renderer = viewModel.renderer {
                renderer.triggerBurst(at: SIMD2<Float>(95, 115), color: SIMD4<Float>(1.0, 0.82, 0.35, 1.0), count: 28, size: 8.0, speed: 95.0, kind: 1)
                renderer.stepSimulationForExport(dt: 0.1)
                let metalImg = renderer.renderSnapshotImage(
                    width: 829 * 2,
                    height: 760 * 2,
                    logicalSize: SIMD2<Float>(660, 605),
                    drawAvatar: true
                )

                let snapshotView = IDESnapshotCompositeView(
                    viewModel: viewModel,
                    metalSnapshot: metalImg,
                    stepProgressFraction: 0.96
                )
                .frame(width: 1360, height: 840)
                .environment(\.colorScheme, .dark)

                let imageRenderer = ImageRenderer(content: snapshotView)
                imageRenderer.scale = 2.0
                if let cgImage = imageRenderer.cgImage {
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    if let pngData = rep.representation(using: .png, properties: [:]) {
                        try? pngData.write(to: URL(fileURLWithPath: outPath))
                        print("Saved full IDE screenshot -> \(outPath)")
                    }
                }
            }
            exit(0)
        }

        if let idx = args.firstIndex(of: "--render-ide-frames"), idx + 2 < args.count {
            let outDir = URL(fileURLWithPath: args[idx + 1])
            let frameCount = max(12, Int(args[idx + 2]) ?? 60)
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            let viewModel = IDEViewModel()
            viewModel.executionMode = .animated
            viewModel.isPlaying = false
            guard let renderer = viewModel.renderer else { exit(1) }
            renderer.resetParticlesTracker()

            // Collect non-empty stroke step indices so every frame advances visible geometry!
            let drawingStepIndices = viewModel.scene.steps.enumerated().compactMap { idx, step in
                step.strokeRange.isEmpty && step.fillVertexRange.isEmpty ? nil : idx
            }
            let totalSteps = Double(max(1, viewModel.scene.steps.count))

            for f in 0..<frameCount {
                let frac = min(1.0, Double(f) / Double(frameCount - 10))
                let drawIdx = min(drawingStepIndices.count - 1, Int(frac * Double(max(1, drawingStepIndices.count - 1))))
                let actualStep = frac >= 1.0 ? viewModel.scene.steps.count : drawingStepIndices[max(0, drawIdx)]
                viewModel.stepCursor = Double(actualStep) + 0.85
                let stepIdx = max(0, min(viewModel.scene.steps.count - 1, actualStep))
                viewModel.activeSourceLine = frac < 1.0 ? viewModel.scene.steps[stepIdx].sourceLine : nil
                viewModel.syncRendererPlaybackMode()

                renderer.stepSimulationForExport(dt: 1.0 / 24.0)
                let metalImg = renderer.renderSnapshotImage(
                    width: 829,
                    height: 760,
                    logicalSize: SIMD2<Float>(660, 605),
                    drawAvatar: frac < 0.99
                )

                let snapshotView = IDESnapshotCompositeView(
                    viewModel: viewModel,
                    metalSnapshot: metalImg,
                    stepProgressFraction: min(1.0, Double(actualStep) / totalSteps)
                )
                .frame(width: 1360, height: 840)
                .environment(\.colorScheme, .dark)

                let imageRenderer = ImageRenderer(content: snapshotView)
                imageRenderer.scale = 1.0
                if let cgImage = imageRenderer.cgImage {
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    if let pngData = rep.representation(using: .png, properties: [:]) {
                        let fileURL = outDir.appendingPathComponent(String(format: "ide_%03d.png", f))
                        try? pngData.write(to: fileURL)
                    }
                }
            }
            print("Rendered \(frameCount) full IDE animation frames -> \(outDir.path)")
            exit(0)
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
