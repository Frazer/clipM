import SwiftData
import Foundation
import CoreData

/// One-time import of `Snippets.xml` from the original ClipMenu app.
///
/// Completion is recorded in UserDefaults under `legacyMigrationCompleted`.
/// Clip history and actions are not read from the old archive or plist.
struct LegacyMigration {

    static let completedKey = "legacyMigrationCompleted"
    static let maximumXMLBytes = 16_777_216

    static var isNeeded: Bool {
        !UserDefaults.standard.bool(forKey: completedKey)
    }

    /// Call from AppDelegate.applicationDidFinishLaunching if `isNeeded`.
    static func run(in context: ModelContext) {
        if let snippetsURL = ClipStoreLocation.snippetsURL {
            _ = importSnippets(from: snippetsURL, into: context)
        }
        UserDefaults.standard.set(true, forKey: completedKey)
    }

    // MARK: - Snippets (Core Data XML → SwiftData)

/// Imports a ClipMenu `Snippets.xml` file. Folders are matched by title.
/// A snippet that already has the same title and text in that folder is skipped.
static func importSnippets(from url: URL, into context: ModelContext) -> SnippetXMLImportResult? {
    // Validate a bounded UTF-8 snapshot before Core Data sees any XML. Legacy
    // exports use UTF-8 and need no DTD or entities beyond XML's built-ins.
    // Import the same bytes we validated so replacing the selected file cannot
    // bypass the checks between validation and Core Data parsing.
    guard let data = validatedSnippetXML(at: url) else { return nil }
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipMenu.SnippetImport.\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: temporaryDirectory.appendingPathComponent("Snippets.xml"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                             ofItemAtPath: temporaryDirectory.appendingPathComponent("Snippets.xml").path)
    } catch {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        return nil
    }
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let mom = makeLegacySnippetModel()
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: mom)
    let options: [String: Any] = [NSReadOnlyPersistentStoreOption: true]
    guard (try? coordinator.addPersistentStore(
        ofType: NSXMLStoreType,
        configurationName: nil,
        at: temporaryDirectory.appendingPathComponent("Snippets.xml"),
        options: options)) != nil
    else { return nil }

    let legacyContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    legacyContext.persistentStoreCoordinator = coordinator

    let folderRequest = NSFetchRequest<NSManagedObject>(entityName: "Folder")
    folderRequest.sortDescriptors = [NSSortDescriptor(key: "index", ascending: true)]
    guard let legacyFolders = try? legacyContext.fetch(folderRequest) else { return nil }

    let existingFolders = (try? context.fetch(FetchDescriptor<SnippetFolder>())) ?? []
    var foldersByTitle: [String: SnippetFolder] = [:]
    for folder in existingFolders where foldersByTitle[folder.title] == nil {
        foldersByTitle[folder.title] = folder
    }
    var nextFolderIndex = (existingFolders.map(\.sortIndex).max() ?? -1) + 1
    var result = SnippetXMLImportResult()

    for legacyFolder in legacyFolders {
        let title = legacyFolder.value(forKey: "title") as? String ?? ""
        let folder: SnippetFolder
        if let existing = foldersByTitle[title] {
            folder = existing
        } else {
            let created = SnippetFolder(title: title, sortIndex: nextFolderIndex)
            created.isEnabled = legacyFolder.value(forKey: "enabled") as? Bool ?? true
            context.insert(created)
            foldersByTitle[title] = created
            folder = created
            nextFolderIndex += 1
            result.foldersAdded += 1
        }

        let snippetSet = (legacyFolder.value(forKey: "snippets") as? NSSet)?
            .allObjects as? [NSManagedObject] ?? []
        let sorted = snippetSet.sorted {
            ($0.value(forKey: "index") as? Int ?? 0) < ($1.value(forKey: "index") as? Int ?? 0)
        }
        var seen = Set(folder.snippets.map { snippetKey(title: $0.title, content: $0.content) })
        var nextSnippetIndex = (folder.snippets.map(\.sortIndex).max() ?? -1) + 1
        for legacySnippet in sorted {
            let snippetTitle = legacySnippet.value(forKey: "title") as? String ?? ""
            let content = legacySnippet.value(forKey: "content") as? String ?? ""
            let key = snippetKey(title: snippetTitle, content: content)
            if seen.contains(key) {
                result.snippetsSkipped += 1
                continue
            }
            let snippet = Snippet(title: snippetTitle, content: content, sortIndex: nextSnippetIndex)
            snippet.isEnabled = legacySnippet.value(forKey: "enabled") as? Bool ?? true
            snippet.folder = folder
            folder.snippets.append(snippet)
            context.insert(snippet)
            seen.insert(key)
            nextSnippetIndex += 1
            result.snippetsAdded += 1
        }
    }

    do {
        try context.save()
    } catch {
        return nil
    }
    return result
}

    /// Writes the current snippet library as a ClipMenu `Snippets.xml` file.
    static func exportSnippets(to url: URL, from context: ModelContext) throws {
        let model = makeLegacySnippetModel()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        // Build the entire export in a private replacement directory. Publishing
        // it atomically preserves an existing export if encoding or saving fails.
        let replacementDirectory = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true
        )
        defer { try? FileManager.default.removeItem(at: replacementDirectory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: replacementDirectory.path)
        let stagedURL = replacementDirectory.appendingPathComponent("Snippets.xml")
        let store = try coordinator.addPersistentStore(ofType: NSXMLStoreType, configurationName: nil, at: stagedURL, options: nil)
        let exportContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        exportContext.persistentStoreCoordinator = coordinator

        let folders = try context.fetch(FetchDescriptor<SnippetFolder>(sortBy: [SortDescriptor(\.sortIndex)]))
        for folder in folders {
            let folderObject = NSEntityDescription.insertNewObject(forEntityName: "Folder", into: exportContext)
            folderObject.setValue(folder.title, forKey: "title")
            folderObject.setValue(folder.sortIndex, forKey: "index")
            folderObject.setValue(folder.isEnabled, forKey: "enabled")

            var snippetObjects: [NSManagedObject] = []
            for snippet in folder.snippets.sorted(by: { $0.sortIndex < $1.sortIndex }) {
                let snippetObject = NSEntityDescription.insertNewObject(forEntityName: "Snippet", into: exportContext)
                snippetObject.setValue(snippet.title, forKey: "title")
                snippetObject.setValue(snippet.content, forKey: "content")
                snippetObject.setValue(snippet.sortIndex, forKey: "index")
                snippetObject.setValue(snippet.isEnabled, forKey: "enabled")
                snippetObject.setValue(folderObject, forKey: "folder")
                snippetObjects.append(snippetObject)
            }
            folderObject.setValue(NSSet(array: snippetObjects), forKey: "snippets")
        }
        try exportContext.save()
        try coordinator.remove(store)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedURL.path)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: stagedURL, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: url)
        }
    }

    private static func validatedSnippetXML(at url: URL) -> Data? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= maximumXMLBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumXMLBytes + 1), data.count <= maximumXMLBytes,
              let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return nil }
        // Core Data's own exporter adds this fixed DTD. Strip it rather than
        // resolving any external file; reject every other DTD/entity declaration.
        let sanitized = text.replacingOccurrences(
            of: "<!DOCTYPE database SYSTEM \"file:///System/Library/DTDs/CoreData.dtd\">", with: ""
        )
        guard !sanitized.contains("<!DOCTYPE"), !sanitized.contains("<!ENTITY") else { return nil }
        let sanitizedData = Data(sanitized.utf8)
        let parser = XMLParser(data: sanitizedData)
        parser.shouldResolveExternalEntities = false
        let limits = SnippetXMLLimits()
        parser.delegate = limits
        return parser.parse() && limits.isValid ? sanitizedData : nil
    }

    private static func snippetKey(title: String, content: String) -> String {
        title + "\u{0}" + content
    }

    /// Constructs the legacy Snippets Core Data model programmatically.
    ///
    /// Avoids any dependency on a compiled `.mom`/`.momd` bundle resource.
    /// Matches the schema defined in `legacy/Snippets.xcdatamodel`.
    private static func makeLegacySnippetModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let folderEntity = NSEntityDescription()
        folderEntity.name = "Folder"
        folderEntity.managedObjectClassName = "NSManagedObject"

        let snippetEntity = NSEntityDescription()
        snippetEntity.name = "Snippet"
        snippetEntity.managedObjectClassName = "NSManagedObject"

        func attr(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name; a.attributeType = type; a.isOptional = true
            return a
        }

        folderEntity.properties = [
            attr("title", .stringAttributeType),
            attr("index", .integer32AttributeType),
            attr("enabled", .booleanAttributeType),
        ]
        snippetEntity.properties = [
            attr("title", .stringAttributeType),
            attr("content", .stringAttributeType),
            attr("index", .integer32AttributeType),
            attr("enabled", .booleanAttributeType),
        ]

        // Relationship: Folder.snippets ↔ Snippet.folder
        let folderSnippets = NSRelationshipDescription()
        folderSnippets.name = "snippets"
        folderSnippets.isOptional = true
        folderSnippets.minCount = 0
        folderSnippets.maxCount = 0  // to-many
        folderSnippets.destinationEntity = snippetEntity

        let snippetFolder = NSRelationshipDescription()
        snippetFolder.name = "folder"
        snippetFolder.isOptional = true
        snippetFolder.minCount = 0
        snippetFolder.maxCount = 1   // to-one
        snippetFolder.destinationEntity = folderEntity

        folderSnippets.inverseRelationship = snippetFolder
        snippetFolder.inverseRelationship = folderSnippets

        folderEntity.properties += [folderSnippets]
        snippetEntity.properties += [snippetFolder]

        model.entities = [folderEntity, snippetEntity]
        return model
    }
}

struct SnippetXMLImportResult {
    var foldersAdded = 0
    var snippetsAdded = 0
    var snippetsSkipped = 0
}

/// Reject pathological nesting/object counts before passing the snapshot to Core Data.
private final class SnippetXMLLimits: NSObject, XMLParserDelegate {
    private var depth = 0
    private var elements = 0
    private(set) var isValid = true

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        depth += 1
        elements += 1
        if depth > 32 || elements > 100_000 {
            isValid = false
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
    }
}
