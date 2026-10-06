#!/bin/bash
# Stops and removes the klipper-macos launchd services and the klipper-mac command.
# Your printer config, G-code files and the downloaded sources are NOT deleted.
set -u
LABEL="com.klipper-macos"
AGENTS="$HOME/Library/LaunchAgents"
for s in klipper moonraker mainsail helper; do
  launchctl bootout "gui/$UID/$LABEL.$s" 2>/dev/null
  rm -f "$AGENTS/$LABEL.$s.plist"
done
link="$(brew --prefix 2>/dev/null)/bin/klipper-mac"
[ -L "$link" ] && rm -f "$link"
echo "Services removed. The USB port is free."
echo "To delete everything else as well, remove these folders by hand (check them first):"
echo "  ~/klipper ~/moonraker ~/mainsail ~/mainsail-config ~/klippy-env ~/moonraker-env ~/printer_data"
