import Foundation

let _Version = "1.0.6"
let _Args    = CommandLine.arguments

func printUsage() {
    let _Prog = (_Args[0] as NSString).lastPathComponent
    print("Usage: \(_Prog) <command> [arguments]")
    print("")
    print("Favourites:")
    print("  list [--json]                         List Finder sidebar favourites")
    print("  add <name> <file:///path>              Append a folder to the sidebar")
    print("  remove <name>                          Remove a sidebar item by name")
    print("")
    print("Locations:")
    print("  locations [--json]                     Show all Locations toggle states")
    print("  locations set <item> <on|off>          Toggle a Locations item")
    print("  locations set <item> <on|off> --no-restart   Toggle without restarting Finder")
    print("  locations apply                        Restart Finder to apply pending changes")
    print("")
    print("  Items: icloud, cloudstorage, home, computer, harddrives,")
    print("         external, cds, airdrop, bonjour, servers, trash, tags")
    print("")
    print("Other:")
    print("  version                                Show version")
    print("")
    print("Examples:")
    print("  \(_Prog) list")
    print("  \(_Prog) list --json")
    print("  \(_Prog) add Projects file:///Users/\(NSUserName())/Projects")
    print("  \(_Prog) remove Projects")
    print("  \(_Prog) locations")
    print("  \(_Prog) locations --json")
    print("  \(_Prog) locations set airdrop off")
    print("  \(_Prog) locations set harddrives off --no-restart")
    print("  \(_Prog) locations set servers off --no-restart")
    print("  \(_Prog) locations apply")
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
        if _JSON { _Manager.listJSON() } else { _Manager.list() }

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
        if _Args.count >= 3 && _Args[2] == "apply" {
            // locations apply — restart Finder to make pending changes visible
            SidebarManager.restartFinder()
            print("Finder restarted.")

        } else if _Args.count >= 3 && _Args[2] == "set" {
            // locations set <item> <on|off> [--no-restart]
            guard _Args.count >= 5 else {
                fputs("Error: 'locations set' requires <item> and <on|off>\n", stderr)
                let _Valid = SidebarManager.LocationItem.allCases.map { $0.rawValue }.joined(separator: ", ")
                fputs("Valid items: \(_Valid)\n", stderr)
                exit(1)
            }
            let _ItemStr  = _Args[3]
            let _StateStr = _Args[4]

            guard let _Item = SidebarManager.LocationItem(rawValue: _ItemStr) else {
                let _Valid = SidebarManager.LocationItem.allCases.map { $0.rawValue }.joined(separator: ", ")
                fputs("Error: unknown location item '\(_ItemStr)'\nValid items: \(_Valid)\n", stderr)
                exit(1)
            }
            guard _StateStr == "on" || _StateStr == "off" else {
                fputs("Error: state must be 'on' or 'off', got '\(_StateStr)'\n", stderr)
                exit(1)
            }

            let _NoRestart = _Args.contains("--no-restart")
            let _Manager   = try SidebarManager()
            try _Manager.setLocation(item: _Item, enabled: _StateStr == "on", restartFinder: !_NoRestart)

        } else {
            // locations [--json]
            let _JSON    = _Args.contains("--json")
            let _Manager = try SidebarManager()
            if _JSON { _Manager.showLocationsJSON() } else { _Manager.showLocations() }
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
