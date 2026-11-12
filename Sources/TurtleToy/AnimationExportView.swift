import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TurtleToyCore

// MARK: - Animation export UI: HUD button + options popover + progress / cancel

public enum AnimationExportSize: String, CaseIterable, Identifiable {
    case square480 = "480 × 480"
    case square720 = "720 × 720"
    case square1080 = "1080 × 1080"
    case hd720 = "1280 × 720"
    case hd1080 = "1920 × 1080"

    public var id: String { rawValue }

    public var pixels: (width: Int, height: Int) {
        switch self {
        case .square480: return (480, 480)
        case .square720: return (720, 720)
        case .square1080: return (1080, 1080)
        case .hd720: return (1280, 720)
        case .hd1080: return (1920, 1080)
        }
    }
}

/// Thread-safe flag polled by the exporter's background thread.
private final class ExportCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

@MainActor
public final class AnimationExportController: ObservableObject {
    // Options
    @Published public var mode: AnimationExportMode = .crawl
    @Published public var format: AnimationExportFormat = .mp4 {
        didSet {
            if format != oldValue, !fpsChoices.contains(fps) {
                fps = format == .gif ? 20 : 30
            }
        }
    }
    @Published public var size: AnimationExportSize = .square720
    @Published public var fps: Int = 30
    @Published public var durationSeconds: Double = 6.0

    // Progress
    @Published public private(set) var isExporting: Bool = false
    @Published public private(set) var framesDone: Int = 0
    @Published public private(set) var framesTotal: Int = 0
    @Published public private(set) var errorMessage: String? = nil

    private var cancellationFlag: ExportCancellationFlag?
    private var didSeedDefaults = false

    public init() {}

    /// GIF delays are whole centiseconds, so offer rates that divide 100 evenly.
    public var fpsChoices: [Int] {
        format == .gif ? [10, 20, 25, 50] : [24, 30, 60]
    }

    public var progressFraction: Double {
        framesTotal > 0 ? Double(framesDone) / Double(framesTotal) : 0.0
    }

    public var frameCount: Int {
        max(2, Int((durationSeconds * Double(fps)).rounded()))
    }

    public var gifTooLarge: Bool {
        format == .gif && AnimationExporter.gifExceedsBudget(width: size.pixels.width, height: size.pixels.height, frameCount: frameCount)
    }

    /// Picks a sensible mode and duration for the current sketch the first time the options open.
    public func seedDefaults(from viewModel: IDEViewModel) {
        if !viewModel.scene.usesTimeVariable {
            mode = .crawl
        }
        guard !didSeedDefaults else { return }
        didSeedDefaults = true
        mode = (viewModel.scene.usesTimeVariable && viewModel.executionMode == .live) ? .time : .crawl
        durationSeconds = suggestedDuration(for: mode, viewModel: viewModel)
    }

    /// Crawl: what the on-screen crawl would take at the current playback speed (clamped). Time loop: 6s.
    public func suggestedDuration(for mode: AnimationExportMode, viewModel: IDEViewModel) -> Double {
        guard mode == .crawl else { return 6.0 }
        let totalSteps = Double(viewModel.scene.steps.count)
        let stepsPerSecond = max(12.0, min(140.0, totalSteps * 0.25)) * max(0.05, viewModel.playbackSpeed)
        let natural = totalSteps / stepsPerSecond + 0.75
        return min(20.0, max(3.0, (natural * 2.0).rounded() / 2.0))
    }

    public func optionsSummary(for viewModel: IDEViewModel) -> String {
        switch mode {
        case .crawl:
            let hold = AnimationExportCLI.defaultHoldFrames(frameCount: frameCount, fps: fps)
            let drawSeconds = max(0.1, Double(frameCount - hold) / Double(fps))
            let rate = Double(viewModel.scene.steps.count) / drawSeconds
            return String(format: "%d frames • about %.0f steps/sec", frameCount, rate)
        case .time:
            return String(format: "%d frames • t runs 0 → %.1f", frameCount, durationSeconds)
        }
    }

    /// Asks where to save, then renders + encodes on a background thread using a separate renderer.
    public func chooseDestinationAndExport(viewModel: IDEViewModel) {
        guard !isExporting else { return }

        let savePanel = NSSavePanel()
        savePanel.title = "Export TurtleToy Animation"
        savePanel.allowedContentTypes = [format.contentType]
        let cleanTitle = viewModel.exportBaseName
        savePanel.nameFieldStringValue = "\(cleanTitle)_\(mode == .crawl ? "crawl" : "loop").\(format.fileExtension)"
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

        var request = AnimationExportRequest()
        request.mode = mode
        request.format = format
        request.width = size.pixels.width
        request.height = size.pixels.height
        request.fps = fps
        request.frameCount = frameCount
        request.holdFrames = mode == .crawl ? AnimationExportCLI.defaultHoldFrames(frameCount: frameCount, fps: fps) : 0
        request.source = viewModel.sourceCode
        request.parameterOverrides = viewModel.parameterValues
        request.colorOverrides = viewModel.colorParameterValues
        request.precompiledScene = mode == .crawl ? viewModel.scene : nil
        request.cameraPan = viewModel.cameraPan
        request.cameraZoom = viewModel.cameraZoom
        request.showGrid = viewModel.showGrid
        request.showTurtleAvatar = viewModel.showTurtleAvatar
        request.bloomIntensity = viewModel.bloomIntensity
        request.backdropOverride = viewModel.backdropOverride

        let flag = ExportCancellationFlag()
        cancellationFlag = flag
        isExporting = true
        errorMessage = nil
        framesDone = 0
        framesTotal = request.frameCount

        Task.detached(priority: .userInitiated) { [weak self, weak viewModel] in
            var failure: Error?
            do {
                try AnimationExporter.run(
                    request,
                    to: url,
                    progress: { done, total in
                        Task { @MainActor [weak self] in
                            guard let self, self.cancellationFlag === flag else { return }
                            self.framesDone = max(self.framesDone, done)
                            self.framesTotal = total
                        }
                    },
                    isCancelled: { flag.isCancelled }
                )
            } catch {
                failure = error
            }
            let outcome = failure
            await MainActor.run { [weak self, weak viewModel] in
                self?.finish(flag: flag, url: url, failure: outcome, viewModel: viewModel)
            }
        }
    }

    public func cancel() {
        cancellationFlag?.cancel()
    }

    private func finish(flag: ExportCancellationFlag, url: URL, failure: Error?, viewModel: IDEViewModel?) {
        guard cancellationFlag === flag else { return }
        cancellationFlag = nil
        isExporting = false

        let banner: String
        if let failure {
            if case AnimationExportError.cancelled = failure {
                banner = "Animation export cancelled"
            } else {
                errorMessage = failure.localizedDescription
                banner = "Failed to export animation"
            }
        } else {
            banner = "Saved \(framesTotal)-frame \(format.rawValue.uppercased()) to \(url.lastPathComponent)"
        }

        guard let viewModel else { return }
        viewModel.exportStatusBanner = banner
        Task { @MainActor [weak viewModel] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if viewModel?.exportStatusBanner == banner {
                viewModel?.exportStatusBanner = nil
            }
        }
    }
}

/// Compact button for the canvas HUD, placed next to "Export 4K".
public struct AnimationExportButton: View {
    @ObservedObject public var viewModel: IDEViewModel
    @StateObject private var controller = AnimationExportController()
    @State private var showOptions = false

    public init(viewModel: IDEViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Button(action: {
            controller.seedDefaults(from: viewModel)
            showOptions.toggle()
        }) {
            if controller.isExporting {
                Label("\(Int(controller.progressFraction * 100))%", systemImage: "film")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .fixedSize()
            } else {
                Image(systemName: "film")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
        .controlSize(.small)
        .help("Export animation (MP4 / GIF)")
        .popover(isPresented: $showOptions, arrowEdge: .bottom) {
            AnimationExportOptionsView(viewModel: viewModel, controller: controller)
        }
    }
}

struct AnimationExportOptionsView: View {
    @ObservedObject var viewModel: IDEViewModel
    @ObservedObject var controller: AnimationExportController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Animation")
                .font(.system(size: 13, weight: .bold, design: .rounded))

            if controller.isExporting {
                progressSection
            } else {
                optionsSection
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Animation", selection: $controller.mode) {
                Text("Turtle Crawl").tag(AnimationExportMode.crawl)
                Text("Time Loop (t)").tag(AnimationExportMode.time)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!viewModel.scene.usesTimeVariable)
            .help(viewModel.scene.usesTimeVariable
                  ? "Crawl reveals the drawing step by step; Time Loop re-runs the sketch with an advancing t"
                  : "This sketch does not read t, so only the Turtle Crawl can be exported")
            .onChange(of: controller.mode) { _, newMode in
                controller.durationSeconds = controller.suggestedDuration(for: newMode, viewModel: viewModel)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Format")
                    Picker("Format", selection: $controller.format) {
                        Text("MP4 (H.264)").tag(AnimationExportFormat.mp4)
                        Text("GIF").tag(AnimationExportFormat.gif)
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Size")
                    Picker("Size", selection: $controller.size) {
                        ForEach(AnimationExportSize.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Frame rate")
                    Picker("Frame rate", selection: $controller.fps) {
                        ForEach(controller.fpsChoices, id: \.self) { value in
                            Text("\(value) fps").tag(value)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Duration")
                    HStack(spacing: 6) {
                        Slider(value: $controller.durationSeconds, in: 1.0...30.0, step: 0.5)
                        Text(String(format: "%.1fs", controller.durationSeconds))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            .font(.system(size: 11.5))

            Text(controller.optionsSummary(for: viewModel))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)

            if controller.gifTooLarge {
                Text("Too large for a GIF. Use MP4, or pick a smaller size, lower frame rate or shorter duration.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = controller.errorMessage {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Export…") {
                    controller.chooseDestinationAndExport(viewModel: viewModel)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .keyboardShortcut(.defaultAction)
                .disabled(controller.gifTooLarge)
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: controller.progressFraction)
            Text("Rendering frame \(controller.framesDone) of \(controller.framesTotal)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    controller.cancel()
                }
            }
        }
    }
}
