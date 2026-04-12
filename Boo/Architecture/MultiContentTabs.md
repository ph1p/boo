# Multi-Content Tabs — Architecture

## Overview

Tabs support multiple content types: terminal, browser, editor, image viewer, markdown preview.
Default is terminal. Content types are mixable within a single pane.

## Content Types

```swift
enum ContentType: String, Codable {
    case terminal
    case browser
    case editor
    case imageViewer
    case markdownPreview
}
```

## Core Abstractions

### 1. ContentView Protocol

Replaces direct `GhosttyView` coupling. Each content type implements this.

```swift
protocol ContentView: NSView {
    var contentType: ContentType { get }
    
    // Lifecycle
    func activate()
    func deactivate()
    func cleanup()
    
    // State
    func saveState() -> ContentState
    func restoreState(_ state: ContentState)
    
    // Events (optional — not all content types emit all events)
    var onTitleChanged: ((String) -> Void)? { get set }
    var onFocused: (() -> Void)? { get set }
}
```

Concrete implementations:
- `TerminalContentView` — wraps `GhosttyView`
- `BrowserContentView` — wraps `WKWebView`
- `EditorContentView` — wraps text editor view
- `ImageContentView` — wraps image view
- `MarkdownContentView` — wraps rendered markdown view

### 2. ContentState Protocol

Replaces terminal-specific `BridgeState`. Each content type defines its state.

```swift
protocol ContentState: Codable {
    var contentType: ContentType { get }
    var title: String { get }
}

// Terminal-specific
struct TerminalState: ContentState {
    let contentType: ContentType = .terminal
    var title: String
    var workingDirectory: String
    var remoteSession: RemoteSessionType?
    var remoteWorkingDirectory: String?
    var shellPID: pid_t
    var foregroundProcess: String
}

// Browser-specific
struct BrowserState: ContentState {
    let contentType: ContentType = .browser
    var title: String
    var url: URL
    var canGoBack: Bool
    var canGoForward: Bool
}

// Editor-specific
struct EditorState: ContentState {
    let contentType: ContentType = .editor
    var title: String
    var filePath: String?
    var isDirty: Bool
    var cursorPosition: (line: Int, column: Int)
}

// Image viewer
struct ImageViewerState: ContentState {
    let contentType: ContentType = .imageViewer
    var title: String
    var filePath: String
    var zoom: CGFloat
}

// Markdown preview
struct MarkdownPreviewState: ContentState {
    let contentType: ContentType = .markdownPreview
    var title: String
    var filePath: String
    var scrollPosition: CGFloat
}
```

### 3. ContentBridge Protocol

Replaces `TerminalBridge`. Abstracts content-specific event handling.

```swift
protocol ContentBridge: AnyObject {
    var contentType: ContentType { get }
    var state: ContentState { get }
    var events: PassthroughSubject<ContentEvent, Never> { get }
    
    func restoreState(_ state: ContentState)
    func focus()
}

enum ContentEvent {
    case titleChanged(String)
    case stateChanged(ContentState)
    case focused
    // Terminal-specific (wrapped)
    case terminal(TerminalEvent)
    // Browser-specific
    case browser(BrowserEvent)
}
```

## TabState Changes

```swift
struct TabState {
    // NEW: Content type identifier
    var contentType: ContentType = .terminal
    
    // NEW: Type-erased content state (replaces terminal-specific fields)
    var contentState: ContentState
    
    // KEPT: Plugin UI state (already generic)
    var expandedPluginIDs: Set<String> = []
    var userCollapsedSectionIDs: Set<String> = []
    var sidebarSectionHeights: [String: CGFloat] = [:]
    var sidebarScrollOffsets: [String: CGPoint] = [:]
    var sidebarSectionOrder: [String: [String]] = [:]
    var selectedPluginTabID: String? = nil
}
```

### Migration Path

For backwards compatibility, existing terminal-specific fields become computed properties that delegate to `contentState` when it's `TerminalState`:

```swift
extension TabState {
    var workingDirectory: String {
        get { (contentState as? TerminalState)?.workingDirectory ?? "~" }
        set { if var ts = contentState as? TerminalState { ts.workingDirectory = newValue; contentState = ts } }
    }
    // ... same pattern for remoteSession, shellPID, etc.
}
```

## WindowStateCoordinator Changes

```swift
final class WindowStateCoordinator {
    // CHANGE: Generic bridge type
    private var contentBridges: [UUID: ContentBridge] = [:]  // per-tab bridges
    
    // CHANGE: Bridge factory
    func createBridge(for contentType: ContentType) -> ContentBridge {
        switch contentType {
        case .terminal: return TerminalContentBridge()
        case .browser: return BrowserContentBridge()
        // ...
        }
    }
    
    // KEPT: Plugin state management (already generic)
    func savePluginState(to pane: Pane, tabIndex: Int)
    func restorePluginState(from tab: Pane.Tab)
}
```

## PaneView Changes

```swift
final class PaneView {
    // CHANGE: Generic content view cache
    private var contentViews: [UUID: ContentView] = [:]  // replaces tabViews: [UUID: GhosttyView]
    
    // CHANGE: Content view factory
    func createContentView(for type: ContentType) -> ContentView {
        switch type {
        case .terminal: return TerminalContentView()
        case .browser: return BrowserContentView()
        // ...
        }
    }
}
```

## Tab Bar Changes

Tab bar shows content-type-specific icon for each tab:

```swift
extension ContentType {
    var icon: NSImage {
        switch self {
        case .terminal: return NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminal")!
        case .browser: return NSImage(systemSymbolName: "globe", accessibilityDescription: "Browser")!
        case .editor: return NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Editor")!
        case .imageViewer: return NSImage(systemSymbolName: "photo", accessibilityDescription: "Image")!
        case .markdownPreview: return NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: "Markdown")!
        }
    }
}
```

## Auto-Detection

```swift
struct ContentTypeDetector {
    static func detect(from input: String) -> ContentType? {
        // URL detection
        if let url = URL(string: input), url.scheme?.hasPrefix("http") == true {
            return .browser
        }
        
        // File path detection
        if FileManager.default.fileExists(atPath: input) {
            let ext = (input as NSString).pathExtension.lowercased()
            switch ext {
            case "png", "jpg", "jpeg", "gif", "webp", "svg":
                return .imageViewer
            case "md", "markdown":
                return .markdownPreview
            default:
                return nil  // Don't auto-detect editor (too generic)
            }
        }
        
        return nil
    }
}
```

## Settings

```swift
extension AppSettings {
    // Default content type for new tabs
    @UserDefault("defaultTabType", defaultValue: "terminal")
    var defaultTabType: String
    
    var defaultContentType: ContentType {
        ContentType(rawValue: defaultTabType) ?? .terminal
    }
    
    // Auto-detection toggle
    @UserDefault("autoDetectContentType", defaultValue: true)
    var autoDetectContentType: Bool
}
```

## Menu Items

```
File
├── New Terminal Tab     ⌘T
├── New Browser Tab      ⌘⇧T
├── New Editor Tab       ⌘⇧E
└── ...
```

## Sidebar Behavior

- **Terminal tabs**: Full plugin cycle runs, sidebar shows all plugins
- **Non-terminal tabs**: Sidebar visible, shows placeholder "No plugins for [content type]"
- **Future**: Content-type-specific plugins (e.g., "Bookmarks" for browser, "Outline" for editor)

### Plugin Context Extension

```swift
// Current: TerminalContext
// Future: Generic ContentContext

protocol ContentContext {
    var contentType: ContentType { get }
    var title: String { get }
}

struct TerminalContext: ContentContext {
    let contentType: ContentType = .terminal
    var title: String
    var workingDirectory: String
    // ... existing fields
}

struct BrowserContext: ContentContext {
    let contentType: ContentType = .browser
    var title: String
    var url: URL
}
```

## Implementation Order

1. **Phase 1: Abstraction Layer**
   - Add `ContentType` enum
   - Create `ContentView` protocol
   - Create `ContentState` protocol
   - Wrap `GhosttyView` in `TerminalContentView`
   - Wrap `TerminalBridge` in `TerminalContentBridge`
   - Refactor `TabState` with backwards-compatible computed properties

2. **Phase 2: Browser Tab**
   - Implement `BrowserContentView` (WKWebView wrapper)
   - Implement `BrowserContentBridge`
   - Add menu item "New Browser Tab"
   - Add URL auto-detection

3. **Phase 3: Additional Content Types**
   - Editor tab
   - Image viewer tab
   - Markdown preview tab

4. **Phase 4: Content-Type Plugins**
   - Extend plugin protocol for content-type filtering
   - Browser-specific plugins (bookmarks, history)
   - Editor-specific plugins (outline, symbols)

## Files to Modify

| File | Changes |
|------|---------|
| `Models/Pane.swift` | Add `ContentType`, refactor `TabState` |
| `Models/Settings.swift` | Add `defaultTabType`, `autoDetectContentType` |
| `Ghostty/GhosttyView.swift` | Extract to `TerminalContentView` wrapper |
| `Services/TerminalBridge.swift` | Extract to `TerminalContentBridge` wrapper |
| `App/WindowStateCoordinator.swift` | Generic `ContentBridge` handling |
| `Views/PaneView.swift` | Generic `ContentView` cache |
| `Views/PaneView+TabBar.swift` | Content-type icons |
| `App/MainWindowController.swift` | Menu items for new tab types |

## New Files

| File | Purpose |
|------|---------|
| `Content/ContentType.swift` | Enum + icon extension |
| `Content/ContentView.swift` | Protocol definition |
| `Content/ContentState.swift` | Protocol + concrete types |
| `Content/ContentBridge.swift` | Protocol definition |
| `Content/TerminalContentView.swift` | GhosttyView wrapper |
| `Content/TerminalContentBridge.swift` | TerminalBridge wrapper |
| `Content/BrowserContentView.swift` | WKWebView wrapper |
| `Content/BrowserContentBridge.swift` | Browser state/events |
| `Content/ContentTypeDetector.swift` | Auto-detection logic |
