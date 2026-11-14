#!/usr/bin/env python3
"""Baut Startseite-Mac.zip mit ausführbaren .command-Startern (Unix-Rechte im ZIP).
Builds Startseite-Mac.zip with executable .command launchers (Unix permissions inside the zip).

Aufruf / usage:  python tools/mac-zip-bauen.py
"""
import os
import time
import zipfile

BASIS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATEIEN = [
    ('Installieren-Mac.command', 0o755),
    ('Deinstallieren-Mac.command', 0o755),
    ('Startseite-mac.js', 0o644),
    ('kategorien.json', 0o644),
    ('startseite.vorlage.html', 0o644),
    ('README.md', 0o644),
    ('README.de.md', 0o644),
    ('LICENSE', 0o644),
]

ziel = os.path.join(BASIS, 'Startseite-Mac.zip')
with zipfile.ZipFile(ziel, 'w', zipfile.ZIP_DEFLATED) as z:
    for name, modus in DATEIEN:
        with open(os.path.join(BASIS, name), 'rb') as f:
            daten = f.read()
        if name.endswith('.command') or name.endswith('.js'):
            daten = daten.replace(b'\r\n', b'\n')          # Mac braucht LF
        info = zipfile.ZipInfo('Startseite/' + name, date_time=time.localtime()[:6])
        info.create_system = 3                              # Unix
        info.external_attr = (0o100000 | modus) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, daten)
print('erstellt:', ziel)
