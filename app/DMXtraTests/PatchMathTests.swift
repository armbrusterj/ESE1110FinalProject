import Testing
@testable import DMXtra

struct PatchMathTests {
    private func fixture(_ id: Int, at address: Int, count: Int) -> Fixture {
        Fixture(id: id, name: "F\(id)", type: "t\(count)", address: address, channelCount: count,
                channels: (0..<count).map { "ch\($0)" }, values: Array(repeating: 0, count: count))
    }

    @Test func emptyPatchStartsAtOne() {
        #expect(PatchMath.nextFreeAddress(channelCount: 3, fixtures: []) == 1)
    }

    @Test func defaultPatchSuggestsSeven() {
        let patch = [fixture(1, at: 1, count: 3), fixture(2, at: 4, count: 3)]
        #expect(PatchMath.nextFreeAddress(channelCount: 3, fixtures: patch) == 7)
        #expect(PatchMath.nextFreeAddress(channelCount: 1, fixtures: patch) == 7)
    }

    @Test func fillsFirstGapThatFits() {
        // Gap of 2 at 4–5, gap of 4 at 9–12.
        let patch = [fixture(1, at: 1, count: 3), fixture(2, at: 6, count: 3), fixture(3, at: 13, count: 1)]
        #expect(PatchMath.nextFreeAddress(channelCount: 1, fixtures: patch) == 4)
        #expect(PatchMath.nextFreeAddress(channelCount: 2, fixtures: patch) == 4)
        #expect(PatchMath.nextFreeAddress(channelCount: 3, fixtures: patch) == 9)
        #expect(PatchMath.nextFreeAddress(channelCount: 4, fixtures: patch) == 9)
        #expect(PatchMath.nextFreeAddress(channelCount: 5, fixtures: patch) == 14)
    }

    @Test func gapBeforeFirstFixture() {
        let patch = [fixture(1, at: 10, count: 3)]
        #expect(PatchMath.nextFreeAddress(channelCount: 4, fixtures: patch) == 1)
        #expect(PatchMath.nextFreeAddress(channelCount: 10, fixtures: patch) == 13)
    }

    @Test func unsortedInputIsHandled() {
        let patch = [fixture(2, at: 4, count: 3), fixture(1, at: 1, count: 3)]
        #expect(PatchMath.nextFreeAddress(channelCount: 3, fixtures: patch) == 7)
    }

    @Test func fullUniverseReturnsNil() {
        let patch = [fixture(1, at: 1, count: 510)]
        #expect(PatchMath.nextFreeAddress(channelCount: 2, fixtures: patch) == 511)
        #expect(PatchMath.nextFreeAddress(channelCount: 3, fixtures: patch) == nil)
        #expect(PatchMath.nextFreeAddress(channelCount: 1, fixtures: [fixture(1, at: 1, count: 512)]) == nil)
    }

    @Test func endsExactlyAtLastChannel() {
        let patch = [fixture(1, at: 1, count: 509)]
        #expect(PatchMath.nextFreeAddress(channelCount: 3, fixtures: patch) == 510)
    }

    @Test func excludingAFixtureFreesItsChannels() {
        let patch = [fixture(1, at: 1, count: 3), fixture(2, at: 4, count: 3)]
        #expect(PatchMath.nextFreeAddress(channelCount: 3, fixtures: patch, excluding: 1) == 1)
    }

    @Test func respectsUniverseSize() {
        #expect(PatchMath.nextFreeAddress(channelCount: 3, fixtures: [fixture(1, at: 1, count: 8)], universeSize: 10) == nil)
    }

    @Test func overlapMatchesFirmwareRule() {
        let patch = [fixture(1, at: 1, count: 3), fixture(2, at: 4, count: 3)]
        #expect(PatchMath.overlaps(address: 3, channelCount: 3, fixtures: patch))
        #expect(PatchMath.overlaps(address: 6, channelCount: 1, fixtures: patch))
        #expect(!PatchMath.overlaps(address: 7, channelCount: 3, fixtures: patch))
        #expect(!PatchMath.overlaps(address: 4, channelCount: 3, fixtures: patch, excluding: 2))
        #expect(!PatchMath.fits(address: 511, channelCount: 3))
        #expect(PatchMath.fits(address: 510, channelCount: 3))
        #expect(!PatchMath.fits(address: 0, channelCount: 1))
    }

    @Test func rgbDetectionIsByChannelName() {
        let rgbw = Fixture(id: 1, name: "A", type: "whatever", address: 1, channelCount: 4,
                           channels: ["White", "Blue", "Green", "Red"], values: [1, 2, 3, 4])
        let indices = rgbw.rgbChannelIndices
        #expect(indices?.red == 3)
        #expect(indices?.green == 2)
        #expect(indices?.blue == 1)
        #expect(rgbw.whiteChannelIndex == 0)
        #expect(fixture(2, at: 1, count: 1).rgbChannelIndices == nil)
    }
}
