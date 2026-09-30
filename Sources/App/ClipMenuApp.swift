import SwiftUI
import SwiftData
import AppKit

@main
struct ClipMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let modelContainer: ModelContainer
    private let runtime = AppRuntime.shared
    private let isPasteUITestMode = ProcessInfo.processInfo.environment["CLIPMENU_UI_TEST_MODE"] == "1"

    init() {
        let schema = Schema([
            ClipEntry.self,
            SnippetFolder.self,
            Snippet.self,
            ActionNode.self,
        ])

        let configuration: ModelConfiguration
        if isPasteUITestMode {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            do {
                let storeURL = try ClipStoreLocation.prepareURL()
                configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
            } catch {
                _ = NSApplication.shared
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "\(AppDistribution.displayName) couldn’t open its saved data."
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Quit")
                alert.runModal()
                exit(1)
            }
        }
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Never discard a user's history or snippets to recover from a
            // store-open failure. Report it instead of crashing on a force-try.
            _ = NSApplication.shared
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "\(AppDistribution.displayName) couldn’t open its saved data."
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            exit(1)
        }
        runtime.modelContainer = modelContainer
    }

    var body: some Scene {
        Settings {
            PreferencesView()
                .modelContainer(modelContainer)
                .environment(runtime.settings)
                .environment(\.loginItemService, runtime.loginItemService)
        }
        .modelContainer(modelContainer)
    }
}

/// Live data lives in `~/Library/Application Support/ClipM`.
/// `Snippets.xml` is still read once from that folder. The old clip archive
/// and action plist are not imported.
enum ClipStoreLocation {
    static let folderName = "ClipM"
    static let storeName = "default.store"

    static var folderURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(folderName, isDirectory: true)
    }

    static var snippetsURL: URL? {
        folderURL?.appendingPathComponent("Snippets.xml")
    }

    static var userActionScriptsURL: URL? {
        folderURL?.appendingPathComponent("script/action", isDirectory: true)
    }

    static var userScriptLibraryURL: URL? {
        folderURL?.appendingPathComponent("script/lib", isDirectory: true)
    }

    static func prepareURL() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = support.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        relocateLegacySupportFiles(into: folder)
        let destination = folder.appendingPathComponent(storeName)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try moveLooseStoreIfNeeded(from: support, to: destination)
        }
        return destination
    }

    /// Moves a copied `Snippets.xml` and `script` folder from the original
    /// ClipMenu support directory. Leaves `clips.data` and `actions.plist` behind.
    private static func relocateLegacySupportFiles(into folder: URL) {
        guard let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ClipMenu", isDirectory: true)
        else { return }
        let fileManager = FileManager.default
        for name in ["Snippets.xml", "script"] {
            let source = legacy.appendingPathComponent(name)
            let destination = folder.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.moveItem(at: source, to: destination)
        }
    }

    private static func moveLooseStoreIfNeeded(from support: URL, to destination: URL) throws {
        let source = support.appendingPathComponent(storeName)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.moveItem(at: source, to: destination)
        do {
            for suffix in ["-wal", "-shm"] {
                let extra = URL(fileURLWithPath: source.path + suffix)
                guard fileManager.fileExists(atPath: extra.path) else { continue }
                try fileManager.moveItem(at: extra, to: URL(fileURLWithPath: destination.path + suffix))
            }
        } catch {
            try? fileManager.moveItem(at: destination, to: source)
            throw error
        }
    }
}
