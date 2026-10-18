//
//  WindowShieldGeometryTests.swift
//  Face ID Tests
//
//  The window shield stands or falls on two pieces of pure geometry: converting
//  Accessibility rectangles into Cocoa ones, and deciding when a window is "full
//  screen" and therefore uncoverable. Both are easy to get subtly wrong and
//  impossible to notice by eye — a one-axis flip error still *looks* plausible —
//  so they are pinned here.
//

import AppKit
import ApplicationServices
import Testing
@testable import FaceID

@Suite("WindowShield geometry")
struct WindowShieldGeometryTests {

    private let primaryHeight: CGFloat = 1080

    // MARK: - AX → Cocoa conversion

    @Test("A full-primary-display AX rect maps to the same Cocoa rect")
    func wholePrimaryDisplayRoundTrips() {
        let ax = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let cocoa = WindowTracker.cocoaRect(fromAX: ax, primaryDisplayHeight: primaryHeight)
        #expect(cocoa == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test("The y axis is flipped about the primary display's height")
    func yAxisIsFlipped() {
        // AX y measures down from the top: y=0 is the very top of the screen.
        let ax = CGRect(x: 100, y: 0, width: 400, height: 300)
        let cocoa = WindowTracker.cocoaRect(fromAX: ax, primaryDisplayHeight: primaryHeight)

        // Cocoa y measures up from the bottom, so a window hugging the top has its
        // origin near the top of the range, not at 0.
        #expect(cocoa.origin.x == 100)
        #expect(cocoa.origin.y == 780)   // 1080 − (0 + 300)
        #expect(cocoa.size == CGSize(width: 400, height: 300))
        // Top edge of the Cocoa rect corresponds to AX y = 0.
        #expect(cocoa.maxY == primaryHeight)
    }

    @Test("A window in the lower half lands in the lower half")
    func lowerHalfStaysLower() {
        let ax = CGRect(x: 0, y: 700, width: 800, height: 380)
        let cocoa = WindowTracker.cocoaRect(fromAX: ax, primaryDisplayHeight: primaryHeight)
        #expect(cocoa.origin.y == 0)
        #expect(cocoa.maxY == 380)
    }

    @Test("A display positioned above the primary maps to negative-to-zero Cocoa range")
    func displayAbovePrimary() {
        // AX y is negative above the primary display; Cocoa y exceeds the primary
        // height there. Getting this wrong would park shields on the wrong screen.
        let ax = CGRect(x: 0, y: -200, width: 1920, height: 200)
        let cocoa = WindowTracker.cocoaRect(fromAX: ax, primaryDisplayHeight: primaryHeight)
        #expect(cocoa.origin.y == primaryHeight)
        #expect(cocoa.maxY == primaryHeight + 200)
    }

    @Test("Width and height are never swapped or scaled")
    func sizeIsPreserved() {
        let ax = CGRect(x: -1400, y: 42, width: 1400, height: 900)
        let cocoa = WindowTracker.cocoaRect(fromAX: ax, primaryDisplayHeight: primaryHeight)
        #expect(cocoa.size == ax.size)
        #expect(cocoa.origin.x == ax.origin.x)
    }

    // MARK: - Full-screen detection

    private let builtIn = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test("A window filling a display exactly counts as full screen")
    func exactFillIsFullScreen() {
        #expect(WindowTracker.coversWholeScreen(builtIn, screens: [builtIn]))
    }

    @Test("A window comfortably smaller than the display is not full screen")
    func smallerWindowIsNotFullScreen() {
        let window = CGRect(x: 100, y: 100, width: 1500, height: 800)
        #expect(!WindowTracker.coversWholeScreen(window, screens: [builtIn]))
    }

    @Test("Width and height must BOTH reach the threshold")
    func oneAxisIsNotEnough() {
        let tallButNarrow = CGRect(x: 0, y: 0, width: 1920, height: 900)
        let wideButShort = CGRect(x: 0, y: 0, width: 1500, height: 1080)
        #expect(!WindowTracker.coversWholeScreen(tallButNarrow, screens: [builtIn]))
        #expect(!WindowTracker.coversWholeScreen(wideButShort, screens: [builtIn]))
    }

    @Test("Covering any one of several displays is enough")
    func anyDisplayCounts() {
        let external = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        #expect(WindowTracker.coversWholeScreen(external, screens: [builtIn, external]))
        // …but a window spanning the seam between them is not "full screen" on either.
        let spanning = CGRect(x: 0, y: 0, width: 4480, height: 1000)
        #expect(!WindowTracker.coversWholeScreen(spanning, screens: [builtIn, external]))
    }

    @Test("Degenerate inputs never report full screen")
    func degenerateInputs() {
        #expect(!WindowTracker.coversWholeScreen(CGRect(x: 0, y: 0, width: 0, height: 0), screens: [builtIn]))
        #expect(!WindowTracker.coversWholeScreen(builtIn, screens: []))
        #expect(!WindowTracker.coversWholeScreen(builtIn, screens: [CGRect(x: 0, y: 0, width: 0, height: 0)]))
    }

    // MARK: - Window filtering

    @Test("Only standard windows are shielded")
    func onlyStandardSubrole() {
        #expect(WindowTracker.isStandardWindow(subrole: kAXStandardWindowSubrole))
        #expect(!WindowTracker.isStandardWindow(subrole: "AXDialog"))
        #expect(!WindowTracker.isStandardWindow(subrole: "AXSystemDialog"))
        #expect(!WindowTracker.isStandardWindow(subrole: "AXFloatingWindow"))
        #expect(!WindowTracker.isStandardWindow(subrole: nil))
    }

    @Test("The standard-window subrole is what we think it is")
    func standardSubroleValue() {
        // Pins the constant this whole filter hangs on, so a platform change shows
        // up as a failing test rather than as shields quietly never appearing.
        #expect(kAXStandardWindowSubrole == "AXStandardWindow")
    }
}
