import UIKit
import SortlyCore

/// Device facts for the diagnostic report: model identifier and system version only.
enum DeviceInfo {
    /// "iPhone17,1" on a device, the simulated model in the simulator.
    static var model: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated + " (Simulator)" }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    @MainActor static var system: String {
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }
}

/// Step problems in plain words. The journal keeps short English reason codes (they also go
/// into the diagnostic report); the user reads these sentences instead.
enum StepProblemText {
    static func text(_ reason: String) -> String {
        switch reason {
        case "interrupted":
            String(localized: "Das Umsetzen wurde unterbrochen.")
        case "parent folder was not created", "target album was not created", "target folder was not created":
            String(localized: "Ein Ordner oder Album, das davor angelegt werden sollte, fehlte.")
        case "a collection with this title appeared meanwhile":
            String(localized: "Inzwischen gab es dort schon ein Album mit diesem Namen.")
        case "parent folder no longer exists":
            String(localized: "Der Zielordner wurde inzwischen gelöscht.")
        case "album no longer exists":
            String(localized: "Das Album wurde inzwischen gelöscht.")
        case "folder is not empty":
            String(localized: "Ein Ordner blieb, weil noch andere Alben darin liegen.")
        case "kept: the album holds photos added meanwhile; only Albumist's photos were taken out":
            String(localized: "Ein Album blieb, weil inzwischen eigene Fotos darin sind. Nur die Fotos von Albumist wurden herausgenommen.")
        case StepState.leftByUserReason:
            String(localized: "Du hast den Rest so gelassen.")
        case let r where r.hasSuffix("could not be verified"):
            String(localized: "Eine Änderung ließ sich in der Mediathek nicht nachprüfen.")
        default:
            String(localized: "Die Fotos-App hat einen Fehler gemeldet.")
        }
    }

    /// One sentence per kind of problem, in plan order.
    static func texts(_ reasons: [String]) -> [String] {
        var seen = Set<String>()
        return reasons.map(text).filter { seen.insert($0).inserted }
    }
}
