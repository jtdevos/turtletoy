import XCTest
@testable import TurtleToyCore

final class TurtleToyTests: XCTestCase {
    func testBasicMovementAndHeading() {
        let code = """
        fd 100
        rt 90
        fd 50
        """
        let scene = Interpreter.compileAndRun(source: code)
        XCTAssertTrue(scene.diagnostics.isEmpty)
        XCTAssertEqual(scene.strokes.count, 2)
        XCTAssertEqual(scene.steps.count, 2)

        let first = scene.strokes[0]
        XCTAssertEqual(first.start.x, 0.0, accuracy: 0.01)
        XCTAssertEqual(first.start.y, 0.0, accuracy: 0.01)
        XCTAssertEqual(first.end.x, 0.0, accuracy: 0.01)
        XCTAssertEqual(first.end.y, 100.0, accuracy: 0.01)

        let second = scene.strokes[1]
        XCTAssertEqual(second.end.x, 50.0, accuracy: 0.01)
        XCTAssertEqual(second.end.y, 100.0, accuracy: 0.01)
    }

    func testParamDirectiveAndOverrides() {
        let code = """
        @param len 80 10 200 1 "Segment Length"
        @param tint #FF00AA "Main Color"
        color tint
        fd len
        """
        let defaultScene = Interpreter.compileAndRun(source: code)
        XCTAssertEqual(defaultScene.parameters.count, 2)
        XCTAssertEqual(defaultScene.strokes.count, 1)
        XCTAssertEqual(defaultScene.strokes[0].end.y, 80.0, accuracy: 0.01)

        let overridden = Interpreter.compileAndRun(
            source: code,
            parameterOverrides: ["len": 145.0]
        )
        XCTAssertEqual(overridden.strokes[0].end.y, 145.0, accuracy: 0.01)
    }

    func testProceduresRecursionAndBranching() {
        let code = """
        to vtree(size, level) {
            if level <= 0 { return }
            fd size
            branch {
                lt 30
                vtree(size * 0.5, level - 1)
            }
            branch {
                rt 30
                vtree(size * 0.5, level - 1)
            }
        }
        vtree(60, 3)
        """
        let scene = Interpreter.compileAndRun(source: code)
        XCTAssertTrue(scene.diagnostics.isEmpty)
        // 1 trunk + 2 level-2 + 4 level-1 = 7 strokes
        XCTAssertEqual(scene.strokes.count, 7)
    }

    func testKaleidoscopeSymmetryMultiplier() {
        let code = """
        kaleidoscope 6, 1
        fd 50
        """
        let scene = Interpreter.compileAndRun(source: code)
        // 6 rotational * 2 mirror = 12 symmetric strokes for 1 step!
        XCTAssertEqual(scene.steps.count, 1)
        XCTAssertEqual(scene.strokes.count, 12)
    }

    func testLSystemExpansionAndDrawing() {
        let code = """
        lsystem {
            axiom: "F"
            generations: 2
            angle: 25
            size: 10
            rule "F" -> "F[+F][-F]"
        }
        """
        let scene = Interpreter.compileAndRun(source: code)
        XCTAssertTrue(scene.diagnostics.isEmpty)
        // Gen 0: F (1) -> Gen 1: F[+F][-F] (3) -> Gen 2: 9 F's
        XCTAssertEqual(scene.strokes.count, 9)
    }

    func testNumberScrubberTokenFinder() {
        let code = "fd 125.5\nrt -45"
        let span1 = Lexer.findNumberAt(utf16Offset: 4, in: code)
        XCTAssertNotNil(span1)
        XCTAssertEqual(span1?.value ?? 0, 125.5, accuracy: 0.001)
        XCTAssertTrue(span1?.hasDecimal ?? false)

        let span2 = Lexer.findNumberAt(utf16Offset: 13, in: code)
        XCTAssertNotNil(span2)
        XCTAssertEqual(span2?.value ?? 0, -45.0, accuracy: 0.001)
    }

    func testAllShowcasePresetsCompileCleanly() {
        for preset in PresetGallery.all {
            let scene = Interpreter.compileAndRun(source: preset.code, timeSeconds: 0.5)
            let errors = scene.diagnostics.filter { $0.severity == .error }
            XCTAssertTrue(errors.isEmpty, "Preset \(preset.id) had errors: \(errors)")
            XCTAssertGreaterThan(scene.strokes.count, 0, "Preset \(preset.id) produced 0 strokes")
        }
    }
}
