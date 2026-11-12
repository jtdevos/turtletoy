import SwiftUI
import AppKit
import TurtleToyCore

// MARK: - Scrubbable Syntax-Highlighted NSTextView

public final class TurtleCodeTextView: NSTextView {
    public var onNumberScrub: ((_ newSource: String) -> Void)?
    public var activeExecutionLine: Int? = nil {
        didSet {
            if activeExecutionLine != oldValue {
                needsDisplay = true
            }
        }
    }
    public var errorLines: Set<Int> = [] {
        didSet {
            if errorLines != oldValue {
                needsDisplay = true
            }
        }
    }

    private var activeScrubSpan: NumberTokenSpan?
    private var scrubStartMouseX: CGFloat = 0
    private var isScrubbingNumber: Bool = false

    public override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            let pt = convert(event.locationInWindow, from: nil)
            let charIndex = characterIndexForInsertion(at: pt)
            if let span = Lexer.findNumberAt(utf16Offset: charIndex, in: self.string) {
                activeScrubSpan = span
                scrubStartMouseX = event.locationInWindow.x
                isScrubbingNumber = true
                NSCursor.resizeLeftRight.push()
                return
            }
        }
        isScrubbingNumber = false
        super.mouseDown(with: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        if isScrubbingNumber, let span = activeScrubSpan {
            let dx = Double(event.locationInWindow.x - scrubStartMouseX)
            let sensitivity: Double = event.modifierFlags.contains(.shift) ? 0.05 : (span.hasDecimal ? 0.1 : 0.5)
            let delta = dx * sensitivity
            let newVal = span.value + delta

            let formatted: String
            if span.hasDecimal || event.modifierFlags.contains(.shift) {
                let places = max(1, span.decimalPlaces)
                formatted = String(format: "%.\(places)f", newVal)
            } else {
                formatted = String(Int(newVal.rounded()))
            }

            let nsString = self.string as NSString
            if span.nsRange.location + span.nsRange.length <= nsString.length {
                let updated = nsString.replacingCharacters(in: span.nsRange, with: formatted)
                self.string = updated
                let newRange = NSRange(location: span.nsRange.location, length: (formatted as NSString).length)
                self.setSelectedRange(newRange)
                activeScrubSpan = NumberTokenSpan(
                    value: span.value,
                    text: formatted,
                    nsRange: newRange,
                    line: span.line,
                    hasDecimal: span.hasDecimal,
                    decimalPlaces: span.decimalPlaces
                )
                onNumberScrub?(updated)
            }
            return
        }
        super.mouseDragged(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        if isScrubbingNumber {
            isScrubbingNumber = false
            activeScrubSpan = nil
            NSCursor.pop()
            return
        }
        super.mouseUp(with: event)
    }

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return }

        let nsText = self.string as NSString
        var lineNum = 1
        var charIdx = 0

        while charIdx < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: charIdx, length: 0))
            if lineNum == activeExecutionLine || errorLines.contains(lineNum) {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                lineRect.origin.x = 0
                lineRect.origin.y += textContainerOrigin.y
                lineRect.size.width = bounds.width

                if errorLines.contains(lineNum) {
                    NSColor(calibratedRed: 1.0, green: 0.22, blue: 0.38, alpha: 0.18).setFill()
                    lineRect.fill()
                } else if lineNum == activeExecutionLine {
                    NSColor(calibratedRed: 0.0, green: 0.96, blue: 0.83, alpha: 0.16).setFill()
                    lineRect.fill()
                }
            }
            charIdx = NSMaxRange(lineRange)
            lineNum += 1
        }
    }
}

// MARK: - Syntax Highlighter

public enum SyntaxHighlighter {
    private static let font = NSFont.monospacedSystemFont(ofSize: 13.0, weight: .medium)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 13.0, weight: .bold)

    private static let defaultColor = NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.97, alpha: 1.0)
    private static let commentColor = NSColor(calibratedRed: 0.45, green: 0.52, blue: 0.66, alpha: 1.0)
    private static let keywordColor = NSColor(calibratedRed: 1.00, green: 0.44, blue: 0.78, alpha: 1.0)
    private static let commandColor = NSColor(calibratedRed: 0.15, green: 0.95, blue: 0.85, alpha: 1.0)
    private static let fxCommandColor = NSColor(calibratedRed: 0.72, green: 0.52, blue: 1.00, alpha: 1.0)
    private static let numberColor = NSColor(calibratedRed: 1.00, green: 0.82, blue: 0.35, alpha: 1.0)
    private static let stringColor = NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.58, alpha: 1.0)
    private static let paramDirectiveColor = NSColor(calibratedRed: 0.35, green: 0.82, blue: 1.00, alpha: 1.0)

    private static let turtleCommands: Set<String> = [
        "fd", "forward", "bk", "back", "lt", "left", "rt", "right",
        "pu", "penup", "pd", "pendown", "home", "goto", "setxy", "move",
        "setx", "sety", "seth", "setheading", "circle", "arc", "dot",
        "polygon", "poly", "star", "beginfill", "endfill"
    ]

    private static let fxCommands: Set<String> = [
        "brush", "color", "pencolor", "hsl", "hsv", "rgb", "palette",
        "width", "glow", "bloom", "alpha", "backdrop", "symmetry",
        "kaleidoscope", "sparkle", "emit", "burst", "ripple", "seed"
    ]

    public static func highlight(textStorage: NSTextStorage, source: String) {
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        guard fullRange.length > 0 else { return }

        textStorage.beginEditing()
        textStorage.setAttributes([
            .font: font,
            .foregroundColor: defaultColor
        ], range: fullRange)

        // Highlight comments first (`// ...` or `; ...` or `# comment`)
        let nsSource = source as NSString
        var lineStart = 0
        while lineStart < nsSource.length {
            let lineRange = nsSource.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineStr = nsSource.substring(with: lineRange)
            if let slashRange = lineStr.range(of: "//") {
                let offset = lineStr.distance(from: lineStr.startIndex, to: slashRange.lowerBound)
                let commentNSRange = NSRange(location: lineRange.location + offset, length: lineRange.length - offset)
                textStorage.addAttribute(.foregroundColor, value: commentColor, range: commentNSRange)
            } else if let semiRange = lineStr.range(of: ";") {
                let offset = lineStr.distance(from: lineStr.startIndex, to: semiRange.lowerBound)
                let commentNSRange = NSRange(location: lineRange.location + offset, length: lineRange.length - offset)
                textStorage.addAttribute(.foregroundColor, value: commentColor, range: commentNSRange)
            }
            lineStart = NSMaxRange(lineRange)
        }

        // Token-based coloring
        let tokens = Lexer(source: source).tokenize()
        for tok in tokens {
            guard tok.kind != .eof && tok.kind != .newline else { continue }
            let nsRange = NSRange(tok.range, in: source)
            guard nsRange.location + nsRange.length <= fullRange.length else { continue }

            switch tok.kind {
            case .paramDirective:
                textStorage.addAttributes([.foregroundColor: paramDirectiveColor, .font: boldFont], range: nsRange)
            case .kwTo, .kwEnd, .kwRepeat, .kwFor, .kwIn, .kwWhile, .kwIf, .kwElse, .kwLet, .kwBranch, .kwSpawn, .kwLSystem, .kwReturn:
                textStorage.addAttributes([.foregroundColor: keywordColor, .font: boldFont], range: nsRange)
            case .number:
                textStorage.addAttributes([
                    .foregroundColor: numberColor,
                    .underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
                    .underlineColor: numberColor.withAlphaComponent(0.45)
                ], range: nsRange)
            case .string:
                textStorage.addAttribute(.foregroundColor, value: stringColor, range: nsRange)
            case .colorHex(let hex):
                if let c = ColorUtils.parseHexOrName(hex) {
                    let nsCol = NSColor(calibratedRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1.0)
                    textStorage.addAttributes([.foregroundColor: nsCol, .font: boldFont], range: nsRange)
                }
            case .identifier(let id):
                let lower = id.lowercased()
                if turtleCommands.contains(lower) {
                    textStorage.addAttributes([.foregroundColor: commandColor, .font: boldFont], range: nsRange)
                } else if fxCommands.contains(lower) {
                    textStorage.addAttributes([.foregroundColor: fxCommandColor, .font: boldFont], range: nsRange)
                }
            default:
                break
            }
        }

        textStorage.endEditing()
    }
}

// MARK: - SwiftUI Representable Wrapper

public struct CodeEditorView: NSViewRepresentable {
    @Binding public var text: String
    public var activeLine: Int?
    public var diagnostics: [DiagnosticMessage]

    public init(text: Binding<String>, activeLine: Int?, diagnostics: [DiagnosticMessage]) {
        self._text = text
        self.activeLine = activeLine
        self.diagnostics = diagnostics
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.062, blue: 0.10, alpha: 1.0)

        let textView = TurtleCodeTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.062, blue: 0.10, alpha: 1.0)
        textView.insertionPointColor = NSColor(calibratedRed: 0.0, green: 0.96, blue: 0.83, alpha: 1.0)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(calibratedRed: 0.20, green: 0.32, blue: 0.55, alpha: 0.65)
        ]
        textView.textContainerInset = NSSize(width: 12, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        textView.delegate = context.coordinator
        textView.string = text
        if let storage = textView.textStorage {
            SyntaxHighlighter.highlight(textStorage: storage, source: text)
        }

        textView.onNumberScrub = { newSource in
            context.coordinator.isUpdatingFromInside = true
            self.text = newSource
            if let storage = textView.textStorage {
                SyntaxHighlighter.highlight(textStorage: storage, source: newSource)
            }
            context.coordinator.isUpdatingFromInside = false
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.activeExecutionLine = activeLine
        textView.errorLines = Set(diagnostics.filter { $0.severity == .error }.map { $0.line })

        if !context.coordinator.isUpdatingFromInside && textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            if let storage = textView.textStorage {
                SyntaxHighlighter.highlight(textStorage: storage, source: text)
            }
            textView.selectedRanges = selectedRanges
        }
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: TurtleCodeTextView?
        var isUpdatingFromInside = false

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            isUpdatingFromInside = true
            let updated = tv.string
            parent.text = updated
            if let storage = tv.textStorage {
                let selected = tv.selectedRanges
                SyntaxHighlighter.highlight(textStorage: storage, source: updated)
                tv.selectedRanges = selected
            }
            isUpdatingFromInside = false
        }
    }
}
