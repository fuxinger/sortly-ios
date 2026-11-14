import Photos
import UIKit

/// Photos changed outside Albumist (an album made in the Photos app, new pictures, a changed
/// selection): a moment later the analysis catches up, so "Deine Alben" and the suggestions
/// match what Photos shows (Fuchs, 14.11.: albums made in Photos did not appear).
@MainActor
final class LibraryChangeWatcher: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = LibraryChangeWatcher()
    private var registered = false
    private var pending: Task<Void, Never>?

    /// Only with read access: registering earlier could bring up the permission question.
    func start() {
        guard !registered else { return }
        registered = true
        PHPhotoLibrary.shared().register(self)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in LibraryChangeWatcher.shared.scheduleCatchUp() }
    }

    private func scheduleCatchUp() {
        let model = AppModel.shared
        // Albumist's own changes are followed by an analysis anyway.
        guard !model.execution.isRunning else { return }
        pending?.cancel()
        pending = Task {
            // Several changes in a row (an album and its photos) start one analysis.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, Self.mayCatchUp(model) else { return }
            model.startAnalysis()
        }
    }

    private static func mayCatchUp(_ model: AppModel) -> Bool {
        #if targetEnvironment(simulator)
        // The demo library starts its own analysis once every photo is there.
        if DemoLibrary.shared.isSeeding { return false }
        #endif
        return model.phase == .ready && model.access.canRead && !model.execution.isRunning && !model.analysis.isRunning
    }
}
