#!/usr/bin/env bash
#
# setup.sh — VPS baseline: auto-updaty (+reboot), fail2ban, SMTP notifikace,
#            post-boot health-check + MOTD. Idempotentní (lze spustit opakovaně).
#
# Cíl: Ubuntu 22.04/24.04 server. Spouštět jako root:  sudo bash setup.sh
#
# Per-server hodnoty lze přepsat přes env, např.:
#   sudo EMAIL_TO=admin@firma.cz REBOOT_TIME=03:00 bash setup.sh
# SMTP heslo se NEZADÁVÁ do skriptu — skript se na něj zeptá (read -s),
# ať není v shell historii ani v souboru. Uloží se jen do /etc/msmtprc (600).
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# KONFIGURACE (per-server) — přepiš přes env nebo zde
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

# Health-check — které kontejnery hlídat (per-server):
WATCH_CRITICAL="${WATCH_CRITICAL:-vndftp grafana}"      # dole = ❌ PROBLEM (alert)
WATCH_OPTIONAL="${WATCH_OPTIONAL:-pgadmin nocodb n8n}"  # dole = ⚠ warning (jen info)
WATCH_IGNORE="${WATCH_IGNORE:-coolify-* coolify}"       # glob vzory pro auto-detekci k ignoru
# Kontejnery s restart policy 'no' (pokusné/testovací) se NEHLÍDAJÍ (zůstanou jak byly).
# Cron pipeline (import-felix apod.): "název:/cesta/k/logu" — hlásí stáří logu jako info:
PIPELINE_LOGS="${PIPELINE_LOGS:-import-felix:/data/bot/import-felix/logs/cron.log}"
# Kritické procesy (ne-kontejner, ne-cron) — "název:pgrep-pattern", dole = ❌ alert:
WATCH_PROC="${WATCH_PROC:-honeypot:honeypot.js}"
# Čitelný název serveru — jde do From a předmětu mailu (IP se doplní automaticky):
SRV_LABEL="${SRV_LABEL:-1P-16GB}"

# ─────────────────────────────────────────────────────────────────────────────
log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[setup CHYBA]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Spusť jako root: sudo bash setup.sh"
command -v apt-get >/dev/null || die "Tohle je pro Debian/Ubuntu (apt)."

if [ -z "$SMTP_PASS" ]; then
  read -rsp "SMTP heslo pro ${SMTP_USER}: " SMTP_PASS; echo
  [ -n "$SMTP_PASS" ] || die "Prázdné SMTP heslo."
fi

export DEBIAN_FRONTEND=noninteractive
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
log "Distro: ${CODENAME:-?} | reboot: ${REBOOT_TIME} UTC | upgrade: ${UPGRADE_TIME} UTC | mail→ ${EMAIL_TO}"

# ─────────────────────────────────────────────────────────────────────────────
log "1/7 — balíky (unattended-upgrades, fail2ban, msmtp)…"
apt-get update -qq
apt-get install -y -qq unattended-upgrades fail2ban msmtp msmtp-mta ca-certificates >/dev/null

# ─────────────────────────────────────────────────────────────────────────────
log "2/7 — SMTP relay (/etc/msmtprc)…"
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
# systémová pošta (root) → admin
if ! grep -q "^root:" /etc/aliases 2>/dev/null; then echo "root: ${EMAIL_TO}" >> /etc/aliases; fi
touch /var/log/msmtp.log; chmod 640 /var/log/msmtp.log

# ─────────────────────────────────────────────────────────────────────────────
log "3/7 — auto-updaty (+ -updates, reboot ${REBOOT_TIME}, mail report)…"
# override soubor (nešaháme do defaultního 50unattended-upgrades)
cat > /etc/apt/apt.conf.d/52unattended-local.conf <<EOF
// Spravováno setup.sh
Unattended-Upgrade::Allowed-Origins:: "\${distro_id}:\${distro_codename}-updates";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";
Unattended-Upgrade::Mail "${EMAIL_TO}";
Unattended-Upgrade::MailReport "on-change";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
# posun času instalace PŘED reboot (jinak by se reboot odložil o den)
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
cat > /usr/local/sbin/post-boot-check.sh <<'HEALTHEOF'
#!/usr/bin/env bash
# post-boot-check.sh — po startu ověří stav systému + Docker kontejnerů,
# zapíše status (log + MOTD state) a pošle e-mail. Spravováno setup.sh.
set -uo pipefail
EMAIL_TO="__EMAIL_TO__"
WATCH_CRITICAL="__WATCH_CRITICAL__"
WATCH_OPTIONAL="__WATCH_OPTIONAL__"
WATCH_IGNORE="__WATCH_IGNORE__"
PIPELINE_LOGS="__PIPELINE_LOGS__"
WATCH_PROC="__WATCH_PROC__"
SRV_LABEL="__SRV_LABEL__"
HOST="$(hostname)"
STATE_DIR="/var/lib/vps-health"; STATE="$STATE_DIR/status"; LOG="/var/log/post-boot-check.log"
mkdir -p "$STATE_DIR"

# Počkej, až se kontejnery s healthcheckem ustálí (max ~180 s)
for _ in $(seq 1 18); do
  starting="$(docker ps --filter health=starting -q 2>/dev/null | wc -l || echo 0)"
  [ "${starting:-0}" -eq 0 ] && break
  sleep 10
done

problems=(); warnings=(); infos=(); crows=()
in_list() { case " $2 " in *" $1 "*) return 0;; esac; return 1; }
is_ignored() { local n="$1" p; for p in $WATCH_IGNORE; do case "$n" in $p) return 0;; esac; done; return 1; }
crunning() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]; }
cexists() { docker inspect "$1" >/dev/null 2>&1; }

# systemd — nejdřív počkej, až dokončí start (jinak by "starting" hned po bootu
# vypadalo jako problém); poll max ~120 s, break jakmile není initializing/starting
sysstate=""
for _ in $(seq 1 24); do
  sysstate="$(systemctl is-system-running 2>/dev/null || true)"
  case "$sysstate" in initializing|starting) sleep 5;; *) break;; esac
done
[ "$sysstate" = "running" ] || problems+=("systemd: $sysstate")
failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd, -)"
nfailed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk 'END{print NR}')"
[ -n "$failed_units" ] && problems+=("failed units: $failed_units")

# cron (spouští import pipelines) — musí běžet
if ! systemctl is-active --quiet cron 2>/dev/null && ! systemctl is-active --quiet crond 2>/dev/null; then
  problems+=("cron neběží (nespustí se cron pipelines)")
fi

# docker + kontejnery
docker_line="docker: n/a"
if systemctl is-active --quiet docker 2>/dev/null; then
  total="$(docker ps -a -q 2>/dev/null | wc -l)"; running="$(docker ps -q 2>/dev/null | wc -l)"
  docker_line="docker: ${running}/${total} kontejnerů běží"
  # kritické — musí běžet
  for c in $WATCH_CRITICAL; do
    if ! cexists "$c"; then problems+=("kritický '$c' chybí"); crows+=("$c|❌ chybí"); continue; fi
    if crunning "$c"; then crows+=("$c|✅ běží"); else
      st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
      problems+=("kritický '$c' NEběží ($st)"); crows+=("$c|❌ $st"); fi
  done
  # volitelné — jen varování
  for c in $WATCH_OPTIONAL; do
    cexists "$c" || continue
    if crunning "$c"; then crows+=("$c|✅ běží"); else warnings+=("volitelný '$c' neběží"); crows+=("$c|⚠ neběží"); fi
  done
  # unhealthy (healthcheck selhává)
  for c in $(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null); do
    if in_list "$c" "$WATCH_CRITICAL"; then problems+=("kritický '$c' unhealthy"); else warnings+=("'$c' unhealthy"); fi
  done
  # auto-detekce záchranná síť: co má restart policy always/unless-stopped, neběží,
  # není v listech ani v ignoru (pokusné s policy 'no' se přeskočí automaticky)
  for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
    crunning "$c" && continue
    in_list "$c" "$WATCH_CRITICAL" && continue
    in_list "$c" "$WATCH_OPTIONAL" && continue
    is_ignored "$c" && continue
    pol="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null)"
    case "$pol" in always|unless-stopped) warnings+=("neběží '$c' (policy=$pol)");; esac
  done
else
  problems+=("docker.service neběží")
fi

# cron pipelines (import-felix apod.) — stáří logu jako info
for spec in $PIPELINE_LOGS; do
  pname="${spec%%:*}"; plog="${spec#*:}"
  if [ -f "$plog" ]; then
    age=$(( ( $(date +%s) - $(stat -c %Y "$plog" 2>/dev/null || echo 0) ) / 60 ))
    infos+=("$pname: cron log ${age} min starý")
  else
    warnings+=("$pname: log nenalezen ($plog)")
  fi
done

# kritické procesy (honeypot apod.) — musí běžet
for spec in $WATCH_PROC; do
  [ -n "$spec" ] || continue
  pname="${spec%%:*}"; ppat="${spec#*:}"
  if pgrep -f -- "$ppat" >/dev/null 2>&1; then infos+=("$pname: proces běží"); else problems+=("kritický proces '$pname' NEběží"); fi
done

reboot_pending=""; [ -f /var/run/reboot-required ] && reboot_pending="ANO ($(cat /var/run/reboot-required.pkgs 2>/dev/null | paste -sd, -))"

if   [ ${#problems[@]} -gt 0 ]; then STATUS="PROBLEM"; ICON="❌"
elif [ ${#warnings[@]} -gt 0 ]; then STATUS="WARN";    ICON="⚠"
else STATUS="OK"; ICON="✅"; fi
TS="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# ── sestavení přehledného reportu ───────────────────────────────────────────
case "$STATUS" in
  OK)      HEAD="server OK po restartu"; VERDICT="Vše naběhlo v pořádku.";;
  WARN)    HEAD="server s výhradami";    VERDICT="Naběhlo, ale ${#warnings[@]}× varování — viz níže.";;
  PROBLEM) HEAD="server — PROBLÉM";      VERDICT="Pozor: ${#problems[@]}× problém vyžaduje kontrolu — viz níže.";;
esac
sys_icon="✅"; { [ "$sysstate" = "running" ] && [ -z "$failed_units" ]; } || sys_icon="❌"
cron_icon="✅"; { systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null; } || cron_icon="❌"
dk_icon="✅"; systemctl is-active --quiet docker 2>/dev/null || dk_icon="❌"

REPORT=""; add() { REPORT+="$1"$'\n'; }; row() { add "$(printf '  %-14s %s' "$1" "$2")"; }
add "${ICON} ${HOST} — ${HEAD}"
add ""
add "${VERDICT}"
add ""
add "Čas:         ${TS}"
add "Uptime:      $(uptime -p 2>/dev/null)"
add "Kernel:      $(uname -r)"
add "Reboot čeká: ${reboot_pending:-ne}"
add ""
add "STAV"
row "Systemd" "${sys_icon} ${sysstate:-?} · ${nfailed:-0} failed"
row "Docker"  "${dk_icon} ${running:-?}/${total:-?} kontejnerů běží"
row "Cron"    "${cron_icon} $([ "$cron_icon" = "✅" ] && echo běží || echo NEběží)"
if [ ${#crows[@]} -gt 0 ]; then add ""; add "KONTEJNERY"; for r in "${crows[@]}"; do row "${r%%|*}" "${r#*|}"; done; fi
if [ ${#infos[@]} -gt 0 ]; then add ""; add "PIPELINES / PROCESY"; for x in "${infos[@]}"; do add "  - $x"; done; fi
if [ ${#problems[@]} -gt 0 ]; then add ""; add "❗ PROBLÉMY"; for x in "${problems[@]}"; do add "  - $x"; done; fi
if [ ${#warnings[@]} -gt 0 ]; then add ""; add "⚠ VAROVÁNÍ"; for x in "${warnings[@]}"; do add "  - $x"; done; fi
REPORT="${REPORT%$'\n'}"

printf '%s\n' "$REPORT" | tee -a "$LOG" >/dev/null
printf 'STATUS=%s\nTS=%s\n%s\n' "$STATUS" "$TS" "$REPORT" > "$STATE"

# e-mail (msmtp/sendmail) — multipart/alternative: text/plain = $REPORT
# (fallback), text/html = schválený návrh (tmavý header, badge, STAV proužek,
# tabulka kontejnerů, alert boxy). E-mail-safe: inline styly, <table>
# layout, systémové fonty, žádné externí assety.
if command -v sendmail >/dev/null; then
  SRV_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
  html_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
  dot_color() { case "$1" in *✅*) echo "#1f9d55";; *⚠*) echo "#d9a441";; *) echo "#d64541";; esac; }
  st_color()  { case "$1" in *✅*) echo "#157347";; *⚠*) echo "#9a6a00";; *) echo "#b3261e";; esac; }

  case "$STATUS" in
    OK)      B_BG="#e6f4ec"; B_FG="#157347"; B_DOT="#1f9d55"; B_TXT="OK"
             H_TITLE="Server naběhl v pořádku"
             H_SUB="Po restartu jsou všechny služby i kontejnery v provozu.";;
    WARN)    B_BG="#fbf3dd"; B_FG="#9a6a00"; B_DOT="#d9a441"; B_TXT="Varování"
             H_TITLE="Naběhlo s výhradami — ${#warnings[@]}× varování"
             H_SUB="Server běží, ale některé komponenty hlásí varování — viz níže.";;
    PROBLEM) B_BG="#fbe7e5"; B_FG="#b3261e"; B_DOT="#d64541"; B_TXT="Problém"
             H_TITLE="Pozor — ${#problems[@]}× problém k prošetření"
             H_SUB="Server naběhl, ale některé kritické komponenty nejsou v pořádku.";;
  esac
  SYS_DOT="$(dot_color "$sys_icon")"; CRON_DOT="$(dot_color "$cron_icon")"
  DK_DOT="$(dot_color "$dk_icon")"
  [ "$dk_icon" = "✅" ] && [ "${running:-0}" -lt "${total:-0}" ] && DK_DOT="#d9a441"
  TS_DATE="$(date -u '+%Y-%m-%d')"; TS_TIME="$(date -u '+%H:%M UTC')"
  _td='padding:8px 2px;border-bottom:1px solid #eef1f4;'

  # řádky tabulky: kontejnery (role z watch-listů) + procesy/pipeliny (infos)
  CONT_ROWS=""
  for r in ${crows[@]+"${crows[@]}"}; do
    cname="$(html_esc "${r%%|*}")"; cstat="${r#*|}"; stxt="${cstat#* }"
    role="volitelný"; in_list "${r%%|*}" "$WATCH_CRITICAL" && role="kritický"
    CONT_ROWS+="<tr><td style=\"${_td}font-family:Consolas,Menlo,monospace;font-size:12.5px;color:#33414d;\">${cname}</td><td style=\"${_td}color:#71808f;font-size:12px;\">${role}</td><td align=\"right\" style=\"${_td}\"><span style=\"font-weight:600;font-size:12.5px;color:$(st_color "$cstat");white-space:nowrap;\"><span style=\"color:$(dot_color "$cstat");\">&#9679;</span> $(html_esc "$stxt")</span></td></tr>"
  done
  for x in ${infos[@]+"${infos[@]}"}; do
    iname="$(html_esc "${x%%:*}")"; irest="$(html_esc "${x#*: }")"
    icol="#71808f"; idot=""
    case "$x" in *běží*) icol="#157347"; idot="<span style=\"color:#1f9d55;\">&#9679;</span> ";; esac
    CONT_ROWS+="<tr><td style=\"${_td}font-family:Consolas,Menlo,monospace;font-size:12.5px;color:#33414d;\">${iname}</td><td style=\"${_td}color:#71808f;font-size:12px;\">proces / pipeline</td><td align=\"right\" style=\"${_td}\"><span style=\"font-weight:600;font-size:12.5px;color:${icol};white-space:nowrap;\">${idot}${irest}</span></td></tr>"
  done

  # alert boxy — jen když nejsou prázdné
  ALERTS=""
  if [ ${#problems[@]} -gt 0 ]; then
    items=""; for x in ${problems[@]+"${problems[@]}"}; do items+="<div style=\"font-size:13px;line-height:1.6;color:#3f4a53;\">&bull; $(html_esc "$x")</div>"; done
    ALERTS+="<tr><td style=\"padding:16px 22px 0;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\"><tr><td style=\"background:#fbe7e5;border:1px solid #f2c9c4;border-left:4px solid #d64541;border-radius:9px;padding:12px 14px;\"><div style=\"margin:0 0 6px;font-size:12px;letter-spacing:.06em;text-transform:uppercase;font-weight:800;color:#b3261e;\">&#10071; Problémy</div>${items}</td></tr></table></td></tr>"
  fi
  if [ ${#warnings[@]} -gt 0 ]; then
    items=""; for x in ${warnings[@]+"${warnings[@]}"}; do items+="<div style=\"font-size:13px;line-height:1.6;color:#3f4a53;\">&bull; $(html_esc "$x")</div>"; done
    ALERTS+="<tr><td style=\"padding:16px 22px 0;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\"><tr><td style=\"background:#fbf3dd;border:1px solid #eddcae;border-left:4px solid #d9a441;border-radius:9px;padding:12px 14px;\"><div style=\"margin:0 0 6px;font-size:12px;letter-spacing:.06em;text-transform:uppercase;font-weight:800;color:#9a6a00;\">&#9888; Varování</div>${items}</td></tr></table></td></tr>"
  fi

  _cell='border:1px solid #e5e9ee;border-radius:9px;padding:11px 12px;'
  _k='font-size:11px;letter-spacing:.07em;text-transform:uppercase;color:#71808f;font-weight:700;margin-bottom:5px;'
  _v='font-size:14px;font-weight:600;color:#1f2933;'
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
<tr><td style="padding:16px 22px 4px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
<td width="32%" style="${_cell}"><div style="${_k}">Systemd</div><div style="${_v}"><span style="color:${SYS_DOT};">&#9679;</span> ${sysstate:-?} &middot; ${nfailed:-0} failed</div></td>
<td width="2%"></td>
<td width="32%" style="${_cell}"><div style="${_k}">Docker</div><div style="${_v}"><span style="color:${DK_DOT};">&#9679;</span> ${running:-?} / ${total:-?} běží</div></td>
<td width="2%"></td>
<td width="32%" style="${_cell}"><div style="${_k}">Cron</div><div style="${_v}"><span style="color:${CRON_DOT};">&#9679;</span> $([ "$cron_icon" = "✅" ] && echo běží || echo NEběží)</div></td>
</tr></table></td></tr>
${ALERTS}
<tr><td style="padding:18px 22px 2px;">
<div style="font-size:11px;letter-spacing:.09em;text-transform:uppercase;color:#71808f;font-weight:700;margin:0 0 9px;">Kontejnery &amp; procesy</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13.5px;">${CONT_ROWS}</table></td></tr>
<tr><td style="padding:14px 22px;border-top:1px solid #eef1f4;font-size:12px;color:#71808f;">
Uptime: <b style="color:#3f4a53;font-weight:600;">$(uptime -p 2>/dev/null)</b> &nbsp;&nbsp; Kernel: <b style="color:#3f4a53;font-weight:600;">$(uname -r)</b> &nbsp;&nbsp; Reboot čeká: <b style="color:#3f4a53;font-weight:600;">${reboot_pending:-ne}</b></td></tr>
<tr><td style="background:#f7f8fa;border-top:1px solid #e5e9ee;padding:11px 22px;font-size:11px;color:#9aa6b1;font-family:Consolas,Menlo,monospace;border-radius:0 0 12px 12px;">post-boot-check &middot; vps-setup</td></tr>
</table></td></tr></table>
</body></html>
HTML
)"
  BOUNDARY="=_vps-health-$$"
  {
    printf 'Subject: [%s] post-boot %s %s\n' "$SRV_LABEL" "$ICON" "$STATUS"
    printf 'From: "%s (%s)" <root@%s>\n' "$SRV_LABEL" "${SRV_IP:-$HOST}" "$HOST"
    printf 'To: %s\n' "$EMAIL_TO"
    printf 'MIME-Version: 1.0\nContent-Type: multipart/alternative; boundary="%s"\n\n' "$BOUNDARY"
    printf -- '--%s\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n%s\n\n' "$BOUNDARY" "$REPORT"
    printf -- '--%s\nContent-Type: text/html; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n%s\n\n' "$BOUNDARY" "$HTML"
    printf -- '--%s--\n' "$BOUNDARY"
  } | sendmail -t 2>>/var/log/msmtp.log || \
    echo "$(date -u) mail selhal (viz msmtp.log)" >> "$LOG"
fi
HEALTHEOF
sed -i -e "s|__EMAIL_TO__|${EMAIL_TO}|g" \
       -e "s|__WATCH_CRITICAL__|${WATCH_CRITICAL}|g" \
       -e "s|__WATCH_OPTIONAL__|${WATCH_OPTIONAL}|g" \
       -e "s|__WATCH_IGNORE__|${WATCH_IGNORE}|g" \
       -e "s|__PIPELINE_LOGS__|${PIPELINE_LOGS}|g" \
       -e "s|__WATCH_PROC__|${WATCH_PROC}|g" \
       -e "s|__SRV_LABEL__|${SRV_LABEL}|g" /usr/local/sbin/post-boot-check.sh
chmod 755 /usr/local/sbin/post-boot-check.sh

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

# ─────────────────────────────────────────────────────────────────────────────
log "7/7 — test e-mailu + verifikace…"
# multipart: text/plain fallback + HTML se stejnou hlavičkou jako health-check
SETUP_TEXT="Baseline nastaven: auto-updaty(+reboot ${REBOOT_TIME} UTC), fail2ban(${F2B_MAXRETRY}/${F2B_BANTIME}), health-check. $(date -u)"
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
&bull; auto-updaty + noční reboot v <b style="font-weight:600;">${REBOOT_TIME} UTC</b> (jen když je potřeba)<br>
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
echo "• reboot po updatu:     ${REBOOT_TIME} UTC (jen když reboot-required)"
echo "• fail2ban sshd:        $(fail2ban-client status sshd 2>/dev/null | grep -i 'currently banned' || echo 'aktivní')"
echo "• post-boot-check:      $(systemctl is-enabled post-boot-check.service 2>/dev/null)"
echo
log "Ruční test health-checku:  sudo /usr/local/sbin/post-boot-check.sh  (pošle e-mail)"
log "Rollback viz runbook.md."
