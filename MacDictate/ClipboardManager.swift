import AppKit
import Foundation

struct ClipboardItemSnapshot: Equatable, Sendable {
    let representations: [String: Data]
}

struct ClipboardSnapshot: Equatable, Sendable {
    let items: [ClipboardItemSnapshot]
}

@MainActor
protocol ClipboardManaging: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> ClipboardSnapshot
    @discardableResult func writeText(_ text: String, transient: Bool) -> Int
    @discardableResult func restore(_ snapshot: ClipboardSnapshot, ifChangeCountIs expectedChangeCount: Int) -> Bool
}

extension ClipboardManaging {
    @discardableResult func writeText(_ text: String) -> Int {
        writeText(text, transient: false)
    }
}

@MainActor
final class ClipboardManager: ClipboardManaging {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> ClipboardSnapshot {
        let snapshots = (pasteboard.pasteboardItems ?? []).map { item in
            var representations: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations[type.rawValue] = data
                }
            }
            return ClipboardItemSnapshot(representations: representations)
        }
        return ClipboardSnapshot(items: snapshots)
    }

    /// The de-facto standard type clipboard managers honor to skip recording an entry.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    @discardableResult
    func writeText(_ text: String, transient: Bool) -> Int {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if transient {
            item.setData(Data(), forType: Self.transientType)
        }
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    @discardableResult
    func restore(_ snapshot: ClipboardSnapshot, ifChangeCountIs expectedChangeCount: Int) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return true }

        let items = snapshot.items.map { snapshotItem in
            let item = NSPasteboardItem()
            for (rawType, data) in snapshotItem.representations {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        pasteboard.writeObjects(items)
        return true
    }
}

