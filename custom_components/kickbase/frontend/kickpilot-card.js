/*
 * Kickpilot card – dashboard for the Kickbase integration.
 * Usage: type: custom:kickpilot-card   (optional: device_id, design: app|ha)
 * Design comes from the integration options (Einstellungen → Design des Dashboards)
 * unless overridden in the card config.
 * Every write action (bids, sales) asks for confirmation first.
 */

const KEYS = {
  budget: ["sensor", "_budget"],
  team_value: ["sensor", "_teamwert"],
  budget_after_bids: ["sensor", "_budget_nach_geboten"],
  open_bids: ["sensor", "_offene_gebote"],
  debt_limit: ["sensor", "_minus_grenze"],
  bid_limit: ["sensor", "_gebotsrahmen_bis_freitag"],
  buy_proposals: ["sensor", "_kaufvorschlage"],
  sale_proposals: ["sensor", "_verkaufsvorschlage"],
  next_deadline: ["sensor", "_nachste_frist"],
  placement: ["sensor", "_platz"],
  squad_size: ["sensor", "_kader"],
  data_status: ["sensor", "_datenstand_transfers_und_marktwerte"],
  balance_needed: ["binary_sensor", "_ausgleich_notig"],
  lineup_problem: ["binary_sensor", "_aufstellung_prufen"],
  upgrades: ["sensor", "_verstarkungen"],
  trend_sales: ["sensor", "_verkaufssignale"],
  league_gap: ["sensor", "_abstand_zum_ersten"],
  capital: ["sensor", "_kapital"],
  automation: ["switch", "_automatik_aktiv"],
  mode_bids: ["select", "_betriebsart_gebote"],
  mode_sales: ["select", "_betriebsart_verkaufe"],
};

// ---- Vereine: Kürzel + Vereinsfarben als Muster (keine Logos) -------------
// Kickbase-Vereins-ID → Kurzname (wie in /competitions/1/table); weitere Namen
// liefert die Integration im Attribut `vereine` des Kader-Sensors.
const TEAM_NAMES = {
  2: "Bayern", 3: "Dortmund", 4: "Frankfurt", 5: "Freiburg", 6: "Hamburg", 7: "Leverkusen", 8: "Schalke",
  9: "Stuttgart", 10: "Bremen", 13: "Augsburg", 14: "Hoffenheim", 15: "M'gladbach", 18: "Mainz", 28: "Köln",
  29: "Paderborn", 40: "Union Berlin", 43: "Leipzig", 77: "Elversberg",
};
const W = "#ffffff", K = "#111111";
const half = (a, b, deg) => `linear-gradient(${deg}deg, ${a} 50%, ${b} 50%)`;
const tri = (a, b, c, deg) => `linear-gradient(${deg}deg, ${a} 0 33.3%, ${b} 0 66.6%, ${c} 0)`;
const stripes = (a, b, deg) => `repeating-linear-gradient(${deg}deg, ${a} 0 25%, ${b} 25% 50%)`;
const band = (a, b, deg) => `linear-gradient(${deg}deg, ${a} 0 38%, ${b} 38% 62%, ${a} 62%)`;
const ring = (inner, outer) => `radial-gradient(circle, ${inner} 0 50%, ${outer} 53%)`;
const quarters = (a, b) => `conic-gradient(${a} 0 25%, ${b} 0 50%, ${a} 0 75%, ${b} 0)`;
const CLUBS = {
  // Rot-Weiß: sechs Vereine, sechs Muster
  "Bayern": ["FCB", quarters("#DC052D", W)],
  "Stuttgart": ["VfB", band(W, "#E32219", 180)],
  "Köln": ["KOE", half(W, "#ED1C24", 180)],
  "Union Berlin": ["FCU", stripes("#D4011D", W, 90)],
  "Mainz": ["M05", half("#C3141E", W, 135)],
  "Leipzig": ["RBL", ring(W, "#DD0741")],
  // Rot-Schwarz
  "Leverkusen": ["B04", half(K, "#E32221", 90)],
  "Frankfurt": ["SGE", half(K, "#E1000F", 180)],
  "Freiburg": ["SCF", stripes("#E2001A", K, 180)],
  // Blau
  "Hoffenheim": ["TSG", half("#1C63B7", W, 90)],
  "Schalke": ["S04", half("#004D9D", W, 180)],
  "Hamburg": ["HSV", tri("#0A3F86", W, K, 180)],
  "Paderborn": ["SCP", stripes("#005CA9", K, 90)],
  // Schwarz-Weiß und eindeutige Farben
  "Elversberg": ["SVE", half(K, W, 135)],
  "M'gladbach": ["BMG", tri(K, W, "#00915A", 90)],
  "Dortmund": ["BVB", half("#FDE100", K, 90)],
  "Bremen": ["SVW", half("#1D9053", W, 90)],
  "Augsburg": ["FCA", tri("#BA3733", W, "#46714D", 90)],
  // Mögliche Aufsteiger späterer Saisons
  "Wolfsburg": ["WOB", ring(W, "#65B32E")],
  "Heidenheim": ["FCH", half("#E30613", "#003B79", 90)],
  "St. Pauli": ["STP", half("#5C3A21", W, 90)],
  "Bochum": ["BOC", half("#005CA9", W, 135)],
  "Kiel": ["KSV", tri("#00438A", W, "#E3001B", 180)],
  "Hertha": ["BSC", stripes("#005CA9", W, 180)],
  "Darmstadt": ["SVD", quarters("#004E9E", W)],
  "Düsseldorf": ["F95", band(W, "#E2001A", 135)],
};
// Erklärungen hinter den Info-Zeichen (Regeln aus AutoTransfer.swift / planner.py).
const INFO = {
  bid_limit:
    "So viel kannst du bis zur Frist (Freitag 20:30 Uhr) insgesamt bieten und dein Budget trotzdem rechtzeitig ins Plus bringen: " +
    "Budget abzüglich offener Gebote plus der Marktwert aller Spieler außerhalb deiner Top 11 (nach Ø-Punkten). " +
    "Die kann man jederzeit für 100 % des Marktwerts an Kickbase verkaufen. " +
    "Käufe, die erst nach Freitag 20:30 Uhr zustande kommen, zählen für die Folgewoche – danach darfst du sofort wieder ins Minus gehen.",
  debt_limit:
    "Ligaregel: Mit allen Geboten zusammen darf dein Budget höchstens auf −30 % deines Teamwerts fallen " +
    "(Teamwert = Summe der Marktwerte deines Kaders). Gebote darüber hinaus schlägt Kickpilot nie vor. " +
    "Unabhängig davon muss das Budget jeden Freitag um 20:30 Uhr wieder mindestens 0 sein.",
  mode_bids:
    "Zu den Prüfzeiten sucht Kickpilot Kaufkandidaten: fit, Angebot endet heute, Marktwert stabil steigend " +
    "(4 von 5 Tagen) oder Trendumkehr, noch unter dem letzten Hochpunkt und erwarteter Gewinn nach 3 Tagen " +
    "mindestens 5 % bzw. 100.000 €. Kickbase aktualisiert die Marktwerte täglich um 22:00 Uhr – die Prüfung danach " +
    "sieht schon die neuen Werte. Gebot = Marktwert + üblicher Aufpreis des stärksten Konkurrenten + 1 Prozentpunkt.\n\n" +
    "Halbautomatisch: Vorschläge kommen aufs Handy, geboten wird erst nach deiner Bestätigung.\n" +
    "Vollautomatisch: Gebote werden ohne Rückfrage abgegeben, begrenzt durch Anzahl und Tagessumme aus den Einstellungen.",
  lineup:
    "Kickpilot prüft deine Startelf vor dem ersten Anpfiff des Spieltags (meist Freitag 20:30 Uhr): Sind alle 11 " +
    "Plätze besetzt, sind alle Spieler fit und hat ihr Verein an diesem Spieltag ein Spiel? Bis dahin muss die " +
    "Aufstellung stehen, danach gilt sie für den ganzen Spieltag. Als Ersatz schlägt Kickpilot den fitten Bankspieler derselben " +
    "Position mit dem besten Ø vor. Tipps zeigen Bankspieler, die im Schnitt mindestens 20 Punkte mehr holen.\n\n" +
    "Die Warnung kommt per Push vor dem ersten Anpfiff (Vorlauf in den Einstellungen). Ändern musst du die Aufstellung " +
    "selbst in der Kickbase-App.",
  upgrades:
    "Punkteprognose für den nächsten Spieltag: halb Saison-Ø, halb Ø der letzten 4 Spieltage – mal Einsatzquote " +
    "(verpasste Spiele zählen), angepasst an den Tabellenplatz des Gegners (±20 %) und Heim/Auswärts (±5 %). " +
    "Angeschlagene zählen halb, Verletzte und Gesperrte 0.\n\n" +
    "Vorgeschlagen werden Marktspieler, deren Angebot heute endet und die mindestens 20 Punkte mehr bringen als " +
    "dein schwächster Starter derselben Position. Gebot und Budgetregeln wie bei den Kaufvorschlägen. " +
    "Nie automatisch – immer mit Bestätigung.",
  trend_sales:
    "Verletzte und angeschlagene Spieler sofort – auch aus deiner Top 11. Außerdem Spieler außerhalb deiner " +
    "Top 11 (Ø-Punkte), deren Marktwert seit 2 Tagen fällt und mindestens 3 % unter dem Hoch der letzten 14 Tage " +
    "liegt. Wert = aktueller Marktwert, Gewinn/Verlust = Änderung seit dem Kauf. Verkauf an Kickbase bringt 100 % des aktuellen Marktwerts – vor dem nächsten " +
    "Update um 22:00 Uhr noch den heutigen. Mindestbesetzung bleibt erhalten. Immer mit Bestätigung.",
  radar:
    "Alle Manager der Liga mit Gesamtpunkten, Abstand zum Ersten, Punkten am aktuellen Spieltag und Teamwert. " +
    "🚑 zeigt verletzte oder gesperrte Spieler in der Startelf der Konkurrenz.",
  capital:
    "Kapital = Budget + Teamwert. Der Zuwachs pro Tag ist die Wertänderung deines heutigen Kaders in den letzten " +
    "14 Tagen. Die Prognosen schreiben ihn bis zur Winterpause bzw. zum Saisonende fort – eine grobe Richtung, " +
    "keine Garantie. Kaufkraft = Gebotsrahmen bis Freitag.",
  mode_sales:
    "Freitags zu den eingestellten Zeiten prüft Kickpilot, ob dein Budget nach offenen Geboten zur Frist " +
    "(20:30 Uhr) im Minus wäre. Dann schlägt es Verkäufe an Kickbase (100 % des Marktwerts) vor: zuerst die " +
    "schwächsten Spieler nach Ø-Punkten mit dem besten Wertzuwachs, die Top 11 zuletzt. Mindestens 1 Torhüter, " +
    "3 Abwehrspieler und 1 Stürmer bleiben immer im Kader. Der Marktwert ändert sich erst um 22:00 Uhr, " +
    "der Erlös ist freitags bis zur Frist also immer gleich.\n\n" +
    "Halbautomatisch: Verkauft wird erst nach deiner Bestätigung.\n" +
    "Vollautomatisch: Verkäufe laufen ohne Rückfrage, höchstens so viele wie in den Einstellungen erlaubt.",
};
const POS_ORDER = { TW: 1, ABW: 2, MIT: 3, ST: 4 };
const POS_COLORS = { TW: "#f59e0b", ABW: "#60a5fa", MIT: "#a78bfa", ST: "#f87171" };
const NUM = new Intl.NumberFormat("de-DE", { maximumFractionDigits: 0 });
const PCT = new Intl.NumberFormat("de-DE", { minimumFractionDigits: 1, maximumFractionDigits: 1 });
const MIO = new Intl.NumberFormat("de-DE", { minimumFractionDigits: 1, maximumFractionDigits: 1 });

const eur = (v) => (v == null || isNaN(v) ? "–" : `${NUM.format(Math.round(v)).replace("-", "−")} €`);
const mio = (v) => (v == null || isNaN(v) ? "–" : `${MIO.format(v / 1e6).replace("-", "−")} Mio`);
const pct = (v, sign = true) =>
  v == null || isNaN(v) ? "–" : `${sign && v > 0 ? "+" : ""}${PCT.format(v).replace("-", "−")} %`;
const esc = (s) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const num = (st) => (st && !isNaN(parseFloat(st.state)) ? parseFloat(st.state) : null);

function ago(iso) {
  if (!iso) return "–";
  const min = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (isNaN(min)) return "–";
  if (min < 60) return `vor ${Math.max(min, 0)} min`;
  if (min < 48 * 60) return `vor ${Math.round(min / 60)} h`;
  return `vor ${Math.round(min / 1440)} Tagen`;
}

function countdown(ms) {
  if (ms <= 0) return "abgelaufen";
  const h = Math.floor(ms / 3600000);
  const m = Math.floor((ms % 3600000) / 60000);
  if (h >= 48) return `${Math.floor(h / 24)} Tage ${h % 24} h`;
  return `${h}:${String(m).padStart(2, "0")} h`;
}

function shortDay(iso) {
  if (!iso) return "–";
  return new Date(iso).toLocaleDateString("de-DE", { day: "2-digit", month: "2-digit", year: "2-digit" });
}

function shortDate(iso) {
  if (!iso) return "–";
  const d = new Date(iso);
  return d.toLocaleString("de-DE", { weekday: "short", hour: "2-digit", minute: "2-digit" });
}

const STYLE = `
:host { display:block; }
.root { container-type:inline-size; font-family:var(--kp-font); color:var(--kp-text); }
.root.app {
  --kp-bg:#12141a; --kp-card:#1c1f28; --kp-card2:#242836; --kp-line:#2a2f3c;
  --kp-text:#e9ebf0; --kp-mut:#8b90a0; --kp-accent:#22c55e; --kp-on-accent:#052e14;
  --kp-red:#f87171; --kp-green:#4ade80; --kp-amber:#fbbf24; --kp-radius:16px; --kp-border:none;
  --kp-crest-ring:rgba(255,255,255,.28);
  --kp-font: Inter, "SF Pro Display", -apple-system, system-ui, sans-serif;
  background:var(--kp-bg); border-radius:var(--kp-radius); padding:20px; min-height:100%;
}
.root.ha {
  --kp-bg:transparent; --kp-card:var(--ha-card-background, var(--card-background-color, #fff));
  --kp-card2:var(--secondary-background-color, #f2f2f2); --kp-line:var(--divider-color, #e0e0e0);
  --kp-text:var(--primary-text-color); --kp-mut:var(--secondary-text-color);
  --kp-accent:var(--primary-color); --kp-on-accent:var(--text-primary-color, #fff);
  --kp-red:var(--error-color, #db4437); --kp-green:var(--success-color, #43a047); --kp-amber:var(--warning-color, #ffa600);
  --kp-radius:var(--ha-card-border-radius, 12px); --kp-crest-ring:var(--divider-color, rgba(0,0,0,.2));
  --kp-border:var(--ha-card-border-width, 1px) solid var(--ha-card-border-color, var(--divider-color, #e0e0e0));
  --kp-font: var(--ha-font-family-body, var(--paper-font-body1_-_font-family, inherit));
  padding:8px 0;
}
.wrap { max-width:1180px; margin:0 auto; }
.top { display:flex; align-items:center; justify-content:space-between; gap:12px; margin-bottom:16px; flex-wrap:wrap; }
.brand { display:flex; align-items:center; gap:12px; }
.logo { width:42px; height:42px; border-radius:12px; background:var(--kp-accent); color:var(--kp-on-accent);
  display:flex; align-items:center; justify-content:center; }
.logo ha-icon { --mdc-icon-size:24px; }
.title { font-size:20px; font-weight:600; letter-spacing:-.01em; }
.sub { font-size:13px; color:var(--kp-mut); }
.pills { display:flex; gap:6px; flex-wrap:wrap; }
.pill { display:inline-flex; align-items:center; gap:4px; border-radius:999px; padding:3px 10px; font-size:12px; font-weight:600;
  background:var(--kp-card2); color:var(--kp-text); white-space:nowrap; }
.pill ha-icon { --mdc-icon-size:14px; }
.pill.red { background:color-mix(in srgb, var(--kp-red) 18%, transparent); color:var(--kp-red); }
.pill.green { background:color-mix(in srgb, var(--kp-green) 18%, transparent); color:var(--kp-green); }
.pill.amber { background:color-mix(in srgb, var(--kp-amber) 18%, transparent); color:var(--kp-amber); }
.grid { display:grid; grid-template-columns:repeat(12, minmax(0,1fr)); gap:12px; }
.card { background:var(--kp-card); border-radius:var(--kp-radius); border:var(--kp-border); padding:16px 18px; min-width:0; }
.s7 { grid-column:span 7; } .s5 { grid-column:span 5; } .s6 { grid-column:span 6; } .s3 { grid-column:span 3; } .s12 { grid-column:span 12; }
@container (max-width: 820px) { .s7, .s5, .s6 { grid-column:span 12; } .s3 { grid-column:span 6; } }
.lbl { font-size:12px; color:var(--kp-mut); font-weight:500; }
.big { font-size:32px; font-weight:650; letter-spacing:-.02em; margin:2px 0 6px; font-variant-numeric:tabular-nums; }
.mid { font-size:20px; font-weight:600; margin-top:4px; font-variant-numeric:tabular-nums; }
.neg { color:var(--kp-red); } .pos { color:var(--kp-green); }
.row { display:flex; gap:16px; flex-wrap:wrap; font-size:13px; color:var(--kp-mut); }
.row b { color:var(--kp-text); font-weight:600; }
.spark { width:100%; height:64px; margin-top:10px; display:block; }
.bar { height:6px; border-radius:3px; background:var(--kp-card2); overflow:hidden; margin:12px 0; }
.bar > div { height:100%; border-radius:3px; }
.head { display:flex; align-items:center; justify-content:space-between; gap:8px; margin-bottom:12px; }
.h { font-size:15px; font-weight:600; display:flex; align-items:center; gap:8px; }
.h ha-icon { --mdc-icon-size:20px; color:var(--kp-accent); }
.count { min-width:22px; height:22px; border-radius:11px; background:var(--kp-card2); font-size:12px; font-weight:700;
  display:inline-flex; align-items:center; justify-content:center; padding:0 6px; }
.list { display:flex; flex-direction:column; }
.item { display:flex; align-items:center; gap:12px; padding:9px 0; border-top:1px solid var(--kp-line); }
.item:first-child { border-top:none; }
.badge { width:38px; height:38px; border-radius:11px; flex:none; display:flex; align-items:center; justify-content:center;
  font-size:11px; font-weight:700; }
.grow { flex:1; min-width:0; }
.name { font-weight:600; font-size:14px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.meta { font-size:12px; color:var(--kp-mut); margin-top:1px; }
.right { text-align:right; font-variant-numeric:tabular-nums; }
.empty { color:var(--kp-mut); font-size:13px; padding:6px 0 2px; line-height:1.5; }
.foot { font-size:12px; color:var(--kp-mut); margin-top:10px; line-height:1.5; }
.actions { display:flex; gap:8px; margin-top:14px; flex-wrap:wrap; }
button { font:inherit; border:none; border-radius:11px; padding:10px 14px; font-size:13px; font-weight:600; cursor:pointer;
  display:inline-flex; align-items:center; justify-content:center; gap:6px; transition:filter .15s, transform .05s; }
button:hover { filter:brightness(1.08); } button:active { transform:scale(.98); }
button[disabled] { opacity:.55; cursor:default; }
button ha-icon { --mdc-icon-size:18px; }
.primary { background:var(--kp-accent); color:var(--kp-on-accent); flex:1; }
.danger { background:var(--kp-red); color:#fff; flex:1; }
.ghost { background:var(--kp-card2); color:var(--kp-text); }
.link { background:none; color:var(--kp-accent); padding:8px 0 0; }
.auto { display:flex; align-items:center; justify-content:space-between; gap:12px; padding:4px 0 12px; }
.toggle { width:46px; height:26px; border-radius:13px; background:var(--kp-card2); position:relative; padding:0; flex:none; }
.toggle.on { background:var(--kp-accent); }
.toggle::after { content:""; position:absolute; top:3px; left:3px; width:20px; height:20px; border-radius:50%; background:#fff;
  transition:left .15s; box-shadow:0 1px 3px rgba(0,0,0,.3); }
.toggle.on::after { left:23px; }
.info { position:relative; display:inline-flex; vertical-align:middle; margin-left:4px; cursor:help; }
.info > ha-icon { --mdc-icon-size:15px; color:var(--kp-mut); }
.info:hover > ha-icon, .info.open > ha-icon { color:var(--kp-accent); }
.tip { display:none; position:absolute; z-index:5; top:calc(100% + 6px); left:-8px; width:min(300px, 80cqi);
  background:var(--kp-card2); color:var(--kp-text); border:var(--kp-border); border-radius:12px; padding:10px 12px;
  font-size:12px; font-weight:400; line-height:1.5; white-space:pre-line; text-align:left; cursor:default;
  box-shadow:0 10px 30px rgba(0,0,0,.35); }
.root.ha .tip { background:var(--card-background-color, #fff); }
.info:hover > .tip, .info.open > .tip { display:block; }
.tip-r .tip { left:auto; right:-8px; }
@container (min-width: 821px) { .tip-r .tip { left:-8px; right:auto; } }
.seg-row { display:flex; align-items:center; justify-content:space-between; gap:10px; padding:8px 0; border-top:1px solid var(--kp-line); font-size:13px; }
.seg { display:inline-flex; background:var(--kp-card2); border-radius:10px; padding:3px; }
.seg button { background:none; color:var(--kp-mut); padding:6px 10px; border-radius:8px; font-size:12px; }
.seg button.sel { background:var(--kp-card); color:var(--kp-text); box-shadow:0 1px 2px rgba(0,0,0,.25); }
.seg button.sel.full { color:var(--kp-red); }
.crest { width:var(--cs, 18px); height:var(--cs, 18px); border-radius:50%; flex:none; display:inline-block;
  box-shadow:0 0 0 1.5px var(--kp-crest-ring); }
.club { display:inline-flex; align-items:center; gap:5px; margin-left:8px; font-size:11px; font-weight:600; color:var(--kp-mut);
  vertical-align:1px; letter-spacing:.02em; }
.club .crest { --cs:13px; box-shadow:0 0 0 1px var(--kp-crest-ring); }
.pitch { position:relative; border-radius:14px; padding:14px 6px; overflow:hidden;
  background:repeating-linear-gradient(180deg, #1f7a43 0 12.5%, #1b6e3c 12.5% 25%); border:2px solid rgba(255,255,255,.35); }
.pitch .mark { position:absolute; border:2px solid rgba(255,255,255,.3); pointer-events:none; }
.pitch .half { left:0; right:0; top:50%; border-width:2px 0 0; }
.pitch .circle { left:50%; top:50%; width:84px; height:84px; margin:-42px; border-radius:50%; }
.pitch .box { left:28%; right:28%; height:12%; }
.pitch .box.t { top:-2px; border-top:none; } .pitch .box.b { bottom:-2px; border-bottom:none; }
.line { position:relative; display:flex; justify-content:space-evenly; align-items:flex-start; padding:10px 0; }
.pl { display:flex; flex-direction:column; align-items:center; gap:3px; width:96px; min-width:0; text-align:center; }
.pl .crest { --cs:40px; box-shadow:0 0 0 2px rgba(255,255,255,.9), 0 3px 8px rgba(0,0,0,.35); }
.pl .nm { max-width:100%; font-size:12px; font-weight:600; color:#fff; background:rgba(0,0,0,.55); border-radius:6px; padding:1px 6px;
  overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.pl .cl { font-size:11px; color:#d7eadb; white-space:nowrap; }
.pl .cl.neg { color:#fecaca; } .pl .cl.pos { color:#bbf7d0; }
@container (max-width: 520px) { .pl { width:72px; } .pl .crest { --cs:32px; } }
.overlay { position:fixed; inset:0; background:rgba(0,0,0,.55); z-index:10; display:flex; align-items:center; justify-content:center; padding:16px; }
.dialog { background:var(--kp-card); color:var(--kp-text); border-radius:18px; padding:22px; max-width:420px; width:100%;
  box-shadow:0 20px 60px rgba(0,0,0,.45); border:var(--kp-border); }
.root.ha .dialog { background:var(--card-background-color, #fff); }
.dialog .h { font-size:17px; margin-bottom:8px; }
.dialog p { font-size:14px; color:var(--kp-mut); line-height:1.5; margin:0 0 6px; }
.dialog ul { margin:8px 0 4px; padding-left:18px; font-size:14px; line-height:1.6; }
.toast { position:fixed; left:50%; bottom:24px; transform:translateX(-50%); z-index:11; max-width:min(560px, calc(100vw - 32px));
  background:var(--kp-card2); color:var(--kp-text); border-radius:12px; padding:12px 16px; font-size:13px; line-height:1.5;
  box-shadow:0 10px 30px rgba(0,0,0,.35); white-space:pre-line; }
.root.ha .toast { background:var(--card-background-color, #fff); border:var(--kp-border); }
.toast.err { border-left:4px solid var(--kp-red); }
.warn { margin-bottom:12px; }
.kv { display:flex; justify-content:space-between; gap:12px; font-size:13px; padding:6px 0; border-bottom:1px solid color-mix(in srgb, var(--kp-mut) 18%, transparent); }
.kv:last-child { border-bottom:none; } .kv span { color:var(--kp-mut); }
.item.me { background:color-mix(in srgb, var(--kp-accent) 12%, transparent); border-radius:10px; }
.rank { width:22px; text-align:center; font-weight:700; color:var(--kp-mut); flex:none; }
.lu { display:flex; flex-direction:column; gap:6px; margin-bottom:10px; }
.lu .row { display:flex; gap:8px; align-items:flex-start; font-size:13px; line-height:1.45; border-radius:10px; padding:8px 10px; }
.lu .row ha-icon { --mdc-icon-size:18px; flex:none; margin-top:1px; }
.lu .row.red { background:color-mix(in srgb, var(--kp-red) 14%, transparent); }
.lu .row.red ha-icon { color:var(--kp-red); }
.lu .row.amber { background:color-mix(in srgb, var(--kp-amber) 14%, transparent); }
.lu .row.amber ha-icon { color:var(--kp-amber); }
.lu .row .sub2 { color:var(--kp-mut); font-size:12px; }
`;

class KickpilotCard extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: "open" });
    this._config = {};
    this._history = null;
    this._historyAt = 0;
    this._busy = null;
    this._confirm = null;
    this._toast = null;
    this._info = null;
    this._sig = "";
    this.shadowRoot.addEventListener("click", (ev) => this._onClick(ev));
  }

  static getStubConfig() {
    return {};
  }

  setConfig(config) {
    this._config = config || {};
    this._sig = "";
    if (this._hass) this._render();
  }

  getCardSize() {
    return 12;
  }

  getGridOptions() {
    return { columns: "full", rows: "auto" };
  }

  connectedCallback() {
    this._timer = setInterval(() => this._render(true), 30000);
  }

  disconnectedCallback() {
    clearInterval(this._timer);
  }

  set hass(hass) {
    this._hass = hass;
    this._ids = this._resolve(hass);
    const sig = Object.values(this._ids)
      .map((id) => hass.states[id]?.last_updated)
      .join("|");
    if (sig !== this._sig) {
      this._sig = sig;
      this._render();
    }
    if (Date.now() - this._historyAt > 15 * 60000) this._loadHistory();
  }

  // ---- entities -----------------------------------------------------------

  _resolve(hass) {
    const ids = {};
    const regs = Object.values(hass.entities || {}).filter((e) => e.platform === "kickbase");
    const device = this._config.device_id || regs.find((e) => e.device_id)?.device_id;
    for (const e of regs) {
      if (device && e.device_id !== device) continue;
      if (e.translation_key && KEYS[e.translation_key] && !ids[e.translation_key]) ids[e.translation_key] = e.entity_id;
    }
    // Fallback: German default entity ids (e.g. registry not yet loaded)
    for (const [key, [domain, suffix]] of Object.entries(KEYS)) {
      if (ids[key]) continue;
      const hit = Object.keys(hass.states).find(
        (id) => id.startsWith(`${domain}.`) && id.includes("kickbase") && id.endsWith(suffix)
      );
      if (hit) ids[key] = hit;
    }
    this._device = device ? hass.devices?.[device] : null;
    return ids;
  }

  _st(key) {
    const id = this._ids?.[key];
    return id ? this._hass.states[id] : undefined;
  }

  _attr(key, name, fallback) {
    return this._st(key)?.attributes?.[name] ?? fallback;
  }

  // ---- data ---------------------------------------------------------------

  async _loadHistory() {
    this._historyAt = Date.now();
    const ids = [this._ids.budget, this._ids.team_value].filter(Boolean);
    if (!ids.length) return;
    try {
      const start = new Date(Date.now() - 14 * 86400000).toISOString();
      const res = await this._hass.callWS({
        type: "history/history_during_period",
        start_time: start,
        entity_ids: ids,
        minimal_response: true,
        no_attributes: true,
        significant_changes_only: false,
      });
      const pts = (res[this._ids.budget] || [])
        .map((p) => ({ t: (p.lu ?? p.lc ?? 0) * 1000, v: parseFloat(p.s) }))
        .filter((p) => !isNaN(p.v));
      this._history = pts;
      this._render(true);
    } catch (e) {
      this._history = [];
    }
  }

  // ---- actions ------------------------------------------------------------

  _onClick(ev) {
    const el = ev.composedPath().find((n) => n.dataset && n.dataset.act);
    if (this._info && el?.dataset.act !== "info" && !el?.classList?.contains("tip")) {
      this._info = null;
      this._render(true);
    }
    if (!el) return;
    const act = el.dataset.act;
    if (act === "noop") return;
    if (act === "info") {
      this._info = this._info === el.dataset.arg ? null : el.dataset.arg;
      return this._render(true);
    }
    const arg = el.dataset.arg;
    if (act === "confirm-yes") return this._runConfirmed();
    if (act === "confirm-no") {
      this._confirm = null;
      return this._render(true);
    }
    if (act === "execute") return this._askExecute(arg);
    if (act === "send") return this._call("send", "kickbase", "vorschlaege_senden", { art: arg }, true);
    if (act === "refresh") return this._call("refresh", "kickbase", "plan_aktualisieren", {});
    if (act === "toggle") {
      const id = this._ids.automation;
      if (id) return this._call("toggle", "switch", "toggle", { entity_id: id });
    }
    if (act === "mode") {
      const [key, option] = arg.split(":");
      const id = this._ids[key];
      if (id && this._hass.states[id]?.state !== option) {
        return this._call(`mode-${key}`, "select", "select_option", { entity_id: id, option });
      }
    }
    if (act === "more") {
      const id = this._ids[arg];
      if (id) this.dispatchEvent(new CustomEvent("hass-more-info", { detail: { entityId: id }, bubbles: true, composed: true }));
    }
  }

  _askExecute(kind) {
    const buys = kind === "kaeufe" || kind === "verstaerkung";
    const source = { kaeufe: "buy_proposals", verkaeufe: "sale_proposals", verstaerkung: "upgrades", abwaertstrend: "trend_sales" }[kind];
    const items = this._attr(source, "vorschlaege", []).filter((p) => p.verkaufbar !== false);
    if (!items.length) return;
    const dry = this._attr("automation", "trockenlauf", false);
    const lines = items.map((p) => `${p.name}: ${eur(buys ? p.gebot : p.erloes)}`);
    this._confirm = {
      kind,
      title: buys ? "Gebote abgeben?" : "An Kickbase verkaufen?",
      text: buys
        ? "Für diese Spieler werden Gebote bei Kickbase abgegeben:"
        : "Diese Spieler werden sofort zum Marktwert an Kickbase verkauft:",
      lines,
      note: dry
        ? "Trockenlauf ist an: es wird nur protokolliert, nichts ausgeführt."
        : "Das sind echte Transaktionen bei Kickbase.",
      dry,
    };
    this._render(true);
  }

  _runConfirmed() {
    const c = this._confirm;
    this._confirm = null;
    if (!c) return;
    this._call("execute", "kickbase", "vorschlaege_ausfuehren", { art: c.kind }, true);
  }

  async _call(busy, domain, service, data, withResponse = false) {
    if (this._busy) return;
    this._busy = busy;
    this._render(true);
    try {
      const res = await this._hass.callService(domain, service, data, undefined, false, withResponse);
      const r = res?.response;
      if (r?.protokoll) this._showToast(r.protokoll.length ? r.protokoll.join("\n") : "Nichts zu tun.");
      else if (r?.auftraege) this._showToast(r.auftraege.length ? "Vorschläge aufs Handy geschickt." : "Keine Vorschläge zum Senden.");
      else if (service === "plan_aktualisieren") this._showToast("Plan neu berechnet.");
    } catch (e) {
      this._showToast(e?.message || String(e), true);
    } finally {
      this._busy = null;
      this._render(true);
    }
  }

  _showToast(text, err = false) {
    this._toast = { text, err };
    clearTimeout(this._toastTimer);
    this._toastTimer = setTimeout(() => {
      this._toast = null;
      this._render(true);
    }, err ? 9000 : 6000);
    this._render(true);
  }

  // ---- rendering ----------------------------------------------------------

  _render() {
    if (!this._hass) return;
    const design = this._config.design || this._attr("automation", "design", "app");
    if (!this._ids?.budget) {
      this.shadowRoot.innerHTML = `<style>${STYLE}</style><div class="root ${design === "ha" ? "ha" : "app"}"><div class="card">
        <div class="h">Kickpilot</div><p class="empty">Keine Kickbase-Integration gefunden. Richte sie unter Einstellungen → Geräte &amp; Dienste ein.</p></div></div>`;
      return;
    }
    this.shadowRoot.innerHTML = `<style>${STYLE}</style>
      <div class="root ${design === "ha" ? "ha" : "app"}"><div class="wrap">
        ${this._header()}
        <div class="grid">
          ${this._hero()}
          ${this._deadline()}
          ${this._stats()}
          ${this._buys()}
          ${this._sales()}
          ${this._upgrades()}
          ${this._trendSales()}
          ${this._radar()}
          ${this._capital()}
          ${this._bids()}
          ${this._automation()}
          ${this._lineup()}
          ${this._bench()}
        </div>
      </div>
      ${this._dialog()}
      ${this._toast ? `<div class="toast ${this._toast.err ? "err" : ""}">${esc(this._toast.text)}</div>` : ""}
      </div>`;
  }

  _header() {
    const league = (this._device?.name_by_user || this._device?.name || "").replace(/^Kickbase\s*/, "");
    const place = num(this._st("placement"));
    const points = this._attr("placement", "punkte");
    const managers = this._attr("placement", "manager");
    const dry = this._attr("automation", "trockenlauf", false);
    const updated = this._st("budget")?.last_updated;
    return `<div class="top">
      <div class="brand">
        <div class="logo"><ha-icon icon="mdi:soccer"></ha-icon></div>
        <div><div class="title">${esc(this._config.title || "Kickpilot")}</div><div class="sub">${esc(league)} · aktualisiert ${ago(updated)}</div></div>
      </div>
      <div class="pills">
        ${place != null ? `<span class="pill"><ha-icon icon="mdi:trophy-outline"></ha-icon>Platz ${place}${managers ? ` / ${managers}` : ""}</span>` : ""}
        ${points != null ? `<span class="pill">${NUM.format(points)} Pkt.</span>` : ""}
        ${dry ? `<span class="pill amber"><ha-icon icon="mdi:test-tube"></ha-icon>Trockenlauf</span>` : ""}
      </div>
    </div>`;
  }

  _hero() {
    const budget = num(this._st("budget"));
    const after = num(this._st("budget_after_bids"));
    const team = num(this._st("team_value"));
    return `<div class="card s7">
      <div class="lbl">Budget</div>
      <div class="big ${budget < 0 ? "neg" : ""}">${eur(budget)}</div>
      <div class="row">
        <span>nach Geboten <b class="${after < 0 ? "neg" : ""}">${mio(after)}</b></span>
        <span>Teamwert <b>${mio(team)}</b></span>
      </div>
      ${this._sparkline()}
    </div>`;
  }

  _sparkline() {
    const pts = this._history || [];
    if (pts.length < 2) return `<div class="foot">Verlauf wird geladen …</div>`;
    const now = Date.now();
    const data = [...pts, { t: now, v: pts[pts.length - 1].v }];
    const t0 = data[0].t;
    const vs = data.map((p) => p.v);
    let lo = Math.min(...vs, 0);
    let hi = Math.max(...vs, 0);
    if (hi === lo) hi = lo + 1;
    const W = 600, H = 64;
    const x = (t) => ((t - t0) / (now - t0 || 1)) * W;
    const y = (v) => H - 4 - ((v - lo) / (hi - lo)) * (H - 8);
    let d = "";
    data.forEach((p, i) => {
      // step line: value holds until the next change
      d += i === 0 ? `M${x(p.t).toFixed(1)},${y(p.v).toFixed(1)}` : `H${x(p.t).toFixed(1)}V${y(p.v).toFixed(1)}`;
    });
    const last = vs[vs.length - 1];
    const color = last < 0 ? "var(--kp-red)" : "var(--kp-green)";
    const zero = y(0).toFixed(1);
    return `<svg class="spark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" aria-label="Budgetverlauf 14 Tage">
      <line x1="0" x2="${W}" y1="${zero}" y2="${zero}" stroke="var(--kp-line)" stroke-dasharray="4 4" stroke-width="1" vector-effect="non-scaling-stroke"/>
      <path d="${d}V${zero}H0Z" fill="${color}" opacity=".12"/>
      <path d="${d}" fill="none" stroke="${color}" stroke-width="2" vector-effect="non-scaling-stroke"/>
    </svg><div class="row" style="justify-content:space-between;margin-top:4px"><span>vor 14 Tagen</span><span>heute</span></div>`;
  }

  _deadline() {
    const iso = this._st("next_deadline")?.state;
    const due = iso ? new Date(iso).getTime() : NaN;
    const left = due - Date.now();
    const progress = isNaN(due) ? 0 : Math.min(100, Math.max(0, 100 - (left / (7 * 86400000)) * 100));
    const alert = this._st("balance_needed")?.state === "on";
    const after = num(this._st("budget_after_bids"));
    const color = alert ? "var(--kp-red)" : left < 24 * 3600000 ? "var(--kp-amber)" : "var(--kp-accent)";
    const status = alert
      ? `<span class="pill red"><ha-icon icon="mdi:alert"></ha-icon>Ausgleich nötig</span>`
      : after < 0
        ? `<span class="pill amber"><ha-icon icon="mdi:alert-outline"></ha-icon>Budget nach Geboten negativ</span>`
        : `<span class="pill green"><ha-icon icon="mdi:check"></ha-icon>Budget im Plus</span>`;
    return `<div class="card s5" data-act="more" data-arg="next_deadline" style="cursor:pointer">
      <div class="lbl">Frist ${isNaN(due) ? "" : esc(shortDate(iso))} Uhr</div>
      <div class="big">${isNaN(due) ? "–" : countdown(left)}</div>
      <div class="bar"><div style="width:${progress.toFixed(1)}%;background:${color}"></div></div>
      ${status}
    </div>`;
  }

  _stats() {
    const tile = (key, label, value, cls = "", extra = "") =>
      `<div class="card s3 ${extra}" data-act="more" data-arg="${key}" style="cursor:pointer"><div class="lbl">${label}${INFO[key] ? this._info_icon(key) : ""}</div><div class="mid ${cls}">${value}</div></div>`;
    const open = num(this._st("open_bids"));
    const limit = num(this._st("bid_limit"));
    const debt = num(this._st("debt_limit"));
    const squad = num(this._st("squad_size"));
    return [
      tile("open_bids", "Offene Gebote", mio(open)),
      tile("bid_limit", "Gebotsrahmen", mio(limit), limit < 0 ? "neg" : "", "tip-r"),
      tile("debt_limit", "Minus-Grenze", mio(debt)),
      tile("squad_size", "Kader", squad == null ? "–" : `${squad} / 18`),
    ].join("");
  }

  _info_icon(key) {
    return `<span class="info ${this._info === key ? "open" : ""}" data-act="info" data-arg="${key}" role="button" tabindex="0"
      aria-label="Erklärung anzeigen"><ha-icon icon="mdi:information-outline"></ha-icon><span class="tip" data-act="noop">${esc(INFO[key])}</span></span>`;
  }

  _badge(pos) {
    const c = POS_COLORS[pos] || "#8b90a0";
    return `<div class="badge" style="background:color-mix(in srgb, ${c} 20%, transparent);color:${c}">${esc(pos || "?")}</div>`;
  }

  _gain(v) {
    if (v == null) return "";
    return `<span class="pill ${v >= 0 ? "green" : "red"}">${pct(v)}</span>`;
  }

  _buys() {
    const items = this._attr("buy_proposals", "vorschlaege", []);
    const a = (n) => this._attr("buy_proposals", n);
    const body = items.length
      ? `<div class="list">${items
          .map(
            (b) => `<div class="item">${this._badge(b.position)}
            <div class="grow"><div class="name">${esc(b.name)}${this._clubTag(b.verein)}${b.nach_frist ? " ⏰" : ""}</div>
            <div class="meta">MW ${eur(b.marktwert)} · ${esc(b.muster || "")}</div></div>
            <div class="right"><div class="name">${eur(b.gebot)}</div><div class="meta">+${PCT.format(b.aufpreis_pct)} % Aufpreis</div></div>
            <span class="pill green">+${mio(b.erwarteter_gewinn)}</span></div>`
          )
          .join("")}</div>
          <div class="foot">Summe ${eur(a("summe"))} · erwarteter Gewinn ${eur(a("erwarteter_gewinn"))}</div>
          <div class="actions">
            <button class="primary" data-act="execute" data-arg="kaeufe" ${this._busy ? "disabled" : ""}><ha-icon icon="mdi:gavel"></ha-icon>${this._busy === "execute" ? "Läuft …" : "Gebote abgeben"}</button>
            <button class="ghost" data-act="send" data-arg="kaeufe" ${this._busy ? "disabled" : ""}><ha-icon icon="mdi:cellphone-message"></ha-icon>Aufs Handy</button>
          </div>`
      : `<div class="empty">Gerade keine Kaufvorschläge. ${a("uebersprungen") ?? 0} Kandidaten geprüft, keiner erfüllt die Regeln.${
          a("warten_auf_ablauftag") ? ` ${a("warten_auf_ablauftag")} davon passen, ihr Angebot endet aber erst an einem späteren Tag.` : ""
        }</div>`;
    return `<div class="card s6">
      <div class="head"><div class="h"><ha-icon icon="mdi:cart-arrow-down"></ha-icon>Kaufvorschläge</div><span class="count">${items.length}</span></div>
      ${body}
      <div class="foot">Vorschläge nur für Angebote, die heute enden · Stärkster Konkurrent: ${esc(a("staerkster_konkurrent") ?? "–")} (${pct(a("konkurrent_aufpreis_pct"))}) · Backtest ${a("backtest_trefferquote_pct") ?? "–"} % Treffer bei ${NUM.format(a("backtest_signale") ?? 0)} Signalen</div>
    </div>`;
  }

  _upgrades() {
    const items = this._attr("upgrades", "vorschlaege", []);
    const day = this._attr("upgrades", "spieltag");
    const body = items.length
      ? `<div class="list">${items
          .map(
            (u) => `<div class="item">${this._badge(u.position)}
            <div class="grow"><div class="name">${esc(u.name)}${this._clubTag(u.verein)}${u.nach_frist ? " ⏰" : ""}</div>
            <div class="meta">Prognose ${NUM.format(u.prognose)} Pkt. statt ${esc(u.statt)} (${NUM.format(u.statt_prognose)})</div></div>
            <div class="right"><div class="name">${eur(u.gebot)}</div><div class="meta">MW ${mio(u.marktwert)}</div></div>
            <span class="pill green">+${NUM.format(u.plus_punkte)} Pkt.</span></div>`
          )
          .join("")}</div>
          <div class="actions">
            <button class="primary" data-act="execute" data-arg="verstaerkung" ${this._busy ? "disabled" : ""}><ha-icon icon="mdi:gavel"></ha-icon>${this._busy === "execute" ? "Läuft …" : "Gebote abgeben"}</button>
            <button class="ghost" data-act="send" data-arg="verstaerkung" ${this._busy ? "disabled" : ""}><ha-icon icon="mdi:cellphone-message"></ha-icon>Aufs Handy</button>
          </div>`
      : `<div class="empty">Kein Marktspieler mit heutigem Ablauf bringt laut Prognose mindestens 20 Punkte mehr als dein schwächster Starter.</div>`;
    return `<div class="card s6">
      <div class="head"><div class="h"><ha-icon icon="mdi:arm-flex"></ha-icon>Verstärkungen${this._info_icon("upgrades")}</div><span class="count">${items.length}</span></div>
      ${body}
      <div class="foot">Punkteprognose für den ${day ?? "–"}. Spieltag · gleiche Budgetregeln wie bei den Kaufvorschlägen · immer mit Bestätigung</div>
    </div>`;
  }

  _trendSales() {
    const items = this._attr("trend_sales", "vorschlaege", []);
    const why = (t) => {
      if (t.grund === "verletzt") return "🚑 Verletzt – vor dem MW-Update um 22:00 Uhr verkaufen";
      if (t.grund === "angeschlagen") return "⚠️ Angeschlagen – Ausfall droht";
      return `${PCT.format(t.unter_hoch_pct)} % unter dem Hoch (${mio(t.hoch)}, ${esc(shortDay(t.hoch_am))})`;
    };
    const gain = (t) =>
      t.gewinn == null
        ? `<div class="name">–</div><div class="meta">seit Kauf</div>`
        : `<div class="name ${t.gewinn >= 0 ? "pos" : "neg"}">${t.gewinn > 0 ? "+" : ""}${eur(t.gewinn)}</div><div class="meta">${t.gewinn >= 0 ? "Gewinn" : "Verlust"}</div>`;
    const sellable = items.filter((t) => t.verkaufbar !== false);
    const body = items.length
      ? `<div class="list">${items
          .map(
            (t) => `<div class="item">${this._badge(t.position)}
            <div class="grow"><div class="name">${esc(t.name)}${this._clubTag(t.verein)}</div>
            <div class="meta">${why(t)}${t.verkaufbar === false ? ` · Verkauf nicht möglich: ${esc(t.hinweis)}` : ""}</div></div>
            <div class="right"><div class="name">${eur(t.wert ?? t.erloes)}</div><div class="meta">Wert</div></div>
            <div class="right">${gain(t)}</div></div>`
          )
          .join("")}</div>
          ${sellable.length ? `<div class="actions">
            <button class="danger" data-act="execute" data-arg="abwaertstrend" ${this._busy ? "disabled" : ""}><ha-icon icon="mdi:cash-fast"></ha-icon>${this._busy === "execute" ? "Läuft …" : "Verkaufen"}</button>
          </div>` : ""}`
      : `<div class="empty">Kein verletzter oder angeschlagener Spieler, und niemand außerhalb deiner Top 11 verliert gerade deutlich an Wert.</div>`;
    return `<div class="card s6">
      <div class="head"><div class="h"><ha-icon icon="mdi:trending-down"></ha-icon>Verkaufssignale${this._info_icon("trend_sales")}</div><span class="count">${items.length}</span></div>
      ${body}
    </div>`;
  }

  _radar() {
    const rows = this._attr("league_gap", "manager", []);
    if (!rows.length) return "";
    const body = rows
      .map(
        (r) => `<div class="item ${r.ich ? "me" : ""}"><span class="rank">${r.platz}</span>
        <div class="grow"><div class="name">${esc(r.name)}${r.ich ? " (du)" : ""}</div>
        <div class="meta">Teamwert ${mio(r.teamwert)} · Spieltag ${NUM.format(r.spieltag_punkte)} Pkt.${r.spieltag_platz ? ` (Platz ${r.spieltag_platz})` : ""}${
          r.verletzt_in_startelf?.length ? ` · 🚑 ${esc(r.verletzt_in_startelf.join(", "))}` : ""
        }</div></div>
        <div class="right"><div class="name">${NUM.format(r.punkte)}</div><div class="meta">${r.abstand ? `−${NUM.format(r.abstand)}` : "Spitze"}</div></div></div>`
      )
      .join("");
    return `<div class="card s6">
      <div class="head"><div class="h"><ha-icon icon="mdi:podium"></ha-icon>Konkurrenz-Radar${this._info_icon("radar")}</div></div>
      <div class="list">${body}</div>
    </div>`;
  }

  _capital() {
    const st = this._st("capital");
    if (!st || st.state === "unavailable" || st.state === "unknown") return "";
    const a = st.attributes || {};
    const row = (label, value, cls = "") => `<div class="kv"><span>${label}</span><b class="${cls}">${value}</b></div>`;
    const g = a.zuwachs_pro_tag;
    return `<div class="card s6">
      <div class="head"><div class="h"><ha-icon icon="mdi:finance"></ha-icon>Kapitalplan${this._info_icon("capital")}</div></div>
      ${row("Kapital heute (Budget + Teamwert)", eur(num(st)))}
      ${row("Zuwachs pro Tag (Ø 14 Tage)", `${g > 0 ? "+" : ""}${eur(g)}`, g > 0 ? "pos" : g < 0 ? "neg" : "")}
      ${a.winterpause ? row(`Winterpause (${esc(shortDay(a.winterpause))})`, eur(a.kapital_winterpause)) : ""}
      ${a.saisonende ? row(`Saisonende (${esc(shortDay(a.saisonende))})`, eur(a.kapital_saisonende)) : ""}
      ${row("Kaufkraft bis Freitag", eur(a.kaufkraft))}
      ${a.kaufkraft_winterpause != null ? row("Kaufkraft zur Winterpause (Prognose)", eur(a.kaufkraft_winterpause)) : ""}
    </div>`;
  }

  _sales() {
    const items = this._attr("sale_proposals", "vorschlaege", []);
    const before = this._attr("sale_proposals", "budget_nach_geboten");
    const after = this._attr("sale_proposals", "budget_nach_verkaeufen");
    const body = items.length
      ? `<div class="list">${items
          .map(
            (s) => `<div class="item">${this._badge(s.position)}
            <div class="grow"><div class="name">${esc(s.name)}${this._clubTag(s.verein)}</div><div class="meta">Gewinn ${esc(s.basis || "")}</div></div>
            <div class="right"><div class="name">${eur(s.erloes)}</div></div>
            ${this._gain(s.gewinn_pct)}</div>`
          )
          .join("")}</div>
          <div class="foot">Budget nach Geboten <b class="neg">${mio(before)}</b> → nach Verkäufen <b class="${after < 0 ? "neg" : "pos"}">${mio(after)}</b></div>
          <div class="actions">
            <button class="danger" data-act="execute" data-arg="verkaeufe" ${this._busy ? "disabled" : ""}><ha-icon icon="mdi:cash-fast"></ha-icon>${this._busy === "execute" ? "Läuft …" : "Alle verkaufen"}</button>
            <button class="ghost" data-act="send" data-arg="verkaeufe" ${this._busy ? "disabled" : ""}><ha-icon icon="mdi:cellphone-message"></ha-icon>Aufs Handy</button>
          </div>`
      : `<div class="empty">Kein Ausgleich bis zur Frist nötig.</div>`;
    return `<div class="card s6">
      <div class="head"><div class="h"><ha-icon icon="mdi:cash-fast"></ha-icon>Verkaufsvorschläge</div><span class="count">${items.length}</span></div>
      ${body}
    </div>`;
  }

  _bids() {
    const items = this._attr("open_bids", "gebote", []);
    const body = items.length
      ? `<div class="list">${items
          .map((g) => {
            const over = g.marktwert ? ((g.gebot - g.marktwert) / g.marktwert) * 100 : null;
            return `<div class="item"><div class="badge" style="background:var(--kp-card2);color:var(--kp-mut)"><ha-icon icon="mdi:gavel" style="--mdc-icon-size:18px"></ha-icon></div>
              <div class="grow"><div class="name">${esc(g.name)}${this._clubTag(g.verein)}</div><div class="meta">endet ${esc(shortDate(g.endet))} · MW ${eur(g.marktwert)}</div></div>
              <div class="right"><div class="name">${eur(g.gebot)}</div><div class="meta">${pct(over)}</div></div></div>`;
          })
          .join("")}</div>`
      : `<div class="empty">Keine offenen Gebote.</div>`;
    return `<div class="card s6">
      <div class="head"><div class="h"><ha-icon icon="mdi:timer-sand"></ha-icon>Offene Gebote</div><span class="count">${items.length}</span></div>
      ${body}
    </div>`;
  }

  _automation() {
    const on = this._st("automation")?.state === "on";
    const seg = (key, label) => {
      const cur = this._st(key)?.state;
      return `<div class="seg-row"><span>${label}${this._info_icon(key)}</span><div class="seg">
        <button class="${cur === "semi" ? "sel" : ""}" data-act="mode" data-arg="${key}:semi" ${this._busy ? "disabled" : ""}>Halbautomatisch</button>
        <button class="${cur === "full" ? "sel full" : ""}" data-act="mode" data-arg="${key}:full" ${this._busy ? "disabled" : ""}>Vollautomatisch</button>
      </div></div>`;
    };
    const stamp = this._st("data_status")?.state;
    return `<div class="card s6">
      <div class="head"><div class="h"><ha-icon icon="mdi:robot-outline"></ha-icon>Automatik</div></div>
      <div class="auto"><div><div class="name">Automatik aktiv</div><div class="meta">${on ? "Prüft zu den eingestellten Zeiten" : "Pausiert, es wird nichts geprüft"}</div></div>
        <button class="toggle ${on ? "on" : ""}" data-act="toggle" aria-label="Automatik umschalten" ${this._busy ? "disabled" : ""}></button></div>
      ${seg("mode_bids", "Gebote")}
      ${seg("mode_sales", "Verkäufe")}
      <div class="seg-row"><span>Transfers und Marktwerte</span><span class="meta">${ago(stamp)}</span></div>
      <button class="link" data-act="refresh" ${this._busy ? "disabled" : ""}><ha-icon icon="mdi:refresh"></ha-icon>${this._busy === "refresh" ? "Wird berechnet …" : "Plan neu berechnen"}</button>
    </div>`;
  }

  _club(tid) {
    const name = this._attr("squad_size", "vereine", {})?.[tid] || TEAM_NAMES[tid] || "";
    const known = CLUBS[name];
    if (known) return { abbr: known[0], bg: known[1], name };
    const abbr = name ? name.replace(/[^A-Za-zÄÖÜäöü]/g, "").slice(0, 3).toUpperCase() : "?";
    return { abbr, bg: half("#6b7280", "#9ca3af", 90), name: name || "unbekannter Verein" };
  }

  _crest(tid) {
    const c = this._club(tid);
    return `<span class="crest" style="background:${c.bg}" title="${esc(c.name)}"></span>`;
  }

  _clubTag(tid) {
    if (!tid) return "";
    return `<span class="club">${this._crest(tid)}${esc(this._club(tid).abbr)}</span>`;
  }

  _lineup() {
    const all = this._attr("squad_size", "spieler", []);
    const xi = all.filter((p) => p.startelf != null).sort((a, b) => a.startelf - b.startelf);
    const rows = ["ST", "MIT", "ABW", "TW"].map((pos) => xi.filter((p) => p.position === pos));
    const formation = rows.slice(0, 3).reverse().map((r) => r.length).join("-");
    const player = (p) => {
      const t = p.trend_24h || 0;
      return `<div class="pl">${this._crest(p.verein)}
        <span class="nm" title="${esc(p.name)}">${esc(p.name)}${p.fit ? "" : " 🚑"}</span>
        <span class="cl">${esc(this._club(p.verein).abbr)} · Ø ${NUM.format(p.schnitt)}${p.prognose != null ? ` · ▸${NUM.format(p.prognose)}` : ""}</span>
        <span class="cl ${t > 0 ? "pos" : t < 0 ? "neg" : ""}">${mio(p.marktwert)}</span></div>`;
    };
    const pitch = xi.length
      ? `<div class="pitch"><div class="mark half"></div><div class="mark circle"></div><div class="mark box t"></div><div class="mark box b"></div>
          ${rows.filter((r) => r.length).map((r) => `<div class="line">${r.map(player).join("")}</div>`).join("")}</div>`
      : `<div class="empty">Keine Aufstellung gesetzt. Stell deine Startelf in der Kickbase-App auf.</div>`;
    return `<div class="card s7">
      <div class="head"><div class="h"><ha-icon icon="mdi:soccer-field"></ha-icon>Startelf</div>
        <span class="sub">${xi.length ? `${formation} · ${xi.length} / 11` : ""}</span></div>
      ${this._lineupCheck()}
      ${pitch}
    </div>`;
  }

  // Aufstellungs-Wächter: nur Hinweise, die Aufstellung wird nie geändert.
  _lineupCheck() {
    const st = this._st("lineup_problem");
    if (!st || st.state === "unavailable") return "";
    const a = st.attributes || {};
    const problems = a.probleme || [];
    const tips = a.tipps || [];
    const next = a.aufstellung_bis;
    const until = (i) => (i.bis ? ` · bis ${esc(shortDate(i.bis))} Uhr` : "");
    const rows = [
      ...problems.map((i) => {
        const sub = i.art === "unvollstaendig" ? "" : i.ersatz
          ? `Ersatz: ${esc(i.ersatz)} (Ø ${NUM.format(i.ersatz_schnitt)})`
          : "Kein fitter Ersatz auf dieser Position";
        return `<div class="row red"><ha-icon icon="mdi:alert"></ha-icon><div>${esc(i.text)}
          <div class="sub2">${sub}${until(i)}</div></div></div>`;
      }),
      ...tips.map((i) => `<div class="row amber"><ha-icon icon="mdi:swap-horizontal"></ha-icon><div>Tipp: ${esc(i.text)}
          <div class="sub2">Stärker auf der Bank${until(i)}</div></div></div>`),
    ];
    const status = !next
      ? `<span class="pill"><ha-icon icon="mdi:lock"></ha-icon>Spieltag ${a.spieltag ?? ""} läuft – Aufstellung gesperrt</span>`
      : problems.length
        ? `<span class="pill red"><ha-icon icon="mdi:alert"></ha-icon>Aufstellung prüfen · bis ${esc(shortDate(next))} Uhr</span>`
        : `<span class="pill green"><ha-icon icon="mdi:check"></ha-icon>Aufstellung ok · steht bis ${esc(shortDate(next))} Uhr</span>`;
    return `<div class="lu"><div class="pills">${status}${this._info_icon("lineup")}</div>${rows.join("")}</div>`;
  }

  _bench() {
    const all = this._attr("squad_size", "spieler", []);
    const bench = all
      .filter((p) => p.startelf == null)
      .sort((a, b) => (POS_ORDER[a.position] || 9) - (POS_ORDER[b.position] || 9) || b.schnitt - a.schnitt);
    const rows = bench
      .map((p) => {
        const t = p.trend_24h || 0;
        return `<div class="item">${this._badge(p.position)}
          <div class="grow"><div class="name">${esc(p.name)}${this._clubTag(p.verein)}${p.fit ? "" : " 🚑"}${p.auf_transfermarkt ? " 🏷️" : ""}</div>
          <div class="meta">Ø ${PCT.format(p.schnitt)} · ${NUM.format(p.punkte)} Pkt.${p.prognose != null ? ` · Prognose ${NUM.format(p.prognose)}` : ""}</div></div>
          <div class="right"><div class="name">${mio(p.marktwert)}</div><div class="meta ${t > 0 ? "pos" : t < 0 ? "neg" : ""}">${t > 0 ? "+" : ""}${eur(t)}</div></div></div>`;
      })
      .join("");
    return `<div class="card s5">
      <div class="head"><div class="h"><ha-icon icon="mdi:seat-outline"></ha-icon>Ersatzbank</div><span class="count">${bench.length}</span></div>
      ${bench.length ? `<div class="list">${rows}</div>` : `<div class="empty">Niemand auf der Bank.</div>`}
      <div class="foot">Kader ${all.length} / 18 · nach Position, dann Ø-Punkten</div>
    </div>`;
  }

  _dialog() {
    const c = this._confirm;
    if (!c) return "";
    return `<div class="overlay" data-act="confirm-no"><div class="dialog" data-act="noop">
      <div class="h">${esc(c.title)}</div>
      <p>${esc(c.text)}</p>
      <ul>${c.lines.map((l) => `<li>${esc(l)}</li>`).join("")}</ul>
      <p style="margin-top:10px;color:${c.dry ? "var(--kp-amber)" : "var(--kp-red)"};font-weight:600">${esc(c.note)}</p>
      <div class="actions">
        <button class="ghost" data-act="confirm-no">Abbrechen</button>
        <button class="${c.kind === "kaeufe" ? "primary" : "danger"}" data-act="confirm-yes">${c.kind === "kaeufe" ? "Gebote abgeben" : "Verkaufen"}</button>
      </div>
    </div></div>`;
  }
}

if (!customElements.get("kickpilot-card")) {
  customElements.define("kickpilot-card", KickpilotCard);
  window.customCards = window.customCards || [];
  window.customCards.push({
    type: "kickpilot-card",
    name: "Kickpilot",
    description: "Kickbase-Dashboard: Budget, Frist, Vorschläge, Automatik, Startelf und Ersatzbank.",
    preview: false,
  });
}
