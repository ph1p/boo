function render(ctx) {
  var dir = ctx.cwd.split("/").pop();
  var items = [];

  // Detect project types by checking for key files
  var checks = [
    { file: "package.json", icon: "shippingbox", label: "Node.js" },
    { file: "Cargo.toml", icon: "hammer", label: "Rust" },
    { file: "go.mod", icon: "chevron.left.forwardslash.chevron.right", label: "Go" },
    { file: "Package.swift", icon: "swift", label: "Swift" },
    { file: "pyproject.toml", icon: "terminal", label: "Python" },
    { file: "Gemfile", icon: "diamond", label: "Ruby" },
    { file: "Makefile", icon: "hammer", label: "Makefile" },
    { file: "Dockerfile", icon: "shippingbox", label: "Docker" },
    { file: ".git", icon: "arrow.triangle.branch", label: "Git repo" },
    { file: "README.md", icon: "doc.text", label: "README" },
    { file: ".env", icon: "key", label: "Environment" },
    { file: "LICENSE", icon: "doc.badge.gearshape", label: "License" }
  ];

  for (var i = 0; i < checks.length; i++) {
    if (fileExists(checks[i].file)) {
      items.push({
        label: checks[i].label,
        icon: checks[i].icon,
        detail: checks[i].file,
        action: { type: "open", path: ctx.cwd + "/" + checks[i].file }
      });
    }
  }

  if (!items.length) {
    return { type: "label", text: "No project files detected", style: "muted" };
  }

  return {
    type: "vstack",
    children: [
      { type: "label", text: dir, style: "bold" },
      { type: "divider" },
      { type: "list", items: items }
    ]
  };
}
