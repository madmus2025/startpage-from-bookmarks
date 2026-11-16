// Startseite für macOS – baut aus den Lesezeichen aller Browser eine Startseite.
// Läuft ohne Zusatzsoftware mit JavaScript for Automation (JXA):
//   /usr/bin/osascript -l JavaScript Startseite-mac.js               → Seite neu erzeugen
//   /usr/bin/osascript -l JavaScript Startseite-mac.js --einrichten  → Einrichtungsfenster
//   /usr/bin/osascript -l JavaScript Startseite-mac.js --entfernen   → alles entfernen
//   … --ausgabe /pfad/seite.html                                     → anderer Zielpfad
//
// Die Logik (Zusammenführen, Themen) entspricht Startseite.ps1 (Windows). Änderungen bitte in beiden Dateien pflegen.

/* =====================================================================
   Kern – reines JavaScript (auch mit Node testbar)
   ===================================================================== */

const TRACKING = /^(utm_[a-z_]+|fbclid|gclid|dclid|gbraid|wbraid|msclkid|mc_cid|mc_eid|_ga|_gl|igshid|yclid|ref_src|si)$/i;

function neuesLesezeichen(liste, titel, url, pfad, leiste, quelle) {
  if (!url || !/^https?:\/\//i.test(url)) return;
  pfad = (pfad || []).filter(Boolean);
  liste.push({
    Titel: String(titel || '').trim(), Url: String(url).trim(),
    Ordner: pfad.join(' / '), Top: pfad.length ? pfad[0] : '',
    Leiste: !!leiste && pfad.length === 0, Quelle: quelle
  });
}

// --- Chromium (Chrome, Edge, Brave, Vivaldi, Opera …): Datei "Bookmarks" (JSON)
function leseChromium(json, quelle, liste) {
  const knoten = (k, pfad, leiste) => {
    if (!k) return;
    if (k.type === 'url') neuesLesezeichen(liste, k.name, k.url, pfad, leiste, quelle);
    else if (k.type === 'folder') for (const c of k.children || []) knoten(c, pfad.concat(k.name), leiste);
  };
  for (const w of ['bookmark_bar', 'other', 'synced']) {
    const r = json.roots && json.roots[w];
    if (r) for (const c of r.children || []) knoten(c, [], w === 'bookmark_bar');
  }
}

// --- Firefox: automatische Sicherung bookmarkbackups/*.jsonlz4 (Mozillas LZ4-Format)
function lz4Block(src, start, groesse) {
  const dst = new Uint8Array(groesse); let s = start, d = 0;
  while (s < src.length) {
    const token = src[s++]; let lit = token >> 4;
    if (lit === 15) { let b; do { b = src[s++]; lit += b; } while (b === 255); }
    for (let i = 0; i < lit; i++) dst[d++] = src[s++];
    if (s >= src.length) break;
    const off = src[s] | (src[s + 1] << 8); s += 2;
    let ml = token & 15;
    if (ml === 15) { let b; do { b = src[s++]; ml += b; } while (b === 255); }
    ml += 4; const m = d - off;
    for (let i = 0; i < ml; i++) dst[d++] = dst[m + i];
  }
  return dst.subarray(0, d);
}
function utf8(bytes) {
  let out = '', i = 0;
  while (i < bytes.length) {
    const c = bytes[i++];
    if (c < 0x80) out += String.fromCharCode(c);
    else if (c < 0xE0) out += String.fromCharCode(((c & 31) << 6) | (bytes[i++] & 63));
    else if (c < 0xF0) out += String.fromCharCode(((c & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63));
    else {
      const cp = ((c & 7) << 18) | ((bytes[i++] & 63) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
      out += String.fromCodePoint(cp);
    }
  }
  return out;
}
function mozLz4(bytes) {
  const magic = String.fromCharCode.apply(null, Array.from(bytes.subarray(0, 7)));
  if (magic !== 'mozLz40') throw new Error('unbekanntes Dateiformat');
  const groesse = bytes[8] | (bytes[9] << 8) | (bytes[10] << 16) | (bytes[11] << 24);
  return utf8(lz4Block(bytes, 12, groesse));
}
function leseFirefox(json, quelle, liste) {
  const knoten = (k, pfad, leiste) => {
    if (!k) return;
    if (k.uri) neuesLesezeichen(liste, k.title, k.uri, pfad, leiste, quelle);
    else if (k.children) for (const c of k.children) knoten(c, pfad.concat(k.title), leiste);
  };
  for (const w of json.children || []) {
    const leiste = w.guid === 'toolbar_____';
    for (const c of w.children || []) knoten(c, [], leiste);
  }
}

// --- Safari: ~/Library/Safari/Bookmarks.plist (als Objekt)
function leseSafari(plist, quelle, liste) {
  const knoten = (k, pfad, leiste) => {
    if (!k) return;
    if (k.WebBookmarkType === 'WebBookmarkTypeLeaf') {
      neuesLesezeichen(liste, (k.URIDictionary && k.URIDictionary.title) || k.Title, k.URLString, pfad, leiste, quelle);
    } else if (k.WebBookmarkType === 'WebBookmarkTypeList') {
      for (const c of k.Children || []) knoten(c, pfad.concat(k.Title), leiste);
    }
  };
  for (const w of plist.Children || []) {
    if (w.WebBookmarkType !== 'WebBookmarkTypeList' || w.Title === 'com.apple.ReadingList') continue;
    const leiste = w.Title === 'BookmarksBar';
    for (const c of w.Children || []) knoten(c, [], leiste);
  }
}

// --- Adresse zerlegen (ohne URL-Klasse, die es in JXA nicht gibt)
function zerlege(url) {
  const m = /^(https?):\/\/([^\/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/i.exec(url);
  if (!m) return null;
  let host = m[2].replace(/^.*@/, ''), port = '';
  const pm = /^(.*):(\d+)$/.exec(host);
  if (pm && !/\]$/.test(host)) { host = pm[1]; port = pm[2]; }
  const schema = m[1].toLowerCase();
  if ((schema === 'http' && port === '80') || (schema === 'https' && port === '443')) port = '';
  return { schema, host: host.toLowerCase(), port, pfad: m[3] || '/', query: m[4] || '', fragment: m[5] || '' };
}

function schluessel(u, hostName) {
  let k = hostName + (u.port ? ':' + u.port : '');
  k += u.pfad.replace(/\/+$/, '').replace(/\/(index|default)\.(html?|php|aspx?)$/i, '');
  if (u.query.length > 1) {
    const teile = u.query.slice(1).split('&').filter(t => t && !TRACKING.test(t.split('=')[0])).sort();
    if (teile.length) k += '?' + teile.join('&');
  }
  if (/^#[!/]/.test(u.fragment)) k += u.fragment;
  return k;
}

function stichwortThema(text, konfig) {
  if (!text) return '';
  text = text.toLowerCase();
  for (const k of konfig.kategorien) {
    for (const w of k.stichworte || []) {
      if (!w) continue;
      const esc = w.toLowerCase().replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const muster = new RegExp('(?:^|[^\\p{L}\\p{N}])' + esc + (w.length <= 3 ? '(?![\\p{L}\\p{N}])' : ''), 'u');
      if (muster.test(text)) return k.name;
    }
  }
  return '';
}

function domainPasst(e, regel) {
  regel = regel.toLowerCase();
  if (regel.includes('/')) return e.HostPfad.startsWith(regel) || e.HostPfad.includes('.' + regel);
  return e.HostName === regel || e.HostName.endsWith('.' + regel);
}

function thema(e, konfig) {
  if (e.Thema) {   // Firmenlink mit festem Thema
    const k = konfig.kategorien.find(k => e.Thema === k.name || e.Thema === k.name_en);
    return k ? k.name : 'ordner:' + e.Thema;
  }
  let beste = '', laenge = 0;
  for (const k of konfig.kategorien) for (const d of k.domains || []) {
    if (d && d.length > laenge && domainPasst(e, d)) { beste = k.name; laenge = d.length; }
  }
  if (beste) return beste;
  const ordnerThema = stichwortThema(e.Ordner, konfig);
  if (ordnerThema) return ordnerThema;
  if (e.Top) return 'ordner:' + e.Top;
  return stichwortThema(e.Titel + ' ' + e.HostName, konfig);
}

const sortiere = (a, b) => a.Titel.localeCompare(b.Titel, 'de', { sensitivity: 'base' });
const zwei = n => (n < 10 ? '0' : '') + n;
function jetztLokal() {
  const d = new Date();
  return `${d.getFullYear()}-${zwei(d.getMonth() + 1)}-${zwei(d.getDate())}T${zwei(d.getHours())}:${zwei(d.getMinutes())}:${zwei(d.getSeconds())}`;
}
const htmlEsc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// Fasst Dubletten zusammen, gliedert nach Themen und setzt die Daten in die Vorlage ein
function baueSeite(alle, konfig, vorlage) {
  const map = new Map(); let ignoriert = 0;
  // Firmenlinks aus kategorien.json stehen bei allen auf der Seite (zuerst, damit sie im Schnellzugriff vorn liegen)
  const firma = (konfig.firmenlinks || []).filter(f => f && /^https?:\/\//i.test(f.url || '')).map(f => ({
    Titel: String(f.titel || '').trim(), Url: String(f.url).trim(), Ordner: '', Top: '',
    Leiste: !!f.schnellzugriff, Quelle: '', Firma: true, Thema: String(f.thema || '').trim()
  }));
  for (const b of firma.concat(alle)) {
    const u = zerlege(b.Url); if (!u) continue;
    const hostName = u.host.replace(/^www\./, '');
    const hostPfad = (hostName + u.pfad).toLowerCase();
    if ((konfig.ignorieren || []).some(r => r && (r = r.toLowerCase(), (r.includes('/') && hostPfad.startsWith(r)) || hostName === r))) { ignoriert++; continue; }
    const k = schluessel(u, hostName).toLowerCase();
    const browser = b.Quelle.split(' · ')[0];
    const titelOk = b.Titel && b.Titel !== b.Url;
    const x = map.get(k);
    if (x) {
      if (/^http:/i.test(x.Url) && /^https:/i.test(b.Url)) x.Url = b.Url;
      if (!x.Titel && titelOk) x.Titel = b.Titel;
      if (!x.Top && b.Top) { x.Top = b.Top; x.Ordner = b.Ordner; }
      if (b.Leiste) x.Leiste = true;
      if (b.Firma) { x.Firma = true; x.Thema = b.Thema; if (titelOk) x.Titel = b.Titel; }
      else if (!x.Browser.includes(browser)) x.Browser.push(browser);
    } else {
      map.set(k, { Titel: titelOk ? b.Titel : '', Url: b.Url, HostName: hostName, HostPfad: hostPfad, Ordner: b.Ordner, Top: b.Top, Leiste: b.Leiste,
                   Browser: b.Firma ? [] : [browser], Firma: !!b.Firma, Thema: b.Firma ? b.Thema : '' });
    }
  }
  const eintraege = [...map.values()];
  for (const x of eintraege) if (!x.Titel) x.Titel = x.HostName;
  const dubletten = firma.length + alle.length - ignoriert - eintraege.length;

  const gruppen = new Map();
  const add = (k, x) => { if (!gruppen.has(k)) gruppen.set(k, []); gruppen.get(k).push(x); };
  for (const x of eintraege) add(thema(x, konfig), x);
  const min = konfig.mindestOrdnerGroesse > 0 ? konfig.mindestOrdnerGroesse : 3;
  for (const k of [...gruppen.keys()].filter(k => k.startsWith('ordner:'))) {
    if (gruppen.get(k).length >= min || gruppen.get(k).some(x => x.Firma)) continue;
    for (const x of gruppen.get(k)) add(stichwortThema(x.Titel + ' ' + x.HostName, konfig), x);
    gruppen.delete(k);
  }

  const item = x => Object.assign({ t: x.Titel, u: x.Url, h: x.HostName, o: x.Ordner, b: x.Browser.slice() }, x.Firma ? { f: 1 } : {});
  const gruppe = (name, nameEn, icon, liste) => ({ name, name_en: nameEn || name, icon, items: liste.slice().sort(sortiere).map(item) });
  const kategorien = [];
  for (const k of konfig.kategorien) if (gruppen.has(k.name)) kategorien.push(gruppe(k.name, k.name_en, k.icon, gruppen.get(k.name)));
  for (const k of [...gruppen.keys()].filter(k => k.startsWith('ordner:')).sort((a, b) => a.localeCompare(b, 'de'))) {
    kategorien.push(gruppe(k.slice(7), k.slice(7), '📁', gruppen.get(k)));
  }
  if (gruppen.has('')) kategorien.push(gruppe(konfig.sonstiges.name, konfig.sonstiges.name_en, konfig.sonstiges.icon, gruppen.get('')));

  const maxSchnell = konfig.schnellzugriffMax > 0 ? konfig.schnellzugriffMax : 16;
  const quellen = [];
  for (const b of alle) { const q = quellen.find(q => q.name === b.Quelle); q ? q.anzahl++ : quellen.push({ name: b.Quelle, anzahl: 1 }); }

  const daten = {
    titel: konfig.titel, titel_en: konfig.titel_en, erstellt: jetztLokal(),
    gesamt: eintraege.length, roh: alle.length, dubletten, quellen,
    suche: konfig.suche, favicons: konfig.favicons, eintraegeProKarte: konfig.eintraegeProKarte,
    schnell: eintraege.filter(x => x.Leiste).slice(0, maxSchnell).map(item),
    kategorien
  };
  const json = JSON.stringify(daten).split('</').join('<\\/');
  const html = vorlage.split('/*__DATEN__*/null').join(json).split('__TITEL__').join(htmlEsc(konfig.titel));
  return { html, gesamt: eintraege.length, dubletten, themen: kategorien.length };
}

if (typeof module !== 'undefined') module.exports = { leseChromium, leseFirefox, leseSafari, mozLz4, baueSeite, zerlege, schluessel };

/* =====================================================================
   macOS-Teil (JXA): Dateien, Browser, Einrichtung
   ===================================================================== */

function macIO() {
  ObjC.import('Foundation');
  const fm = $.NSFileManager.defaultManager;
  const app = Application.currentApplication(); app.includeStandardAdditions = true;
  const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const b64 = s => {
    const map = {}; for (let i = 0; i < 64; i++) map[B64[i]] = i;
    s = s.replace(/[^A-Za-z0-9+/]/g, '');
    const out = new Uint8Array(Math.floor(s.length * 3 / 4)); let o = 0;
    for (let i = 0; i < s.length; i += 4) {
      const n = (map[s[i]] << 18) | (map[s[i + 1]] << 12) | ((map[s[i + 2]] || 0) << 6) | (map[s[i + 3]] || 0);
      out[o++] = (n >> 16) & 255; if (i + 2 < s.length) out[o++] = (n >> 8) & 255; if (i + 3 < s.length) out[o++] = n & 255;
    }
    return out.subarray(0, o);
  };
  const io = {
    app,
    home: ObjC.unwrap($.NSHomeDirectory()),
    exists: p => fm.fileExistsAtPath(p),
    istOrdner: p => { const d = Ref(); return fm.fileExistsAtPathIsDirectory(p, d) && !!d[0]; },
    liste: p => { const r = fm.contentsOfDirectoryAtPathError(p, null); return r.isNil() ? [] : ObjC.deepUnwrap(r); },
    lies: p => { const s = $.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null); if (s.isNil()) throw new Error('nicht lesbar: ' + p); return ObjC.unwrap(s); },
    schreib: (p, text) => {
      io.ordner(p.replace(/\/[^/]+$/, ''));
      if (!$(text).writeToFileAtomicallyEncodingError(p, true, $.NSUTF8StringEncoding, null)) throw new Error('nicht schreibbar: ' + p);
    },
    bytes: p => { const d = $.NSData.dataWithContentsOfFile(p); if (d.isNil()) throw new Error('nicht lesbar: ' + p); return b64(ObjC.unwrap(d.base64EncodedStringWithOptions(0))); },
    plist: p => { const d = $.NSDictionary.dictionaryWithContentsOfFile(p); return d.isNil() ? null : ObjC.deepUnwrap(d); },
    ordner: p => fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(p, true, $(), null),
    loesche: p => { if (fm.fileExistsAtPath(p)) fm.removeItemAtPathError(p, null); },
    kopiere: (a, b) => { io.loesche(b); fm.copyItemAtPathToPathError(a, b, null); },
    sh: cmd => app.doShellScript(cmd),
    sprache: () => ObjC.unwrap($.NSLocale.preferredLanguages.objectAtIndex(0)) || 'en'
  };
  return io;
}

const sh_q = s => "'" + String(s).replace(/'/g, "'\\''") + "'";
const dateiUrl = p => 'file://' + encodeURI(p);

const chromiumOrdner = home => {
  const AS = home + '/Library/Application Support';
  return [
    ['Google Chrome', AS + '/Google/Chrome'], ['Microsoft Edge', AS + '/Microsoft Edge'],
    ['Brave', AS + '/BraveSoftware/Brave-Browser'], ['Vivaldi', AS + '/Vivaldi'], ['Chromium', AS + '/Chromium'],
    ['Opera', AS + '/com.operasoftware.Opera'], ['Opera GX', AS + '/com.operasoftware.OperaGX']
  ];
};

// Dateien, deren Änderung eine neue Startseite auslöst (launchd „WatchPaths“)
function lesezeichenPfade(io) {
  const pfade = [];
  for (const [, ordner] of chromiumOrdner(io.home)) {
    if (!io.istOrdner(ordner)) continue;
    if (io.exists(ordner + '/Bookmarks')) pfade.push(ordner + '/Bookmarks');
    for (const p of io.liste(ordner)) if ((p === 'Default' || /^Profile /.test(p)) && io.exists(`${ordner}/${p}/Bookmarks`)) pfade.push(`${ordner}/${p}/Bookmarks`);
  }
  const ff = io.home + '/Library/Application Support/Firefox/Profiles';
  if (io.istOrdner(ff)) for (const p of io.liste(ff)) if (io.istOrdner(`${ff}/${p}/bookmarkbackups`)) pfade.push(`${ff}/${p}/bookmarkbackups`);
  const safari = io.home + '/Library/Safari/Bookmarks.plist';
  if (io.exists(safari)) pfade.push(safari);
  return pfade;
}

function sammleMac(io, hinweise, bericht = []) {
  const alle = [];
  const AS = io.home + '/Library/Application Support';
  const chromium = chromiumOrdner(io.home);
  for (const [name, ordner] of chromium) {
    if (!io.istOrdner(ordner)) continue;
    let namen = {};
    try { const ls = JSON.parse(io.lies(ordner + '/Local State')); for (const k in ls.profile.info_cache) namen[k] = ls.profile.info_cache[k].name; } catch (e) { }
    const dateien = [];
    if (io.exists(ordner + '/Bookmarks')) dateien.push([ordner + '/Bookmarks', '']);
    for (const p of io.liste(ordner)) if (p === 'Default' || /^Profile /.test(p)) if (io.exists(`${ordner}/${p}/Bookmarks`)) dateien.push([`${ordner}/${p}/Bookmarks`, p]);
    if (!dateien.length) bericht.push([name, 0]);
    for (const [datei, profil] of dateien) {
      const quelle = dateien.length > 1 ? `${name} · ${namen[profil] || profil}` : name;
      const vorher = alle.length;
      try { leseChromium(JSON.parse(io.lies(datei)), quelle, alle); console.log(`  ${quelle}: ${alle.length - vorher}`); bericht.push([quelle, alle.length - vorher]); }
      catch (e) { hinweise.push(`${quelle}: ${e.message}`); }
    }
  }
  // Firefox
  const ff = AS + '/Firefox/Profiles';
  const profile = io.istOrdner(ff) ? io.liste(ff).filter(p => io.istOrdner(`${ff}/${p}/bookmarkbackups`)) : [];
  // Firefox installiert, aber noch keine Lesezeichen-Sicherung geschrieben
  if (io.istOrdner(ff) && !profile.some(p => io.liste(`${ff}/${p}/bookmarkbackups`).some(f => /\.jsonlz4$/.test(f)))) hinweise.push('FIREFOX_SICHERUNG');
  for (const p of profile) {
    const dir = `${ff}/${p}/bookmarkbackups`;
    const datei = io.liste(dir).filter(f => /\.jsonlz4$/.test(f)).sort().pop();
    if (!datei) continue;
    const quelle = profile.length > 1 ? 'Firefox · ' + p.replace(/^[^.]+\./, '') : 'Firefox';
    const vorher = alle.length;
    try { leseFirefox(JSON.parse(mozLz4(io.bytes(`${dir}/${datei}`))), quelle, alle); console.log(`  ${quelle}: ${alle.length - vorher}`); bericht.push([quelle, alle.length - vorher]); }
    catch (e) { hinweise.push(`${quelle}: ${e.message}`); }
  }
  // Safari (benötigt "Festplattenvollzugriff" für Terminal bzw. osascript)
  const safari = io.home + '/Library/Safari/Bookmarks.plist';
  if (io.exists(safari)) {
    const pl = io.plist(safari);
    if (pl) { const vorher = alle.length; leseSafari(pl, 'Safari', alle); console.log(`  Safari: ${alle.length - vorher}`); bericht.push(['Safari', alle.length - vorher]); }
    else hinweise.push('SAFARI_ZUGRIFF');
  }
  return alle;
}

const L = {
  de: {
    titel: 'Startseite einrichten', ok: 'Einrichten', abbrechen: 'Abbrechen',
    prompt: 'Die Startseite wird aus den Lesezeichen aller Browser erzeugt. Ausgewählte Optionen werden eingerichtet (⌘-Klick zum An-/Abwählen):',
    auto: 'Automatisch aktualisieren (bei jeder Lesezeichen-Änderung, bei Anmeldung und alle 2 Stunden)',
    desktop: 'Verknüpfung „Startseite“ auf dem Schreibtisch',
    firefox: 'Firefox: als Startseite eintragen (automatisch)',
    oeffnen: 'Startseite nach dem Einrichten öffnen',
    browser: n => `${n}: Einstellungen öffnen (Adresse in der Zwischenablage)`,
    fertig: 'Die Startseite ist eingerichtet.',
    zusammen: (g, d, t) => `${g} Lesezeichen, ${d} Dubletten zusammengeführt, ${t} Themen`,
    okAuto: 'Wird bei jeder Lesezeichen-Änderung aktualisiert (nach wenigen Sekunden), außerdem bei Anmeldung und alle 2 Stunden', okDesktop: 'Verknüpfung auf dem Schreibtisch', okFirefox: 'Firefox: als Startseite eingetragen (nach Neustart)',
    handgriff: n => `Noch ein Handgriff für ${n}:\nDie Adresse ist in der Zwischenablage. Nach „OK“ öffnen sich die Einstellungen.\n\n` +
      `• Chrome/Edge/Brave: „Beim Start“ → „Bestimmte Seiten öffnen“ → „Neue Seite hinzufügen“ → ⌘V\n` +
      `• Safari: Einstellungen (⌘,) → Allgemein → „Homepage“ → ⌘V, und „Neue Fenster öffnen mit: Homepage“`,
    safariZugriff: 'Safari: kein Zugriff auf die Lesezeichen. Bitte in Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff „Terminal“ (und für die automatische Aktualisierung „/usr/bin/osascript“, mit ⌘⇧G eingeben) erlauben und danach „Installieren-Mac.command“ erneut starten.',
    firefoxSicherung: 'Firefox: noch keine Lesezeichen-Sicherung vorhanden. Firefox legt sie automatisch an (etwa einmal täglich); danach erscheinen die Firefox-Lesezeichen beim nächsten Aktualisieren.',
    quellen: q => 'Gefunden: ' + (q.length ? q.map(([n, a]) => `${n} ${a}`).join(' · ') : 'keine Browser-Lesezeichen'),
    zugriffOeffnen: 'Festplattenvollzugriff öffnen',
    entfernenFrage: 'Startseite, automatische Aktualisierung, Verknüpfung und Firefox-Eintrag wirklich entfernen?',
    entfernt: 'Die Startseite wurde entfernt.', ja: 'Entfernen', fehler: 'Bei der Einrichtung ist ein Fehler aufgetreten:'
  },
  en: {
    titel: 'Set up start page', ok: 'Set up', abbrechen: 'Cancel',
    prompt: 'The start page is built from the bookmarks of all your browsers. Selected options will be set up (⌘-click to toggle):',
    auto: 'Update automatically (whenever bookmarks change, at login and every 2 hours)',
    desktop: 'Shortcut “Startseite” on the desktop',
    firefox: 'Firefox: set as home page (automatic)',
    oeffnen: 'Open the start page when done',
    browser: n => `${n}: open settings (address on clipboard)`,
    fertig: 'The start page is set up.',
    zusammen: (g, d, t) => `${g} bookmarks, ${d} duplicates merged, ${t} topics`,
    okAuto: 'Updates whenever bookmarks change (within seconds), plus at login and every 2 hours', okDesktop: 'Desktop shortcut', okFirefox: 'Firefox: set as home page (after restart)',
    handgriff: n => `One more step for ${n}:\nThe address is on the clipboard. After “OK” the settings open.\n\n` +
      `• Chrome/Edge/Brave: “On startup” → “Open a specific page or set of pages” → “Add a new page” → ⌘V\n` +
      `• Safari: Settings (⌘,) → General → “Homepage” → ⌘V, and “New windows open with: Homepage”`,
    safariZugriff: 'Safari: no access to bookmarks. Please allow “Terminal” (and “/usr/bin/osascript” for automatic updates, enter it with ⌘⇧G) under System Settings → Privacy & Security → Full Disk Access, then run “Installieren-Mac.command” again.',
    firefoxSicherung: 'Firefox: no bookmark backup yet. Firefox creates it automatically (about once a day); the Firefox bookmarks will appear with the next update.',
    quellen: q => 'Found: ' + (q.length ? q.map(([n, a]) => `${n} ${a}`).join(' · ') : 'no browser bookmarks'),
    zugriffOeffnen: 'Open Full Disk Access',
    entfernenFrage: 'Really remove the start page, automatic updates, shortcut and Firefox setting?',
    entfernt: 'The start page has been removed.', ja: 'Remove', fehler: 'Setup failed:'
  }
};

function run(argv) {
  const io = macIO();
  const T = /^de\b/i.test(io.sprache()) ? L.de : L.en;
  const installOrdner = io.home + '/Library/Application Support/Startseite';
  const agentLabel = 'local.startseite.aktualisieren';
  const agentPlist = `${io.home}/Library/LaunchAgents/${agentLabel}.plist`;
  const desktopLink = io.home + '/Desktop/Startseite.html';
  const desktopAlt = io.home + '/Desktop/Startseite.webloc';   // frühere Fassung, wird entfernt
  const ffProfile = io.home + '/Library/Application Support/Firefox/Profiles';
  const ffMuster = /\/\/ >>> Startseite[\s\S]*?\/\/ <<< Startseite\r?\n?/g;
  const dateien = ['Startseite-mac.js', 'kategorien.json', 'startseite.vorlage.html'];

  // Ordner dieses Skripts (aus den Startargumenten von osascript)
  const args = ObjC.deepUnwrap($.NSProcessInfo.processInfo.arguments);
  const skript = args.find(a => /\.js$/i.test(a)) || (installOrdner + '/Startseite-mac.js');
  let basis = skript.replace(/\/[^/]+$/, '');
  if (!basis.startsWith('/')) basis = ObjC.unwrap($.NSFileManager.defaultManager.currentDirectoryPath) + '/' + basis;

  const ai = argv.indexOf('--ausgabe');
  const ausgabe = ai > -1 ? argv[ai + 1] : installOrdner + '/index.html';
  const url = dateiUrl(ausgabe);
  const dialog = (text, knoepfe) => io.app.displayDialog(text, { withTitle: T.titel, buttons: knoepfe || ['OK'], defaultButton: (knoepfe || ['OK']).slice(-1)[0] });

  const erzeuge = () => {
    const hinweise = [];
    const konfig = JSON.parse(io.lies(basis + '/kategorien.json'));
    const vorlage = io.lies(basis + '/startseite.vorlage.html');
    console.log('Lesezeichen werden gesammelt …');
    const bericht = [];
    const alle = sammleMac(io, hinweise, bericht);
    const r = baueSeite(alle, konfig, vorlage);
    io.schreib(ausgabe, r.html);
    console.log(`Fertig: ${r.gesamt} Lesezeichen, ${r.dubletten} Dubletten, ${r.themen} Themen → ${ausgabe}`);
    hinweise.forEach(h => console.log('  Hinweis: ' + h));
    return { r, hinweise, bericht };
  };

  const firefoxSetzen = an => {
    if (!io.istOrdner(ffProfile)) return;
    for (const p of io.liste(ffProfile)) {
      const dir = `${ffProfile}/${p}`; if (!io.istOrdner(dir)) continue;
      const datei = dir + '/user.js';
      const alt = io.exists(datei) ? io.lies(datei) : '';
      const ohne = alt.replace(ffMuster, '');
      const neu = an ? ohne + `// >>> Startseite\nuser_pref("browser.startup.homepage", "${url}");\nuser_pref("browser.startup.page", 1);\n// <<< Startseite\n` : ohne;
      if (neu.trim()) io.schreib(datei, neu); else io.loesche(datei);
    }
  };
  const uid = () => io.sh('id -u').trim();
  const agentSetzen = an => {
    try { io.sh(`launchctl bootout gui/${uid()} ${sh_q(agentPlist)} 2>/dev/null || true`); } catch (e) { }
    if (!an) { io.loesche(agentPlist); return; }
    io.schreib(agentPlist, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${agentLabel}</string>
  <key>ProgramArguments</key><array><string>/usr/bin/osascript</string><string>-l</string><string>JavaScript</string><string>${htmlEsc(installOrdner + '/Startseite-mac.js')}</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>7200</integer>
  <key>WatchPaths</key><array>${lesezeichenPfade(io).map(p => `<string>${htmlEsc(p)}</string>`).join('')}</array>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardErrorPath</key><string>${htmlEsc(installOrdner + '/protokoll.txt')}</string>
</dict></plist>
`);
    io.sh(`launchctl bootstrap gui/${uid()} ${sh_q(agentPlist)} 2>/dev/null || true`);
  };
  const desktopSetzen = an => {
    // .webloc mit file://-Adresse blockiert macOS („Dokument konnte nicht geöffnet werden“) → symbolischer Link auf die Seite
    io.loesche(desktopAlt);
    io.sh(`rm -f ${sh_q(desktopLink)}`);
    if (an) io.sh(`ln -s ${sh_q(ausgabe)} ${sh_q(desktopLink)}`);
  };
  const browserListe = () => {
    const apps = [['Safari', '/Applications/Safari.app', '', ''],
      ['Google Chrome', '/Applications/Google Chrome.app', 'Contents/MacOS/Google Chrome', 'chrome://settings/onStartup'],
      ['Microsoft Edge', '/Applications/Microsoft Edge.app', 'Contents/MacOS/Microsoft Edge', 'edge://settings/startHomeNTP'],
      ['Brave', '/Applications/Brave Browser.app', 'Contents/MacOS/Brave Browser', 'brave://settings/getStarted']];
    const liste = [];
    for (const [name, pfad, bin, seite] of apps) {
      const p = io.exists(pfad) ? pfad : (io.exists(io.home + pfad) ? io.home + pfad : '');
      if (p) liste.push({ name, app: p, bin: bin ? p + '/' + bin : '', seite });
    }
    return liste;
  };

  try {
    // --- Entfernen
    if (argv.includes('--entfernen')) {
      if (dialog(T.entfernenFrage, [T.abbrechen, T.ja]).buttonReturned !== T.ja) return;
      agentSetzen(false); desktopSetzen(false); firefoxSetzen(false); io.loesche(installOrdner);
      dialog(T.entfernt);
      return;
    }

    // --- Nur erzeugen (Standard, auch für die automatische Aktualisierung)
    if (!argv.includes('--einrichten')) { erzeuge(); return; }

    // --- Einrichtungsfenster
    const browser = browserListe();
    const optionen = [
      { id: 'auto', text: T.auto, an: true },
      { id: 'desktop', text: T.desktop, an: true },
      ...(io.istOrdner(ffProfile) ? [{ id: 'firefox', text: T.firefox, an: true }] : []),
      ...browser.map(b => ({ id: 'b:' + b.name, text: T.browser(b.name), an: true, b })),
      { id: 'oeffnen', text: T.oeffnen, an: true }
    ];
    const wahl = io.app.chooseFromList(optionen.map(o => o.text), {
      withTitle: T.titel, withPrompt: T.prompt, defaultItems: optionen.filter(o => o.an).map(o => o.text),
      okButtonName: T.ok, cancelButtonName: T.abbrechen, multipleSelectionsAllowed: true, emptySelectionAllowed: true
    });
    if (wahl === false) return;
    const an = id => optionen.some(o => o.id === id && wahl.includes(o.text));

    // App-Dateien in den festen Ordner kopieren
    if (basis !== installOrdner) {
      io.ordner(installOrdner);
      for (const f of dateien) io.kopiere(`${basis}/${f}`, `${installOrdner}/${f}`);
      basis = installOrdner;
    }
    const { r, hinweise, bericht } = erzeuge();
    const zeilen = ['✔  ' + T.zusammen(r.gesamt, r.dubletten, r.themen), '     ' + T.quellen(bericht)];
    agentSetzen(an('auto')); if (an('auto')) zeilen.push('✔  ' + T.okAuto);
    desktopSetzen(an('desktop')); if (an('desktop')) zeilen.push('✔  ' + T.okDesktop);
    if (io.istOrdner(ffProfile)) { firefoxSetzen(an('firefox')); if (an('firefox')) zeilen.push('✔  ' + T.okFirefox); }
    for (const h of hinweise) zeilen.push('⚠  ' + (h === 'SAFARI_ZUGRIFF' ? T.safariZugriff : h === 'FIREFOX_SICHERUNG' ? T.firefoxSicherung : h));

    const gewaehlt = browser.filter(b => an('b:' + b.name));
    let text = T.fertig + '\n\n' + zeilen.join('\n');
    if (gewaehlt.length) { io.app.setTheClipboardTo(url); text += '\n\n' + T.handgriff(gewaehlt.map(b => b.name).join(', ')); }
    const ohneZugriff = hinweise.includes('SAFARI_ZUGRIFF');
    const antwort = dialog(text, ohneZugriff ? [T.zugriffOeffnen, 'OK'] : ['OK']);
    if (ohneZugriff && antwort.buttonReturned === T.zugriffOeffnen) io.sh(`open ${sh_q('x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles')}`);
    for (const b of gewaehlt) {
      if (b.seite) io.sh(`nohup ${sh_q(b.bin)} ${sh_q(b.seite)} >/dev/null 2>&1 &`);
      else io.sh(`open -a ${sh_q(b.app)}`);
    }
    if (an('oeffnen')) io.sh(`open ${sh_q(ausgabe)}`);
  } catch (e) {
    if (argv.includes('--einrichten') || argv.includes('--entfernen')) dialog(T.fehler + '\n\n' + e.message);
    else throw e;
  }
}
