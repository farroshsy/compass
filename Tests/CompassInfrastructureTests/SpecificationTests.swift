import CompassDomain
import Foundation
import Testing

/// `docs/technical.md` §3 against the code that has to implement it.
///
/// **Why a test reads a Markdown file.** §3's per-kind payload table is not
/// prose: it is the specification week 1b's canonical encoder is written from,
/// and the canonical form cannot be revised after the first signature. A kind
/// that ships in the code and is missing from that table at the moment the
/// format freezes is a kind whose bytes nobody ever specified — the same class
/// of omission as the missing `payload` object §3 itself records, which left
/// every `habitID` outside the digest and would have let a hundred-day
/// meditation streak be rewritten into a reading streak with every proof still
/// verifying.
///
/// The constitution's §6 already requires that "if code and documentation
/// disagree, the documentation is updated in the same change, not later". This
/// is that requirement with a failing test behind it, for the one document where
/// the cost of the drift is unrecoverable. It caught nothing when it was
/// written — §3 had just been corrected by hand from eight kinds to nine — and
/// that is the point: it exists so the tenth kind cannot be added in silence.
///
/// It lives in `CompassInfrastructureTests` because it reads a file, and this is
/// the target that is allowed to.
@Suite("docs/technical.md §3 — the closed set of kinds is the one the code ships")
struct SpecificationTests {

    /// Every kind this build knows. There is no reflection over the static
    /// members of a `RawRepresentable` struct, so the list is written out — and
    /// a kind added to `EventKind` and forgotten here is caught by the two
    /// assertions below running in the other direction: the document is also
    /// checked for rows the code does not know.
    private static let shipped: [EventKind] = [
        .habitCreated, .habitRenamed, .habitArchived, .habitUnarchived,
        .checkedIn, .checkInRevoked, .achievementAwarded, .achievementRevoked,
        .subjectNamed,
    ]

    private static let spelled = [
        1: "One", 2: "Two", 3: "Three", 4: "Four", 5: "Five",
        6: "Six", 7: "Seven", 8: "Eight", 9: "Nine", 10: "Ten",
    ]

    /// `docs/technical.md`, found from this file rather than from a working
    /// directory a test runner is free to choose.
    private static func technicalDocument() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent("docs/technical.md"), encoding: .utf8)
    }

    /// Lines of the form `habitCreated(habitID, name)` — §3's kind list.
    private static func declaredKinds(in document: String) -> [String] {
        document.split(separator: "\n").compactMap { line in
            guard let open = line.firstIndex(of: "("),
                  line.startIndex < open,
                  line[line.startIndex..<open].allSatisfy({ $0.isLetter })
            else { return nil }
            return String(line[line.startIndex..<open])
        }
    }

    /// Lines of the form `habitCreated       {"habitID":…}` — §3's frozen
    /// per-kind payload table.
    private static func payloadRows(in document: String) -> [String: String] {
        var rows: [String: String] = [:]
        for line in document.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  parts[0].allSatisfy(\.isLetter),
                  parts[1].trimmingCharacters(in: .whitespaces).hasPrefix("{\"")
            else { continue }
            rows[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return rows
    }

    @Test("Every kind the code ships is listed in §3")
    func everyKindIsDeclared() throws {
        let declared = Set(SpecificationTests.declaredKinds(in: try SpecificationTests.technicalDocument()))
        for kind in SpecificationTests.shipped {
            #expect(
                declared.contains(kind.rawValue),
                "docs/technical.md §3 does not list the event kind \(kind.rawValue)"
            )
        }
    }

    /// The table the encoder is written from. A kind with no row here is a kind
    /// whose canonical bytes are unspecified, and after the first signature that
    /// is not correctable.
    @Test("Every kind the code ships has a frozen payload in §3")
    func everyKindHasAPayload() throws {
        let rows = SpecificationTests.payloadRows(in: try SpecificationTests.technicalDocument())
        #expect(rows.count == SpecificationTests.shipped.count)

        for kind in SpecificationTests.shipped {
            #expect(
                rows[kind.rawValue] != nil,
                "docs/technical.md §3's payload table has no row for \(kind.rawValue)"
            )
        }
        // And nothing in the table that this build cannot write.
        let known = Set(SpecificationTests.shipped.map(\.rawValue))
        for name in rows.keys {
            #expect(known.contains(name), "§3 specifies \(name), which the code does not ship")
        }
    }

    /// "Seven kinds, closed set" over a list of eight was how the omission stayed
    /// invisible: the sentence and the list disagreed and neither was checked.
    @Test("§3's count is the number of kinds it lists, and the number shipped")
    func theCountIsRight() throws {
        let document = try SpecificationTests.technicalDocument()
        let declared = SpecificationTests.declaredKinds(in: document)
        let expected = try #require(SpecificationTests.spelled[SpecificationTests.shipped.count])

        #expect(declared.count == SpecificationTests.shipped.count)
        #expect(
            document.contains("\(expected) kinds, closed set"),
            "§3 must open with \"\(expected) kinds, closed set\""
        )
    }

    /// The payload of a `subjectNamed` is `{"name":<string>}` and nothing else —
    /// asserted against the code, so the table above is a specification the
    /// encoder meets rather than a claim about it.
    @Test("The payloads the code writes are the payloads §3 froze")
    func theCodeWritesWhatIsSpecified() throws {
        let cases: [(EventKind, EventPayload, [String])] = [
            (.habitCreated, .habit(HabitID(rawValue: "h"), name: "Move"), ["habitID", "name"]),
            (.habitRenamed, .habit(HabitID(rawValue: "h"), name: "Move"), ["habitID", "name"]),
            (.habitArchived, .habit(HabitID(rawValue: "h")), ["habitID"]),
            (.habitUnarchived, .habit(HabitID(rawValue: "h")), ["habitID"]),
            (.checkedIn, .habit(HabitID(rawValue: "h")), ["habitID"]),
            (.checkInRevoked, .habit(HabitID(rawValue: "h")), ["habitID"]),
            (.achievementAwarded, .achievement(AchievementID(rawValue: "a")), ["achievementID"]),
            (
                .achievementRevoked,
                .achievement(AchievementID(rawValue: "a"), reason: "why"),
                ["achievementID", "reason"]
            ),
            (.subjectNamed, .subject(named: "Farros"), ["name"]),
        ]
        let rows = SpecificationTests.payloadRows(in: try SpecificationTests.technicalDocument())

        for (kind, payload, keys) in cases {
            let encoded = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(payload))
            let object = try #require(encoded as? [String: Any])
            #expect(Set(object.keys) == Set(keys), "\(kind.rawValue)")

            let row = try #require(rows[kind.rawValue], "no §3 row for \(kind.rawValue)")
            for key in keys {
                #expect(row.contains("\"\(key)\":"), "§3's \(kind.rawValue) row omits \(key)")
            }
        }
    }
}
