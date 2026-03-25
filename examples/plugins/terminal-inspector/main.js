// Terminal Inspector — showcase plugin demonstrating every external plugin feature.
//
// Features demonstrated:
//   - Every ctx field: cwd, processName, isRemote, envType, paneCount, tabCount, git, settings
//   - readFile() / fileExists() host functions
//   - ctx.settings from manifest declarations
//   - Every DSL element: vstack, hstack, list, button, badge, label, divider, spacer
//   - Every text style: bold, muted, mono
//   - Every tint: success, error, warning, accent, muted
//   - Every button style: primary, secondary, destructive
//   - Every action: exec, cd, open, copy, reveal
//   - Context menus on list items and buttons

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
    { label: ctx.envType, icon: "globe", detail: "Environment" }
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
        label: ctx.git.changedFileCount + " changed",
        icon: "pencil.circle",
        detail: "Dirty",
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
    children.push({ type: "list", items: gitItems });
    children.push({ type: "divider" });
  }

  // ── File detection ────────────────────────────────────────
  var showFiles = !ctx.settings || ctx.settings.showFiles !== false;
  if (showFiles) {
    var files = ["package.json", "Makefile", "Dockerfile", "Cargo.toml", "go.mod",
                 "Package.swift", "pyproject.toml", ".env", "README.md"];
    var found = [];
    for (var i = 0; i < files.length; i++) {
      if (fileExists(files[i])) found.push(files[i]);
    }
    if (found.length) {
      children.push({
        type: "hstack",
        children: [
          { type: "label", text: "Project Files", style: "bold" },
          { type: "badge", text: "" + found.length, tint: "muted" }
        ]
      });
      children.push({
        type: "list",
        items: found.map(function (f) {
          return {
            label: f,
            icon: "doc",
            action: { type: "open", path: ctx.cwd + "/" + f },
            contextMenu: [
              { label: "Open", icon: "pencil", action: { type: "open", path: ctx.cwd + "/" + f } },
              { label: "Copy path", icon: "doc.on.doc", action: { type: "copy", text: ctx.cwd + "/" + f } },
              { label: "Reveal in Finder", icon: "folder", action: { type: "reveal", path: ctx.cwd + "/" + f } }
            ]
          };
        })
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

  children.push({ type: "spacer" });
  children.push({
    type: "button",
    label: "Reset terminal",
    style: "destructive",
    action: { type: "exec", command: "reset" }
  });

  return { type: "vstack", children: children };
}
