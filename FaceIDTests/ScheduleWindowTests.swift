//
//  ScheduleWindowTests.swift
//  Face ID Tests
//
//  `ScheduleWindow` is pure date arithmetic with an easy-to-get-wrong boundary
//  rule (inclusive start, exclusive end) and a cross-midnight case that is the
//  whole reason the type exists. It gets tested directly.
//

import Foundation
import Testing
@testable import FaceID

@Suite("ScheduleWindow")
struct ScheduleWindowTests {

    @Test("An empty window never contains anything")
    func emptyWindowMatchesNothing() {
        let window = ScheduleWindow(isEnabled: true, startHour: 9, startMinute: 0, endHour: 9, endMinute: 0)
        #expect(window.isEmpty)
        #expect(!window.contains(hour: 9, minute: 0))
        #expect(!window.contains(hour: 3, minute: 0))
    }

    @Test("Start is inclusive, end is exclusive")
    func normalWindowBoundaries() {
        let window = ScheduleWindow(isEnabled: true, startHour: 9, startMinute: 0, endHour: 17, endMinute: 30)
        #expect(!window.isEmpty)
        #expect(window.contains(hour: 9, minute: 0))
        #expect(window.contains(hour: 12, minute: 0))
        #expect(window.contains(hour: 17, minute: 29))
        #expect(!window.contains(hour: 17, minute: 30))
        #expect(!window.contains(hour: 8, minute: 59))
    }

    @Test("A window crossing midnight spans both sides")
    func crossMidnightWindow() {
        let window = ScheduleWindow(isEnabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0)
        #expect(window.contains(hour: 22, minute: 0))
        #expect(window.contains(hour: 23, minute: 59))
        #expect(window.contains(hour: 0, minute: 0))
        #expect(window.contains(hour: 6, minute: 59))
        #expect(!window.contains(hour: 7, minute: 0))
        #expect(!window.contains(hour: 12, minute: 0))
    }

    @Test("Codable round-trips")
    func codableRoundTrip() throws {
        let window = ScheduleWindow(isEnabled: true, startHour: 1, startMinute: 2, endHour: 3, endMinute: 4)
        let data = try JSONEncoder().encode(window)
        let decoded = try JSONDecoder().decode(ScheduleWindow.self, from: data)
        #expect(decoded == window)
    }
}
