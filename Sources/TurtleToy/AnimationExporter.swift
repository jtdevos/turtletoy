import Foundation
import AVFoundation
import CoreVideo
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd
import TurtleToyCore

// MARK: - Animation Export (MP4 via AVAssetWriter, GIF via ImageIO)
//
// The exporter owns its own `MetalRenderer`, so the on-screen canvas is never disturbed, and it is
// fully synchronous: call `run` from a background thread/queue. Nothing in here touches the main actor.

public enum AnimationExportMode: String, CaseIterable, Identifiable, Sendable {
    /// Turtle Crawl: the finished drawing is revealed step by step (no re-interpretation).
    case crawl
    /// Time loop: the program is re-interpreted for every frame with an advancing `t`.
    case time

    public var id: String { rawValue }
}

public enum AnimationExportFormat: String, CaseIterable, Identifiable, Sendable {
    case mp4
    case gif

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var contentType: UTType { self == .mp4 ? .mpeg4Movie : .gif }

    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "mp4", "m4v": self = .mp4
        case "gif": self = .gif
        default: return nil
        }
    }
}

public struct AnimationExportRequest: Sendable {
    public var mode: AnimationExportMode = .crawl
    public var format: AnimationExportFormat = .mp4
    public var width: Int = 720
    public var height: Int = 720
    public var fps: Int = 30
    /// Total number of frames written (including `holdFrames`).
    public var frameCount: Int = 150
    /// Crawl only: trailing frames that hold the completed drawing.
    public var holdFrames: Int = 0
    /// Time loop only: value of `t` for the first frame. `t` then advances by `1 / fps` per frame.
    public var startTime: Double = 0.0

    // Program. `source` is also embedded verbatim in the exported file's metadata.
    public var source: String = ""
    public var parameterOverrides: [String: Double] = [:]
    public var colorOverrides: [String: SIMD4<Float>] = [:]
    /// Crawl only: an already-interpreted scene to play back. When nil the source is interpreted once.
    public var precompiledScene: TurtleScene? = nil

    // Look (mirrors the live canvas settings)
    public var cameraPan: SIMD2<Float> = .zero
    public var cameraZoom: Float = 1.0
    public var showGrid: Bool = false
    public var showTurtleAvatar: Bool = true
    public var bloomIntensity: Float = 0.85
    public var backdropOverride: BackdropKind? = nil

    public init() {}

    public var durationSeconds: Double { Double(frameCount) / Double(max(1, fps)) }
}

public enum AnimationExportError: Error, LocalizedError {
    case cancelled
    case rendererUnavailable
    case invalidOptions(String)
    case encoderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Export cancelled"
        case .rendererUnavailable: return "Could not create a Metal renderer for export"
        case .invalidOptions(let message): return message
        case .encoderFailed(let message): return "Encoding failed: \(message)"
        }
    }
}

public enum AnimationExporter {
    /// Longest side of the logical (world-unit) viewport's short edge; same framing as the PNG export.
    private static let logicalShortSide: Float = 760.0

    /// ImageIO keeps every GIF frame in memory until the file is finalized (roughly 12 bytes per pixel
    /// per frame, measured), so cap GIFs at about 1.5 GB of peak memory. MP4 streams and has no cap.
    /// Written as the software / creator tag of exported files.
    public static let softwareName = "TurtleToy"

    public static let gifPixelFrameBudget = 120_000_000

    public static func gifExceedsBudget(width: Int, height: Int, frameCount: Int) -> Bool {
        width * height * frameCount > gifPixelFrameBudget
    }

    /// Renders and encodes the whole animation. Blocking; call off the main thread.
    /// - Parameters:
    ///   - progress: called after each frame with (frames done, total frames), on the calling thread.
    ///   - isCancelled: polled once per frame; returning true aborts and removes the partial file.
    public static func run(
        _ request: AnimationExportRequest,
        to outputURL: URL,
        progress: ((Int, Int) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws {
        var req = request
        // H.264 needs even dimensions; keep GIF consistent.
        req.width = max(64, min(4096, req.width)) & ~1
        req.height = max(64, min(4096, req.height)) & ~1
        req.fps = max(1, min(req.format == .gif ? 50 : 120, req.fps))
        req.frameCount = max(1, req.frameCount)
        req.holdFrames = max(0, min(req.frameCount - 1, req.holdFrames))
        if req.format == .gif && gifExceedsBudget(width: req.width, height: req.height, frameCount: req.frameCount) {
            throw AnimationExportError.invalidOptions(
                "A \(req.width)×\(req.height) GIF with \(req.frameCount) frames is too large. Use MP4, a smaller size, a lower frame rate or a shorter duration."
            )
        }

        guard let renderer = MetalRenderer() else { throw AnimationExportError.rendererUnavailable }
        renderer.cameraPan = req.cameraPan
        renderer.cameraZoom = req.cameraZoom
        renderer.showGrid = req.showGrid
        renderer.showTurtleAvatar = req.showTurtleAvatar
        renderer.bloomIntensity = req.bloomIntensity
        renderer.backdropOverride = req.backdropOverride

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: req.width,
            height: req.height,
            mipmapped: false
        )
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let target = renderer.device.makeTexture(descriptor: texDesc) else {
            throw AnimationExportError.rendererUnavailable
        }

        let aspect = Float(req.width) / Float(req.height)
        let logicalSize = aspect >= 1.0
            ? SIMD2<Float>(logicalShortSide * aspect, logicalShortSide)
            : SIMD2<Float>(logicalShortSide, logicalShortSide / aspect)

        // Scene setup
        var totalSteps = 0.0
        switch req.mode {
        case .crawl:
            let scene = req.precompiledScene ?? Interpreter.compileAndRun(
                source: req.source,
                parameterOverrides: req.parameterOverrides,
                colorOverrides: req.colorOverrides,
                timeSeconds: req.startTime
            )
            renderer.scene = scene
            renderer.isLiveMode = false
            totalSteps = Double(scene.steps.count)
        case .time:
            renderer.isLiveMode = true
        }
        renderer.resetParticlesTracker()

        // Encode into a hidden sibling file, then move into place, so a cancelled or failed export
        // never leaves a truncated file (or destroys an existing one) at the destination.
        let fm = FileManager.default
        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).exporting.\(req.format.fileExtension)")
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: tempURL) } }

        let sink: FrameSink
        switch req.format {
        case .mp4: sink = try MP4FrameSink(url: tempURL, width: req.width, height: req.height, fps: req.fps, source: req.source)
        case .gif: sink = try GIFFrameSink(url: tempURL, width: req.width, height: req.height, fps: req.fps, frameCount: req.frameCount, source: req.source)
        }

        let dt = 1.0 / Double(req.fps)
        let drawFrames = req.frameCount - req.holdFrames

        do {
            for frame in 0..<req.frameCount {
                if isCancelled() { throw AnimationExportError.cancelled }
                try autoreleasepool {
                    let frameTime = Double(frame) * dt
                    var drawAvatar = false

                    switch req.mode {
                    case .crawl:
                        let fraction = req.holdFrames > 0
                            ? Double(frame) / Double(drawFrames)                 // last drawing frame lands just before completion
                            : Double(frame) / Double(max(1, drawFrames - 1))     // no hold: final frame is the finished drawing
                        let finished = fraction >= 1.0 || totalSteps <= 0
                        renderer.playbackStepCursor = finished ? totalSteps : fraction * totalSteps
                        drawAvatar = !finished
                    case .time:
                        renderer.scene = Interpreter.compileAndRun(
                            source: req.source,
                            parameterOverrides: req.parameterOverrides,
                            colorOverrides: req.colorOverrides,
                            timeSeconds: req.startTime + frameTime
                        )
                    }

                    renderer.stepSimulationForExport(dt: Float(dt))
                    renderer.renderFrame(
                        targetTexture: target,
                        pixelWidth: req.width,
                        pixelHeight: req.height,
                        logicalSize: logicalSize,
                        time: Float(req.startTime + frameTime),
                        presentDrawable: nil,
                        forceDrawAvatar: drawAvatar
                    )
                    try sink.append(texture: target, frameIndex: frame, isCancelled: isCancelled)
                }
                progress?(frame + 1, req.frameCount)
            }

            try sink.finish()
        } catch {
            sink.cancel()
            throw error
        }

        if fm.fileExists(atPath: outputURL.path) {
            _ = try fm.replaceItemAt(outputURL, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: outputURL)
        }
        succeeded = true
    }
}

// MARK: - Frame sinks

private protocol FrameSink {
    /// Copies the BGRA contents of `texture` into the encoder.
    func append(texture: MTLTexture, frameIndex: Int, isCancelled: () -> Bool) throws
    func finish() throws
    func cancel()
}

private func copyBGRA(from texture: MTLTexture, into destination: UnsafeMutableRawPointer, bytesPerRow: Int) {
    texture.getBytes(
        destination,
        bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
}

/// H.264 in an MP4 container. Frames go straight from the Metal texture into pooled `CVPixelBuffer`s.
private final class MP4FrameSink: FrameSink {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Int

    init(url: URL, width: Int, height: Int, fps: Int, source: String) throws {
        self.fps = fps
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw AnimationExportError.encoderFailed(error.localizedDescription)
        }
        writer.metadata = Self.metadataItems(source: source)
        // Roughly 0.2 bits per pixel per frame: visually clean for thin glowing lines on dark backdrops.
        let bitrate = max(1_500_000, Int(Double(width * height * fps) * 0.2))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else {
            throw AnimationExportError.encoderFailed("H.264 \(width)×\(height) is not supported")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw AnimationExportError.encoderFailed(writer.error?.localizedDescription ?? "could not start writing")
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Sketch source in the description item, plus a "TurtleToy" software tag.
    private static func metadataItems(source: String) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.extendedLanguageTag = "und"
            return item
        }
        // Written twice: as iTunes-style items (what ffprobe / exiftool / most players show) and as
        // common-key items (which AVFoundation stores as MP4 user data).
        var items = [
            item(.iTunesMetadataEncodingTool, AnimationExporter.softwareName),
            item(.commonIdentifierSoftware, AnimationExporter.softwareName)
        ]
        if !source.isEmpty {
            items.append(item(.iTunesMetadataUserComment, source))
            items.append(item(.commonIdentifierDescription, source))
        }
        return items
    }

    func append(texture: MTLTexture, frameIndex: Int, isCancelled: () -> Bool) throws {
        while !input.isReadyForMoreMediaData {
            if isCancelled() { throw AnimationExportError.cancelled }
            if writer.status != .writing {
                throw AnimationExportError.encoderFailed(writer.error?.localizedDescription ?? "writer stopped")
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw AnimationExportError.encoderFailed("no pixel buffer pool")
        }
        var maybeBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
        guard let buffer = maybeBuffer else {
            throw AnimationExportError.encoderFailed("could not allocate a pixel buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            copyBGRA(from: texture, into: base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw AnimationExportError.encoderFailed(writer.error?.localizedDescription ?? "could not append frame \(frameIndex)")
        }
    }

    func finish() throws {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw AnimationExportError.encoderFailed(writer.error?.localizedDescription ?? "writer did not complete")
        }
    }

    func cancel() {
        if writer.status == .writing {
            input.markAsFinished()
            writer.cancelWriting()
        }
    }
}

/// Looping animated GIF. ImageIO does the palette quantisation.
private final class GIFFrameSink: FrameSink {
    private let destination: CGImageDestination
    private let encoded = NSMutableData()
    private let url: URL
    private let metadata: CGImageMetadata?
    private let width: Int
    private let height: Int
    private let fps: Int
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    init(url: URL, width: Int, height: Int, fps: Int, frameCount: Int, source: String) throws {
        self.url = url
        self.width = width
        self.height = height
        self.fps = fps
        self.metadata = Self.makeMetadata(source: source)
        // Encode into memory: a URL destination leaves ImageIO's own temp file behind when cancelled.
        guard let dest = CGImageDestinationCreateWithData(encoded, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw AnimationExportError.encoderFailed("could not create GIF at \(url.path)")
        }
        destination = dest
        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, fileProps as CFDictionary)
    }

    func append(texture: MTLTexture, frameIndex: Int, isCancelled: () -> Bool) throws {
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                copyBGRA(from: texture, into: base, bytesPerRow: bytesPerRow)
            }
        }
        // BGRA bytes == 32-bit little-endian xRGB; the alpha byte is ignored.
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw AnimationExportError.encoderFailed("could not wrap frame \(frameIndex)")
        }

        // GIF delays are whole centiseconds. Spread the rounding error across frames so the total
        // duration stays right for any fps; players treat delays under 2cs as "slow", so floor there.
        let startCs = Int((Double(frameIndex) * 100.0 / Double(fps)).rounded())
        let endCs = Int((Double(frameIndex + 1) * 100.0 / Double(fps)).rounded())
        let delay = Double(max(2, endCs - startCs)) / 100.0
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay
            ]
        ]
        if frameIndex == 0, let metadata {
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, frameProps as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, frameProps as CFDictionary)
        }
    }

    /// XMP packet on the first frame: sketch source in `dc:description`, "TurtleToy" in `xmp:CreatorTool`.
    private static func makeMetadata(source: String) -> CGImageMetadata? {
        let metadata = CGImageMetadataCreateMutable()
        func set(_ namespace: CFString, _ prefix: CFString, _ name: String, _ value: String) {
            if let tag = CGImageMetadataTagCreate(namespace, prefix, name as CFString, .string, value as CFString) {
                CGImageMetadataSetTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString, tag)
            }
        }
        set(kCGImageMetadataNamespaceXMPBasic, kCGImageMetadataPrefixXMPBasic, "CreatorTool", AnimationExporter.softwareName)
        if !source.isEmpty {
            set(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore, "description", source)
        }
        return metadata
    }

    func finish() throws {
        guard CGImageDestinationFinalize(destination) else {
            throw AnimationExportError.encoderFailed("could not finalize GIF")
        }
        do {
            try (encoded as Data).write(to: url)
        } catch {
            throw AnimationExportError.encoderFailed(error.localizedDescription)
        }
    }

    func cancel() {
        // Nothing has been written to disk yet.
    }
}

// MARK: - Headless CLI: `--export-animation <presetId> <outputPath> [--frames N] [--fps N] [--size N|WxH] [--mode crawl|time]`
// (`--cancel-after N` cancels after N frames, to exercise the cancel path without the UI.)

public enum AnimationExportCLI {
    /// Runs the export and exits the process if `--export-animation` is present; otherwise returns.
    public static func runIfRequested(arguments args: [String]) {
        guard let idx = args.firstIndex(of: "--export-animation") else { return }
        guard idx + 2 < args.count else {
            fail("usage: --export-animation <presetId> <outputPath> [--frames N] [--fps N] [--size N|WxH] [--mode crawl|time]")
        }
        let presetId = args[idx + 1]
        let outputURL = URL(fileURLWithPath: args[idx + 2])

        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        guard let preset = PresetGallery.all.first(where: { $0.id == presetId }) else {
            fail("unknown preset '\(presetId)'. Available: \(PresetGallery.all.map(\.id).joined(separator: ", "))")
        }
        guard let format = AnimationExportFormat(fileExtension: outputURL.pathExtension) else {
            fail("output path must end in .mp4 or .gif")
        }

        var request = AnimationExportRequest()
        request.format = format
        request.source = preset.code

        if let modeString = option("--mode") {
            guard let mode = AnimationExportMode(rawValue: modeString.lowercased()) else {
                fail("--mode must be 'crawl' or 'time'")
            }
            request.mode = mode
        }
        if let fpsString = option("--fps") {
            guard let fps = Int(fpsString), fps > 0 else { fail("--fps must be a positive integer") }
            request.fps = fps
        }
        if let framesString = option("--frames") {
            guard let frames = Int(framesString), frames > 0 else { fail("--frames must be a positive integer") }
            request.frameCount = frames
        } else {
            request.frameCount = request.fps * 4
        }
        if let sizeString = option("--size") {
            let parts = sizeString.lowercased().split(separator: "x").compactMap { Int($0) }
            switch parts.count {
            case 1 where parts[0] > 0:
                request.width = parts[0]; request.height = parts[0]
            case 2 where parts[0] > 0 && parts[1] > 0:
                request.width = parts[0]; request.height = parts[1]
            default:
                fail("--size must be N or WxH")
            }
        }
        if request.mode == .crawl {
            request.holdFrames = defaultHoldFrames(frameCount: request.frameCount, fps: request.fps)
        }

        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Same path as the app: the export runs on a background queue. We are called before the run
        // loop starts, so block this (main) thread until it has finished; the exporter never needs it.
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        let started = Date()
        let cancelAfter = option("--cancel-after").flatMap { Int($0) }
        let finalRequest = request
        DispatchQueue.global(qos: .userInitiated).async {
            var framesDone = 0
            do {
                try AnimationExporter.run(
                    finalRequest,
                    to: outputURL,
                    progress: { done, _ in framesDone = done },
                    isCancelled: { cancelAfter.map { framesDone >= $0 } ?? false }
                )
            } catch {
                failure = error
            }
            done.signal()
        }
        done.wait()

        if let failure {
            fail("export failed: \(failure.localizedDescription)")
        }
        print(String(
            format: "Exported %@ %@ animation for %@: %d frames @ %d fps, %dx%d, %.1fs -> %@",
            request.mode.rawValue, request.format.rawValue, preset.id,
            request.frameCount, request.fps, request.width & ~1, request.height & ~1,
            Date().timeIntervalSince(started), outputURL.path
        ))
        exit(0)
    }

    /// Frames at the end of a crawl that hold the finished drawing: ~0.75s, at most a quarter of the clip.
    public static func defaultHoldFrames(frameCount: Int, fps: Int) -> Int {
        min(frameCount / 4, Int((Double(fps) * 0.75).rounded()))
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("--export-animation: \(message)\n".utf8))
        exit(1)
    }
}
