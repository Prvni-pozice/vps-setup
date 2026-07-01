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
HOST="$(hostname)"
STATE_DIR="/var/lib/vps-health"; STATE="$STATE_DIR/status"; LOG="/var/log/post-boot-check.log"
mkdir -p "$STATE_DIR"

# Počkej, až se kontejnery s healthcheckem ustálí (max ~180 s)
for _ in $(seq 1 18); do
  starting="$(docker ps --filter health=starting -q 2>/dev/null | wc -l || echo 0)"
  [ "${starting:-0}" -eq 0 ] && break
  sleep 10
done

problems=(); warnings=(); infos=()
in_list() { case " $2 " in *" $1 "*) return 0;; esac; return 1; }
is_ignored() { local n="$1" p; for p in $WATCH_IGNORE; do case "$n" in $p) return 0;; esac; done; return 1; }
crunning() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]; }
cexists() { docker inspect "$1" >/dev/null 2>&1; }

# systemd
sysstate="$(systemctl is-system-running 2>/dev/null || true)"
[ "$sysstate" = "running" ] || problems+=("systemd: $sysstate")
failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd, -)"
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
    cexists "$c" || { problems+=("kritický '$c' chybí"); continue; }
    crunning "$c" || problems+=("kritický '$c' NEběží ($(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null))")
  done
  # volitelné — jen varování
  for c in $WATCH_OPTIONAL; do
    cexists "$c" || continue
    crunning "$c" || warnings+=("volitelný '$c' neběží")
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

reboot_pending=""; [ -f /var/run/reboot-required ] && reboot_pending="ANO ($(cat /var/run/reboot-required.pkgs 2>/dev/null | paste -sd, -))"

if   [ ${#problems[@]} -gt 0 ]; then STATUS="PROBLEM"; ICON="❌"
elif [ ${#warnings[@]} -gt 0 ]; then STATUS="WARN";    ICON="⚠"
else STATUS="OK"; ICON="✅"; fi
TS="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

sect() { [ "$2" -gt 0 ] || return 0; printf '%s:\n' "$1"; printf -- '- %s\n' "${@:3}"; }
REPORT="$(cat <<EOF
${ICON} ${HOST} — post-boot ${STATUS}
Čas:     ${TS}
Uptime:  $(uptime -p 2>/dev/null)
Kernel:  $(uname -r)
${docker_line}
Reboot čeká: ${reboot_pending:-ne}
$(sect "PROBLÉMY" "${#problems[@]}" ${problems[@]+"${problems[@]}"})
$(sect "VAROVÁNÍ" "${#warnings[@]}" ${warnings[@]+"${warnings[@]}"})
$(sect "INFO" "${#infos[@]}" ${infos[@]+"${infos[@]}"})
EOF
)"

printf '%s\n' "$REPORT" | tee -a "$LOG" >/dev/null
printf 'STATUS=%s\nTS=%s\n%s\n' "$STATUS" "$TS" "$REPORT" > "$STATE"

# e-mail (msmtp/sendmail) — pošli vždy po startu jako potvrzení
if command -v sendmail >/dev/null; then
  printf 'Subject: [%s] post-boot %s %s\nFrom: %s\nTo: %s\n\n%s\n' \
    "$HOST" "$ICON" "$STATUS" "root@$HOST" "$EMAIL_TO" "$REPORT" | sendmail -t 2>>/var/log/msmtp.log || \
    echo "$(date -u) mail selhal (viz msmtp.log)" >> "$LOG"
fi
HEALTHEOF
sed -i -e "s|__EMAIL_TO__|${EMAIL_TO}|g" \
       -e "s|__WATCH_CRITICAL__|${WATCH_CRITICAL}|g" \
       -e "s|__WATCH_OPTIONAL__|${WATCH_OPTIONAL}|g" \
       -e "s|__WATCH_IGNORE__|${WATCH_IGNORE}|g" \
       -e "s|__PIPELINE_LOGS__|${PIPELINE_LOGS}|g" /usr/local/sbin/post-boot-check.sh
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
if printf 'Subject: [%s] VPS setup dokončen ✅\nFrom: %s\nTo: %s\n\nBaseline nastaven: auto-updaty(+reboot %s UTC), fail2ban(%s/%s), health-check. %s\n' \
     "$(hostname)" "root@$(hostname)" "$EMAIL_TO" "$REBOOT_TIME" "$F2B_MAXRETRY" "$F2B_BANTIME" "$(date -u)" \
     | sendmail -t 2>>/var/log/msmtp.log; then
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
