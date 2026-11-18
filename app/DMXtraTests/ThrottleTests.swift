import Foundation
import Testing
@testable import DMXtra

struct ThrottleCoreTests {
    @Test func firstChangeSendsImmediately() {
        var core = ThrottleCore(minInterval: 0.05)
        core.submit([10, nil, nil])
        #expect(core.nextAction(now: 100) == .send([10, nil, nil]))
        #expect(core.inFlight)
        #expect(core.nextAction(now: 100) == .idle)
    }

    @Test func newerValueReplacesWaitingOne() {
        var core = ThrottleCore(minInterval: 0.05)
        core.submit([1, nil, nil])
        #expect(core.nextAction(now: 0) == .send([1, nil, nil]))
        core.didFinishSend()
        // Three changes inside the interval collapse into the newest one.
        core.submit([2, nil, nil])
        core.submit([3, nil, nil])
        core.submit([4, nil, nil])
        #expect(core.nextAction(now: 0.01) == .wait(0.04))
        #expect(core.nextAction(now: 0.05) == .send([4, nil, nil]))
    }

    @Test func changesToDifferentChannelsAreMerged() {
        var core = ThrottleCore(minInterval: 0.05)
        core.submit([1, nil, nil])
        core.submit([nil, 2, nil])
        core.submit([5, nil, 3])
        #expect(core.nextAction(now: 0) == .send([5, 2, 3]))
    }

    @Test func noSecondSendWhileOneIsInFlight() {
        var core = ThrottleCore(minInterval: 0.05)
        core.submit([1])
        _ = core.nextAction(now: 0)
        core.submit([2])
        // Interval has passed, but the first request hasn't finished.
        #expect(core.nextAction(now: 1) == .idle)
        #expect(core.isBusy)
        core.didFinishSend()
        #expect(core.nextAction(now: 1) == .send([2]))
    }

    @Test func rateNeverExceedsTwentyPerSecond() {
        var core = ThrottleCore(minInterval: 0.05)
        var sends: [TimeInterval] = []
        // Simulate a fader moving every 5 ms for one second.
        var t: TimeInterval = 0
        var i = 0
        while t < 1.0 {
            core.submit([i % 256])
            if case .send = core.nextAction(now: t) {
                sends.append(t)
                core.didFinishSend()
            }
            t += 0.005
            i += 1
        }
        #expect(sends.count <= 21)
        #expect(sends.count >= 15)
        for (a, b) in zip(sends, sends.dropFirst()) {
            #expect(b - a >= 0.05 - 1e-9)
        }
    }

    @Test func finalValueAlwaysGoesOut() {
        var core = ThrottleCore(minInterval: 0.05)
        core.submit([100])
        _ = core.nextAction(now: 0)
        core.didFinishSend()
        core.submit([200])  // the user lets go here
        #expect(core.isBusy)
        if case .wait(let w) = core.nextAction(now: 0.02) {
            #expect(abs(w - 0.03) < 1e-9)
        } else {
            Issue.record("expected wait")
        }
        #expect(core.nextAction(now: 0.05) == .send([200]))
        core.didFinishSend()
        #expect(!core.isBusy)
        #expect(core.nextAction(now: 1) == .idle)
    }

    @Test func discardPendingDropsWaitingChange() {
        var core = ThrottleCore(minInterval: 0.05)
        core.submit([1])
        core.discardPending()
        #expect(core.nextAction(now: 0) == .idle)
    }
}

/// The driver, with a fake clock so nothing actually sleeps.
@MainActor
struct FixtureUpdateThrottleTests {
    final class Recorder {
        var now: TimeInterval = 0
        var sends: [(time: TimeInterval, id: Int, values: [Int?])] = []
    }

    private func makeThrottle(_ r: Recorder) -> FixtureUpdateThrottle {
        FixtureUpdateThrottle(
            minInterval: 0.05,
            now: { r.now },
            sleep: { r.now += $0 },
            sender: { id, values in r.sends.append((r.now, id, values)) }
        )
    }

    private func drain(_ t: FixtureUpdateThrottle) async {
        for _ in 0..<1000 where !t.isIdle { await Task.yield() }
    }

    @Test func burstCollapsesToNewestValue() async {
        let r = Recorder()
        let t = makeThrottle(r)
        for v in 0...50 { t.submit(fixtureID: 1, values: [v, nil, nil]) }
        await drain(t)
        #expect(r.sends.count == 1)
        #expect(r.sends.last?.values == [50, nil, nil])
    }

    @Test func trailingValueIsSentAfterInterval() async {
        let r = Recorder()
        let t = makeThrottle(r)
        t.submit(fixtureID: 1, values: [1])
        await drain(t)
        t.submit(fixtureID: 1, values: [2])
        t.submit(fixtureID: 1, values: [3])
        await drain(t)
        #expect(r.sends.map(\.values) == [[1], [3]])
        #expect(r.sends[1].time - r.sends[0].time >= 0.05 - 1e-9)
        #expect(!t.isBusy(fixtureID: 1))
    }

    @Test func fixturesAreThrottledIndependently() async {
        let r = Recorder()
        let t = makeThrottle(r)
        t.submit(fixtureID: 1, values: [1])
        t.submit(fixtureID: 2, values: [2])
        await drain(t)
        #expect(Set(r.sends.map(\.id)) == [1, 2])
        #expect(r.sends.allSatisfy { $0.time == 0 })
    }
}
