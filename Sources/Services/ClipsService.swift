import SwiftData
import AppKit
import Combine
import os

/// Manages the clipboard history: monitors NSPasteboard, deduplicates entries,
/// enforces the max-history limit, and writes ClipEntry records to SwiftData.
///
/// Reference: `legacy/Source/ClipsController.{h,m}` and `Clip.{h,m}`.
@MainActor
final class ClipsService {
    private static let log = Logger(subsystem: "com.naotaka.ClipMenu", category: "ClipsService")

    private let monitor: ClipboardMonitor
    private let pasteboard: NSPasteboard
    private let exclusion  = AppExclusionService()
    private let paste      = PasteService()
    private let settings: ClipMenuSettings

    private var context:     ModelContext?
    private var cancellables = Set<AnyCancellable>()

    init(settings: ClipMenuSettings = ClipMenuSettings(), pasteboard: NSPasteboard = .general) {
        self.settings = settings
        self.pasteboard = pasteboard
        monitor = ClipboardMonitor(pasteboard: pasteboard)
    }

    func start(context: ModelContext) {
        stop()
        self.context = context
        exclusion.update(from: settings)
        enforceHistoryLimitNow()
        monitor.start()
        monitor.pasteboardChanged
            .sink { [weak self] pasteboard in
                Task {
                    await self?.handlePasteboardChange(pasteboard)
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        monitor.stop()
    }

    /// Copies the given entry back onto the system pasteboard and triggers paste.
    func select(_ entry: ClipEntry, pasteImmediately: Bool = true) async {
        let pboard = pasteboard
        pboard.clearContents()

        var declaredTypes = entry.types.map(NSPasteboard.PasteboardType.init(rawValue:))
        if declaredTypes.isEmpty {
            declaredTypes = [.string]
        }
        // URLs are one string per pasteboard item, not an array property list.
        // Keep additional text/rich representations on the first item.
        let urls = entry.filenames?.map { URL(fileURLWithPath: $0).absoluteString }
            ?? entry.urlStrings ?? []
        let urlType: NSPasteboard.PasteboardType = entry.filenames != nil ? .fileURL : .URL
        let items = (0..<max(urls.count, 1)).map { _ in NSPasteboardItem() }
        let first = items[0]
        for (item, url) in zip(items, urls) { item.setString(url, forType: urlType) }

        for type in declaredTypes {
            switch type {
            case .string:
                if let value = entry.stringValue {
                    first.setString(value, forType: .string)
                }
            case .rtfd:
                if entry.isRTFD, let data = entry.rtfData {
                    first.setData(data, forType: .rtfd)
                }
            case .rtf:
                if !entry.isRTFD, let data = entry.rtfData {
                    first.setData(data, forType: .rtf)
                }
            case .pdf:
                if let data = entry.pdfData {
                    first.setData(data, forType: .pdf)
                }
            case .fileURL, .URL:
                break // Written above, including all files in a multi-file copy.
            case .tiff, .png:
                if let data = entry.imageData {
                    // Older captures could contain PNG bytes under a TIFF type.
                    let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
                    let tiff = data.starts(with: pngSignature)
                        ? NSBitmapImageRep(data: data)?.tiffRepresentation : data
                    if let tiff { first.setData(tiff, forType: .tiff) }
                }
            default:
                break
            }
        }
        guard pboard.writeObjects(items) else { return }

        monitor.ignoreCurrentChange()
        if settings.reorderClipsAfterPasting { entry.lastUsedAt = .now }
        try? context?.save()

        if pasteImmediately && settings.autoPasteAfterSelection {
            Self.log.debug("Auto-paste after clip selection is ON (immediate)")
            await paste.paste()
        } else {
            Self.log.debug("Clip selected without immediate paste (pasteImmediately=\(pasteImmediately, privacy: .public), setting=\(self.settings.autoPasteAfterSelection, privacy: .public))")
        }
    }

    func handlePasteboardChange(_ pboard: NSPasteboard) async {
        exclusion.update(from: settings)
        if exclusion.shouldExclude() {
            return
        }

        guard let clip = makeClip(from: pboard) else { return }
        guard let context else { return }

        do {
            let existing = try context.fetch(FetchDescriptor<ClipEntry>())
            let hash = clip.contentHash
            if let matched = existing.first(where: { $0.contentHash == hash && $0.hasSameContent(as: clip) }) {
                if settings.reorderClipsAfterPasting { matched.lastUsedAt = .now }
                if matched.imageData != nil || clip.imageData != nil {
                    Self.log.debug("Matched existing image clip")
                }
                // Actions can insert a transformed clip before the monitor
                // observes it. Enforce the limit on that duplicate path too.
                trimHistoryIfNeeded(context: context)
                try context.save()
                return
            }

            context.insert(clip)
            Self.log.debug("Captured clipboard entry")
            if clip.imageData != nil {
                Self.log.debug("Inserted image clip")
            }
            trimHistoryIfNeeded(context: context)
            try context.save()
        } catch {
            Self.log.error("Failed handling pasteboard change: \(error.localizedDescription, privacy: .public)")
            return
        }
    }

    private func enforceHistoryLimitNow() {
        guard let context else { return }
        trimHistoryIfNeeded(context: context)
        try? context.save()
    }

    private func trimHistoryIfNeeded(context: ModelContext) {
        do {
            // Offset fetches merge pending inserts AND updates separately.
            // Flush both so a new or recently used clip cannot be mistaken for
            // an entry beyond the retained range.
            if context.hasChanges { try context.save() }
            var descriptor = FetchDescriptor<ClipEntry>(sortBy: [SortDescriptor(\ClipEntry.createdAt, order: .reverse)])
            descriptor.fetchOffset = max(settings.maxHistorySize, 0)
            let clips = try context.fetch(descriptor)

            for clip in clips {
                context.delete(clip)
            }
        } catch {
            return
        }
    }

    func makeClip(from pboard: NSPasteboard) -> ClipEntry? {
        guard let pbTypes = pboard.types, !pbTypes.isEmpty else { return nil }

        let filtered = filteredTypes(from: pbTypes)
        guard !filtered.isEmpty else { return nil }

        let clip = ClipEntry()
        clip.types = filtered.map(\.rawValue)

        for pbType in filtered {
            switch pbType {
            case .string:
                clip.stringValue = pboard.string(forType: .string)
            case .rtfd:
                clip.rtfData = pboard.data(forType: .rtfd)
                clip.isRTFD = true
            case .rtf:
                if clip.rtfData == nil {
                    clip.rtfData = pboard.data(forType: .rtf)
                    clip.isRTFD = false
                }
            case .pdf:
                clip.pdfData = pboard.data(forType: .pdf)
            case .fileURL:
                clip.filenames = (pboard.pasteboardItems ?? []).compactMap {
                    guard let value = $0.string(forType: .fileURL),
                          let url = URL(string: value), url.isFileURL else { return nil }
                    return url.path
                }
            case .URL:
                clip.urlStrings = (pboard.pasteboardItems ?? []).compactMap { $0.string(forType: .URL) }
            case .tiff, .png:
                // Store actual TIFF bytes since capture normalizes image types
                // to TIFF; labelling raw PNG bytes as TIFF breaks other apps.
                clip.imageData = pboard.data(forType: .tiff)
                    ?? pboard.data(forType: .png).flatMap { NSBitmapImageRep(data: $0)?.tiffRepresentation }
                if clip.imageData == nil {
                    Self.log.debug("Image type seen but no image bytes. pbTypes=\(filtered.map(\.rawValue).joined(separator: ","), privacy: .public)")
                } else {
                    Self.log.debug("Captured image bytes=\(clip.imageData?.count ?? 0, privacy: .public)")
                }
            default:
                break
            }
        }

        return clip
    }

    private func filteredTypes(from pbTypes: [NSPasteboard.PasteboardType]) -> [NSPasteboard.PasteboardType] {
        var results: [NSPasteboard.PasteboardType] = []

        for pbType in pbTypes {
            guard shouldStore(pbType) else { continue }

            if pbType == .tiff || pbType == .png {
                if !results.contains(.tiff) {
                    results.append(.tiff)
                }
                continue
            }

            results.append(pbType)
        }

        return results
    }

    private func shouldStore(_ type: NSPasteboard.PasteboardType) -> Bool {
        guard let typeName = legacyTypeName(for: type) else { return false }
        return settings.storeTypes[typeName] ?? false
    }

    private func legacyTypeName(for type: NSPasteboard.PasteboardType) -> String? {
        switch type {
        case .string: return "String"
        case .rtf: return "RTF"
        case .rtfd: return "RTFD"
        case .pdf: return "PDF"
        case .fileURL: return "Filenames"
        case .URL: return "URL"
        case .tiff, .png: return "TIFF"
        default: return nil
        }
    }

    func clearAll() async throws {
        guard let context else { return }
        let all = try context.fetch(FetchDescriptor<ClipEntry>())
        for entry in all { context.delete(entry) }
        try context.save()
    }

    /// Writes a plain string to the pasteboard and triggers paste.
    func copyStringToPasteboard(_ string: String, pasteImmediately: Bool = true) async {
        let pboard = pasteboard
        pboard.clearContents()
        pboard.setString(string, forType: .string)
        if pasteImmediately && settings.autoPasteAfterSelection {
            Self.log.debug("Auto-paste after snippet selection is ON (immediate)")
            await paste.paste()
        } else {
            Self.log.debug("Snippet copied without immediate paste (pasteImmediately=\(pasteImmediately, privacy: .public), setting=\(self.settings.autoPasteAfterSelection, privacy: .public))")
        }
    }
}
