import Foundation

/// Product identity in one place. The product is called Albumist (chosen 14.11.2026); the
/// bundle identifiers keep the old working name "sortly" until the App Store record exists.
/// The display name lives here and in project.yml (Info.plist).
enum AppInfo {
    static let name = "Albumist"
    static let bundleID = "app.sortly.ios"
    static let refinementTaskID = "app.sortly.ios.refinement"
    static let continuedAnalysisTaskPrefix = "app.sortly.ios.analysis"
    static let supportFolderName = "Albumist"
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
