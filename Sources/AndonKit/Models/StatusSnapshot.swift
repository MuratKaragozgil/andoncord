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

    /// Compact reset countdown, e.g. `4h11m` / `2d 3h`.
    public var resetCountdown: String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSinceNow
        guard remaining > 0 else { return "now" }
        let totalMinutes = Int(remaining / 60)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
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

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    public init(fiveHour: RateLimitWindow? = nil, sevenDay: RateLimitWindow? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    public var isEmpty: Bool { fiveHour == nil && sevenDay == nil }

    /// The window closest to its cap — the one that will actually stop you.
    public var binding: (label: String, window: RateLimitWindow)? {
        switch (fiveHour, sevenDay) {
        case let (.some(five), .some(seven)):
            return five.usedPercentage >= seven.usedPercentage
                ? ("5h", five) : ("7d", seven)
        case let (.some(five), nil): return ("5h", five)
        case let (nil, .some(seven)): return ("7d", seven)
        case (nil, nil): return nil
        }
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
