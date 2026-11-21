import Darwin
import Foundation
import os
import AlbumistCore
import UIKit

/// Debug builds started by the UI tests (`-AlbumistUITestUnlocked`): no purchase sheet and no
/// system rating prompt, which would cover the screen the test is about to tap.
/// Always false in release builds.
enum UITestSupport {
    static let isRunning: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-AlbumistUITestUnlocked")
        #else
        false
        #endif
    }()

    /// `-AlbumistUITestDark`: dark mode for the large-text screenshots (the simulator's own
    /// appearance switch does not reach the app reliably on the CI machines).
    static let forcesDarkMode: Bool = isRunning && ProcessInfo.processInfo.arguments.contains("-AlbumistUITestDark")

    /// The copy of the decisions for the device backup is written and restored as in the
    /// shipped app. UI runs leave it alone unless `-AlbumistUITestBackup` asks for it, so one
    /// run does not bring decisions into the next.
    static let allowsSafetyBackup: Bool = !isRunning || ProcessInfo.processInfo.arguments.contains("-AlbumistUITestBackup")

    /// `-AlbumistUITestRebuildDatabase`: the database is set aside at launch, exactly like
    /// "Neu aufbauen" after a start error, to test that the decisions come back.
    static let rebuildsDatabase: Bool = isRunning && ProcessInfo.processInfo.arguments.contains("-AlbumistUITestRebuildDatabase")

    /// UI runs only, first thing at launch: the app's stderr and stdout go into a file in its
    /// tmp folder instead of the pipe the test runner gave it. In a UI run every os_log line
    /// is also written to stderr, XCTest's own snapshot code on the main thread logs too, and
    /// that pipe was emptied only slowly (presumably by the runner, which waits for that very
    /// snapshot meanwhile): the main thread stood in `writev` (stacks of UI run 44032718289:
    /// `XCElementSnapshot elementType` > `_os_log_impl_mirror_to_stderr` > `writev`) until the
    /// query timed out, the "Failed to get matching snapshots" of the UI tests. A file never
    /// makes a writer wait. The system log (`log stream`, where the workflow reads the app's
    /// lines) is not affected. A phone without a debugger never mirrors the log, so this
    /// never happens to a user.
    ///
    /// Every launch of a pass appends to the same file, after a line `=== Albumist launch <pid>`:
    /// the Main Thread Checker writes its reports to stderr only, and `ui_tests.py`
    /// (`main_thread_checker_report`) reads the file once after each pass.
    static func moveConsoleToFile() {
        guard isRunning else { return }
        let path = NSTemporaryDirectory() + consoleFileName
        let file = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard file >= 0 else { return }
        dup2(file, STDERR_FILENO)
        dup2(file, STDOUT_FILENO)
        close(file)
        FileHandle.standardError.write(Data("=== Albumist launch \(getpid())\n".utf8))
        MainThreadCheckerProbe.launched()
    }

    /// In the app's tmp folder (`ui_tests.py` CONSOLE_FILE).
    static let consoleFileName = "albumist-console.log"

    /// `-AlbumistUITestSlowAnalysis`: every photo takes a little longer, so a UI test can leave
    /// the app and switch tabs while the analysis is still busy (first device test 15.11.).
    static let slowsAnalysis: Bool = isRunning && ProcessInfo.processInfo.arguments.contains("-AlbumistUITestSlowAnalysis")
}

// MARK: Locked purchase (free-album limit and unlock card)

extension UITestSupport {
    /// `-AlbumistUITestLocked`: the purchase is not skipped; free albums count as in the shipped
    /// app and the unlock card appears, so the locked path is tested end to end.
    static let locksPurchase: Bool = isRunning && ProcessInfo.processInfo.arguments.contains("-AlbumistUITestLocked")

    /// `-AlbumistUITestFreeAlbumsLeft N` (with `-AlbumistUITestLocked`): the run starts with N free
    /// albums left.
    static let freeAlbumsLeft: Int? = {
        guard locksPurchase else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-AlbumistUITestFreeAlbumsLeft"), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }()

    private static let lockedPurchaseSuite = "app.albumist.uitest.purchases"

    /// The free-album count of a locked UI run: its own domain, emptied at every launch, so
    /// the count of one run never reaches the next one or the normal runs.
    static func lockedPurchaseDefaults() -> UserDefaults? {
        guard locksPurchase, let defaults = UserDefaults(suiteName: lockedPurchaseSuite) else { return nil }
        defaults.removePersistentDomain(forName: lockedPurchaseSuite)
        return defaults
    }
}

/// The real analyzer with a pause per photo (UI tests only, see `slowsAnalysis`).
struct SlowedAnalyzer: ContentAnalyzing {
    var base: any ContentAnalyzing

    func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
        try await Task.sleep(for: .milliseconds(150))
        return try await base.analyzeContent(asset, request: request)
    }

    func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
        try await base.recognizeText(asset, allowNetwork: allowNetwork)
    }

    /// Handed on: without the preview prefetch every photo of a slowed run came back
    /// unreadable (UI run 43753915509, "246 Fotos konnten noch nicht gelesen werden").
    func willAnalyze(_ upcoming: [AssetSnapshot]) async {
        await base.willAnalyze(upcoming)
    }
}

// MARK: Progress line record

/// UI runs only (`-AlbumistUITestProgressLog <path>`): the analysis card's progress line as
/// XCTest reads it (label and value of `analysis.progress`) each time it changes, as
/// "<seconds since 1970> <line>" in that file of the test runner's, and "<seconds> -" when
/// the card stops showing the line (the analysis ended, another tab). A launch appends
/// "@ <pid> <seconds since 1970>" first, so the lines of a relaunch follow the ones before;
/// `mark` adds "# <seconds since 1970> <what>" for a moment the line itself does not show.
/// The stress test (DeviceConditionUITests test12) takes the longest still time from these
/// times: its own reads of the card took 5–7 s each during the analysis (stress run
/// 44116350940), so a still time measured from them was off by up to that much.
@MainActor
enum ProgressLineLog {
    private static var file: FileHandle?
    private static var last: String?

    /// Whether lines are written (the card asks before it builds the line).
    static var isOn: Bool { file != nil }

    static func start(path: String) {
        guard UITestSupport.isRunning, file == nil else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        _ = try? handle.seekToEnd()
        file = handle
        write(String(format: "@ %d %.3f", getpid(), Date().timeIntervalSince1970))
    }

    static func note(_ line: String) {
        guard file != nil, line != last else { return }
        last = line
        write(String(format: "%.3f ", Date().timeIntervalSince1970) + line.replacingOccurrences(of: "\n", with: " "))
    }

    static func mark(_ what: String) {
        guard file != nil else { return }
        write(String(format: "# %.3f ", Date().timeIntervalSince1970) + what)
    }

    private static func write(_ text: String) {
        try? file?.write(contentsOf: Data((text + "\n").utf8))
    }
}

// MARK: Main-thread watch

/// UI runs only (`-AlbumistUITestUnlocked`): writes a fault to the system log when the main
/// thread did not answer, and when the whole process got no time (the watch's own 0.2 s sleep
/// took seconds). The UI workflow prints the app's fault lines (`UI_RUNTIME_WARNING`, the 40
/// most frequent distinct lines), so a run whose UI queries time out ("Failed to get matching
/// snapshots: Timed out while evaluating UI query", runs 43893790053 and 43918684247) says
/// whether Albumist blocked its main thread or the simulator stood still.
///
/// Lines (kept few, so the 40 printed lines hold them):
/// - `UI_MAIN_STALL 12.3 s from 18:31:05.2 UTC in <section>`: every stall of 2 s or more, with
///   its start (the test prints `UI_FACT clock` lines on the same clock) and the marked section the
///   main thread was in while it did not answer (`unmarked`: SwiftUI, UIKit or XCTest's own
///   work, such as an accessibility audit, which runs on the app's main thread)
/// - `UI_MAIN_STALL 1-2 s in <section>`: shorter stalls, counted per section
/// - `UI_MAIN_SLOW <section> 250 ms to 1 s` / `UI_MAIN_SLOW <section> 3.4 s`: a marked section
///   that took that long (`section(_:_:)`), shorter ones counted per section
/// - `UI_MAIN_STALL the main thread has not answered for 10.0 s ...`: a hang, again at 20, 40,
///   80 s ..., with the section it hangs in and how long that section has been running
/// - `UI_MAIN_HANG 312 ms <kind> in [<sections>]: <frames>`: every hang of 250 ms or more (Apple's own
///   limit for a hang, owner's decision 16.11.2026: "Hänger-Wächter 250 ms"), with the main
///   thread's stack taken 200 ms into it. `<kind>` (`HangKind`): `app` (Albumist's own code on
///   the stack), `test` (XCTest reading the screen, which runs on the app's main thread),
///   `start` (before the app was first active), `inactive` (in the background or behind a
///   system alert), `system` (iOS alone, no frame of Albumist). `ui_tests.py` (`hang_report`)
///   collects them from the whole pass and applies `.github/hang-gate.json`.
/// Stall lines end in `(app not active)` when the app was in the background or behind a
/// system alert during the stall: the system may hold back a main thread then.
final class MainThreadWatch: @unchecked Sendable {
    static let shared = MainThreadWatch()
    private let logger = Logger(subsystem: "app.albumist.ios", category: "uitest")
    private let lock = NSLock()
    /// Uptime (ns) and wall clock (s since 1970) of the ping the main thread has not answered yet.
    private var askedAt: UInt64?
    private var askedWall: Double = 0
    /// The hang report of the current ping is written again once the wait reaches this (s).
    private var nextStuckReport: Double = 10
    private var started = false
    /// Marked sections the main thread is in now, outermost first, with their start (uptime
    /// ns); changed on the main thread.
    private var sections: [(name: String, began: UInt64)] = []
    /// The sections seen while the current ping was not answered.
    private var seenInStall: [String] = []
    /// The app is foreground-active (changed on the main thread by the app's notifications).
    private var active = true
    /// The app was not active at some point while the current ping waited.
    private var inactiveInStall = false
    /// `-AlbumistUITestWatchMain` (stress runs, `watchForStress`): `UITEST_MAIN_BLOCKED` lines,
    /// and every stall over half a second in the test runner's file.
    private var stressLines = false
    private var stressFile: FileHandle?
    private var longestStall: Double = 0
    /// Serializes the writes into `stressFile` (the main thread's stall lines, the watch
    /// thread's stack lines).
    private let fileLock = NSLock()
    /// Marked work done on the main thread since the current ping was sent: how often, and for
    /// how long (uptime ns; 0 for `count`). Written to the runner's file after a stall of 2 s
    /// or more, so a stall says whether one piece of work was slow or a view was drawn again
    /// and again (UI run 44038288087: 68 s in SwiftUI updates of the plan preview).
    private var workInPing: [String: (count: Int, nanoseconds: UInt64)] = [:]

    // Main-thread stacks: taken by the watch thread while a ping waits (at 2 s, then every
    // 5 s, at most `maxStacks`), so a long stall says where the main thread was, not only how long.
    /// The main thread's port and stack bounds, set in `start()` before the watch thread runs.
    private var mainPort: mach_port_t = 0
    private var stackLow: UInt = 0
    private var stackHigh: UInt = 0
    private static let maxFrames = 64
    private static let maxStacks = 14
    /// Watch thread only: stacks taken for the current ping.
    private var stacksInPing = 0
    /// Filled while the main thread is suspended: nothing may be allocated then (the main thread
    /// may hold the allocator's lock), so the buffer is made once.
    private let frameBuffer = UnsafeMutablePointer<UInt>.allocate(capacity: MainThreadWatch.maxFrames)
    /// Watch thread only: when the current ping's next stack is taken (seconds waited).
    private var nextStackAt: Double = 2
    /// The main thread's return addresses 150 ms into the current ping's wait, for the
    /// `UI_MAIN_HANG` line; stored by the watch thread under `lock` right after they are taken
    /// (symbolized only in `answered`, so a hang that ends just after keeps its stack).
    private var hangStack: [UInt]?
    /// The marked sections seen from 150 ms into the current ping (the hang line's, at most 4;
    /// `seenInStall` keeps its 0.5 s for the stall lines as before).
    private var hangSections: [String] = []
    /// How long the watch's own sleep overran while the current ping waited (s): the whole
    /// process got no time then (a busy Mac). Over half the wait, the stack says nothing about
    /// who blocked the main thread (`HangKind.starved`).
    private var starvedInPing: Double = 0
    /// The app has been foreground-active at least once (a hang before is part of the start).
    private var wasActive = false
    /// The watch's tick: a hang of 250 ms is seen within 50 ms (it was 0.2 s before
    /// the 250-ms watch; a ping costs one main-queue block).
    static let tick = 0.05
    /// A stall of this length or more is a hang (Apple's limit, as in Xcode's hang reports).
    /// A ping goes out up to one tick after the main thread last answered, so a wait is measured
    /// up to 50 ms short: every wait from `hangLimit - tick` on is written (`ui_tests.py` counts
    /// from there too, MAIN_HANG_SLACK_MS), and the stack is taken a tick before that.
    static let hangLimit = 0.25

    @MainActor
    func start() {
        guard UITestSupport.isRunning else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [self] _ in setActive(true) }
        _ = center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [self] _ in setActive(false) }
        mainPort = mach_thread_self()
        let main = pthread_self()
        stackHigh = UInt(bitPattern: pthread_get_stackaddr_np(main))
        stackLow = stackHigh - UInt(pthread_get_stacksize_np(main))
        let thread = Thread { [self] in watch() }
        thread.name = "Albumist main-thread watch"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// `-AlbumistUITestWatchMain` (DeviceConditionUITests test12, ui-stress.yml): besides the lines
    /// above, `UITEST_MAIN_BLOCKED <ms> ms (longest <ms> ms)` for every stall over a second, and
    /// with `-AlbumistUITestWatchMainLog <path>` every stall over half a second as
    /// "<end as seconds since 1970> <ms>" in that file of the test runner's.
    /// `lines: false` (only `-AlbumistUITestWatchMainLog`, every DeviceConditionUITests launch):
    /// the file without the `UITEST_MAIN_BLOCKED` lines.
    @MainActor
    func watchForStress(log path: String?, lines: Bool = true) {
        let file = path.flatMap { path -> FileHandle? in
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }
        // When this process was started and when its own code got here, as
        // "@ <pid> <start> <now>" (seconds since 1970): tells a launch that iOS began late
        // from one the app made slow, when XCTest loses the app at a launch ("does not have a
        // process ID", device test 04 of UI run 44066730498; `ui_tests.py`).
        if let file {
            let now = Date().timeIntervalSince1970
            let started = Self.processStart() ?? now
            file.write(Data(String(format: "@ %d %.1f %.1f\n", getpid(), started, now).utf8))
        }
        lock.lock()
        stressLines = lines
        stressFile = file
        lock.unlock()
        start()
    }

    /// When the kernel started this process (seconds since 1970).
    static func processStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }

    private func setActive(_ value: Bool) {
        lock.lock()
        active = value
        if value { wasActive = true }
        if !value { inactiveInStall = true }
        lock.unlock()
    }

    /// Marks main-thread work, so a stall line names it. Costs nothing outside UI runs.
    @discardableResult
    func section<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard UITestSupport.isRunning, Thread.isMainThread else { return try body() }
        let begin = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        sections.append((name, begin))
        lock.unlock()
        defer {
            let end = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            if !sections.isEmpty { sections.removeLast() }
            let before = workInPing[name] ?? (0, 0)
            workInPing[name] = (before.count + 1, before.nanoseconds + (end > begin ? end - begin : 0))
            lock.unlock()
            let took = Self.seconds(from: begin, to: end)
            if took >= 1 {
                note("UI_MAIN_SLOW \(name) \(Self.text(took)) s")
            } else if took >= 0.25 {
                note("UI_MAIN_SLOW \(name) 250 ms to 1 s")
            }
        }
        return try body()
    }

    /// Counts a piece of main-thread work that is too small to time, such as a view's body:
    /// a stall line then says how often it ran while the main thread did not answer.
    /// Costs nothing outside UI runs.
    func count(_ name: String) {
        guard UITestSupport.isRunning else { return }
        lock.lock()
        let before = workInPing[name] ?? (0, 0)
        workInPing[name] = (before.count + 1, before.nanoseconds)
        lock.unlock()
    }

    private func watch() {
        while true {
            let before = DispatchTime.now().uptimeNanoseconds
            Thread.sleep(forTimeInterval: Self.tick)
            let now = DispatchTime.now().uptimeNanoseconds
            let slept = Self.seconds(from: before, to: now)
            if slept >= 1.5 {
                note("UI_PROCESS_STALL the watch slept \(Self.text(slept)) s instead of \(Self.tick) s from \(Self.clock(Date().timeIntervalSince1970 - slept)) UTC (the whole process got no time)")
            }
            lock.lock()
            let pending = askedAt
            if pending == nil {
                askedAt = now
                askedWall = Date().timeIntervalSince1970
                seenInStall = []
                nextStuckReport = 10
                nextStackAt = 2
                stacksInPing = 0
                workInPing = [:]
                inactiveInStall = !active
                hangStack = nil
                hangSections = []
                starvedInPing = 0
            } else if slept >= Self.tick + 0.05 {
                starvedInPing += slept - Self.tick
            }
            let needsHangStack = pending != nil && hangStack == nil
            let waited = pending.map { Self.seconds(from: $0, to: now) } ?? 0
            let path = sections.isEmpty ? "unmarked" : sections.map { $0.name }.joined(separator: ">")
            if waited >= 0.5 {
                if !seenInStall.contains(path) && seenInStall.count < 4 { seenInStall.append(path) }
            }
            if waited >= Self.hangLimit - 2 * Self.tick {
                if !hangSections.contains(path) && hangSections.count < 4 { hangSections.append(path) }
            }
            let stuck = pending != nil && waited >= nextStuckReport
            if stuck { nextStuckReport *= 2 }
            let since = askedWall
            let names = seenInStall.joined(separator: ", ")
            let current = sections.last.map { "\($0.name) running for \(Self.text(Self.seconds(from: $0.began, to: now))) s" } ?? "no marked section"
            let inactive = inactiveInStall
            lock.unlock()
            if needsHangStack, waited >= Self.hangLimit - 2 * Self.tick, let stack = captureMainStack() {
                lock.lock()
                if askedAt == pending { hangStack = stack }
                lock.unlock()
            }
            if pending != nil, waited >= nextStackAt, stacksInPing < Self.maxStacks {
                nextStackAt = nextStackAt < 5 ? 5 : nextStackAt + 5
                stacksInPing += 1
                reportStack(waited: waited, since: since)
            }
            if stuck {
                note("UI_MAIN_STALL the main thread has not answered for \(Self.text(waited)) s, since \(Self.clock(since)) UTC, in \(names) (now \(current))\(Self.tag(inactive))")
            }
            if pending == nil {
                DispatchQueue.main.async { [self] in answered() }
            }
        }
    }

    /// Where a hang's stack is named and logged (see `answered`); serial, so the lines keep their order.
    private static let hangNaming = DispatchQueue(label: "app.albumist.uitest.hang-naming", qos: .utility)

    private func answered() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let asked = askedAt
        let since = askedWall
        let names = seenInStall.isEmpty ? "unmarked" : seenInStall.joined(separator: ", ")
        let inactive = inactiveInStall
        askedAt = nil
        let waited = asked.map { Self.seconds(from: $0, to: now) } ?? 0
        let stress = stressLines, file = stressFile
        if stress, waited > 1 { longestStall = max(longestStall, waited) }
        let longest = longestStall
        let work = workInPing
        let addresses = hangStack ?? []
        let hangNames = hangSections.isEmpty ? "unmarked" : hangSections.joined(separator: ", ")
        let starved = starvedInPing >= waited / 2
        let started = wasActive
        hangStack = nil
        lock.unlock()
        guard asked != nil else { return }
        if waited >= Self.hangLimit - Self.tick {
            // Named off the main thread: `dladdr` and demangling of up to 64 frames took up to half
            // a second here when the images' symbol tables were cold, and the watch reported its
            // own naming as a hang of the app (accessibility, UI run 44870948643).
            Self.hangNaming.async { [self] in
                let frames = addresses.enumerated().map { Self.symbol($0.element, isReturnAddress: $0.offset > 0) }
                let kind = HangKind(frames: frames, inactive: inactive, beforeFirstActive: !started, starved: starved)
                note("UI_MAIN_HANG \(Int(waited * 1000)) ms \(kind.rawValue) in [\(hangNames)]: \(HangKind.shortStack(frames))")
            }
        }
        // Written only here, on the main thread.
        if waited > 0.5, let file {
            var lines = String(format: "%.3f %ld\n", Date().timeIntervalSince1970, Int(waited * 1000))
            if waited >= 2, !work.isEmpty {
                let parts = work.sorted { ($0.value.nanoseconds, $0.value.count) > ($1.value.nanoseconds, $1.value.count) }.prefix(12).map { name, value in
                    value.nanoseconds > 0 ? "\(name) \(value.count)x \(Self.text(Double(value.nanoseconds) / 1e9)) s" : "\(name) \(value.count)x"
                }
                lines += "% in the stall of \(Self.text(waited)) s from \(Self.clock(since)) UTC: \(parts.joined(separator: ", "))\n"
            }
            fileLock.lock()
            file.write(Data(lines.utf8))
            fileLock.unlock()
        }
        if stress, waited > 1 {
            NSLog("UITEST_MAIN_BLOCKED %ld ms (longest %ld ms)", Int(waited * 1000), Int(longest * 1000))
        }
        if waited >= 2 {
            note("UI_MAIN_STALL \(Self.text(waited)) s from \(Self.clock(since)) UTC in \(names)\(Self.tag(inactive))")
        } else if waited >= 1 {
            note("UI_MAIN_STALL 1-2 s in \(names)\(Self.tag(inactive))")
        }
    }

    private static func tag(_ inactive: Bool) -> String { inactive ? " (app not active)" : "" }

    // MARK: Main-thread stacks

    /// `UI_MAIN_STACK after 5.0 s of the stall from 18:31:05.2 UTC: <frames>` in the log (the
    /// app's own frames only, so the line stays short), and the whole stack as a `#` line in
    /// the runner's file when there is one (`-AlbumistUITestWatchMainLog`; the device tests print
    /// it as `UI_FACT main stack`, which the job log never cuts off).
    private func reportStack(waited: Double, since: Double) {
        guard let stack = captureMainStack() else { return }
        let frames = stack.enumerated().map { Self.symbol($0.element, isReturnAddress: $0.offset > 0) }
        let head = "after \(Self.text(waited)) s of the stall from \(Self.clock(since)) UTC"
        let own = frames.filter { $0.hasPrefix("Albumist") }.prefix(8)
        // In the log from 5 s on only: it keeps 40 of the app's lines, and the stall lines
        // must not be pushed out by stacks.
        if waited >= 5 { note("UI_MAIN_STACK \(head): \(own.isEmpty ? frames.prefix(6).joined(separator: " | ") : own.joined(separator: " | "))") }
        lock.lock()
        let file = stressFile
        lock.unlock()
        guard let file else { return }
        fileLock.lock()
        file.write(Data("# \(head): \(frames.joined(separator: " | "))\n".utf8))
        fileLock.unlock()
    }

    /// The main thread's return addresses, read while it is suspended (frame records:
    /// [previous frame pointer, return address], each one higher on the stack).
    private func captureMainStack() -> [UInt]? {
        guard mainPort != 0, thread_suspend(mainPort) == KERN_SUCCESS else { return nil }
        var count = 0
        var fp: UInt = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainPort, thread_state_flavor_t(6) /* ARM_THREAD_STATE64 */, $0, &stateCount)
            }
        }
        if result == KERN_SUCCESS {
            frameBuffer[0] = Self.strip(UInt(state.__pc))
            // The leaf may not have stored its frame yet: the link register is its caller.
            frameBuffer[1] = Self.strip(UInt(state.__lr))
            count = 2
            fp = UInt(state.__fp)
        }
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainPort, thread_state_flavor_t(4) /* x86_THREAD_STATE64 */, $0, &stateCount)
            }
        }
        if result == KERN_SUCCESS {
            frameBuffer[0] = UInt(state.__rip)
            count = 1
            fp = UInt(state.__rbp)
        }
        #endif
        while count > 0, count < Self.maxFrames, fp >= stackLow, fp + 16 <= stackHigh, fp % 8 == 0 {
            guard let record = UnsafePointer<UInt>(bitPattern: fp) else { break }
            let next = record[0]
            let returnAddress = Self.strip(record[1])
            if returnAddress == 0 { break }
            frameBuffer[count] = returnAddress
            count += 1
            if next <= fp { break }
            fp = next
        }
        thread_resume(mainPort)
        return count > 0 ? Array(UnsafeBufferPointer(start: frameBuffer, count: count)) : nil
    }

    /// Pointer-authentication bits off a code address (none on the simulator; harmless).
    private static func strip(_ address: UInt) -> UInt { address & 0x0000_7FFF_FFFF_FFFF }

    /// "Albumist.debug.dylib AppModel.tick(run:) + 120", Swift names demangled.
    private static func symbol(_ address: UInt, isReturnAddress: Bool) -> String {
        // A return address points after the call; the call is one byte before.
        let lookup = isReturnAddress && address > 0 ? address - 1 : address
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: lookup), dladdr(pointer, &info) != 0 else {
            return String(format: "?? 0x%lx", address)
        }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "??"
        guard let name = info.dli_sname, let start = info.dli_saddr else {
            return "\(image) +0x\(String(address - UInt(bitPattern: info.dli_fbase), radix: 16))"
        }
        let symbol = demangle(String(cString: name))
        let short = symbol.count > 140 ? String(symbol.prefix(140)) + "…" : symbol
        return "\(image) \(short) + \(address - UInt(bitPattern: start))"
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                                                 UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    nonisolated(unsafe) private static let swiftDemangle: Demangle? = {
        guard let handle = dlopen(nil, RTLD_NOW), let found = dlsym(handle, "swift_demangle") else { return nil }
        return unsafeBitCast(found, to: Demangle.self)
    }()

    private static func demangle(_ name: String) -> String {
        guard name.hasPrefix("$s") || name.hasPrefix("_$s"), let swiftDemangle else { return name }
        return name.withCString { pointer in
            guard let result = swiftDemangle(pointer, strlen(pointer), nil, nil, 0) else { return name }
            defer { free(result) }
            return String(cString: result)
        }
    }

    /// A line of another part of the app for the same log (UI runs only).
    func report(_ text: String) {
        guard UITestSupport.isRunning else { return }
        note(text)
    }

    private func note(_ text: String) {
        logger.fault("\(text, privacy: .public)")
    }

    /// Never below zero: a time read before the lock can be older than a section the main
    /// thread began meanwhile (an unsigned `now - began` trapped and ended the app in UI run
    /// 43988095437).
    private static func seconds(from start: UInt64, to end: UInt64) -> Double {
        end > start ? Double(end - start) / 1_000_000_000 : 0
    }
    private static func text(_ seconds: Double) -> String { String(format: "%.1f", seconds) }

    /// Time of day in UTC with tenths ("18:31:05.2"), as the UI tests print it (`UI_FACT clock`).
    static func clock(_ since1970: Double) -> String {
        let day = since1970.truncatingRemainder(dividingBy: 86_400)
        let hours = Int(day / 3600), minutes = Int(day.truncatingRemainder(dividingBy: 3600) / 60)
        let rest = day.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%04.1f", hours, minutes, rest)
    }
}

// MARK: Main Thread Checker

/// UI runs only: whether Xcode's Main Thread Checker watches this launch (the tests insert it,
/// `UITestAppEnd.launch` with ALBUMIST_MTC_DYLIB from `ui_tests.py`; owner's decision
/// 16.11.2026), as the log line `UI_FACT main thread checker active` or `… not active`. With
/// ALBUMIST_MTC_PROBE=1 the app also calls one UIKit method from a background thread on
/// purpose, once per launch, so the run proves that a report reaches `ui_tests.py`; that
/// report is recognized by this type's name in its stack and never counts as a finding.
enum MainThreadCheckerProbe {
    static func launched() {
        let active = (0..<_dyld_image_count()).contains { index in
            _dyld_get_image_name(index).map { String(cString: $0).hasSuffix("/libMainThreadChecker.dylib") } ?? false
        }
        MainThreadWatch.shared.report("UI_FACT main thread checker \(active ? "active" : "not active")")
        guard active, ProcessInfo.processInfo.environment["ALBUMIST_MTC_PROBE"] == "1" else { return }
        // Once the app is up (second review 21.11.: not while UIKit starts), once per launch.
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                                   queue: .main) { _ in
            guard !fired else { return }
            fired = true
            // Made here on the main thread; only the layout call goes to the background thread.
            guard let type = NSClassFromString("UIView") as? NSObject.Type else { return }
            nonisolated(unsafe) let view = type.init()
            Thread.detachNewThread { fireFromBackground(view) }
        }
    }

    /// Main thread only (the observer above).
    nonisolated(unsafe) private static var fired = false

    /// The deliberate report: `-[UIView setNeedsLayout]` off the main thread, on a view nobody
    /// shows. Called through the Objective-C runtime, because Swift 6 rightly refuses a main-actor
    /// call from a background thread at compile time; the checker watches the method itself.
    @inline(never)
    static func fireFromBackground(_ view: NSObject) {
        _ = view.perform(NSSelectorFromString("setNeedsLayout"))
    }
}
