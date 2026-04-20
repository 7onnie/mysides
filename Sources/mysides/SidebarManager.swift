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
//   FavoriteVolumes → the "Locations" section  (toggle category/item visibility)
//
// All property keys used here were verified by inspecting the actual
// FavoriteVolumes.sfl4 file which stores them as real NSKeyedArchiver keys.
// "Recent Tags" lives in com.apple.finder preferences, not LSSharedFileList.
class SidebarManager {

    // MARK: - Private C function type aliases

    private typealias SFLCreateFn   = @convention(c) (CFAllocator?, CFString, CFTypeRef?) -> CFTypeRef?
    private typealias SFLSnapshotFn = @convention(c) (CFTypeRef, UnsafeMutablePointer<UInt32>) -> CFArray?
    private typealias SFLNameFn     = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    private typealias SFLURLFn      = @convention(c) (CFTypeRef, UInt32, UnsafeMutablePointer<CFTypeRef?>?) -> Unmanaged<CFURL>?
    // Second param is OpaquePointer? because kLSSharedFileListItemLast = 0x2 (sentinel integer,
    // not a real CF object — using CFTypeRef? causes swift_unknownObjectRetain(0x2) → segfault).
    private typealias SFLInsertFn   = @convention(c) (CFTypeRef, OpaquePointer?, CFString?, CFTypeRef?, CFURL, CFDictionary?, CFArray?) -> CFTypeRef?
    private typealias SFLRemoveFn   = @convention(c) (CFTypeRef, CFTypeRef) -> OSStatus
    private typealias SFLCopyPropFn     = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias SFLSetPropFn      = @convention(c) (CFTypeRef, CFString, CFTypeRef) -> OSStatus
    // Item-level variants (LSSharedFileListItem* vs LSSharedFileList*)
    private typealias SFLItemCopyPropFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias SFLItemSetPropFn  = @convention(c) (CFTypeRef, CFString, CFTypeRef) -> OSStatus

    // MARK: - Loaded symbols

    private let _SFL:      CFTypeRef      // LSSharedFileListRef – FavoriteItems
    private let _SFLVol:   CFTypeRef      // LSSharedFileListRef – FavoriteVolumes
    private let _kLast:    OpaquePointer  // kLSSharedFileListItemLast sentinel (0x2)
    private let _snapshot: SFLSnapshotFn
    private let _getName:  SFLNameFn
    private let _getURL:   SFLURLFn
    private let _insert:   SFLInsertFn
    private let _remove:   SFLRemoveFn
    private let _copyProp:     SFLCopyPropFn
    private let _setProp:      SFLSetPropFn
    private let _itemCopyProp: SFLItemCopyPropFn
    private let _itemSetProp:  SFLItemSetPropFn

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
        _copyProp     = try sym("LSSharedFileListCopyProperty")
        _setProp      = try sym("LSSharedFileListSetProperty")
        _itemCopyProp = try sym("LSSharedFileListItemCopyProperty")
        _itemSetProp  = try sym("LSSharedFileListItemSetProperty")

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
        guard _insert(_SFL, _kLast, _Name as CFString, nil, _URL as CFURL, nil, nil) != nil else {
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

    // MARK: - Locations: items, state, and control

    // List-level property keys — verified via FavoriteVolumes.sfl4 inspection.
    // These control volume *categories* shown under Locations (Finder reads these from lsd).
    // Note: .servers uses ShowNetworkVolumes (confirmed in sfl4), NOT ShowConnectedServers.
    private static let _locKey: [LocationItem: String] = [
        .computer:    "com.apple.LSSharedFileList.FavoriteVolumes.ComputerIsVisible",
        .harddrives:  "com.apple.LSSharedFileList.FavoriteVolumes.ShowHardDrives",
        .external:    "com.apple.LSSharedFileList.FavoriteVolumes.ShowExternalVolumes",
        .cds:         "com.apple.LSSharedFileList.FavoriteVolumes.ShowEjectableVolumes",
        .bonjour:     "com.apple.LSSharedFileList.FavoriteVolumes.ShowBonjour",
        .servers:     "com.apple.LSSharedFileList.FavoriteVolumes.ShowNetworkVolumes",
        .cloudstorage:"com.apple.LSSharedFileList.FavoriteVolumes.ShowCloudStorage",
    ]

    // Special items that live as explicit items in the FavoriteVolumes snapshot.
    // Their SpecialItemIdentifier value (from sfl4) is listed here.
    // Visibility is controlled item-level via LSSharedFileListItemSetProperty(IsHidden),
    // NOT via the list-level ShowXxx keys (which Finder ignores for these items).
    private static let _specialId: [LocationItem: String] = [
        .airdrop: "com.apple.LSSharedFileList.IsMeetingRoom",
        .icloud:  "com.apple.LSSharedFileList.IsICloudDrive",
        .home:    "com.apple.LSSharedFileList.IsHome",
        .trash:   "com.apple.LSSharedFileList.IsTrash",
    ]

    enum LocationItem: String, CaseIterable {
        // Locations section
        case icloud       = "icloud"       // iCloud Drive
        case cloudstorage = "cloudstorage" // Third-party cloud (Dropbox, Nextcloud…)
        case home         = "home"         // Home folder (~/)
        case computer     = "computer"     // Mac itself (JonHa-MBP etc.)
        case harddrives   = "harddrives"   // Internal hard disks
        case external     = "external"     // External drives (USB, Thunderbolt)
        case cds          = "cds"          // CDs, DVDs, iOS devices
        case airdrop      = "airdrop"      // AirDrop
        case bonjour      = "bonjour"      // Bonjour computers
        case servers      = "servers"      // Connected network servers
        case trash        = "trash"        // Trash
        // Tags section
        case tags         = "tags"         // Recent Tags

        var label: String {
            switch self {
            case .icloud:       return "iCloud Drive"
            case .cloudstorage: return "Cloud storage (Nextcloud, Dropbox…)"
            case .home:         return "Home folder"
            case .computer:     return "Mac (computer icon)"
            case .harddrives:   return "Internal hard disks"
            case .external:     return "External disks"
            case .cds:          return "CDs, DVDs, iOS devices"
            case .airdrop:      return "AirDrop"
            case .bonjour:      return "Bonjour computers"
            case .servers:      return "Connected servers"
            case .trash:        return "Trash"
            case .tags:         return "Recent Tags section"
            }
        }
    }

    struct LocationsState {
        var icloud:       Bool
        var cloudstorage: Bool
        var home:         Bool
        var computer:     Bool
        var harddrives:   Bool
        var external:     Bool
        var cds:          Bool
        var airdrop:      Bool
        var bonjour:      Bool
        var servers:      Bool
        var trash:        Bool
        var tags:         Bool
    }

    func getLocations() -> LocationsState {
        func vol(_ _Item: LocationItem) -> Bool {
            if let _Id = SidebarManager._specialId[_Item] {
                return isVolItemEnabled(specialId: _Id)
            }
            guard let _Key = Self._locKey[_Item] else { return true }
            guard let _V = _copyProp(_SFLVol, _Key as CFString)?.takeRetainedValue() else { return true }
            return (_V as AnyObject).boolValue ?? true
        }
        let _TagsRaw = CFPreferencesCopyAppValue("ShowRecentTags" as CFString, "com.apple.finder" as CFString)
        let _Tags: Bool = _TagsRaw.map { ($0 as AnyObject).boolValue ?? true } ?? true
        return LocationsState(
            icloud:       vol(.icloud),
            cloudstorage: vol(.cloudstorage),
            home:         vol(.home),
            computer:     vol(.computer),
            harddrives:   vol(.harddrives),
            external:     vol(.external),
            cds:          vol(.cds),
            airdrop:      vol(.airdrop),
            bonjour:      vol(.bonjour),
            servers:      vol(.servers),
            trash:        vol(.trash),
            tags:         _Tags
        )
    }

    /// Human-readable Locations status table.
    func showLocations() {
        let _S = getLocations()
        let _Pairs: [(LocationItem, Bool)] = [
            (.icloud,       _S.icloud),
            (.cloudstorage, _S.cloudstorage),
            (.home,         _S.home),
            (.computer,     _S.computer),
            (.harddrives,   _S.harddrives),
            (.external,     _S.external),
            (.cds,          _S.cds),
            (.airdrop,      _S.airdrop),
            (.bonjour,      _S.bonjour),
            (.servers,      _S.servers),
            (.trash,        _S.trash),
            (.tags,         _S.tags),
        ]
        for (_Item, _Val) in _Pairs {
            let _Key  = _Item.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
            let _Flag = _Val ? "on " : "off"
            print("\(_Key) \(_Flag)  \(_Item.label)")
        }
    }

    /// Machine-readable JSON object.
    func showLocationsJSON() {
        let _S = getLocations()
        let _Parts = [
            "\"icloud\":\(_S.icloud)",
            "\"cloudstorage\":\(_S.cloudstorage)",
            "\"home\":\(_S.home)",
            "\"computer\":\(_S.computer)",
            "\"harddrives\":\(_S.harddrives)",
            "\"external\":\(_S.external)",
            "\"cds\":\(_S.cds)",
            "\"airdrop\":\(_S.airdrop)",
            "\"bonjour\":\(_S.bonjour)",
            "\"servers\":\(_S.servers)",
            "\"trash\":\(_S.trash)",
            "\"tags\":\(_S.tags)",
        ]
        print("{\(_Parts.joined(separator: ","))}")
    }

    /// Toggle a Locations item.
    /// - Parameter restartFinder: when true (default) kills Finder so the change
    ///   takes effect immediately; Finder relaunches automatically via launchd.
    func setLocation(item _Item: LocationItem, enabled _Enabled: Bool, restartFinder _Restart: Bool = true) throws {
        if _Item == .tags {
            let _Val: CFPropertyList = _Enabled ? kCFBooleanTrue! : kCFBooleanFalse!
            CFPreferencesSetAppValue("ShowRecentTags" as CFString, _Val, "com.apple.finder" as CFString)
            CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        } else if let _Id = Self._specialId[_Item] {
            // Special items (AirDrop, iCloud, Home, Trash) are explicit items in the
            // FavoriteVolumes snapshot — set IsHidden at item level, not list level.
            try setVolItemHidden(specialId: _Id, hidden: !_Enabled)
        } else {
            guard let _Key = Self._locKey[_Item] else {
                throw SidebarError.apiUnavailable("no property key for \(_Item.rawValue)")
            }
            let _Value: CFTypeRef = _Enabled ? kCFBooleanTrue! : kCFBooleanFalse!
            let _Status = _setProp(_SFLVol, _Key as CFString, _Value)
            guard _Status == 0 else {
                throw SidebarError.apiUnavailable("LSSharedFileListSetProperty failed: OSStatus \(_Status)")
            }
        }

        print("\(_Enabled ? "Enabled" : "Disabled"): \(_Item.rawValue)")

        if _Restart {
            SidebarManager.restartFinder()
        }
    }

    /// Restart Finder so pending Locations changes become visible.
    static func restartFinder() {
        let _Task = Process()
        _Task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        _Task.arguments = ["Finder"]
        try? _Task.run()
        _Task.waitUntilExit()
    }

    // MARK: - Private helpers

    /// Snapshot of the FavoriteVolumes list (Locations items).
    private func volSnapshot() -> [CFTypeRef] {
        var _Seed: UInt32 = 0
        guard let _Arr = _snapshot(_SFLVol, &_Seed) as? [CFTypeRef] else { return [] }
        return _Arr
    }

    /// Returns the FavoriteVolumes item whose SpecialItemIdentifier matches _Id,
    /// excluding permanently system-hidden items (ItemVisibility = NeverVisible).
    private func volItem(specialId _Id: String) -> CFTypeRef? {
        let _IdKey  = "com.apple.LSSharedFileList.SpecialItemIdentifier" as CFString
        let _VisKey = "com.apple.LSSharedFileList.ItemVisibility" as CFString
        return volSnapshot().first { _Item in
            guard let _Val = _itemCopyProp(_Item, _IdKey)?.takeRetainedValue() else { return false }
            guard (_Val as? String) == _Id else { return false }
            // Skip items that are permanently system-hidden
            if let _V = _itemCopyProp(_Item, _VisKey)?.takeRetainedValue(),
               (_V as? String) == "NeverVisible" {
                return false
            }
            return true
        }
    }

    /// Returns true if the special item is visible (IsHidden == false or not set).
    private func isVolItemEnabled(specialId _Id: String) -> Bool {
        guard let _Item = volItem(specialId: _Id) else { return true }
        guard let _Val = _itemCopyProp(_Item, "com.apple.LSSharedFileList.IsHidden" as CFString)?.takeRetainedValue() else {
            return true
        }
        return !((_Val as AnyObject).boolValue ?? false)
    }

    /// Sets or clears IsHidden on the matching special FavoriteVolumes item.
    private func setVolItemHidden(specialId _Id: String, hidden _Hidden: Bool) throws {
        guard let _Item = volItem(specialId: _Id) else {
            throw SidebarError.itemNotFound(_Id)
        }
        let _Val: CFTypeRef = _Hidden ? kCFBooleanTrue! : kCFBooleanFalse!
        let _Status = _itemSetProp(_Item, "com.apple.LSSharedFileList.IsHidden" as CFString, _Val)
        guard _Status == 0 else {
            throw SidebarError.apiUnavailable("LSSharedFileListItemSetProperty failed: OSStatus \(_Status)")
        }
    }

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
