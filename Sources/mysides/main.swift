import Foundation

let _Version = "1.0.5"
let _Args    = CommandLine.arguments

func printUsage() {
    let _Prog = (_Args[0] as NSString).lastPathComponent
    print("Usage: \(_Prog) <command> [arguments]")
    print("")
    print("Favourites commands:")
    print("  list [--json]                       List Finder sidebar favourites")
    print("  add <name> <file:///path>            Append a folder to the sidebar")
    print("  remove <name>                        Remove a sidebar item by name")
    print("")
    print("Locations commands:")
    print("  locations [--json]                   Show Locations section toggle states")
    print("  locations set <item> <on|off>        Toggle a Locations item")
    print("")
    print("  Location items: computer, harddrives, removable, network, tags")
    print("")
    print("Other:")
    print("  version                              Show version")
    print("")
    print("Examples:")
    print("  \(_Prog) list")
    print("  \(_Prog) list --json")
    print("  \(_Prog) add Projects file:///Users/\(NSUserName())/Projects")
    print("  \(_Prog) remove Projects")
    print("  \(_Prog) locations")
    print("  \(_Prog) locations --json")
    print("  \(_Prog) locations set harddrives off")
    print("  \(_Prog) locations set network on")
}

guard _Args.count >= 2 else {
    printUsage()
    exit(1)
}

do {
    switch _Args[1] {

    case "list":
        let _JSON    = _Args.contains("--json")
        let _Manager = try SidebarManager()
        if _JSON {
            _Manager.listJSON()
        } else {
            _Manager.list()
        }

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

    case "locations":
        if _Args.count >= 3 && _Args[2] == "set" {
            // locations set <item> <on|off>
            guard _Args.count >= 5 else {
                fputs("Error: 'locations set' requires <item> and <on|off>\n", stderr)
                fputs("Valid items: \(SidebarManager.LocationItem.allCases.map { $0.rawValue }.joined(separator: ", "))\n", stderr)
                exit(1)
            }
            let _ItemStr  = _Args[3]
            let _StateStr = _Args[4]

            guard let _Item = SidebarManager.LocationItem(rawValue: _ItemStr) else {
                fputs("Error: unknown location item '\(_ItemStr)'\n", stderr)
                fputs("Valid items: \(SidebarManager.LocationItem.allCases.map { $0.rawValue }.joined(separator: ", "))\n", stderr)
                exit(1)
            }
            guard _StateStr == "on" || _StateStr == "off" else {
                fputs("Error: state must be 'on' or 'off', got '\(_StateStr)'\n", stderr)
                exit(1)
            }

            let _Manager = try SidebarManager()
            try _Manager.setLocation(item: _Item, enabled: _StateStr == "on")

        } else {
            // locations [--json]
            let _JSON    = _Args.contains("--json")
            let _Manager = try SidebarManager()
            if _JSON {
                _Manager.showLocationsJSON()
            } else {
                _Manager.showLocations()
            }
        }

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
