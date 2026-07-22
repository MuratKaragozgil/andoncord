import CoreGraphics
import XCTest
@testable import AndonKit

/// The glyph strings are compile-time constants and the parser fails soft, so
/// a lexer bug would not crash — it would silently draw garbage badges. These
/// tests are what actually guards the four marks.
final class AgentGlyphTests: XCTestCase {

    // MARK: - Parser primitives

    func testRectangleUsesAbsoluteHVAndClose() {
        let box = AgentGlyph.parse("M0 0H10V10H0Z").boundingBoxOfPath
        XCTAssertEqual(box, CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    func testImplicitLinetoAfterMoveto() {
        // "M" with extra coordinate pairs is moveto-then-linetos, per spec.
        let box = AgentGlyph.parse("M1 1 5 1 5 5").boundingBoxOfPath
        XCTAssertEqual(box, CGRect(x: 1, y: 1, width: 4, height: 4))
    }

    func testPackedNumbersSplitAtSecondDotAndSign() {
        // ".5.5" is (0.5, 0.5); ".5-.25" is (0.5, -0.25). One misread token
        // would shear every coordinate after it.
        let box = AgentGlyph.parse("m0 0 .5.5.5-.25").boundingBoxOfPath
        XCTAssertEqual(box.width, 1.0, accuracy: 1e-9)
        XCTAssertEqual(box.height, 0.5, accuracy: 1e-9)
    }

    func testArcFlagsAreSingleCharacters() {
        // Cursor's real data packs "0 0 0-.42.726" — flags then a signed
        // coordinate with no separator.
        let path = AgentGlyph.parse("M1 0a.84.84 0 0 0-.42.726")
        XCTAssertFalse(path.isEmpty)
        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.maxY, 0.726, accuracy: 0.05)
    }

    func testFullCircleArcRoundTrips() {
        // Two half-turn arcs of r=12 must come back as a 24×24 circle; the
        // arc→bezier conversion drifting would distort the OpenAI knot.
        let box = AgentGlyph.parse("M0 12A12 12 0 1 1 24 12A12 12 0 1 1 0 12Z").boundingBoxOfPath
        XCTAssertEqual(box.minX, 0, accuracy: 0.05)
        XCTAssertEqual(box.minY, 0, accuracy: 0.05)
        XCTAssertEqual(box.width, 24, accuracy: 0.1)
        XCTAssertEqual(box.height, 24, accuracy: 0.1)
    }

    func testSmoothQuadraticReflectsControl() {
        // "t" mirrors the previous quadratic control; a symmetric S-curve's
        // second bump must reach as far as the first one.
        let box = AgentGlyph.parse("M0 0Q2 4 4 0t4 0").boundingBoxOfPath
        XCTAssertEqual(box.minY, -2, accuracy: 1e-6)
        XCTAssertEqual(box.maxY, 2, accuracy: 1e-6)
    }

    func testMalformedDataFailsSoft() {
        XCTAssertTrue(AgentGlyph.parse("banana").isEmpty)
        // A truncated arc keeps what was already drawn.
        XCTAssertFalse(AgentGlyph.parse("M0 0L5 5a1 1").isEmpty)
    }

    // MARK: - The four marks

    func testEveryGlyphFillsItsViewBox() {
        let glyphs: [(String, CGPath)] = [
            ("claude", AgentGlyph.claude), ("openai", AgentGlyph.openai),
            ("gemini", AgentGlyph.gemini), ("cursor", AgentGlyph.cursor),
        ]
        let frame = CGRect(x: -0.5, y: -0.5, width: 25, height: 25)
        for (name, glyph) in glyphs {
            XCTAssertFalse(glyph.isEmpty, "\(name) parsed to nothing")
            let box = glyph.boundingBoxOfPath
            XCTAssertTrue(frame.contains(box), "\(name) escapes the 24×24 grid: \(box)")
            XCTAssertGreaterThan(max(box.width, box.height), 15,
                                 "\(name) came out tiny — a lexer slip, not a design choice: \(box)")
        }
    }
}
