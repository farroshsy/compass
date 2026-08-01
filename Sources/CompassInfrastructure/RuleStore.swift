import CompassDomain
import Foundation

/// Where the rules come from. `docs/technical.md` §5 and §6.
///
/// **Rules are data, evaluators are code.** A rule ships as a JSON row and each
/// ``RuleKind`` has a small Swift evaluator, so adding an achievement is a JSON
/// row rather than a code change and the engine backfills it over existing
/// history with `earnedOn` set to the historical day. Hard-coded
/// `if streak == 100` would need a version-gated backfill migration per
/// achievement, which is the migration pain this project cannot afford.
///
/// §6 puts them in two places — "`rules/*.json` — bundle + user directory,
/// hot-reloadable" — and both are read here. The bundled rows are seeded into the
/// store's `rules/` directory on first load, **by file name, never overwriting**,
/// so that:
///
/// - the export bundle's `rules/*.json` is actually populated (§8 lists it, and
///   a bundle without it cannot re-render an award whose rule file is gone);
/// - a new rule row shipped in a later build lands on the next launch;
/// - a file already in the store is left exactly as it is, because a rule that
///   has already fired is frozen onto an award and a rule that has been edited
///   by hand is the "hot-reloadable" half of §6.
///
/// ### Unknown kinds are skipped, and the file is left alone
///
/// `docs/achievement-protocol.md` §5.1: "An evaluator MUST skip an unknown
/// `RuleKind` with a warning and MUST leave the rule file on disk untouched." The
/// skipping happens in ``AchievementEngine``, which reports the skipped IDs. This
/// type never rewrites a rule file for any reason, which is the "untouched" half.
///
/// ### The gap this leaves, reported rather than designed around
///
/// The shipped streak rows name the four seeded habits by their compiled-in
/// identifiers, because a rule is static data and `Scope.habit` is a `HabitID`.
/// **A habit created in the settings sheet therefore has no streak rule and can
/// never earn a streak certificate.** The all-habit `total` rows still cover it,
/// since they are scoped to "any habit". The corpus does not say what should
/// happen here: `docs/technical.md` §5 says "per habit at 7, 30, 100, 365 and
/// 1000 consecutive days" and `docs/product.md` allows adding habits, and nothing
/// reconciles the two. The one-line fix when it is wanted is to write a per-habit
/// rule row into the store's `rules/` directory at `habitCreated`, which needs no
/// new concept — only a decision. `memory/known-bugs.md`.
public struct RuleStore: Sendable {

    public let layout: StoreLayout

    public init(layout: StoreLayout) {
        self.layout = layout
    }

    /// Every rule, seeded and then read from the store, sorted by ID.
    ///
    /// A rule file that cannot be decoded is **skipped and left on disk**, never
    /// deleted and never fatal: `docs/technical.md` §6 ends its damage policy
    /// with "never silently drop lines and never refuse to launch", and a rule
    /// file written by a newer build is the ordinary case of a file this build
    /// cannot read.
    public func load() throws -> [RuleSpec] {
        try seedIfAbsent()

        var rules: [RuleID: RuleSpec] = [:]
        for url in ruleFiles(in: layout.rules) {
            guard let data = try? Data(contentsOf: url),
                  let rows = try? JSONDecoder().decode([RuleSpec].self, from: data)
            else { continue }
            // A duplicate ID across two files is resolved deterministically by
            // file name and then by position, so two launches agree. It cannot
            // change what a recorded award says: the award carries its own frozen
            // copy of the rule that fired.
            for rule in rows where rules[rule.id] == nil {
                rules[rule.id] = rule
            }
        }
        return rules.values.sorted { $0.id < $1.id }
    }

    /// Copies bundled rule files the store does not already have.
    func seedIfAbsent() throws {
        try FileManager.default.createDirectory(
            at: layout.rules, withIntermediateDirectories: true
        )
        for source in RuleStore.bundledRuleFiles {
            let destination = layout.rules.appendingPathComponent(source.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func ruleFiles(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The rows compiled into the package's resource bundle.
    ///
    /// Empty rather than fatal when the bundle is unreachable. A first launch
    /// that cannot read its rules records every tap exactly as before and simply
    /// awards nothing — which is the correct failure for a subsystem that sits
    /// beside the loop rather than inside it. The seeded *habits* are compiled-in
    /// constants for the opposite reason: a first launch with no rows is a broken
    /// screen. `AppComposition.seededHabits`.
    static var bundledRuleFiles: [URL] {
        guard let directory = Bundle.module.url(forResource: "Rules", withExtension: nil),
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil
              )
        else { return [] }
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
