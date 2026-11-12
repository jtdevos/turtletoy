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
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
