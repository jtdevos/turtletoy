import Foundation
import Metal
import MetalKit
import AppKit
import ImageIO
import UniformTypeIdentifiers
import simd
import TurtleToyCore

// Matches `FrameUniforms` in MetalShaderSource.swift
public struct FrameUniformsGPU {
    public var viewportSize: SIMD2<Float> = SIMD2<Float>(1000, 800)
    public var cameraPan: SIMD2<Float> = .zero
    public var cameraZoom: Float = 1.0
    public var time: Float = 0.0
    public var backdropKind: UInt32 = 0
    public var showGrid: UInt32 = 0
    public var bloomIntensity: Float = 0.85
    public var partialStepFraction: Float = 1.0
    public var activeStepIndex: UInt32 = 0
    public var isAnimatingStep: UInt32 = 0
    public var ripple0: SIMD4<Float> = .zero
    public var ripple1: SIMD4<Float> = .zero
    public var ripple2: SIMD4<Float> = .zero
    public var ripple3: SIMD4<Float> = .zero
}

public struct TurtleAvatarUniformsGPU {
    public var position: SIMD2<Float>
    public var headingRadians: Float
    public var scale: Float
    public var penColor: SIMD4<Float>
    public var penDown: UInt32
    public var brushKind: UInt32
    public var time: Float
    public var pad: Float = 0.0
}

private struct ActiveRipple {
    var position: SIMD2<Float>
    var age: Float // 0..1
    var maxRadius: Float
}

public final class MetalRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    // Render pipeline states
    private var backdropPSO: MTLRenderPipelineState!
    private var fillPSO: MTLRenderPipelineState!
    private var strokePSO: MTLRenderPipelineState!
    private var particlePSO: MTLRenderPipelineState!
    private var avatarPSO: MTLRenderPipelineState!
    private var bloomThresholdPSO: MTLRenderPipelineState!
    private var bloomBlurPSO: MTLRenderPipelineState!
    private var compositePSO: MTLRenderPipelineState!

    // Dynamic GPU Buffers
    private var strokeBuffer: MTLBuffer?
    private var strokeCapacity: Int = 0
    private var fillBuffer: MTLBuffer?
    private var fillCapacity: Int = 0
    private var particleBuffer: MTLBuffer?
    private var particleCapacity: Int = 4096

    // Offscreen HDR + Bloom textures
    private var hdrSceneTexture: MTLTexture?
    private var bloomPingTexture: MTLTexture?
    private var bloomPongTexture: MTLTexture?
    private var cachedViewportPixels: SIMD2<Int> = .zero

    // Current scene & playback state
    public var scene: TurtleScene = TurtleScene() {
        didSet {
            uploadSceneBuffers()
        }
    }

    public var cameraPan: SIMD2<Float> = .zero
    public var cameraZoom: Float = 1.0
    public var showGrid: Bool = false
    public var showTurtleAvatar: Bool = true
    public var bloomIntensity: Float = 0.85
    public var backdropOverride: BackdropKind? = nil

    // Playback / Scrubber state
    public var isLiveMode: Bool = true
    /// Continuous step cursor in `[0 ... Double(scene.steps.count)]`
    public var playbackStepCursor: Double = 0.0
    private var lastProcessedBurstStep: Int = -1

    // Live particles & ripples
    private var particles: [ParticleGPU] = []
    private var activeRipples: [ActiveRipple] = []
    private var lastFrameTimestamp: CFTimeInterval = CFAbsoluteTimeGetCurrent()
    private var startTimestamp: CFTimeInterval = CFAbsoluteTimeGetCurrent()

    // FPS tracking & live-coding callback
    public private(set) var currentFPS: Double = 120.0
    private var fpsSmoothing: Double = 120.0
    public var onFrameTick: ((_ dt: Double, _ totalTime: Double) -> Void)?

    public init?(mtkView: MTKView? = nil) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            return nil
        }
        self.device = dev
        self.commandQueue = queue
        super.init()

        do {
            try buildPipelines()
        } catch {
            print("MetalRenderer pipeline compilation failed: \(error)")
            return nil
        }

        self.particleBuffer = device.makeBuffer(
            length: MemoryLayout<ParticleGPU>.stride * particleCapacity,
            options: .storageModeShared
        )

        if let view = mtkView {
            configure(mtkView: view)
        }
    }

    public func configure(mtkView: MTKView) {
        mtkView.device = device
        mtkView.delegate = self
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.02, green: 0.025, blue: 0.045, alpha: 1.0)
        mtkView.preferredFramesPerSecond = 120
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
    }

    private func buildPipelines() throws {
        let library = try device.makeLibrary(source: MetalShaderSource.source, options: nil)

        // Helper for standard alpha-blended HDR pass (`rgba16Float`)
        func makeHDRPipeline(vertex: String, fragment: String, additive: Bool = false) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            guard let ca = desc.colorAttachments[0] else {
                throw NSError(domain: "TurtleToy", code: -1)
            }
            ca.pixelFormat = .rgba16Float
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .sourceAlpha
            ca.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
            ca.rgbBlendOperation = .add
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            ca.alphaBlendOperation = .add
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        backdropPSO = try makeHDRPipeline(vertex: "fullscreen_vertex", fragment: "backdrop_fragment")
        fillPSO = try makeHDRPipeline(vertex: "fill_vertex", fragment: "fill_fragment")
        strokePSO = try makeHDRPipeline(vertex: "stroke_vertex", fragment: "stroke_fragment")
        particlePSO = try makeHDRPipeline(vertex: "particle_vertex", fragment: "particle_fragment", additive: true)
        avatarPSO = try makeHDRPipeline(vertex: "turtle_avatar_vertex", fragment: "turtle_avatar_fragment")

        // Post-processing pipelines (no blending needed)
        func makePostPipeline(fragment: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
            desc.fragmentFunction = library.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat = format
            desc.colorAttachments[0].isBlendingEnabled = false
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        bloomThresholdPSO = try makePostPipeline(fragment: "bloom_threshold_fragment", format: .rgba16Float)
        bloomBlurPSO = try makePostPipeline(fragment: "bloom_blur_fragment", format: .rgba16Float)
        compositePSO = try makePostPipeline(fragment: "composite_fragment", format: .bgra8Unorm)
    }

    // MARK: - Buffer & Texture Management

    private func uploadSceneBuffers() {
        let strokeCount = scene.strokes.count
        if strokeCount > 0 {
            if strokeCount > strokeCapacity || strokeBuffer == nil {
                strokeCapacity = max(strokeCount * 2, 4096)
                strokeBuffer = device.makeBuffer(
                    length: MemoryLayout<StrokeInstanceGPU>.stride * strokeCapacity,
                    options: .storageModeShared
                )
            }
            if let buf = strokeBuffer {
                scene.strokes.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        memcpy(buf.contents(), base, raw.count)
                    }
                }
            }
        }

        let fillCount = scene.fillVertices.count
        if fillCount > 0 {
            if fillCount > fillCapacity || fillBuffer == nil {
                fillCapacity = max(fillCount * 2, 4096)
                fillBuffer = device.makeBuffer(
                    length: MemoryLayout<FillVertexGPU>.stride * fillCapacity,
                    options: .storageModeShared
                )
            }
            if let buf = fillBuffer {
                scene.fillVertices.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        memcpy(buf.contents(), base, raw.count)
                    }
                }
            }
        }
    }

    private func ensureOffscreenTextures(width: Int, height: Int) {
        let w = max(64, width)
        let h = max(64, height)
        guard cachedViewportPixels.x != w || cachedViewportPixels.y != h || hdrSceneTexture == nil else {
            return
        }
        cachedViewportPixels = SIMD2<Int>(w, h)

        let sceneDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: w,
            height: h,
            mipmapped: false
        )
        sceneDesc.usage = [.renderTarget, .shaderRead]
        sceneDesc.storageMode = .private
        hdrSceneTexture = device.makeTexture(descriptor: sceneDesc)

        // Half-resolution bloom pyramid textures for lush wide glow at 120fps
        let bw = max(32, w / 2)
        let bh = max(32, h / 2)
        let bloomDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: bw,
            height: bh,
            mipmapped: false
        )
        bloomDesc.usage = [.renderTarget, .shaderRead]
        bloomDesc.storageMode = .private
        bloomPingTexture = device.makeTexture(descriptor: bloomDesc)
        bloomPongTexture = device.makeTexture(descriptor: bloomDesc)
    }

    // MARK: - Interactive Effects (Sparks & Ripples)

    public func triggerBurst(at worldPos: SIMD2<Float>, color: SIMD4<Float>, count: Int = 28, size: Float = 9.0, speed: Float = 110.0, kind: UInt32 = 1) {
        for _ in 0..<count {
            if particles.count >= particleCapacity {
                particles.removeFirst(min(count, particles.count))
            }
            let angle = Float.random(in: 0...(2.0 * .pi))
            let spd = Float.random(in: (speed * 0.25)...(speed * 1.35))
            let vel = SIMD2<Float>(cos(angle) * spd, sin(angle) * spd)
            let life = Float.random(in: 0.45...1.25)
            let jitterCol = SIMD4<Float>(
                min(1.5, max(0.1, color.x + Float.random(in: -0.12...0.12))),
                min(1.5, max(0.1, color.y + Float.random(in: -0.12...0.12))),
                min(1.5, max(0.1, color.z + Float.random(in: -0.12...0.12))),
                1.0
            )
            particles.append(
                ParticleGPU(
                    position: worldPos,
                    velocity: vel,
                    color: jitterCol,
                    size: size * Float.random(in: 0.65...1.35),
                    age: 0.0,
                    lifetime: life,
                    kind: kind
                )
            )
        }
    }

    public func triggerRipple(at worldPos: SIMD2<Float>, maxRadius: Float = 160.0) {
        if activeRipples.count >= 4 {
            activeRipples.removeFirst()
        }
        activeRipples.append(ActiveRipple(position: worldPos, age: 0.0, maxRadius: maxRadius))
    }

    public func resetParticlesTracker() {
        lastProcessedBurstStep = -1
        particles.removeAll()
        activeRipples.removeAll()
    }

    public func stepSimulationForExport(dt: Float) {
        updateSimulation(dt: dt)
    }

    private func updateSimulation(dt: Float) {
        // Update particles
        var idx = 0
        while idx < particles.count {
            particles[idx].age += dt
            if particles[idx].age >= particles[idx].lifetime {
                particles.swapAt(idx, particles.count - 1)
                particles.removeLast()
            } else {
                particles[idx].position += particles[idx].velocity * dt
                particles[idx].velocity *= max(0.0, 1.0 - 2.2 * dt) // Air drag
                particles[idx].velocity.y -= 18.0 * dt // Gentle whimsical gravity drift
                idx += 1
            }
        }

        // Update ripples
        var rIdx = 0
        while rIdx < activeRipples.count {
            activeRipples[rIdx].age += dt * 0.85
            if activeRipples[rIdx].age >= 1.0 {
                activeRipples.remove(at: rIdx)
            } else {
                rIdx += 1
            }
        }

        // If in animated playback mode, emit trail sparks from the moving turtle pen!
        if !isLiveMode && !scene.steps.isEmpty {
            let currentStepInt = Int(playbackStepCursor)
            if currentStepInt > lastProcessedBurstStep {
                for b in scene.bursts where b.stepIndex > lastProcessedBurstStep && b.stepIndex <= currentStepInt {
                    triggerBurst(at: b.position, color: b.color, count: b.count, size: b.size, speed: b.speed, kind: b.kind)
                }
                for rp in scene.ripples where rp.stepIndex > lastProcessedBurstStep && rp.stepIndex <= currentStepInt {
                    triggerRipple(at: rp.position, maxRadius: rp.radius)
                }
                lastProcessedBurstStep = currentStepInt
            }

            if currentStepInt < scene.steps.count {
                let pose = interpolatedTurtlePose()
                if pose.penDown && Float.random(in: 0...1) < 0.65 {
                    triggerBurst(
                        at: pose.position,
                        color: pose.color,
                        count: 2,
                        size: max(4.5, pose.width * 1.4),
                        speed: 48.0,
                        kind: pose.brush == .stardust ? 1 : 0
                    )
                }
            }
        }
    }

    public func interpolatedTurtlePose() -> TurtlePose {
        guard !scene.steps.isEmpty else {
            return scene.finalTurtles.first ?? TurtlePose()
        }
        if isLiveMode || playbackStepCursor >= Double(scene.steps.count) {
            return scene.finalTurtles.first ?? scene.steps.last!.endPose
        }
        let idx = max(0, min(scene.steps.count - 1, Int(playbackStepCursor)))
        let frac = Float(playbackStepCursor - Double(idx))
        let step = scene.steps[idx]
        var pose = step.endPose
        pose.position = simd_mix(step.startPose.position, step.endPose.position, SIMD2<Float>(repeating: frac))
        return pose
    }

    // MARK: - MTKViewDelegate Rendering

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        ensureOffscreenTextures(width: Int(size.width), height: Int(size.height))
    }

    public func draw(in view: MTKView) {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = min(0.1, max(0.0005, now - lastFrameTimestamp))
        lastFrameTimestamp = now
        let totalTime = now - startTimestamp

        let instFPS = 1.0 / dt
        fpsSmoothing = fpsSmoothing * 0.92 + instFPS * 0.08
        currentFPS = fpsSmoothing

        onFrameTick?(dt, totalTime)
        updateSimulation(dt: Float(dt))

        guard let drawable = view.currentDrawable else { return }
        let width = Int(view.drawableSize.width)
        let height = Int(view.drawableSize.height)
        let logicalWidth = Float(view.bounds.width > 0 ? view.bounds.width : CGFloat(width))
        let logicalHeight = Float(view.bounds.height > 0 ? view.bounds.height : CGFloat(height))

        renderFrame(
            targetTexture: drawable.texture,
            pixelWidth: width,
            pixelHeight: height,
            logicalSize: SIMD2<Float>(logicalWidth, logicalHeight),
            time: Float(totalTime),
            presentDrawable: drawable
        )
    }

    // MARK: - Core Multi-Pass Render Routine (Shared by Live View & 4K Export)

    public func renderFrame(
        targetTexture: MTLTexture,
        pixelWidth: Int,
        pixelHeight: Int,
        logicalSize: SIMD2<Float>,
        time: Float,
        presentDrawable: MTLDrawable? = nil,
        forceDrawAvatar: Bool = false
    ) {
        ensureOffscreenTextures(width: pixelWidth, height: pixelHeight)
        guard let hdrTex = hdrSceneTexture,
              let pingTex = bloomPingTexture,
              let pongTex = bloomPongTexture,
              let cmdBuf = commandQueue.makeCommandBuffer() else {
            return
        }

        // Determine visible stroke & fill counts based on live mode vs scrubber cursor
        let visibleStrokeCount: Int
        let visibleFillVertexCount: Int
        var isAnimatingStep: UInt32 = 0
        var activeStepIdx: UInt32 = 0
        var partialFrac: Float = 1.0

        if isLiveMode || scene.steps.isEmpty || playbackStepCursor >= Double(scene.steps.count) {
            visibleStrokeCount = scene.strokes.count
            visibleFillVertexCount = scene.fillVertices.count
        } else {
            let stepIdx = max(0, min(scene.steps.count - 1, Int(playbackStepCursor)))
            let step = scene.steps[stepIdx]
            visibleStrokeCount = step.strokeRange.upperBound
            visibleFillVertexCount = step.fillVertexRange.upperBound
            isAnimatingStep = 1
            activeStepIdx = UInt32(stepIdx)
            partialFrac = Float(playbackStepCursor - Double(stepIdx))
        }

        var uniforms = FrameUniformsGPU(
            viewportSize: logicalSize,
            cameraPan: cameraPan,
            cameraZoom: cameraZoom,
            time: time,
            backdropKind: (backdropOverride ?? scene.backdrop).rawValue,
            showGrid: showGrid ? 1 : 0,
            bloomIntensity: bloomIntensity,
            partialStepFraction: partialFrac,
            activeStepIndex: activeStepIdx,
            isAnimatingStep: isAnimatingStep
        )

        if activeRipples.count > 0 { uniforms.ripple0 = SIMD4<Float>(activeRipples[0].position.x, activeRipples[0].position.y, activeRipples[0].age, activeRipples[0].maxRadius) }
        if activeRipples.count > 1 { uniforms.ripple1 = SIMD4<Float>(activeRipples[1].position.x, activeRipples[1].position.y, activeRipples[1].age, activeRipples[1].maxRadius) }
        if activeRipples.count > 2 { uniforms.ripple2 = SIMD4<Float>(activeRipples[2].position.x, activeRipples[2].position.y, activeRipples[2].age, activeRipples[2].maxRadius) }
        if activeRipples.count > 3 { uniforms.ripple3 = SIMD4<Float>(activeRipples[3].position.x, activeRipples[3].position.y, activeRipples[3].age, activeRipples[3].maxRadius) }

        // PASS 1: Render Backdrop + Fills + SDF Strokes + Particles + Cyber-Turtle into `hdrTex`
        let scenePassDesc = MTLRenderPassDescriptor()
        scenePassDesc.colorAttachments[0].texture = hdrTex
        scenePassDesc.colorAttachments[0].loadAction = .clear
        scenePassDesc.colorAttachments[0].storeAction = .store
        scenePassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: scenePassDesc) {
            // 1A. Procedural Backdrop
            enc.setRenderPipelineState(backdropPSO)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniformsGPU>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            // 1B. Polygon Fills
            if visibleFillVertexCount > 0, let fBuf = fillBuffer {
                enc.setRenderPipelineState(fillPSO)
                enc.setVertexBuffer(fBuf, offset: 0, index: 0)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniformsGPU>.stride, index: 1)
                enc.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniformsGPU>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: visibleFillVertexCount)
            }

            // 1C. Instanced SDF Strokes
            if visibleStrokeCount > 0, let sBuf = strokeBuffer {
                enc.setRenderPipelineState(strokePSO)
                enc.setVertexBuffer(sBuf, offset: 0, index: 0)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniformsGPU>.stride, index: 1)
                enc.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniformsGPU>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: visibleStrokeCount)
            }

            // 1D. GPU Particles
            if !particles.isEmpty, let pBuf = particleBuffer {
                let count = min(particles.count, particleCapacity)
                particles.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        memcpy(pBuf.contents(), base, count * MemoryLayout<ParticleGPU>.stride)
                    }
                }
                enc.setRenderPipelineState(particlePSO)
                enc.setVertexBuffer(pBuf, offset: 0, index: 0)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniformsGPU>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
            }

            // 1E. Procedural SDF Cyber-Turtle Avatar(s)
            if showTurtleAvatar && (presentDrawable != nil || forceDrawAvatar) {
                enc.setRenderPipelineState(avatarPSO)
                let pose = interpolatedTurtlePose()
                var avatarUni = TurtleAvatarUniformsGPU(
                    position: pose.position,
                    headingRadians: pose.headingRadians,
                    scale: 1.0,
                    penColor: pose.color,
                    penDown: pose.penDown ? 1 : 0,
                    brushKind: pose.brush.rawValue,
                    time: time
                )
                enc.setVertexBytes(&avatarUni, length: MemoryLayout<TurtleAvatarUniformsGPU>.stride, index: 0)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniformsGPU>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }

            enc.endEncoding()
        }

        // PASS 2: Bloom Threshold (`hdrTex` -> `pingTex`)
        let threshDesc = MTLRenderPassDescriptor()
        threshDesc.colorAttachments[0].texture = pingTex
        threshDesc.colorAttachments[0].loadAction = .dontCare
        threshDesc.colorAttachments[0].storeAction = .store
        if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: threshDesc) {
            enc.setRenderPipelineState(bloomThresholdPSO)
            enc.setFragmentTexture(hdrTex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // PASS 3: Separable Gaussian Blur (2 iterations of Horizontal + Vertical)
        let bw = Float(pingTex.width)
        let bh = Float(pingTex.height)
        for iter in 0..<2 {
            let radiusScale: Float = iter == 0 ? 1.0 : 2.2
            var stepH = SIMD2<Float>(radiusScale / bw, 0.0)
            var stepV = SIMD2<Float>(0.0, radiusScale / bh)

            // Horizontal: ping -> pong
            let hDesc = MTLRenderPassDescriptor()
            hDesc.colorAttachments[0].texture = pongTex
            hDesc.colorAttachments[0].loadAction = .dontCare
            hDesc.colorAttachments[0].storeAction = .store
            if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: hDesc) {
                enc.setRenderPipelineState(bloomBlurPSO)
                enc.setFragmentTexture(pingTex, index: 0)
                enc.setFragmentBytes(&stepH, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }

            // Vertical: pong -> ping
            let vDesc = MTLRenderPassDescriptor()
            vDesc.colorAttachments[0].texture = pingTex
            vDesc.colorAttachments[0].loadAction = .dontCare
            vDesc.colorAttachments[0].storeAction = .store
            if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: vDesc) {
                enc.setRenderPipelineState(bloomBlurPSO)
                enc.setFragmentTexture(pongTex, index: 0)
                enc.setFragmentBytes(&stepV, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        // PASS 4: Final HDR + Bloom Composite & ACES Tonemap into `targetTexture`
        let compDesc = MTLRenderPassDescriptor()
        compDesc.colorAttachments[0].texture = targetTexture
        compDesc.colorAttachments[0].loadAction = .dontCare
        compDesc.colorAttachments[0].storeAction = .store
        if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: compDesc) {
            enc.setRenderPipelineState(compositePSO)
            enc.setFragmentTexture(hdrTex, index: 0)
            enc.setFragmentTexture(pingTex, index: 1)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniformsGPU>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        if let drawable = presentDrawable {
            cmdBuf.present(drawable)
            cmdBuf.commit()
        } else {
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
        }
    }

    // MARK: - High-Resolution PNG Export (Up to 4K)

    public func renderSnapshotImage(width: Int, height: Int, logicalSize: SIMD2<Float>, drawAvatar: Bool = true) -> NSImage? {
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let outTex = device.makeTexture(descriptor: texDesc) else { return nil }

        renderFrame(
            targetTexture: outTex,
            pixelWidth: width,
            pixelHeight: height,
            logicalSize: logicalSize,
            time: Float(CFAbsoluteTimeGetCurrent() - startTimestamp),
            presentDrawable: nil,
            forceDrawAvatar: drawAvatar
        )

        let bytesPerRow = width * 4
        var rawBytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        outTex.getBytes(
            &rawBytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        for i in stride(from: 0, to: rawBytes.count, by: 4) {
            let b = rawBytes[i]
            let r = rawBytes[i + 2]
            rawBytes[i] = r
            rawBytes[i + 2] = b
            rawBytes[i + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(rawBytes) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(width) / 2.0, height: CGFloat(height) / 2.0))
    }

    /// `sourceText`, when given, is embedded in the PNG's Description text chunk (with a "TurtleToy" Software tag)
    /// so the sketch that produced an image can be recovered from it.
    public func exportHighResPNG(to url: URL, size: Int = 2048, drawAvatar: Bool = false, explicitTime: Float? = nil, sourceText: String? = nil) -> Bool {
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let outTex = device.makeTexture(descriptor: texDesc) else { return false }

        // Keep logical coordinate space at 760×760 world units so artwork fills the frame generously
        let savedZoom = cameraZoom
        defer { cameraZoom = savedZoom }

        renderFrame(
            targetTexture: outTex,
            pixelWidth: size,
            pixelHeight: size,
            logicalSize: SIMD2<Float>(760.0, 760.0),
            time: explicitTime ?? Float(CFAbsoluteTimeGetCurrent() - startTimestamp),
            presentDrawable: nil,
            forceDrawAvatar: drawAvatar
        )

        let bytesPerRow = size * 4
        var rawBytes = [UInt8](repeating: 0, count: bytesPerRow * size)
        outTex.getBytes(
            &rawBytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0
        )

        // Convert BGRA to RGBA
        for i in stride(from: 0, to: rawBytes.count, by: 4) {
            let b = rawBytes[i]
            let r = rawBytes[i + 2]
            rawBytes[i] = r
            rawBytes[i + 2] = b
            rawBytes[i + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(rawBytes) as CFData),
              let cgImage = CGImage(
                width: size,
                height: size,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return false
        }

        let pngData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        var properties: [CFString: Any] = [:]
        if let sourceText {
            properties[kCGImagePropertyPNGDictionary] = [
                kCGImagePropertyPNGDescription: sourceText,
                kCGImagePropertyPNGSoftware: "TurtleToy"
            ] as [CFString: Any]
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return false
        }

        do {
            try (pngData as Data).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
