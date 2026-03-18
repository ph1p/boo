#!/bin/bash
# System Info plugin for exterm
# Outputs DSL JSON with hostname, uptime, and disk usage

HOSTNAME=$(hostname -s)
UPTIME=$(uptime | sed 's/.*up //' | sed 's/,.*//')
DISK=$(df -h / | awk 'NR==2 {print $4 " free of " $2}')

cat <<EOF
{
  "type": "vstack",
  "children": [
    { "type": "label", "text": "System Info", "style": "bold" },
    { "type": "divider" },
    { "type": "list", "items": [
      { "label": "$HOSTNAME", "icon": "desktopcomputer", "detail": "Hostname" },
      { "label": "$UPTIME", "icon": "clock", "detail": "Uptime" },
      { "label": "$DISK", "icon": "internaldrive", "detail": "Disk" }
    ]}
  ]
}
EOF
