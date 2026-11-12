import Foundation
import simd

// MARK: - Brush & Backdrop Types

public enum BrushKind: UInt32, CaseIterable, Sendable, Codable {
    case neon = 0
    case laser = 1
    case watercolor = 2
    case calligraphy = 3
    case rainbow = 4
    case electric = 5
    case stardust = 6
    case ribbon = 7

    public var name: String {
        switch self {
        case .neon: return "neon"
        case .laser: return "laser"
        case .watercolor: return "watercolor"
        case .calligraphy: return "calligraphy"
        case .rainbow: return "rainbow"
        case .electric: return "electric"
        case .stardust: return "stardust"
        case .ribbon: return "ribbon"
        }
    }

    public var displayName: String {
        switch self {
        case .neon: return "Neon Plasma"
        case .laser: return "Coherent Laser"
        case .watercolor: return "Watercolor Bleed"
        case .calligraphy: return "Calligraphy Ink"
        case .rainbow: return "Rainbow Prism"
        case .electric: return "Electric Arc"
        case .stardust: return "Stardust Trail"
        case .ribbon: return "Satin Ribbon"
        }
    }

    public static func from(string: String) -> BrushKind {
        switch string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "neon", "plasma", "glow": return .neon
        case "laser", "beam": return .laser
        case "watercolor", "water", "paint", "aquarelle": return .watercolor
        case "calligraphy", "ink", "pen", "nib": return .calligraphy
        case "rainbow", "prism", "spectrum": return .rainbow
        case "electric", "lightning", "zap", "bolt": return .electric
        case "stardust", "stars", "glitter", "sparkle": return .stardust
        case "ribbon", "silk", "wave": return .ribbon
        default: return .neon
        }
    }
}

public enum BackdropKind: UInt32, CaseIterable, Sendable, Codable {
    case cosmicVoid = 0
    case synthwave = 1
    case parchment = 2
    case deepOcean = 3
    case auroraNebula = 4
    case blueprint = 5

    public var name: String {
        switch self {
        case .cosmicVoid: return "void"
        case .synthwave: return "synthwave"
        case .parchment: return "parchment"
        case .deepOcean: return "ocean"
        case .auroraNebula: return "nebula"
        case .blueprint: return "blueprint"
        }
    }

    public var displayName: String {
        switch self {
        case .cosmicVoid: return "Cosmic Void"
        case .synthwave: return "Synthwave Grid"
        case .parchment: return "Warm Parchment"
        case .deepOcean: return "Bioluminescent Ocean"
        case .auroraNebula: return "Aurora Nebula"
        case .blueprint: return "Architect Blueprint"
        }
    }

    public static func from(string: String) -> BackdropKind {
        switch string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "void", "dark", "space", "cosmic", "night": return .cosmicVoid
        case "synthwave", "synth", "grid", "retro", "cyber": return .synthwave
        case "parchment", "paper", "canvas", "warm", "cream": return .parchment
        case "ocean", "sea", "water", "abyss", "deep": return .deepOcean
        case "nebula", "aurora", "galaxy", "cosmos": return .auroraNebula
        case "blueprint", "draft", "cad", "tech": return .blueprint
        default: return .cosmicVoid
        }
    }
}

// MARK: - Interactive Parameters (@param)

public enum ParameterControlKind: Sendable, Equatable {
    case slider(min: Double, max: Double, step: Double?)
    case toggle
    case color
}

public struct ProgramParameter: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let label: String
    public let control: ParameterControlKind
    public var defaultValue: Double
    public var defaultColor: SIMD4<Float>?
    public let sourceLine: Int

    public init(
        name: String,
        label: String,
        control: ParameterControlKind,
        defaultValue: Double,
        defaultColor: SIMD4<Float>? = nil,
        sourceLine: Int
    ) {
        self.id = name
        self.name = name
        self.label = label
        self.control = control
        self.defaultValue = defaultValue
        self.defaultColor = defaultColor
        self.sourceLine = sourceLine
    }
}

// MARK: - GPU-Aligned Primitives

/// Matches the Metal `StrokeInstanceGPU` struct layout in Shaders.metal.
public struct StrokeInstanceGPU: Sendable {
    public var start: SIMD2<Float>
    public var end: SIMD2<Float>
    public var colorStart: SIMD4<Float>
    public var colorEnd: SIMD4<Float>
    public var widthStart: Float
    public var widthEnd: Float
    public var glow: Float
    public var brushKind: UInt32
    public var cumulativeDistStart: Float
    public var cumulativeDistEnd: Float
    public var seed: Float
    public var stepIndex: UInt32

    public init(
        start: SIMD2<Float>,
        end: SIMD2<Float>,
        colorStart: SIMD4<Float>,
        colorEnd: SIMD4<Float>,
        widthStart: Float,
        widthEnd: Float,
        glow: Float,
        brushKind: UInt32,
        cumulativeDistStart: Float,
        cumulativeDistEnd: Float,
        seed: Float,
        stepIndex: UInt32
    ) {
        self.start = start
        self.end = end
        self.colorStart = colorStart
        self.colorEnd = colorEnd
        self.widthStart = widthStart
        self.widthEnd = widthEnd
        self.glow = glow
        self.brushKind = brushKind
        self.cumulativeDistStart = cumulativeDistStart
        self.cumulativeDistEnd = cumulativeDistEnd
        self.seed = seed
        self.stepIndex = stepIndex
    }
}

/// Matches the Metal `FillVertexGPU` struct layout in Shaders.metal.
public struct FillVertexGPU: Sendable {
    public var position: SIMD2<Float>
    public var color: SIMD4<Float>
    public var glow: Float
    public var stepIndex: UInt32

    public init(position: SIMD2<Float>, color: SIMD4<Float>, glow: Float, stepIndex: UInt32) {
        self.position = position
        self.color = color
        self.glow = glow
        self.stepIndex = stepIndex
    }
}

/// Matches the Metal `ParticleGPU` struct layout in Shaders.metal.
public struct ParticleGPU: Sendable {
    public var position: SIMD2<Float>
    public var velocity: SIMD2<Float>
    public var color: SIMD4<Float>
    public var size: Float
    public var age: Float
    public var lifetime: Float
    public var kind: UInt32 // 0 = spark, 1 = stardust, 2 = bubble/ink, 3 = ring

    public init(
        position: SIMD2<Float>,
        velocity: SIMD2<Float>,
        color: SIMD4<Float>,
        size: Float,
        age: Float,
        lifetime: Float,
        kind: UInt32
    ) {
        self.position = position
        self.velocity = velocity
        self.color = color
        self.size = size
        self.age = age
        self.lifetime = lifetime
        self.kind = kind
    }
}

// MARK: - Scene Metadata & Turtle Steps

public struct ParticleBurstEvent: Sendable {
    public let position: SIMD2<Float>
    public let color: SIMD4<Float>
    public let count: Int
    public let size: Float
    public let speed: Float
    public let kind: UInt32
    public let stepIndex: Int

    public init(
        position: SIMD2<Float>,
        color: SIMD4<Float>,
        count: Int,
        size: Float = 8.0,
        speed: Float = 90.0,
        kind: UInt32 = 0,
        stepIndex: Int
    ) {
        self.position = position
        self.color = color
        self.count = count
        self.size = size
        self.speed = speed
        self.kind = kind
        self.stepIndex = stepIndex
    }
}

public struct RippleEvent: Sendable {
    public let position: SIMD2<Float>
    public let color: SIMD4<Float>
    public let radius: Float
    public let stepIndex: Int

    public init(position: SIMD2<Float>, color: SIMD4<Float>, radius: Float, stepIndex: Int) {
        self.position = position
        self.color = color
        self.radius = radius
        self.stepIndex = stepIndex
    }
}

public struct TurtlePose: Sendable {
    public var position: SIMD2<Float>
    public var headingRadians: Float // 0 = North/Up or East? Let's make 0 = Up (North) in classic Logo, or store standard math angle + convert
    public var penDown: Bool
    public var color: SIMD4<Float>
    public var width: Float
    public var glow: Float
    public var brush: BrushKind
    public var sourceLine: Int
    public var turtleID: Int

    public init(
        position: SIMD2<Float> = .zero,
        headingRadians: Float = .pi / 2.0, // Facing North (+Y)
        penDown: Bool = true,
        color: SIMD4<Float> = SIMD4<Float>(0.15, 0.95, 0.85, 1.0),
        width: Float = 4.0,
        glow: Float = 1.0,
        brush: BrushKind = .neon,
        sourceLine: Int = 1,
        turtleID: Int = 0
    ) {
        self.position = position
        self.headingRadians = headingRadians
        self.penDown = penDown
        self.color = color
        self.width = width
        self.glow = glow
        self.brush = brush
        self.sourceLine = sourceLine
        self.turtleID = turtleID
    }
}

public struct TurtleStepRecord: Sendable {
    public let stepIndex: Int
    public let startPose: TurtlePose
    public let endPose: TurtlePose
    /// Range of indices in `scene.strokes` generated by this step (includes symmetry copies)
    public let strokeRange: Range<Int>
    /// Range of indices in `scene.fillVertices` generated by this step
    public let fillVertexRange: Range<Int>
    public let sourceLine: Int

    public init(
        stepIndex: Int,
        startPose: TurtlePose,
        endPose: TurtlePose,
        strokeRange: Range<Int>,
        fillVertexRange: Range<Int>,
        sourceLine: Int
    ) {
        self.stepIndex = stepIndex
        self.startPose = startPose
        self.endPose = endPose
        self.strokeRange = strokeRange
        self.fillVertexRange = fillVertexRange
        self.sourceLine = sourceLine
    }
}

public struct DiagnosticMessage: Identifiable, Sendable, Equatable {
    public enum Severity: String, Sendable {
        case error
        case warning
        case info
    }
    public let id = UUID()
    public let severity: Severity
    public let message: String
    public let line: Int
    public let column: Int

    public init(severity: Severity, message: String, line: Int, column: Int = 1) {
        self.severity = severity
        self.message = message
        self.line = line
        self.column = column
    }
}

public struct TurtleScene: Sendable {
    public var strokes: [StrokeInstanceGPU] = []
    public var fillVertices: [FillVertexGPU] = []
    public var steps: [TurtleStepRecord] = []
    public var bursts: [ParticleBurstEvent] = []
    public var ripples: [RippleEvent] = []
    public var parameters: [ProgramParameter] = []
    public var diagnostics: [DiagnosticMessage] = []
    public var logs: [String] = []
    public var backdrop: BackdropKind = .cosmicVoid
    public var symmetryCount: Int = 1
    public var mirrorSymmetry: Bool = false
    public var bloomStrength: Float = 0.85
    public var totalPathLength: Float = 0.0
    public var finalTurtles: [TurtlePose] = []
    public var usesTimeVariable: Bool = false
    public var executionTimeMs: Double = 0.0

    public init() {}
}
