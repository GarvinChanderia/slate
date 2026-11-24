import Foundation

/// Decides which image the widget shows at which time.
///
/// Time is divided into fixed slots aligned to local midnight (so "hourly" changes on the hour
/// and "daily" at midnight). Each slot has an absolute number, and the image for a slot is a pure
/// function of that number. That means a timeline rebuilt mid-way (after an import, or when
/// WidgetKit asks again) continues the same rotation instead of starting over.
nonisolated struct RotationSchedule: Sendable {
    enum Order: Sendable {
        case shuffle
        case newestFirst
    }

    /// Slot length in seconds; values of a day or more mean one slot per calendar day.
    let interval: TimeInterval
    let order: Order
    /// Item IDs, newest first.
    let itemIDs: [UUID]
    /// Varies the shuffle between widgets of different sizes so they don't all show the same image.
    var shuffleSalt: UInt64 = 0
    var calendar: Calendar = .current

    private static let day: TimeInterval = 24 * 60 * 60
    private var isDaily: Bool { interval >= Self.day }
    private var slotsPerDay: Int { isDaily ? 1 : max(1, Int(Self.day / interval)) }

    /// Entries starting now: the first is dated `now` (the current slot's image), the rest at
    /// each following slot boundary.
    func entries(startingAt now: Date, count: Int) -> [(date: Date, itemID: UUID)] {
        guard !itemIDs.isEmpty, count > 0 else { return [] }
        var result: [(date: Date, itemID: UUID)] = []
        var slot = slotStart(containing: now)
        for index in 0..<count {
            result.append((index == 0 ? now : slot, itemID(forSlot: slotNumber(of: slot))))
            slot = nextSlotStart(after: slot)
        }
        return result
    }

    func slotStart(containing date: Date) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        guard !isDaily else { return dayStart }
        let index = min(Int(date.timeIntervalSince(dayStart) / interval), slotsPerDay - 1)
        return dayStart.addingTimeInterval(Double(index) * interval)
    }

    func nextSlotStart(after slotStart: Date) -> Date {
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: slotStart)) ?? slotStart.addingTimeInterval(Self.day)
        guard !isDaily else { return nextDay }
        // Clamp so a DST day's extra/missing hour never shifts the alignment of the next day.
        return min(slotStart.addingTimeInterval(interval), nextDay)
    }

    /// Absolute, monotonically increasing slot number.
    func slotNumber(of slotStart: Date) -> Int {
        let epoch = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        let dayStart = calendar.startOfDay(for: slotStart)
        let days = calendar.dateComponents([.day], from: epoch, to: dayStart).day ?? 0
        let indexInDay = isDaily ? 0 : min(Int(slotStart.timeIntervalSince(dayStart) / interval), slotsPerDay - 1)
        return days * slotsPerDay + indexInDay
    }

    func itemID(forSlot slot: Int) -> UUID {
        let count = itemIDs.count
        let cycle = slot.quotient(dividingBy: count)
        let position = slot - cycle * count
        switch order {
        case .newestFirst:
            return itemIDs[position]
        case .shuffle:
            return permutation(forCycle: cycle)[position]
        }
    }

    /// A deterministic shuffle per cycle, so every image appears once per cycle.
    private func permutation(forCycle cycle: Int) -> [UUID] {
        var generator = SplitMix64(seed: (UInt64(bitPattern: Int64(cycle)) &* 0x9E37_79B9_7F4A_7C15) ^ shuffleSalt)
        return itemIDs.shuffled(using: &generator)
    }

    /// Stable (unlike `Hasher`, which is seeded per process) string hash for `shuffleSalt`.
    static func stableHash(_ string: String) -> UInt64 {
        string.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }
}

/// Small deterministic RNG (SplitMix64), used so shuffles are reproducible across timeline reloads.
nonisolated struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

nonisolated private extension Int {
    /// Floor division (rounds toward negative infinity, unlike `/`).
    func quotient(dividingBy divisor: Int) -> Int {
        let quotient = self / divisor
        return (self % divisor < 0) ? quotient - 1 : quotient
    }
}
