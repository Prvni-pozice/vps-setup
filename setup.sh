#!/usr/bin/env bash
#
# setup.sh — VPS baseline: auto-updaty (BEZ auto-rebootu), fail2ban, SMTP notifikace,
#            post-boot health-check + denní heartbeat + MOTD. Idempotentní.
# Dva HTML maily (stejná šablona, From i předmět [SRV_LABEL]):
#   • health-check — po startu (post-boot) i denně (heartbeat, ticho = problém)
#   • apt-upgrade  — po každém automatickém upgradu (nahrazuje ošklivý plaintext)
#
# Cíl: Ubuntu 22.04/24.04 server. Spouštět jako root:  sudo bash setup.sh
#
# Per-server hodnoty lze přepsat přes env, např.:
#   sudo EMAIL_TO=admin@firma.cz REBOOT_TIME=03:00 bash setup.sh
# SMTP heslo se NEZADÁVÁ do skriptu — skript se na něj zeptá (read -s),
# ať není v shell historii ani v souboru. Uloží se jen do /etc/msmtprc (600).
#
set -euo pipefail

# Per-server konfigurace mimo repo (bez hesla). Přednost: cmdline env > tento
# soubor > default níže. Soubor zapíše setup.sh na konci běhu (viz krok 7),
# takže příští běhy hodnoty načtou samy — nemusíš je znovu předávat.
[ -r /etc/vps-setup.env ] && . /etc/vps-setup.env

# ─────────────────────────────────────────────────────────────────────────────
# KONFIGURACE (per-server) — přepiš přes env, /etc/vps-setup.env, nebo zde
# ─────────────────────────────────────────────────────────────────────────────
EMAIL_TO="${EMAIL_TO:-zdenek@prvni-pozice.com}"     # kam chodí reporty
SMTP_HOST="${SMTP_HOST:-1pmail.cz}"
SMTP_PORT="${SMTP_PORT:-587}"                       # 587 = STARTTLS (1pmail.cz), 465 = SSL
SMTP_FROM="${SMTP_FROM:-podpora@prvni-pozice.com}"
SMTP_USER="${SMTP_USER:-podpora@prvni-pozice.com}"
SMTP_PASS="${SMTP_PASS:-}"                          # prázdné → zeptá se
REBOOT_TIME="${REBOOT_TIME:-02:30}"                 # UTC (systémová zóna serveru!)
UPGRADE_TIME="${UPGRADE_TIME:-02:00}"               # UTC — musí být PŘED REBOOT_TIME
F2B_MAXRETRY="${F2B_MAXRETRY:-5}"
F2B_BANTIME="${F2B_BANTIME:-1h}"
F2B_FINDTIME="${F2B_FINDTIME:-10m}"
F2B_IGNOREIP="${F2B_IGNOREIP:-127.0.0.1/8 ::1}"     # bez whitelistu ext. IP (dynamická)

# Health-check — které kontejnery/procesy hlídat (UNIKÁTNÍ per server!).
# Defaulty jsou ZÁMĚRNĚ prázdné (jako SRV_LABEL=hostname) — konkrétní služby
# patří do /etc/vps-setup.env daného serveru, ne natvrdo do sdíleného skriptu.
# Prázdno = nehlídat nic navíc (auto-detekce níže stejně zachytí spadlé
# always/unless-stopped kontejnery jako varování). Pozn.: defaulty MUSÍ zůstat
# prázdné, jinak by ": ${VAR:=}" v env souboru nešlo použít k vypnutí hlídání
# (operátor :- bere prázdno jako „nezadáno" a vrátil by default).
WATCH_CRITICAL="${WATCH_CRITICAL:-}"   # kontejnery: dole = ❌ PROBLEM (alert)
WATCH_OPTIONAL="${WATCH_OPTIONAL:-}"   # kontejnery: dole = ⚠ warning (jen info)
WATCH_IGNORE="${WATCH_IGNORE:-}"       # glob vzory pro auto-detekci k ignoru
# Kontejnery s restart policy 'no' (pokusné/testovací) se NEHLÍDAJÍ (zůstanou jak byly).
# Cron pipeline (import-felix apod.): "název:/log" nebo "název:/log:max_min"
# (default práh 120 min) — log čerstvý = ✅, starší/chybí = ⚠:
PIPELINE_LOGS="${PIPELINE_LOGS:-}"
# Kritické procesy (ne-kontejner, ne-cron) — "název:pgrep-pattern", dole = ❌ alert:
WATCH_PROC="${WATCH_PROC:-}"
# Čitelný název serveru — jde do From a předmětu mailu (IP se doplní automaticky).
# UNIKÁTNÍ per server → default = hostname (NE natvrdo konkrétní server!).
# Tenhle server (1p) má SRV_LABEL=1P-16GB v /etc/vps-setup.env.
SRV_LABEL="${SRV_LABEL:-$(hostname -s)}"
# Denní health-check (heartbeat) — pošle stav i bez rebootu, ať ticho = problém:
HEALTH_DAILY_TIME="${HEALTH_DAILY_TIME:-04:00}"     # UTC — po upgrade+reboot okně

# ─────────────────────────────────────────────────────────────────────────────
log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[setup CHYBA]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Spusť jako root: sudo bash setup.sh"
command -v apt-get >/dev/null || die "Tohle je pro Debian/Ubuntu (apt)."

# SMTP heslo: při opakovaném běhu se NEPTÁ — /etc/msmtprc už existuje a nechá
# se beze změny. Nové heslo: smaž /etc/msmtprc nebo předej SMTP_PASS env.
if [ -z "$SMTP_PASS" ] && [ ! -f /etc/msmtprc ]; then
  read -rsp "SMTP heslo pro ${SMTP_USER}: " SMTP_PASS; echo
  [ -n "$SMTP_PASS" ] || die "Prázdné SMTP heslo."
fi

export DEBIAN_FRONTEND=noninteractive
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
log "Distro: ${CODENAME:-?} | reboot: RUČNÍ (auto vypnuto) | upgrade: ${UPGRADE_TIME} UTC | mail→ ${EMAIL_TO}"

# ─────────────────────────────────────────────────────────────────────────────
log "1/7 — balíky (unattended-upgrades, fail2ban, msmtp)…"
apt-get update -qq
apt-get install -y -qq unattended-upgrades fail2ban msmtp msmtp-mta ca-certificates >/dev/null

# ─────────────────────────────────────────────────────────────────────────────
log "2/7 — SMTP relay (/etc/msmtprc)…"
if [ -z "$SMTP_PASS" ]; then
  log "  /etc/msmtprc už existuje a heslo nebylo zadáno → ponechávám beze změny"
else
TLS_STARTTLS="off"; [ "$SMTP_PORT" = "587" ] && TLS_STARTTLS="on"
umask 077
cat > /etc/msmtprc <<MSMTPEOF
# Spravováno setup.sh — NEUKLÁDAT do gitu (obsahuje heslo)
defaults
auth           on
tls            on
tls_starttls   ${TLS_STARTTLS}
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log
aliases        /etc/aliases

account        default
host           ${SMTP_HOST}
port           ${SMTP_PORT}
from           ${SMTP_FROM}
user           ${SMTP_USER}
password       ${SMTP_PASS}
MSMTPEOF
chown root:root /etc/msmtprc; chmod 600 /etc/msmtprc
umask 022
fi
# systémová pošta (root) → admin
if ! grep -q "^root:" /etc/aliases 2>/dev/null; then echo "root: ${EMAIL_TO}" >> /etc/aliases; fi
touch /var/log/msmtp.log; chmod 640 /var/log/msmtp.log

# ─────────────────────────────────────────────────────────────────────────────
log "3/7 — auto-updaty (+ -updates, BEZ auto-rebootu, mail report)…"
# override soubor (nešaháme do defaultního 50unattended-upgrades)
cat > /etc/apt/apt.conf.d/52unattended-local.conf <<EOF
// Spravováno setup.sh
Unattended-Upgrade::Allowed-Origins:: "\${distro_id}:\${distro_codename}-updates";
// Automatický reboot je ZÁMĚRNĚ vypnutý — restart provádí uživatel ručně.
// Když je po updatu potřeba restart, health-check i apt report to červeně
// zvýrazní ("Nutný ruční restart"). Viz post-boot-check.sh / apt-upgrade-report.sh.
Unattended-Upgrade::Automatic-Reboot "false";
// Vestavěný plaintext mail je VYPNUTÝ — report posílá /usr/local/sbin/apt-upgrade-report.sh
// v HTML se stejnou hlavičkou/From/předmětem jako health-check (viz krok 6).
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
# pevný čas instalace upgradů (auto-reboot je vypnutý, řeší se ručně)
mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf <<EOF
[Timer]
OnCalendar=
OnCalendar=*-*-* ${UPGRADE_TIME} UTC
RandomizedDelaySec=15m
Persistent=true
EOF
systemctl daemon-reload
systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
systemctl restart apt-daily-upgrade.timer

# ─────────────────────────────────────────────────────────────────────────────
log "4/7 — fail2ban (sshd: ${F2B_MAXRETRY} pokusů → ban ${F2B_BANTIME})…"
BANACTION="nftables-multiport"; { command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi "Status: active" && BANACTION="ufw"; } || true
cat > /etc/fail2ban/jail.local <<EOF
# Spravováno setup.sh
[DEFAULT]
backend   = systemd
bantime   = ${F2B_BANTIME}
findtime  = ${F2B_FINDTIME}
maxretry  = ${F2B_MAXRETRY}
ignoreip  = ${F2B_IGNOREIP}
banaction = ${BANACTION}
# bez navyšování bantime (žádná eskalace)

[sshd]
enabled = true
EOF
systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban

# ─────────────────────────────────────────────────────────────────────────────
log "5/7 — post-boot health-check…"
install -d -m 755 /var/lib/vps-health
# Skripty žijí v repu (scripts/) a instalují se SYMLINKEM — změna kódu v repu
# (edit / git pull) platí od příští kontroly bez re-runu setup.sh.
# Konfiguraci čtou za běhu z /etc/vps-setup.env (zapisuje se níže, krok 7).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/scripts/post-boot-check.sh" ] || die "chybí $SCRIPT_DIR/scripts/post-boot-check.sh — spouštěj setup.sh z klonu repa vps-setup"
chmod 755 "$SCRIPT_DIR/scripts/post-boot-check.sh" "$SCRIPT_DIR/scripts/apt-upgrade-report.sh"
ln -sfn "$SCRIPT_DIR/scripts/post-boot-check.sh" /usr/local/sbin/post-boot-check.sh

# ── apt-upgrade report (HTML, stejná šablona jako health-check) ──────────────
ln -sfn "$SCRIPT_DIR/scripts/apt-upgrade-report.sh" /usr/local/sbin/apt-upgrade-report.sh
# spustit report po každém běhu apt-daily-upgrade (tj. po unattended-upgrades)
mkdir -p /etc/systemd/system/apt-daily-upgrade.service.d
cat > /etc/systemd/system/apt-daily-upgrade.service.d/zz-vps-report.conf <<EOF
[Service]
ExecStartPost=/usr/local/sbin/apt-upgrade-report.sh
EOF

# ─────────────────────────────────────────────────────────────────────────────
log "6/7 — systemd unit (spustí health-check po každém startu)…"
cat > /etc/systemd/system/post-boot-check.service <<'EOF'
[Unit]
Description=Post-boot health check + report
After=multi-user.target docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 45
ExecStart=/usr/local/sbin/post-boot-check.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable post-boot-check.service >/dev/null 2>&1 || true

# denní health-check (heartbeat) — pošle stav i bez rebootu (ticho = problém)
cat > /etc/systemd/system/vps-health-daily.service <<'EOF'
[Unit]
Description=Denní health-check + report (heartbeat)
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=RUN_MODE=daily
ExecStart=/usr/local/sbin/post-boot-check.sh
RemainAfterExit=no
EOF
cat > /etc/systemd/system/vps-health-daily.timer <<EOF
[Unit]
Description=Spouští denní health-check (heartbeat)

[Timer]
OnCalendar=*-*-* ${HEALTH_DAILY_TIME}:00 UTC
Persistent=true
RandomizedDelaySec=3m

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now vps-health-daily.timer >/dev/null 2>&1 || true

# MOTD — stav při přihlášení
cat > /etc/update-motd.d/99-vps-health <<'EOF'
#!/bin/sh
S="/var/lib/vps-health/status"
echo
if [ -f "$S" ]; then
  echo "── Stav serveru (poslední post-boot check) ──"
  sed -n '3,20p' "$S"
else
  echo "── Stav serveru: post-boot check zatím neproběhl ──"
fi
[ -f /var/run/reboot-required ] && echo "⚠  Čeká restart (reboot-required)"
echo
EOF
chmod 755 /etc/update-motd.d/99-vps-health

# ── per-server konfigurace → /etc/vps-setup.env (BEZ hesla) ──────────────────
# Zapíše aktuální hodnoty, ať je příští běh načte sám (viz zdroj na začátku
# skriptu). Forma ": ${VAR:=…}" = přednost má cmdline env, pak tento soubor.
# SMTP_PASS se ZÁMĚRNĚ neukládá (zůstává jen v /etc/msmtprc, 600).
umask 077
cat > /etc/vps-setup.env <<EOF
# Per-server konfigurace vps-setup — generuje setup.sh. NEcommitovat do gitu.
# Heslo zde NENÍ (jen v /etc/msmtprc). Uprav dle potřeby; příští běh to načte.
: "\${SRV_LABEL:=${SRV_LABEL}}"
: "\${EMAIL_TO:=${EMAIL_TO}}"
: "\${SMTP_HOST:=${SMTP_HOST}}"
: "\${SMTP_PORT:=${SMTP_PORT}}"
: "\${SMTP_FROM:=${SMTP_FROM}}"
: "\${SMTP_USER:=${SMTP_USER}}"
: "\${REBOOT_TIME:=${REBOOT_TIME}}"
: "\${UPGRADE_TIME:=${UPGRADE_TIME}}"
: "\${HEALTH_DAILY_TIME:=${HEALTH_DAILY_TIME}}"
: "\${F2B_MAXRETRY:=${F2B_MAXRETRY}}"
: "\${F2B_BANTIME:=${F2B_BANTIME}}"
: "\${F2B_FINDTIME:=${F2B_FINDTIME}}"
: "\${F2B_IGNOREIP:=${F2B_IGNOREIP}}"
: "\${WATCH_CRITICAL:=${WATCH_CRITICAL}}"
: "\${WATCH_OPTIONAL:=${WATCH_OPTIONAL}}"
: "\${WATCH_IGNORE:=${WATCH_IGNORE}}"
: "\${PIPELINE_LOGS:=${PIPELINE_LOGS}}"
: "\${WATCH_PROC:=${WATCH_PROC}}"
EOF
chmod 600 /etc/vps-setup.env
umask 022
log "per-server konfigurace uložena → /etc/vps-setup.env (SRV_LABEL=${SRV_LABEL})"

# ─────────────────────────────────────────────────────────────────────────────
log "7/7 — test e-mailu + verifikace…"
# multipart: text/plain fallback + HTML se stejnou hlavičkou jako health-check
SETUP_TEXT="Baseline nastaven: auto-updaty (BEZ auto-rebootu — restart ručně), fail2ban(${F2B_MAXRETRY}/${F2B_BANTIME}), health-check. $(date -u)"
SETUP_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
SETUP_HTML="$(cat <<HTML
<!doctype html>
<html><body style="margin:0;padding:0;background:#eceef1;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eceef1;"><tr><td align="center" style="padding:24px 8px;">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#ffffff;border:1px solid #e5e9ee;border-radius:12px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#1f2933;">
<tr><td style="background:#263445;padding:16px 22px;border-radius:12px 12px 0 0;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
<td style="color:#ffffff;font-weight:700;font-size:15px;">${SRV_LABEL}<br><span style="font-weight:500;color:#9fb0c2;font-size:12px;font-family:Consolas,Menlo,monospace;">$(hostname) &middot; ${SETUP_IP:-?}</span></td>
<td align="right" style="color:#9fb0c2;font-size:12px;font-family:Consolas,Menlo,monospace;white-space:nowrap;">$(date -u '+%Y-%m-%d')<br>$(date -u '+%H:%M UTC')</td>
</tr></table></td></tr>
<tr><td style="padding:20px 22px 6px;">
<div style="font-size:22px;font-weight:800;margin:0 0 4px;">VPS setup dokončen</div>
<div style="color:#55636e;font-size:14px;line-height:1.5;">Provozní baseline je nastaven a health-check poběží po každém restartu.</div></td></tr>
<tr><td style="padding:12px 22px 0;"><span style="display:inline-block;padding:5px 12px;border-radius:999px;font-weight:700;font-size:12px;letter-spacing:.09em;text-transform:uppercase;background:#e6f4ec;color:#157347;"><span style="color:#1f9d55;">&#9679;</span>&nbsp;OK</span></td></tr>
<tr><td style="padding:16px 22px 14px;font-size:13px;line-height:1.7;color:#3f4a53;">
&bull; auto-updaty <b style="font-weight:600;">bez automatického restartu</b> — případný restart hlásí health-check červeně<br>
&bull; fail2ban sshd: <b style="font-weight:600;">${F2B_MAXRETRY} pokusů &rarr; ban ${F2B_BANTIME}</b><br>
&bull; post-boot health-check + e-mail report po každém startu</td></tr>
<tr><td style="background:#f7f8fa;border-top:1px solid #e5e9ee;padding:11px 22px;font-size:11px;color:#9aa6b1;font-family:Consolas,Menlo,monospace;border-radius:0 0 12px 12px;">setup.sh &middot; vps-setup</td></tr>
</table></td></tr></table>
</body></html>
HTML
)"
SETUP_BOUNDARY="=_vps-setup-$$"
if {
    printf 'Subject: [%s] VPS setup dokončen ✅\n' "$SRV_LABEL"
    printf 'From: "%s (%s)" <root@%s>\n' "$SRV_LABEL" "${SETUP_IP:-$(hostname)}" "$(hostname)"
    printf 'To: %s\n' "$EMAIL_TO"
    printf 'MIME-Version: 1.0\nContent-Type: multipart/alternative; boundary="%s"\n\n' "$SETUP_BOUNDARY"
    printf -- '--%s\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n%s\n\n' "$SETUP_BOUNDARY" "$SETUP_TEXT"
    printf -- '--%s\nContent-Type: text/html; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n%s\n\n' "$SETUP_BOUNDARY" "$SETUP_HTML"
    printf -- '--%s--\n' "$SETUP_BOUNDARY"
  } | sendmail -t 2>>/var/log/msmtp.log; then
  log "✔ testovací e-mail odeslán na ${EMAIL_TO} (zkontroluj schránku)"
else
  warn "✘ test e-mailu SELHAL — zkontroluj /var/log/msmtp.log a SMTP údaje"
fi

echo
log "════════ HOTOVO — kontrola ════════"
echo "• unattended-upgrades:  $(systemctl is-enabled unattended-upgrades 2>/dev/null)"
echo "• apt-daily-upgrade:    příští běh $(systemctl show apt-daily-upgrade.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
echo "• auto-reboot:          VYPNUTÝ (restart ručně; health-check hlásí červeně)"
echo "• fail2ban sshd:        $(fail2ban-client status sshd 2>/dev/null | grep -i 'currently banned' || echo 'aktivní')"
echo "• post-boot-check:      $(systemctl is-enabled post-boot-check.service 2>/dev/null)"
echo "• denní health-check:   $(systemctl is-enabled vps-health-daily.timer 2>/dev/null) (${HEALTH_DAILY_TIME} UTC)"
echo "• apt-upgrade report:   HTML po každém upgradu (vestavěný plaintext mail vypnut)"
echo
log "Ruční test health-checku:  sudo /usr/local/sbin/post-boot-check.sh  (pošle e-mail)"
log "Ruční test apt reportu:    sudo /usr/local/sbin/apt-upgrade-report.sh  (mailuje jen při změně/chybě)"
log "Rollback viz runbook.md."
