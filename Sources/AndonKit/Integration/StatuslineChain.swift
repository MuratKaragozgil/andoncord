import Foundation

/// Records the `statusLine` configuration that was in place before Andon Cord
/// took it over.
///
/// Only one statusline command can be configured at a time, so installing ours
/// necessarily displaces whatever was there. Rather than refuse to install, or
/// silently discard someone else's statusline, we remember it and invoke it
/// from our shim with the identical payload — their output still renders, and
/// uninstall restores the original entry byte for byte.
public struct StatuslineChain: Codable, Sendable {
    /// The displaced `statusLine.command`, if there was one.
    public var command: String?
    /// The displaced `statusLine.type`, preserved for exact restoration.
    public var type: String?
    public var padding: Int?
    public var refreshInterval: Int?
    /// Set when there was no prior statusline, so uninstall removes the key
    /// entirely instead of writing back an empty one.
    public var wasAbsent: Bool

    public init(
        command: String? = nil, type: String? = nil,
        padding: Int? = nil, refreshInterval: Int? = nil,
        wasAbsent: Bool = false
    ) {
        self.command = command
        self.type = type
        self.padding = padding
        self.refreshInterval = refreshInterval
        self.wasAbsent = wasAbsent
    }
}
