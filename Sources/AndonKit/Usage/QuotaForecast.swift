import Foundation

/// Will the quota last?
///
/// Claude Code hands out one number per window — the percentage used right
/// now — and that number alone cannot answer the only question anyone
/// actually asks it. 60% used is fine four hours into a five-hour window and
/// a wall you will hit before lunch if you are twenty minutes in.
///
/// The missing piece is the window's *start*, and it is derivable: these
/// windows are fixed-length, so a window that resets at `resetsAt` began at
/// `resetsAt − length`. From that, elapsed time is known, and the average pace
/// so far extrapolates to a projected figure at reset. When quota samples have
/// been collected the recent pace is used instead, because someone who has
/// been idle for an hour should not be told they are about to run out.
public struct QuotaForecast: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// The window will end with room to spare.
        case holds
        /// Projected to land close enough to the cap that a long task is a
        /// gamble.
        case tight
        /// Projected to hit the cap before the window resets.
        case exhausts
        /// Not enough information — no reset time, or the window just opened.
        case unknown
    }

    public var verdict: Verdict
    /// Percentage this window is projected to reach by the time it resets.
    public var projectedAtReset: Double?
    /// When the cap is reached at the current pace, if it is reached at all.
    public var exhaustsAt: Date?
    /// Percentage points per hour.
    public var burnPerHour: Double?
    /// Whether `burnPerHour` came from observed samples rather than from the
    /// window-long average. Recent pace is more responsive but needs data.
    public var usesRecentPace: Bool

    public init(
        verdict: Verdict, projectedAtReset: Double? = nil, exhaustsAt: Date? = nil,
        burnPerHour: Double? = nil, usesRecentPace: Bool = false
    ) {
        self.verdict = verdict
        self.projectedAtReset = projectedAtReset
        self.exhaustsAt = exhaustsAt
        self.burnPerHour = burnPerHour
        self.usesRecentPace = usesRecentPace
    }

    public static let unknown = QuotaForecast(verdict: .unknown)

    /// Anything projected past this is called tight rather than fine. Being
    /// told at 92% that everything is fine is worse than useless.
    private static let tightThreshold: Double = 85

    /// - Parameters:
    ///   - window: the quota window as Claude Code last reported it.
    ///   - kind: which window this is, which fixes its length.
    ///   - samples: recent readings, oldest first. Optional — without them the
    ///     forecast falls back to the window-long average pace.
    public static func project(
        window: RateLimitWindow,
        kind: QuotaWindowKind,
        samples: [QuotaSample] = [],
        now: Date = Date()
    ) -> QuotaForecast {
        let length = kind.length
        guard let resetsAt = window.resetsAt else { return .unknown }
        let remaining = resetsAt.timeIntervalSince(now)
        // Past its reset: whatever this window says is about a window that no
        // longer exists. Refusing to forecast is the honest answer.
        guard remaining > 0 else { return .unknown }

        let elapsed = length - remaining
        // The first minutes of a window extrapolate to absurdities — one
        // request at minute two projects to 3000%.
        guard elapsed > length * 0.04 else { return .unknown }

        let used = window.usedPercentage
        let averagePace = used / (elapsed / 3600)
        let recentPace = Self.recentPace(samples: samples, kind: kind, now: now)
        let pace = recentPace ?? averagePace
        guard pace > 0 else {
            // Nothing burned and nothing burning: it will hold trivially.
            return QuotaForecast(
                verdict: .holds, projectedAtReset: used, burnPerHour: 0,
                usesRecentPace: recentPace != nil)
        }

        let projected = used + pace * (remaining / 3600)
        let headroom = 100 - used
        let exhaustsAt = projected >= 100
            ? now.addingTimeInterval(headroom / pace * 3600)
            : nil

        let verdict: Verdict
        switch projected {
        case ..<tightThreshold: verdict = .holds
        case ..<100: verdict = .tight
        default: verdict = .exhausts
        }

        return QuotaForecast(
            verdict: verdict,
            projectedAtReset: projected,
            exhaustsAt: exhaustsAt,
            burnPerHour: pace,
            usesRecentPace: recentPace != nil)
    }

    /// Pace over the recent samples, when there are enough of them far enough
    /// apart to mean anything.
    ///
    /// A short baseline turns one busy minute into a fictional 400%/h, so the
    /// span has a floor. Samples are ignored entirely once they are old enough
    /// that "recent" would be a lie.
    private static func recentPace(
        samples: [QuotaSample], kind: QuotaWindowKind, now: Date
    ) -> Double? {
        let horizon = now.addingTimeInterval(-90 * 60)
        let recent = samples
            .filter { $0.at >= horizon && $0.value(for: kind) != nil }
            .sorted { $0.at < $1.at }
        guard recent.count >= 2,
              let first = recent.first, let last = recent.last,
              let start = first.value(for: kind), let end = last.value(for: kind)
        else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= 10 * 60 else { return nil }
        // A reset inside the sample span shows up as the percentage falling.
        // The pre-reset samples describe a window that is gone.
        guard end >= start else { return nil }
        return (end - start) / (span / 3600)
    }

    /// One line for the board: what happens, and when.
    public func summary(windowLabel: String) -> String? {
        switch verdict {
        case .unknown:
            return nil
        case .holds:
            guard let projected = projectedAtReset else { return nil }
            return "on pace for \(Int(projected.rounded()))% by reset"
        case .tight:
            guard let projected = projectedAtReset else { return nil }
            return "tight — on pace for \(Int(projected.rounded()))% by reset"
        case .exhausts:
            guard let exhaustsAt else { return "on pace to run out before reset" }
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            let when = exhaustsAt.timeIntervalSinceNow > 20 * 3600
                ? RelativeDateTimeFormatter().localizedString(for: exhaustsAt, relativeTo: Date())
                : formatter.string(from: exhaustsAt)
            return "\(windowLabel) runs out \(when) at this pace"
        }
    }
}

/// One reading of one quota window.
public struct QuotaSample: Codable, Sendable, Equatable {
    public var at: Date
    public var fiveHour: Double?
    public var sevenDay: Double?

    public init(at: Date, fiveHour: Double?, sevenDay: Double?) {
        self.at = at
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    public func value(for window: QuotaWindowKind) -> Double? {
        switch window {
        case .fiveHour: return fiveHour
        case .sevenDay: return sevenDay
        }
    }
}

public enum QuotaWindowKind: Sendable, CaseIterable {
    case fiveHour
    case sevenDay

    public var length: TimeInterval {
        switch self {
        case .fiveHour: return 5 * 3600
        case .sevenDay: return 7 * 24 * 3600
        }
    }

    public var shortLabel: String {
        switch self {
        case .fiveHour: return "5H"
        case .sevenDay: return "7D"
        }
    }

    public var longLabel: String {
        switch self {
        case .fiveHour: return "session"
        case .sevenDay: return "week"
        }
    }

    /// When this window opened.
    ///
    /// These windows are fixed-length, so a reset time gives the start for
    /// free — which is what makes both the forecast and the spend-per-window
    /// figures possible from a single reported percentage. With no reading to
    /// go on, a plain lookback of the same length is the closest thing
    /// available.
    public func windowStart(limits: RateLimits?, now: Date = Date()) -> Date {
        guard let resetsAt = limits?.window(self)?.resetsAt, resetsAt > now else {
            return now.addingTimeInterval(-length)
        }
        return resetsAt.addingTimeInterval(-length)
    }
}

/// The quota sample log.
///
/// Claude Code reports a percentage and nothing about how fast it is moving.
/// Two readings answer that, so every reading that differs from the last one
/// is appended here. JSONL because the only two operations are "append one"
/// and "read them all" — and appends really are appends: the statusline fires
/// on every assistant message, so rewriting the whole file each time would put
/// a disk write on Claude Code's hot path for no reason.
@MainActor
public final class QuotaHistory {
    /// Roughly a week of readings at the statusline's cadence. The file is
    /// compacted, not truncated, when it goes past this.
    private static let maxSamples = 4_000

    public private(set) var samples: [QuotaSample]
    private let url: URL

    public init(url: URL = Paths.usageHistory) {
        self.url = url
        self.samples = Self.read(url)
    }

    /// Records a reading. Returns false when it carried nothing new, which is
    /// the common case — most statusline fires do not move either percentage.
    @discardableResult
    public func record(_ sample: QuotaSample) -> Bool {
        if let last = samples.last,
           last.fiveHour == sample.fiveHour, last.sevenDay == sample.sevenDay {
            return false
        }
        samples.append(sample)
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
            rewrite()
        } else {
            appendLine(sample)
        }
        return true
    }

    public func samples(for kind: QuotaWindowKind) -> [QuotaSample] {
        samples.filter { $0.value(for: kind) != nil }
    }

    /// The forecast for one window against everything recorded so far.
    public func forecast(
        for kind: QuotaWindowKind, limits: RateLimits?, now: Date = Date()
    ) -> QuotaForecast {
        guard let window = limits?.window(kind) else { return .unknown }
        return QuotaForecast.project(
            window: window, kind: kind, samples: samples(for: kind), now: now)
    }

    // MARK: - Disk

    private static func read(_ url: URL) -> [QuotaSample] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(QuotaSample.self, from: lineData)
        }
    }

    private func line(for sample: QuotaSample) -> Data? {
        guard var data = try? JSONEncoder().encode(sample) else { return nil }
        data.append(0x0A)
        return data
    }

    private func appendLine(_ sample: QuotaSample) {
        guard let data = line(for: sample) else { return }
        try? Paths.ensureDirectories()
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func rewrite() {
        try? Paths.ensureDirectories()
        var blob = Data()
        for sample in samples {
            if let data = line(for: sample) { blob.append(data) }
        }
        try? blob.write(to: url, options: .atomic)
    }
}
