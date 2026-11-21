import Foundation
import Testing
@testable import AlbumistCore

/// The hang watch of the UI runs (owner's decision 16.11.2026, "Hänger-Wächter 250 ms"): which
/// hangs are Albumist's own, and what their log line shows. Frames as `MainThreadWatch.symbol`
/// writes them on the simulator.
@Suite("Hang kinds")
struct HangKindTests {
    let ours = "Albumist.debug.dylib closure #1 in OverviewView.body.getter + 312"
    let swiftUI = "SwiftUICore AG::Graph::UpdateStack::update() + 520"
    let snapshot = "XCTAutomationSupport -[XCTElementSnapshotRequest loadSnapshot:] + 88"
    let axRuntime = "UIAccessibility -[UIView(AXPrivate) _accessibilityUserTestingChildren] + 64"
    let kernel = "libsystem_kernel.dylib mach_msg2_trap + 8"

    @Test func ourCodeOnTheStackIsAnAppHang() {
        #expect(HangKind(frames: [swiftUI, ours, swiftUI], inactive: false, beforeFirstActive: false) == .app)
        #expect(HangKind(frames: ["Albumist AppModel.refresh() + 4"], inactive: false, beforeFirstActive: false) == .app)
    }

    @Test func xcTestReadingTheScreenIsNeverTheApps() {
        // XCTest's snapshot asked SwiftUI for the tree, which ran our body: still the test's.
        #expect(HangKind(frames: [ours, swiftUI, axRuntime, snapshot], inactive: false, beforeFirstActive: false) == .test)
        #expect(HangKind(frames: [kernel, "libXCTestBundleInject.dylib x + 1"], inactive: false, beforeFirstActive: false) == .test)
    }

    @Test func startAndBackgroundComeFirst() {
        #expect(HangKind(frames: [ours], inactive: false, beforeFirstActive: true) == .start)
        #expect(HangKind(frames: [ours], inactive: true, beforeFirstActive: false) == .inactive)
        #expect(HangKind(frames: [ours, snapshot], inactive: true, beforeFirstActive: true) == .start)
    }

    @Test func onlySystemFramesAreTheSystems() {
        #expect(HangKind(frames: [kernel, swiftUI], inactive: false, beforeFirstActive: false) == .system)
        // An image whose name only starts like ours is not ours.
        #expect(HangKind(frames: ["AlbumistWidgets x + 1"], inactive: false, beforeFirstActive: false) == .system)
    }

    @Test func theEntryPointAtTheBottomOfEveryStackIsNotOurs() {
        // Second review 21.11.: every main-thread stack ends in our `main`; without this every
        // hang of iOS alone counted as ours, all under one place.
        let bottom = ["Albumist.debug.dylib static AlbumistApp.$main() + 40", "Albumist.debug.dylib __debug_main_executable_dylib_entry_point + 12",
                      "Albumist main + 8", "dyld start + 2840"]
        #expect(HangKind(frames: [kernel, swiftUI] + bottom, inactive: false, beforeFirstActive: false) == .system)
        #expect(HangKind(frames: ["Albumist.debug.dylib MainThreadWatch.section<A>(_:_:) + 9"] + bottom,
                         inactive: false, beforeFirstActive: false) == .system)
        #expect(HangKind(frames: [ours] + bottom, inactive: false, beforeFirstActive: false) == .app)
        #expect(HangKind.shortStack([kernel] + bottom) == "libsystem_kernel.dylib mach_msg2_trap | Albumist.debug.dylib static AlbumistApp.$main() | Albumist.debug.dylib __debug_main_executable_dylib_entry_point | Albumist main")
        // An app frame without a symbol is still ours.
        #expect(HangKind(frames: ["Albumist.debug.dylib +0x1f2c"] + bottom, inactive: false, beforeFirstActive: false) == .app)
    }

    @Test func ourCodeCallingTheAccessibilityRuntimeStaysOurs() {
        // Our code (caller, higher index) posts to the accessibility runtime (callee, lower index).
        #expect(HangKind(frames: [axRuntime, ours, swiftUI], inactive: false, beforeFirstActive: false) == .app)
        // XCTest's snapshot (caller) ran our body (callee): the test's.
        #expect(HangKind(frames: [ours, axRuntime, snapshot], inactive: false, beforeFirstActive: false) == .test)
    }

    @Test func aStarvedProcessOrAMissingStackSaysNothingAboutUs() {
        #expect(HangKind(frames: [ours], inactive: false, beforeFirstActive: false, starved: true) == .starved)
        #expect(HangKind(frames: [], inactive: false, beforeFirstActive: false) == .unknown)
        #expect(HangKind(frames: [ours], inactive: true, beforeFirstActive: false, starved: true) == .inactive)
    }

    @Test func theShortStackShowsOurFramesAndWhatTheyWaitedIn() {
        let line = HangKind.shortStack([kernel, swiftUI, ours, swiftUI, "Albumist.debug.dylib AppModel.tick() + 7"])
        #expect(line == "SwiftUICore AG::Graph::UpdateStack::update() | Albumist.debug.dylib closure #1 in OverviewView.body.getter | Albumist.debug.dylib AppModel.tick()")
    }

    @Test func theShortStackIsTheSameInEveryRun() {
        // Offsets dropped: the same place groups together in hang_report.
        #expect(HangKind.shortStack([ours]) == HangKind.shortStack([ours.replacingOccurrences(of: "312", with: "16")]))
        #expect(HangKind.shortStack([kernel, swiftUI]) == "libsystem_kernel.dylib mach_msg2_trap | SwiftUICore AG::Graph::UpdateStack::update()")
        #expect(HangKind.shortStack(["?? 0x1234"]) == "?? 0x1234")
    }

    @Test func atMostSixOfOurFrames() {
        let deep = (0..<10).map { "Albumist.debug.dylib f\($0)() + 1" }
        #expect(HangKind.shortStack(deep).split(separator: "|").count == 6)
    }
}
