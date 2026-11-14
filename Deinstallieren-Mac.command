#!/bin/bash
# Startseite entfernen (macOS)
S="$HOME/Library/Application Support/Startseite/Startseite-mac.js"
[ -f "$S" ] || S="$(dirname "$0")/Startseite-mac.js"
/usr/bin/osascript -l JavaScript "$S" --entfernen
