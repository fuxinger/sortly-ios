import Foundation
import Observation
import StoreKit

/// One-time unlock (decision 2026-11-13): free download, the first albums are free, then
/// a single non-consumable purchase unlocks everything. No subscription, no tracking.
@MainActor
@Observable
final class Purchases {
    static let shared = Purchases()

    /// Albums Albumist may create or extend before the unlock is needed. Change here only.
    static let freeAlbumLimit = 10
    static let unlockProductID = "app.sortly.ios.unlock"
    private static let usedKey = "purchases.albumsUsed"

    private(set) var isUnlocked = false
    private(set) var product: Product?
    private(set) var isPurchasing = false
    var lastError: String?

    /// Albums created or extended so far. A completed undo gives its albums back.
    private(set) var albumsUsed: Int = UserDefaults.standard.integer(forKey: Purchases.usedKey)

    private var updates: Task<Void, Never>?

    var remainingFreeAlbums: Int { max(0, Self.freeAlbumLimit - albumsUsed) }

    /// True if a plan touching `albums` albums may run without the unlock.
    func allows(albums: Int) -> Bool { isUnlocked || Self.unlockedForUITests || albums <= remainingFreeAlbums }

    /// Debug builds only: the end-to-end UI test runs without the purchase sheet.
    static var unlockedForUITests: Bool { UITestSupport.isRunning }

    func recordUsage(albums: Int) {
        guard albums > 0 else { return }
        albumsUsed += albums
        UserDefaults.standard.set(albumsUsed, forKey: Self.usedKey)
    }

    /// After an undo the albums are gone again, so they do not count as used.
    func returnUsage(albums: Int) {
        guard albums > 0 else { return }
        albumsUsed = max(0, albumsUsed - albums)
        UserDefaults.standard.set(albumsUsed, forKey: Self.usedKey)
    }

    func start() {
        guard updates == nil else { return }
        updates = Task {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await refreshEntitlements()
                }
            }
        }
        Task {
            await refreshEntitlements()
            await loadProduct()
        }
    }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.unlockProductID]).first
        } catch {
            product = nil
        }
    }

    func refreshEntitlements() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.unlockProductID,
               transaction.revocationDate == nil {
                unlocked = true
            }
        }
        isUnlocked = unlocked
    }

    func purchase() async {
        guard let product else {
            lastError = String(localized: "Der Kauf ist gerade nicht verfügbar. Bitte versuche es später noch einmal.")
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    isUnlocked = true
                }
            case .pending, .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restore() async {
        do { try await AppStore.sync() } catch { lastError = error.localizedDescription }
        await refreshEntitlements()
    }
}
