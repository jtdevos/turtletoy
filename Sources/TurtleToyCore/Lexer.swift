import Foundation

public enum TokenKind: Equatable, Sendable {
    case number(Double)
    case identifier(String)
    case string(String)
    case colorHex(String)
    case paramDirective // @param

    // Keywords
    case kwTo
    case kwEnd
    case kwRepeat
    case kwFor
    case kwIn
    case kwWhile
    case kwIf
    case kwElse
    case kwLet
    case kwBranch
    case kwSpawn
    case kwLSystem
    case kwReturn

    // Punctuation & Operators
    case lBrace      // {
    case rBrace      // }
    case lParen      // (
    case rParen      // )
    case comma       // ,
    case colon       // :
    case arrow       // ->
    case dotDot      // ..
    case assign      // =
    case plus        // +
    case minus       // -
    case star        // *
    case slash       // /
    case percent     // %
    case caret       // ^
    case eq          // ==
    case neq         // !=
    case lt          // <
    case lte         // <=
    case gt          // >
    case gte         // >=
    case and         // && or and
    case or          // || or or
    case not         // !
    case newline
    case eof
}

public struct Token: Equatable, Sendable {
    public let kind: TokenKind
    public let lexeme: String
    public let line: Int
    public let column: Int
    public let range: Range<String.Index>

    public init(kind: TokenKind, lexeme: String, line: Int, column: Int, range: Range<String.Index>) {
        self.kind = kind
        self.lexeme = lexeme
        self.line = line
        self.column = column
        self.range = range
    }
}

public struct NumberTokenSpan: Sendable {
    public let value: Double
    public let text: String
    public let nsRange: NSRange
    public let line: Int
    public let hasDecimal: Bool
    public let decimalPlaces: Int

    public init(value: Double, text: String, nsRange: NSRange, line: Int, hasDecimal: Bool, decimalPlaces: Int) {
        self.value = value
        self.text = text
        self.nsRange = nsRange
        self.line = line
        self.hasDecimal = hasDecimal
        self.decimalPlaces = decimalPlaces
    }
}

public final class Lexer {
    private let source: String
    private var index: String.Index
    private var line: Int = 1
    private var column: Int = 1

    public init(source: String) {
        self.source = source
        self.index = source.startIndex
    }

    public func tokenize() -> [Token] {
        var tokens: [Token] = []
        while !isAtEnd {
            skipWhitespace()
            guard !isAtEnd else { break }

            let startIdx = index
            let startLine = line
            let startCol = column
            let ch = advance()

            switch ch {
            case "\n":
                tokens.append(Token(kind: .newline, lexeme: "\n", line: startLine, column: startCol, range: startIdx..<index))
                line += 1
                column = 1
            case "\r":
                if peek() == "\n" {
                    _ = advance()
                }
                tokens.append(Token(kind: .newline, lexeme: "\n", line: startLine, column: startCol, range: startIdx..<index))
                line += 1
                column = 1
            case "{":
                tokens.append(Token(kind: .lBrace, lexeme: "{", line: startLine, column: startCol, range: startIdx..<index))
            case "}":
                tokens.append(Token(kind: .rBrace, lexeme: "}", line: startLine, column: startCol, range: startIdx..<index))
            case "(":
                tokens.append(Token(kind: .lParen, lexeme: "(", line: startLine, column: startCol, range: startIdx..<index))
            case ")":
                tokens.append(Token(kind: .rParen, lexeme: ")", line: startLine, column: startCol, range: startIdx..<index))
            case ",":
                tokens.append(Token(kind: .comma, lexeme: ",", line: startLine, column: startCol, range: startIdx..<index))
            case ":":
                if isIdentifierStart(peek()) {
                    // Classic Logo `:varname` syntax — treat as identifier!
                    while isIdentifierContinue(peek()) {
                        _ = advance()
                    }
                    let name = String(source[source.index(after: startIdx)..<index])
                    tokens.append(Token(kind: .identifier(name), lexeme: String(source[startIdx..<index]), line: startLine, column: startCol, range: startIdx..<index))
                } else {
                    tokens.append(Token(kind: .colon, lexeme: ":", line: startLine, column: startCol, range: startIdx..<index))
                }
            case "+":
                tokens.append(Token(kind: .plus, lexeme: "+", line: startLine, column: startCol, range: startIdx..<index))
            case "-":
                if peek() == ">" {
                    _ = advance()
                    tokens.append(Token(kind: .arrow, lexeme: "->", line: startLine, column: startCol, range: startIdx..<index))
                } else {
                    tokens.append(Token(kind: .minus, lexeme: "-", line: startLine, column: startCol, range: startIdx..<index))
                }
            case "*":
                tokens.append(Token(kind: .star, lexeme: "*", line: startLine, column: startCol, range: startIdx..<index))
            case "/":
                if peek() == "/" {
                    while !isAtEnd && peek() != "\n" {
                        _ = advance()
                    }
                } else {
                    tokens.append(Token(kind: .slash, lexeme: "/", line: startLine, column: startCol, range: startIdx..<index))
                }
            case "%":
                tokens.append(Token(kind: .percent, lexeme: "%", line: startLine, column: startCol, range: startIdx..<index))
            case "^":
                tokens.append(Token(kind: .caret, lexeme: "^", line: startLine, column: startCol, range: startIdx..<index))
            case ".":
                if peek() == "." {
                    _ = advance()
                    tokens.append(Token(kind: .dotDot, lexeme: "..", line: startLine, column: startCol, range: startIdx..<index))
                } else if isDigit(peek()) {
                    while isDigit(peek()) { _ = advance() }
                    let text = String(source[startIdx..<index])
                    let val = Double(text) ?? 0.0
                    tokens.append(Token(kind: .number(val), lexeme: text, line: startLine, column: startCol, range: startIdx..<index))
                }
            case "=":
                if peek() == "=" {
                    _ = advance()
                    tokens.append(Token(kind: .eq, lexeme: "==", line: startLine, column: startCol, range: startIdx..<index))
                } else {
                    tokens.append(Token(kind: .assign, lexeme: "=", line: startLine, column: startCol, range: startIdx..<index))
                }
            case "!":
                if peek() == "=" {
                    _ = advance()
                    tokens.append(Token(kind: .neq, lexeme: "!=", line: startLine, column: startCol, range: startIdx..<index))
                } else {
                    tokens.append(Token(kind: .not, lexeme: "!", line: startLine, column: startCol, range: startIdx..<index))
                }
            case "<":
                if peek() == "=" {
                    _ = advance()
                    tokens.append(Token(kind: .lte, lexeme: "<=", line: startLine, column: startCol, range: startIdx..<index))
                } else {
                    tokens.append(Token(kind: .lt, lexeme: "<", line: startLine, column: startCol, range: startIdx..<index))
                }
            case ">":
                if peek() == "=" {
                    _ = advance()
                    tokens.append(Token(kind: .gte, lexeme: ">=", line: startLine, column: startCol, range: startIdx..<index))
                } else {
                    tokens.append(Token(kind: .gt, lexeme: ">", line: startLine, column: startCol, range: startIdx..<index))
                }
            case "&":
                if peek() == "&" { _ = advance() }
                tokens.append(Token(kind: .and, lexeme: "&&", line: startLine, column: startCol, range: startIdx..<index))
            case "|":
                if peek() == "|" { _ = advance() }
                tokens.append(Token(kind: .or, lexeme: "||", line: startLine, column: startCol, range: startIdx..<index))
            case ";":
                // Classic Logo comment `;`
                while !isAtEnd && peek() != "\n" {
                    _ = advance()
                }
            case "#":
                // Distinguish between `#FF00AA` hex color and `# comment`
                if isHexColorCandidate() {
                    while isHexDigit(peek()) {
                        _ = advance()
                    }
                    let hexText = String(source[startIdx..<index])
                    tokens.append(Token(kind: .colorHex(hexText), lexeme: hexText, line: startLine, column: startCol, range: startIdx..<index))
                } else {
                    while !isAtEnd && peek() != "\n" {
                        _ = advance()
                    }
                }
            case "@":
                while isIdentifierContinue(peek()) {
                    _ = advance()
                }
                let word = String(source[startIdx..<index]).lowercased()
                if word == "@param" {
                    tokens.append(Token(kind: .paramDirective, lexeme: word, line: startLine, column: startCol, range: startIdx..<index))
                }
            case "\"", "'":
                let quote = ch
                var content = ""
                while !isAtEnd && peek() != quote && peek() != "\n" {
                    content.append(advance())
                }
                if peek() == quote {
                    _ = advance()
                }
                tokens.append(Token(kind: .string(content), lexeme: String(source[startIdx..<index]), line: startLine, column: startCol, range: startIdx..<index))
            default:
                if isDigit(ch) {
                    while isDigit(peek()) {
                        _ = advance()
                    }
                    if peek() == "." && peekNext() != "." && isDigit(peekNext()) {
                        _ = advance() // consume '.'
                        while isDigit(peek()) {
                            _ = advance()
                        }
                    }
                    let text = String(source[startIdx..<index])
                    let val = Double(text) ?? 0.0
                    tokens.append(Token(kind: .number(val), lexeme: text, line: startLine, column: startCol, range: startIdx..<index))
                } else if isIdentifierStart(ch) {
                    while isIdentifierContinue(peek()) {
                        _ = advance()
                    }
                    let raw = String(source[startIdx..<index])
                    let lower = raw.lowercased()
                    let kind = keywordKind(for: lower) ?? .identifier(raw)
                    tokens.append(Token(kind: kind, lexeme: raw, line: startLine, column: startCol, range: startIdx..<index))
                }
            }
        }

        tokens.append(Token(kind: .eof, lexeme: "", line: line, column: column, range: index..<index))
        return tokens
    }

    /// Scans the source for number literals (including optional leading `-`) so the code editor can scrub numbers live.
    public static func findNumberAt(utf16Offset: Int, in source: String) -> NumberTokenSpan? {
        let lexer = Lexer(source: source)
        let tokens = lexer.tokenize()
        for i in 0..<tokens.count {
            let tok = tokens[i]
            guard case .number(let val) = tok.kind else { continue }
            var startIndex = tok.range.lowerBound
            var signedValue = val
            if i > 0, tokens[i - 1].kind == .minus, tokens[i - 1].range.upperBound == tok.range.lowerBound {
                // Check if previous token before minus is an operator/newline/keyword/lparen or command name
                let prevIsUnary: Bool
                if i == 1 {
                    prevIsUnary = true
                } else {
                    switch tokens[i - 2].kind {
                    case .number, .rParen:
                        prevIsUnary = false
                    default:
                        prevIsUnary = true
                    }
                }
                if prevIsUnary {
                    startIndex = tokens[i - 1].range.lowerBound
                    signedValue = -val
                }
            }
            let fullRange = startIndex..<tok.range.upperBound
            let nsRange = NSRange(fullRange, in: source)
            if utf16Offset >= nsRange.location && utf16Offset <= nsRange.location + nsRange.length {
                let text = String(source[fullRange])
                let parts = text.split(separator: ".")
                let hasDecimal = text.contains(".")
                let places = (hasDecimal && parts.count == 2) ? parts[1].count : 0
                return NumberTokenSpan(
                    value: signedValue,
                    text: text,
                    nsRange: nsRange,
                    line: tok.line,
                    hasDecimal: hasDecimal,
                    decimalPlaces: places
                )
            }
        }
        return nil
    }

    // MARK: - Helpers

    private var isAtEnd: Bool {
        index >= source.endIndex
    }

    private func peek() -> Character {
        guard !isAtEnd else { return "\0" }
        return source[index]
    }

    private func peekNext() -> Character {
        guard !isAtEnd else { return "\0" }
        let next = source.index(after: index)
        guard next < source.endIndex else { return "\0" }
        return source[next]
    }

    private func advance() -> Character {
        let ch = source[index]
        index = source.index(after: index)
        column += 1
        return ch
    }

    private func skipWhitespace() {
        while !isAtEnd {
            let ch = peek()
            if ch == " " || ch == "\t" {
                _ = advance()
            } else {
                break
            }
        }
    }

    private func isDigit(_ ch: Character) -> Bool {
        ch >= "0" && ch <= "9"
    }

    private func isHexDigit(_ ch: Character) -> Bool {
        (ch >= "0" && ch <= "9") || (ch >= "a" && ch <= "f") || (ch >= "A" && ch <= "F")
    }

    private func isHexColorCandidate() -> Bool {
        // Count consecutive hex digits starting at current `index`
        var probe = index
        var count = 0
        while probe < source.endIndex && isHexDigit(source[probe]) {
            count += 1
            probe = source.index(after: probe)
        }
        guard count == 3 || count == 6 || count == 8 else { return false }
        if probe < source.endIndex && isIdentifierContinue(source[probe]) {
            return false
        }
        return true
    }

    private func isIdentifierStart(_ ch: Character) -> Bool {
        (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || ch == "_"
    }

    private func isIdentifierContinue(_ ch: Character) -> Bool {
        isIdentifierStart(ch) || isDigit(ch) || ch == "?"
    }

    private func keywordKind(for word: String) -> TokenKind? {
        switch word {
        case "to", "def", "proc", "fn": return .kwTo
        case "end": return .kwEnd
        case "repeat": return .kwRepeat
        case "for": return .kwFor
        case "in": return .kwIn
        case "while": return .kwWhile
        case "if": return .kwIf
        case "else": return .kwElse
        case "let", "make", "var": return .kwLet
        case "branch", "save", "isolated": return .kwBranch
        case "spawn": return .kwSpawn
        case "lsystem": return .kwLSystem
        case "return": return .kwReturn
        case "and": return .and
        case "or": return .or
        default: return nil
        }
    }
}
