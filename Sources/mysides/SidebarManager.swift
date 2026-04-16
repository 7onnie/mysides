import Foundation

// Represents a single entry in the Finder Favorites sidebar.
struct SidebarItem {
    let bookmarkData: Data
    let uuid: String
    let visibility: Int
    let customProperties: NSDictionary

    // Resolves the bookmark to a URL without mounting volumes or showing UI.
    var resolvedURL: URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    // Uses an explicit custom Name property if present, otherwise falls back to
    // the last path component of the resolved URL.
    var displayName: String {
        if let name = customProperties["Name"] as? String, !name.isEmpty {
            return name
        }
        return resolvedURL?.lastPathComponent ?? "(unresolvable)"
    }

    var urlString: String {
        return resolvedURL?.absoluteString ?? "NOTFOUND"
    }

    // Serialises the item back to the NSDictionary form expected by NSKeyedArchiver.
    func asDictionary() -> NSDictionary {
        return [
            "visibility":           visibility as NSNumber,
            "CustomItemProperties": customProperties,
            "Bookmark":             bookmarkData as NSData,
            "uuid":                 uuid,
        ]
    }
}

// Manages the .sfl4 / .sfl3 / .sfl2 Finder sidebar file.
// All mutations are written atomically; Finder is notified via a distributed
// notification so changes appear without restarting Finder.
class SidebarManager {
    private let sflURL: URL
    private var rootDict: NSMutableDictionary

    init() throws {
        let supportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")

        // Prefer the newest format present on this system.
        let formats = ["sfl4", "sfl3", "sfl2"]
        var found: URL?
        for ext in formats {
            let candidate = supportDir
                .appendingPathComponent("com.apple.LSSharedFileList.FavoriteItems")
                .appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                found = candidate
                break
            }
        }

        if let sflFile = found {
            // Load the existing file.
            sflURL = sflFile
            let data = try Data(contentsOf: sflURL)
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = false
            guard let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSDictionary else {
                throw SidebarError.invalidFormat("root object is not a dictionary")
            }
            rootDict = root.mutableCopy() as! NSMutableDictionary
        } else {
            // No sfl file exists yet (e.g. fresh user account, Finder not opened).
            // Point at sfl4 — save() will create the directory and file on first write.
            sflURL = supportDir
                .appendingPathComponent("com.apple.LSSharedFileList.FavoriteItems")
                .appendingPathExtension("sfl4")
            rootDict = NSMutableDictionary(dictionary: [
                "items":      NSMutableArray(),
                "properties": NSDictionary(),
            ])
        }
    }

    // MARK: - Public API

    func list() {
        let all = items
        if all.isEmpty {
            print("(no items)")
            return
        }
        for item in all {
            print("\(item.displayName) -> \(item.urlString)")
        }
    }

    func add(name: String, url: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw SidebarError.pathNotFound(url.path)
        }
        guard isDir.boolValue else {
            throw SidebarError.notADirectory(url.path)
        }

        let bookmarkData = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.nameKey],
            relativeTo: nil
        )

        // Only store an explicit Name when it differs from the folder's own name,
        // to stay consistent with how Finder itself writes sidebar entries.
        var customProps: NSDictionary = NSDictionary()
        if name != url.lastPathComponent {
            customProps = ["Name": name] as NSDictionary
        }

        let newItem: NSDictionary = [
            "visibility":           0 as NSNumber,
            "CustomItemProperties": customProps,
            "Bookmark":             bookmarkData as NSData,
            "uuid":                 UUID().uuidString,
        ]

        let list = mutableItems()
        list.add(newItem)
        rootDict["items"] = list

        try save()
        print("Added: \(name)")
    }

    func remove(name: String) throws {
        let list = mutableItems()
        var indexToRemove: Int?

        for (i, obj) in list.enumerated() {
            guard let dict = obj as? NSDictionary,
                  let bookmark = dict["Bookmark"] as? Data
            else { continue }

            // Match against explicit custom Name first.
            if let customName = (dict["CustomItemProperties"] as? NSDictionary)?["Name"] as? String,
               customName == name {
                indexToRemove = i
                break
            }

            // Fall back to the resolved URL's last path component.
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), url.lastPathComponent == name {
                indexToRemove = i
                break
            }
        }

        guard let idx = indexToRemove else {
            throw SidebarError.itemNotFound(name)
        }

        list.removeObject(at: idx)
        rootDict["items"] = list

        try save()
        print("Removed: \(name)")
    }

    // MARK: - Private helpers

    private var items: [SidebarItem] {
        guard let arr = rootDict["items"] as? NSArray else { return [] }
        return arr.compactMap { obj -> SidebarItem? in
            guard let dict = obj as? NSDictionary,
                  let bookmark = dict["Bookmark"] as? Data,
                  let uuid = dict["uuid"] as? String
            else { return nil }

            return SidebarItem(
                bookmarkData: bookmark,
                uuid: uuid,
                visibility: (dict["visibility"] as? Int) ?? 0,
                customProperties: (dict["CustomItemProperties"] as? NSDictionary) ?? NSDictionary()
            )
        }
    }

    private func mutableItems() -> NSMutableArray {
        return (rootDict["items"] as? NSArray)?.mutableCopy() as? NSMutableArray ?? NSMutableArray()
    }

    private func save() throws {
        // Create the sharedfilelist directory if it doesn't exist yet.
        let dir = sflURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(rootDict as NSDictionary, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()

        try archiver.encodedData.write(to: sflURL, options: .atomic)
        notifyFinder()
    }

    // Posts a distributed notification that Finder listens for to reload its sidebar.
    private func notifyFinder() {
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.SidebarPreferencesChanged"),
            object: nil
        )
    }
}
