import Foundation
import SwiftUI
import AppKit
import simd
import UniformTypeIdentifiers
import TurtleToyCore

public enum ExecutionMode: String, CaseIterable, Identifiable {
    case live = "Live 120Hz"
    case animated = "Turtle Crawl"

    public var id: String { rawValue }
}

@MainActor
public final class IDEViewModel: ObservableObject {
    @Published public var selectedPreset: PresetProgram
    /// Identity + saved baseline of the editor contents (preset, untitled, or a `.turtle` file). See SketchDocumentSupport.swift.
    @Published public var document: SketchDocumentState = .preset(PresetGallery.all[0])
    @Published public var sourceCode: String {
        didSet {
            if sourceCode != oldValue {
                compileProgram(resetAnimationIfNeeded: false)
            }
        }
    }

    @Published public var scene: TurtleScene = TurtleScene()
    @Published public var parameterValues: [String: Double] = [:]
    @Published public var colorParameterValues: [String: SIMD4<Float>] = [:]

    // Execution & Playback state
    @Published public var executionMode: ExecutionMode = .live {
        didSet {
            syncRendererPlaybackMode()
        }
    }
    @Published public var isPlaying: Bool = true
    @Published public var playbackSpeed: Double = 1.0 // 0.25x .. 30x
    @Published public var stepCursor: Double = 0.0    // 0 .. totalSteps
    @Published public var activeSourceLine: Int? = nil
    @Published public var animateTimeInLiveMode: Bool = true

    // Canvas & FX Controls
    @Published public var showGrid: Bool = false {
        didSet { renderer?.showGrid = showGrid }
    }
    @Published public var showTurtleAvatar: Bool = true {
        didSet { renderer?.showTurtleAvatar = showTurtleAvatar }
    }
    @Published public var bloomIntensity: Float = 0.85 {
        didSet { renderer?.bloomIntensity = bloomIntensity }
    }
    @Published public var backdropOverride: BackdropKind? = nil {
        didSet { renderer?.backdropOverride = backdropOverride }
    }
    @Published public var cameraZoom: Float = 1.0 {
        didSet { renderer?.cameraZoom = cameraZoom }
    }
    @Published public var cameraPan: SIMD2<Float> = .zero {
        didSet { renderer?.cameraPan = cameraPan }
    }

    // Telemetry & UI Drawer states
    @Published public var fps: Int = 120
    @Published public var showCheatSheet: Bool = false
    @Published public var exportStatusBanner: String? = nil

    public var renderer: MetalRenderer?
    private var liveTimeAccumulator: Double = 0.0
    private var fpsUpdateCounter: Int = 0

    public init() {
        let initialPreset = PresetGallery.all[0]
        self.selectedPreset = initialPreset
        self.sourceCode = initialPreset.code
        self.renderer = MetalRenderer()
        setupRendererCallbacks()
        compileProgram(resetAnimationIfNeeded: true)
        restoreLastSession()

        if CommandLine.arguments.contains("--auto-crawl") {
            self.playbackSpeed = 1.65
            self.startAnimatedCrawl()
        }
    }

    private func setupRendererCallbacks() {
        guard let renderer else { return }
        renderer.onFrameTick = { [weak self] dt, _ in
            Task { @MainActor [weak self] in
                self?.handleFrameTick(dt: dt)
            }
        }
    }

    private func handleFrameTick(dt: Double) {
        guard let renderer else { return }

        fpsUpdateCounter += 1
        if fpsUpdateCounter >= 15 {
            fpsUpdateCounter = 0
            fps = min(120, max(1, Int(renderer.currentFPS.rounded())))
        }

        if executionMode == .live {
            if animateTimeInLiveMode && scene.usesTimeVariable && isPlaying {
                liveTimeAccumulator += dt * playbackSpeed
                let updated = Interpreter.compileAndRun(
                    source: sourceCode,
                    parameterOverrides: parameterValues,
                    colorOverrides: colorParameterValues,
                    timeSeconds: liveTimeAccumulator
                )
                self.scene = updated
                renderer.scene = updated
            }
            activeSourceLine = nil
        } else {
            // Animated Turtle Crawl mode
            let totalSteps = Double(scene.steps.count)
            if isPlaying && totalSteps > 0 {
                // Base rate: ~28 steps/sec scaled by playbackSpeed and program size
                let adaptiveBase = max(12.0, min(140.0, totalSteps * 0.25))
                let deltaSteps = dt * adaptiveBase * playbackSpeed
                if stepCursor < totalSteps {
                    stepCursor = min(totalSteps, stepCursor + deltaSteps)
                } else {
                    isPlaying = false
                }
            }
            renderer.playbackStepCursor = stepCursor
            let idx = max(0, min(scene.steps.count - 1, Int(stepCursor)))
            if !scene.steps.isEmpty && stepCursor < totalSteps {
                activeSourceLine = scene.steps[idx].sourceLine
            } else {
                activeSourceLine = nil
            }
        }
    }

    public func selectPreset(_ preset: PresetProgram) {
        selectedPreset = preset
        document = .preset(preset)
        parameterValues.removeAll()
        colorParameterValues.removeAll()
        backdropOverride = nil
        sourceCode = preset.code
        compileProgram(resetAnimationIfNeeded: true)

        if let renderer {
            renderer.triggerRipple(at: .zero, maxRadius: 260.0)
            renderer.triggerBurst(at: .zero, color: SIMD4<Float>(0.2, 0.95, 0.85, 1.0), count: 32, size: 9.0, speed: 120.0, kind: 1)
        }
    }

    public func compileProgram(resetAnimationIfNeeded: Bool) {
        let compiled = Interpreter.compileAndRun(
            source: sourceCode,
            parameterOverrides: parameterValues,
            colorOverrides: colorParameterValues,
            timeSeconds: liveTimeAccumulator
        )

        // Populate default parameter values for newly discovered `@param` declarations
        var updatedNumParams = parameterValues
        var updatedColParams = colorParameterValues
        for p in compiled.parameters {
            if p.control == .color {
                if updatedColParams[p.name] == nil {
                    updatedColParams[p.name] = p.defaultColor ?? SIMD4<Float>(0.1, 0.95, 0.85, 1.0)
                }
            } else {
                if updatedNumParams[p.name] == nil {
                    updatedNumParams[p.name] = p.defaultValue
                }
            }
        }
        parameterValues = updatedNumParams
        colorParameterValues = updatedColParams

        self.scene = compiled
        renderer?.scene = compiled

        let total = Double(compiled.steps.count)
        if resetAnimationIfNeeded {
            if executionMode == .animated {
                stepCursor = 0.0
                isPlaying = true
                renderer?.resetParticlesTracker()
            } else {
                stepCursor = total
            }
        } else {
            if executionMode == .animated {
                stepCursor = min(stepCursor, total)
            } else {
                stepCursor = total
            }
        }
        syncRendererPlaybackMode()
    }

    public func updateParameter(_ name: String, value: Double) {
        parameterValues[name] = value
        compileProgram(resetAnimationIfNeeded: false)
    }

    public func updateColorParameter(_ name: String, color: SIMD4<Float>) {
        colorParameterValues[name] = color
        compileProgram(resetAnimationIfNeeded: false)
    }

    public func resetParametersToDefaults() {
        for p in scene.parameters {
            if p.control == .color {
                colorParameterValues[p.name] = p.defaultColor ?? SIMD4<Float>(0.1, 0.95, 0.85, 1.0)
            } else {
                parameterValues[p.name] = p.defaultValue
            }
        }
        compileProgram(resetAnimationIfNeeded: false)
    }

    public func randomizeParameters() {
        for p in scene.parameters {
            switch p.control {
            case .slider(let minVal, let maxVal, let step):
                var r = Double.random(in: minVal...maxVal)
                if let s = step, s > 0 {
                    r = (r / s).rounded() * s
                } else {
                    r = (r * 10.0).rounded() / 10.0
                }
                parameterValues[p.name] = r
            case .color:
                colorParameterValues[p.name] = ColorUtils.hsl(Double.random(in: 0...360), 90, 62, 1.0)
            case .toggle:
                parameterValues[p.name] = Bool.random() ? 1.0 : 0.0
            }
        }
        compileProgram(resetAnimationIfNeeded: false)
        renderer?.triggerBurst(at: .zero, color: SIMD4<Float>(1.0, 0.75, 0.2, 1.0), count: 36, size: 10.0, speed: 130.0, kind: 1)
    }

    // MARK: - Playback Transport Actions

    public func syncRendererPlaybackMode() {
        guard let renderer else { return }
        renderer.isLiveMode = (executionMode == .live)
        renderer.playbackStepCursor = stepCursor
    }

    public func startAnimatedCrawl() {
        executionMode = .animated
        stepCursor = 0.0
        isPlaying = true
        renderer?.resetParticlesTracker()
        syncRendererPlaybackMode()
    }

    public func togglePlayPause() {
        if executionMode == .live {
            if !scene.usesTimeVariable {
                // Switching to animated crawl when user presses Play on a static sketch!
                startAnimatedCrawl()
                return
            }
            isPlaying.toggle()
        } else {
            if stepCursor >= Double(scene.steps.count) {
                stepCursor = 0.0
                renderer?.resetParticlesTracker()
            }
            isPlaying.toggle()
        }
    }

    public func stepForward() {
        executionMode = .animated
        isPlaying = false
        let total = Double(scene.steps.count)
        stepCursor = min(total, floor(stepCursor) + 1.0)
        syncRendererPlaybackMode()
    }

    public func stepBackward() {
        executionMode = .animated
        isPlaying = false
        stepCursor = max(0.0, ceil(stepCursor) - 1.0)
        syncRendererPlaybackMode()
    }

    public func scrub(to step: Double) {
        if executionMode == .live {
            executionMode = .animated
        }
        isPlaying = false
        stepCursor = max(0.0, min(Double(scene.steps.count), step))
        syncRendererPlaybackMode()
    }

    public func resetCamera() {
        cameraPan = .zero
        cameraZoom = 1.0
        renderer?.triggerRipple(at: .zero, maxRadius: 180.0)
    }

    public func insertSnippet(_ snippet: String) {
        if sourceCode.hasSuffix("\n") {
            sourceCode += snippet + "\n"
        } else {
            sourceCode += "\n" + snippet + "\n"
        }
    }

    // MARK: - Export 4K PNG

    public func exportHighResArtwork() {
        guard let renderer else { return }
        let savePanel = NSSavePanel()
        savePanel.title = "Export 4K HDR TurtleToy Artwork"
        savePanel.allowedContentTypes = [.png]
        let cleanTitle = exportBaseName
        savePanel.nameFieldStringValue = "\(cleanTitle)_4k.png"

        if savePanel.runModal() == .OK, let url = savePanel.url {
            let ok = renderer.exportHighResPNG(to: url, size: 3072, sourceText: sourceCode)
            exportStatusBanner = ok ? "Saved 3072×3072 PNG to \(url.lastPathComponent)" : "Failed to export PNG"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if self.exportStatusBanner != nil {
                    self.exportStatusBanner = nil
                }
            }
        }
    }
}
