import Foundation
import simd

public enum RuntimeValue: Sendable, Equatable {
    case number(Double)
    case string(String)
    case color(SIMD4<Float>)

    public var asNumber: Double {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s) ?? 0.0
        case .color(let c): return Double(c.x)
        }
    }

    public var asString: String {
        switch self {
        case .number(let d):
            if d.rounded() == d { return String(Int(d)) }
            return String(format: "%.3f", d)
        case .string(let s): return s
        case .color(let c): return ColorUtils.toHex(c)
        }
    }

    public var asColor: SIMD4<Float>? {
        switch self {
        case .color(let c): return c
        case .string(let s): return ColorUtils.parseHexOrName(s)
        case .number(let d):
            // Treat single number as hue in degrees!
            return ColorUtils.hsl(d, 85.0, 60.0, 1.0)
        }
    }
}

private struct ProcedureDefinition {
    let name: String
    let params: [String]
    let body: [Stmt]
}

private struct ActiveTurtleState {
    var pose: TurtlePose
    var cumulativeDist: Float = 0.0
    var isFilling: Bool = false
    var fillPolygonPoints: [(pos: SIMD2<Float>, color: SIMD4<Float>)] = []
}

private struct ReturnSignal: Error {
    let value: RuntimeValue?
}

private struct BudgetExceededError: Error {}

public final class Interpreter {
    private let maxInstructions: Int
    private let maxCallDepth: Int
    private let maxStrokes: Int

    private var instructionCount: Int = 0
    private var callDepth: Int = 0
    private var rngState: UInt64 = 0x853C49E6748FEA9B

    private var globals: [String: RuntimeValue] = [:]
    private var scopes: [[String: RuntimeValue]] = []
    private var procedures: [String: ProcedureDefinition] = [:]

    private var activeTurtle = ActiveTurtleState(pose: TurtlePose())
    private var turtleStack: [ActiveTurtleState] = []
    private var nextTurtleID: Int = 1

    private var scene = TurtleScene()
    private var parameterOverrides: [String: Double]
    private var colorOverrides: [String: SIMD4<Float>]
    private var timeSeconds: Double

    public init(
        parameterOverrides: [String: Double] = [:],
        colorOverrides: [String: SIMD4<Float>] = [:],
        timeSeconds: Double = 0.0,
        maxInstructions: Int = 250_000,
        maxCallDepth: Int = 180,
        maxStrokes: Int = 180_000
    ) {
        self.parameterOverrides = parameterOverrides
        self.colorOverrides = colorOverrides
        self.timeSeconds = timeSeconds
        self.maxInstructions = maxInstructions
        self.maxCallDepth = maxCallDepth
        self.maxStrokes = maxStrokes
    }

    public static func compileAndRun(
        source: String,
        parameterOverrides: [String: Double] = [:],
        colorOverrides: [String: SIMD4<Float>] = [:],
        timeSeconds: Double = 0.0
    ) -> TurtleScene {
        let startTime = CFAbsoluteTimeGetCurrent()
        let lexer = Lexer(source: source)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let ast = parser.parse()

        let interpreter = Interpreter(
            parameterOverrides: parameterOverrides,
            colorOverrides: colorOverrides,
            timeSeconds: timeSeconds
        )
        var result = interpreter.evaluate(ast: ast)
        result.executionTimeMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        return result
    }

    public func evaluate(ast: ProgramAST) -> TurtleScene {
        scene = TurtleScene()
        scene.parameters = ast.parameters
        scene.diagnostics = ast.diagnostics

        // Seed built-in constants
        globals["pi"] = .number(Double.pi)
        globals["tau"] = .number(Double.pi * 2.0)
        globals["phi"] = .number((1.0 + sqrt(5.0)) / 2.0)
        globals["t"] = .number(timeSeconds)
        globals["time"] = .number(timeSeconds)
        globals["true"] = .number(1.0)
        globals["false"] = .number(0.0)

        // Register all procedures first so forward references work cleanly
        for stmt in ast.statements {
            if case .procDef(let name, let params, let body, _) = stmt {
                procedures[name.lowercased()] = ProcedureDefinition(name: name, params: params, body: body)
            }
        }

        do {
            for stmt in ast.statements {
                try executeStatement(stmt)
            }
        } catch is ReturnSignal {
            // Top-level return stops program cleanly
        } catch is BudgetExceededError {
            scene.diagnostics.append(
                DiagnosticMessage(
                    severity: .warning,
                    message: "Execution budget reached (\(maxInstructions) operations or \(maxStrokes) strokes). Capped for smooth 120fps responsiveness!",
                    line: activeTurtle.pose.sourceLine
                )
            )
        } catch {
            scene.diagnostics.append(
                DiagnosticMessage(
                    severity: .error,
                    message: "Runtime error: \(error.localizedDescription)",
                    line: activeTurtle.pose.sourceLine
                )
            )
        }

        scene.finalTurtles.append(activeTurtle.pose)
        return scene
    }

    // MARK: - Statement Execution

    private func executeStatement(_ stmt: Stmt) throws {
        instructionCount += 1
        if instructionCount > maxInstructions || scene.strokes.count >= maxStrokes {
            throw BudgetExceededError()
        }

        switch stmt {
        case .paramDecl(let param):
            activeTurtle.pose.sourceLine = param.sourceLine
            if param.control == .color {
                let c = colorOverrides[param.name] ?? param.defaultColor ?? SIMD4<Float>(0.2, 0.9, 1.0, 1.0)
                setVariable(param.name, value: .color(c))
            } else {
                let v = parameterOverrides[param.name] ?? param.defaultValue
                setVariable(param.name, value: .number(v))
            }

        case .varAssign(let name, let expr, let line):
            activeTurtle.pose.sourceLine = line
            let val = try evalExpr(expr)
            setVariable(name, value: val)

        case .command(let name, let args, let line):
            activeTurtle.pose.sourceLine = line
            try executeCommand(name: name, args: args, line: line)

        case .repeatLoop(let countExpr, let body, let line):
            activeTurtle.pose.sourceLine = line
            let count = max(0, min(50_000, Int(try evalExpr(countExpr).asNumber.rounded())))
            for idx in 0..<count {
                // Provide `i` or `repcount` inside repeat loop if not shadowing a parameter
                let prevRep = lookupVariable("repcount")
                setVariable("repcount", value: .number(Double(idx + 1)))
                for s in body {
                    try executeStatement(s)
                }
                if let prevRep {
                    setVariable("repcount", value: prevRep)
                }
            }

        case .forLoop(let variable, let startExpr, let endExpr, let stepExpr, let body, let line):
            activeTurtle.pose.sourceLine = line
            let startVal = try evalExpr(startExpr).asNumber
            let endVal = try evalExpr(endExpr).asNumber
            let rawStep: Double
            if let stepExpr {
                rawStep = try evalExpr(stepExpr).asNumber
            } else {
                rawStep = endVal >= startVal ? 1.0 : -1.0
            }
            guard abs(rawStep) > 1e-9 else { return }

            var currentVal = startVal
            var iterations = 0
            while (rawStep > 0 ? currentVal <= endVal + 1e-7 : currentVal >= endVal - 1e-7) && iterations < 50_000 {
                setVariable(variable, value: .number(currentVal))
                for s in body {
                    try executeStatement(s)
                }
                currentVal += rawStep
                iterations += 1
            }

        case .whileLoop(let condition, let body, let line):
            activeTurtle.pose.sourceLine = line
            var iterations = 0
            while try isTruthy(evalExpr(condition)) && iterations < 50_000 {
                for s in body {
                    try executeStatement(s)
                }
                iterations += 1
            }

        case .ifStmt(let condition, let thenBody, let elseBody, let line):
            activeTurtle.pose.sourceLine = line
            if try isTruthy(evalExpr(condition)) {
                for s in thenBody {
                    try executeStatement(s)
                }
            } else if let elseBody {
                for s in elseBody {
                    try executeStatement(s)
                }
            }

        case .procDef:
            // Already registered in pre-pass
            break

        case .branchBlock(let body, let line):
            activeTurtle.pose.sourceLine = line
            turtleStack.append(activeTurtle)
            for s in body {
                try executeStatement(s)
            }
            if let saved = turtleStack.popLast() {
                activeTurtle = saved
            }

        case .spawnBlock(let body, let line):
            activeTurtle.pose.sourceLine = line
            var spawned = activeTurtle
            spawned.pose.turtleID = nextTurtleID
            nextTurtleID += 1
            turtleStack.append(activeTurtle)
            activeTurtle = spawned
            for s in body {
                try executeStatement(s)
            }
            scene.finalTurtles.append(activeTurtle.pose)
            if let saved = turtleStack.popLast() {
                activeTurtle = saved
            }

        case .lsystemBlock(let axiom, let generations, let angle, let stepSize, let decay, let rules, let symbolActions, let line):
            activeTurtle.pose.sourceLine = line
            try executeLSystem(
                axiomExpr: axiom,
                genExpr: generations,
                angleExpr: angle,
                sizeExpr: stepSize,
                decayExpr: decay,
                rules: rules,
                symbolActions: symbolActions,
                line: line
            )

        case .returnStmt(let expr, let line):
            activeTurtle.pose.sourceLine = line
            let val = try expr.map { try evalExpr($0) }
            throw ReturnSignal(value: val)
        }
    }

    // MARK: - L-System Engine

    private func executeLSystem(
        axiomExpr: Expr,
        genExpr: Expr,
        angleExpr: Expr,
        sizeExpr: Expr,
        decayExpr: Expr?,
        rules: [String: String],
        symbolActions: [String: [Stmt]],
        line: Int
    ) throws {
        let axiom = try evalExpr(axiomExpr).asString
        let generations = max(0, min(11, Int(try evalExpr(genExpr).asNumber.rounded())))
        let turnAngle = try evalExpr(angleExpr).asNumber
        var stepDist = try evalExpr(sizeExpr).asNumber
        let decayFactor = try decayExpr.map { try evalExpr($0).asNumber } ?? 1.0

        for _ in 0..<generations {
            stepDist *= decayFactor
        }

        // Expand string with cap to protect memory
        var currentString = axiom
        let maxStringChars = 120_000
        for _ in 0..<generations {
            var next = String()
            next.reserveCapacity(min(maxStringChars, currentString.count * 3))
            for ch in currentString {
                let key = String(ch)
                if let replacement = rules[key] {
                    next.append(replacement)
                } else {
                    next.append(ch)
                }
                if next.count >= maxStringChars { break }
            }
            currentString = next
            if currentString.count >= maxStringChars { break }
        }

        // Interpret expanded L-system string
        var lsysStack: [(ActiveTurtleState, Double)] = []
        var currentStepDist = stepDist
        let totalChars = max(1, currentString.count)

        for (idx, ch) in currentString.enumerated() {
            instructionCount += 1
            if instructionCount > maxInstructions || scene.strokes.count >= maxStrokes {
                throw BudgetExceededError()
            }

            let progress = Double(idx) / Double(totalChars)
            setVariable("progress", value: .number(progress))

            let sym = String(ch)
            if let customBody = symbolActions[sym] {
                for s in customBody {
                    try executeStatement(s)
                }
                continue
            }

            switch ch {
            case "F", "G", "A", "B":
                moveTurtleForward(distance: Float(currentStepDist), line: line)
            case "f":
                let oldPen = activeTurtle.pose.penDown
                activeTurtle.pose.penDown = false
                moveTurtleForward(distance: Float(currentStepDist), line: line)
                activeTurtle.pose.penDown = oldPen
            case "+":
                // Turn right
                activeTurtle.pose.headingRadians -= Float(turnAngle * .pi / 180.0)
            case "-":
                // Turn left
                activeTurtle.pose.headingRadians += Float(turnAngle * .pi / 180.0)
            case "|":
                activeTurtle.pose.headingRadians += .pi
            case "[":
                lsysStack.append((activeTurtle, currentStepDist))
            case "]":
                if let (savedTurtle, savedStep) = lsysStack.popLast() {
                    activeTurtle = savedTurtle
                    currentStepDist = savedStep
                }
            case "!":
                activeTurtle.pose.width = max(0.5, activeTurtle.pose.width * 0.82)
            case "@":
                // Small glowing blossom/berry dot at branch tip!
                emitDot(radius: activeTurtle.pose.width * 1.8, line: line)
            case "*":
                scene.bursts.append(
                    ParticleBurstEvent(
                        position: activeTurtle.pose.position,
                        color: activeTurtle.pose.color,
                        count: 10,
                        size: activeTurtle.pose.width * 2.0,
                        speed: 55.0,
                        kind: 1,
                        stepIndex: scene.steps.count
                    )
                )
            default:
                break
            }
        }
    }

    // MARK: - Commands & Procedures

    private func executeCommand(name: String, args: [Expr], line: Int) throws {
        // First check if user-defined procedure matches
        if let proc = procedures[name] {
            _ = try callProcedure(proc, args: args, line: line)
            return
        }

        let evalArgs = try args.map { try evalExpr($0) }

        switch name {
        case "fd", "forward":
            let dist = Float(evalArgs.first?.asNumber ?? 50.0)
            moveTurtleForward(distance: dist, line: line)

        case "bk", "back", "backward":
            let dist = Float(evalArgs.first?.asNumber ?? 50.0)
            moveTurtleForward(distance: -dist, line: line)

        case "lt", "left":
            let deg = Float(evalArgs.first?.asNumber ?? 90.0)
            activeTurtle.pose.headingRadians += deg * (.pi / 180.0)

        case "rt", "right":
            let deg = Float(evalArgs.first?.asNumber ?? 90.0)
            activeTurtle.pose.headingRadians -= deg * (.pi / 180.0)

        case "pu", "penup":
            activeTurtle.pose.penDown = false

        case "pd", "pendown":
            activeTurtle.pose.penDown = true

        case "home":
            moveTurtleTo(target: .zero, line: line)
            activeTurtle.pose.headingRadians = .pi / 2.0

        case "goto", "setxy", "setpos", "move":
            let x = Float(evalArgs.count > 0 ? evalArgs[0].asNumber : 0.0)
            let y = Float(evalArgs.count > 1 ? evalArgs[1].asNumber : 0.0)
            if name == "move" {
                let wasDown = activeTurtle.pose.penDown
                activeTurtle.pose.penDown = false
                moveTurtleTo(target: SIMD2<Float>(x, y), line: line)
                activeTurtle.pose.penDown = wasDown
            } else {
                moveTurtleTo(target: SIMD2<Float>(x, y), line: line)
            }

        case "setx":
            let x = Float(evalArgs.first?.asNumber ?? 0.0)
            moveTurtleTo(target: SIMD2<Float>(x, activeTurtle.pose.position.y), line: line)

        case "sety":
            let y = Float(evalArgs.first?.asNumber ?? 0.0)
            moveTurtleTo(target: SIMD2<Float>(activeTurtle.pose.position.x, y), line: line)

        case "seth", "setheading", "heading":
            // Logo convention: 0 is North (+Y), 90 is East (+X), 180 is South (-Y), 270 is West (-X)
            let deg = Float(evalArgs.first?.asNumber ?? 0.0)
            activeTurtle.pose.headingRadians = (.pi / 2.0) - (deg * .pi / 180.0)

        case "circle":
            let radius = Float(evalArgs.count > 0 ? evalArgs[0].asNumber : 40.0)
            let segments = max(12, min(120, Int(evalArgs.count > 1 ? evalArgs[1].asNumber : Double(max(24, abs(radius) * 0.6)))))
            drawCircleAroundCenter(radius: radius, segments: segments, line: line)

        case "arc":
            let radius = Float(evalArgs.count > 0 ? evalArgs[0].asNumber : 50.0)
            let angleDeg = Float(evalArgs.count > 1 ? evalArgs[1].asNumber : 90.0)
            drawTurtleArc(radius: radius, angleDegrees: angleDeg, line: line)

        case "dot":
            let radius = Float(evalArgs.first?.asNumber ?? Double(activeTurtle.pose.width * 2.0))
            emitDot(radius: radius, line: line)

        case "polygon", "poly":
            let sides = max(3, min(64, Int(evalArgs.count > 0 ? evalArgs[0].asNumber : 6.0)))
            let radius = Float(evalArgs.count > 1 ? evalArgs[1].asNumber : 40.0)
            let filled = evalArgs.count > 2 ? (evalArgs[2].asNumber != 0.0) : true
            drawRegularPolygon(sides: sides, radius: radius, filled: filled, line: line)

        case "star":
            let points = max(3, min(32, Int(evalArgs.count > 0 ? evalArgs[0].asNumber : 5.0)))
            let outerR = Float(evalArgs.count > 1 ? evalArgs[1].asNumber : 50.0)
            let innerR = Float(evalArgs.count > 2 ? evalArgs[2].asNumber : Double(outerR * 0.42))
            drawStar(points: points, outerRadius: outerR, innerRadius: innerR, line: line)

        case "beginfill", "begin_fill":
            activeTurtle.isFilling = true
            activeTurtle.fillPolygonPoints = [(pos: activeTurtle.pose.position, color: activeTurtle.pose.color)]

        case "endfill", "end_fill":
            if activeTurtle.isFilling {
                commitPolygonFill(line: line)
                activeTurtle.isFilling = false
                activeTurtle.fillPolygonPoints.removeAll()
            }

        case "width", "penwidth", "pensize", "size":
            let w = Float(max(0.25, min(200.0, evalArgs.first?.asNumber ?? 4.0)))
            activeTurtle.pose.width = w

        case "glow", "bloom":
            let g = Float(max(0.0, min(5.0, evalArgs.first?.asNumber ?? 1.0)))
            activeTurtle.pose.glow = g

        case "alpha", "opacity":
            let a = Float(max(0.0, min(1.0, evalArgs.first?.asNumber ?? 1.0)))
            activeTurtle.pose.color.w = a

        case "brush":
            if let first = evalArgs.first {
                switch first {
                case .string(let s):
                    activeTurtle.pose.brush = BrushKind.from(string: s)
                case .number(let n):
                    let raw = UInt32(max(0, Int(n.rounded())) % BrushKind.allCases.count)
                    activeTurtle.pose.brush = BrushKind(rawValue: raw) ?? .neon
                case .color:
                    break
                }
            }

        case "color", "pencolor", "pc":
            let currentAlpha = activeTurtle.pose.color.w
            if evalArgs.count == 1 {
                if let c = evalArgs[0].asColor {
                    activeTurtle.pose.color = SIMD4<Float>(c.x, c.y, c.z, evalArgs[0] == .string(evalArgs[0].asString) ? currentAlpha : c.w)
                }
            } else if evalArgs.count >= 3 {
                var r = Float(evalArgs[0].asNumber)
                var g = Float(evalArgs[1].asNumber)
                var b = Float(evalArgs[2].asNumber)
                if r > 1.0 || g > 1.0 || b > 1.0 {
                    r /= 255.0; g /= 255.0; b /= 255.0
                }
                let a = evalArgs.count >= 4 ? Float(evalArgs[3].asNumber) : currentAlpha
                activeTurtle.pose.color = SIMD4<Float>(r, g, b, a)
            }

        case "hsl", "hsv":
            let h = evalArgs.count > 0 ? evalArgs[0].asNumber : 180.0
            let s = evalArgs.count > 1 ? evalArgs[1].asNumber : 85.0
            let l = evalArgs.count > 2 ? evalArgs[2].asNumber : 60.0
            let a = evalArgs.count > 3 ? evalArgs[3].asNumber : Double(activeTurtle.pose.color.w)
            activeTurtle.pose.color = ColorUtils.hsl(h, s, l, a)

        case "rgb":
            var r = Float(evalArgs.count > 0 ? evalArgs[0].asNumber : 255.0)
            var g = Float(evalArgs.count > 1 ? evalArgs[1].asNumber : 255.0)
            var b = Float(evalArgs.count > 2 ? evalArgs[2].asNumber : 255.0)
            if r > 1.0 || g > 1.0 || b > 1.0 {
                r /= 255.0; g /= 255.0; b /= 255.0
            }
            let a = evalArgs.count > 3 ? Float(evalArgs[3].asNumber) : activeTurtle.pose.color.w
            activeTurtle.pose.color = SIMD4<Float>(r, g, b, a)

        case "palette":
            let palName = evalArgs.count > 0 ? evalArgs[0].asString : "cyberpunk"
            let tVal = Float(evalArgs.count > 1 ? evalArgs[1].asNumber : Double(activeTurtle.cumulativeDist * 0.002))
            let a = evalArgs.count > 2 ? Float(evalArgs[2].asNumber) : activeTurtle.pose.color.w
            activeTurtle.pose.color = ColorUtils.namedPalette(palName, t: tVal, alpha: a)

        case "backdrop", "background", "bg":
            if let first = evalArgs.first {
                switch first {
                case .string(let s):
                    scene.backdrop = BackdropKind.from(string: s)
                case .number(let n):
                    let raw = UInt32(max(0, Int(n.rounded())) % BackdropKind.allCases.count)
                    scene.backdrop = BackdropKind(rawValue: raw) ?? .cosmicVoid
                case .color:
                    break
                }
            }

        case "symmetry", "kaleidoscope":
            let sym = max(1, min(64, Int(evalArgs.first?.asNumber ?? 6.0)))
            scene.symmetryCount = sym
            if name == "kaleidoscope" {
                scene.mirrorSymmetry = evalArgs.count > 1 ? (evalArgs[1].asNumber != 0) : true
            } else if evalArgs.count > 1 {
                scene.mirrorSymmetry = (evalArgs[1].asNumber != 0)
            }

        case "sparkle", "emit", "burst":
            let count = max(1, min(200, Int(evalArgs.count > 0 ? evalArgs[0].asNumber : 24.0)))
            let size = Float(evalArgs.count > 1 ? evalArgs[1].asNumber : Double(activeTurtle.pose.width * 2.5))
            let speed = Float(evalArgs.count > 2 ? evalArgs[2].asNumber : 90.0)
            scene.bursts.append(
                ParticleBurstEvent(
                    position: activeTurtle.pose.position,
                    color: activeTurtle.pose.color,
                    count: count,
                    size: size,
                    speed: speed,
                    kind: name == "sparkle" ? 1 : 0,
                    stepIndex: scene.steps.count
                )
            )

        case "ripple":
            let radius = Float(evalArgs.count > 0 ? evalArgs[0].asNumber : 120.0)
            scene.ripples.append(
                RippleEvent(
                    position: activeTurtle.pose.position,
                    color: activeTurtle.pose.color,
                    radius: radius,
                    stepIndex: scene.steps.count
                )
            )

        case "seed", "randomseed":
            let s = UInt64(bitPattern: Int64(evalArgs.first?.asNumber ?? 42.0))
            rngState = s == 0 ? 0x853C49E6748FEA9B : s

        case "print", "log":
            let msg = evalArgs.map { $0.asString }.joined(separator: " ")
            scene.logs.append(msg)

        case "clean", "clear", "cs":
            scene.strokes.removeAll()
            scene.fillVertices.removeAll()
            scene.steps.removeAll()
            if name == "cs" {
                activeTurtle.pose.position = .zero
                activeTurtle.pose.headingRadians = .pi / 2.0
            }

        default:
            scene.diagnostics.append(
                DiagnosticMessage(
                    severity: .warning,
                    message: "Unknown command or procedure '\(name)' on line \(line).",
                    line: line
                )
            )
        }
    }

    private func callProcedure(_ proc: ProcedureDefinition, args: [Expr], line: Int) throws -> RuntimeValue {
        guard callDepth < maxCallDepth else {
            return .number(0.0)
        }
        let evaluatedArgs = try args.map { try evalExpr($0) }
        var frame: [String: RuntimeValue] = [:]
        for (idx, paramName) in proc.params.enumerated() {
            frame[paramName.lowercased()] = idx < evaluatedArgs.count ? evaluatedArgs[idx] : .number(0.0)
        }
        scopes.append(frame)
        callDepth += 1
        defer {
            callDepth -= 1
            _ = scopes.popLast()
        }

        do {
            for stmt in proc.body {
                try executeStatement(stmt)
            }
        } catch let ret as ReturnSignal {
            return ret.value ?? .number(0.0)
        }
        return .number(0.0)
    }

    // MARK: - Geometry & Symmetry Emission

    private func moveTurtleForward(distance: Float, line: Int) {
        let dir = SIMD2<Float>(cos(activeTurtle.pose.headingRadians), sin(activeTurtle.pose.headingRadians))
        let target = activeTurtle.pose.position + dir * distance
        moveTurtleTo(target: target, line: line)
    }

    private func moveTurtleTo(target: SIMD2<Float>, line: Int) {
        var startPose = activeTurtle.pose
        startPose.sourceLine = line
        let oldPos = activeTurtle.pose.position
        activeTurtle.pose.position = target
        activeTurtle.pose.sourceLine = line

        if activeTurtle.isFilling {
            activeTurtle.fillPolygonPoints.append((pos: target, color: activeTurtle.pose.color))
        }

        let segLen = simd_distance(oldPos, target)
        let oldDist = activeTurtle.cumulativeDist
        let newDist = oldDist + segLen
        activeTurtle.cumulativeDist = newDist
        scene.totalPathLength += segLen

        let strokeStartIdx = scene.strokes.count
        let stepIdx = scene.steps.count

        if activeTurtle.pose.penDown && segLen > 0.0001 {
            emitSymmetricStrokes(
                from: oldPos,
                to: target,
                colorStart: startPose.color,
                colorEnd: activeTurtle.pose.color,
                widthStart: startPose.width,
                widthEnd: activeTurtle.pose.width,
                glow: activeTurtle.pose.glow,
                brush: activeTurtle.pose.brush,
                distStart: oldDist,
                distEnd: newDist,
                stepIndex: UInt32(stepIdx)
            )
        }

        let strokeEndIdx = scene.strokes.count
        let fillIdx = scene.fillVertices.count
        scene.steps.append(
            TurtleStepRecord(
                stepIndex: stepIdx,
                startPose: startPose,
                endPose: activeTurtle.pose,
                strokeRange: strokeStartIdx..<strokeEndIdx,
                fillVertexRange: fillIdx..<fillIdx,
                sourceLine: line
            )
        )
    }

    private func emitDot(radius: Float, line: Int) {
        var startPose = activeTurtle.pose
        startPose.sourceLine = line
        let pos = activeTurtle.pose.position
        let tinyOffset = SIMD2<Float>(cos(activeTurtle.pose.headingRadians), sin(activeTurtle.pose.headingRadians)) * 0.05
        let strokeStartIdx = scene.strokes.count
        let stepIdx = scene.steps.count

        emitSymmetricStrokes(
            from: pos - tinyOffset,
            to: pos + tinyOffset,
            colorStart: activeTurtle.pose.color,
            colorEnd: activeTurtle.pose.color,
            widthStart: radius * 2.0,
            widthEnd: radius * 2.0,
            glow: activeTurtle.pose.glow,
            brush: activeTurtle.pose.brush,
            distStart: activeTurtle.cumulativeDist,
            distEnd: activeTurtle.cumulativeDist + 0.1,
            stepIndex: UInt32(stepIdx)
        )

        let strokeEndIdx = scene.strokes.count
        let fillIdx = scene.fillVertices.count
        scene.steps.append(
            TurtleStepRecord(
                stepIndex: stepIdx,
                startPose: startPose,
                endPose: activeTurtle.pose,
                strokeRange: strokeStartIdx..<strokeEndIdx,
                fillVertexRange: fillIdx..<fillIdx,
                sourceLine: line
            )
        )
    }

    private func drawCircleAroundCenter(radius: Float, segments: Int, line: Int) {
        let center = activeTurtle.pose.position
        let r = abs(radius)
        guard r > 0.01 else { return }

        var prevPoint = center + SIMD2<Float>(r, 0.0)
        let startPose = activeTurtle.pose
        let strokeStartIdx = scene.strokes.count
        let stepIdx = scene.steps.count

        for i in 1...segments {
            let angle = (Float(i) / Float(segments)) * (.pi * 2.0)
            let pt = center + SIMD2<Float>(cos(angle) * r, sin(angle) * r)
            let segLen = simd_distance(prevPoint, pt)
            let d0 = activeTurtle.cumulativeDist
            let d1 = d0 + segLen
            activeTurtle.cumulativeDist = d1

            emitSymmetricStrokes(
                from: prevPoint,
                to: pt,
                colorStart: activeTurtle.pose.color,
                colorEnd: activeTurtle.pose.color,
                widthStart: activeTurtle.pose.width,
                widthEnd: activeTurtle.pose.width,
                glow: activeTurtle.pose.glow,
                brush: activeTurtle.pose.brush,
                distStart: d0,
                distEnd: d1,
                stepIndex: UInt32(stepIdx)
            )
            prevPoint = pt
            if scene.strokes.count >= maxStrokes { break }
        }

        let strokeEndIdx = scene.strokes.count
        let fillIdx = scene.fillVertices.count
        scene.steps.append(
            TurtleStepRecord(
                stepIndex: stepIdx,
                startPose: startPose,
                endPose: activeTurtle.pose,
                strokeRange: strokeStartIdx..<strokeEndIdx,
                fillVertexRange: fillIdx..<fillIdx,
                sourceLine: line
            )
        )
    }

    private func drawTurtleArc(radius: Float, angleDegrees: Float, line: Int) {
        let steps = max(6, min(90, Int(abs(angleDegrees) / 4.0) + 4))
        let stepAngleDeg = angleDegrees / Float(steps)
        let stepAngleRad = stepAngleDeg * (.pi / 180.0)
        let chordLen = 2.0 * radius * sin(abs(stepAngleRad) * 0.5)
        let sign: Float = angleDegrees >= 0 ? 1.0 : -1.0

        for _ in 0..<steps {
            activeTurtle.pose.headingRadians -= sign * ( abs(stepAngleRad) * 0.5 )
            moveTurtleForward(distance: chordLen, line: line)
            activeTurtle.pose.headingRadians -= sign * ( abs(stepAngleRad) * 0.5 )
            if scene.strokes.count >= maxStrokes { break }
        }
    }

    private func drawRegularPolygon(sides: Int, radius: Float, filled: Bool, line: Int) {
        let center = activeTurtle.pose.position
        let baseAngle = activeTurtle.pose.headingRadians
        var vertices: [(pos: SIMD2<Float>, color: SIMD4<Float>)] = []
        for i in 0..<sides {
            let a = baseAngle + Float(i) * (2.0 * .pi / Float(sides))
            let pt = center + SIMD2<Float>(cos(a) * radius, sin(a) * radius)
            vertices.append((pos: pt, color: activeTurtle.pose.color))
        }

        let startPose = activeTurtle.pose
        let strokeStartIdx = scene.strokes.count
        let fillStartIdx = scene.fillVertices.count
        let stepIdx = scene.steps.count

        if filled {
            emitSymmetricPolygonFill(points: vertices, stepIndex: UInt32(stepIdx))
        }

        if activeTurtle.pose.penDown {
            for i in 0..<sides {
                let p0 = vertices[i].pos
                let p1 = vertices[(i + 1) % sides].pos
                let d0 = activeTurtle.cumulativeDist
                let d1 = d0 + simd_distance(p0, p1)
                activeTurtle.cumulativeDist = d1
                emitSymmetricStrokes(
                    from: p0,
                    to: p1,
                    colorStart: activeTurtle.pose.color,
                    colorEnd: activeTurtle.pose.color,
                    widthStart: activeTurtle.pose.width,
                    widthEnd: activeTurtle.pose.width,
                    glow: activeTurtle.pose.glow,
                    brush: activeTurtle.pose.brush,
                    distStart: d0,
                    distEnd: d1,
                    stepIndex: UInt32(stepIdx)
                )
            }
        }

        scene.steps.append(
            TurtleStepRecord(
                stepIndex: stepIdx,
                startPose: startPose,
                endPose: activeTurtle.pose,
                strokeRange: strokeStartIdx..<scene.strokes.count,
                fillVertexRange: fillStartIdx..<scene.fillVertices.count,
                sourceLine: line
            )
        )
    }

    private func drawStar(points: Int, outerRadius: Float, innerRadius: Float, line: Int) {
        let center = activeTurtle.pose.position
        let baseAngle = activeTurtle.pose.headingRadians
        let totalVerts = points * 2
        var vertices: [(pos: SIMD2<Float>, color: SIMD4<Float>)] = []
        for i in 0..<totalVerts {
            let r = (i % 2 == 0) ? outerRadius : innerRadius
            let a = baseAngle + Float(i) * (.pi / Float(points))
            let pt = center + SIMD2<Float>(cos(a) * r, sin(a) * r)
            vertices.append((pos: pt, color: activeTurtle.pose.color))
        }

        let startPose = activeTurtle.pose
        let strokeStartIdx = scene.strokes.count
        let fillStartIdx = scene.fillVertices.count
        let stepIdx = scene.steps.count

        emitSymmetricPolygonFill(points: vertices, stepIndex: UInt32(stepIdx))

        for i in 0..<totalVerts {
            let p0 = vertices[i].pos
            let p1 = vertices[(i + 1) % totalVerts].pos
            let d0 = activeTurtle.cumulativeDist
            let d1 = d0 + simd_distance(p0, p1)
            activeTurtle.cumulativeDist = d1
            emitSymmetricStrokes(
                from: p0,
                to: p1,
                colorStart: activeTurtle.pose.color,
                colorEnd: activeTurtle.pose.color,
                widthStart: activeTurtle.pose.width,
                widthEnd: activeTurtle.pose.width,
                glow: activeTurtle.pose.glow,
                brush: activeTurtle.pose.brush,
                distStart: d0,
                distEnd: d1,
                stepIndex: UInt32(stepIdx)
            )
        }

        scene.steps.append(
            TurtleStepRecord(
                stepIndex: stepIdx,
                startPose: startPose,
                endPose: activeTurtle.pose,
                strokeRange: strokeStartIdx..<scene.strokes.count,
                fillVertexRange: fillStartIdx..<scene.fillVertices.count,
                sourceLine: line
            )
        )
    }

    private func commitPolygonFill(line: Int) {
        let pts = activeTurtle.fillPolygonPoints
        guard pts.count >= 3 else { return }
        let startPose = activeTurtle.pose
        let strokeIdx = scene.strokes.count
        let fillStartIdx = scene.fillVertices.count
        let stepIdx = scene.steps.count

        emitSymmetricPolygonFill(points: pts, stepIndex: UInt32(stepIdx))

        scene.steps.append(
            TurtleStepRecord(
                stepIndex: stepIdx,
                startPose: startPose,
                endPose: activeTurtle.pose,
                strokeRange: strokeIdx..<strokeIdx,
                fillVertexRange: fillStartIdx..<scene.fillVertices.count,
                sourceLine: line
            )
        )
    }

    private func emitSymmetricStrokes(
        from p0: SIMD2<Float>,
        to p1: SIMD2<Float>,
        colorStart: SIMD4<Float>,
        colorEnd: SIMD4<Float>,
        widthStart: Float,
        widthEnd: Float,
        glow: Float,
        brush: BrushKind,
        distStart: Float,
        distEnd: Float,
        stepIndex: UInt32
    ) {
        let symCount = max(1, scene.symmetryCount)
        let seedVal = Float(nextRandom01())

        for s in 0..<symCount {
            if scene.strokes.count >= maxStrokes { break }
            let angle = Float(s) * (2.0 * .pi / Float(symCount))
            let cosA = cos(angle)
            let sinA = sin(angle)

            let r0 = SIMD2<Float>(p0.x * cosA - p0.y * sinA, p0.x * sinA + p0.y * cosA)
            let r1 = SIMD2<Float>(p1.x * cosA - p1.y * sinA, p1.x * sinA + p1.y * cosA)

            scene.strokes.append(
                StrokeInstanceGPU(
                    start: r0,
                    end: r1,
                    colorStart: colorStart,
                    colorEnd: colorEnd,
                    widthStart: widthStart,
                    widthEnd: widthEnd,
                    glow: glow,
                    brushKind: brush.rawValue,
                    cumulativeDistStart: distStart,
                    cumulativeDistEnd: distEnd,
                    seed: seedVal + Float(s) * 0.137,
                    stepIndex: stepIndex
                )
            )

            if scene.mirrorSymmetry && scene.strokes.count < maxStrokes {
                let m0 = SIMD2<Float>(-p0.x * cosA - p0.y * sinA, -p0.x * sinA + p0.y * cosA)
                let m1 = SIMD2<Float>(-p1.x * cosA - p1.y * sinA, -p1.x * sinA + p1.y * cosA)
                scene.strokes.append(
                    StrokeInstanceGPU(
                        start: m0,
                        end: m1,
                        colorStart: colorStart,
                        colorEnd: colorEnd,
                        widthStart: widthStart,
                        widthEnd: widthEnd,
                        glow: glow,
                        brushKind: brush.rawValue,
                        cumulativeDistStart: distStart,
                        cumulativeDistEnd: distEnd,
                        seed: seedVal + Float(s) * 0.271,
                        stepIndex: stepIndex
                    )
                )
            }
        }
    }

    private func emitSymmetricPolygonFill(points: [(pos: SIMD2<Float>, color: SIMD4<Float>)], stepIndex: UInt32) {
        guard points.count >= 3 else { return }
        // Centroid fan triangulation (works great for star/convex/flower shapes)
        var centerPos = SIMD2<Float>.zero
        var centerCol = SIMD4<Float>.zero
        for pt in points {
            centerPos += pt.pos
            centerCol += pt.color
        }
        centerPos /= Float(points.count)
        centerCol /= Float(points.count)
        centerCol.w *= 0.48 // Semi-translucent luminous fill by default

        let symCount = max(1, scene.symmetryCount)
        let glowVal = activeTurtle.pose.glow * 0.65

        for s in 0..<symCount {
            let angle = Float(s) * (2.0 * .pi / Float(symCount))
            let cosA = cos(angle)
            let sinA = sin(angle)

            func rot(_ v: SIMD2<Float>) -> SIMD2<Float> {
                SIMD2<Float>(v.x * cosA - v.y * sinA, v.x * sinA + v.y * cosA)
            }

            let rc = rot(centerPos)
            for i in 0..<points.count {
                let p0 = points[i]
                let p1 = points[(i + 1) % points.count]
                var c0 = p0.color; c0.w *= 0.65
                var c1 = p1.color; c1.w *= 0.65
                scene.fillVertices.append(FillVertexGPU(position: rc, color: centerCol, glow: glowVal, stepIndex: stepIndex))
                scene.fillVertices.append(FillVertexGPU(position: rot(p0.pos), color: c0, glow: glowVal, stepIndex: stepIndex))
                scene.fillVertices.append(FillVertexGPU(position: rot(p1.pos), color: c1, glow: glowVal, stepIndex: stepIndex))
            }

            if scene.mirrorSymmetry {
                func rotMirror(_ v: SIMD2<Float>) -> SIMD2<Float> {
                    SIMD2<Float>(-v.x * cosA - v.y * sinA, -v.x * sinA + v.y * cosA)
                }
                let mc = rotMirror(centerPos)
                for i in 0..<points.count {
                    let p0 = points[i]
                    let p1 = points[(i + 1) % points.count]
                    var c0 = p0.color; c0.w *= 0.65
                    var c1 = p1.color; c1.w *= 0.65
                    scene.fillVertices.append(FillVertexGPU(position: mc, color: centerCol, glow: glowVal, stepIndex: stepIndex))
                    scene.fillVertices.append(FillVertexGPU(position: rotMirror(p0.pos), color: c0, glow: glowVal, stepIndex: stepIndex))
                    scene.fillVertices.append(FillVertexGPU(position: rotMirror(p1.pos), color: c1, glow: glowVal, stepIndex: stepIndex))
                }
            }
        }
    }

    // MARK: - Expression Evaluation

    private func evalExpr(_ expr: Expr) throws -> RuntimeValue {
        switch expr {
        case .number(let n):
            return .number(n)
        case .string(let s):
            return .string(s)
        case .colorHex(let hex):
            if let c = ColorUtils.parseHexOrName(hex) {
                return .color(c)
            }
            return .string(hex)
        case .variable(let name):
            let lower = name.lowercased()
            if lower == "t" || lower == "time" {
                scene.usesTimeVariable = true
            }
            if lower == "x" { return .number(Double(activeTurtle.pose.position.x)) }
            if lower == "y" { return .number(Double(activeTurtle.pose.position.y)) }
            if lower == "heading" {
                let deg = ((.pi / 2.0) - activeTurtle.pose.headingRadians) * 180.0 / .pi
                return .number(Double(deg))
            }
            if lower == "dist" {
                return .number(Double(activeTurtle.cumulativeDist))
            }
            if let val = lookupVariable(lower) {
                return val
            }
            // Also check if variable name is a known color name or brush name!
            if let c = ColorUtils.parseHexOrName(lower) {
                return .color(c)
            }
            return .string(name)

        case .unary(let op, let inner):
            let v = try evalExpr(inner)
            switch op {
            case .minus:
                return .number(-v.asNumber)
            case .not:
                return .number(isTruthy(v) ? 0.0 : 1.0)
            default:
                return v
            }

        case .binary(let lhsExpr, let op, let rhsExpr):
            let lhs = try evalExpr(lhsExpr)
            let rhs = try evalExpr(rhsExpr)
            let a = lhs.asNumber
            let b = rhs.asNumber

            switch op {
            case .plus:
                if case .string(let s1) = lhs {
                    return .string(s1 + rhs.asString)
                }
                return .number(a + b)
            case .minus: return .number(a - b)
            case .star: return .number(a * b)
            case .slash: return .number(abs(b) < 1e-12 ? 0.0 : a / b)
            case .percent: return .number(abs(b) < 1e-12 ? 0.0 : a.truncatingRemainder(dividingBy: b))
            case .caret: return .number(pow(a, b))
            case .eq:
                return .number(lhs == rhs || abs(a - b) < 1e-7 ? 1.0 : 0.0)
            case .neq:
                return .number(lhs != rhs && abs(a - b) >= 1e-7 ? 1.0 : 0.0)
            case .lt: return .number(a < b ? 1.0 : 0.0)
            case .lte: return .number(a <= b ? 1.0 : 0.0)
            case .gt: return .number(a > b ? 1.0 : 0.0)
            case .gte: return .number(a >= b ? 1.0 : 0.0)
            case .and: return .number((isTruthy(lhs) && isTruthy(rhs)) ? 1.0 : 0.0)
            case .or: return .number((isTruthy(lhs) || isTruthy(rhs)) ? 1.0 : 0.0)
            default: return .number(0.0)
            }

        case .call(let name, let args):
            if let proc = procedures[name] {
                return try callProcedure(proc, args: args, line: activeTurtle.pose.sourceLine)
            }
            let vals = try args.map { try evalExpr($0) }
            return evalBuiltinFunction(name: name, args: vals)
        }
    }

    private func evalBuiltinFunction(name: String, args: [RuntimeValue]) -> RuntimeValue {
        let a0 = args.count > 0 ? args[0].asNumber : 0.0
        let a1 = args.count > 1 ? args[1].asNumber : 0.0
        let a2 = args.count > 2 ? args[2].asNumber : 0.0
        let a3 = args.count > 3 ? args[3].asNumber : 1.0

        switch name {
        // Degree-based trig (Logo friendly!) + Radian variants
        case "sin": return .number(sin(a0 * .pi / 180.0))
        case "cos": return .number(cos(a0 * .pi / 180.0))
        case "tan": return .number(tan(a0 * .pi / 180.0))
        case "sinr": return .number(sin(a0))
        case "cosr": return .number(cos(a0))
        case "atan2": return .number(atan2(a0, a1) * 180.0 / .pi)
        case "sqrt": return .number(sqrt(max(0.0, a0)))
        case "abs": return .number(abs(a0))
        case "floor": return .number(floor(a0))
        case "ceil": return .number(ceil(a0))
        case "round": return .number(a0.rounded())
        case "min": return .number(min(a0, a1))
        case "max": return .number(max(a0, a1))
        case "pow": return .number(pow(a0, a1))
        case "mod": return .number(abs(a1) < 1e-12 ? 0.0 : ((a0.truncatingRemainder(dividingBy: a1)) + a1).truncatingRemainder(dividingBy: a1))
        case "lerp", "mix": return .number(a0 + (a1 - a0) * a2)
        case "clamp": return .number(min(max(a0, a1), a2))
        case "smoothstep":
            let t = min(max((a2 - a0) / max(1e-9, a1 - a0), 0.0), 1.0)
            return .number(t * t * (3.0 - 2.0 * t))
        case "wave":
            // Smooth 0..1 sine wave with frequency a0 and phase a1
            scene.usesTimeVariable = true
            let freq = args.count > 0 ? a0 : 1.0
            let phase = args.count > 1 ? a1 : 0.0
            return .number(0.5 + 0.5 * sin(timeSeconds * freq * 2.0 * .pi + phase))
        case "rand", "random":
            let r = nextRandom01()
            if args.isEmpty { return .number(r) }
            if args.count == 1 { return .number(r * a0) }
            return .number(a0 + r * (a1 - a0))
        case "noise":
            return .number(valueNoise2D(x: a0, y: args.count > 1 ? a1 : 0.0))
        case "hsl", "hsv":
            return .color(ColorUtils.hsl(a0, args.count > 1 ? a1 : 85.0, args.count > 2 ? a2 : 60.0, args.count > 3 ? a3 : 1.0))
        case "rgb":
            var r = Float(a0), g = Float(a1), b = Float(a2)
            if r > 1.0 || g > 1.0 || b > 1.0 { r /= 255.0; g /= 255.0; b /= 255.0 }
            return .color(SIMD4<Float>(r, g, b, Float(a3)))
        case "palette":
            let pName = args.count > 0 ? args[0].asString : "cyberpunk"
            return .color(ColorUtils.namedPalette(pName, t: Float(a1)))
        default:
            return .number(0.0)
        }
    }

    // MARK: - Variables & Determinism

    private func lookupVariable(_ name: String) -> RuntimeValue? {
        let key = name.lowercased()
        for scope in scopes.reversed() {
            if let val = scope[key] { return val }
        }
        return globals[key]
    }

    private func setVariable(_ name: String, value: RuntimeValue) {
        let key = name.lowercased()
        if !scopes.isEmpty {
            if scopes[scopes.count - 1][key] != nil {
                scopes[scopes.count - 1][key] = value
                return
            }
        }
        globals[key] = value
    }

    private func isTruthy(_ val: RuntimeValue) -> Bool {
        switch val {
        case .number(let n): return abs(n) > 1e-9
        case .string(let s): return !s.isEmpty && s != "0" && s.lowercased() != "false"
        case .color: return true
        }
    }

    private func nextRandom01() -> Double {
        // Xorshift64*
        var x = rngState
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        rngState = x
        let mult = x &* 0x2545F4914F6CDD1D
        return Double(mult >> 11) / Double(1 << 53)
    }

    private func valueNoise2D(x: Double, y: Double) -> Double {
        let xi = Int(floor(x))
        let yi = Int(floor(y))
        let xf = x - floor(x)
        let yf = y - floor(y)

        func hash(_ ix: Int, _ iy: Int) -> Double {
            var n = UInt64(bitPattern: Int64(ix &* 374761393 &+ iy &* 668265263))
            n = (n ^ (n >> 13)) &* 1274126177
            return Double((n ^ (n >> 16)) & 0xFFFFFF) / Double(0xFFFFFF)
        }

        let u = xf * xf * (3.0 - 2.0 * xf)
        let v = yf * yf * (3.0 - 2.0 * yf)

        let a = hash(xi, yi)
        let b = hash(xi + 1, yi)
        let c = hash(xi, yi + 1)
        let d = hash(xi + 1, yi + 1)

        let x1 = a + u * (b - a)
        let x2 = c + u * (d - c)
        return (x1 + v * (x2 - x1)) * 2.0 - 1.0
    }
}
