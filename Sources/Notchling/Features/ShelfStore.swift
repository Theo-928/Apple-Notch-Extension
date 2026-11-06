import AppKit
import Foundation

/// The file shelf: drop files on the notch, drag them out later.
///
/// Only file *references* are kept (we never read file contents), so no
/// Files & Folders permission is needed — drag-and-drop is an explicit user
/// action that macOS treats as consent.
@MainActor
final class ShelfStore: ObservableObject {
    struct Item: Identifiable, Hashable {
        let id: UUID
        let url: URL
        var name: String { url.lastPathComponent }
    }

    @Published private(set) var items: [Item] = []
    private let defaultsKey = "shelfItems"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        items = paths.map { Item(id: UUID(), url: URL(fileURLWithPath: $0)) }
    }

    func add(_ urls: [URL]) {
        let existing = Set(items.map(\.url.standardizedFileURL))
        for url in urls where url.isFileURL && !existing.contains(url.standardizedFileURL) {
            items.append(Item(id: UUID(), url: url))
        }
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    func icon(for item: Item) -> NSImage {
        NSWorkspace.shared.icon(forFile: item.url.path)
    }

    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func open(_ item: Item) {
        NSWorkspace.shared.open(item.url)
    }

    /// AirDrop via the system share service — no permission involved.
    func airDrop(_ items: [Item]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: items.map(\.url))
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: defaultsKey)
    }
}
