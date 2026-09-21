import Foundation

/// A quota window as reported by Claude Code.
///
/// Percentages come straight from Claude Code rather than being derived from
/// token counts, so the number on the board is the same number the CLI would
/// print. Anthropic does not publish per-tier caps, and deriving them from
/// transcript tokens would be guesswork that goes stale every plan change.
public struct RateLimitWindow: Codable, Sendable, Equatable {
    public var usedPercentage: Double
    public var resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usedPercentage = (try? c.decode(Double.self, forKey: .usedPercentage)) ?? 0
        if let epoch = try? c.decode(Double.self, forKey: .resetsAt) {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else {
            resetsAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(usedPercentage, forKey: .usedPercentage)
        try c.encodeIfPresent(resetsAt?.timeIntervalSince1970, forKey: .resetsAt)
    }

    public init(usedPercentage: Double, resetsAt: Date?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    public var fraction: Double { min(max(usedPercentage / 100, 0), 1) }

    /// Whether this window's reset time has already passed.
    ///
    /// Matters more than it looks. Claude Code only reports quota while a
    /// session is rendering a statusline, so the last reading can easily
    /// outlive the window it described — and a percentage from a window that
    /// has since reset is not a small error, it is a number about nothing.
    /// Everything downstream refuses to draw a bar for an expired window
    /// rather than showing a stale one as if it were live.
    public func isExpired(asOf now: Date = Date()) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    /// Compact reset countdown, e.g. `4h11m` / `2d 3h`. Nil once the window
    /// has rolled over, because there is nothing left to count down to.
    public var resetCountdown: String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        let totalMinutes = Int(remaining / 60)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        // Non-breaking space: this is one token, and the only form here with a
        // gap in it. In the notch strip — the tightest place it is drawn — an
        // ordinary space let "2d 2h" break across two lines and push the whole
        // row taller than everything beside it.
        if days > 0 { return "\(days)d\u{00A0}\(hours)h" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }

    /// Board colour thresholds. Amber is deliberately early: the point of the
    /// readout is to let someone re-plan before they are blocked, not to
    /// announce the wall after they hit it.
    public var severity: Severity {
        switch usedPercentage {
        case ..<70: return .nominal
        case ..<90: return .caution
        default: return .critical
        }
    }

    public enum Severity: Sendable { case nominal, caution, critical }
}

public struct RateLimits: Codable, Sendable, Equatable {
    public var fiveHour: RateLimitWindow?
    public var sevenDay: RateLimitWindow?

    /// Every window in the payload that is not one of the two above, keyed by
    /// the name the payload used.
    ///
    /// This exists because the two named fields were not a complete list and
    /// there is no reason to think they ever will be — Anthropic has since
    /// started reporting a per-model weekly window alongside them, and the old
    /// decoder dropped it on the floor without a word. Anything unrecognised is
    /// kept verbatim and round-trips through the cache, so a window this build
    /// has never heard of is still available to show and still legible in
    /// `rate-limits.json` when someone goes looking.
    ///
    /// `Paths.rateLimitsCache` written by an older build simply has none.
    public var others: [String: RateLimitWindow] = [:]

    /// Keys handled by the typed fields, so `others` stays free of duplicates.
    private static let knownKeys: Set<String> = ["five_hour", "seven_day"]

    /// Names that arrived in the payload but that this build has no typed
    /// field for. Empty on a payload that matches expectations, which is what
    /// makes it worth logging when it is not.
    public var unrecognisedWindowNames: [String] { others.keys.sorted() }

    private struct RawKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RawKey.self)
        for key in c.allKeys {
            guard let window = try? c.decode(RateLimitWindow.self, forKey: key) else { continue }
            switch key.stringValue {
            case "five_hour": fiveHour = window
            case "seven_day": sevenDay = window
            default: others[key.stringValue] = window
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: RawKey.self)
        if let fiveHour, let key = RawKey(stringValue: "five_hour") {
            try c.encode(fiveHour, forKey: key)
        }
        if let sevenDay, let key = RawKey(stringValue: "seven_day") {
            try c.encode(sevenDay, forKey: key)
        }
        for (name, window) in others.sorted(by: { $0.key < $1.key }) {
            guard !Self.knownKeys.contains(name), let key = RawKey(stringValue: name) else { continue }
            try c.encode(window, forKey: key)
        }
    }

    public init(
        fiveHour: RateLimitWindow? = nil, sevenDay: RateLimitWindow? = nil,
        others: [String: RateLimitWindow] = [:]
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.others = others
    }

    /// Counts unrecognised windows too, and that is the point: the statusline
    /// only caches a payload it considers non-empty, so a release that renamed
    /// both known keys would otherwise stop the readout dead and leave the last
    /// good reading on screen looking current.
    public var isEmpty: Bool { fiveHour == nil && sevenDay == nil && others.isEmpty }

    /// Unrecognised windows that are still describing something real, for a UI
    /// that would rather show a window it cannot name than pretend it does not
    /// exist. Sorted for a stable order across reads.
    public func liveOthers(asOf now: Date = Date()) -> [(name: String, window: RateLimitWindow)] {
        others.sorted { $0.key < $1.key }
            .compactMap { $0.value.isExpired(asOf: now) ? nil : ($0.key, $0.value) }
    }

    public func window(_ kind: QuotaWindowKind) -> RateLimitWindow? {
        switch kind {
        case .fiveHour: return fiveHour
        case .sevenDay: return sevenDay
        }
    }

    /// Windows that are still describing something real.
    public func live(asOf now: Date = Date()) -> [(kind: QuotaWindowKind, window: RateLimitWindow)] {
        QuotaWindowKind.allCases.compactMap { kind in
            guard let window = window(kind), !window.isExpired(asOf: now) else { return nil }
            return (kind, window)
        }
    }

    /// The window closest to its cap — the one that will actually stop you.
    /// Expired windows are skipped: a rolled-over 5-hour reading stuck at 90%
    /// would otherwise permanently outrank a live weekly one.
    public func binding(asOf now: Date = Date()) -> (kind: QuotaWindowKind, window: RateLimitWindow)? {
        live(asOf: now).max { $0.window.usedPercentage < $1.window.usedPercentage }
    }
}

/// The slice of Claude Code's statusline payload we keep.
///
/// The statusline hook is the only documented surface that exposes
/// `rate_limits`, which is why AndonCord installs one at all.
public struct StatusSnapshot: Codable, Sendable, Equatable {
    public var sessionId: String?
    public var rateLimits: RateLimits?
    public var contextWindow: ContextWindow?
    public var cost: Cost?
    public var modelDisplayName: String?
    public var capturedAt: Date

    /// How long ago Claude Code produced this reading.
    public var age: TimeInterval { max(0, Date().timeIntervalSince(capturedAt)) }

    /// Beyond this, the reading is old enough that presenting it as the
    /// current state would be a lie.
    ///
    /// The statusline is the only surface that carries `rate_limits`, and it
    /// only fires while a Claude Code session is actually rendering one — so
    /// the cache goes quiet the moment you stop working, and stays quiet for
    /// however long that lasts. The number is still worth showing; pretending
    /// it is live is not.
    public var isStale: Bool { age > 15 * 60 }

    /// `4m` / `2h` / `6d`, for the "as of" label next to a stale reading.
    public var ageDescription: String {
        let minutes = Int(age / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    public struct ContextWindow: Codable, Sendable, Equatable {
        public var usedPercentage: Double?
        public var contextWindowSize: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case contextWindowSize = "context_window_size"
        }
    }

    public struct Cost: Codable, Sendable, Equatable {
        public var totalCostUsd: Double?
        public var totalLinesAdded: Int?
        public var totalLinesRemoved: Int?

        enum CodingKeys: String, CodingKey {
            case totalCostUsd = "total_cost_usd"
            case totalLinesAdded = "total_lines_added"
            case totalLinesRemoved = "total_lines_removed"
        }
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case rateLimits = "rate_limits"
        case contextWindow = "context_window"
        case cost
        case model
        case capturedAt = "captured_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try? c.decode(String.self, forKey: .sessionId)
        rateLimits = try? c.decode(RateLimits.self, forKey: .rateLimits)
        contextWindow = try? c.decode(ContextWindow.self, forKey: .contextWindow)
        cost = try? c.decode(Cost.self, forKey: .cost)
        if let model = try? c.decode(JSONValue.self, forKey: .model) {
            modelDisplayName = model["display_name"]?.stringValue
                ?? model["id"]?.stringValue
        }
        capturedAt = (try? c.decode(Date.self, forKey: .capturedAt)) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(rateLimits, forKey: .rateLimits)
        try c.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try c.encodeIfPresent(cost, forKey: .cost)
        // Round-trips as the same shape Claude Code sends, so a cached
        // snapshot decodes identically to a live one.
        if let modelDisplayName {
            try c.encode(JSONValue.object(["display_name": .string(modelDisplayName)]), forKey: .model)
        }
        try c.encode(capturedAt, forKey: .capturedAt)
    }

    public init(
        sessionId: String? = nil, rateLimits: RateLimits? = nil,
        contextWindow: ContextWindow? = nil, cost: Cost? = nil,
        modelDisplayName: String? = nil, capturedAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.rateLimits = rateLimits
        self.contextWindow = contextWindow
        self.cost = cost
        self.modelDisplayName = modelDisplayName
        self.capturedAt = capturedAt
    }
}
