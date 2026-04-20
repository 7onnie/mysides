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
    // Item-level read (used to identify special items in the FavoriteVolumes snapshot)
    private typealias SFLItemCopyPropFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

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
            // Special items (AirDrop, iCloud, Home, Trash): Finder reads the top-level
            // `visibility` integer in sfl4 — write it directly, then reload sharedfilelistd.
            try SidebarManager.modifySfl4Visibility(specialId: _Id, visible: _Enabled)
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
            // Special items need sharedfilelistd to reload the sfl4 before Finder connects.
            if Self._specialId[_Item] != nil {
                SidebarManager.restartSharedFileListd()
            }
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

    /// Returns the FavoriteVolumes item whose SpecialItemIdentifier matches _Id.
    /// Items with visibility=1 (hidden) are filtered from the snapshot by lsd, so
    /// returning nil means the item is hidden (or missing).
    private func volItem(specialId _Id: String) -> CFTypeRef? {
        let _IdKey = "com.apple.LSSharedFileList.SpecialItemIdentifier" as CFString
        return volSnapshot().first { _Item in
            guard let _Val = _itemCopyProp(_Item, _IdKey)?.takeRetainedValue() else { return false }
            return (_Val as? String) == _Id
        }
    }

    /// Returns true if the special item is in the snapshot (visibility=0 = shown).
    /// Hidden items (visibility=1) are absent from the snapshot.
    private func isVolItemEnabled(specialId _Id: String) -> Bool {
        return volItem(specialId: _Id) != nil
    }

    /// Directly modifies the visibility field in FavoriteVolumes.sfl4 for the
    /// matching special item, then restarts sharedfilelistd so it reloads the file.
    ///
    /// Background: LSSharedFileListItemSetProperty only writes to CustomItemProperties,
    /// but Finder reads the top-level `visibility` integer field (0=shown, 1=hidden).
    /// The sfl4 file is owned by the current user and is directly writable via SSH /
    /// non-sandboxed CLI contexts. plistlib handles the NSKeyedArchiver binary format.
    private static func modifySfl4Visibility(specialId _Id: String, visible _Visible: Bool) throws {
        let _SflPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.FavoriteVolumes.sfl4")

        // Python script: modifies the top-level `visibility` integer for the matching item.
        // Uses plistlib which handles NSKeyedArchiver UID references natively.
        let _Script = #"""
import plistlib, sys
sfl, target_id, vis_arg = sys.argv[1], sys.argv[2], sys.argv[3]
visible = vis_arg == "1"
SPEC  = "com.apple.LSSharedFileList.SpecialItemIdentifier"
VIS   = "visibility"
CIP   = "CustomItemProperties"
ITVIS = "com.apple.LSSharedFileList.ItemVisibility"
with open(sfl, "rb") as f:
    data = plistlib.load(f)
objs = data["$objects"]
uid0 = uid1 = None
for i, obj in enumerate(objs):
    if type(obj) is int:
        if obj == 0 and uid0 is None: uid0 = i
        if obj == 1 and uid1 is None: uid1 = i
if uid0 is None:
    sys.exit("no int 0 in $objects")
if uid1 is None:
    objs.append(1); uid1 = len(objs) - 1
target_uid = uid0 if visible else uid1
root = objs[data["$top"]["root"].data]
for rk, rv in zip(root["NS.keys"], root["NS.objects"]):
    if objs[rk.data] == "items":
        items_arr = objs[rv.data]; break
else:
    sys.exit("items array not found")
changed = 0
for item_ref in items_arr["NS.objects"]:
    item = objs[item_ref.data]
    if "NS.keys" not in item: continue
    keys = [objs[k.data] for k in item["NS.keys"]]
    vals = item["NS.objects"]
    if VIS not in keys or CIP not in keys: continue
    cip = objs[vals[keys.index(CIP)].data]
    if "NS.keys" not in cip: continue
    ck = [objs[k.data] for k in cip["NS.keys"]]
    cv = cip["NS.objects"]
    if SPEC not in ck: continue
    if objs[cv[ck.index(SPEC)].data] != target_id: continue
    if ITVIS in ck and objs[cv[ck.index(ITVIS)].data] == "NeverVisible": continue
    vals[keys.index(VIS)] = plistlib.UID(target_uid)
    changed += 1
if changed == 0:
    sys.exit("item not found: " + target_id)
with open(sfl, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
"""#

        let _TmpPath = "/tmp/mysides_sfl4_\(UUID().uuidString).py"
        guard (try? _Script.write(toFile: _TmpPath, atomically: true, encoding: .utf8)) != nil else {
            throw SidebarError.apiUnavailable("failed to write temp script")
        }
        defer { try? FileManager.default.removeItem(atPath: _TmpPath) }

        let _Task = Process()
        _Task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        _Task.arguments = [_TmpPath, _SflPath, _Id, _Visible ? "1" : "0"]
        let _Pipe = Pipe()
        _Task.standardOutput = _Pipe
        _Task.standardError  = _Pipe
        try _Task.run()
        _Task.waitUntilExit()

        if _Task.terminationStatus != 0 {
            let _Out = String(data: _Pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw SidebarError.apiUnavailable("sfl4 modification failed: \(_Out)")
        }
    }

    /// Restarts the per-user sharedfilelistd so it reloads the sfl4 from disk.
    /// launchd brings it back automatically; we wait briefly before restarting Finder.
    static func restartSharedFileListd() {
        let _UID = String(getuid())

        // Preferred: ask launchd to kill-and-restart the service (no privilege needed
        // for own GUI-domain services).
        let _Kick = Process()
        _Kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        _Kick.arguments = ["kickstart", "-k",
                           "gui/\(_UID)/com.apple.coreservices.sharedfilelistd"]
        try? _Kick.run()
        _Kick.waitUntilExit()

        // Fallback: direct SIGKILL if kickstart had no effect (process still owns it).
        let _Kill = Process()
        _Kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        _Kill.arguments = ["-9", "-u", _UID, "sharedfilelistd"]
        try? _Kill.run()
        _Kill.waitUntilExit()

        // Give launchd ~1.5 s to restart sharedfilelistd before Finder connects.
        Thread.sleep(forTimeInterval: 1.5)
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
