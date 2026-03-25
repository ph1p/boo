function render(ctx) {
  var src = readFile("Makefile");
  if (!src) return { type: "label", text: "No Makefile", style: "muted" };

  // Match lines like "target:" or "target: deps" — skip lines starting with tab/dot/variable
  var targets = [];
  var lines = src.split("\n");
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^([a-zA-Z][a-zA-Z0-9_-]*)\s*:/);
    if (m) targets.push(m[1]);
  }
  if (!targets.length) return { type: "label", text: "No targets found", style: "muted" };

  return {
    type: "list",
    items: targets.map(function (t) {
      return {
        label: t,
        icon: "terminal",
        action: { type: "exec", command: "make " + t }
      };
    })
  };
}
