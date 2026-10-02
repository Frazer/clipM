import SwiftData
import AppKit
import Foundation

/// CRUD operations over SnippetFolder / Snippet records.
///
/// Reference: `legacy/Source/SnippetsController.{h,m}`.
@MainActor
final class SnippetService {

    private var context: ModelContext?
    private let pasteService = PasteService()

    nonisolated init() {}

    func start(context: ModelContext) {
        self.context = context
        seedStarterSnippetsIfNeeded()
    }

    /// Example folders for a brand-new library, so the menu isn’t empty.
    /// Runs once. A library that already has folders is left alone.
    private func seedStarterSnippetsIfNeeded() {
        guard let context else { return }
        let defaults = UserDefaults.standard
        let key = "didSeedStarterSnippets"
        if defaults.bool(forKey: key) { return }
        let count = (try? context.fetchCount(FetchDescriptor<SnippetFolder>())) ?? 0
        defer { defaults.set(true, forKey: key) }
        guard count == 0 else { return }

        let groups: [(String, [(String, String)])] = [
            ("me", [
                ("email", "you@example.com"),
                ("phone", "626-831-9333"),
                ("address", "123 Kindness Lane"),
                ("About me", "I like laughing and helping little old ladies cross the street."),
                ("name", "John Doe"),
            ]),
            ("dev", [
                ("ls", "ls"),
            ]),
            ("work", [
                ("Company Name", "United Visions"),
                ("Address", "1 Infinite Loop"),
            ]),
            ("hobbies", [
                ("Baskets", "I love to weave baskets with patterns that inspire kindness."),
                ("Ultimate Frisbee", "I love playing ultimate frisbee. It is the kindest, funnest game."),
            ]),
            ("affirmations", [
                ("I practice feeling great.", "I practice feeling great."),
                ("Kindness makes me strong.", "Kindness makes me strong."),
                ("My ideas arrive wearing capes.", "My ideas arrive wearing capes."),
                ("I am the plot twist the day was hoping for.", "I am the plot twist the day was hoping for."),
                ("Confidence sees me coming and holds the door.", "Confidence sees me coming and holds the door."),
                ("I radiate so much goodwill that houseplants stand up straighter.", "I radiate so much goodwill that houseplants stand up straighter."),
                ("I write the thank-you I have been meaning to send.", "I write the thank-you I have been meaning to send."),
                ("My kindness has a marching band.", "My kindness has a marching band."),
                ("I am wildly, inconveniently, magnificently on time for my own life.", "I am wildly, inconveniently, magnificently on time for my own life."),
                ("I take the next small step before I talk myself out of it.", "I take the next small step before I talk myself out of it."),
            ]),
        ]

        for (folderIndex, group) in groups.enumerated() {
            let folder = SnippetFolder(title: group.0, sortIndex: folderIndex)
            context.insert(folder)
            for (snippetIndex, item) in group.1.enumerated() {
                let snippet = Snippet(title: item.0, content: item.1, sortIndex: snippetIndex)
                snippet.folder = folder
                folder.snippets.append(snippet)
                context.insert(snippet)
            }
        }
        try? context.save()
    }

    func folders() throws -> [SnippetFolder] {
        guard let context else { return [] }
        return try context.fetch(FetchDescriptor<SnippetFolder>(sortBy: [SortDescriptor(\SnippetFolder.sortIndex)]))
    }

    func createFolder(title: String) throws -> SnippetFolder {
        guard let context else { return SnippetFolder(title: title, sortIndex: 0) }
        let current = try folders()
        let folder = SnippetFolder(title: title, sortIndex: current.count)
        context.insert(folder)
        try context.save()
        return folder
    }

    func updateFolder(_ folder: SnippetFolder, title: String? = nil, isEnabled: Bool? = nil) throws {
        if let title {
            folder.title = title
        }
        if let isEnabled {
            folder.isEnabled = isEnabled
        }
        try context?.save()
    }

    func deleteFolder(_ folder: SnippetFolder) throws {
        context?.delete(folder)
        try context?.save()
    }

    func createSnippet(in folder: SnippetFolder, title: String, content: String = "") throws -> Snippet {
        let sortIndex = folder.snippets.map(\.sortIndex).max().map { $0 + 1 } ?? 0
        let snippet = Snippet(title: title, content: content, sortIndex: sortIndex)
        snippet.folder = folder
        context?.insert(snippet)
        try context?.save()
        return snippet
    }

    func updateSnippet(_ snippet: Snippet, title: String? = nil, content: String? = nil, isEnabled: Bool? = nil) throws {
        if let title {
            snippet.title = title
        }
        if let content {
            snippet.content = content
        }
        if let isEnabled {
            snippet.isEnabled = isEnabled
        }
        try context?.save()
    }

    func deleteSnippet(_ snippet: Snippet) throws {
        context?.delete(snippet)
        try context?.save()
    }

    func moveSnippet(_ snippet: Snippet, to folder: SnippetFolder, at index: Int) throws {
        snippet.folder = folder
        snippet.sortIndex = max(index, 0)
        try context?.save()
    }

    func paste(snippet: Snippet) async {
        let pboard = NSPasteboard.general
        pboard.clearContents()
        pboard.setString(snippet.content, forType: .string)
        await pasteService.paste()
    }
}
