import Foundation
import simd

public final class Parser {
    private let tokens: [Token]
    private var current: Int = 0
    private var diagnostics: [DiagnosticMessage] = []
    private var parameters: [ProgramParameter] = []
    /// Tracks user-defined procedure parameter counts so space-separated calls know their arity
    private var procArity: [String: Int] = [:]

    public init(tokens: [Token]) {
        self.tokens = tokens
        self.prescanProcedures()
    }

    /// Pre-scans `to <name> <params...>` declarations so procedure calls before or after definition know their arity.
    private func prescanProcedures() {
        var idx = 0
        while idx < tokens.count {
            if tokens[idx].kind == .kwTo {
                idx += 1
                if idx < tokens.count, case .identifier(let procName) = tokens[idx].kind {
                    idx += 1
                    var count = 0
                    if idx < tokens.count && tokens[idx].kind == .lParen {
                        idx += 1
                        while idx < tokens.count && tokens[idx].kind != .rParen && tokens[idx].kind != .newline && tokens[idx].kind != .eof {
                            if case .identifier = tokens[idx].kind {
                                count += 1
                            }
                            idx += 1
                        }
                    } else {
                        while idx < tokens.count {
                            let k = tokens[idx].kind
                            if k == .lBrace || k == .newline || k == .eof { break }
                            if case .identifier = k {
                                count += 1
                            }
                            idx += 1
                        }
                    }
                    procArity[procName.lowercased()] = count
                }
            } else {
                idx += 1
            }
        }
    }

    public func parse() -> ProgramAST {
        var statements: [Stmt] = []
        skipNewlines()
        while !isAtEnd {
            if let stmt = parseStatement() {
                statements.append(stmt)
            } else {
                synchronize()
            }
            skipNewlines()
        }
        return ProgramAST(statements: statements, parameters: parameters, diagnostics: diagnostics)
    }

    // MARK: - Statements

    private func parseStatement() -> Stmt? {
        skipNewlines()
        guard !isAtEnd else { return nil }

        let tok = peek()
        switch tok.kind {
        case .paramDirective:
            return parseParamDirective()
        case .kwLet:
            return parseLetStatement()
        case .kwRepeat:
            return parseRepeatStatement()
        case .kwFor:
            return parseForStatement()
        case .kwWhile:
            return parseWhileStatement()
        case .kwIf:
            return parseIfStatement()
        case .kwTo:
            return parseProcDefinition()
        case .kwBranch:
            return parseBranchStatement()
        case .kwSpawn:
            return parseSpawnStatement()
        case .kwLSystem:
            return parseLSystemStatement()
        case .kwReturn:
            return parseReturnStatement()
        case .identifier(let name):
            // Check if assignment: `name = expr`
            if peekNext().kind == .assign {
                let line = tok.line
                _ = advance() // name
                _ = advance() // =
                guard let expr = parseExpression() else {
                    error("Expected expression after '=' for variable '\(name)'.", at: peek())
                    return nil
                }
                return .varAssign(name: name, expr: expr, line: line)
            }
            return parseCommandOrProcCall()
        default:
            error("Unexpected token '\(tok.lexeme)' on line \(tok.line).", at: tok)
            _ = advance()
            return nil
        }
    }

    /// Parses `@param <name> <default> [min] [max] [step] [label]`
    /// or `@param <name> #RRGGBB [label]`
    private func parseParamDirective() -> Stmt? {
        let startTok = advance() // consume @param
        let line = startTok.line
        guard case .identifier(let name) = peek().kind else {
            error("Expected parameter variable name after '@param'.", at: peek())
            return nil
        }
        _ = advance()
        if peek().kind == .comma || peek().kind == .assign { _ = advance() }

        // Color parameter?
        if case .colorHex(let hex) = peek().kind {
            _ = advance()
            let colorVal = ColorUtils.parseHexOrName(hex) ?? SIMD4<Float>(0.2, 0.9, 1.0, 1.0)
            var label = formatLabel(name)
            if case .string(let customLabel) = peek().kind {
                _ = advance()
                label = customLabel
            }
            let param = ProgramParameter(
                name: name,
                label: label,
                control: .color,
                defaultValue: 0.0,
                defaultColor: colorVal,
                sourceLine: line
            )
            parameters.append(param)
            return .paramDecl(param)
        }

        // Numeric parameter
        guard let defaultVal = parseSignedNumberLiteral() else {
            error("Expected default number or #hex color after '@param \(name)'.", at: peek())
            return nil
        }
        if peek().kind == .comma { _ = advance() }

        var minVal = min(0.0, defaultVal)
        var maxVal = max(100.0, defaultVal * 2.0)
        var stepVal: Double? = nil
        var label = formatLabel(name)

        if let parsedMin = parseSignedNumberLiteral() {
            minVal = parsedMin
            if peek().kind == .comma { _ = advance() }
            if let parsedMax = parseSignedNumberLiteral() {
                maxVal = parsedMax
                if peek().kind == .comma { _ = advance() }
                if let parsedStep = parseSignedNumberLiteral() {
                    stepVal = parsedStep
                    if peek().kind == .comma { _ = advance() }
                }
            }
        }

        if case .string(let customLabel) = peek().kind {
            _ = advance()
            label = customLabel
        }

        let param = ProgramParameter(
            name: name,
            label: label,
            control: .slider(min: minVal, max: maxVal, step: stepVal),
            defaultValue: defaultVal,
            defaultColor: nil,
            sourceLine: line
        )
        parameters.append(param)
        return .paramDecl(param)
    }

    private func parseSignedNumberLiteral() -> Double? {
        if case .number(let n) = peek().kind {
            _ = advance()
            return n
        }
        if peek().kind == .minus, case .number(let n) = peekNext().kind {
            _ = advance()
            _ = advance()
            return -n
        }
        return nil
    }

    private func parseLetStatement() -> Stmt? {
        let startTok = advance() // consume let/make
        guard case .identifier(let name) = peek().kind else {
            error("Expected variable name after '\(startTok.lexeme)'.", at: peek())
            return nil
        }
        _ = advance()
        if peek().kind == .assign {
            _ = advance()
        }
        guard let expr = parseExpression() else {
            error("Expected expression for variable '\(name)'.", at: peek())
            return nil
        }
        return .varAssign(name: name, expr: expr, line: startTok.line)
    }

    private func parseRepeatStatement() -> Stmt? {
        let startTok = advance() // consume repeat
        guard let countExpr = parseExpression() else {
            error("Expected repeat count expression after 'repeat'.", at: peek())
            return nil
        }
        let body = parseBlock()
        return .repeatLoop(count: countExpr, body: body, line: startTok.line)
    }

    private func parseForStatement() -> Stmt? {
        let startTok = advance() // consume for
        guard case .identifier(let varName) = peek().kind else {
            error("Expected loop variable name after 'for'.", at: peek())
            return nil
        }
        _ = advance()

        if peek().kind == .kwIn || peek().kind == .assign {
            _ = advance()
        }

        guard let startExpr = parseExpression() else {
            error("Expected start expression in 'for' loop.", at: peek())
            return nil
        }

        // Expect `..` or `to` or comma
        if peek().kind == .dotDot || peek().kind == .kwTo || peek().kind == .comma {
            _ = advance()
        } else {
            error("Expected '..' or 'to' in 'for \(varName) in start..end' range.", at: peek())
        }

        guard let endExpr = parseExpression() else {
            error("Expected end expression in 'for' loop range.", at: peek())
            return nil
        }

        var stepExpr: Expr? = nil
        if case .identifier(let stepKw) = peek().kind, stepKw.lowercased() == "step" {
            _ = advance()
            stepExpr = parseExpression()
        } else if peek().kind == .comma {
            _ = advance()
            stepExpr = parseExpression()
        }

        let body = parseBlock()
        return .forLoop(variable: varName, start: startExpr, end: endExpr, step: stepExpr, body: body, line: startTok.line)
    }

    private func parseWhileStatement() -> Stmt? {
        let startTok = advance() // consume while
        guard let cond = parseExpression() else {
            error("Expected condition after 'while'.", at: peek())
            return nil
        }
        let body = parseBlock()
        return .whileLoop(condition: cond, body: body, line: startTok.line)
    }

    private func parseIfStatement() -> Stmt? {
        let startTok = advance() // consume if
        guard let cond = parseExpression() else {
            error("Expected condition after 'if'.", at: peek())
            return nil
        }
        let thenBody = parseBlock()
        skipNewlines()
        var elseBody: [Stmt]? = nil
        if peek().kind == .kwElse {
            _ = advance()
            skipNewlines()
            if peek().kind == .kwIf {
                if let nestedIf = parseIfStatement() {
                    elseBody = [nestedIf]
                }
            } else {
                elseBody = parseBlock()
            }
        }
        return .ifStmt(condition: cond, thenBody: thenBody, elseBody: elseBody, line: startTok.line)
    }

    private func parseProcDefinition() -> Stmt? {
        let startTok = advance() // consume `to` / `def`
        guard case .identifier(let procName) = peek().kind else {
            error("Expected procedure name after 'to'.", at: peek())
            return nil
        }
        _ = advance()

        var params: [String] = []
        if peek().kind == .lParen {
            _ = advance()
            while !isAtEnd && peek().kind != .rParen {
                if case .identifier(let p) = peek().kind {
                    params.append(p)
                    _ = advance()
                }
                if peek().kind == .comma { _ = advance() }
                else if peek().kind != .rParen { break }
            }
            if peek().kind == .rParen { _ = advance() }
        } else {
            while !isAtEnd && peek().kind != .lBrace && peek().kind != .newline {
                if case .identifier(let p) = peek().kind {
                    params.append(p)
                    _ = advance()
                    if peek().kind == .comma { _ = advance() }
                } else {
                    break
                }
            }
        }

        procArity[procName.lowercased()] = params.count
        let body = parseBlock(allowEndKeyword: true)
        return .procDef(name: procName, params: params, body: body, line: startTok.line)
    }

    private func parseBranchStatement() -> Stmt? {
        let startTok = advance() // consume branch
        let body = parseBlock()
        return .branchBlock(body: body, line: startTok.line)
    }

    private func parseSpawnStatement() -> Stmt? {
        let startTok = advance() // consume spawn
        let body = parseBlock()
        return .spawnBlock(body: body, line: startTok.line)
    }

    private func parseReturnStatement() -> Stmt? {
        let startTok = advance() // consume return
        if peek().kind == .newline || peek().kind == .rBrace || peek().kind == .kwEnd || peek().kind == .eof {
            return .returnStmt(expr: nil, line: startTok.line)
        }
        let expr = parseExpression()
        return .returnStmt(expr: expr, line: startTok.line)
    }

    /// Parses an `lsystem { axiom "F", generations 4, angle 25, size 10, rule "F" -> "F[+F]F[-F]F" }` block
    private func parseLSystemStatement() -> Stmt? {
        let startTok = advance() // consume lsystem
        skipNewlines()
        guard peek().kind == .lBrace else {
            error("Expected '{' after 'lsystem'.", at: peek())
            return nil
        }
        _ = advance() // consume '{'
        skipNewlines()

        var axiomExpr: Expr = .string("F")
        var genExpr: Expr = .number(4)
        var angleExpr: Expr = .number(25)
        var sizeExpr: Expr = .number(10)
        var decayExpr: Expr? = nil
        var rules: [String: String] = [:]
        var symbolActions: [String: [Stmt]] = [:]

        while !isAtEnd && peek().kind != .rBrace {
            skipNewlines()
            if peek().kind == .rBrace { break }

            if case .identifier(let keyRaw) = peek().kind {
                let key = keyRaw.lowercased()
                _ = advance()
                if peek().kind == .colon || peek().kind == .assign {
                    _ = advance()
                }

                switch key {
                case "axiom", "start":
                    if let e = parseExpression() { axiomExpr = e }
                case "generations", "gen", "depth", "iterations":
                    if let e = parseExpression() { genExpr = e }
                case "angle", "turn":
                    if let e = parseExpression() { angleExpr = e }
                case "size", "step", "length", "dist":
                    if let e = parseExpression() { sizeExpr = e }
                case "decay", "scale":
                    if let e = parseExpression() { decayExpr = e }
                case "rule":
                    // rule "X" -> "F-[[X]+X]+F[+FX]-X" or rule X -> "..."
                    let lhs = parseSymbolString()
                    if peek().kind == .arrow || peek().kind == .assign || peek().kind == .colon {
                        _ = advance()
                    }
                    let rhs = parseSymbolString()
                    if !lhs.isEmpty {
                        rules[lhs] = rhs
                    }
                case "draw", "action", "on":
                    let sym = parseSymbolString()
                    let actionBody = parseBlock()
                    if !sym.isEmpty {
                        symbolActions[sym] = actionBody
                    }
                default:
                    // Shorthand rule: `F -> "FF+[+F-F-F]-[-F+F+F]"`
                    if peek().kind == .arrow {
                        _ = advance()
                        let rhs = parseSymbolString()
                        rules[keyRaw] = rhs
                    } else {
                        _ = parseExpression()
                    }
                }
            } else if case .string(let sym) = peek().kind {
                _ = advance()
                if peek().kind == .arrow || peek().kind == .colon {
                    _ = advance()
                    let rhs = parseSymbolString()
                    rules[sym] = rhs
                }
            } else {
                _ = advance()
            }

            if peek().kind == .comma { _ = advance() }
            skipNewlines()
        }

        if peek().kind == .rBrace {
            _ = advance()
        } else {
            error("Expected '}' to close 'lsystem' block.", at: peek())
        }

        return .lsystemBlock(
            axiom: axiomExpr,
            generations: genExpr,
            angle: angleExpr,
            stepSize: sizeExpr,
            decay: decayExpr,
            rules: rules,
            symbolActions: symbolActions,
            line: startTok.line
        )
    }

    private func parseSymbolString() -> String {
        switch peek().kind {
        case .string(let s):
            _ = advance()
            return s
        case .identifier(let id):
            _ = advance()
            return id
        default:
            return ""
        }
    }

    private func parseBlock(allowEndKeyword: Bool = false) -> [Stmt] {
        skipNewlines()
        var stmts: [Stmt] = []
        if peek().kind == .lBrace {
            let openTok = advance()
            skipNewlines()
            while !isAtEnd && peek().kind != .rBrace {
                if let s = parseStatement() {
                    stmts.append(s)
                } else {
                    synchronize(stopAtBrace: true)
                }
                skipNewlines()
            }
            if peek().kind == .rBrace {
                _ = advance()
            } else {
                error("Missing closing '}' for block starting on line \(openTok.line).", at: peek())
            }
            return stmts
        } else if allowEndKeyword {
            while !isAtEnd && peek().kind != .kwEnd {
                if let s = parseStatement() {
                    stmts.append(s)
                } else {
                    synchronize()
                }
                skipNewlines()
            }
            if peek().kind == .kwEnd {
                _ = advance()
            } else {
                error("Missing 'end' or '}' for procedure definition.", at: peek())
            }
            return stmts
        } else {
            // Single statement on same/next line or expect `{`
            error("Expected '{' to start block.", at: peek())
            if let s = parseStatement() {
                stmts.append(s)
            }
            return stmts
        }
    }

    // MARK: - Command or Procedure Call

    private func parseCommandOrProcCall() -> Stmt? {
        let cmdTok = advance()
        guard case .identifier(let rawName) = cmdTok.kind else { return nil }
        let lowerName = rawName.lowercased()
        let line = cmdTok.line

        var args: [Expr] = []

        // If called with parentheses: `circle(50)` or `goto(10, 20)`
        if peek().kind == .lParen && peek().range.lowerBound == cmdTok.range.upperBound {
            _ = advance() // consume '('
            while !isAtEnd && peek().kind != .rParen && peek().kind != .newline {
                if let expr = parseExpression() {
                    args.append(expr)
                }
                if peek().kind == .comma {
                    _ = advance()
                } else {
                    break
                }
            }
            if peek().kind == .rParen { _ = advance() }
            return .command(name: lowerName, args: args, line: line)
        }

        // Otherwise space-separated or comma-separated arguments on the same line
        let maxArgs = expectedMaxArity(for: lowerName)
        while args.count < maxArgs && !isAtStatementBoundary() {
            guard let expr = parseExpression() else { break }
            args.append(expr)
            if peek().kind == .comma {
                _ = advance()
            }
        }

        return .command(name: lowerName, args: args, line: line)
    }

    private func isAtStatementBoundary() -> Bool {
        switch peek().kind {
        case .newline, .eof, .rBrace, .lBrace, .kwEnd, .kwElse:
            return true
        case .identifier(let nextId):
            // If the next identifier is a known statement command and we're not separated by an operator,
            // wait: what if an argument IS a variable name? Variables are valid expressions!
            // That's why `expectedMaxArity` bounds how many arguments a command consumes.
            _ = nextId
            return false
        default:
            return false
        }
    }

    private func expectedMaxArity(for cmd: String) -> Int {
        if let userArity = procArity[cmd] {
            return userArity
        }
        switch cmd {
        case "pu", "penup", "pd", "pendown", "home", "clean", "clear", "cs",
             "beginfill", "begin_fill", "endfill", "end_fill", "noop":
            return 0
        case "fd", "forward", "bk", "back", "backward",
             "lt", "left", "rt", "right",
             "setx", "sety", "seth", "setheading", "heading",
             "width", "penwidth", "pensize", "size",
             "glow", "bloom", "alpha", "opacity",
             "brush", "backdrop", "background", "bg",
             "seed", "randomseed", "print", "log":
            return 1
        case "goto", "setxy", "setpos", "move",
             "circle", "dot", "symmetry", "kaleidoscope":
            return 2
        case "arc", "star", "polygon", "poly", "sparkle", "emit", "burst", "ripple":
            return 3
        case "color", "pencolor", "pc", "rgb", "hsl", "hsv", "palette":
            return 4
        default:
            return 8
        }
    }

    // MARK: - Expressions (Precedence Climbing)

    private func parseExpression() -> Expr? {
        return parseOr()
    }

    private func parseOr() -> Expr? {
        guard var lhs = parseAnd() else { return nil }
        while peek().kind == .or {
            let op = advance().kind
            guard let rhs = parseAnd() else { return lhs }
            lhs = .binary(lhs: lhs, op: op, rhs: rhs)
        }
        return lhs
    }

    private func parseAnd() -> Expr? {
        guard var lhs = parseEquality() else { return nil }
        while peek().kind == .and {
            let op = advance().kind
            guard let rhs = parseEquality() else { return lhs }
            lhs = .binary(lhs: lhs, op: op, rhs: rhs)
        }
        return lhs
    }

    private func parseEquality() -> Expr? {
        guard var lhs = parseComparison() else { return nil }
        while peek().kind == .eq || peek().kind == .neq {
            let op = advance().kind
            guard let rhs = parseComparison() else { return lhs }
            lhs = .binary(lhs: lhs, op: op, rhs: rhs)
        }
        return lhs
    }

    private func parseComparison() -> Expr? {
        guard var lhs = parseAdditive() else { return nil }
        while peek().kind == .lt || peek().kind == .lte || peek().kind == .gt || peek().kind == .gte {
            let op = advance().kind
            guard let rhs = parseAdditive() else { return lhs }
            lhs = .binary(lhs: lhs, op: op, rhs: rhs)
        }
        return lhs
    }

    private func parseAdditive() -> Expr? {
        guard var lhs = parseMultiplicative() else { return nil }
        while peek().kind == .plus || peek().kind == .minus {
            let op = advance().kind
            guard let rhs = parseMultiplicative() else { return lhs }
            lhs = .binary(lhs: lhs, op: op, rhs: rhs)
        }
        return lhs
    }

    private func parseMultiplicative() -> Expr? {
        guard var lhs = parsePower() else { return nil }
        while peek().kind == .star || peek().kind == .slash || peek().kind == .percent {
            let op = advance().kind
            guard let rhs = parsePower() else { return lhs }
            lhs = .binary(lhs: lhs, op: op, rhs: rhs)
        }
        return lhs
    }

    private func parsePower() -> Expr? {
        guard let lhs = parseUnary() else { return nil }
        if peek().kind == .caret {
            let op = advance().kind
            guard let rhs = parsePower() else { return lhs }
            return .binary(lhs: lhs, op: op, rhs: rhs)
        }
        return lhs
    }

    private func parseUnary() -> Expr? {
        if peek().kind == .minus || peek().kind == .not || peek().kind == .plus {
            let op = advance().kind
            guard let operand = parseUnary() else { return nil }
            if op == .plus { return operand }
            return .unary(op: op, expr: operand)
        }
        return parsePrimary()
    }

    private func parsePrimary() -> Expr? {
        let tok = peek()
        switch tok.kind {
        case .number(let val):
            _ = advance()
            return .number(val)
        case .string(let s):
            _ = advance()
            return .string(s)
        case .colorHex(let hex):
            _ = advance()
            return .colorHex(hex)
        case .identifier(let name):
            _ = advance()
            if peek().kind == .lParen {
                _ = advance() // consume '('
                var args: [Expr] = []
                while !isAtEnd && peek().kind != .rParen {
                    if let arg = parseExpression() {
                        args.append(arg)
                    }
                    if peek().kind == .comma {
                        _ = advance()
                    } else {
                        break
                    }
                }
                if peek().kind == .rParen {
                    _ = advance()
                } else {
                    error("Expected ')' after arguments to '\(name)'.", at: peek())
                }
                return .call(name: name.lowercased(), args: args)
            }
            return .variable(name)
        case .lParen:
            _ = advance() // consume '('
            guard let inner = parseExpression() else {
                error("Expected expression inside parentheses.", at: peek())
                return nil
            }
            if peek().kind == .rParen {
                _ = advance()
            } else {
                error("Expected closing ')'.", at: peek())
            }
            return inner
        default:
            return nil
        }
    }

    // MARK: - Utilities

    private var isAtEnd: Bool {
        peek().kind == .eof
    }

    private func peek() -> Token {
        tokens[current]
    }

    private func peekNext() -> Token {
        guard current + 1 < tokens.count else { return tokens.last! }
        return tokens[current + 1]
    }

    private func advance() -> Token {
        if !isAtEnd { current += 1 }
        return tokens[current - 1]
    }

    private func skipNewlines() {
        while !isAtEnd && peek().kind == .newline {
            _ = advance()
        }
    }

    private func synchronize(stopAtBrace: Bool = false) {
        while !isAtEnd {
            if peek().kind == .newline {
                _ = advance()
                return
            }
            if stopAtBrace && peek().kind == .rBrace {
                return
            }
            _ = advance()
        }
    }

    private func error(_ message: String, at token: Token) {
        diagnostics.append(DiagnosticMessage(severity: .error, message: message, line: token.line, column: token.column))
    }

    private func formatLabel(_ raw: String) -> String {
        let withSpaces = raw.replacingOccurrences(of: "_", with: " ")
        return withSpaces.prefix(1).uppercased() + withSpaces.dropFirst()
    }
}
