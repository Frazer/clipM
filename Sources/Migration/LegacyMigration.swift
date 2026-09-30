import SwiftData
import Foundation
import CoreData

/// One-time import of `Snippets.xml` from the original ClipMenu app.
///
/// Completion is recorded in UserDefaults under `legacyMigrationCompleted`.
/// Clip history and actions are not read from the old archive or plist.
struct LegacyMigration {

    static let completedKey = "legacyMigrationCompleted"

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
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }

    let mom = makeLegacySnippetModel()
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: mom)
    let options: [String: Any] = [NSReadOnlyPersistentStoreOption: true]
    guard (try? coordinator.addPersistentStore(
        ofType: NSXMLStoreType,
        configurationName: nil,
        at: url,
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
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try coordinator.addPersistentStore(ofType: NSXMLStoreType, configurationName: nil, at: url, options: nil)
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
