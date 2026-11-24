import Foundation
import Testing

struct RotationScheduleTests {
    let ids = (0..<5).map { _ in UUID() }
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.date(from: string)!
    }

    @Test func hourlySlotsAlignToTheHour() {
        let schedule = RotationSchedule(interval: 3600, order: .newestFirst, itemIDs: ids, calendar: calendar)
        let entries = schedule.entries(startingAt: date("2026-03-10T09:41:00"), count: 3)

        #expect(entries.map(\.date) == [date("2026-03-10T09:41:00"), date("2026-03-10T10:00:00"), date("2026-03-10T11:00:00")])
    }

    @Test func dailySlotsChangeAtMidnight() {
        let schedule = RotationSchedule(interval: 86_400, order: .newestFirst, itemIDs: ids, calendar: calendar)
        let entries = schedule.entries(startingAt: date("2026-03-10T15:00:00"), count: 3)

        #expect(entries.map(\.date).dropFirst() == [date("2026-03-11T00:00:00"), date("2026-03-12T00:00:00")])
    }

    @Test func newestFirstCyclesThroughEveryItemInOrder() throws {
        let schedule = RotationSchedule(interval: 900, order: .newestFirst, itemIDs: ids, calendar: calendar)
        let entries = schedule.entries(startingAt: date("2026-03-10T00:00:00"), count: 10)

        let first = try #require(ids.firstIndex(of: entries[0].itemID))
        for (offset, entry) in entries.enumerated() {
            #expect(entry.itemID == ids[(first + offset) % ids.count])
        }
    }

    @Test func shuffleShowsEveryItemOncePerCycle() {
        let schedule = RotationSchedule(interval: 1800, order: .shuffle, itemIDs: ids, calendar: calendar)
        // Slot numbers are absolute, so start at a cycle boundary to check one full cycle.
        let firstSlot = schedule.slotNumber(of: schedule.slotStart(containing: date("2026-03-10T00:00:00")))
        let cycleStart = (firstSlot / ids.count + 1) * ids.count
        let cycle = (cycleStart..<cycleStart + ids.count).map(schedule.itemID(forSlot:))

        #expect(Set(cycle) == Set(ids))
    }

    @Test func rebuildingMidwayContinuesTheSameRotation() {
        let schedule = RotationSchedule(interval: 3600, order: .shuffle, itemIDs: ids, calendar: calendar)
        let original = schedule.entries(startingAt: date("2026-03-10T08:10:00"), count: 12)
        let rebuilt = schedule.entries(startingAt: date("2026-03-10T11:25:00"), count: 6)

        #expect(rebuilt.map(\.itemID) == Array(original[3..<9]).map(\.itemID))
    }

    @Test func daylightSavingDayKeepsHourAlignment() {
        // Clocks go forward at 01:00 on 29 March 2026 in London (a 23-hour day).
        let schedule = RotationSchedule(interval: 3 * 3600, order: .newestFirst, itemIDs: ids, calendar: calendar)
        let entries = schedule.entries(startingAt: date("2026-03-29T22:00:00"), count: 3)

        #expect(entries[1].date == date("2026-03-30T00:00:00"))
        #expect(entries[2].date == date("2026-03-30T03:00:00"))
    }

    @Test func emptyLibraryProducesNoEntries() {
        let schedule = RotationSchedule(interval: 900, order: .shuffle, itemIDs: [], calendar: calendar)
        #expect(schedule.entries(startingAt: .now, count: 10).isEmpty)
    }
}
