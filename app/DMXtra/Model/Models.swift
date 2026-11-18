import Foundation

// Codable models that mirror embedded/API.md exactly. Field names match the
// JSON keys, so no CodingKeys are needed.

/// `GET /`
struct ControllerInfo: Codable, Equatable, Sendable {
    var name: String
    var firmware: String
    var universeSize: Int
    var maxFixtures: Int
    var fixtureCount: Int
}

/// One entry of `GET /fixture-types`.
struct FixtureType: Codable, Hashable, Identifiable, Sendable {
    var type: String
    var label: String
    var channelCount: Int
    var channels: [String]

    var id: String { type }
}

/// One entry of `GET /fixtures`, and the body returned by the fixture endpoints.
struct Fixture: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var name: String
    var type: String
    var address: Int
    var channelCount: Int
    var channels: [String]
    var values: [Int]

    /// The DMX channels this fixture occupies, e.g. `1...3`.
    var channelRange: ClosedRange<Int> {
        address...(address + max(channelCount, 1) - 1)
    }

    /// The last DMX channel this fixture occupies.
    var endAddress: Int { channelRange.upperBound }
}

/// `GET /dmx` response and `POST /dmx` request body.
struct DmxRange: Codable, Equatable, Sendable {
    var start: Int
    var values: [Int]
}

// MARK: - Request / response bodies

/// `POST /fixtures` body.
struct NewFixture: Codable, Equatable, Sendable {
    var name: String
    var type: String
    var address: Int
}

/// `PATCH /fixtures/{id}` body. Nil properties are left out of the JSON;
/// nil entries inside `values` are sent as `null` ("leave unchanged").
struct FixtureUpdate: Codable, Equatable, Sendable {
    var name: String?
    var address: Int?
    var values: [Int?]?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(address, forKey: .address)
        if let values {
            // Encode explicitly so nil entries become JSON null.
            var arr = c.nestedUnkeyedContainer(forKey: .values)
            for v in values {
                if let v { try arr.encode(v) } else { try arr.encodeNil() }
            }
        }
    }
}

/// `POST /dmx` response: `{"start":1,"count":3}`.
struct DmxWriteResult: Codable, Equatable, Sendable {
    var start: Int
    var count: Int
}

/// Every 4xx/5xx body: `{"error":"..."}`.
struct ServerErrorBody: Codable, Equatable, Sendable {
    var error: String
}
