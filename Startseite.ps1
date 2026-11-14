#Requires -Version 5.1
<#
.SYNOPSIS
    Startseite – liest die Lesezeichen aller installierten Browser aus und baut daraus
    eine moderne, thematisch gegliederte Startseite (eine einzelne HTML-Datei).

.DESCRIPTION
    Unterstützte Browser: Google Chrome, Microsoft Edge, Brave, Vivaldi, Chromium,
    Opera, Opera GX (alle Profile) sowie Mozilla Firefox (alle Profile, über die
    automatischen Lesezeichen-Sicherungen).

    - Doppelte Lesezeichen (auch über Browser hinweg, http/https, www, Tracking-
      Parameter, abschließender Slash) werden automatisch zusammengeführt.
    - Die Zuordnung zu Themen steuert die Datei kategorien.json.
    - Alle Links öffnen in einem neuen Tab (target="_blank").

.PARAMETER Installieren
    Kopiert die App nach %LOCALAPPDATA%\Startseite, erzeugt die Seite, trägt sie
    in Chrome, Edge, Brave und Firefox als Startseite ein und legt einen
    Autostart-Eintrag an, der die Seite bei jeder Anmeldung neu aufbaut.

.PARAMETER Deinstallieren
    Macht alles von -Installieren rückgängig.

.PARAMETER Ausgabe
    Zielpfad der HTML-Datei (Standard: %LOCALAPPDATA%\Startseite\index.html).

.PARAMETER Oeffnen
    Öffnet die erzeugte Seite anschließend im Standardbrowser.

.PARAMETER Demo
    Verwendet Beispiel-Lesezeichen statt der echten (zum Ausprobieren/Vorführen).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Startseite.ps1 -Installieren -Oeffnen
#>
[CmdletBinding()]
param(
    [string]$Ausgabe,
    [switch]$Installieren,
    [switch]$Deinstallieren,
    [switch]$Oeffnen,
    [switch]$Demo,
    [switch]$Oberflaeche,
    [switch]$Richtlinie,
    [switch]$NurRichtlinie
)

$ErrorActionPreference = 'Stop'
$InstallOrdner = Join-Path $env:LOCALAPPDATA 'Startseite'
$AppDateien    = 'Startseite.ps1', 'kategorien.json', 'startseite.vorlage.html'
$Utf8          = New-Object System.Text.UTF8Encoding($false)
$Basis         = $PSScriptRoot
# Sprache der Oberfläche: Deutsch bei deutschem Windows, sonst Englisch
$SpracheDeutsch = (Get-UICulture).TwoLetterISOLanguageName -eq 'de'
function Tx([string]$Deutsch, [string]$Englisch) { if ($SpracheDeutsch) { $Deutsch } else { $Englisch } }
if (-not $Ausgabe) { $Ausgabe = Join-Path $InstallOrdner 'index.html' }

$PolicyKeys = @(
    'HKCU:\Software\Policies\Google\Chrome\Recommended',
    'HKCU:\Software\Policies\Microsoft\Edge\Recommended',
    'HKCU:\Software\Policies\BraveSoftware\Brave\Recommended'
)
$AutostartLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Startseite aktualisieren.lnk'

function Info([string]$Text) { Write-Host "  $Text" }

# ---------------------------------------------------------------------------
#  Lesezeichen einsammeln
# ---------------------------------------------------------------------------
$Alle = New-Object System.Collections.Generic.List[object]

function Add-Lesezeichen([string]$Titel, [string]$Url, [string[]]$Pfad, [bool]$Leiste, [string]$Quelle) {
    if (-not $Url -or $Url -notmatch '^https?://') { return }
    $Pfad = @($Pfad | Where-Object { $_ })
    $Alle.Add([pscustomobject]@{
        Titel  = "$Titel".Trim()
        Url    = $Url.Trim()
        Ordner = ($Pfad -join ' / ')
        Top    = $(if ($Pfad.Count) { $Pfad[0] } else { '' })
        Leiste = ($Leiste -and $Pfad.Count -eq 0)
        Quelle = $Quelle
    })
}

function Read-ChromiumKnoten($Knoten, [string[]]$Pfad, [bool]$Leiste, [string]$Quelle) {
    if (-not $Knoten) { return }
    if ($Knoten.type -eq 'url') {
        Add-Lesezeichen $Knoten.name $Knoten.url $Pfad $Leiste $Quelle
    } elseif ($Knoten.type -eq 'folder') {
        $neu = @($Pfad) + $Knoten.name
        foreach ($k in @($Knoten.children)) { Read-ChromiumKnoten $k $neu $Leiste $Quelle }
    }
}

function Read-ChromiumBrowser([string]$Name, [string]$DatenOrdner) {
    if (-not (Test-Path -LiteralPath $DatenOrdner)) { return }

    # Anzeigenamen der Profile aus "Local State" holen (falls vorhanden)
    $profilNamen = @{}
    try {
        $ls = [IO.File]::ReadAllText((Join-Path $DatenOrdner 'Local State'), $Utf8) | ConvertFrom-Json
        foreach ($p in $ls.profile.info_cache.PSObject.Properties) { $profilNamen[$p.Name] = $p.Value.name }
    } catch { }

    $dateien = @()
    $direkt = Join-Path $DatenOrdner 'Bookmarks'           # ältere Opera-Versionen
    if (Test-Path -LiteralPath $direkt) { $dateien += [pscustomobject]@{ Datei = $direkt; Profil = '' } }
    Get-ChildItem -LiteralPath $DatenOrdner -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
        ForEach-Object {
            $f = Join-Path $_.FullName 'Bookmarks'
            if (Test-Path -LiteralPath $f) { $dateien += [pscustomobject]@{ Datei = $f; Profil = $_.Name } }
        }

    $mehrere = $dateien.Count -gt 1
    foreach ($d in $dateien) {
        $quelle = $Name
        if ($mehrere) {
            $pn = $profilNamen[$d.Profil]; if (-not $pn) { $pn = $d.Profil }
            $quelle = "$Name · $pn"
        }
        try {
            $vorher = $Alle.Count
            $json = [IO.File]::ReadAllText($d.Datei, $Utf8) | ConvertFrom-Json
            foreach ($wurzel in 'bookmark_bar', 'other', 'synced') {
                $r = $json.roots.$wurzel
                if (-not $r) { continue }
                foreach ($k in @($r.children)) { Read-ChromiumKnoten $k @() ($wurzel -eq 'bookmark_bar') $quelle }
            }
            Info ("{0,-34} {1,5} Lesezeichen" -f $quelle, ($Alle.Count - $vorher))
        } catch {
            Write-Warning "$quelle konnte nicht gelesen werden: $($_.Exception.Message)"
        }
    }
}

# Firefox speichert Lesezeichen in SQLite. Ohne Zusatzsoftware lesen wir stattdessen die
# automatischen JSON-Sicherungen (bookmarkbackups\*.jsonlz4, Mozillas LZ4-Format).
function Initialize-Lz4 {
    if ('StartseiteLz4' -as [type]) { return }
    Add-Type -TypeDefinition @'
public static class StartseiteLz4 {
    public static byte[] Decode(byte[] src, int offset, int size) {
        byte[] dst = new byte[size]; int s = offset, d = 0;
        while (s < src.Length) {
            int token = src[s++]; int lit = token >> 4;
            if (lit == 15) { int b; do { b = src[s++]; lit += b; } while (b == 255); }
            System.Buffer.BlockCopy(src, s, dst, d, lit); s += lit; d += lit;
            if (s >= src.Length) break;
            int off = src[s] | (src[s + 1] << 8); s += 2;
            int ml = token & 15;
            if (ml == 15) { int b; do { b = src[s++]; ml += b; } while (b == 255); }
            ml += 4; int m = d - off;
            for (int i = 0; i < ml; i++) dst[d++] = dst[m + i];
        }
        if (d == size) return dst;
        byte[] r = new byte[d]; System.Buffer.BlockCopy(dst, 0, r, 0, d); return r;
    }
}
'@
}

function Read-FirefoxKnoten($Knoten, [string[]]$Pfad, [bool]$Leiste, [string]$Quelle) {
    if (-not $Knoten) { return }
    if ($Knoten.uri) {
        Add-Lesezeichen $Knoten.title $Knoten.uri $Pfad $Leiste $Quelle
    } elseif ($Knoten.children) {
        $neu = @($Pfad) + $Knoten.title
        foreach ($k in @($Knoten.children)) { Read-FirefoxKnoten $k $neu $Leiste $Quelle }
    }
}

function Read-Firefox {
    $profile = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
    if (-not (Test-Path -LiteralPath $profile)) { return }
    $liste = @(Get-ChildItem -LiteralPath $profile -Directory)
    foreach ($p in $liste) {
        $ordner = Join-Path $p.FullName 'bookmarkbackups'
        if (-not (Test-Path -LiteralPath $ordner)) { continue }
        $datei = Get-ChildItem -LiteralPath $ordner -Filter '*.jsonlz4' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $datei) { continue }
        $quelle = 'Firefox'
        if ($liste.Count -gt 1) { $quelle = 'Firefox · ' + ($p.Name -replace '^[^.]+\.', '') }
        try {
            Initialize-Lz4
            $b = [IO.File]::ReadAllBytes($datei.FullName)
            if ([Text.Encoding]::ASCII.GetString($b, 0, 7) -ne 'mozLz40') { throw 'unbekanntes Dateiformat' }
            $laenge = [BitConverter]::ToInt32($b, 8)
            $json = $Utf8.GetString([StartseiteLz4]::Decode($b, 12, $laenge)) | ConvertFrom-Json
            $vorher = $Alle.Count
            foreach ($wurzel in @($json.children)) {
                $leiste = $wurzel.guid -eq 'toolbar_____'
                foreach ($k in @($wurzel.children)) { Read-FirefoxKnoten $k @() $leiste $quelle }
            }
            Info ("{0,-34} {1,5} Lesezeichen (Sicherung vom {2:dd.MM.yyyy HH:mm})" -f $quelle, ($Alle.Count - $vorher), $datei.LastWriteTime)
        } catch {
            Write-Warning "$quelle konnte nicht gelesen werden: $($_.Exception.Message)"
        }
    }
}

function Read-Demo {
    $demo = @(
        # Titel, URL, Ordner, Leiste, Quelle
        @('Outlook', 'https://outlook.office.com/mail/', '', $true, 'Google Chrome'),
        @('Teams', 'https://teams.microsoft.com/', '', $true, 'Google Chrome'),
        @('SharePoint – Intranet', 'https://firma.sharepoint.com/sites/intranet', '', $true, 'Google Chrome'),
        @('ChatGPT', 'https://chatgpt.com/', '', $true, 'Google Chrome'),
        @('Claude', 'https://claude.ai/new', '', $true, 'Google Chrome'),
        @('Figma', 'https://www.figma.com/files/recents-and-sharing', '', $true, 'Google Chrome'),
        @('GitHub', 'https://github.com/', '', $true, 'Google Chrome'),
        @('DATEV Unternehmen online', 'https://duo.datev.de/', '', $true, 'Google Chrome'),
        @('Asana – Meine Aufgaben', 'https://app.asana.com/0/home', 'Projekte', $false, 'Google Chrome'),
        @('Miro Board Kampagne Q4', 'https://miro.com/app/board/uXjVabc=/', 'Projekte', $false, 'Google Chrome'),
        @('Google Analytics', 'https://analytics.google.com/analytics/web/', 'Marketing', $false, 'Google Chrome'),
        @('Search Console', 'https://search.google.com/search-console', 'Marketing', $false, 'Google Chrome'),
        @('Meta Business Suite', 'https://business.facebook.com/latest/home', 'Marketing', $false, 'Google Chrome'),
        @('SISTRIX', 'https://app.sistrix.com/', 'Marketing', $false, 'Google Chrome'),
        @('CleverReach', 'https://eu.cleverreach.com/admin/', 'Marketing', $false, 'Google Chrome'),
        @('Canva', 'https://www.canva.com/', 'Grafik', $false, 'Google Chrome'),
        @('Adobe Stock', 'https://stock.adobe.com/de/', 'Grafik', $false, 'Google Chrome'),
        @('Unsplash', 'https://unsplash.com/', 'Grafik', $false, 'Google Chrome'),
        @('Google Fonts', 'https://fonts.google.com/', 'Grafik', $false, 'Google Chrome'),
        @('Coolors – Farbpaletten', 'https://coolors.co/', 'Grafik', $false, 'Google Chrome'),
        @('Kunde Müller – Website', 'https://www.mueller-moebel.example/', 'Kunden', $false, 'Google Chrome'),
        @('Kunde Becker – Staging', 'https://staging.becker-bau.example/', 'Kunden', $false, 'Google Chrome'),
        @('Kunde Schneider – Shop', 'https://shop.schneider-optik.example/', 'Kunden', $false, 'Google Chrome'),
        @('Kunde Wagner – Briefing', 'https://wagner-gruppe.example/briefing', 'Kunden', $false, 'Google Chrome'),
        # Edge – mit Dubletten in anderer Schreibweise
        @('Outlook Web', 'https://outlook.office.com/mail/?utm_source=edge', '', $true, 'Microsoft Edge'),
        @('GitHub', 'http://www.github.com', '', $true, 'Microsoft Edge'),
        @('Microsoft 365', 'https://www.microsoft365.com/', '', $true, 'Microsoft Edge'),
        @('OneDrive', 'https://onedrive.live.com/', 'Büro', $false, 'Microsoft Edge'),
        @('Personio – Urlaub beantragen', 'https://firma.personio.de/time-off', 'Büro', $false, 'Microsoft Edge'),
        @('lexoffice', 'https://app.lexoffice.de/', 'Büro', $false, 'Microsoft Edge'),
        @('Sparkasse Online-Banking', 'https://www.sparkasse-musterstadt.de/', 'Büro', $false, 'Microsoft Edge'),
        @('DeepL Übersetzer', 'https://www.deepl.com/translator', '', $false, 'Microsoft Edge'),
        @('iLovePDF', 'https://www.ilovepdf.com/de', '', $false, 'Microsoft Edge'),
        @('WeTransfer', 'https://wetransfer.com/', '', $false, 'Microsoft Edge'),
        @('Perplexity', 'https://www.perplexity.ai/', 'KI', $false, 'Microsoft Edge'),
        @('ChatGPT', 'https://chatgpt.com', 'KI', $false, 'Microsoft Edge'),
        @('ElevenLabs', 'https://elevenlabs.io/app/home', 'KI', $false, 'Microsoft Edge'),
        @('Stack Overflow', 'https://stackoverflow.com/', 'Dev', $false, 'Microsoft Edge'),
        @('MDN Web Docs', 'https://developer.mozilla.org/de/', 'Dev', $false, 'Microsoft Edge'),
        @('Hetzner Console', 'https://console.hetzner.cloud/', 'Dev', $false, 'Microsoft Edge'),
        @('localhost / XAMPP', 'http://localhost/dashboard/', 'Dev', $false, 'Microsoft Edge'),
        # Firefox
        @('heise online', 'https://www.heise.de/', '', $true, 'Firefox'),
        @('t3n', 'https://t3n.de/', '', $true, 'Firefox'),
        @('tagesschau.de', 'https://www.tagesschau.de/', 'News', $false, 'Firefox'),
        @('SPIEGEL', 'https://www.spiegel.de/', 'News', $false, 'Firefox'),
        @('YouTube', 'https://www.youtube.com/', '', $false, 'Firefox'),
        @('YouTube Studio', 'https://studio.youtube.com/', '', $false, 'Firefox'),
        @('LinkedIn', 'https://www.linkedin.com/feed/', '', $false, 'Firefox'),
        @('Instagram', 'https://www.instagram.com/', '', $false, 'Firefox'),
        @('Deutsche Bahn', 'https://www.bahn.de/', '', $false, 'Firefox'),
        @('Google Maps', 'https://www.google.com/maps', '', $false, 'Firefox'),
        @('Wikipedia', 'https://de.wikipedia.org/wiki/Wikipedia:Hauptseite', '', $false, 'Firefox'),
        @('Udemy – Meine Kurse', 'https://www.udemy.com/home/my-courses/learning/', '', $false, 'Firefox'),
        @('Amazon', 'https://www.amazon.de/', '', $false, 'Firefox'),
        @('Thomann', 'https://www.thomann.de/de/index.html', '', $false, 'Firefox'),
        @('Teams', 'https://teams.microsoft.com', '', $false, 'Firefox')
    )
    foreach ($d in $demo) {
        $pfad = @(); if ($d[2]) { $pfad = @($d[2]) }
        Add-Lesezeichen $d[0] $d[1] $pfad $d[3] $d[4]
    }
    Info "Demo-Modus: $($Alle.Count) Beispiel-Lesezeichen"
}

# ---------------------------------------------------------------------------
#  Zusammenführen & Kategorisieren
# ---------------------------------------------------------------------------
$TrackingParameter = '^(utm_[a-z_]+|fbclid|gclid|dclid|gbraid|wbraid|msclkid|mc_cid|mc_eid|_ga|_gl|igshid|yclid|ref_src|si)$'

function Get-Schluessel([Uri]$U, [string]$HostName) {
    $schluessel = $HostName
    if (-not $U.IsDefaultPort) { $schluessel += ':' + $U.Port }
    $pfad = $U.AbsolutePath.TrimEnd('/') -replace '/(index|default)\.(html?|php|aspx?)$', ''
    $schluessel += $pfad
    if ($U.Query.Length -gt 1) {
        $teile = @($U.Query.Substring(1).Split('&') | Where-Object { $_ -and (($_ -split '=')[0] -notmatch $TrackingParameter) } | Sort-Object)
        if ($teile.Count) { $schluessel += '?' + ($teile -join '&') }
    }
    if ($U.Fragment -match '^#[!/]') { $schluessel += $U.Fragment }   # SPA-Routen behalten
    return $schluessel
}

function Test-Domain($Eintrag, [string]$Regel) {
    $Regel = $Regel.ToLowerInvariant()
    if ($Regel.Contains('/')) { return ($Eintrag.HostPfad.StartsWith($Regel) -or $Eintrag.HostPfad.Contains('.' + $Regel)) }
    return ($Eintrag.HostName -eq $Regel -or $Eintrag.HostName.EndsWith('.' + $Regel))
}

function Get-Kategorie($Eintrag) {
    # 1. Domain-Regeln – die genaueste (längste) passende Regel gewinnt
    $beste = $null; $besteLaenge = 0
    foreach ($k in $Konfig.kategorien) {
        foreach ($d in @($k.domains)) {
            if ($d -and $d.Length -gt $besteLaenge -and (Test-Domain $Eintrag $d)) { $beste = $k.name; $besteLaenge = $d.Length }
        }
    }
    if ($beste) { return $beste }

    # 2. Ordnername des Nutzers passt zu einem Thema (z. B. Ordner "Marketing")
    $k = Find-Stichwort $Eintrag.Ordner
    if ($k) { return $k }

    # 3. Eigener Ordner des Nutzers bleibt zusammen (zu kleine Ordner: siehe New-Startseite)
    if ($Eintrag.Top) { return "ordner:$($Eintrag.Top)" }

    # 4. Stichworte in Titel und Domain
    return (Find-Stichwort ('{0} {1}' -f $Eintrag.Titel, $Eintrag.HostName))
}

# Liefert das erste Thema, dessen Stichwort im Text vorkommt (kurze Wörter nur als ganzes Wort)
function Find-Stichwort([string]$Text) {
    if (-not $Text) { return '' }
    $Text = $Text.ToLowerInvariant()
    foreach ($k in $Konfig.kategorien) {
        foreach ($w in @($k.stichworte)) {
            if (-not $w) { continue }
            $muster = '(?<![\p{L}\p{N}])' + [regex]::Escape($w.ToLowerInvariant())
            if ($w.Length -le 3) { $muster += '(?![\p{L}\p{N}])' }
            if ($Text -match $muster) { return $k.name }
        }
    }
    return ''
}

function New-Startseite {
    $konfigPfad  = Join-Path $Basis 'kategorien.json'
    $vorlagePfad = Join-Path $Basis 'startseite.vorlage.html'
    $script:Konfig = [IO.File]::ReadAllText($konfigPfad, $Utf8) | ConvertFrom-Json

    Write-Host ''
    Write-Host 'Lesezeichen werden gesammelt …' -ForegroundColor Cyan
    if ($Demo) {
        Read-Demo
    } else {
        $L = $env:LOCALAPPDATA; $R = $env:APPDATA
        Read-ChromiumBrowser 'Google Chrome'  "$L\Google\Chrome\User Data"
        Read-ChromiumBrowser 'Microsoft Edge' "$L\Microsoft\Edge\User Data"
        Read-ChromiumBrowser 'Brave'          "$L\BraveSoftware\Brave-Browser\User Data"
        Read-ChromiumBrowser 'Vivaldi'        "$L\Vivaldi\User Data"
        Read-ChromiumBrowser 'Chromium'       "$L\Chromium\User Data"
        Read-ChromiumBrowser 'Opera'          "$R\Opera Software\Opera Stable"
        Read-ChromiumBrowser 'Opera GX'       "$R\Opera Software\Opera GX Stable"
        Read-Firefox
    }

    # --- Dubletten zusammenführen -------------------------------------------
    $map = [ordered]@{}
    $ignoriert = 0
    foreach ($b in $Alle) {
        $u = $null
        if (-not [Uri]::TryCreate($b.Url, [UriKind]::Absolute, [ref]$u)) { continue }
        $hostName = $u.Host.ToLowerInvariant() -replace '^www\.', ''
        $e = [pscustomobject]@{ HostName = $hostName; HostPfad = ($hostName + $u.AbsolutePath).ToLowerInvariant() }

        $ignorieren = $false
        foreach ($r in @($Konfig.ignorieren)) {
            if (-not $r) { continue }
            $r = $r.ToLowerInvariant()
            if (($r.Contains('/') -and $e.HostPfad.StartsWith($r)) -or $hostName -eq $r) { $ignorieren = $true; break }
        }
        if ($ignorieren) { $ignoriert++; continue }

        $schluessel = Get-Schluessel $u $hostName
        $browser = ($b.Quelle -split ' · ')[0]
        $titelOk = $b.Titel -and $b.Titel -ne $b.Url

        if ($map.Contains($schluessel)) {
            $x = $map[$schluessel]
            if ($x.Url -like 'http://*' -and $b.Url -like 'https://*') { $x.Url = $b.Url }
            if (-not $x.Titel -and $titelOk) { $x.Titel = $b.Titel }
            if (-not $x.Top -and $b.Top) { $x.Top = $b.Top; $x.Ordner = $b.Ordner }
            if ($b.Leiste) { $x.Leiste = $true }
            if ($x.Browser -notcontains $browser) { $x.Browser.Add($browser) }
        } else {
            $liste = New-Object System.Collections.Generic.List[string]; $liste.Add($browser)
            $map[$schluessel] = [pscustomobject]@{
                Titel = $(if ($titelOk) { $b.Titel } else { '' })
                Url = $b.Url; HostName = $hostName; HostPfad = $e.HostPfad
                Ordner = $b.Ordner; Top = $b.Top; Leiste = $b.Leiste; Browser = $liste
            }
        }
    }
    $eintraege = @($map.Values)
    foreach ($x in $eintraege) { if (-not $x.Titel) { $x.Titel = $x.HostName } }
    $dubletten = $Alle.Count - $ignoriert - $eintraege.Count

    # --- Thematisch gliedern ---------------------------------------------------
    $gruppen = @{}
    foreach ($x in $eintraege) {
        $k = Get-Kategorie $x
        if (-not $gruppen.ContainsKey($k)) { $gruppen[$k] = New-Object System.Collections.Generic.List[object] }
        $gruppen[$k].Add($x)
    }
    # Zu kleine Ordner werden aufgelöst: Einträge per Stichwort zuordnen, sonst "Sonstiges"
    $min = [int]$Konfig.mindestOrdnerGroesse; if ($min -lt 1) { $min = 3 }
    foreach ($k in @($gruppen.Keys | Where-Object { $_ -like 'ordner:*' })) {
        if ($gruppen[$k].Count -ge $min) { continue }
        foreach ($x in $gruppen[$k]) {
            $neu = Find-Stichwort ('{0} {1}' -f $x.Titel, $x.HostName)
            if (-not $gruppen.ContainsKey($neu)) { $gruppen[$neu] = New-Object System.Collections.Generic.List[object] }
            $gruppen[$neu].Add($x)
        }
        $gruppen.Remove($k)
    }

    function ConvertTo-Item($x) {
        [ordered]@{ t = $x.Titel; u = $x.Url; h = $x.HostName; o = $x.Ordner; b = @($x.Browser) }
    }
    function New-Gruppe([string]$Name, [string]$NameEn, [string]$Icon, $Liste) {
        if (-not $NameEn) { $NameEn = $Name }
        [ordered]@{ name = $Name; name_en = $NameEn; icon = $Icon; items = @($Liste | Sort-Object Titel | ForEach-Object { ConvertTo-Item $_ }) }
    }

    $kategorien = New-Object System.Collections.Generic.List[object]
    foreach ($k in $Konfig.kategorien) {
        if ($gruppen.ContainsKey($k.name)) { $kategorien.Add((New-Gruppe $k.name $k.name_en $k.icon $gruppen[$k.name])) }
    }
    foreach ($k in @($gruppen.Keys | Where-Object { $_ -like 'ordner:*' } | Sort-Object)) {
        $kategorien.Add((New-Gruppe $k.Substring(7) $k.Substring(7) '📁' $gruppen[$k]))
    }
    if ($gruppen.ContainsKey('')) {
        $kategorien.Add((New-Gruppe $Konfig.sonstiges.name $Konfig.sonstiges.name_en $Konfig.sonstiges.icon $gruppen['']))
    }

    $maxSchnell = [int]$Konfig.schnellzugriffMax; if ($maxSchnell -lt 1) { $maxSchnell = 16 }
    $schnell = @($eintraege | Where-Object { $_.Leiste } | Select-Object -First $maxSchnell | ForEach-Object { ConvertTo-Item $_ })

    $quellen = @($Alle | Group-Object Quelle | ForEach-Object { [ordered]@{ name = $_.Name; anzahl = $_.Count } })

    $daten = [ordered]@{
        titel             = $Konfig.titel
        titel_en          = $Konfig.titel_en
        erstellt          = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        gesamt            = $eintraege.Count
        roh               = $Alle.Count
        dubletten         = $dubletten
        quellen           = $quellen
        suche             = $Konfig.suche
        favicons          = $Konfig.favicons
        eintraegeProKarte = $Konfig.eintraegeProKarte
        schnell           = $schnell
        kategorien        = $kategorien.ToArray()
    }

    $json = ($daten | ConvertTo-Json -Depth 10 -Compress).Replace('</', '<\/')
    $html = [IO.File]::ReadAllText($vorlagePfad, $Utf8)
    $html = $html.Replace('/*__DATEN__*/null', $json).Replace('__TITEL__', [Net.WebUtility]::HtmlEncode($Konfig.titel))

    $ziel = Split-Path -Parent $Ausgabe
    if ($ziel -and -not (Test-Path -LiteralPath $ziel)) { New-Item -ItemType Directory -Path $ziel | Out-Null }
    [IO.File]::WriteAllText($Ausgabe, $html, $Utf8)

    Write-Host ''
    $script:Zusammenfassung = (Tx '{0} Lesezeichen, {1} Dubletten zusammengeführt, {2} Themen' '{0} bookmarks, {1} duplicates merged, {2} topics') -f $eintraege.Count, $dubletten, $kategorien.Count
    Write-Host "Fertig: $script:Zusammenfassung." -ForegroundColor Green
    Info $Ausgabe
}

# ---------------------------------------------------------------------------
#  Einbindung in Browser & System
# ---------------------------------------------------------------------------
$FirefoxProfile = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
$DesktopLink    = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Startseite.url'
$FfMuster       = '(?s)// >>> Startseite.*?// <<< Startseite\r?\n?'

function Get-SeitenUrl { ([Uri]$Ausgabe).AbsoluteUri }

function Find-Programm([string]$Exe, [string[]]$Kandidaten) {
    foreach ($root in 'HKCU:', 'HKLM:') {
        try {
            $v = (Get-ItemProperty "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$Exe" -ErrorAction Stop).'(default)'
            if ($v) { $v = $v.Trim('"'); if (Test-Path -LiteralPath $v) { return $v } }
        } catch { }
    }
    foreach ($k in $Kandidaten) { if ($k -and (Test-Path -LiteralPath $k)) { return $k } }
    return $null
}

# Installierte Chromium-Browser, deren Startseite man nur in den Einstellungen setzen kann
function Get-Browser {
    $pf = $env:ProgramFiles; $pf86 = ${env:ProgramFiles(x86)}; $la = $env:LOCALAPPDATA
    $liste = @(
        [pscustomobject]@{ Name = 'Google Chrome';  Einstellungen = 'chrome://settings/onStartup'
            Exe = (Find-Programm 'chrome.exe' @("$pf\Google\Chrome\Application\chrome.exe", "$pf86\Google\Chrome\Application\chrome.exe", "$la\Google\Chrome\Application\chrome.exe")) },
        [pscustomobject]@{ Name = 'Microsoft Edge'; Einstellungen = 'edge://settings/startHomeNTP'
            Exe = (Find-Programm 'msedge.exe' @("$pf86\Microsoft\Edge\Application\msedge.exe", "$pf\Microsoft\Edge\Application\msedge.exe")) },
        [pscustomobject]@{ Name = 'Brave';          Einstellungen = 'brave://settings/getStarted'
            Exe = (Find-Programm 'brave.exe' @("$pf\BraveSoftware\Brave-Browser\Application\brave.exe", "$la\BraveSoftware\Brave-Browser\Application\brave.exe")) }
    )
    @($liste | Where-Object { $_.Exe })
}

function Open-BrowserEinstellungen($Browser) {
    foreach ($b in @($Browser)) {
        try { Start-Process -FilePath $b.Exe -ArgumentList $b.Einstellungen } catch { Write-Warning "$($b.Name) konnte nicht geöffnet werden." }
    }
}

# --- Firefox (user.js – funktioniert ohne Adminrechte) -----------------------
function Test-Firefox { Test-Path -LiteralPath $FirefoxProfile }

function Test-FirefoxEingetragen {
    if (-not (Test-Firefox)) { return $false }
    foreach ($p in Get-ChildItem -LiteralPath $FirefoxProfile -Directory) {
        $u = Join-Path $p.FullName 'user.js'
        if ((Test-Path -LiteralPath $u) -and ([IO.File]::ReadAllText($u, $Utf8) -match '// >>> Startseite')) { return $true }
    }
    return $false
}

function Set-FirefoxStartseite([string]$Url) {
    if (-not (Test-Firefox)) { return }
    $block = "// >>> Startseite`r`nuser_pref(""browser.startup.homepage"", ""$Url"");`r`nuser_pref(""browser.startup.page"", 1);`r`n// <<< Startseite`r`n"
    foreach ($p in Get-ChildItem -LiteralPath $FirefoxProfile -Directory) {
        $userJs = Join-Path $p.FullName 'user.js'
        $alt = ''; if (Test-Path -LiteralPath $userJs) { $alt = [IO.File]::ReadAllText($userJs, $Utf8) }
        [IO.File]::WriteAllText($userJs, ($alt -replace $FfMuster, '') + $block, $Utf8)
    }
    Info 'Firefox: als Startseite eingetragen (wirkt nach Neustart von Firefox)'
}

function Remove-FirefoxStartseite {
    if (-not (Test-Firefox)) { return }
    foreach ($p in Get-ChildItem -LiteralPath $FirefoxProfile -Directory) {
        $userJs = Join-Path $p.FullName 'user.js'
        if (-not (Test-Path -LiteralPath $userJs)) { continue }
        $alt = [IO.File]::ReadAllText($userJs, $Utf8)
        if ($alt -notmatch '// >>> Startseite') { continue }
        $neu = $alt -replace $FfMuster, ''
        if ($neu.Trim()) { [IO.File]::WriteAllText($userJs, $neu, $Utf8) } else { Remove-Item -LiteralPath $userJs }
    }
}

# --- Richtlinie für Chrome/Edge/Brave (nur mit Adminrechten) ----------------
function Test-Richtlinie {
    foreach ($key in $PolicyKeys) {
        try { if ((Get-ItemProperty -Path $key -Name 'HomepageLocation' -ErrorAction Stop).HomepageLocation) { return $true } } catch { }
    }
    return $false
}

# Gibt die Anzahl der Browser zurück, bei denen das Setzen geklappt hat
function Set-Richtlinie([string]$Url) {
    $ok = 0
    foreach ($key in $PolicyKeys) {
        try {
            if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
            New-ItemProperty -Path $key -Name 'HomepageLocation'     -Value $Url -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $key -Name 'HomepageIsNewTabPage' -Value 0    -PropertyType DWord  -Force | Out-Null
            New-ItemProperty -Path $key -Name 'ShowHomeButton'       -Value 1    -PropertyType DWord  -Force | Out-Null
            New-ItemProperty -Path $key -Name 'RestoreOnStartup'     -Value 4    -PropertyType DWord  -Force | Out-Null
            $urls = "$key\RestoreOnStartupURLs"
            if (-not (Test-Path $urls)) { New-Item -Path $urls -Force | Out-Null }
            New-ItemProperty -Path $urls -Name '1' -Value $Url -PropertyType String -Force | Out-Null
            $ok++
        } catch {
            Write-Warning "Richtlinie nicht gesetzt ($key): keine Berechtigung – nur mit Administratorrechten möglich."
        }
    }
    if ($ok) { Info "Richtlinie: Startseite für $ok Browser gesetzt" }
    return $ok
}

function Remove-Richtlinie {
    $ok = $true
    foreach ($key in $PolicyKeys) {
        if (-not (Test-Path $key)) { continue }
        try {
            foreach ($n in 'HomepageLocation', 'HomepageIsNewTabPage', 'ShowHomeButton', 'RestoreOnStartup') {
                if ($null -ne (Get-ItemProperty -Path $key -Name $n -ErrorAction SilentlyContinue)) { Remove-ItemProperty -Path $key -Name $n }
            }
            if (Test-Path "$key\RestoreOnStartupURLs") { Remove-Item -Path "$key\RestoreOnStartupURLs" -Recurse }
        } catch { $ok = $false; Write-Warning "Richtlinie nicht entfernt ($key): keine Berechtigung." }
    }
    return $ok
}

# Startet dieses Skript mit Adminrechten (UAC-Abfrage), um die Richtlinie zu setzen/entfernen
function Invoke-RichtlinieAlsAdmin([switch]$Entfernen) {
    $skript = Join-Path $Basis 'Startseite.ps1'
    $argumente = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$skript"" -NurRichtlinie -Ausgabe ""$Ausgabe"""
    if ($Entfernen) { $argumente += ' -Deinstallieren' }
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumente -Verb RunAs -Wait -PassThru
        return ($p.ExitCode -eq 0)
    } catch {
        return $false   # UAC-Abfrage abgelehnt
    }
}

# --- Autostart & Desktop-Verknüpfung ------------------------------------------
function Set-Autostart {
    $skript = Join-Path $InstallOrdner 'Startseite.ps1'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($AutostartLnk)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$skript"""
    $lnk.WorkingDirectory = $InstallOrdner
    $lnk.WindowStyle = 7
    $lnk.Description = 'Baut die Startseite aus den aktuellen Lesezeichen neu auf'
    $lnk.Save()
    Info 'Autostart: Seite wird bei jeder Anmeldung aktualisiert'
}
function Remove-Autostart { if (Test-Path -LiteralPath $AutostartLnk) { Remove-Item -LiteralPath $AutostartLnk } }

function Set-Desktoplink([string]$Url) {
    [IO.File]::WriteAllText($DesktopLink, "[InternetShortcut]`r`nURL=$Url`r`n", [Text.Encoding]::ASCII)
    Info 'Desktop-Verknüpfung angelegt'
}
function Remove-Desktoplink { if (Test-Path -LiteralPath $DesktopLink) { Remove-Item -LiteralPath $DesktopLink } }

function Copy-App {
    if ($Basis -and $Basis.TrimEnd('\') -eq $InstallOrdner.TrimEnd('\')) { return }
    if (-not (Test-Path -LiteralPath $InstallOrdner)) { New-Item -ItemType Directory -Path $InstallOrdner | Out-Null }
    foreach ($f in $AppDateien) { Copy-Item -LiteralPath (Join-Path $Basis $f) -Destination $InstallOrdner -Force }
    $script:Basis = $InstallOrdner
}

# ---------------------------------------------------------------------------
#  Einrichtungs-Oberfläche
# ---------------------------------------------------------------------------
function Show-Meldung([string]$Text, [string]$Art = 'Information', [string]$Knoepfe = 'OK') {
    [Windows.Forms.MessageBox]::Show($Text, (Tx 'Startseite' 'Start Page'), $Knoepfe, $Art)
}

function Show-Einrichtung {
    $browser    = Get-Browser
    $hatFirefox = Test-Firefox
    $installiert = (Test-Path -LiteralPath $AutostartLnk) -or (Test-Path -LiteralPath (Join-Path $InstallOrdner 'index.html'))

    $grau   = [Drawing.Color]::FromArgb(96, 102, 118)
    $akzent = [Drawing.Color]::FromArgb(79, 95, 232)
    $breite = 480

    $form = New-Object Windows.Forms.Form -Property @{
        Text = (Tx 'Startseite einrichten' 'Set up start page'); StartPosition = 'CenterScreen'; FormBorderStyle = 'FixedDialog'
        MaximizeBox = $false; MinimizeBox = $false; BackColor = [Drawing.Color]::White
        Font = New-Object Drawing.Font('Segoe UI', 9.75); ShowIcon = $false
        ClientSize = New-Object Drawing.Size(($breite + 60), 400)
    }
    $panel = New-Object Windows.Forms.FlowLayoutPanel -Property @{
        FlowDirection = 'TopDown'; WrapContents = $false; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'
        Padding = New-Object Windows.Forms.Padding(26, 22, 26, 14); Dock = 'Top'
    }

    function Add-Text([string]$Text, [single]$Groesse = 9.75, [string]$Stil = 'Regular', $Farbe = $null, [int]$Oben = 0, [int]$Links = 0) {
        $l = New-Object Windows.Forms.Label -Property @{
            Text = $Text; AutoSize = $true; MaximumSize = New-Object Drawing.Size(($breite - $Links), 0)
            Font = New-Object Drawing.Font('Segoe UI', $Groesse, [Drawing.FontStyle]$Stil)
            Margin = New-Object Windows.Forms.Padding($Links, $Oben, 0, 0)
        }
        if ($Farbe) { $l.ForeColor = $Farbe }
        $panel.Controls.Add($l)
    }
    function Add-Ueberschrift([string]$Text) { Add-Text $Text 10.5 'Bold' $null 18 }
    function Add-Option([string]$Text, [bool]$An, [string]$Hinweis = '', [bool]$Aktiv = $true) {
        $c = New-Object Windows.Forms.CheckBox -Property @{
            Text = $Text; Checked = ($An -and $Aktiv); Enabled = $Aktiv; AutoSize = $true
            Margin = New-Object Windows.Forms.Padding(0, 8, 0, 0)
        }
        $panel.Controls.Add($c)
        if ($Hinweis) { Add-Text $Hinweis 8.75 'Regular' $grau 0 18 }
        return $c
    }

    Add-Text (Tx 'Startseite einrichten' 'Set up start page') 16 'Bold'
    Add-Text (Tx 'Die Startseite wird aus den Lesezeichen aller Browser erzeugt. Wähle aus, wie sie eingebunden werden soll.' 'The start page is built from the bookmarks of all your browsers. Choose how it should be set up.') 9.75 'Regular' $grau 4

    Add-Ueberschrift (Tx 'Allgemein' 'General')
    $cbAuto    = Add-Option (Tx 'Bei jeder Anmeldung automatisch aktualisieren' 'Update automatically at every sign-in') $true
    $cbDesktop = Add-Option (Tx 'Verknüpfung „Startseite“ auf dem Desktop' 'Shortcut “Startseite” on the desktop') $true
    $cbOeffnen = Add-Option (Tx 'Startseite nach dem Einrichten öffnen' 'Open the start page when done') $true

    Add-Ueberschrift 'Firefox'
    if ($hatFirefox) {
        $cbFirefox = Add-Option (Tx 'Als Startseite eintragen' 'Set as home page') $true (Tx 'Wird automatisch gesetzt und gilt nach einem Neustart von Firefox.' 'Set automatically; takes effect after restarting Firefox.')
    } else {
        $cbFirefox = Add-Option (Tx 'Als Startseite eintragen' 'Set as home page') $false (Tx 'Firefox ist auf diesem Rechner nicht eingerichtet.' 'Firefox is not set up on this computer.') $false
    }

    Add-Ueberschrift 'Chrome · Edge · Brave'
    Add-Text (Tx 'Diese Browser erlauben Programmen nicht, die Startseite zu ändern. Die Adresse wird in die Zwischenablage kopiert und die passende Einstellungsseite geöffnet – dort nur noch einfügen.' 'These browsers do not let programs change the home page. The address is copied to the clipboard and the right settings page is opened – just paste it there.') 8.75 'Regular' $grau 4
    $cbBrowser = @{}
    foreach ($b in $browser) { $cbBrowser[$b.Name] = Add-Option ("$($b.Name): " + (Tx 'Einstellungen öffnen' 'open settings')) $true }
    if (-not $browser.Count) { Add-Text (Tx 'Keiner dieser Browser ist installiert.' 'None of these browsers is installed.') 9 'Italic' $grau 6 }
    $cbRichtlinie = Add-Option (Tx 'Fest als Richtlinie eintragen (Administrator)' 'Enforce as policy (administrator)') (Test-Richtlinie) (Tx 'Setzt die Startseite für Chrome, Edge und Brave ohne Handarbeit. Fragt nach Administratorrechten und greift nur auf Geräten, die per Domäne oder Intune verwaltet werden.' 'Sets the home page for Chrome, Edge and Brave without manual steps. Asks for administrator rights and only works on devices managed via domain or Intune.')

    # Knopfleiste
    $leiste = New-Object Windows.Forms.FlowLayoutPanel -Property @{
        FlowDirection = 'RightToLeft'; Dock = 'Bottom'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'
        BackColor = [Drawing.Color]::FromArgb(244, 245, 249); Padding = New-Object Windows.Forms.Padding(20, 12, 20, 12)
    }
    function New-Knopf([string]$Text, [bool]$Primaer = $false) {
        $k = New-Object Windows.Forms.Button -Property @{
            Text = $Text; AutoSize = $true; MinimumSize = New-Object Drawing.Size(112, 34); FlatStyle = 'Flat'
            Margin = New-Object Windows.Forms.Padding(8, 0, 0, 0); Cursor = [Windows.Forms.Cursors]::Hand
        }
        if ($Primaer) { $k.BackColor = $akzent; $k.ForeColor = [Drawing.Color]::White; $k.FlatAppearance.BorderSize = 0; $k.Font = New-Object Drawing.Font('Segoe UI', 9.75, [Drawing.FontStyle]::Bold) }
        else { $k.BackColor = [Drawing.Color]::White; $k.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(210, 214, 224) }
        return $k
    }
    $btnOk = New-Knopf (Tx 'Einrichten' 'Set up') $true
    $btnAbbrechen = New-Knopf (Tx 'Abbrechen' 'Cancel')
    $btnOk.DialogResult = 'OK'; $btnAbbrechen.DialogResult = 'Cancel'
    $leiste.Controls.Add($btnOk); $leiste.Controls.Add($btnAbbrechen)
    if ($installiert) {
        $btnEntfernen = New-Knopf (Tx 'Entfernen' 'Remove')
        $btnEntfernen.DialogResult = 'Abort'
        $btnEntfernen.Margin = New-Object Windows.Forms.Padding(8, 0, 60, 0)
        $leiste.Controls.Add($btnEntfernen)
    }
    $form.AcceptButton = $btnOk; $form.CancelButton = $btnAbbrechen

    $form.Controls.Add($leiste)
    $form.Controls.Add($panel)
    $panel.BringToFront()
    $form.PerformLayout()
    $form.ClientSize = New-Object Drawing.Size(($breite + 60), ($panel.PreferredSize.Height + $leiste.PreferredSize.Height))
    $form.TopMost = $true
    $form.Add_Shown({ $form.Activate(); $form.TopMost = $false })
    $ergebnis = $form.ShowDialog()

    $aktion = switch ($ergebnis) { 'OK' { 'einrichten' } 'Abort' { 'entfernen' } default { $null } }
    [pscustomobject]@{
        Aktion     = $aktion
        Autostart  = $cbAuto.Checked
        Desktop    = $cbDesktop.Checked
        Oeffnen    = $cbOeffnen.Checked
        Firefox    = $cbFirefox.Checked
        Richtlinie = $cbRichtlinie.Checked
        Browser    = @($browser | Where-Object { $cbBrowser[$_.Name].Checked })
    }
}

function Invoke-Einrichtung($O) {
    $zeilen = New-Object System.Collections.Generic.List[string]
    Copy-App
    New-Startseite
    $zeilen.Add("✔  $script:Zusammenfassung")
    $url = Get-SeitenUrl

    if ($O.Autostart) { Set-Autostart; $zeilen.Add((Tx '✔  Wird bei jeder Anmeldung aktualisiert' '✔  Updates at every sign-in')) } else { Remove-Autostart }
    if ($O.Desktop)   { Set-Desktoplink $url; $zeilen.Add((Tx '✔  Desktop-Verknüpfung „Startseite“' '✔  Desktop shortcut “Startseite”')) } else { Remove-Desktoplink }
    if (Test-Firefox) {
        if ($O.Firefox) { Set-FirefoxStartseite $url; $zeilen.Add((Tx '✔  Firefox: als Startseite eingetragen (nach Neustart)' '✔  Firefox: set as home page (after restart)')) } else { Remove-FirefoxStartseite }
    }

    $vorher = Test-Richtlinie
    if ($O.Richtlinie) {
        if (Invoke-RichtlinieAlsAdmin) { $zeilen.Add((Tx '✔  Chrome/Edge/Brave: Richtlinie gesetzt' '✔  Chrome/Edge/Brave: policy set')) }
        else { $zeilen.Add((Tx '⚠  Richtlinie nicht gesetzt (Administratorrechte abgelehnt oder fehlen)' '⚠  Policy not set (administrator rights declined or missing)')) }
    } elseif ($vorher) {
        if (Invoke-RichtlinieAlsAdmin -Entfernen) { $zeilen.Add((Tx '✔  Richtlinie entfernt' '✔  Policy removed')) } else { $zeilen.Add((Tx '⚠  Richtlinie konnte nicht entfernt werden' '⚠  Policy could not be removed')) }
    }

    $text = (Tx 'Die Startseite ist eingerichtet.' 'The start page is set up.') + "`r`n`r`n" + ($zeilen -join "`r`n")
    if ($O.Browser.Count) {
        Set-Clipboard -Value $url
        $namen = ($O.Browser | ForEach-Object { $_.Name }) -join ', '
        $text += "`r`n`r`n" + (Tx "Noch ein Handgriff für $($namen):" "One more step for $($namen):") + "`r`n" +
                 (Tx 'Die Adresse der Startseite ist in der Zwischenablage. Nach „OK“ öffnen sich die Einstellungen. Dort jeweils:' 'The start page address is on the clipboard. After “OK” the settings open. In each one:') + "`r`n`r`n" +
                 (Tx '   „Beim Start“ → „Bestimmte Seiten öffnen“' '   “On startup” → “Open a specific page or set of pages”') + "`r`n" +
                 (Tx '   → „Neue Seite hinzufügen“ → Strg+V → Hinzufügen' '   → “Add a new page” → Ctrl+V → Add')
    }
    Show-Meldung $text | Out-Null
    if ($O.Browser.Count) { Open-BrowserEinstellungen $O.Browser }
    if ($O.Oeffnen) { Start-Process $Ausgabe }
}

function Invoke-Entfernen {
    $hinweis = ''
    Remove-Autostart; Remove-Desktoplink; Remove-FirefoxStartseite
    if (Test-Richtlinie) {
        $okRichtlinie = $false
        if ($Oberflaeche) { $okRichtlinie = Invoke-RichtlinieAlsAdmin -Entfernen } else { $okRichtlinie = Remove-Richtlinie }
        if (-not $okRichtlinie) { $hinweis = (Tx 'Die Richtlinie für Chrome/Edge/Brave konnte ohne Administratorrechte nicht entfernt werden.' 'The Chrome/Edge/Brave policy could not be removed without administrator rights.') }
    }
    if (Test-Path -LiteralPath $InstallOrdner) {
        try { Remove-Item -LiteralPath $InstallOrdner -Recurse -Force }
        catch { $hinweis += " " + (Tx "Der Ordner $InstallOrdner konnte nicht vollständig gelöscht werden." "The folder $InstallOrdner could not be deleted completely.") }
    }
    Info 'Startseite entfernt.'
    if ($hinweis) { Write-Warning $hinweis }
    return $hinweis
}

# ---------------------------------------------------------------------------
#  Ablauf
# ---------------------------------------------------------------------------

# Hilfsaufruf mit Adminrechten aus der Oberfläche
if ($NurRichtlinie) {
    if ($Deinstallieren) { if (Remove-Richtlinie) { exit 0 } else { exit 1 } }
    if ((Set-Richtlinie (Get-SeitenUrl)) -eq $PolicyKeys.Count) { exit 0 } else { exit 1 }
}

if ($Oberflaeche) {
    # Konsolenfenster ausblenden (nicht per -WindowStyle Hidden, sonst bleibt auch der Dialog unsichtbar)
    try {
        Add-Type -Name Konsole -Namespace Startseite -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);'
        [Startseite.Konsole]::ShowWindow([Startseite.Konsole]::GetConsoleWindow(), 0) | Out-Null
    } catch { }
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    try {
        $wahl = Show-Einrichtung
        if ($wahl.Aktion -eq 'einrichten') { Invoke-Einrichtung $wahl }
        elseif ($wahl.Aktion -eq 'entfernen') {
            if ((Show-Meldung (Tx 'Startseite, Autostart, Desktop-Verknüpfung und Browser-Eintragungen wirklich entfernen?' 'Really remove the start page, autostart, desktop shortcut and browser settings?') 'Question' 'YesNo') -eq 'Yes') {
                $h = Invoke-Entfernen
                Show-Meldung ((Tx 'Die Startseite wurde entfernt. ' 'The start page has been removed. ') + $h).Trim() | Out-Null
            }
        }
    } catch {
        Show-Meldung ((Tx 'Bei der Einrichtung ist ein Fehler aufgetreten:' 'Setup failed:') + "`r`n`r`n$($_.Exception.Message)") 'Error' | Out-Null
        exit 1
    }
    return
}

if ($Deinstallieren) {
    Write-Host 'Startseite wird entfernt …' -ForegroundColor Cyan
    Invoke-Entfernen | Out-Null
    return
}

if ($Installieren) { Copy-App }

New-Startseite

if ($Installieren) {
    $url = Get-SeitenUrl
    Write-Host ''
    Write-Host 'Einrichtung …' -ForegroundColor Cyan
    Set-Autostart
    Set-FirefoxStartseite $url
    if ($Richtlinie) { Set-Richtlinie $url | Out-Null }
    else { Info 'Chrome / Edge / Brave: Startseite bitte in den Einstellungen eintragen (oder -Richtlinie als Administrator).' }
    Info "Adresse: $url"
}

if ($Oeffnen) { Start-Process $Ausgabe }
