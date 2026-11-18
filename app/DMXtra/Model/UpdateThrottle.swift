import Foundation

/// The rate-limiting state machine for one fixture's value updates.
///
/// Pure and clock-free so it can be unit-tested: callers pass in the current
/// time. Changes are merged per channel, so a newer value for a channel
/// replaces a waiting one instead of being queued behind it, and changes to
/// different channels made between two sends are combined into one request.
struct ThrottleCore: Equatable {
    enum Action: Equatable {
        /// Send these values now (nil = leave that channel unchanged).
        case send([Int?])
        /// Something is waiting; ask again after this many seconds.
        case wait(TimeInterval)
        /// Nothing to send.
        case idle
    }

    let minInterval: TimeInterval
    private(set) var pending: [Int?]?
    private(set) var lastSendTime: TimeInterval?
    private(set) var inFlight = false

    init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    /// True while there is a change waiting or a request on the wire.
    var isBusy: Bool { pending != nil || inFlight }

    /// Record a change. Non-nil entries overwrite whatever is waiting for that channel.
    mutating func submit(_ values: [Int?]) {
        guard var merged = pending, merged.count == values.count else {
            pending = values
            return
        }
        for (i, v) in values.enumerated() where v != nil {
            merged[i] = v
        }
        pending = merged
    }

    /// Decide what to do now. A `.send` marks the request as in flight;
    /// call `didFinishSend()` when it completes.
    mutating func nextAction(now: TimeInterval) -> Action {
        guard !inFlight, let values = pending else { return .idle }
        if let last = lastSendTime, now - last < minInterval {
            return .wait(minInterval - (now - last))
        }
        pending = nil
        inFlight = true
        lastSendTime = now
        return .send(values)
    }

    mutating func didFinishSend() {
        inFlight = false
    }

    /// Drop anything waiting (e.g. after a blackout).
    mutating func discardPending() {
        pending = nil
    }
}

/// Drives one `ThrottleCore` per fixture and performs the sends.
///
/// At most one request per fixture is in flight, sends are spaced at least
/// `minInterval` apart, and whatever is waiting when the user lets go is
/// always sent: the pump keeps running until nothing is pending.
@MainActor
final class FixtureUpdateThrottle {
    typealias Sender = @MainActor (_ fixtureID: Int, _ values: [Int?]) async -> Void

    private let minInterval: TimeInterval
    private let now: @MainActor () -> TimeInterval
    private let sleep: @MainActor (TimeInterval) async -> Void
    private let sender: Sender

    private var cores: [Int: ThrottleCore] = [:]
    private var pumps: [Int: Task<Void, Never>] = [:]

    init(
        minInterval: TimeInterval = 1.0 / 20.0,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @MainActor (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        sender: @escaping Sender
    ) {
        self.minInterval = minInterval
        self.now = now
        self.sleep = sleep
        self.sender = sender
    }

    func submit(fixtureID: Int, values: [Int?]) {
        cores[fixtureID, default: ThrottleCore(minInterval: minInterval)].submit(values)
        if pumps[fixtureID] == nil {
            pumps[fixtureID] = Task { [weak self] in await self?.pump(fixtureID) }
        }
    }

    func isBusy(fixtureID: Int) -> Bool {
        cores[fixtureID]?.isBusy ?? false
    }

    var isIdle: Bool { pumps.isEmpty }

    /// Drop all waiting changes. Requests already sent still complete.
    func discardAllPending() {
        for id in cores.keys { cores[id]?.discardPending() }
    }

    private func pump(_ id: Int) async {
        while true {
            let action = cores[id]?.nextAction(now: now()) ?? .idle
            switch action {
            case .idle:
                pumps[id] = nil
                return
            case .wait(let seconds):
                await sleep(seconds)
            case .send(let values):
                await sender(id, values)
                cores[id]?.didFinishSend()
            }
        }
    }
}
