import Foundation
import Observation

/// The token book: every Claude Code session on this Mac, what it cost, and
/// where the cost went.
///
/// Claude Code already writes everything needed for this — it just never adds
/// it up. `~/.claude/projects/<mangled-cwd>/<session>.jsonl` holds one line per
/// content block with the API's `usage` attached, which is the only record
/// anywhere of what an individual prompt or file read actually cost. The
/// ledger indexes those files, keeps the result on disk so a relaunch is
/// instant, and re-reads only what changed.
///
/// Nothing here talks to the network, and nothing is written outside
/// `~/.andoncord`.
@Observable
@MainActor
public final class UsageLedger {
    public private(set) var sessions: [SessionUsage] = []
    /// True during the first full index, which on a year of transcripts takes
    /// long enough that the panel needs to say so rather than look empty.
    public private(set) var isIndexing = false
    public private(set) var indexedAt: Date?
    /// Set when the transcripts directory cannot be read at all, so a blank
    /// board is explainable instead of mysterious.
    public private(set) var failure: String?

    /// Called after every pass. The app uses it to revisit anything that was
    /// computed against an index that had not finished loading yet.
    @ObservationIgnored
    public var onIndexed: (() -> Void)?

    @ObservationIgnored
    private var cache: [String: IndexEntry] = [:]
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var ticker: Task<Void, Never>?

    /// How often the transcript directory is re-checked. Only files whose
    /// size or mtime moved are re-read, so this is a `stat` per transcript —
    /// cheap enough to keep the board close to live without a watcher on
    /// twenty directories.
    private static let pollInterval: Duration = .seconds(20)

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        loadCache()
        refresh()
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Re-index anything that changed. Safe to call from a hook event — a
    /// refresh already in flight is left to finish rather than restarted.
    public func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            await self?.reindexNow()
            self?.refreshTask = nil
        }
    }

    /// The same pass, awaited. Separate from `refresh()` so a caller that
    /// needs the result — a test, or a first load that must finish before
    /// anything is drawn — can wait for it.
    public func reindexNow() async {
        let known = cache
        if sessions.isEmpty { isIndexing = true }
        let result = await Self.reindex(known: known)
        cache = result.entries
        sessions = result.entries.values
            .compactMap(\.session)
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        failure = result.failure
        isIndexing = false
        indexedAt = Date()
        if result.changed { saveCache() }
        onIndexed?()
    }

    // MARK: - Derived views

    /// Sessions whose activity falls inside a window, with their usage clipped
    /// to it. A session that started yesterday and is still running must not
    /// contribute yesterday's tokens to "today".
    public func sessions(since cutoff: Date) -> [SessionUsage] {
        sessions.compactMap { session in
            guard session.lastActivityAt >= cutoff else { return nil }
            let inWindow = session.hourly.filter { $0.hour >= cutoff }
            guard !inWindow.isEmpty else { return nil }
            var clipped = session
            clipped.hourly = inWindow
            clipped.usage = inWindow.reduce(TokenUsage()) { $0 + $1.usage }
            return clipped
        }
    }

    /// Summed straight off the buckets rather than through `sessions(since:)`.
    ///
    /// Views call this several times per redraw — two quota cards, the pill,
    /// the strip — so it does no work beyond the addition itself.
    public func total(since cutoff: Date) -> TokenUsage {
        sessions.reduce(TokenUsage()) { running, session in
            guard session.lastActivityAt >= cutoff else { return running }
            return running + session.hourly
                .filter { $0.hour >= cutoff }
                .reduce(TokenUsage()) { $0 + $1.usage }
        }
    }

    /// Spend inside an arbitrary interval, including ones that have already
    /// closed.
    ///
    /// Needed to pair a quota reading with the spend that produced it. That
    /// reading may be days old, and "the last five hours" is then the wrong
    /// five hours entirely — the window it described has to be reconstructed
    /// from its own reset time.
    public func total(in interval: Range<Date>) -> TokenUsage {
        sessions.reduce(TokenUsage()) { running, session in
            running + session.hourly
                .filter { interval.contains($0.hour) }
                .reduce(TokenUsage()) { $0 + $1.usage }
        }
    }

    /// Sessions grouped by the directory they ran in, biggest spend first.
    public func projects(since cutoff: Date? = nil) -> [ProjectUsage] {
        let scope = cutoff.map { sessions(since: $0) } ?? sessions
        var grouped: [String: [SessionUsage]] = [:]
        for session in scope {
            let path = session.projectPath.isEmpty ? "Unknown" : session.projectPath
            grouped[path, default: []].append(session)
        }
        return grouped.map { path, sessions in
            ProjectUsage(
                path: path,
                usage: sessions.reduce(TokenUsage()) { $0 + $1.usage },
                sessions: sessions.sorted { $0.usage.total > $1.usage.total },
                lastActivityAt: sessions.map(\.lastActivityAt).max() ?? .distantPast)
        }
        .sorted { $0.usage.total > $1.usage.total }
    }

    /// The heaviest single prompts across everything in the window, each
    /// carrying the session it belongs to so a row can name the project.
    public func costliestPrompts(since cutoff: Date, limit: Int = 12) -> [(SessionUsage, PromptTurn)] {
        sessions(since: cutoff)
            .flatMap { session in
                session.turns
                    .filter { !$0.isSynthetic && $0.at >= cutoff }
                    .map { (session, $0) }
            }
            .sorted { $0.1.usage.total > $1.1.usage.total }
            .prefix(limit)
            .map { $0 }
    }

    /// The heaviest context contributors — files re-read, commands whose
    /// output never left the window — merged across sessions.
    public func costliestFootprints(since cutoff: Date, limit: Int = 12) -> [ContextFootprint] {
        var merged: [String: ContextFootprint] = [:]
        for session in sessions(since: cutoff) {
            for footprint in session.footprints where footprint.lastAt >= cutoff {
                let id = "\(footprint.tool)\u{1}\(footprint.key)"
                if var existing = merged[id] {
                    existing.occurrences += footprint.occurrences
                    existing.directTokens += footprint.directTokens
                    existing.carriedTokens += footprint.carriedTokens
                    existing.lastAt = max(existing.lastAt, footprint.lastAt)
                    merged[id] = existing
                } else {
                    merged[id] = footprint
                }
            }
        }
        return merged.values
            .sorted { $0.totalTokens > $1.totalTokens }
            .prefix(limit)
            .map { $0 }
    }

    /// Hour-by-hour totals across every session, oldest first. The basis for
    /// burn rate and the activity strip.
    public func hourlyTotals(since cutoff: Date) -> [HourBucket] {
        var merged: [Date: TokenUsage] = [:]
        for session in sessions where session.lastActivityAt >= cutoff {
            for bucket in session.hourly where bucket.hour >= cutoff {
                merged[bucket.hour, default: TokenUsage()] += bucket.usage
            }
        }
        return merged.map { HourBucket(hour: $0.key, usage: $0.value) }
            .sorted { $0.hour < $1.hour }
    }

    public func session(id: String) -> SessionUsage? {
        sessions.first { $0.id == id }
    }

    // MARK: - Indexing

    struct IndexEntry: Codable, Sendable {
        var size: Int
        var modified: Date
        var session: SessionUsage?
    }

    private struct ReindexResult: Sendable {
        var entries: [String: IndexEntry]
        var changed: Bool
        var failure: String?
    }

    /// Walk the transcript tree and re-read only what moved.
    ///
    /// Runs off the main actor: a first index over a year of transcripts is
    /// hundreds of megabytes of JSON, and doing that on the main thread would
    /// freeze the notch panel for the duration.
    private nonisolated static func reindex(
        known: [String: IndexEntry]
    ) async -> ReindexResult {
        await Task.detached(priority: .utility) { () -> ReindexResult in
            let root = Paths.claudeDir.appendingPathComponent("projects")
            guard let projectDirs = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])
            else {
                return ReindexResult(
                    entries: known, changed: false,
                    failure: "No transcripts at \(root.path)")
            }

            var entries: [String: IndexEntry] = [:]
            var stale: [(path: String, url: URL, size: Int, modified: Date)] = []

            for directory in projectDirs {
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
                )) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    let values = try? file.resourceValues(
                        forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size = values?.fileSize ?? 0
                    let modified = values?.contentModificationDate ?? .distantPast

                    if let cached = known[file.path],
                       cached.size == size, cached.modified == modified {
                        entries[file.path] = cached
                    } else {
                        stale.append((file.path, file, size, modified))
                    }
                }
            }

            // The first index is hundreds of megabytes of JSON and the only
            // moment this could plausibly feel slow. Files are independent, so
            // scan them across cores; after that first run this list is
            // normally one file — whichever session is live.
            if !stale.isEmpty {
                let scanned = await withTaskGroup(of: (String, IndexEntry).self) { group in
                    for item in stale {
                        group.addTask {
                            let session = TranscriptScanner.scan(
                                file: item.url,
                                sessionId: item.url.deletingPathExtension().lastPathComponent)
                            return (item.path, IndexEntry(
                                size: item.size, modified: item.modified, session: session))
                        }
                    }
                    var results: [String: IndexEntry] = [:]
                    for await (path, entry) in group { results[path] = entry }
                    return results
                }
                entries.merge(scanned) { _, new in new }
            }

            // A transcript that disappeared drops out by omission, which is
            // still a change worth persisting.
            let changed = !stale.isEmpty || entries.count != known.count
            return ReindexResult(entries: entries, changed: changed, failure: nil)
        }.value
    }

    // MARK: - Cache

    /// The index is expensive to build and entirely derived, so it lives in
    /// our own directory and is thrown away rather than migrated when its
    /// shape changes.
    private static let cacheVersion = 2

    private struct CacheFile: Codable {
        var version: Int
        var entries: [String: IndexEntry]
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Paths.usageIndex),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              file.version == Self.cacheVersion
        else { return }
        cache = file.entries
        sessions = file.entries.values
            .compactMap(\.session)
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private func saveCache() {
        let file = CacheFile(version: Self.cacheVersion, entries: cache)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? Paths.ensureDirectories()
        try? data.write(to: Paths.usageIndex, options: .atomic)
    }
}
