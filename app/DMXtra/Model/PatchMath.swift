import Foundation

/// Pure helpers for reasoning about the patch (which channels each fixture uses).
enum PatchMath {
    static let defaultUniverseSize = 512

    /// The lowest start address where a fixture with `channelCount` channels
    /// fits without overlapping any fixture in `fixtures`, or nil if there is
    /// no gap big enough. `excluding` ignores one fixture (used when moving it).
    static func nextFreeAddress(
        channelCount: Int,
        fixtures: [Fixture],
        excluding excludedID: Fixture.ID? = nil,
        universeSize: Int = defaultUniverseSize
    ) -> Int? {
        let count = max(channelCount, 1)
        let ranges = fixtures
            .filter { $0.id != excludedID }
            .map(\.channelRange)
            .sorted { $0.lowerBound < $1.lowerBound }

        var candidate = 1
        for range in ranges {
            if candidate + count - 1 < range.lowerBound { return candidate }
            candidate = max(candidate, range.upperBound + 1)
        }
        return candidate + count - 1 <= universeSize ? candidate : nil
    }

    /// True if `count` channels starting at `address` collide with any fixture
    /// other than `excluding`. Same rule as the firmware's `overlaps()`.
    static func overlaps(
        address: Int,
        channelCount count: Int,
        fixtures: [Fixture],
        excluding excludedID: Fixture.ID? = nil
    ) -> Bool {
        let end = address + count  // exclusive
        return fixtures.contains { f in
            f.id != excludedID && address < f.address + f.channelCount && f.address < end
        }
    }

    /// True if the fixture stays inside channels 1...universeSize.
    static func fits(address: Int, channelCount: Int, universeSize: Int = defaultUniverseSize) -> Bool {
        address >= 1 && address + channelCount - 1 <= universeSize
    }

    /// Maps each DMX channel (1-based) to the fixture that owns it.
    static func ownerMap(_ fixtures: [Fixture]) -> [Int: Fixture] {
        var map: [Int: Fixture] = [:]
        for f in fixtures {
            for ch in f.channelRange { map[ch] = f }
        }
        return map
    }

    /// "1–3", or "7" for a one-channel fixture.
    static func rangeLabel(_ range: ClosedRange<Int>) -> String {
        range.lowerBound == range.upperBound
            ? "\(range.lowerBound)"
            : "\(range.lowerBound)–\(range.upperBound)"
    }
}

extension Fixture {
    /// Indices of the red, green, and blue channels, if the fixture has all three.
    var rgbChannelIndices: (red: Int, green: Int, blue: Int)? {
        func index(_ name: String) -> Int? {
            channels.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        guard let r = index("red"), let g = index("green"), let b = index("blue") else { return nil }
        return (r, g, b)
    }

    var isColorFixture: Bool { rgbChannelIndices != nil }

    /// Index of a "white" channel, used to tint the swatch of RGBW-style fixtures.
    var whiteChannelIndex: Int? {
        channels.firstIndex { $0.caseInsensitiveCompare("white") == .orderedSame }
    }

    var addressLabel: String { PatchMath.rangeLabel(channelRange) }

    /// "Channel 7" or "Channels 1–3".
    var channelsDescription: String {
        channelRange.count == 1 ? "Channel \(address)" : "Channels \(addressLabel)"
    }
}
