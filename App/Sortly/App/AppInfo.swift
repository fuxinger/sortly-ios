import Foundation

/// Product identity in one place. The product is called Albumist (chosen 14.11.2026); the
/// bundle identifiers keep the old working name "sortly" until the App Store record exists.
/// The display name lives here and in project.yml (Info.plist).
enum AppInfo {
    static let name = "Albumist"
    static let bundleID = "app.albumist.ios"
    static let refinementTaskID = "app.albumist.ios.refinement"
    static let continuedAnalysisTaskPrefix = "app.albumist.ios.analysis"
    static let supportFolderName = "Albumist"
    /// Website from `website/` (GitHub Pages), in the app's language.
    static var privacyPolicyURL: URL {
        let german = Bundle.main.preferredLocalizations.first?.hasPrefix("de") ?? true
        return URL(string: german ? "https://fuxinger.github.io/sortly-ios/de/datenschutz.html"
                                  : "https://fuxinger.github.io/sortly-ios/en/privacy.html")!
    }
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
