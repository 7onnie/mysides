import Foundation

enum SidebarError: Error, LocalizedError {
    case invalidFormat(String)
    case itemNotFound(String)
    case pathNotFound(String)
    case notADirectory(String)
    case accessDenied
    case apiUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg):
            return "Invalid sidebar file format: \(msg)"
        case .itemNotFound(let name):
            return "No sidebar item found with name: \(name)"
        case .pathNotFound(let path):
            return "Path does not exist: \(path)"
        case .notADirectory(let path):
            return "Path is not a directory: \(path)"
        case .accessDenied:
            return """
            Access denied to sidebar file.
            macOS requires Full Disk Access for this operation.
            Fix: System Settings → Privacy & Security → Full Disk Access → enable Terminal
            """
        case .apiUnavailable(let detail):
            return "LSSharedFileList API unavailable: \(detail)"
        }
    }
}
