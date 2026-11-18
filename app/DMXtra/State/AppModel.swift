import Foundation
import Observation

enum ConnectionState: Equatable {
    case notConfigured
    case connecting
    case connected(ControllerInfo)
    case unreachable(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// All app state, shared by every screen.
@Observable
@MainActor
final class AppModel {
    static let addressDefaultsKey = "controllerAddress"
    /// How long poll results are ignored for a fixture after its last local edit.
    static let pollHoldAfterEdit: TimeInterval = 1.5
    static let pollInterval: Duration = .seconds(2)

    // MARK: Published state

    private(set) var addressText: String
    private(set) var connection: ConnectionState = .notConfigured
    private(set) var fixtureTypes: [FixtureType] = []
    private(set) var fixtures: [Fixture] = []
    /// Universe values, index 0 = DMX channel 1.
    private(set) var universe: [Int] = Array(repeating: 0, count: PatchMath.defaultUniverseSize)
    /// The last error from a fixture/channel update, for the UI to show.
    var lastError: ControllerError?

    var info: ControllerInfo? {
        if case .connected(let info) = connection { return info }
        return nil
    }

    var universeSize: Int { info?.universeSize ?? PatchMath.defaultUniverseSize }

    // MARK: Private state

    @ObservationIgnored private var client: ControllerClient?
    @ObservationIgnored private var lastInfo: ControllerInfo?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private lazy var throttle = FixtureUpdateThrottle { [weak self] id, values in
        await self?.sendValues(fixtureID: id, values: values)
    }
    /// Fixtures with a control currently held down.
    @ObservationIgnored private var activeEdits: Set<Int> = []
    /// Last local edit time per fixture (system uptime).
    @ObservationIgnored private var lastEdit: [Int: TimeInterval] = [:]
    /// Bumped on every connect, so stale responses from an old address are dropped.
    @ObservationIgnored private var generation = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.addressText = defaults.string(forKey: Self.addressDefaultsKey) ?? ""
    }

    // MARK: - Connection

    /// Connect to the saved address, if there is one.
    func connectToSavedAddress() async {
        guard !addressText.isEmpty, client == nil else { return }
        await connect(to: addressText)
    }

    /// Save `text` as the controller address and connect to it.
    func connect(to text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        addressText = text
        defaults.set(text, forKey: Self.addressDefaultsKey)
        generation += 1
        let gen = generation

        guard let url = ControllerAddress.baseURL(from: text) else {
            client = nil
            connection = text.isEmpty ? .notConfigured : .unreachable(ControllerError.invalidAddress(text).localizedDescription)
            return
        }

        let client = ControllerClient(baseURL: url)
        self.client = client
        fixtures = []
        fixtureTypes = []
        universe = Array(repeating: 0, count: PatchMath.defaultUniverseSize)
        connection = .connecting

        do {
            let info = try await client.info()
            let types = try await client.fixtureTypes()
            let fixtures = try await client.fixtures()
            guard gen == generation else { return }
            lastInfo = info
            fixtureTypes = types
            universe = Array(repeating: 0, count: info.universeSize)
            applyPolled(fixtures)
            connection = .connected(info)
            await refreshUniverse()
        } catch {
            guard gen == generation else { return }
            connection = .unreachable(ControllerError.from(error).localizedDescription)
        }
    }

    /// Retry the current address.
    func reconnect() async {
        await connect(to: addressText)
    }

    // MARK: - Refreshing

    /// `GET /fixtures`. Also keeps the connection status honest.
    func refreshFixtures() async {
        // connect() is already fetching everything.
        guard let client, connection != .connecting else { return }
        let gen = generation
        do {
            let list = try await client.fixtures()
            guard gen == generation else { return }
            // Pick up fixture types and info if the first connect failed.
            if fixtureTypes.isEmpty || !connection.isConnected {
                let info = try await client.info()
                let types = try await client.fixtureTypes()
                guard gen == generation else { return }
                lastInfo = info
                fixtureTypes = types
            }
            applyPolled(list)
            if let lastInfo {
                var info = lastInfo
                info.fixtureCount = list.count
                connection = .connected(info)
            }
        } catch {
            guard gen == generation else { return }
            connection = .unreachable(ControllerError.from(error).localizedDescription)
        }
    }

    /// `GET /dmx` for the whole universe.
    func refreshUniverse() async {
        guard let client else { return }
        let gen = generation
        do {
            let range = try await client.dmx()
            guard gen == generation else { return }
            var next = universe
            if next.count < range.start - 1 + range.values.count {
                next += Array(repeating: 0, count: range.start - 1 + range.values.count - next.count)
            }
            for (i, v) in range.values.enumerated() {
                let channel = range.start + i
                // Keep local values for fixtures the user is editing.
                if let owner = fixtures.first(where: { $0.channelRange.contains(channel) }), isHeld(owner.id) {
                    continue
                }
                next[channel - 1] = v
            }
            universe = next
        } catch {
            guard gen == generation else { return }
            connection = .unreachable(ControllerError.from(error).localizedDescription)
        }
    }

    /// Polls `GET /fixtures` (and optionally `GET /dmx`) every 2 s until the
    /// calling task is cancelled, i.e. while the screen that started it is visible.
    func pollWhileVisible(includeUniverse: Bool = false) async {
        while !Task.isCancelled {
            await refreshFixtures()
            if includeUniverse { await refreshUniverse() }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Replace the fixture list with a fresh one from the server, keeping the
    /// local values of fixtures the user is editing so a poll can't yank a fader.
    private func applyPolled(_ list: [Fixture]) {
        let local = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.id, $0) })
        fixtures = list.map { incoming in
            guard isHeld(incoming.id), let mine = local[incoming.id],
                  mine.channelCount == incoming.channelCount
            else { return incoming }
            var merged = incoming
            merged.values = mine.values
            return merged
        }
        for f in fixtures {
            for (i, v) in f.values.enumerated() where f.address - 1 + i < universe.count {
                universe[f.address - 1 + i] = v
            }
        }
    }

    // MARK: - Hold-back while editing

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func isHeld(_ fixtureID: Int) -> Bool {
        if activeEdits.contains(fixtureID) { return true }
        if throttle.isBusy(fixtureID: fixtureID) { return true }
        if let t = lastEdit[fixtureID], uptime - t < Self.pollHoldAfterEdit { return true }
        return false
    }

    /// Call when a fader is grabbed (`true`) or released (`false`).
    func setEditing(_ editing: Bool, fixtureID: Int) {
        if editing {
            activeEdits.insert(fixtureID)
        } else {
            activeEdits.remove(fixtureID)
        }
        lastEdit[fixtureID] = uptime
    }

    // MARK: - Fixture values

    func fixture(id: Int) -> Fixture? {
        fixtures.first { $0.id == id }
    }

    func fixtureType(for fixture: Fixture) -> FixtureType? {
        fixtureTypes.first { $0.type == fixture.type }
    }

    func typeLabel(for fixture: Fixture) -> String {
        fixtureType(for: fixture)?.label ?? fixture.type
    }

    /// Set one channel of a fixture from a fader.
    func setValue(_ value: Int, channel index: Int, fixtureID: Int) {
        var changes = [Int?](repeating: nil, count: fixture(id: fixtureID)?.channelCount ?? 0)
        guard changes.indices.contains(index) else { return }
        changes[index] = value
        apply(changes, fixtureID: fixtureID)
    }

    /// Set the red/green/blue channels of a color fixture together.
    func setColor(red: Int, green: Int, blue: Int, fixtureID: Int) {
        guard let f = fixture(id: fixtureID), let rgb = f.rgbChannelIndices else { return }
        var changes = [Int?](repeating: nil, count: f.channelCount)
        changes[rgb.red] = red
        changes[rgb.green] = green
        changes[rgb.blue] = blue
        apply(changes, fixtureID: fixtureID)
    }

    /// Apply changes locally right away, then hand them to the throttle.
    /// Only channels whose value actually changed are sent; the rest are null.
    private func apply(_ changes: [Int?], fixtureID: Int) {
        guard let i = fixtures.firstIndex(where: { $0.id == fixtureID }) else { return }
        var f = fixtures[i]
        guard changes.count == f.channelCount else { return }
        var outgoing = [Int?](repeating: nil, count: f.channelCount)
        for (ch, value) in changes.enumerated() {
            guard let value else { continue }
            let clamped = min(max(value, 0), 255)
            guard f.values.indices.contains(ch), f.values[ch] != clamped else { continue }
            f.values[ch] = clamped
            outgoing[ch] = clamped
            let u = f.address - 1 + ch
            if universe.indices.contains(u) { universe[u] = clamped }
        }
        guard outgoing.contains(where: { $0 != nil }) else { return }
        fixtures[i] = f
        lastEdit[fixtureID] = uptime
        throttle.submit(fixtureID: fixtureID, values: outgoing)
    }

    private func sendValues(fixtureID: Int, values: [Int?]) async {
        guard let client else { return }
        do {
            // The response's values are ignored: the local copy is newer while editing.
            _ = try await client.updateFixture(id: fixtureID, FixtureUpdate(values: values))
        } catch {
            let e = ControllerError.from(error)
            lastError = e
            if case .server = e {
                lastEdit[fixtureID] = nil
                await refreshFixtures()
            }
        }
    }

    // MARK: - Patch editing

    /// `POST /fixtures`. Throws `ControllerError` so the form can show the server's message.
    @discardableResult
    func addFixture(name: String, type: String, address: Int) async throws -> Fixture {
        let client = try requireClient()
        do {
            let created = try await client.createFixture(NewFixture(name: name, type: type, address: address))
            await refreshFixtures()
            return created
        } catch {
            throw ControllerError.from(error)
        }
    }

    /// `PATCH /fixtures/{id}` with only the fields that changed.
    func updateFixture(id: Int, name: String?, address: Int?) async throws {
        let client = try requireClient()
        guard name != nil || address != nil else { return }
        do {
            _ = try await client.updateFixture(id: id, FixtureUpdate(name: name, address: address))
            lastEdit[id] = nil
            await refreshFixtures()
            await refreshUniverse()
        } catch {
            throw ControllerError.from(error)
        }
    }

    /// `DELETE /fixtures/{id}`.
    func deleteFixture(id: Int) async throws {
        let client = try requireClient()
        do {
            try await client.deleteFixture(id: id)
            fixtures.removeAll { $0.id == id }
            await refreshFixtures()
            await refreshUniverse()
        } catch {
            throw ControllerError.from(error)
        }
    }

    /// The suggested start address for a new fixture with this many channels.
    func suggestedAddress(channelCount: Int, excluding id: Int? = nil) -> Int? {
        PatchMath.nextFreeAddress(channelCount: channelCount, fixtures: fixtures, excluding: id, universeSize: universeSize)
    }

    // MARK: - Universe

    /// `POST /dmx` for a single channel.
    func setChannel(_ channel: Int, to value: Int) async throws {
        let client = try requireClient()
        do {
            try await client.setDmx(DmxRange(start: channel, values: [min(max(value, 0), 255)]))
            if let owner = fixtures.first(where: { $0.channelRange.contains(channel) }) {
                lastEdit[owner.id] = nil
            }
            await refreshUniverse()
            await refreshFixtures()
        } catch {
            throw ControllerError.from(error)
        }
    }

    // MARK: - Blackout

    /// `POST /blackout`, then re-read everything.
    func blackout() async {
        guard let client else { return }
        throttle.discardAllPending()
        activeEdits.removeAll()
        lastEdit.removeAll()
        do {
            try await client.blackout()
            await refreshFixtures()
            await refreshUniverse()
        } catch {
            lastError = ControllerError.from(error)
        }
    }

    private func requireClient() throws -> ControllerClient {
        guard let client else { throw ControllerError.unreachable("Set the controller address first.") }
        return client
    }
}
