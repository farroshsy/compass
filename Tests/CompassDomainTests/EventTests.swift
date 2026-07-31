import Foundation
import Testing

@testable import CompassDomain

@Suite("Event — the record")
struct EventRecordTests {

    @Test("Every event carries the sync-shaped fields from the very first write")
    func fieldsPresentFromTheFirstWrite() throws {
        let subject = event(.checkedIn, habit: habitA, lamport: 1, source: .tap)
        let text = try #require(
            String(data: try JSONEncoder().encode(subject), encoding: .utf8)
        )

        for key in [
            "\"v\"", "\"id\"", "\"device\"", "\"lamport\"", "\"kind\"", "\"day\"",
            "\"recordedAt\"", "\"zoneOffset\"", "\"source\"", "\"payload\"", "\"prev\"",
        ] {
            #expect(text.contains(key), "missing \(key)")
        }
    }

    @Test("v is 1 and recordedAt is an integer count of milliseconds")
    func versionAndTimestamp() throws {
        let subject = event(.checkedIn, habit: habitA, lamport: 1, recordedAt: 1_754_000_000_123)
        #expect(subject.v == 1)
        #expect(Event.currentVersion == 1)

        let text = try #require(
            String(data: try JSONEncoder().encode(subject), encoding: .utf8)
        )
        #expect(text.contains("\"recordedAt\":1754000000123"))
        #expect(!text.contains("."), "no floating point may reach a digested value")
    }

    @Test("prev is 32 bytes, and genesis is 32 zero bytes")
    func prevChain() throws {
        #expect(Event.genesisPrev.count == 32)
        #expect(Event.genesisPrev.allSatisfy { $0 == 0 })

        let subject = event(.checkedIn, habit: habitA, lamport: 1)
        #expect(subject.prev == Event.genesisPrev)

        let encoded = try JSONEncoder().encode(subject)
        let decoded = try JSONDecoder().decode(Event.self, from: encoded)
        #expect(decoded.prev.count == Event.hashLength)
    }

    @Test("A prev that is not a SHA-256 length is rejected")
    func shortPrevRejected() throws {
        var object = try encodedObject(
            of: event(.checkedIn, habit: habitA, lamport: 1)
        )
        object["prev"] = "AAAA"
        #expect(throws: (any Error).self) {
            try decodeEvent(object)
        }
    }

    @Test("An absent optional is omitted entirely, never emitted as null")
    func absentSourceIsOmitted() throws {
        let subject = event(.habitCreated, habit: habitA, lamport: 1, name: "Meditate")
        let text = try #require(
            String(data: try JSONEncoder().encode(subject), encoding: .utf8)
        )
        #expect(!text.contains("\"source\""))
        #expect(!text.contains("null"))
    }

    @Test("An event round-trips unchanged")
    func roundTrip() throws {
        for subject in corpus() {
            let decoded = try JSONDecoder().decode(
                Event.self, from: try JSONEncoder().encode(subject)
            )
            #expect(decoded == subject)
        }
    }

    @Test("The total order is (lamport, device), and device breaks ties byte-wise")
    func totalOrder() {
        let low = EventOrder(lamport: 3, device: deviceApp)
        let high = EventOrder(lamport: 4, device: deviceApp)
        #expect(low < high)

        let tieA = EventOrder(lamport: 3, device: deviceApp)     // "1111…"
        let tieB = EventOrder(lamport: 3, device: deviceWidget)  // "2222…"
        #expect(tieA < tieB)
        #expect(!(tieB < tieA))

        // Lamport dominates the device tiebreak.
        #expect(EventOrder(lamport: 3, device: deviceWidget) < EventOrder(lamport: 4, device: deviceApp))
    }
}

@Suite("Event — unknown kinds and forward compatibility")
struct EventForwardCompatibilityTests {

    @Test("An unknown event kind from a newer build decodes instead of crashing")
    func unknownKindDecodes() throws {
        var object = try encodedObject(of: event(.checkedIn, habit: habitA, lamport: 7))
        object["kind"] = "habitTeleported"

        let decoded = try decodeEvent(object)

        #expect(decoded.kind.rawValue == "habitTeleported")
        #expect(decoded.kind != .checkedIn)
        #expect(decoded.day == day("2026-07-31"))
    }

    @Test("An unknown event kind is re-emitted unchanged, never dropped")
    func unknownKindRoundTrips() throws {
        var object = try encodedObject(of: event(.checkedIn, habit: habitA, lamport: 7))
        object["kind"] = "habitTeleported"

        let once = try decodeEvent(object)
        let twice = try JSONDecoder().decode(
            Event.self, from: try JSONEncoder().encode(once)
        )
        #expect(twice == once)
        #expect(twice.kind.rawValue == "habitTeleported")
    }

    @Test("An unknown event kind is ignored by the fold, not fatal to it")
    func unknownKindFoldsToNothing() throws {
        var object = try encodedObject(of: event(.checkedIn, habit: habitA, lamport: 7))
        object["kind"] = "habitTeleported"
        let unknown = try decodeEvent(object)

        let known = event(.checkedIn, habit: habitA, on: day("2026-07-30"), lamport: 1)
        let projection = project([known, unknown])

        #expect(projection.isChecked(habitA, on: day("2026-07-30")))
        #expect(!projection.isChecked(habitA, on: day("2026-07-31")))
    }

    @Test("An unknown source value is rejected rather than silently changed")
    func unknownSourceRejected() throws {
        var object = try encodedObject(
            of: event(.checkedIn, habit: habitA, lamport: 1, source: .tap)
        )
        object["source"] = "backfill"
        #expect(throws: (any Error).self) {
            try decodeEvent(object)
        }
    }

    @Test("extra round-trips losslessly, including nesting and null")
    func extraRoundTrips() throws {
        let bag: [String: JSONValue] = [
            "clientBuild": .string("2026.31"),
            "retries": .int(0),
            "wasWidget": .bool(true),
            "nothing": .null,
            "nested": .object(["days": .array([.int(1), .int(2)]), "note": .string("hi")]),
        ]
        let subject = event(.checkedIn, habit: habitA, lamport: 1, extra: bag)

        let decoded = try JSONDecoder().decode(
            Event.self, from: try JSONEncoder().encode(subject)
        )
        #expect(decoded.extra == bag)
        #expect(decoded == subject)
    }

    @Test("An empty extra is not written, and a missing extra decodes as empty")
    func emptyExtraIsOmitted() throws {
        let subject = event(.checkedIn, habit: habitA, lamport: 1)
        let text = try #require(
            String(data: try JSONEncoder().encode(subject), encoding: .utf8)
        )
        #expect(!text.contains("\"extra\""))

        let decoded = try JSONDecoder().decode(
            Event.self, from: try JSONEncoder().encode(subject)
        )
        #expect(decoded.extra.isEmpty)
    }

    @Test("A floating-point value inside extra is refused, not rounded")
    func extraRefusesFloatingPoint() throws {
        var object = try encodedObject(of: event(.checkedIn, habit: habitA, lamport: 1))
        object["extra"] = ["ratio": 0.5]
        #expect(throws: (any Error).self) {
            try decodeEvent(object)
        }
    }
}

@Suite("Event — payload is closed")
struct EventPayloadTests {

    @Test("A payload with no fields of its own is an empty object, never null")
    func emptyPayload() throws {
        let subject = event(.achievementAwarded, lamport: 1, payload: .empty)
        let text = try #require(
            String(data: try JSONEncoder().encode(subject), encoding: .utf8)
        )
        #expect(text.contains("\"payload\":{}"))
    }

    @Test("payload is required")
    func payloadRequired() throws {
        var object = try encodedObject(of: event(.checkedIn, habit: habitA, lamport: 1))
        object["payload"] = nil
        #expect(throws: (any Error).self) {
            try decodeEvent(object)
        }
    }

    @Test("An unknown payload key makes the event invalid")
    func unknownPayloadKeyRejected() throws {
        var object = try encodedObject(of: event(.checkedIn, habit: habitA, lamport: 1))
        object["payload"] = ["habitID": "habit-a", "cadence": "weekly"]
        #expect(throws: (any Error).self) {
            try decodeEvent(object)
        }
    }

    @Test("The known payload keys decode")
    func knownPayloadKeys() throws {
        var object = try encodedObject(of: event(.achievementRevoked, lamport: 1))
        object["payload"] = [
            "achievementID": "streak.habit-a.7@2026-07-07",
            "reason": "a day it depended on was edited",
        ]
        let decoded = try decodeEvent(object)
        #expect(decoded.payload.achievementID?.rawValue == "streak.habit-a.7@2026-07-07")
        #expect(decoded.payload.reason == "a day it depended on was edited")
        #expect(decoded.payload.habitID == nil)
    }
}

// MARK: - Hand-built JSON, so a test can write a line no encoder would produce

private func encodedObject(of event: Event) throws -> [String: Any] {
    let data = try JSONEncoder().encode(event)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "event did not encode as an object")
        )
    }
    return object
}

private func decodeEvent(_ object: [String: Any]) throws -> Event {
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(Event.self, from: data)
}
