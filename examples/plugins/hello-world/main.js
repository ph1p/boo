function render(ctx) {
  var dir = ctx.cwd.split("/").pop();
  return {
    type: "vstack",
    children: [
      { type: "label", text: "Hello from " + dir, style: "bold" },
      { type: "label", text: ctx.cwd, style: "muted" },
      { type: "divider" },
      { type: "button", label: "Open in Finder", action: { type: "reveal", path: ctx.cwd } }
    ]
  };
}
