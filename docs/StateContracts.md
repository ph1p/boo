# Boo State Architecture Contracts

This document defines the single source of truth for each piece of state in the Boo application, along with invariants and sync rules.

## State Hierarchy

```
AppState (workspace container)
  └─ Workspace[] (folder-based)
      └─ SplitTree (layout binary tree)
          └─ Pane[] (tab container)
              └─ Tab[] + TabState (per-tab state)

Parallel State:
├─ AppSettings (singleton, persisted)
├─ AppStore (observable projection for SwiftUI)
├─ TerminalBridge + BridgeState (live snapshot)
├─ WindowStateCoordinator (sync coordinator)
└─ PluginRegistry (plugin lifecycle)
```

## Single Source of Truth Rules

| Data | Source of Truth | Persistence | Sync Rule |
|------|-----------------|-------------|-----------|
| **Working Directory** | BridgeState (live) | TabState | Sync to TabState on tab switch |
| **Remote Session** | BridgeState (live) | NOT persisted | Re-detected on restore via process tree |
| **Remote CWD** | BridgeState (live) | TabState | Sync to TabState on tab switch |
| **Foreground Process** | BridgeState (live) | TabState | Sync to TabState on tab switch |
| **Shell PID** | TabState | SessionStore | Set once on terminal creation |
| **Terminal Title** | BridgeState (live) | TabState | Sync to TabState on tab switch |
| **Agent Session ID** | TabState | SessionStore | Updated by plugin detection |
| **Plugin Expanded IDs** | WindowStateCoordinator | TabState (if !sidebarGlobalState) | Sync on tab switch |
| **Section Heights** | DetailPanelView | AppSettings.__sidebar | Sync on panel switch, app quit |
| **Section Order** | WindowStateCoordinator | AppSettings.__sidebar | Sync on reorder, app quit |
| **Scroll Offsets** | DetailPanelView | TabState | Sync on tab switch |
| **Active Plugin Tab** | WindowStateCoordinator | TabState (if !sidebarGlobalState) | Sync on tab switch |
| **Theme** | AppSettings | UserDefaults + file | Immediate |
| **Sidebar Width** | AppSettings | UserDefaults + file | Immediate |
| **Sidebar Visible** | MainWindowController | NOT persisted | Runtime only |

## State Invariants

### BridgeState Invariants
1. `BridgeState.paneID` always matches the focused pane
2. `BridgeState.workingDirectory` is authoritative for CWD of focused pane
3. `BridgeState.remoteSession` is authoritative for remote detection of focused pane
4. Bridge state MUST be synced to TabState before tab switch via `syncBridgeToTab()`

### TabState Invariants
1. TabState is the persistence layer — bridge is live, tab is saved
2. Remote session is intentionally NOT restored from persistence (re-detected)
3. Plugin UI state only saved per-tab when `sidebarGlobalState == false`

### AppSettings Invariants
1. Changes emit `Notification.Name.settingsChanged` with optional topic
2. Settings are persisted to both UserDefaults AND `~/.boo/settings.json`
3. Plugin settings use namespace: `pluginSettings[pluginID][key]`
4. Internal sidebar state uses reserved namespace: `pluginSettings["__sidebar"]`

### Sidebar State Invariants
1. Section heights persist across app restarts via AppSettings
2. Section order persists across app restarts via AppSettings
3. Scroll offsets are per-terminal, cleaned up when terminal closes
4. When `sidebarGlobalState == true`, sidebar state is independent of tabs

## Sync Points

### Tab Switch
```
1. syncBridgeToTab(previousPane, previousTabIndex)  // Save bridge → tab
2. savePluginState(previousPane, previousTabIndex)  // Save plugin UI → tab
3. restorePluginState(newTab)                       // Restore plugin UI ← tab
4. bridge.restoreTabState(...)                      // Restore bridge ← tab
```

### App Quit
```
1. For each workspace:
   a. syncBridgeToTab(activePane, activeTabIndex)
   b. savePluginState(activePane, activeTabIndex)
2. saveSidebarHeightsToSettings()
3. saveSidebarOrderToSettings()
4. SessionStore.save(appState)
```

### Panel Switch
```
1. Save current panel heights to AppSettings
2. Save current panel order to AppSettings
```

### Terminal Close
```
1. cleanupScrollOffsets(terminalID)  // Remove stale scroll data
2. RemoteSessionMonitor.untrack(paneID)
```

## Anti-Patterns to Avoid

1. **Reading TabState for live data** — Always use BridgeState for focused pane
2. **Forgetting syncBridgeToTab()** — Must call before saving/switching
3. **Direct plugin state access** — Use WindowStateCoordinator methods
4. **Persisting remote session** — Should always re-detect
5. **Storing heights only in DetailPanelView** — Must sync to AppSettings

## Controller Responsibilities

| Controller | Responsibility |
|------------|---------------|
| **MainWindowController** | Window lifecycle, menu actions, high-level coordination |
| **SidebarController** | Panel visibility, tab selection, heights sync |
| **PluginCycleController** | runPluginCycle, context building |
| **TerminalController** | Terminal lifecycle, focus management |
| **IPCController** | Socket command handling |
| **WindowStateCoordinator** | Bridge↔Tab sync, plugin state save/restore |

## Migration Notes

### From v1 (pre-refactor)
- Section heights were runtime-only → now persisted
- Section order was runtime-only → now persisted
- MainWindowController was monolithic → now split into controllers
