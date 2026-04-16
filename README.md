# mysides

A command-line tool for managing the macOS Finder sidebar favorites — updated for modern macOS.

This is a Swift rewrite of the original [mosen/mysides](https://github.com/mosen/mysides) by Eamon Brosnan.
The original used the `LSSharedFileList` API, which was deprecated in macOS 10.10 and **removed in macOS 12**.
This rewrite reads and writes the `.sfl4` sidebar file directly using `NSKeyedArchiver`, without any deprecated API.

## Requirements

- macOS 13 or later
- Apple Silicon or Intel

## Installation

### Homebrew (recommended)

```sh
brew install 7onnie/tap/mysides
```

### Build from source

Requires Swift 5.9+ (included with Xcode Command Line Tools).

```sh
git clone https://github.com/7onnie/mysides.git
cd mysides
swift build -c release
cp .build/release/mysides /usr/local/bin/
```

## Usage

```sh
# List all sidebar favorites
mysides list

# Add a folder (name can differ from the folder name)
mysides add Projects file:///Users/you/Projects

# Remove a sidebar item by name
mysides remove Projects

# Show version
mysides version
```

### Example output

```
Applications  -> file:///Applications/
Downloads     -> file:///Users/you/Downloads/
Projects      -> file:///Users/you/Projects/
Desktop       -> file:///Users/you/Desktop/
Documents     -> file:///Users/you/Documents/
```

## How it works

The Finder sidebar favorites are stored in:

```
~/Library/Application Support/com.apple.sharedfilelist/
  com.apple.LSSharedFileList.FavoriteItems.sfl4
```

This is a binary NSKeyedArchiver file. Each entry contains Apple Bookmark data
(the modern replacement for aliases) plus a UUID and visibility flag.
`mysides` decodes this file, applies the requested change, re-encodes it atomically,
and sends a distributed notification so Finder reloads without restarting.

## Supported formats

| Format | macOS version |
|--------|--------------|
| `.sfl4` | macOS 15+ |
| `.sfl3` | macOS 13–14 |
| `.sfl2` | macOS 10.11–12 |

## License

MIT — see [LICENSE](LICENSE).

Original work © 2016 Eamon Brosnan · Rewrite © 2026 Jonas Haderer
