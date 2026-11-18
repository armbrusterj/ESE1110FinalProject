import Foundation
import Testing
@testable import DMXtra

/// End-to-end checks against the Rust simulator in `simulator/` (or a real board).
/// Skipped unless DMXTRA_MOCK_URL is set, e.g.:
///
///     (cd simulator && cargo run --release) &
///     TEST_RUNNER_DMXTRA_MOCK_URL=127.0.0.1:8080 xcodebuild test ...
///
/// These tests change the controller's state (they add and remove a fixture,
/// set values, and end with a blackout).
private let mockAddress = ProcessInfo.processInfo.environment["DMXTRA_MOCK_URL"]

@Suite(.serialized, .enabled(if: mockAddress != nil, "set DMXTRA_MOCK_URL to run"))
struct MockServerIntegrationTests {
    private var client: ControllerClient {
        ControllerClient(baseURL: ControllerAddress.baseURL(from: mockAddress!)!)
    }

    @Test func readsInfoTypesAndFixtures() async throws {
        let client = client
        let info = try await client.info()
        #expect(info.name == "DMXtra")
        #expect(info.universeSize == 512)
        let types = try await client.fixtureTypes()
        #expect(!types.isEmpty)
        let fixtures = try await client.fixtures()
        #expect(fixtures.count == info.fixtureCount)
        let dmx = try await client.dmx()
        #expect(dmx.start == 1 && dmx.values.count == 512)
    }

    @Test func serverErrorsCarryTheMessage() async throws {
        let client = client
        let fixtures = try await client.fixtures()
        let taken = try #require(fixtures.first)
        await #expect(throws: ControllerError.server(status: 409, message: "address overlaps another fixture")) {
            _ = try await client.createFixture(NewFixture(name: "Clash", type: taken.type, address: taken.address))
        }
        await #expect(throws: ControllerError.server(status: 404, message: "no such fixture")) {
            _ = try await client.fixture(id: 999_999)
        }
        await #expect(throws: ControllerError.server(status: 400, message: "values must be integers 0-255")) {
            try await client.setDmx(DmxRange(start: 1, values: [300]))
        }
    }

    @Test func createPatchAndDelete() async throws {
        let client = client
        let types = try await client.fixtureTypes()
        let type = try #require(types.first)
        let free = try #require(PatchMath.nextFreeAddress(channelCount: type.channelCount, fixtures: try await client.fixtures()))
        let created = try await client.createFixture(NewFixture(name: "Integration", type: type.type, address: free))
        #expect(created.address == free && created.channelCount == type.channelCount)

        var values = [Int?](repeating: nil, count: created.channelCount)
        values[0] = 77
        let updated = try await client.updateFixture(id: created.id, FixtureUpdate(name: "Integration 2", values: values))
        #expect(updated.name == "Integration 2")
        #expect(updated.values[0] == 77)

        try await client.deleteFixture(id: created.id)
        let dmx = try await client.dmx(start: free, count: 1)
        #expect(dmx.values == [0])
    }

    /// Many callers at once must still reach the one-connection-at-a-time server in order.
    @Test func parallelCallersAreSerialized() async throws {
        let client = client
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<30 {
                group.addTask { try await client.fixtures().count }
            }
            for try await count in group { #expect(count >= 0) }
        }
    }

    /// A fader burst through AppModel ends with the final value on the server.
    @MainActor @Test func faderBurstLandsOnFinalValue() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: "DMXtraTests-\(UUID())")!)
        await model.connect(to: mockAddress!)
        #expect(model.connection.isConnected)
        let fixture = try #require(model.fixtures.first)

        model.setEditing(true, fixtureID: fixture.id)
        for v in stride(from: 0, through: 255, by: 3) {
            model.setValue(v, channel: 0, fixtureID: fixture.id)
            try await Task.sleep(for: .milliseconds(5))
        }
        model.setValue(201, channel: 0, fixtureID: fixture.id)
        model.setEditing(false, fixtureID: fixture.id)

        for _ in 0..<100 where model.isHeld(fixture.id) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let onServer = try await client.fixture(id: fixture.id)
        #expect(onServer.values[0] == 201)

        await model.blackout()
        #expect(model.fixture(id: fixture.id)?.values.allSatisfy { $0 == 0 } == true)
    }
}
