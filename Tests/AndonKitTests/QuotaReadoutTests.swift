import XCTest
@testable import AndonKit

/// Composing a usable quota figure out of a reading that may be hours old and
/// a ledger that is always current.
///
/// The rule every case here encodes: the board may estimate, but it must never
/// present an estimate as a reading, and it must never present a reading about
/// a window that has since reset as though it were about this one.
final class QuotaReadoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func limits(used: Double, resetsIn: TimeInterval) -> RateLimits {
        RateLimits(fiveHour: RateLimitWindow(
            usedPercentage: used, resetsAt: now.addingTimeInterval(resetsIn)))
    }

    private func spend(_ usd: Double, requests: Int = 60) -> TokenUsage {
        TokenUsage(input: 1_000, output: 1_000, requests: requests, costUsd: usd)
    }

    private func inputs(
        limits: RateLimits?, capturedAt: Date?, isStale: Bool,
        spentInWindow: TokenUsage = TokenUsage(),
        spentSinceReading: TokenUsage = TokenUsage(),
        calibration: QuotaCalibration = QuotaCalibration(),
        samples: [QuotaSample] = []
    ) -> QuotaReadout.Inputs {
        .init(
            limits: limits, capturedAt: capturedAt, isStale: isStale,
            spentInWindow: spentInWindow, spentSinceReading: spentSinceReading,
            calibration: calibration, samples: samples)
    }

    func testFreshReadingIsUsedVerbatim() {
        let readout = QuotaReadout.compose(
            kind: .fiveHour,
            inputs: inputs(
                limits: limits(used: 42, resetsIn: 2 * 3600),
                capturedAt: now.addingTimeInterval(-60), isStale: false,
                spentInWindow: spend(4)),
            now: now)

        XCTAssertEqual(readout.usedPercentage, 42)
        XCTAssertTrue(readout.isMeasured)
        XCTAssertFalse(readout.isEstimate)
    }

    /// The reported number is a snapshot. Requests made after it are invisible
    /// to it, and with a known cap they are exactly recoverable — so a stale
    /// reading gets carried forward rather than shown frozen.
    func testStaleReadingIsCarriedForwardByMeasuredSpend() {
        var calibration = QuotaCalibration()
        // $10 of spend was 50% of the window, so the window is worth $20.
        calibration.observe(
            kind: .fiveHour, usedPercentage: 50, spent: spend(10),
            at: now.addingTimeInterval(-7_200))

        let readout = QuotaReadout.compose(
            kind: .fiveHour,
            inputs: inputs(
                limits: limits(used: 50, resetsIn: 2 * 3600),
                capturedAt: now.addingTimeInterval(-3_600), isStale: true,
                spentInWindow: spend(15), spentSinceReading: spend(5),
                calibration: calibration),
            now: now)

        // $5 more against a $20 window is another 25 points.
        XCTAssertEqual(try XCTUnwrap(readout.usedPercentage), 75, accuracy: 0.5)
        XCTAssertFalse(readout.isMeasured)
        XCTAssertTrue(readout.isEstimate)
        if case .extrapolated = readout.source {} else {
            XCTFail("expected an extrapolated source, got \(readout.source)")
        }
    }

    func testStaleReadingWithoutACalibrationIsLeftAlone() {
        let readout = QuotaReadout.compose(
            kind: .fiveHour,
            inputs: inputs(
                limits: limits(used: 50, resetsIn: 2 * 3600),
                capturedAt: now.addingTimeInterval(-3_600), isStale: true,
                spentInWindow: spend(15), spentSinceReading: spend(5)),
            now: now)

        XCTAssertEqual(readout.usedPercentage, 50)
        XCTAssertFalse(readout.isEstimate)
        XCTAssertFalse(readout.isMeasured)
    }

    /// The case this whole layer exists for: the statusline never fired, so
    /// the only reading on disk is about a window that reset days ago.
    func testExpiredReadingIsReplacedByAnEstimate() {
        var calibration = QuotaCalibration()
        calibration.observe(
            kind: .fiveHour, usedPercentage: 50, spent: spend(10),
            at: now.addingTimeInterval(-86_400))

        let readout = QuotaReadout.compose(
            kind: .fiveHour,
            inputs: inputs(
                limits: limits(used: 90, resetsIn: -86_400),
                capturedAt: now.addingTimeInterval(-90_000), isStale: true,
                spentInWindow: spend(6), calibration: calibration),
            now: now)

        // $6 against the $20 window the calibration derived.
        XCTAssertEqual(try XCTUnwrap(readout.usedPercentage), 30, accuracy: 0.5)
        XCTAssertTrue(readout.isEstimate)
        // No reset time is invented: a 5-hour window opens on the first request
        // after the last one closed, and nothing records when that was.
        XCTAssertNil(readout.resetsAt)
    }

    func testExpiredReadingWithNothingToEstimateFromShowsNothing() {
        let readout = QuotaReadout.compose(
            kind: .fiveHour,
            inputs: inputs(
                limits: limits(used: 90, resetsIn: -86_400),
                capturedAt: now.addingTimeInterval(-90_000), isStale: true),
            now: now)

        XCTAssertNil(readout.usedPercentage)
        XCTAssertEqual(readout.source, .unknown)
        XCTAssertEqual(readout.forecast.verdict, .unknown)
    }

    func testNoReadingAtAllShowsNothing() {
        let readout = QuotaReadout.compose(
            kind: .sevenDay,
            inputs: inputs(limits: nil, capturedAt: nil, isStale: true),
            now: now)
        XCTAssertNil(readout.usedPercentage)
        XCTAssertEqual(readout.provenance, "no reading yet")
    }

    func testCarriedForwardFigureIsCappedAtFullyUsed() {
        var calibration = QuotaCalibration()
        calibration.observe(
            kind: .fiveHour, usedPercentage: 50, spent: spend(10), at: now)

        let readout = QuotaReadout.compose(
            kind: .fiveHour,
            inputs: inputs(
                limits: limits(used: 80, resetsIn: 3_600),
                capturedAt: now.addingTimeInterval(-3_600), isStale: true,
                spentInWindow: spend(40), spentSinceReading: spend(30),
                calibration: calibration),
            now: now)

        XCTAssertEqual(readout.usedPercentage, 100)
    }
}

/// Learning the cap nobody publishes.
final class QuotaCalibrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func spend(_ usd: Double, requests: Int = 60) -> TokenUsage {
        TokenUsage(requests: requests, costUsd: usd)
    }

    func testCapIsDerivedFromOneReadingAndItsSpend() {
        var calibration = QuotaCalibration()
        calibration.observe(kind: .fiveHour, usedPercentage: 25, spent: spend(5), at: now)
        XCTAssertEqual(try XCTUnwrap(calibration.capUsd(for: .fiveHour)), 20, accuracy: 0.001)
        XCTAssertEqual(calibration.entry(for: .fiveHour)?.samples, 1)
    }

    /// The percentage is reported to one decimal, so dividing by a very small
    /// one multiplies its rounding error — a 1% reading can imply a cap three
    /// times too large.
    func testTinyPercentagesAreIgnored() {
        var calibration = QuotaCalibration()
        calibration.observe(kind: .fiveHour, usedPercentage: 3, spent: spend(0.4), at: now)
        XCTAssertNil(calibration.capUsd(for: .fiveHour))
    }

    /// Spend is only as complete as the transcripts on this machine. A window
    /// with barely any measured requests behind it is more likely to be a gap
    /// in the record than a genuinely cheap window, and calibrating on it
    /// would scale every later estimate down with it.
    func testThinlyEvidencedSpendIsIgnored() {
        var calibration = QuotaCalibration()
        calibration.observe(
            kind: .sevenDay, usedPercentage: 40, spent: spend(20, requests: 3), at: now)
        XCTAssertNil(calibration.capUsd(for: .sevenDay))
    }

    /// A weekly window read early is still worth calibrating on: it is backed
    /// by days of measured requests, and it is the one window that would
    /// otherwise never get a scale at all.
    func testEarlyWeeklyReadingStillCalibrates() {
        var calibration = QuotaCalibration()
        calibration.observe(
            kind: .sevenDay, usedPercentage: 8.2, spent: spend(357.84, requests: 1_461), at: now)
        XCTAssertEqual(try XCTUnwrap(calibration.capUsd(for: .sevenDay)), 4_363.9, accuracy: 1)
    }

    func testLaterReadingsBlendRatherThanReplace() {
        var calibration = QuotaCalibration()
        calibration.observe(kind: .sevenDay, usedPercentage: 50, spent: spend(50), at: now)
        XCTAssertEqual(try XCTUnwrap(calibration.capUsd(for: .sevenDay)), 100, accuracy: 0.001)

        // A window that implies $200 should move the estimate, not become it.
        calibration.observe(
            kind: .sevenDay, usedPercentage: 50, spent: spend(100),
            at: now.addingTimeInterval(3_600))
        let cap = try! XCTUnwrap(calibration.capUsd(for: .sevenDay))
        XCTAssertEqual(cap, 130, accuracy: 0.001)
        XCTAssertEqual(calibration.entry(for: .sevenDay)?.samples, 2)
    }

    /// The same reading is offered again on every relaunch and after every
    /// re-index. Folding it in each time would let one window's ratio walk the
    /// average towards itself indefinitely.
    func testTheSameReadingIsOnlyFoldedInOnce() {
        var calibration = QuotaCalibration()
        calibration.observe(kind: .fiveHour, usedPercentage: 50, spent: spend(10), at: now)
        calibration.observe(kind: .fiveHour, usedPercentage: 50, spent: spend(10), at: now)
        calibration.observe(kind: .fiveHour, usedPercentage: 20, spent: spend(2),
                            at: now.addingTimeInterval(-3_600))

        XCTAssertEqual(calibration.entry(for: .fiveHour)?.samples, 1)
        XCTAssertEqual(try XCTUnwrap(calibration.capUsd(for: .fiveHour)), 20, accuracy: 0.001)
    }

    func testWindowsAreCalibratedIndependently() {
        var calibration = QuotaCalibration()
        calibration.observe(kind: .fiveHour, usedPercentage: 50, spent: spend(10), at: now)
        XCTAssertNil(calibration.capUsd(for: .sevenDay))
        XCTAssertNotNil(calibration.capUsd(for: .fiveHour))
    }

    func testSurvivesADiskRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("andon-calib-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var calibration = QuotaCalibration()
        calibration.observe(kind: .fiveHour, usedPercentage: 40, spent: spend(8), at: now)
        calibration.save(to: url)

        let reloaded = QuotaCalibration.load(from: url)
        XCTAssertEqual(reloaded, calibration)
    }
}
