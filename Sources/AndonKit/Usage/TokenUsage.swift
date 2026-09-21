import Foundation

/// One request's worth of token accounting, in the four buckets Claude bills
/// separately.
///
/// Kept as a plain additive value so the same type can describe a single API
/// call, one prompt's turn, a session, a project, or a whole week — the only
/// difference between those is how many of them were summed.
public struct TokenUsage: Codable, Sendable, Equatable {
    public var input: Int = 0
    public var output: Int = 0
    /// Tokens written into the prompt cache. Claude Code uses the 1-hour TTL,
    /// which is the expensive write tier.
    public var cacheWrite: Int = 0
    /// Tokens read back out of the cache. Individually cheap, but every turn
    /// re-reads the entire conversation, so this is where a long session's
    /// spend actually accumulates.
    public var cacheRead: Int = 0
    /// How many API requests these numbers came from. Needed to tell "one
    /// enormous turn" apart from "two hundred small ones".
    public var requests: Int = 0
    /// Accumulated at parse time, because the per-token rate depends on which
    /// model served each request and a session can switch models mid-way.
    public var costUsd: Double = 0

    public init() {}

    public init(
        input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0,
        requests: Int = 0, costUsd: Double = 0
    ) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.requests = requests
        self.costUsd = costUsd
    }

    /// Everything that had to be sent or generated, cache reads included.
    ///
    /// This is the honest "how much did this move through the model" number,
    /// and the one to sort by — a session that reads 8M cached tokens is
    /// genuinely more expensive than one that reads 80k, even though neither
    /// wrote much.
    public var total: Int { input + output + cacheWrite + cacheRead }

    /// Tokens that were *new* to the model: everything except cache reads.
    ///
    /// Useful as the "real work" denominator, since cache reads are mostly a
    /// function of how long the conversation already is rather than of what
    /// the current turn asked for.
    public var fresh: Int { input + output + cacheWrite }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            requests: lhs.requests + rhs.requests,
            costUsd: lhs.costUsd + rhs.costUsd)
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) { lhs = lhs + rhs }

    public var isEmpty: Bool { requests == 0 && total == 0 }
}

/// Per-million-token rates for one model.
///
/// These are list prices for the Claude API. A Max/Pro subscription is not
/// billed per token at all, so the dollar figures here are a *cost-equivalent*
/// — what the same traffic would have cost on the API. That is still the most
/// useful single number for comparing two sessions, and the UI labels it as an
/// estimate rather than a bill.
public struct ModelPricing: Sendable, Equatable {
    public let input: Double
    public let output: Double
    public let cacheWrite: Double
    public let cacheRead: Double

    /// Cache pricing is a fixed multiple of the input rate: writes at the
    /// 1-hour TTL Claude Code uses cost 2×, reads 0.1×.
    public init(input: Double, output: Double) {
        self.input = input
        self.output = output
        self.cacheWrite = input * 2
        self.cacheRead = input * 0.1
    }

    public func cost(_ usage: TokenUsage) -> Double {
        (Double(usage.input) * input
            + Double(usage.output) * output
            + Double(usage.cacheWrite) * cacheWrite
            + Double(usage.cacheRead) * cacheRead) / 1_000_000
    }

    /// Matched by prefix so a dated snapshot id (`claude-opus-4-5@20251101`)
    /// resolves to the same rates as the bare id. Unknown models fall back to
    /// Sonnet, the middle tier — guessing high would make an unrecognised
    /// model look like the most expensive thing on the board.
    public static func forModel(_ id: String?) -> ModelPricing {
        guard let id = id?.lowercased() else { return sonnet }
        if id.contains("fable") || id.contains("mythos") { return fable }
        if id.contains("haiku") { return haiku }
        if id.contains("opus") { return opus }
        if id.contains("sonnet") { return sonnet }
        return sonnet
    }

    public static let fable = ModelPricing(input: 10, output: 50)
    public static let opus = ModelPricing(input: 5, output: 25)
    public static let sonnet = ModelPricing(input: 3, output: 15)
    public static let haiku = ModelPricing(input: 1, output: 5)
}

/// Compact token counts for a readout that has to stay the same width as it
/// ticks: `912`, `41.2k`, `3.8M`.
public func formatTokens(_ count: Int) -> String {
    let value = Double(count)
    switch abs(count) {
    case 1_000_000...:
        return String(format: "%.1fM", value / 1_000_000)
    case 10_000...:
        return String(format: "%.0fk", value / 1_000)
    case 1_000...:
        return String(format: "%.1fk", value / 1_000)
    default:
        return "\(count)"
    }
}

/// Dollar amounts, with enough precision at the low end that a cheap session
/// does not round away to `$0.00` and look like a bug.
public func formatCost(_ usd: Double) -> String {
    if usd >= 100 { return String(format: "$%.0f", usd) }
    if usd >= 1 { return String(format: "$%.2f", usd) }
    if usd >= 0.01 { return String(format: "$%.2f", usd) }
    if usd <= 0 { return "$0" }
    return "<$0.01"
}
