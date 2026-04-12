# Tab Type Selection & File Association System

**Date:** 2026-04-12  
**Status:** Approved

## Overview

Improve tab creation UX with type selection dropdown, expose tab types via plugin API, and enable markdown files to open in rendered preview tabs using ironmark.

## Goals

1. Plus button shows dropdown with Terminal/Browser options
2. Context menus (tab bar + terminal) include new tab type options
3. Plugin API provides unified `openTab(payload:)` method
4. Markdown files open in preview tab (configurable)
5. Ironmark integration for markdown rendering via static linking

## Architecture

### ContentType Enhancement

```swift
extension ContentType {
    /// User-creatable tab types shown in dropdown
    static var creatableTypes: [ContentType] { [.terminal, .browser] }
    
    /// Resolve content type for a file path based on extension
    static func forFile(_ path: String) -> ContentType? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "mdown", "mkd":
            return .markdownPreview
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "tiff", "tif", "ico", "svg":
            return .imageViewer
        default:
            return nil
        }
    }
}
```

### TabPayload Enum

```swift
enum TabPayload {
    case terminal(workingDirectory: String)
    case browser(url: URL)
    case file(path: String)  // auto-routes based on extension + settings
}
```

### Settings

```swift
enum MarkdownOpenMode: String, Codable, CaseIterable {
    case preview   // open in markdown tab (default)
    case editor    // open in terminal editor
    case external  // open in system default app
}
```

### Ironmark Integration

Static linking approach:
- C header: `Boo/Vendor/Ironmark/ironmark.h`
- Swift wrapper: `Boo/Vendor/Ironmark/Ironmark.swift`
- Link `libironmark.a` from `Vendor/ironmark/target/release/`

FFI:
```c
char *ironmark_parse(const char *input);
void ironmark_free(char *ptr);
```

### Plugin API

Add to `PluginActions`:
```swift
var openTab: ((TabPayload) -> Void)?
```

FileTree plugin calls `actions.openTab?(.file(path: path))` for markdown files.

## Files to Modify

| File | Action |
|------|--------|
| `Boo/Vendor/Ironmark/ironmark.h` | Create |
| `Boo/Vendor/Ironmark/Ironmark.swift` | Create |
| `Boo/Content/ContentType.swift` | Add `creatableTypes`, `forFile()` |
| `Boo/Plugin/TabPayload.swift` | Create |
| `Boo/Plugin/PluginActions.swift` | Add `openTab` |
| `Boo/Models/Settings.swift` | Add `MarkdownOpenMode` |
| `Boo/Views/PaneView+DragDrop.swift` | Plus button → menu |
| `Boo/Views/PaneView+TabBar.swift` | Add `showNewTabMenu` |
| `Boo/Ghostty/GhosttyView.swift` | Add new tab items to context menu |
| `Boo/Content/MarkdownPreviewContentView.swift` | Use Ironmark |
| `Boo/Plugins/FileTree/LocalFileTreePlugin.swift` | Route markdown via API |
| `Boo/Views/SettingsWindow.swift` | Add markdown picker |
| `Boo-Bridging-Header.h` | Import ironmark.h |
| Xcode project | Link libironmark.a, search paths |

## UI Behavior

- **Plus button**: Click shows NSMenu with Terminal/Browser options
- **Tab context menu**: Adds "New Terminal Tab" / "New Browser Tab" items
- **Terminal context menu**: Same new tab items after Flash
- **FileTree click**: Markdown files route through `openTab(.file)`, respects `markdownOpenMode` setting
