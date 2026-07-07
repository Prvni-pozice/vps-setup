#!/usr/bin/env bash
# apt-upgrade-report.sh — po běhu unattended-upgrades pošle HTML report se
# STEJNOU hlavičkou, From i předmětem [SRV_LABEL] jako health-check.
# Mailuje jen když se něco upgradovalo NEBO nastala chyba; klidné no-op běhy
# mlčí (denní stav pokrývá vps-health-daily).
# Instalace: symlink z /usr/local/sbin (dělá setup.sh). Konfigurace se čte
# ZA BĚHU z /etc/vps-setup.env — úprava platí hned, bez re-runu setup.sh.
set -uo pipefail
CONF="${VPS_SETUP_ENV:-/etc/vps-setup.env}"
[ -r "$CONF" ] && . "$CONF"
EMAIL_TO="${EMAIL_TO:-root}"
SRV_LABEL="${SRV_LABEL:-$(hostname -s)}"
HOST="$(hostname)"
UULOG="/var/log/unattended-upgrades/unattended-upgrades.log"
STAMP="/var/lib/vps-health/apt-report.last"
command -v sendmail >/dev/null 2>&1 || exit 0
[ -f "$UULOG" ] || exit 0

# poslední běh = blok od posledního "Starting unattended upgrades script" do konce
block="$(awk '/Starting unattended upgrades script/{buf=""} {buf=buf $0 ORS} END{printf "%s", buf}' "$UULOG")"
[ -n "$block" ] || exit 0

pkgs="$(printf '%s\n' "$block" | sed -n 's/.*Packages that will be upgraded: //p' | tail -n1)"
err="$(printf '%s\n' "$block" | grep -iE 'ERROR|Exception|Traceback|failed to install' | head -n5)"

# nic k hlášení → ticho (že server žije, pokryje denní heartbeat)
[ -z "$pkgs" ] && [ -z "$err" ] && exit 0

# dedup: stejný běh neposílat 2× (ExecStartPost může proběhnout opakovaně)
mkdir -p "$(dirname "$STAMP")"
sig="$(printf '%s' "$block" | md5sum | awk '{print $1}')"
[ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$sig" ] && exit 0
printf '%s' "$sig" > "$STAMP"

if [ -n "$err" ]; then STATUS="PROBLEM"; ICON="❌"; else STATUS="OK"; ICON="✅"; fi
TS="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
reboot_pending="ne"; reboot_pkgs=""
if [ -f /var/run/reboot-required ]; then
  reboot_pkgs="$(cat /var/run/reboot-required.pkgs 2>/dev/null | paste -sd, -)"
  reboot_pending="ANO${reboot_pkgs:+ ($reboot_pkgs)}"
fi
npkg=0; [ -n "$pkgs" ] && npkg="$(printf '%s' "$pkgs" | wc -w)"

# ── text/plain fallback ─────────────────────────────────────────────────────
REPORT="${ICON} ${HOST} — automatické aktualizace"$'\n\n'
if [ "$STATUS" = OK ]; then REPORT+="Nainstalováno ${npkg} aktualizací."$'\n'
else REPORT+="Aktualizace narazily na chybu — viz níže."$'\n'; fi
REPORT+=$'\n'"Čas:         ${TS}"$'\n'"Reboot čeká: ${reboot_pending}"$'\n'
[ "$reboot_pending" != "ne" ] && REPORT+=$'\n'"🔴 NUTNÝ RUČNÍ RESTART — auto-reboot je vypnutý, spusť: sudo reboot"$'\n'
[ -n "$pkgs" ] && REPORT+=$'\n'"Balíky (${npkg}):"$'\n'"  ${pkgs}"$'\n'
[ -n "$err" ] && REPORT+=$'\n'"Chyby:"$'\n'"$(printf '%s\n' "$err" | sed 's/^/  /')"$'\n'
REPORT="${REPORT%$'\n'}"

command -v sendmail >/dev/null || exit 0
SRV_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
TS_DATE="$(date -u '+%Y-%m-%d')"; TS_TIME="$(date -u '+%H:%M UTC')"
html_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

if [ "$STATUS" = OK ]; then
  B_BG="#e6f4ec"; B_FG="#157347"; B_DOT="#1f9d55"; B_TXT="OK"
  H_TITLE="Aktualizace nainstalovány"
  H_SUB="Nainstalováno ${npkg} balíčků z bezpečnostních a systémových zdrojů."
else
  B_BG="#fbe7e5"; B_FG="#b3261e"; B_DOT="#d64541"; B_TXT="Problém"
  H_TITLE="Aktualizace selhaly"
  H_SUB="Automatické aktualizace narazily na chybu — je potřeba kontrola."
fi

# červený box "nutný ruční restart" (auto-reboot je vypnutý)
REBOOT_BOX=""; RB_COL="#3f4a53"
if [ "$reboot_pending" != "ne" ]; then
  RB_COL="#b3261e"
  REBOOT_BOX="<tr><td style=\"padding:16px 22px 0;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\"><tr><td style=\"background:#fbe7e5;border:1px solid #f2c9c4;border-left:4px solid #d64541;border-radius:9px;padding:12px 14px;\"><div style=\"margin:0 0 6px;font-size:12px;letter-spacing:.06em;text-transform:uppercase;font-weight:800;color:#b3261e;\">&#128308; Nutný ruční restart</div><div style=\"font-size:13px;line-height:1.6;color:#3f4a53;\">Po aktualizacích je potřeba restart — <b>automatický reboot je vypnutý</b>. Restartuj ručně: <code style=\"font-family:Consolas,Menlo,monospace;background:#f3d9d5;padding:1px 5px;border-radius:4px;\">sudo reboot</code><br>Balíky: $(html_esc "${reboot_pkgs:-—}")</div></td></tr></table></td></tr>"
fi

# obsah: seznam balíků (monospace, zalomený) + případné chyby (alert box)
PKG_HTML=""
if [ -n "$pkgs" ]; then
  PKG_HTML="<tr><td style=\"padding:16px 22px 2px;\"><div style=\"font-size:11px;letter-spacing:.09em;text-transform:uppercase;color:#71808f;font-weight:700;margin:0 0 9px;\">Upgradované balíčky (${npkg})</div><div style=\"font-family:Consolas,Menlo,monospace;font-size:12.5px;line-height:1.8;color:#33414d;word-break:break-word;\">$(html_esc "$pkgs")</div></td></tr>"
fi
ERR_HTML=""
if [ -n "$err" ]; then
  items=""; while IFS= read -r l; do [ -n "$l" ] && items+="<div style=\"font-size:13px;line-height:1.6;color:#3f4a53;\">&bull; $(html_esc "$l")</div>"; done <<< "$err"
  ERR_HTML="<tr><td style=\"padding:16px 22px 0;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\"><tr><td style=\"background:#fbe7e5;border:1px solid #f2c9c4;border-left:4px solid #d64541;border-radius:9px;padding:12px 14px;\"><div style=\"margin:0 0 6px;font-size:12px;letter-spacing:.06em;text-transform:uppercase;font-weight:800;color:#b3261e;\">&#10071; Chyby</div>${items}</td></tr></table></td></tr>"
fi

HTML="$(cat <<HTML
<!doctype html>
<html><body style="margin:0;padding:0;background:#eceef1;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eceef1;"><tr><td align="center" style="padding:24px 8px;">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#ffffff;border:1px solid #e5e9ee;border-radius:12px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#1f2933;">
<tr><td style="background:#263445;padding:16px 22px;border-radius:12px 12px 0 0;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
<td style="color:#ffffff;font-weight:700;font-size:15px;">${SRV_LABEL}<br><span style="font-weight:500;color:#9fb0c2;font-size:12px;font-family:Consolas,Menlo,monospace;">${HOST} &middot; ${SRV_IP:-?}</span></td>
<td align="right" style="color:#9fb0c2;font-size:12px;font-family:Consolas,Menlo,monospace;white-space:nowrap;">${TS_DATE}<br>${TS_TIME}</td>
</tr></table></td></tr>
<tr><td style="padding:20px 22px 6px;">
<div style="font-size:22px;font-weight:800;margin:0 0 4px;">${H_TITLE}</div>
<div style="color:#55636e;font-size:14px;line-height:1.5;">${H_SUB}</div></td></tr>
<tr><td style="padding:12px 22px 0;"><span style="display:inline-block;padding:5px 12px;border-radius:999px;font-weight:700;font-size:12px;letter-spacing:.09em;text-transform:uppercase;background:${B_BG};color:${B_FG};"><span style="color:${B_DOT};">&#9679;</span>&nbsp;${B_TXT}</span></td></tr>
${REBOOT_BOX}
${ERR_HTML}
${PKG_HTML}
<tr><td style="padding:14px 22px;border-top:1px solid #eef1f4;font-size:12px;color:#71808f;">
Reboot čeká: <b style="color:${RB_COL};font-weight:600;">${reboot_pending}</b></td></tr>
<tr><td style="background:#f7f8fa;border-top:1px solid #e5e9ee;padding:11px 22px;font-size:11px;color:#9aa6b1;font-family:Consolas,Menlo,monospace;border-radius:0 0 12px 12px;">apt-upgrade &middot; vps-setup</td></tr>
</table></td></tr></table>
</body></html>
HTML
)"
BOUNDARY="=_vps-apt-$$"
{
  printf 'Subject: [%s] apt-upgrade %s %s\n' "$SRV_LABEL" "$ICON" "$STATUS"
  printf 'From: "%s (%s)" <root@%s>\n' "$SRV_LABEL" "${SRV_IP:-$HOST}" "$HOST"
  printf 'To: %s\n' "$EMAIL_TO"
  printf 'MIME-Version: 1.0\nContent-Type: multipart/alternative; boundary="%s"\n\n' "$BOUNDARY"
  printf -- '--%s\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n%s\n\n' "$BOUNDARY" "$REPORT"
  printf -- '--%s\nContent-Type: text/html; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n%s\n\n' "$BOUNDARY" "$HTML"
  printf -- '--%s--\n' "$BOUNDARY"
} | sendmail -t 2>>/var/log/msmtp.log
