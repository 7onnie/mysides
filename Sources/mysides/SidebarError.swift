import Foundation

enum SidebarError: Error, LocalizedError {
    case invalidFormat(String)
    case itemNotFound(String)
    case pathNotFound(String)
    case notADirectory(String)

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
        }
    }
}
