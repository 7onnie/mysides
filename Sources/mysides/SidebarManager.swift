import Foundation
import Darwin

// Represents a single entry in the Finder Favorites sidebar.
struct SidebarItem {
    let bookmarkData: Data
    let uuid: String
    let visibility: Int
    let customProperties: NSDictionary

    var resolvedURL: URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    var displayName: String {
        if let name = customProperties["Name"] as? String, !name.isEmpty {
            return name
        }
        return resolvedURL?.lastPathComponent ?? "(unresolvable)"
    }

    var urlString: String {
        return resolvedURL?.absoluteString ?? "NOTFOUND"
    }
}

// Manages the .sfl4 / .sfl3 / .sfl2 Finder sidebar file.
class SidebarManager {
    private let sflURL: URL
    private var rootDict: NSMutableDictionary

    init() throws {
        let supportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")

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
            let data = try sflRead(sflFile.path)
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = false
            guard let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSDictionary else {
                throw SidebarError.invalidFormat("root object is not a dictionary")
            }
            sflURL   = sflFile
            rootDict = root.mutableCopy() as! NSMutableDictionary
        } else {
            sflURL   = supportDir
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

            if let customName = (dict["CustomItemProperties"] as? NSDictionary)?["Name"] as? String,
               customName == name {
                indexToRemove = i
                break
            }

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
        let dir = sflURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(rootDict as NSDictionary, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()

        try sflWrite(archiver.encodedData, to: sflURL.path)
        notifyFinder()
    }

    private func notifyFinder() {
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.SidebarPreferencesChanged"),
            object: nil
        )
    }
}

// MARK: - I/O strategy
//
// macOS 16 (Tahoe) enforces TCC on ~/Library/Application Support/com.apple.sharedfilelist/
// even at the POSIX level for non-platform-signed binaries. Platform binaries (/bin/cat,
// /bin/mv) are exempt from this restriction.
//
// Strategy (tried in order):
//   1. POSIX open()/read() — fast, works on macOS ≤15 or when Terminal has FDA
//   2. Subprocess via /bin/cat or /bin/mv — works on macOS 16 without FDA
//   3. Clear error message guiding the user to grant Full Disk Access

private func sflRead(_ path: String) throws -> Data {
    // Attempt 1: direct POSIX read
    if let data = posixRead(path) {
        return data
    }
    let _PosixErrno = errno

    // Attempt 2: spawn /bin/cat (Apple platform binary, TCC-exempt)
    if let data = subprocessRead(path) {
        return data
    }

    // Both failed — give an actionable error
    if _PosixErrno == EPERM {
        throw SidebarError.accessDenied
    }
    throw SidebarError.invalidFormat("read failed (errno \(_PosixErrno): \(String(cString: strerror(_PosixErrno))))")
}

private func sflWrite(_ data: Data, to path: String) throws {
    // Attempt 1: POSIX atomic write (write to tmp + rename)
    if posixWriteAtomic(data, to: path) {
        return
    }
    let _PosixErrno = errno

    // Attempt 2: write to /tmp, then move via /bin/mv (TCC-exempt)
    if subprocessWriteAtomic(data, to: path) {
        return
    }

    if _PosixErrno == EPERM {
        throw SidebarError.accessDenied
    }
    throw SidebarError.invalidFormat("write failed (errno \(_PosixErrno): \(String(cString: strerror(_PosixErrno))))")
}

// MARK: - POSIX primitives

private func posixRead(_ path: String) -> Data? {
    let _FD = Darwin.open(path, O_RDONLY)
    guard _FD >= 0 else { return nil }
    defer { Darwin.close(_FD) }

    var _Stat = stat()
    guard fstat(_FD, &_Stat) == 0 else { return nil }

    let _Size   = Int(_Stat.st_size)
    var _Buffer = [UInt8](repeating: 0, count: _Size)
    guard Darwin.read(_FD, &_Buffer, _Size) == _Size else { return nil }
    return Data(_Buffer)
}

private func posixWriteAtomic(_ data: Data, to path: String) -> Bool {
    let _Tmp = path + ".mysides.tmp"
    let _FD  = Darwin.open(_Tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard _FD >= 0 else { return false }

    let _Written = data.withUnsafeBytes { Darwin.write(_FD, $0.baseAddress!, data.count) }
    Darwin.close(_FD)

    guard _Written == data.count else { Darwin.unlink(_Tmp); return false }
    guard Darwin.rename(_Tmp, path) == 0 else { Darwin.unlink(_Tmp); return false }
    return true
}

// MARK: - Subprocess fallback (platform-signed binaries bypass TCC)

private func subprocessRead(_ path: String) -> Data? {
    let _Proc  = Process()
    _Proc.executableURL = URL(fileURLWithPath: "/bin/cat")
    _Proc.arguments     = [path]
    let _Pipe  = Pipe()
    _Proc.standardOutput = _Pipe
    _Proc.standardError  = FileHandle.nullDevice
    guard (try? _Proc.run()) != nil else { return nil }
    let _Data = _Pipe.fileHandleForReading.readDataToEndOfFile()
    _Proc.waitUntilExit()
    return _Proc.terminationStatus == 0 && !_Data.isEmpty ? _Data : nil
}

private func subprocessWriteAtomic(_ data: Data, to path: String) -> Bool {
    // Write to /tmp first (no TCC restriction), then move with /bin/mv.
    let _Tmp = "/tmp/mysides-\(UUID().uuidString).tmp"
    guard FileManager.default.createFile(atPath: _Tmp, contents: data) else { return false }

    let _Proc = Process()
    _Proc.executableURL = URL(fileURLWithPath: "/bin/mv")
    _Proc.arguments     = [_Tmp, path]
    _Proc.standardError = FileHandle.nullDevice
    guard (try? _Proc.run()) != nil else { try? FileManager.default.removeItem(atPath: _Tmp); return false }
    _Proc.waitUntilExit()

    if _Proc.terminationStatus != 0 {
        try? FileManager.default.removeItem(atPath: _Tmp)
        return false
    }
    return true
}
