# VPS baseline — runbook + zadání pro Claude

Nastaví na Ubuntu serveru (22.04/24.04) jednotný provozní baseline:
automatické aktualizace s nočním restartem, fail2ban, e-mailové notifikace
přes SMTP a health-check služeb/kontejnerů s reportem.

Vše dělá **`setup.sh`** — idempotentní (lze spustit opakovaně), jeden soubor.

**Dva HTML maily se stejnou šablonou, From i předmětem `[SRV_LABEL]`:**
- **health-check** — po startu (`post-boot`) **i denně** (`health`, heartbeat).
  Chodí **vždy**, takže ticho = problém (server neběží / nemá mail).
- **apt-upgrade** — po každém automatickém upgradu. Nahrazuje ošklivý vestavěný
  plaintext (`Unattended-Upgrade::Mail` je vypnutý). Mailuje jen při změně/chybě.

---

## Co to nastaví (7 částí)

1. **Auto-updaty** (`unattended-upgrades`) — bezpečnostní **i** `-updates`, override v
   `/etc/apt/apt.conf.d/52unattended-local.conf` (defaultní `50…` se nemění).
2. **Noční restart** — jen když je potřeba (`reboot-required`), v `REBOOT_TIME`.
   Timer instalace updatů se posune na `UPGRADE_TIME` (musí být **před** rebootem,
   jinak by se restart odložil o den).
3. **SMTP relay** (`msmtp` + `msmtp-mta`) → `/etc/msmtprc` (chmod 600, root-only).
4. **fail2ban** — `sshd` jail: `maxretry` pokusů → ban `bantime`, **bez eskalace**.
   Ban akce `ufw` (když je UFW aktivní) jinak `nftables-multiport`. `backend=systemd`
   (Ubuntu 24.04 nemá `/var/log/auth.log`).
5. **Health-check** `/usr/local/sbin/post-boot-check.sh` — dvouúrovňový watch-list
   (kritické = ❌ alert, volitelné = ⚠ warning) + auto-detekce ostatních
   `always/unless-stopped` kontejnerů. Kontejnery s policy `no` (pokusné) se ignorují.
   Kontroluje i `cron` (kvůli cron pipelines) a hlásí stáří jejich logů, plus
   kritické ne-kontejnerové procesy (`WATCH_PROC`, např. honeypot).
   **Timing:** skript nejdřív počká, až systemd dokončí start (poll
   `is-system-running`, max ~120 s) a až se ustálí kontejnery s healthcheckem
   (max ~180 s) — jinak by „starting" hned po bootu vypadalo jako problém.
   **Formát reportu** (mail + MOTD): verdikt nahoře, blok faktů (čas/uptime/
   kernel/reboot), sekce STAV (Systemd/Docker/Cron ✅/❌), KONTEJNERY po
   řádcích, PIPELINES/PROCESY, ❗PROBLÉMY a ⚠VAROVÁNÍ jen když existují.
   **Mail je multipart/alternative**: text/plain = textový report (fallback),
   text/html = karta se schváleným designem (tmavý header s názvem serveru,
   badge OK/Varování/Problém, STAV proužek, tabulka kontejnerů, alert boxy).
   E-mail-safe: inline styly, tabulkový layout, bez externích assetů.
   Stejnou hlavičku má i jednorázový mail „VPS setup dokončen" a **apt-upgrade** report.
   **Odesílatel mailu:** `"<SRV_LABEL> (<IP>)" <root@host>` — v klientovi se
   ukáže čitelný název serveru + veřejná IP (z `ip route get 1.1.1.1`),
   předmět `[<SRV_LABEL>] post-boot ✅ OK` (po startu), `[<SRV_LABEL>] health ✅ OK`
   (denní heartbeat) nebo `[<SRV_LABEL>] apt-upgrade ✅ OK` (po upgradu).
   Skript zná `RUN_MODE` (`boot`/`daily`) — mění jen slovník („po restartu" vs. „stav").
6. **systemd unit** `post-boot-check.service` — health-check po **každém** startu —
   plus **`vps-health-daily.timer`** (denně v `HEALTH_DAILY_TIME`, heartbeat i bez rebootu).
   **apt-upgrade report** `/usr/local/sbin/apt-upgrade-report.sh` se spouští přes
   `ExecStartPost` v drop-inu `apt-daily-upgrade.service.d/zz-vps-report.conf`.
7. **MOTD** `/etc/update-motd.d/99-vps-health` — stav při SSH přihlášení.

---

## Per-server proměnné (přepiš přes env)

| Proměnná | Default (server 1p) | Význam |
|---|---|---|
| `EMAIL_TO` | zdenek@prvni-pozice.com | kam chodí reporty |
| `SMTP_HOST` / `SMTP_PORT` | 1pmail.cz / 587 | 587=STARTTLS (1pmail.cz jede tady), 465=SSL |
| `SMTP_FROM` / `SMTP_USER` | podpora@prvni-pozice.com | odesílatel / login |
| `SMTP_PASS` | *(prompt)* | **nezadávat na cmdline** — skript se zeptá |
| `REBOOT_TIME` | 02:30 | **UTC** (= 04:30 CEST) |
| `UPGRADE_TIME` | 02:00 | UTC, před rebootem |
| `F2B_MAXRETRY` / `F2B_BANTIME` | 5 / 1h | fail2ban |
| `F2B_IGNOREIP` | 127.0.0.1/8 ::1 | whitelist (přidej pevnou IP, máš-li) |
| `WATCH_CRITICAL` | `vndftp grafana` | kontejnery: dole = ❌ alert |
| `WATCH_OPTIONAL` | `pgadmin nocodb n8n` | kontejnery: dole = ⚠ warning |
| `WATCH_IGNORE` | `coolify-* coolify` | glob vzory mimo auto-detekci |
| `PIPELINE_LOGS` | `import-felix:/data/bot/import-felix/logs/cron.log` | cron pipeliny: `název:log` (info) |
| `WATCH_PROC` | `honeypot:honeypot.js` | kritické procesy: `název:pgrep-pattern` — neběží = ❌ alert |
| `SRV_LABEL` | `$(hostname -s)` | čitelný název serveru — jde do From a předmětu mailu (IP se doplní sama). **Unikátní per server** → default je hostname, ne natvrdo konkrétní server. Tento server (`1p`) má `1P-16GB` v `/etc/vps-setup.env`. |
| `HEALTH_DAILY_TIME` | `04:00` | UTC — kdy chodí denní health-check (heartbeat po upgrade+reboot okně) |

> 💾 **Per-server konfigurace** se na konci běhu uloží do **`/etc/vps-setup.env`**
> (bez hesla — to zůstává jen v `/etc/msmtprc`). Skript ho na začátku sám načte,
> takže příští `sudo bash setup.sh` hodnoty nemusíš znovu předávat. Přednost:
> cmdline env > `/etc/vps-setup.env` > default. Chceš jiný název serveru? Uprav
> `SRV_LABEL` v tom souboru (mimo git).

> ⏰ Časy jsou v **UTC** (systémová zóna serveru). Pro CEST (léto) = UTC+2, CET (zima) = UTC+1.
> Ověř zónu: `timedatectl`. Chceš-li fixní lokální čas, nejdřív nastav TZ serveru.

---

## Spuštění

```bash
sudo bash setup.sh            # zeptá se na SMTP heslo (read -s, nejde do historie)
```

Jiný server (příklad s ollama + webem, bez coolify):
```bash
sudo EMAIL_TO=admin@firma.cz \
     SMTP_HOST=smtp.firma.cz SMTP_PORT=587 SMTP_FROM=server@firma.cz SMTP_USER=server@firma.cz \
     REBOOT_TIME=02:30 SRV_LABEL="Ollama-32GB" \
     WATCH_CRITICAL="ollama web-frontend" WATCH_OPTIONAL="adminer" \
     WATCH_IGNORE="" PIPELINE_LOGS="" WATCH_PROC="" \
     bash setup.sh
```

## Ověření

```bash
systemctl status fail2ban unattended-upgrades post-boot-check.service
fail2ban-client status sshd
sudo unattended-upgrade --dry-run -d | tail                 # co by se aktualizovalo
sudo /usr/local/sbin/post-boot-check.sh && cat /var/lib/vps-health/status   # ruční test + e-mail
sudo RUN_MODE=daily /usr/local/sbin/post-boot-check.sh      # test denního (heartbeat) mailu
sudo /usr/local/sbin/apt-upgrade-report.sh                  # test apt reportu (mailuje jen při změně/chybě)
systemctl list-timers apt-daily-upgrade.timer vps-health-daily.timer   # kdy poběží upgrade + heartbeat
```

## Rollback

```bash
sudo systemctl disable --now post-boot-check.service vps-health-daily.timer fail2ban
sudo rm -f /etc/apt/apt.conf.d/52unattended-local.conf \
           /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf \
           /etc/systemd/system/apt-daily-upgrade.service.d/zz-vps-report.conf \
           /etc/fail2ban/jail.local \
           /usr/local/sbin/post-boot-check.sh /usr/local/sbin/apt-upgrade-report.sh \
           /etc/systemd/system/post-boot-check.service \
           /etc/systemd/system/vps-health-daily.service \
           /etc/systemd/system/vps-health-daily.timer \
           /etc/update-motd.d/99-vps-health /etc/msmtprc /etc/vps-setup.env
sudo systemctl daemon-reload
# volitelně: sudo apt-get purge fail2ban msmtp msmtp-mta unattended-upgrades
```

---

## Bezpečnost

- **SMTP heslo** je jen v `/etc/msmtprc` (root, 0600). **Nikdy do gitu.** Tento runbook
  a `setup.sh` heslo neobsahují (skript se ptá interaktivně).
- fail2ban **nemá** whitelist externí IP (dynamická IP) → při 5 překlepech se sám na 1h
  zablokuješ. Máš-li pevnou IP, přidej ji do `F2B_IGNOREIP`.
- SSH auth se **nemění** (heslo i root login zůstávají). Silnější krok (jen klíč) je mimo
  tento skript — až budeš mít jistotu funkčního klíče, dá se doplnit.

---

## Zadání pro Claude na jiném VPS (zkopíruj jako prompt)

> Na tomto Ubuntu VPS nastav provozní baseline podle `/data/bot/vps-setup/setup.sh`
> (mám ho, nebo si ho vyžádej). Postup:
> 1. Zjisti reálný stav: `timedatectl` (zóna), `docker ps` (kontejnery + restart policy),
>    `crontab -l` a `/etc/cron.d` (pipeliny), `ufw status`, je-li MTA.
> 2. Se mnou potvrď per-server proměnné (hlavně `WATCH_CRITICAL/OPTIONAL`, `PIPELINE_LOGS`,
>    `REBOOT_TIME` v UTC, SMTP údaje). Kontejnery s policy `no` neřeš (pokusné).
> 3. Spusť `sudo … bash setup.sh` s těmi proměnnými (heslo zadám interaktivně).
> 4. Ověř podle sekce „Ověření" a nech mě zkontrolovat testovací e-mail.
> Security gate: heslo nikdy do gitu ani do logu; `/etc/msmtprc` musí být 0600.
