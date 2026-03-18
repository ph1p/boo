#!/bin/bash
# NPM Scripts plugin for exterm
# Reads package.json and lists available scripts as clickable items

PACKAGE_JSON="$EXTERM_CWD/package.json"

if [ ! -f "$PACKAGE_JSON" ]; then
  cat <<EOF
{ "type": "label", "text": "No package.json found", "style": "muted" }
EOF
  exit 0
fi

# Extract script names using python3 (available on macOS)
SCRIPTS=$(python3 -c "
import json, sys
try:
    with open('$PACKAGE_JSON') as f:
        pkg = json.load(f)
    scripts = pkg.get('scripts', {})
    items = []
    for name, cmd in scripts.items():
        items.append({
            'label': name,
            'icon': 'play.circle',
            'detail': cmd[:50],
            'action': {'type': 'exec', 'command': 'npm run ' + name}
        })
    result = {
        'type': 'vstack',
        'children': [
            {'type': 'label', 'text': 'NPM Scripts', 'style': 'bold'},
            {'type': 'divider'},
            {'type': 'list', 'items': items}
        ]
    }
    print(json.dumps(result))
except Exception as e:
    print(json.dumps({'type': 'label', 'text': str(e), 'tint': 'error'}))
" 2>/dev/null)

echo "$SCRIPTS"
