import XCTest
@testable import AndonKit

/// Lifecycle tests for the audio graph.
///
/// A running `AVAudioEngine` costs real CPU even in total silence — the render
/// block is still called ~93 times a second and the output unit keeps the audio
/// hardware awake. Measured on an idle graph: ~0.7% of a core in-process plus
/// ~2.4% in `coreaudiod`. The board is quiet almost all the time, so "the
/// engine came up once and never went away" is a permanent background drain,
/// and it is invisible in every functional test because the sounds still work.
/// Hence these.
final class ChiptuneEngineTests: XCTestCase {

    /// Short enough to keep the suite fast, comfortably longer than the
    /// dispatch latency the assertions depend on.
    private let idleTimeout: TimeInterval = 0.4

    private func makeEngine() -> ChiptuneEngine {
        let engine = ChiptuneEngine(idleTimeout: idleTimeout)
        // Audible cues in a test run are obnoxious, and a zero gain would take
        // a different path through `perform`.
        engine.volume = 0.0001
        return engine
    }

    /// Nothing should touch the audio device until there is something to say.
    func testEngineIsNotBuiltUntilTheFirstCue() {
        let engine = makeEngine()
        XCTAssertFalse(engine.isEngineRunning)
    }

    func testCuePlayingBringsTheEngineUp() {
        let engine = makeEngine()
        engine.play(.cordPulled)
        XCTAssertTrue(waitFor { engine.isEngineRunning })
    }

    /// The regression this file exists for.
    func testEngineIsTornDownOnceTheBoardFallsQuiet() {
        let engine = makeEngine()
        engine.play(.cordPulled)
        XCTAssertTrue(waitFor { engine.isEngineRunning }, "engine never came up")

        XCTAssertTrue(
            waitFor(timeout: idleTimeout + 2) { !engine.isEngineRunning },
            "engine still running \(idleTimeout)s after the last cue — "
                + "it is burning CPU for silence")
    }

    /// Teardown must not be a one-way door: the pool survives it and the next
    /// cue has to rebuild the graph rather than going silent.
    func testEngineComesBackForALaterCue() {
        let engine = makeEngine()
        engine.play(.cordPulled)
        XCTAssertTrue(waitFor { engine.isEngineRunning })
        XCTAssertTrue(waitFor(timeout: idleTimeout + 2) { !engine.isEngineRunning })

        engine.play(.sessionStart)
        XCTAssertTrue(waitFor { engine.isEngineRunning }, "engine did not rebuild")
    }

    /// A burst of hook events must not tear down and rebuild between cues.
    func testEachCueExtendsTheCountdown() {
        let engine = makeEngine()
        let deadline = Date().addingTimeInterval(idleTimeout * 3)
        engine.play(.cordPulled)
        XCTAssertTrue(waitFor { engine.isEngineRunning })

        // Keep cueing past what would have been the first teardown. Distinct
        // sounds, because repeats inside `coalesceWindow` are dropped and a
        // dropped cue would not re-arm anything.
        let cues: [BoardSound] = [.sessionStart, .cordPulled, .sessionStart, .cordPulled]
        var index = 0
        while Date() < deadline {
            engine.play(cues[index % cues.count])
            index += 1
            Thread.sleep(forTimeInterval: idleTimeout / 2)
            XCTAssertTrue(engine.isEngineRunning, "torn down mid-burst")
        }
    }

    /// Polls rather than sleeping a fixed interval, so the suite is not paying
    /// for the slowest plausible machine on every run.
    private func waitFor(
        timeout: TimeInterval = 2, _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }
}
