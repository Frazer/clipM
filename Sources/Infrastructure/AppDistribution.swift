import Foundation

/// Distribution channel and public links shared by About / Updates UI.
enum AppDistribution {
    /// Compile-time channel. Direct (GitHub) builds omit `APP_STORE`.
    static var isAppStoreBuild: Bool {
        #if APP_STORE
        true
        #else
        false
        #endif
    }

    static var channelDisplayName: String {
        isAppStoreBuild ? "Mac App Store" : "Direct download"
    }

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    static var versionLabel: String {
        "Version \(shortVersion) (\(buildNumber))"
    }

    /// Open-source repository (safe to link from App Store builds as source/docs).
    static let githubURL = URL(string: "https://github.com/Frazer/ClipMenu")!

    static let unitedVisionsURL = URL(string: "https://unitedvisions.org")!
    static let unitedVisionsName = "United Visions"

    /// Set this once the app is listed (numeric App Store ID). Used to deep-link the product page.
    static let appStoreProductID: String? = nil

    /// Sparkle appcast for direct builds. Host this file on GitHub Releases (or your site).
    static let sparkleFeedURL = URL(string: "https://github.com/Frazer/ClipMenu/releases/latest/download/appcast.xml")!

    static var aboutBlurb: String {
        """
        ClipMenu is a modern macOS clipboard manager — keep history, snippets, and actions at your fingertips from the menu bar.

        This project is open source. Source code and direct-download releases live on GitHub. ClipMenu is supported by \(unitedVisionsName).
        """
    }
}
