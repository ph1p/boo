// Terminal Inspector — showcase plugin demonstrating every external plugin feature.
//
// Features demonstrated:
//   - Every ctx field: cwd, processName, isRemote, envType, paneCount, tabCount, git, settings
//   - New ctx fields: terminalID, environmentLabel, remoteCwd, git.stagedCount/aheadCount/behindCount/lastCommitShort
//   - readFile() / fileExists() / listDir() / readJSON() / getEnv() / log() host functions
//   - ctx.settings from manifest declarations
//   - Every DSL element: vstack, hstack, list, button, badge, label, divider, spacer
//   - Every text style: bold, muted, mono
//   - Every tint: success, error, warning, accent, muted
//   - Every button style: primary, secondary, destructive
//   - Every action: exec, cd, open, copy, reveal, url, newTab, newPane, paste, notification
//   - Context menus on list items and buttons
//   - Menu contributions via onAction()

function render(ctx) {
  var dir = ctx.cwd.split("/").pop();
  var children = [];

  // ── Header ────────────────────────────────────────────────
  children.push({
    type: "hstack",
    children: [
      { type: "label", text: dir, style: "bold" },
      ctx.isRemote
        ? { type: "badge", text: ctx.envType, tint: "warning" }
        : { type: "badge", text: "local", tint: "success" }
    ]
  });
  children.push({ type: "label", text: ctx.cwd, style: "mono" });
  children.push({ type: "divider" });

  // ── Terminal context ──────────────────────────────────────
  children.push({ type: "label", text: "Terminal", style: "bold" });

  var terminalItems = [
    {
      label: ctx.processName || "(none)",
      icon: "terminal",
      detail: "Process",
      action: { type: "copy", text: ctx.processName || "" },
      contextMenu: [
        { label: "Copy process name", icon: "doc.on.doc", action: { type: "copy", text: ctx.processName || "" } }
      ]
    },
    { label: "" + ctx.paneCount, icon: "rectangle.split.2x1", detail: "Panes" },
    { label: "" + ctx.tabCount, icon: "rectangle.stack", detail: "Tabs" },
    { label: ctx.envType, icon: "globe", detail: "Environment" },
    { label: ctx.terminalID || "unknown", icon: "number", detail: "Terminal ID" },
    { label: ctx.environmentLabel || "local", icon: "tag", detail: "Environment Label" }
  ];
  if (ctx.remoteHost) {
    terminalItems.push({
      label: ctx.remoteHost,
      icon: "network",
      detail: "Remote host",
      tint: "warning",
      action: { type: "copy", text: ctx.remoteHost },
      contextMenu: [
        { label: "Copy hostname", icon: "doc.on.doc", action: { type: "copy", text: ctx.remoteHost } }
      ]
    });
  }
  if (ctx.remoteCwd) {
    terminalItems.push({
      label: ctx.remoteCwd,
      icon: "folder.badge.gearshape",
      detail: "Remote CWD"
    });
  }

  // Show EDITOR from getEnv
  var editor = getEnv("EDITOR");
  if (editor) {
    terminalItems.push({ label: editor, icon: "pencil", detail: "EDITOR" });
  }

  children.push({ type: "list", items: terminalItems });
  children.push({ type: "divider" });

  // ── Git section ───────────────────────────────────────────
  var showGit = !ctx.settings || ctx.settings.showGit !== false;
  if (showGit && ctx.git) {
    children.push({ type: "label", text: "Git", style: "bold" });
    var gitItems = [
      {
        label: ctx.git.branch,
        icon: "arrow.triangle.branch",
        detail: "Branch",
        tint: "accent",
        action: { type: "copy", text: ctx.git.branch },
        contextMenu: [
          { label: "Copy branch name", icon: "doc.on.doc", action: { type: "copy", text: ctx.git.branch } },
          { label: "Checkout", action: { type: "exec", command: "git checkout " + ctx.git.branch } }
        ]
      }
    ];
    if (ctx.git.isDirty) {
      gitItems.push({
        label: ctx.git.changedFileCount + " changed, " + ctx.git.stagedCount + " staged",
        icon: "pencil.circle",
        detail: "Working tree",
        tint: "warning"
      });
    } else {
      gitItems.push({
        label: "Clean",
        icon: "checkmark.circle",
        detail: "No changes",
        tint: "success"
      });
    }
    if (ctx.git.aheadCount > 0 || ctx.git.behindCount > 0) {
      gitItems.push({
        label: ctx.git.aheadCount + " ahead, " + ctx.git.behindCount + " behind",
        icon: "arrow.up.arrow.down",
        detail: "Remote tracking"
      });
    }
    if (ctx.git.lastCommitShort) {
      gitItems.push({
        label: ctx.git.lastCommitShort,
        icon: "clock",
        detail: "Last commit",
        action: { type: "copy", text: ctx.git.lastCommitShort }
      });
    }
    children.push({ type: "list", items: gitItems });
    children.push({ type: "divider" });
  }

  // ── File detection ────────────────────────────────────────
  var showFiles = !ctx.settings || ctx.settings.showFiles !== false;
  if (showFiles) {
    // Use listDir to show first 10 files
    var entries = listDir(".");
    if (entries && entries.length > 0) {
      children.push({
        type: "hstack",
        children: [
          { type: "label", text: "Directory Contents", style: "bold" },
          { type: "badge", text: "" + entries.length, tint: "muted" }
        ]
      });
      var items = entries.slice(0, 10).map(function (e) {
        return {
          label: e.name,
          icon: e.isDirectory ? "folder" : "doc",
          tint: e.isDirectory ? "accent" : null,
          action: e.isDirectory
            ? { type: "cd", path: ctx.cwd + "/" + e.name }
            : { type: "open", path: ctx.cwd + "/" + e.name },
          contextMenu: [
            { label: "Copy path", icon: "doc.on.doc", action: { type: "copy", text: ctx.cwd + "/" + e.name } },
            { label: "Reveal in Finder", icon: "folder", action: { type: "reveal", path: ctx.cwd + "/" + e.name } }
          ]
        };
      });
      children.push({ type: "list", items: items });
      if (entries.length > 10) {
        children.push({ type: "label", text: "... and " + (entries.length - 10) + " more", style: "muted" });
      }
      children.push({ type: "divider" });
    }

    // Use readJSON for package.json
    var pkg = readJSON("package.json");
    if (pkg) {
      children.push({ type: "label", text: "package.json", style: "bold" });
      children.push({
        type: "list",
        items: [
          { label: pkg.name || "unnamed", icon: "shippingbox", detail: "Name" },
          { label: pkg.version || "0.0.0", icon: "number", detail: "Version" }
        ]
      });
      children.push({ type: "divider" });
    }
  }

  // ── Actions ───────────────────────────────────────────────
  children.push({ type: "label", text: "Actions", style: "bold" });
  children.push({
    type: "hstack",
    children: [
      {
        type: "button",
        label: "Reveal",
        style: "primary",
        action: { type: "reveal", path: ctx.cwd },
        contextMenu: [
          { label: "Copy path", icon: "doc.on.doc", action: { type: "copy", text: ctx.cwd } },
          { label: "Open in editor", icon: "pencil", action: { type: "open", path: ctx.cwd } }
        ]
      },
      {
        type: "button",
        label: "Copy path",
        style: "secondary",
        action: { type: "copy", text: ctx.cwd }
      }
    ]
  });

  // New action types
  children.push({
    type: "hstack",
    children: [
      {
        type: "button",
        label: "New tab",
        style: "secondary",
        action: { type: "newTab", path: ctx.cwd }
      },
      {
        type: "button",
        label: "New pane",
        style: "secondary",
        action: { type: "newPane", path: ctx.cwd }
      }
    ]
  });
  children.push({
    type: "button",
    label: "Paste date",
    style: "secondary",
    action: { type: "paste", text: new Date().toISOString() }
  });

  children.push({ type: "spacer" });
  children.push({
    type: "button",
    label: "Reset terminal",
    style: "destructive",
    action: { type: "exec", command: "reset" }
  });

  log("Terminal Inspector rendered for " + dir);

  return { type: "vstack", children: children };
}

// Menu action handler — called when user clicks a plugin menu item
function onAction(name, ctx) {
  if (name === "copyCwd") return { type: "copy", text: ctx.cwd };
  if (name === "revealCwd") return { type: "reveal", path: ctx.cwd };
  if (name === "openReadme") {
    if (fileExists("README.md")) return { type: "open", path: ctx.cwd + "/README.md" };
    return { type: "notification", text: "No README.md found", title: "Terminal Inspector" };
  }
  return null;
}
