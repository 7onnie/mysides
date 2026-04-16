import Foundation
import Darwin

// Manages the Finder sidebar favorites via the private LSSharedFileList API
// loaded at runtime through dlopen/dlsym.
//
// Although LSSharedFileList was removed from Apple's public headers in macOS 12,
// the implementation is still present in CoreServices and communicates internally
// via the LaunchServices daemon (lsd) over XPC.  Because the actual file access
// happens inside a system daemon, TCC restrictions on
// ~/Library/Application Support/com.apple.sharedfilelist/ do not apply to the
// calling process — no Full Disk Access required.
//
// Note: kLSSharedFileListItemLast is a magic sentinel value (0x2), not a real
// CF object.  It must be stored as OpaquePointer (no ARC) and the insert function
// signature uses OpaquePointer? for the "after item" parameter so Swift never
// tries to retain it.
class SidebarManager {

    // MARK: - Private C function types

    private typealias SFLCreateFn   = @convention(c) (CFAllocator?, CFString,  CFTypeRef?) -> CFTypeRef?
    private typealias SFLSnapshotFn = @convention(c) (CFTypeRef, UnsafeMutablePointer<UInt32>) -> CFArray?
    private typealias SFLNameFn     = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    private typealias SFLURLFn      = @convention(c) (CFTypeRef, UInt32, UnsafeMutablePointer<CFTypeRef?>?) -> Unmanaged<CFURL>?
    // Second parameter is OpaquePointer? (not CFTypeRef?) because kLSSharedFileListItemLast = 0x2,
    // a sentinel integer — not a real heap object.  Using CFTypeRef? here would cause Swift ARC
    // to call swift_unknownObjectRetain(0x2) → immediate segfault.
    private typealias SFLInsertFn   = @convention(c) (CFTypeRef, OpaquePointer?, CFString?, CFTypeRef?, CFURL, CFDictionary?, CFArray?) -> CFTypeRef?
    private typealias SFLRemoveFn   = @convention(c) (CFTypeRef, CFTypeRef) -> OSStatus

    // MARK: - Loaded symbols

    private let _SFL:      CFTypeRef      // LSSharedFileListRef for FavoriteItems
    private let _kLast:    OpaquePointer  // kLSSharedFileListItemLast (sentinel value 0x2, not an object)
    private let _snapshot: SFLSnapshotFn
    private let _getName:  SFLNameFn
    private let _getURL:   SFLURLFn
    private let _insert:   SFLInsertFn
    private let _remove:   SFLRemoveFn

    // Flag values hardcoded from the old public header (never changed in any macOS version)
    private static let _NoUserInteraction: UInt32 = 1
    private static let _DoNotMount:        UInt32 = 2
    private static let _ResolveFlags:      UInt32 = _NoUserInteraction | _DoNotMount

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

        guard let _KFavPtr = dlsym(_Handle, "kLSSharedFileListFavoriteItems") else {
            throw SidebarError.apiUnavailable("symbol not found: kLSSharedFileListFavoriteItems")
        }
        // kLSSharedFileListFavoriteItems is a CFString global — dereference the pointer once
        let _KFav = _KFavPtr.assumingMemoryBound(to: CFString.self).pointee

        guard let _KLastPtr = dlsym(_Handle, "kLSSharedFileListItemLast") else {
            throw SidebarError.apiUnavailable("symbol not found: kLSSharedFileListItemLast")
        }
        // kLSSharedFileListItemLast stores the raw sentinel 0x2.  Read it as a UInt (pointer-width
        // integer) and wrap in OpaquePointer so Swift never applies ARC to this non-object value.
        let _KLastRaw = _KLastPtr.assumingMemoryBound(to: UInt.self).pointee
        guard let _KLastOpaque = OpaquePointer(bitPattern: _KLastRaw) else {
            throw SidebarError.apiUnavailable("kLSSharedFileListItemLast is zero")
        }
        _kLast = _KLastOpaque

        guard let _SFLRef = _create(nil, _KFav, nil) else {
            throw SidebarError.apiUnavailable("LSSharedFileListCreate returned nil")
        }
        _SFL = _SFLRef

        // dlclose intentionally omitted: the framework stays loaded for the lifetime
        // of the process, which is fine for a short-lived CLI tool.
    }

    // MARK: - Public API

    func list() {
        let _Items = snapshot()
        if _Items.isEmpty {
            print("(no items)")
            return
        }
        for _Item in _Items {
            let _Name = displayName(for: _Item)
            let _URL  = resolvedURL(for: _Item)?.absoluteString ?? "NOTFOUND"
            print("\(_Name) -> \(_URL)")
        }
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
}
