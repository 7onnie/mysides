import Foundation

let _Version = "1.0.4"
let _Args    = CommandLine.arguments

func printUsage() {
    let _Prog = (_Args[0] as NSString).lastPathComponent
    print("Usage: \(_Prog) <command> [arguments]")
    print("")
    print("Commands:")
    print("  list                        List all Finder sidebar favorites")
    print("  add <name> <file:///path>   Append a folder to the sidebar")
    print("  remove <name>               Remove a sidebar item by name")
    print("  version                     Show version")
    print("")
    print("Examples:")
    print("  \(_Prog) list")
    print("  \(_Prog) add Projects file:///Users/\(NSUserName())/Projects")
    print("  \(_Prog) remove Projects")
}

guard _Args.count >= 2 else {
    printUsage()
    exit(1)
}

do {
    switch _Args[1] {

    case "list":
        let _Manager = try SidebarManager()
        _Manager.list()

    case "add":
        guard _Args.count >= 4 else {
            fputs("Error: 'add' requires <name> and <file:///path>\n", stderr)
            printUsage()
            exit(1)
        }
        let _Name      = _Args[2]
        let _URIString = _Args[3]

        let _URL: URL
        if _URIString.hasPrefix("file://") {
            guard let _U = URL(string: _URIString) else {
                fputs("Error: invalid URI: \(_URIString)\n", stderr)
                exit(1)
            }
            _URL = _U
        } else {
            // Accept plain paths as a convenience in addition to file:// URIs.
            _URL = URL(fileURLWithPath: _URIString)
        }

        let _Manager = try SidebarManager()
        try _Manager.add(name: _Name, url: _URL)

    case "remove":
        guard _Args.count >= 3 else {
            fputs("Error: 'remove' requires <name>\n", stderr)
            printUsage()
            exit(1)
        }
        let _Manager = try SidebarManager()
        try _Manager.remove(name: _Args[2])

    case "version":
        print("mysides \(_Version)")

    default:
        fputs("Error: unknown command '\(_Args[1])'\n", stderr)
        printUsage()
        exit(1)
    }

} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(2)
}
