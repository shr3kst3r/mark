import Foundation

/// ADR-8's memory bound, enforced across every window at once.
///
/// `2026-08-26-multiple-windows-and-split-panes` names the trap this type
/// exists to close:
///
/// > `residentLimit` is a property of a `TabStore`. The obvious implementation
/// > gives each window its own store, and three windows then license 3 × 3 = 9
/// > resident views — about 470 MB — while `MARK_RESIDENT_TABS`, every log line,
/// > and any future `mark doctor` output still report the limit as 3.
///
/// So the limit is not a property of a store. One governor holds it, every
/// store registers with it, and an eviction pass ranks **every tab in the
/// application** by one clock. A window is not a memory allowance.
///
/// The MRU clock lives here for the same reason: per-store counters are not
/// comparable, and "least recently used" across two windows is meaningless
/// unless both were stamped by the same source.
@MainActor
public final class ResidencyGovernor {

    /// The application's governor. Windows share it; tests make their own.
    ///
    /// Started from the *preference* rather than from the constant, so a limit
    /// set in Settings survives a relaunch. `MARK_RESIDENT_TABS` still wins
    /// when it is set — `Preferences.residentTabs` is what enforces that, and
    /// the reason is that an environment variable is a deliberate per-launch
    /// act, usually a measurement, that a stored preference must not silently
    /// override.
    public static let shared = ResidencyGovernor(limit: Preferences.residentTabs())

    /// **3, carried forward unchanged from
    /// `2026-08-24-tab-residency-and-memory-model`.** A resident tab costs
    /// ~52 MB; 3 is ~264 MB. The superseding ADR changes what the limit is
    /// counted over, not what it is.
    public static let defaultLimit = 3

    /// The environment override, read once. Nonsense values are ignored with a
    /// log line rather than silently clamping to something surprising.
    public static let configuredLimit: Int = {
        guard let raw = ProcessInfo.processInfo.environment["MARK_RESIDENT_TABS"] else {
            return defaultLimit
        }
        guard let value = Int(raw), value >= 1 else {
            Log.tabs.error(
                "MARK_RESIDENT_TABS=\(raw, privacy: .public) is not a positive integer; using \(defaultLimit)"
            )
            return defaultLimit
        }
        return value
    }()

    /// How many tabs may hold a web view at once, **across the whole app**.
    public var limit: Int {
        didSet {
            limit = max(1, limit)
            enforce()
        }
    }

    /// Registered stores, held weakly: a closing window's store must not be
    /// kept alive by the thing that budgets it, and an eviction pass that
    /// resurrected a closed window's tabs would be worse than one that missed
    /// them.
    private var stores: [WeakStore] = []

    /// Monotonic MRU clock, application-wide.
    private var clock: UInt64 = 0

    /// Resident `WKWebView`s that no ``TabStore`` owns.
    ///
    /// Today that is one thing: the markdown reference's window
    /// (`2026-08-26-markdown-reference-window`). It is a count rather than a
    /// list because nothing here can act on such a view — it has no tab to
    /// dehydrate and no reader-visible state to preserve, so the only correct
    /// response to being over budget is to evict a *tab* instead.
    ///
    /// It is counted at all because the alternative is a lie. The budget is the
    /// application's, `mark doctor` prints it, and a web view left out of the
    /// arithmetic is 52 MB the report cannot see — which is the exact failure
    /// `2026-08-24-tab-residency-and-memory-model` was superseded for.
    public private(set) var auxiliaryWebViews = 0

    public init(limit: Int = ResidencyGovernor.configuredLimit) {
        self.limit = max(1, limit)
    }

    // MARK: - Registration

    public func register(_ store: TabStore) {
        compact()
        guard !stores.contains(where: { $0.store === store }) else { return }
        stores.append(WeakStore(store))
    }

    public func unregister(_ store: TabStore) {
        stores.removeAll { $0.store === store || $0.store == nil }
    }

    /// Every registered store that is still alive.
    public var registeredStores: [TabStore] {
        stores.compactMap(\.store)
    }

    private func compact() {
        stores.removeAll { $0.store == nil }
    }

    // MARK: - The clock

    /// The next MRU stamp. Called on every selection, in every window.
    public func stamp() -> UInt64 {
        clock += 1
        return clock
    }

    // MARK: - Accounting

    /// Every open tab in the application, in no particular order.
    public var allTabs: [DocumentTab] {
        registeredStores.flatMap(\.tabs)
    }

    /// Tabs holding a web view. Each costs ~52 MB of WebContent process.
    public var residentCount: Int {
        allTabs.count { $0.state.isResident }
    }

    /// Every resident web view in the application — tabs plus
    /// ``auxiliaryWebViews``. This, not ``residentCount``, is what the budget
    /// is about.
    public var residentWebViewCount: Int { residentCount + auxiliaryWebViews }

    /// The ADR's formula, in megabytes: `~100 MB baseline + ~52 MB × resident`.
    ///
    /// Reported by `mark doctor` rather than inferred by a reader, which is the
    /// bullet `2026-08-24-tab-residency-and-memory-model` asked for and never
    /// got.
    public var estimatedFootprintMB: Int { 100 + 52 * residentWebViewCount }

    /// A web view that is not a tab's came into existence.
    public func registerAuxiliaryWebView() {
        auxiliaryWebViews += 1
        enforce()
    }

    /// …and went away again. Clamped at zero rather than trusted: an
    /// unbalanced release should not make the app report a negative budget.
    public func unregisterAuxiliaryWebView() {
        auxiliaryWebViews = max(0, auxiliaryWebViews - 1)
    }

    // MARK: - Eviction

    /// Evict least-recently-used residents until the working set fits.
    ///
    /// Three tabs are exempt, and the third is what this supersession added:
    ///
    /// * **the selected tab** of any window — never evicted, so a limit of 1
    ///   still means "only the tab you are looking at";
    /// * **a displayed tab** — the other half of a split, and every window's
    ///   panes while some other window is key. Evicting one takes the web view
    ///   out from under a document somebody is reading, and the failure looks
    ///   like a pane going blank;
    /// * **a dirty tab**, because `2026-08-25-flock-write-locking` forbids
    ///   dehydrating unsaved work.
    ///
    /// So the working set can legitimately exceed ``limit``, and the log says by
    /// how much and why. That is the accepted trade, not a bug.
    public func enforce() {
        compact()
        let tabs = allTabs
        // Counted over every resident web view, not every resident *tab*:
        // opening the markdown reference displaces the least recently used
        // background tab rather than adding 52 MB above the ceiling.
        var over = tabs.count { $0.state.isResident } + auxiliaryWebViews - limit
        guard over > 0 else { return }

        // One ranking across every window: the least recently used tab in the
        // application is the victim, wherever it lives.
        let evictable =
            tabs
            .filter { $0.state.isResident && !$0.isDisplayed && !$0.isDirty }
            .sorted { $0.lastUsed < $1.lastUsed }

        for tab in evictable {
            guard over > 0 else { break }
            tab.store?.dehydrate(tab)
            over -= 1
        }

        reportExemptions()
    }

    /// Say out loud when the working set is over the limit and cannot come
    /// down, and which of the two reasons is holding it up.
    ///
    /// One message with two counts rather than two messages: someone reading
    /// the log wants to know why the app is using 420 MB, and "3 displayed,
    /// 2 dirty" answers that in a way two separate lines do not.
    private func reportExemptions() {
        let resident = residentWebViewCount
        guard resident > limit else { return }
        let pinned = allTabs.filter { $0.state.isResident && ($0.isDisplayed || $0.isDirty) }
        let displayed = pinned.count(where: \.isDisplayed)
        let dirty = pinned.count { $0.isDirty && !$0.isDisplayed }
        let auxiliary = auxiliaryWebViews
        Log.tabs.info(
            """
            resident set is \(resident) with a limit of \(self.limit): \
            \(displayed) displayed and \(dirty) dirty tab(s) are exempt from eviction, \
            \(auxiliary) web view(s) are not tabs \
            (~\(52 * (pinned.count + auxiliary)) MB) — a document on screen, unsaved work, \
            and the markdown reference are never dehydrated
            """
        )
    }
}

/// A weak box, because Swift arrays hold strongly and the governor must not own
/// the windows it budgets.
@MainActor
private struct WeakStore {
    weak var store: TabStore?
    init(_ store: TabStore) { self.store = store }
}
