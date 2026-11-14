#!/bin/bash
# Startseite einrichten (macOS) – Doppelklick im Finder
cd "$(dirname "$0")" || exit 1
/usr/bin/osascript -l JavaScript ./Startseite-mac.js --einrichten
