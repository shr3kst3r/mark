import AppKit
import Foundation
import UniformTypeIdentifiers

/// Row icons, cached by *kind* rather than fetched per path.
///
/// `NSWorkspace.icon(forFile:)` — which is what M2's sidebar called once per
/// row per redraw — asks LaunchServices about that specific file, and
/// LaunchServices may go to disk for a bundle's `Info.plist` or a custom icon
/// resource. `mark-bench` measured the cost directly: with a per-path lookup,
/// moving the root to a 34-entry directory took **414 ms** and a burst of
/// arriving badges stalled the main thread for **551 ms**, both of them almost
/// entirely inside icon fetches. With this cache the same moves are single-
/// digit milliseconds.
///
/// **What is given up, stated plainly:** a file or folder with a *custom* icon
/// now draws its type's generic icon in the sidebar. That is a real, visible
/// difference, and it is the trade this makes deliberately — a project tree
/// where scrolling stutters is worse than one where a folder someone
/// customised in Finder looks like every other folder. Finder itself is the
/// only place most people expect custom icons, and ⌘⌥R still gets there.
///
/// Not an `NSCache`: the key space is "how many file extensions are in this
/// tree", which is tens, and the values are shared `NSImage`s that AppKit
/// already keeps alive. Eviction would buy nothing and would reintroduce the
/// stall it exists to prevent.
@MainActor
public enum SidebarIcons {

    private static var cache: [String: NSImage] = [:]

    /// Lookups served, and lookups that actually asked the system. Read by
    /// `mark-bench`, so "the cache stopped working" is a measurement rather
    /// than a mystery about why scrolling got worse.
    public private(set) static var hits = 0
    public private(set) static var misses = 0

    public static func icon(for node: TreeNode) -> NSImage {
        icon(isDirectory: node.isDirectory, pathExtension: node.url.pathExtension)
    }

    public static func icon(isDirectory: Bool, pathExtension: String) -> NSImage {
        let key = isDirectory ? "\u{0}dir" : pathExtension.lowercased()
        if let cached = cache[key] {
            hits += 1
            return cached
        }
        misses += 1
        let type: UTType
        if isDirectory {
            type = .folder
        } else if !key.isEmpty, let resolved = UTType(filenameExtension: key) {
            type = resolved
        } else {
            // No extension, or one macOS has never heard of. `.data` is the
            // generic document icon, which is what Finder shows too.
            type = .data
        }
        let icon = NSWorkspace.shared.icon(for: type)
        cache[key] = icon
        return icon
    }

    /// For tests and for `mark-bench`, so a measurement starts cold.
    public static func reset() {
        cache.removeAll()
        hits = 0
        misses = 0
    }
}
