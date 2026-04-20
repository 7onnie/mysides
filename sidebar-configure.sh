#!/bin/zsh
# ──────────────────────────────────────────────────────────────────────────────
# sidebar-configure.sh
# Idempotent Finder sidebar configuration via mysides.
#
# Usage:
#   zsh sidebar-configure.sh
#
# Requirements:
#   mysides must be installed: brew install 7onnie/tap/mysides
# ──────────────────────────────────────────────────────────────────────────────

_MySides="${_MySides:-/opt/homebrew/bin/mysides}"
_User="${_User:-$(whoami)}"

# ── SIDEBAR FAVOURITES ────────────────────────────────────────────────────────
# Items listed here are ADDED if missing from the sidebar.
# Items currently in the sidebar that are NOT listed here are REMOVED.
# (Existing items keep their position; new items are appended.)
#
# _FavNames and _FavURLs must have the same number of entries.

typeset -a _FavNames=(
    "Projekte"
    "Downloads"
    "Repos"
)
typeset -a _FavURLs=(
    "file:///Users/${_User}/Projects"
    "file:///Users/${_User}/Downloads"
    "file:///Users/${_User}/Repos"
)

# ── LOCATIONS ─────────────────────────────────────────────────────────────────
# Set each item to "on" or "off". Leave a variable unset to leave it unchanged.

_LocICloud="off"          # iCloud Drive
_LocCloudStorage="off"    # Third-party cloud (Dropbox, Nextcloud…)
_LocHome="on"             # Home folder
_LocComputer="on"         # This Mac
_LocHardDrives="on"       # Internal hard disks
_LocExternal="on"         # External drives
_LocCDs="off"             # CDs, DVDs, iOS devices
_LocAirDrop="off"         # AirDrop
_LocBonjour="off"         # Bonjour computers
_LocServers="off"         # Connected servers
_LocTrash="on"            # Trash
_LocTags="off"            # Recent Tags

# ══════════════════════════════════════════════════════════════════════════════
# Logic — do not edit below this line
# ══════════════════════════════════════════════════════════════════════════════

_ok()  { print -- "  ✓ $*" }
_skip(){ print -- "  · $*" }
_run() { print -- "  → $*"; "$@" }

# ── Favourites ────────────────────────────────────────────────────────────────
print "\n=== Sidebar Favourites ==="

# Read current names from JSON
_CurrentJSON=$("${_MySides}" list --json 2>/dev/null) || {
    print "Error: mysides not found at ${_MySides}" >&2; exit 1
}

_CurrentNames=("${(@f)$(print "${_CurrentJSON}" | /usr/bin/python3 -c "
import json, sys
items = json.load(sys.stdin)
for item in items:
    print(item['name'])
")}")

# Remove items that are present but not in _FavNames
for _CurName in "${_CurrentNames[@]}"; do
    [[ -z "${_CurName}" ]] && continue
    _Found=0
    for _WantName in "${_FavNames[@]}"; do
        [[ "${_CurName}" == "${_WantName}" ]] && { _Found=1; break }
    done
    if (( _Found == 0 )); then
        _run "${_MySides}" remove "${_CurName}"
    else
        _skip "keep   ${_CurName}"
    fi
done

# Add items that are wanted but not present
for (( _I=1; _I<=${#_FavNames[@]}; _I++ )); do
    _WantName="${_FavNames[_I]}"
    _WantURL="${_FavURLs[_I]}"
    _Found=0
    for _CurName in "${_CurrentNames[@]}"; do
        [[ "${_CurName}" == "${_WantName}" ]] && { _Found=1; break }
    done
    if (( _Found == 0 )); then
        _run "${_MySides}" add "${_WantName}" "${_WantURL}"
    else
        _ok "present ${_WantName}"
    fi
done

# ── Locations ─────────────────────────────────────────────────────────────────
print "\n=== Locations ==="

_LocJSON=$("${_MySides}" locations --json 2>/dev/null)

_loc_current() {
    # Returns "true" or "false" for the given item key
    print "${_LocJSON}" | /usr/bin/python3 -c "
import json, sys
data = json.load(sys.stdin)
print(str(data.get('$1', None)).lower())
"
}

_loc_set() {
    local _Item="$1" _Want="$2"
    [[ -z "${_Want}" ]] && return          # unset → skip
    local _Current
    _Current=$(_loc_current "${_Item}")
    local _WantBool
    [[ "${_Want}" == "on" ]] && _WantBool="true" || _WantBool="false"
    if [[ "${_Current}" == "${_WantBool}" ]]; then
        _skip "${_Item} already ${_Want}"
    else
        _run "${_MySides}" locations set "${_Item}" "${_Want}"
    fi
}

_loc_set icloud        "${_LocICloud}"
_loc_set cloudstorage  "${_LocCloudStorage}"
_loc_set home          "${_LocHome}"
_loc_set computer      "${_LocComputer}"
_loc_set harddrives    "${_LocHardDrives}"
_loc_set external      "${_LocExternal}"
_loc_set cds           "${_LocCDs}"
_loc_set airdrop       "${_LocAirDrop}"
_loc_set bonjour       "${_LocBonjour}"
_loc_set servers       "${_LocServers}"
_loc_set trash         "${_LocTrash}"
_loc_set tags          "${_LocTags}"

print "\nDone.\n"
