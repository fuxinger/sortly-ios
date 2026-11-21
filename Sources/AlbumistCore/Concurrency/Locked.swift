#if canImport(Darwin)
import Synchronization

/// A value behind a lock, for every lock in the core package and its tests. On Apple platforms
/// this is exactly the standard library's `Mutex` (an `os_unfair_lock`), so the app is unchanged.
///
/// On Linux it is a small lock of its own (`NSLock`, a pthread mutex), because Thread Sanitizer
/// cannot see `Mutex` there: the standard library's Linux `Mutex` locks with atomics inside the
/// prebuilt `Synchronization` module, which TSan does not instrument, so every value read under
/// it is reported as a race although the lock holds (reproduced 21.11.2026 with a 5-line program
/// and in `AppSource.code`, the first report of the Linux TSan run, sanitize.yml). A pthread
/// mutex is one TSan knows, so its reports on Linux are real ones.
public typealias Locked = Mutex
#else
import Foundation

/// See the Apple-platform branch above: the Linux stand-in for `Mutex` with the same `withLock`.
public final class Locked<Value: ~Copyable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ initialValue: consuming sending Value) {
        value = initialValue
    }

    public func withLock<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
#endif
