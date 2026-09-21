import Foundation

/// What a quota window is really at, combining the two things that know
/// anything about it.
///
/// Claude Code publishes `rate_limits` on exactly one surface — the statusline
/// — and a statusline only renders while a session is drawing one. Work
/// through the desktop app, an SDK session, or a headless run and the reading
/// never updates at all; close every terminal and it stops the moment you do.
/// The cached number then sits there looking authoritative for however long
/// that lasts, which is how a board ends up confidently wrong.
///
/// The transcripts have no such gap: every request is written down as it
/// happens. They just do not know what the cap *is*, because Anthropic does
/// not publish per-tier limits. So the two halves complete each other — one
/// real reading pins the scale, and the ledger carries it forward:
///
///     cap ≈ spend in the window ÷ (reported percentage ÷ 100)
///
/// Spend is measured in cost-equivalent dollars rather than raw tokens
/// deliberately: that already weights an Opus request against a Haiku one and
/// discounts cache reads, which raw token counts do not.
///
/// An estimate is never dressed up as a reading — `source` says which it is,
/// and the UI draws them differently.
public struct QuotaReadout: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Straight from Claude Code. `stale` means the reading is old enough
        /// that spend has probably moved since.
        case reported(at: Date, stale: Bool)
        /// Claude Code's last reading, carried forward by measured spend.
        case extrapolated(from: Date)
        /// No usable reading; derived entirely from spend against a cap
        /// calibrated earlier.
        case estimated(calibratedAt: Date)
        /// Nothing to say.
        case unknown
    }

    public var kind: QuotaWindowKind
    /// Best available figure, or nil when there is genuinely nothing to show.
    public var usedPercentage: Double?
    public var resetsAt: Date?
    public var source: Source
    /// What the ledger counted inside this window.
    public var spent: TokenUsage
    public var forecast: QuotaForecast

    public init(
        kind: QuotaWindowKind, usedPercentage: Double? = nil, resetsAt: Date? = nil,
        source: Source = .unknown, spent: TokenUsage = TokenUsage(),
        forecast: QuotaForecast = .unknown
    ) {
        self.kind = kind
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.source = source
        self.spent = spent
        self.forecast = forecast
    }

    /// Whether the number came from Claude Code itself, unqualified.
    public var isMeasured: Bool {
        if case .reported(_, let stale) = source { return !stale }
        return false
    }

    public var isEstimate: Bool {
        switch source {
        case .extrapolated, .estimated: return true
        case .reported, .unknown: return false
        }
    }

    public var fraction: Double {
        min(max((usedPercentage ?? 0) / 100, 0), 1)
    }

    public var severity: RateLimitWindow.Severity {
        RateLimitWindow(usedPercentage: usedPercentage ?? 0, resetsAt: resetsAt).severity
    }

    public var resetCountdown: String? {
        RateLimitWindow(usedPercentage: 0, resetsAt: resetsAt).resetCountdown
    }

    /// Inputs the composer needs. Grouped so the call site reads as one thing
    /// rather than seven positional arguments.
    public struct Inputs: Sendable {
        public var limits: RateLimits?
        public var capturedAt: Date?
        public var isStale: Bool
        /// Ledger spend across the whole window.
        public var spentInWindow: TokenUsage
        /// Ledger spend since the reading was taken — the part the reported
        /// percentage cannot know about.
        public var spentSinceReading: TokenUsage
        public var calibration: QuotaCalibration
        public var samples: [QuotaSample]

        public init(
            limits: RateLimits?, capturedAt: Date?, isStale: Bool,
            spentInWindow: TokenUsage, spentSinceReading: TokenUsage,
            calibration: QuotaCalibration, samples: [QuotaSample]
        ) {
            self.limits = limits
            self.capturedAt = capturedAt
            self.isStale = isStale
            self.spentInWindow = spentInWindow
            self.spentSinceReading = spentSinceReading
            self.calibration = calibration
            self.samples = samples
        }
    }

    public static func compose(
        kind: QuotaWindowKind, inputs: Inputs, now: Date = Date()
    ) -> QuotaReadout {
        let window = inputs.limits?.window(kind)
        let capUsd = inputs.calibration.capUsd(for: kind)

        // A reading whose window has already reset describes a window that no
        // longer exists, so it is dropped rather than aged.
        if let window, !window.isExpired(asOf: now), let capturedAt = inputs.capturedAt {
            var used = window.usedPercentage
            var source = Source.reported(at: capturedAt, stale: inputs.isStale)

            // The reported figure is a snapshot; requests made after it are
            // invisible to it. When the cap is known, adding them back is
            // strictly closer to the truth than pretending nothing happened.
            if inputs.isStale, let capUsd, capUsd > 0, inputs.spentSinceReading.costUsd > 0 {
                used = min(100, used + inputs.spentSinceReading.costUsd / capUsd * 100)
                source = .extrapolated(from: capturedAt)
            }

            let forecast = QuotaForecast.project(
                window: RateLimitWindow(usedPercentage: used, resetsAt: window.resetsAt),
                kind: kind, samples: inputs.samples, now: now)
            return QuotaReadout(
                kind: kind, usedPercentage: used, resetsAt: window.resetsAt,
                source: source, spent: inputs.spentInWindow, forecast: forecast)
        }

        // No usable reading. Spend is still measured, so with a cap from an
        // earlier calibration the window can be reconstructed from scratch.
        guard let capUsd, capUsd > 0, let calibratedAt = inputs.calibration.date(for: kind) else {
            return QuotaReadout(kind: kind, spent: inputs.spentInWindow)
        }
        let used = min(100, inputs.spentInWindow.costUsd / capUsd * 100)
        // The reset time is unknown: a 5-hour window opens on the first
        // request after the last one closed, and nothing on disk records that.
        // Assuming one would put a countdown on the board that is fiction.
        return QuotaReadout(
            kind: kind, usedPercentage: used, resetsAt: nil,
            source: .estimated(calibratedAt: calibratedAt),
            spent: inputs.spentInWindow,
            forecast: .unknown)
    }

    /// How the figure was arrived at, in the words a person would use.
    public var provenance: String {
        switch source {
        case .reported(_, let stale) where !stale:
            return "reported by Claude Code"
        case .reported(let at, _):
            return "reported by Claude Code, \(Self.age(at))"
        case .extrapolated(let from):
            return "reported \(Self.age(from)), plus spend measured since"
        case .estimated(let calibratedAt):
            return "estimated from spend, scaled to a reading from \(Self.age(calibratedAt))"
        case .unknown:
            return "no reading yet"
        }
    }

    private static func age(_ date: Date) -> String {
        let minutes = Int(max(0, Date().timeIntervalSince(date)) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

/// What one quota window's cap works out to, in cost-equivalent dollars.
///
/// Learned rather than configured: Anthropic publishes no per-tier caps, and a
/// hard-coded table would be wrong the day a plan changes. One honest reading
/// of "you are 40% through this window" alongside "$8.10 of spend went into
/// it" is all it takes to derive the rest, and every later reading refines it.
public struct QuotaCalibration: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var capUsd: Double
        public var at: Date
        /// How many readings have gone into this figure, so a single odd one
        /// can be told apart from a settled average.
        public var samples: Int

        public init(capUsd: Double, at: Date, samples: Int) {
            self.capUsd = capUsd
            self.at = at
            self.samples = samples
        }
    }

    public var fiveHour: Entry?
    public var sevenDay: Entry?

    public init(fiveHour: Entry? = nil, sevenDay: Entry? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    public func entry(for kind: QuotaWindowKind) -> Entry? {
        switch kind {
        case .fiveHour: return fiveHour
        case .sevenDay: return sevenDay
        }
    }

    public func capUsd(for kind: QuotaWindowKind) -> Double? { entry(for: kind)?.capUsd }
    public func date(for kind: QuotaWindowKind) -> Date? { entry(for: kind)?.at }

    /// Fold in a fresh reading.
    ///
    /// Two guards, for two different ways this goes wrong.
    ///
    /// Claude Code reports the percentage to one decimal, so dividing by a
    /// very small one multiplies its rounding error: at 1% used the implied
    /// cap can be out by a factor of three. Five percent is where that error
    /// falls under a couple of percent, which is well inside the noise
    /// everything else here carries.
    ///
    /// The other risk is the numerator. Spend is only as complete as the
    /// transcripts on this machine — a window worked from another Mac, or one
    /// whose transcripts were pruned, reads as cheaper than it was and would
    /// scale the cap down with it. Requiring a decent number of measured
    /// requests behind the figure is what rules that out.
    ///
    /// Past those, readings are blended rather than replacing each other, so
    /// one unusual window cannot throw the scale — and a reading no newer than
    /// the last one folded in is ignored, so offering the same one repeatedly
    /// is harmless.
    public mutating func observe(
        kind: QuotaWindowKind, usedPercentage: Double, spent: TokenUsage, at: Date
    ) {
        guard usedPercentage >= 5, spent.costUsd > 0, spent.requests >= 25 else { return }
        let existing = entry(for: kind)
        // Each reading counts once. The same one is offered again on every
        // relaunch and after every re-index, and folding it in repeatedly
        // would let one window quietly become the whole average.
        if let existing, at <= existing.at { return }
        let implied = spent.costUsd / (usedPercentage / 100)
        let blended = existing.map { $0.capUsd * 0.7 + implied * 0.3 } ?? implied
        let updated = Entry(
            capUsd: blended, at: at, samples: (existing?.samples ?? 0) + 1)
        switch kind {
        case .fiveHour: fiveHour = updated
        case .sevenDay: sevenDay = updated
        }
    }

    // MARK: - Storage

    public static func load(from url: URL = Paths.quotaCalibration) -> QuotaCalibration {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(QuotaCalibration.self, from: data)
        else { return QuotaCalibration() }
        return decoded
    }

    public func save(to url: URL = Paths.quotaCalibration) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? Paths.ensureDirectories()
        try? data.write(to: url, options: .atomic)
    }
}
