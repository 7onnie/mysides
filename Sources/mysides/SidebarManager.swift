import Foundation
import Darwin

// Manages the Finder sidebar via the private LSSharedFileList API loaded at runtime
// through dlopen/dlsym.
//
// LSSharedFileList was removed from Apple's public headers in macOS 12 but the
// implementation still lives in CoreServices and communicates internally via the
// LaunchServices daemon (lsd) over XPC.  Because the actual state is held inside
// a system daemon, TCC restrictions on ~/Library/Application Support/com.apple.sharedfilelist/
// do not apply to the calling process — no Full Disk Access required.
//
// Two lists are managed:
//   FavoriteItems   → the "Favourites" section (list/add/remove individual folders)
//   FavoriteVolumes → the "Locations" section  (toggle category visibility)
//
// The "Recent Tags" toggle lives in com.apple.finder preferences, not in
// LSSharedFileList, so it is handled via CFPreferences.
class SidebarManager {

    // MARK: - Private C function type aliases

    private typealias SFLCreateFn   = @convention(c) (CFAllocator?, CFString, CFTypeRef?) -> CFTypeRef?
    private typealias SFLSnapshotFn = @convention(c) (CFTypeRef, UnsafeMutablePointer<UInt32>) -> CFArray?
    private typealias SFLNameFn     = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    private typealias SFLURLFn      = @convention(c) (CFTypeRef, UInt32, UnsafeMutablePointer<CFTypeRef?>?) -> Unmanaged<CFURL>?
    // Second param is OpaquePointer? because kLSSharedFileListItemLast = 0x2 (sentinel integer,
    // not a real CF object).  Using CFTypeRef? here would cause Swift ARC to call
    // swift_unknownObjectRetain(0x2) → immediate segfault.
    private typealias SFLInsertFn   = @convention(c) (CFTypeRef, OpaquePointer?, CFString?, CFTypeRef?, CFURL, CFDictionary?, CFArray?) -> CFTypeRef?
    private typealias SFLRemoveFn   = @convention(c) (CFTypeRef, CFTypeRef) -> OSStatus
    private typealias SFLCopyPropFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias SFLSetPropFn  = @convention(c) (CFTypeRef, CFString, CFTypeRef) -> OSStatus

    // MARK: - Loaded symbols

    private let _SFL:      CFTypeRef      // LSSharedFileListRef – FavoriteItems
    private let _SFLVol:   CFTypeRef      // LSSharedFileListRef – FavoriteVolumes
    private let _kLast:    OpaquePointer  // kLSSharedFileListItemLast sentinel (0x2)
    private let _snapshot: SFLSnapshotFn
    private let _getName:  SFLNameFn
    private let _getURL:   SFLURLFn
    private let _insert:   SFLInsertFn
    private let _remove:   SFLRemoveFn
    private let _copyProp: SFLCopyPropFn
    private let _setProp:  SFLSetPropFn

    // Locations property key strings (verified via runtime inspection on macOS 13-16)
    private static let _kComputer   = "com.apple.LSSharedFileList.FavoriteVolumes.ComputerIsVisible" as CFString
    private static let _kHardDrives = "com.apple.LSSharedFileList.FavoriteVolumes.ShowHardDrives" as CFString
    private static let _kRemovable  = "com.apple.LSSharedFileList.FavoriteVolumes.ShowEjectableVolumes" as CFString
    private static let _kNetwork    = "com.apple.LSSharedFileList.FavoriteVolumes.ShowNetworkVolumes" as CFString

    // Resolve flags from the old public header (stable across all macOS versions)
    private static let _NoUserInteraction: UInt32 = 1
    private static let _DoNotMount:        UInt32 = 2
    private static let _ResolveFlags:      UInt32 = _NoUserInteraction | _DoNotMount

    // MARK: - Init

    init() throws {
        guard let _Handle = dlopen(
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            RTLD_LAZY
        ) else {
            throw SidebarError.apiUnavailable("dlopen failed: \(String(cString: dlerror()))")
        }

        func sym<T>(_ name: String) throws -> T {
            guard let _P = dlsym(_Handle, name) else {
                throw SidebarError.apiUnavailable("symbol not found: \(name)")
            }
            return unsafeBitCast(_P, to: T.self)
        }

        let _create: SFLCreateFn = try sym("LSSharedFileListCreate")
        _snapshot = try sym("LSSharedFileListCopySnapshot")
        _getName  = try sym("LSSharedFileListItemCopyDisplayName")
        _getURL   = try sym("LSSharedFileListItemCopyResolvedURL")
        _insert   = try sym("LSSharedFileListInsertItemURL")
        _remove   = try sym("LSSharedFileListItemRemove")
        _copyProp = try sym("LSSharedFileListCopyProperty")
        _setProp  = try sym("LSSharedFileListSetProperty")

        // FavoriteItems list
        guard let _KFavPtr = dlsym(_Handle, "kLSSharedFileListFavoriteItems") else {
            throw SidebarError.apiUnavailable("symbol not found: kLSSharedFileListFavoriteItems")
        }
        let _KFav = _KFavPtr.assumingMemoryBound(to: CFString.self).pointee

        guard let _KLastPtr = dlsym(_Handle, "kLSSharedFileListItemLast") else {
            throw SidebarError.apiUnavailable("symbol not found: kLSSharedFileListItemLast")
        }
        let _KLastRaw = _KLastPtr.assumingMemoryBound(to: UInt.self).pointee
        guard let _KLastOpaque = OpaquePointer(bitPattern: _KLastRaw) else {
            throw SidebarError.apiUnavailable("kLSSharedFileListItemLast is zero")
        }
        _kLast = _KLastOpaque

        guard let _SFLRef = _create(nil, _KFav, nil) else {
            throw SidebarError.apiUnavailable("LSSharedFileListCreate returned nil for FavoriteItems")
        }
        _SFL = _SFLRef

        // FavoriteVolumes list
        guard let _KVolPtr = dlsym(_Handle, "kLSSharedFileListFavoriteVolumes") else {
            throw SidebarError.apiUnavailable("symbol not found: kLSSharedFileListFavoriteVolumes")
        }
        let _KVol = _KVolPtr.assumingMemoryBound(to: CFString.self).pointee

        guard let _SFLVolRef = _create(nil, _KVol, nil) else {
            throw SidebarError.apiUnavailable("LSSharedFileListCreate returned nil for FavoriteVolumes")
        }
        _SFLVol = _SFLVolRef

        // dlclose intentionally omitted: framework stays loaded for the lifetime
        // of the process, which is fine for a short-lived CLI tool.
    }

    // MARK: - Favourites: list / add / remove

    /// Raw data for every Favourites item.
    func listItems() -> [(name: String, url: String)] {
        return snapshot().map { _Item in
            let _Name = displayName(for: _Item)
            let _URL  = resolvedURL(for: _Item)?.absoluteString ?? "NOTFOUND"
            return (name: _Name, url: _URL)
        }
    }

    /// Human-readable output (backward-compatible, unchanged format).
    func list() {
        let _Items = listItems()
        if _Items.isEmpty {
            print("(no items)")
            return
        }
        for _Item in _Items {
            print("\(_Item.name) -> \(_Item.url)")
        }
    }

    /// Machine-readable JSON array: [{"name":"…","url":"…"},…]
    func listJSON() {
        let _Parts = listItems().map { _Item -> String in
            let _N = jsonEscape(_Item.name)
            let _U = jsonEscape(_Item.url)
            return "{\"name\":\"\(_N)\",\"url\":\"\(_U)\"}"
        }
        print("[\(_Parts.joined(separator: ","))]")
    }

    func add(name _Name: String, url _URL: URL) throws {
        var _IsDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: _URL.path, isDirectory: &_IsDir) else {
            throw SidebarError.pathNotFound(_URL.path)
        }
        guard _IsDir.boolValue else {
            throw SidebarError.notADirectory(_URL.path)
        }

        let _DisplayName = _Name as CFString
        let _CFURL       = _URL as CFURL

        guard _insert(_SFL, _kLast, _DisplayName, nil, _CFURL, nil, nil) != nil else {
            throw SidebarError.apiUnavailable("LSSharedFileListInsertItemURL returned nil")
        }
        print("Added: \(_Name)")
    }

    func remove(name _Name: String) throws {
        let _Items = snapshot()

        guard let _Item = _Items.first(where: { displayName(for: $0) == _Name }) else {
            throw SidebarError.itemNotFound(_Name)
        }

        let _Status = _remove(_SFL, _Item)
        guard _Status == 0 else {
            throw SidebarError.apiUnavailable("LSSharedFileListItemRemove failed: OSStatus \(_Status)")
        }
        print("Removed: \(_Name)")
    }

    // MARK: - Locations: items and state

    struct LocationsState {
        var computer:   Bool
        var harddrives: Bool
        var removable:  Bool
        var network:    Bool
        var tags:       Bool
    }

    enum LocationItem: String, CaseIterable {
        case computer   = "computer"
        case harddrives = "harddrives"
        case removable  = "removable"
        case network    = "network"
        case tags       = "tags"

        var label: String {
            switch self {
            case .computer:   return "Mac (computer icon)"
            case .harddrives: return "Internal hard disks"
            case .removable:  return "External disks, CDs, DVDs, iOS devices"
            case .network:    return "Servers, Bonjour computers"
            case .tags:       return "Recent Tags section"
            }
        }
    }

    func getLocations() -> LocationsState {
        func boolProp(_ _Key: CFString) -> Bool {
            guard let _V = _copyProp(_SFLVol, _Key)?.takeRetainedValue() else { return true }
            return (_V as AnyObject).boolValue
        }
        let _TagsRaw = CFPreferencesCopyAppValue("ShowRecentTags" as CFString, "com.apple.finder" as CFString)
        let _Tags: Bool = _TagsRaw.map { ($0 as AnyObject).boolValue ?? true } ?? true
        return LocationsState(
            computer:   boolProp(Self._kComputer),
            harddrives: boolProp(Self._kHardDrives),
            removable:  boolProp(Self._kRemovable),
            network:    boolProp(Self._kNetwork),
            tags:       _Tags
        )
    }

    /// Human-readable Locations status table.
    func showLocations() {
        let _State = getLocations()
        func row(_ _Item: LocationItem, _ _Val: Bool) {
            let _Key   = _Item.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
            let _Flag  = _Val ? "on " : "off"
            print("\(_Key) \(_Flag)  \(_Item.label)")
        }
        row(.computer,   _State.computer)
        row(.harddrives, _State.harddrives)
        row(.removable,  _State.removable)
        row(.network,    _State.network)
        row(.tags,       _State.tags)
    }

    /// Machine-readable JSON object: {"computer":true,…}
    func showLocationsJSON() {
        let _S = getLocations()
        print("{\"computer\":\(_S.computer),\"harddrives\":\(_S.harddrives),\"removable\":\(_S.removable),\"network\":\(_S.network),\"tags\":\(_S.tags)}")
    }

    func setLocation(item _Item: LocationItem, enabled _Enabled: Bool) throws {
        switch _Item {

        case .tags:
            // Stored in com.apple.finder preferences, not in LSSharedFileList
            let _Val: CFPropertyList = _Enabled ? kCFBooleanTrue! : kCFBooleanFalse!
            CFPreferencesSetAppValue("ShowRecentTags" as CFString, _Val, "com.apple.finder" as CFString)
            CFPreferencesAppSynchronize("com.apple.finder" as CFString)

        default:
            let _Key: CFString
            switch _Item {
            case .computer:   _Key = Self._kComputer
            case .harddrives: _Key = Self._kHardDrives
            case .removable:  _Key = Self._kRemovable
            case .network:    _Key = Self._kNetwork
            case .tags:       fatalError("unreachable")
            }
            let _Value: CFTypeRef = _Enabled ? kCFBooleanTrue! : kCFBooleanFalse!
            let _Status = _setProp(_SFLVol, _Key, _Value)
            guard _Status == 0 else {
                throw SidebarError.apiUnavailable("LSSharedFileListSetProperty failed: OSStatus \(_Status)")
            }
        }

        print("\(_Enabled ? "Enabled" : "Disabled"): \(_Item.rawValue)")
    }

    // MARK: - Private helpers

    private func snapshot() -> [CFTypeRef] {
        var _Seed: UInt32 = 0
        guard let _Arr = _snapshot(_SFL, &_Seed) as? [CFTypeRef] else { return [] }
        return _Arr
    }

    private func displayName(for _Item: CFTypeRef) -> String {
        return _getName(_Item)?.takeRetainedValue() as String? ?? "(unresolvable)"
    }

    private func resolvedURL(for _Item: CFTypeRef) -> URL? {
        return _getURL(_Item, Self._ResolveFlags, nil)?.takeRetainedValue() as URL?
    }

    private func jsonEscape(_ _Str: String) -> String {
        return _Str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
