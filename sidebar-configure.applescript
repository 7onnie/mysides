(*
    sidebar-configure.applescript
    Idempotent Finder sidebar configuration via mysides.

    Run via Script Editor (Cmd+R) or terminal:
        osascript sidebar-configure.applescript

    Requirements:
        mysides ≥ 1.0.11: brew install 7onnie/tap/mysides
*)

-- ── CONFIGURATION ─────────────────────────────────────────────────────────────

property _MySides : "/opt/homebrew/bin/mysides"

-- Desired sidebar favourites: {{"Display Name", "file:///path"}, ...}
-- Items listed here are ADDED if missing from the sidebar.
-- Items currently in the sidebar that are NOT listed here are REMOVED.
on getFavItems()
    set _User to do shell script "whoami"
    return { ¬
        {"Projekte",  "file:///Users/" & _User & "/Projects"},  ¬
        {"Downloads", "file:///Users/" & _User & "/Downloads"}, ¬
        {"Repos",     "file:///Users/" & _User & "/Repos"}      ¬
    }
end getFavItems

-- Desired location states: {{"item", "on"/"off"}, ...}
-- Remove a line to leave that item unchanged.
property _Locations : { ¬
    {"icloud",       "off"}, ¬
    {"cloudstorage", "off"}, ¬
    {"home",         "on"},  ¬
    {"computer",     "on"},  ¬
    {"harddrives",   "on"},  ¬
    {"external",     "on"},  ¬
    {"cds",          "off"}, ¬
    {"airdrop",      "off"}, ¬
    {"bonjour",      "off"}, ¬
    {"servers",      "off"}, ¬
    {"trash",        "on"},  ¬
    {"tags",         "off"}  ¬
}

-- ── LOGIC — do not edit below this line ───────────────────────────────────────

-- Returns true if _Name is in the desired favourites list
on favWanted(_Name, _FavItems)
    repeat with _Pair in _FavItems
        if item 1 of _Pair is _Name then return true
    end repeat
    return false
end favWanted

-- Runs a shell command and returns its output; logs errors without stopping
on shell(_Cmd)
    try
        return do shell script _Cmd
    on error _Err number _N
        log "shell error (" & _N & "): " & _Err
        return ""
    end try
end shell

-- ── FAVOURITES ─────────────────────────────────────────────────────────────────

log "=== Sidebar Favourites ==="

set _FavItems to getFavItems()

-- Read current favourite names from JSON output
set _JSON to shell(_MySides & " list --json")
set _CurrentNames to paragraphs of shell( ¬
    "echo " & quoted form of _JSON & ¬
    " | /usr/bin/python3 -c " & ¬
    quoted form of "import json,sys; [print(i['name']) for i in json.load(sys.stdin)]")

-- Remove items present in sidebar but NOT in desired list
repeat with _CurName in _CurrentNames
    if _CurName is not "" then
        if favWanted(_CurName, _FavItems) then
            log "· keep    " & _CurName
        else
            log "→ remove  " & _CurName
            shell(_MySides & " remove " & quoted form of (_CurName as string))
        end if
    end if
end repeat

-- Add items from desired list that are not yet in sidebar
repeat with _Pair in _FavItems
    set _WantName to item 1 of _Pair
    set _WantURL to item 2 of _Pair
    set _Found to false
    repeat with _CurName in _CurrentNames
        if (_CurName as string) is _WantName then
            set _Found to true
            exit repeat
        end if
    end repeat
    if _Found then
        log "✓ present " & _WantName
    else
        log "→ add     " & _WantName & "  " & _WantURL
        shell(_MySides & " add " & quoted form of _WantName & " " & _WantURL)
    end if
end repeat

-- ── LOCATIONS ──────────────────────────────────────────────────────────────────

log ""
log "=== Locations ==="

set _LocJSON to shell(_MySides & " locations --json")

-- Parse all location states once: "item:on\nitem:off\n..."
set _LocStates to shell( ¬
    "echo " & quoted form of _LocJSON & ¬
    " | /usr/bin/python3 -c " & ¬
    quoted form of "import json,sys; d=json.load(sys.stdin); [print(k+':'+('on' if v else 'off')) for k,v in d.items()]")

repeat with _Pair in _Locations
    set _Item to item 1 of _Pair
    set _Want to item 2 of _Pair

    -- Look up current state from pre-parsed list
    set _Current to "unknown"
    repeat with _Line in paragraphs of _LocStates
        if _Line starts with (_Item & ":") then
            set _Current to text ((length of _Item) + 2) thru -1 of _Line
            exit repeat
        end if
    end repeat

    if _Current is _Want then
        log "· skip    " & _Item & " already " & _Want
    else
        log "→ set     " & _Item & " " & _Want
        shell(_MySides & " locations set " & _Item & " " & _Want)
    end if
end repeat

log ""
log "Done."
