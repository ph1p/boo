// Node Project — showcase plugin demonstrating every external plugin feature.
//
// Features demonstrated:
//   - readFile() / fileExists() host functions
//   - ctx.settings (plugin settings from manifest)
//   - ctx.git / ctx.cwd / ctx.processName context fields
//   - Every DSL element: vstack, hstack, list, button, badge, label, divider, spacer
//   - Every text style: bold, muted, mono
//   - Every tint: success, error, warning, accent, muted
//   - Every button style: primary, secondary, destructive
//   - Every action: exec, cd, open, copy, reveal
//   - Context menus on list items and buttons
//   - List items with icon, detail, tint, and action

function render(ctx) {
  var raw = readFile("package.json");
  if (!raw) {
    return { type: "label", text: "No package.json in this directory", style: "muted" };
  }

  var pkg = JSON.parse(raw);
  var pm = detectPM(pkg);
  var children = [];

  // ── Header ────────────────────────────────────────────────
  children.push({
    type: "hstack",
    children: [
      { type: "label", text: pkg.name || "unnamed", style: "bold" },
      { type: "badge", text: pkg.version || "0.0.0", tint: "accent" }
    ]
  });

  if (pkg.description) {
    children.push({ type: "label", text: pkg.description, style: "muted" });
  }

  // node_modules + lock file status
  children.push({
    type: "hstack",
    children: [
      fileExists("node_modules")
        ? { type: "badge", text: "installed", tint: "success" }
        : { type: "badge", text: "not installed", tint: "error" },
      fileExists(lockFileName(pm))
        ? { type: "badge", text: pm, tint: "muted" }
        : { type: "badge", text: "no lockfile", tint: "warning" }
    ]
  });

  children.push({ type: "divider" });

  // ── Scripts ───────────────────────────────────────────────
  var scripts = pkg.scripts || {};
  var scriptNames = Object.keys(scripts);
  if (scriptNames.length) {
    children.push({ type: "label", text: "Scripts", style: "bold" });
    children.push({
      type: "list",
      items: scriptNames.map(function (name) {
        return {
          label: name,
          icon: scriptIcon(name),
          detail: scripts[name],
          tint: scriptTint(name),
          action: { type: "exec", command: pm + " run " + name },
          contextMenu: [
            { label: "Run in terminal", icon: "play.fill", action: { type: "exec", command: pm + " run " + name } },
            { label: "Copy command", icon: "doc.on.doc", action: { type: "copy", text: pm + " run " + name } }
          ]
        };
      })
    });
    children.push({ type: "divider" });
  }

  // ── Dependencies ──────────────────────────────────────────
  var showDeps = !ctx.settings || ctx.settings.showDeps !== false;
  var showDevDeps = ctx.settings && ctx.settings.showDevDeps === true;
  var maxDeps = (ctx.settings && ctx.settings.maxDeps) || 10;

  if (showDeps) {
    children = children.concat(renderDeps(pkg.dependencies, "Dependencies", "shippingbox", "accent", maxDeps));
  }
  if (showDevDeps) {
    children = children.concat(renderDeps(pkg.devDependencies, "Dev Dependencies", "wrench", "warning", maxDeps));
  }

  // ── Quick actions ─────────────────────────────────────────
  children.push({ type: "label", text: "Quick Actions", style: "bold" });
  children.push({
    type: "hstack",
    children: [
      {
        type: "button",
        label: "Install",
        style: "primary",
        action: { type: "exec", command: pm + " install" },
        contextMenu: [
          { label: "Install (clean)", action: { type: "exec", command: "rm -rf node_modules && " + pm + " install" } },
          { label: "Update all", action: { type: "exec", command: pm + " update" } }
        ]
      },
      {
        type: "button",
        label: "Open",
        style: "secondary",
        action: { type: "open", path: ctx.cwd + "/package.json" }
      }
    ]
  });

  children.push({
    type: "list",
    items: [
      {
        label: "Reveal in Finder",
        icon: "folder",
        action: { type: "reveal", path: ctx.cwd },
        contextMenu: [
          { label: "Copy path", icon: "doc.on.doc", action: { type: "copy", text: ctx.cwd } },
          { label: "Open terminal here", icon: "terminal", action: { type: "cd", path: ctx.cwd } }
        ]
      }
    ]
  });

  // ── Destructive ───────────────────────────────────────────
  children.push({ type: "spacer" });
  children.push({
    type: "button",
    label: "Delete node_modules",
    style: "destructive",
    action: { type: "exec", command: "rm -rf node_modules && echo 'node_modules deleted'" }
  });

  return { type: "vstack", children: children };
}

// ── Helpers ───────────────────────────────────────────────────

function renderDeps(deps, title, icon, tint, max) {
  if (!deps) return [];
  var names = Object.keys(deps);
  if (!names.length) return [];

  var result = [];
  result.push({
    type: "hstack",
    children: [
      { type: "label", text: title, style: "bold" },
      { type: "badge", text: "" + names.length, tint: tint }
    ]
  });
  result.push({
    type: "list",
    items: names.slice(0, max).map(function (name) {
      return {
        label: name,
        icon: icon,
        detail: deps[name],
        action: { type: "copy", text: name },
        contextMenu: [
          { label: "Copy name", icon: "doc.on.doc", action: { type: "copy", text: name } },
          { label: "Copy with version", action: { type: "copy", text: name + "@" + deps[name] } }
        ]
      };
    })
  });
  if (names.length > max) {
    result.push({ type: "label", text: "+" + (names.length - max) + " more", style: "muted" });
  }
  result.push({ type: "divider" });
  return result;
}

function detectPM(pkg) {
  if (pkg.packageManager) {
    if (pkg.packageManager.indexOf("yarn") === 0) return "yarn";
    if (pkg.packageManager.indexOf("pnpm") === 0) return "pnpm";
    if (pkg.packageManager.indexOf("bun") === 0) return "bun";
  }
  if (fileExists("yarn.lock")) return "yarn";
  if (fileExists("pnpm-lock.yaml")) return "pnpm";
  if (fileExists("bun.lockb")) return "bun";
  return "npm";
}

function lockFileName(pm) {
  if (pm === "yarn") return "yarn.lock";
  if (pm === "pnpm") return "pnpm-lock.yaml";
  if (pm === "bun") return "bun.lockb";
  return "package-lock.json";
}

function scriptIcon(name) {
  if (name === "test" || name.indexOf("test") === 0) return "checkmark.circle";
  if (name === "build" || name.indexOf("build") === 0) return "hammer";
  if (name === "dev" || name === "start" || name === "serve") return "play.circle";
  if (name === "lint" || name.indexOf("lint") === 0) return "exclamationmark.triangle";
  if (name === "format" || name.indexOf("format") === 0) return "textformat";
  if (name === "deploy" || name.indexOf("deploy") === 0) return "arrow.up.circle";
  if (name === "clean") return "trash";
  return "terminal";
}

function scriptTint(name) {
  if (name === "test" || name.indexOf("test") === 0) return "success";
  if (name === "lint" || name.indexOf("lint") === 0) return "warning";
  if (name === "deploy" || name.indexOf("deploy") === 0) return "accent";
  return null;
}
