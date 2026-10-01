import Foundation

/// Which build this is.
///
/// `mark` ships as a Homebrew `--HEAD` formula (`Formula/mark.rb`), so the
/// semver in `Cargo.toml` moves on a deliberate bump while the code moves every
/// push: between two bumps every install reports the same version, and "am I
/// running the build I just made?" has no answer. Brew already speaks in
/// commits — `HEAD-19ecc64 -> HEAD-061dce8` — so this does too.
///
/// The values come from `Info.plist`, which `scripts/assemble-bundle.sh` writes
/// from the same checkout, in the same run, that produced the two binaries next
/// to it — the script deletes and rebuilds the bundle every time, so the plist
/// cannot describe an older build than the Mach-O it sits beside. The core is
/// stamped identically by `core/build.rs`, and `mark doctor` prints the CLI's
/// copy; a disagreement between the two is itself worth seeing.
///
/// It is *not* read over the C ABI. ADR-1 caps that surface at twelve functions
/// and `mark_version` already spends one; a build string is not the thing to
/// spend a superseding ADR on.
public enum BuildInfo {

    /// What a build with no answer reports. Never an empty string and never a
    /// plausible-looking placeholder: "which build is this?" answered wrongly
    /// is worse than answered not at all.
    public static let unknown = "unknown"

    /// How the plist is read. A closure rather than a `Bundle`, because the
    /// tests need to describe a bundle that does not exist — a build from a
    /// tarball with no `.git`, an empty value, a bundle with no stamp at all —
    /// and `Bundle` cannot be made to say those things.
    /// `@Sendable` because the one production instance is a `static let` and
    /// `Info.plist` is read-only for the life of the process.
    typealias Lookup = @Sendable (String) -> String?

    private static let main: Lookup = { key in
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    /// `0.2.0` — or the core's own version when there is no plist to read,
    /// which is how `swift test` and `mark-bench` run.
    public static var version: String { version(main) }

    /// `061dce8`, `061dce8-dirty`, or `unknown`.
    public static var commit: String { commit(main) }

    /// The date ``commit`` was committed, `YYYY-MM-DD`, or `unknown`.
    public static var date: String { date(main) }

    /// `0.2.0 (061dce8 2026-08-25)`. What the launch log and `ping` report, and
    /// what a bug report should carry.
    public static var summary: String { summary(main) }

    static func version(_ lookup: Lookup) -> String {
        string("CFBundleShortVersionString", lookup)
            ?? (try? MarkCore.version())
            ?? unknown
    }

    static func commit(_ lookup: Lookup) -> String {
        string("MarkBuildCommit", lookup) ?? unknown
    }

    static func date(_ lookup: Lookup) -> String {
        string("MarkBuildDate", lookup) ?? unknown
    }

    static func summary(_ lookup: Lookup) -> String {
        "\(version(lookup)) (\(commit(lookup)) \(date(lookup)))"
    }

    /// An empty value is treated as absent: that is what a `${commit}`
    /// substitution leaves behind when git answers with nothing, and a blank
    /// where a commit should be reads as a bug in the reporting rather than as
    /// a build with no provenance.
    private static func string(_ key: String, _ lookup: Lookup) -> String? {
        guard let value = lookup(key), !value.isEmpty else { return nil }
        return value
    }
}
