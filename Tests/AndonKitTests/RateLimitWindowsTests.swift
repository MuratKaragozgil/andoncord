import XCTest
@testable import AndonKit

/// Decoding `rate_limits` out of the statusline payload.
///
/// The two named windows were never a closed set. Anthropic has since started
/// reporting a per-model weekly window next to them, and the decoder that only
/// knew `five_hour` and `seven_day` discarded it silently — so the board could
/// not show it, the cache on disk did not mention it, and nothing anywhere
/// said a window had been thrown away. These pin the shape that fixes that.
final class RateLimitWindowsTests: XCTestCase {

    private func decode(_ json: String) throws -> RateLimits {
        try JSONDecoder().decode(RateLimits.self, from: Data(json.utf8))
    }

    func testKnownWindowsStillLandOnTheirTypedFields() throws {
        let limits = try decode("""
        {"five_hour":{"used_percentage":40},"seven_day":{"used_percentage":54}}
        """)
        XCTAssertEqual(limits.fiveHour?.usedPercentage, 40)
        XCTAssertEqual(limits.sevenDay?.usedPercentage, 54)
        XCTAssertTrue(limits.others.isEmpty)
        XCTAssertTrue(limits.unrecognisedWindowNames.isEmpty)
    }

    func testAnUnrecognisedWindowIsKeptRatherThanDropped() throws {
        let limits = try decode("""
        {"seven_day":{"used_percentage":85},"seven_day_fable":{"used_percentage":66}}
        """)
        XCTAssertEqual(limits.sevenDay?.usedPercentage, 85)
        XCTAssertEqual(limits.others["seven_day_fable"]?.usedPercentage, 66)
        XCTAssertEqual(limits.unrecognisedWindowNames, ["seven_day_fable"])
    }

    /// The cache is what the app reads back, so a window that survives decoding
    /// but not encoding is dropped just as thoroughly, one step later.
    func testUnrecognisedWindowsSurviveTheCacheRoundTrip() throws {
        let original = try decode("""
        {"five_hour":{"used_percentage":43,"resets_at":1789252200},
         "seven_day":{"used_percentage":85},
         "seven_day_fable":{"used_percentage":66,"resets_at":1789567200}}
        """)
        let restored = try JSONDecoder().decode(
            RateLimits.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.others["seven_day_fable"]?.usedPercentage, 66)
        XCTAssertEqual(
            restored.others["seven_day_fable"]?.resetsAt,
            Date(timeIntervalSince1970: 1789567200))
    }

    /// The statusline only caches a payload it considers non-empty. If a
    /// release renamed both known keys and `isEmpty` still only asked about
    /// those two, the cache would stop updating and the last good reading would
    /// sit on the board looking current — which is exactly the failure this
    /// whole change came out of.
    func testAPayloadOfOnlyUnrecognisedWindowsIsNotEmpty() throws {
        let limits = try decode("""
        {"session":{"used_percentage":44},"weekly_all_models":{"used_percentage":70}}
        """)
        XCTAssertNil(limits.fiveHour)
        XCTAssertNil(limits.sevenDay)
        XCTAssertFalse(limits.isEmpty, "this payload has two real windows in it")
        XCTAssertEqual(limits.unrecognisedWindowNames, ["session", "weekly_all_models"])
    }

    func testTrulyEmptyIsStillEmpty() throws {
        XCTAssertTrue(try decode("{}").isEmpty)
    }

    /// Same rule the typed windows follow: a reading whose reset has passed
    /// describes a window that no longer exists.
    func testExpiredUnrecognisedWindowsAreNotLive() throws {
        let limits = try decode("""
        {"gone":{"used_percentage":90,"resets_at":1000000000},
         "current":{"used_percentage":30,"resets_at":4000000000}}
        """)
        XCTAssertEqual(limits.liveOthers().map(\.name), ["current"])
    }

    /// A window with a name we do not recognise is still a window; nothing
    /// about it should need a special case to read.
    func testAnUnrecognisedWindowBehavesLikeAnyOther() throws {
        let limits = try decode("""
        {"seven_day_fable":{"used_percentage":95}}
        """)
        let window = try XCTUnwrap(limits.others["seven_day_fable"])
        XCTAssertEqual(window.severity, .critical)
        XCTAssertEqual(window.fraction, 0.95, accuracy: 0.0001)
    }
}
