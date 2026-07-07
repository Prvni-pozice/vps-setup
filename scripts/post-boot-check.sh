#!/usr/bin/env bash
# post-boot-check.sh — po startu ověří stav systému + Docker kontejnerů,
# zapíše status (log + MOTD state) a pošle e-mail.
# Instalace: symlink z /usr/local/sbin (dělá setup.sh). Konfigurace se čte
# ZA BĚHU z /etc/vps-setup.env — úprava env souboru (nebo git pull tohoto
# skriptu) platí od příští kontroly, setup.sh se znovu spouštět nemusí.
set -uo pipefail
CONF="${VPS_SETUP_ENV:-/etc/vps-setup.env}"
[ -r "$CONF" ] && . "$CONF"
EMAIL_TO="${EMAIL_TO:-root}"
WATCH_CRITICAL="${WATCH_CRITICAL:-}"
WATCH_OPTIONAL="${WATCH_OPTIONAL:-}"
WATCH_IGNORE="${WATCH_IGNORE:-}"
PIPELINE_LOGS="${PIPELINE_LOGS:-}"
WATCH_PROC="${WATCH_PROC:-}"
SRV_LABEL="${SRV_LABEL:-$(hostname -s)}"
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
if systemctl is-active --quiet docker 2>/dev/null; then
  # Jmenovatel = jen kontejnery, které MAJÍ běžet (restart policy != no).
  # Jednorázové/pokusné (policy=no, typicky exited) se nepočítají — jinak by
  # jeden zapomenutý one-shot kontejner trvale barvil stav oranžově (13/14).
  running=0; total=0
  for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
    pol="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null)"
    case "$pol" in ""|no) continue;; esac
    total=$((total+1)); crunning "$c" && running=$((running+1))
  done
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

# cron pipelines (import-felix apod.): "název:/log" nebo "název:/log:max_min".
# Log čerstvý (≤ max, default 120 min) → OK/zeleně; starší nebo chybí → ⚠ oranžově.
for spec in $PIPELINE_LOGS; do
  pname="${spec%%:*}"; rest="${spec#*:}"
  plog="${rest%%:*}"; maxage="${rest#*:}"
  { [ "$maxage" = "$rest" ] || [ -z "$maxage" ]; } && maxage=120
  if [ -f "$plog" ]; then
    age=$(( ( $(date +%s) - $(stat -c %Y "$plog" 2>/dev/null || echo 0) ) / 60 ))
    if [ "$age" -le "$maxage" ]; then infos+=("$pname: cron log ${age} min starý — běží")
    else warnings+=("$pname: cron log ${age} min starý (>${maxage} min — možná neběžel)"); fi
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

# tmux — jen informativně, když na serveru běží (≥1 session). Health-check je
# root, ale tmux server je per-uživatel → projdi sockety všech uživatelů
# (root je smí číst) a sečti session napříč nimi.
if command -v tmux >/dev/null 2>&1; then
  tmux_sess=0
  for sock in /tmp/tmux-*/* /run/user/*/tmux-*/*; do
    [ -S "$sock" ] || continue
    n="$(tmux -S "$sock" ls 2>/dev/null | wc -l)"
    [ "${n:-0}" -gt 0 ] && tmux_sess=$((tmux_sess+n))
  done
  [ "$tmux_sess" -gt 0 ] && infos+=("tmux: ${tmux_sess} session běží")
fi

reboot_pending=""; reboot_pkgs=""
if [ -f /var/run/reboot-required ]; then
  reboot_pkgs="$(cat /var/run/reboot-required.pkgs 2>/dev/null | paste -sd, -)"
  reboot_pending="ANO${reboot_pkgs:+ ($reboot_pkgs)}"
fi

if   [ ${#problems[@]} -gt 0 ]; then STATUS="PROBLEM"; ICON="❌"
elif [ ${#warnings[@]} -gt 0 ]; then STATUS="WARN";    ICON="⚠"
else STATUS="OK"; ICON="✅"; fi
TS="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# RUN_MODE=boot (po startu, default) | daily (denní heartbeat) — mění jen slovník
RUN_MODE="${RUN_MODE:-boot}"
if [ "$RUN_MODE" = daily ]; then
  MODE_TAG="health"; FOOT_TAG="health-check"
  OK_HEAD="server OK"; OK_TITLE="Server běží v pořádku"
  OK_SUB="Všechny služby i kontejnery jsou v provozu."; OK_VERDICT="Vše v pořádku."
  PROB_SUB="Na serveru nejsou některé kritické komponenty v pořádku."
else
  MODE_TAG="post-boot"; FOOT_TAG="post-boot-check"
  OK_HEAD="server OK po restartu"; OK_TITLE="Server naběhl v pořádku"
  OK_SUB="Po restartu jsou všechny služby i kontejnery v provozu."; OK_VERDICT="Vše naběhlo v pořádku."
  PROB_SUB="Server naběhl, ale některé kritické komponenty nejsou v pořádku."
fi

# ── sestavení přehledného reportu ───────────────────────────────────────────
case "$STATUS" in
  OK)      HEAD="$OK_HEAD";          VERDICT="$OK_VERDICT";;
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
if [ -n "$reboot_pending" ]; then add ""; add "🔴 NUTNÝ RUČNÍ RESTART — auto-reboot je vypnutý, spusť: sudo reboot"; fi
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
             H_TITLE="$OK_TITLE"
             H_SUB="$OK_SUB";;
    WARN)    B_BG="#fbf3dd"; B_FG="#9a6a00"; B_DOT="#d9a441"; B_TXT="Varování"
             H_TITLE="Naběhlo s výhradami — ${#warnings[@]}× varování"
             H_SUB="Server běží, ale některé komponenty hlásí varování — viz níže.";;
    PROBLEM) B_BG="#fbe7e5"; B_FG="#b3261e"; B_DOT="#d64541"; B_TXT="Problém"
             H_TITLE="Pozor — ${#problems[@]}× problém k prošetření"
             H_SUB="$PROB_SUB";;
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

  # červený box "nutný ruční restart" (auto-reboot je vypnutý) — nad ostatními
  REBOOT_BOX=""; RB_COL="#3f4a53"
  if [ -n "$reboot_pending" ]; then
    RB_COL="#b3261e"
    REBOOT_BOX="<tr><td style=\"padding:16px 22px 0;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\"><tr><td style=\"background:#fbe7e5;border:1px solid #f2c9c4;border-left:4px solid #d64541;border-radius:9px;padding:12px 14px;\"><div style=\"margin:0 0 6px;font-size:12px;letter-spacing:.06em;text-transform:uppercase;font-weight:800;color:#b3261e;\">&#128308; Nutný ruční restart</div><div style=\"font-size:13px;line-height:1.6;color:#3f4a53;\">Po aktualizacích je potřeba restart — <b>automatický reboot je vypnutý</b>. Restartuj ručně: <code style=\"font-family:Consolas,Menlo,monospace;background:#f3d9d5;padding:1px 5px;border-radius:4px;\">sudo reboot</code><br>Balíky: $(html_esc "${reboot_pkgs:-—}")</div></td></tr></table></td></tr>"
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
${REBOOT_BOX}
${ALERTS}
<tr><td style="padding:18px 22px 2px;">
<div style="font-size:11px;letter-spacing:.09em;text-transform:uppercase;color:#71808f;font-weight:700;margin:0 0 9px;">Kontejnery &amp; procesy</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13.5px;">${CONT_ROWS}</table></td></tr>
<tr><td style="padding:14px 22px;border-top:1px solid #eef1f4;font-size:12px;color:#71808f;">
Uptime: <b style="color:#3f4a53;font-weight:600;">$(uptime -p 2>/dev/null)</b> &nbsp;&nbsp; Kernel: <b style="color:#3f4a53;font-weight:600;">$(uname -r)</b> &nbsp;&nbsp; Reboot čeká: <b style="color:${RB_COL};font-weight:600;">${reboot_pending:-ne}</b></td></tr>
<tr><td style="background:#f7f8fa;border-top:1px solid #e5e9ee;padding:11px 22px;font-size:11px;color:#9aa6b1;font-family:Consolas,Menlo,monospace;border-radius:0 0 12px 12px;">${FOOT_TAG} &middot; vps-setup</td></tr>
</table></td></tr></table>
</body></html>
HTML
)"
  BOUNDARY="=_vps-health-$$"
  {
    printf 'Subject: [%s] %s %s %s\n' "$SRV_LABEL" "$MODE_TAG" "$ICON" "$STATUS"
    printf 'From: "%s (%s)" <root@%s>\n' "$SRV_LABEL" "${SRV_IP:-$HOST}" "$HOST"
    printf 'To: %s\n' "$EMAIL_TO"
    printf 'MIME-Version: 1.0\nContent-Type: multipart/alternative; boundary="%s"\n\n' "$BOUNDARY"
    printf -- '--%s\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n%s\n\n' "$BOUNDARY" "$REPORT"
    printf -- '--%s\nContent-Type: text/html; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n%s\n\n' "$BOUNDARY" "$HTML"
    printf -- '--%s--\n' "$BOUNDARY"
  } | sendmail -t 2>>/var/log/msmtp.log || \
    echo "$(date -u) mail selhal (viz msmtp.log)" >> "$LOG"
fi
