import Foundation

/// Product identity in one place: the name "SORTLY" collides with an existing App Store
/// app ("Sortly" inventory) and must be changed before release – only here and in
/// project.yml / Info.plist display name.
enum AppInfo {
    static let name = "SORTLY"
    static let bundleID = "app.sortly.ios"
    static let refinementTaskID = "app.sortly.ios.refinement"
    static let continuedAnalysisTaskPrefix = "app.sortly.ios.analysis"
    static let supportFolderName = "SORTLY"
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
