import Foundation
import simd

public indirect enum Expr: Sendable, Equatable {
    case number(Double)
    case string(String)
    case colorHex(String)
    case variable(String)
    case unary(op: TokenKind, expr: Expr)
    case binary(lhs: Expr, op: TokenKind, rhs: Expr)
    case call(name: String, args: [Expr])
}

public struct LSystemRuleSpec: Sendable, Equatable {
    public let symbol: Character
    public let replacement: String
    public let action: [Stmt]?

    public init(symbol: Character, replacement: String, action: [Stmt]? = nil) {
        self.symbol = symbol
        self.replacement = replacement
        self.action = action
    }
}

public indirect enum Stmt: Sendable, Equatable {
    case paramDecl(ProgramParameter)
    case varAssign(name: String, expr: Expr, line: Int)
    case command(name: String, args: [Expr], line: Int)
    case repeatLoop(count: Expr, body: [Stmt], line: Int)
    case forLoop(variable: String, start: Expr, end: Expr, step: Expr?, body: [Stmt], line: Int)
    case whileLoop(condition: Expr, body: [Stmt], line: Int)
    case ifStmt(condition: Expr, thenBody: [Stmt], elseBody: [Stmt]?, line: Int)
    case procDef(name: String, params: [String], body: [Stmt], line: Int)
    case branchBlock(body: [Stmt], line: Int)
    case spawnBlock(body: [Stmt], line: Int)
    case lsystemBlock(
        axiom: Expr,
        generations: Expr,
        angle: Expr,
        stepSize: Expr,
        decay: Expr?,
        rules: [String: String],
        symbolActions: [String: [Stmt]],
        line: Int
    )
    case returnStmt(expr: Expr?, line: Int)
}

public struct ProgramAST: Sendable {
    public var statements: [Stmt]
    public var parameters: [ProgramParameter]
    public var diagnostics: [DiagnosticMessage]

    public init(statements: [Stmt], parameters: [ProgramParameter], diagnostics: [DiagnosticMessage]) {
        self.statements = statements
        self.parameters = parameters
        self.diagnostics = diagnostics
    }
}
