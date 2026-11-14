import Foundation
import Observation
import StoreKit
import SortlyCore

/// One-time unlock (decision 2026-11-13): free download, the first albums are free, then
/// a single non-consumable purchase unlocks everything. No subscription, no tracking.
@MainActor
@Observable
final class Purchases {
    static let shared = Purchases()

    /// Albums Albumist may create or extend before the unlock is needed. Change here only.
    static let freeAlbumLimit = 10
    static let unlockProductID = "app.albumist.ios.unlock"
    private static let usedKey = "purchases.albumsUsed"
    private static let byPlanKey = "purchases.albumsByPlan"

    private(set) var isUnlocked = false
    private(set) var product: Product?
    private(set) var isPurchasing = false
    var lastError: String?

    /// Albums created or extended before counting per plan (older versions).
    private var legacyUsed: Int = UserDefaults.standard.integer(forKey: Purchases.usedKey)
    /// Plan id → albums that plan created or extended. Counting per plan makes recording
    /// idempotent: a plan finalized again after a crash is not counted twice.
    private var byPlan: [String: Int] = UserDefaults.standard.dictionary(forKey: Purchases.byPlanKey) as? [String: Int] ?? [:]

    /// Albums created or extended so far. A completed undo gives its albums back.
    var albumsUsed: Int { legacyUsed + byPlan.values.reduce(0, +) }

    private var updates: Task<Void, Never>?

    var remainingFreeAlbums: Int { max(0, Self.freeAlbumLimit - albumsUsed) }

    /// True if a plan touching `albums` albums may run without the unlock.
    func allows(albums: Int) -> Bool { isUnlocked || Self.unlockedForUITests || albums <= remainingFreeAlbums }

    /// Debug builds only: the end-to-end UI test runs without the purchase sheet.
    static var unlockedForUITests: Bool { UITestSupport.isRunning }

    func recordUsage(plan: SortlyID, albums: Int) {
        guard albums > 0, byPlan[plan.rawValue] == nil else { return }
        byPlan[plan.rawValue] = albums
        UserDefaults.standard.set(byPlan, forKey: Self.byPlanKey)
    }

    /// After an undo the albums are gone again, so they do not count as used. Plans counted by
    /// an older version give back `albums` from the old total.
    func returnUsage(plan: SortlyID, albums: Int) {
        if byPlan.removeValue(forKey: plan.rawValue) != nil {
            UserDefaults.standard.set(byPlan, forKey: Self.byPlanKey)
        } else if albums > 0 {
            legacyUsed = max(0, legacyUsed - albums)
            UserDefaults.standard.set(legacyUsed, forKey: Self.usedKey)
        }
    }

    func start() {
        guard updates == nil else { return }
        updates = Task {
            for await result in Transaction.updates {
                switch result {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshEntitlements()
                    lastError = nil
                case .unverified(let transaction, _):
                    await transaction.finish()
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
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    isUnlocked = true
                    lastError = nil
                case .unverified(let transaction, _):
                    // Never unlock on an unverified receipt, but close the transaction so
                    // it does not come back on every launch.
                    await transaction.finish()
                    lastError = String(localized: "Der Kauf konnte nicht bestätigt werden. Tippe auf „Kauf wiederherstellen“ oder versuche es später noch einmal.")
                }
            case .pending:
                lastError = String(localized: "Der Kauf wartet noch auf eine Bestätigung, zum Beispiel durch die Familienfreigabe. Albumist schaltet sich danach von selbst frei.")
            case .userCancelled:
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
