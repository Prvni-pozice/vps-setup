# VPS baseline — runbook + zadání pro Claude

Nastaví na Ubuntu serveru (22.04/24.04) jednotný provozní baseline:
automatické aktualizace (**bez** automatického restartu — restart dělá uživatel
ručně, health-check ho červeně připomene), fail2ban, e-mailové notifikace
přes SMTP a health-check služeb/kontejnerů s reportem.

Instalaci dělá **`setup.sh`** (idempotentní; při opakovaném běhu se už neptá na
SMTP heslo). Health skripty žijí v **`scripts/`** a do `/usr/local/sbin` se
**symlinkují** — po prvním setupu se změny nasazují BEZ re-runu setup.sh:

- **změna konfigurace** (watch listy, prahy, e-mail…) → uprav `/etc/vps-setup.env`
  — skripty ho čtou za běhu, platí od příští kontroly
- **změna kódu** (logika checků, vzhled mailu) → uprav / `git pull` v repu
  — symlink míří přímo na repo, platí od příští kontroly
- `setup.sh` je potřeba jen poprvé na novém serveru (nebo při změně
  systemd/apt/fail2ban částí)

**Dva HTML maily se stejnou šablonou, From i předmětem `[SRV_LABEL]`:**
- **health-check** — po startu (`post-boot`) **i denně** (`health`, heartbeat).
  Chodí **vždy**, takže ticho = problém (server neběží / nemá mail).
- **apt-upgrade** — po každém automatickém upgradu. Nahrazuje ošklivý vestavěný
  plaintext (`Unattended-Upgrade::Mail` je vypnutý). Mailuje jen při změně/chybě.

---

## Co to nastaví (7 částí)

1. **Auto-updaty** (`unattended-upgrades`) — bezpečnostní **i** `-updates`, override v
   `/etc/apt/apt.conf.d/52unattended-local.conf` (defaultní `50…` se nemění).
2. **Automatický restart je VYPNUTÝ** (`Automatic-Reboot "false"`). Když update
   vyžaduje restart (`reboot-required`), health-check i apt report to **červeně
   zvýrazní** (box „🔴 Nutný ruční restart" + seznam balíků) — restart provede
   uživatel ručně (`sudo reboot`). Timer instalace updatů běží v `UPGRADE_TIME`.
3. **SMTP relay** (`msmtp` + `msmtp-mta`) → `/etc/msmtprc` (chmod 600, root-only).
4. **fail2ban** — `sshd` jail: `maxretry` pokusů → ban `bantime`, **bez eskalace**.
   Ban akce `ufw` (když je UFW aktivní) jinak `nftables-multiport`. `backend=systemd`
   (Ubuntu 24.04 nemá `/var/log/auth.log`).
5. **Health-check** `scripts/post-boot-check.sh` (symlink z
   `/usr/local/sbin/post-boot-check.sh`; konfigurace za běhu z
   `/etc/vps-setup.env`) — dvouúrovňový watch-list
   (kritické = ❌ alert, volitelné = ⚠ warning) + auto-detekce ostatních
   `always/unless-stopped` kontejnerů. Kontejnery s policy `no` (pokusné) se ignorují.
   **Počítadlo Docker (X/Y)** má ve jmenovateli jen kontejnery, které _mají_ běžet
   (policy ≠ `no`) — jeden zapomenutý one-shot kontejner tak netrvale nebarví stav
   oranžově. Kontroluje i `cron` (kvůli cron pipelines) a **stáří jejich logů proti
   prahu** (`PIPELINE_LOGS` „název:log:max_min", default 120 min: čerstvý = zeleně,
   starší nebo chybí = ⚠ oranžově), plus kritické ne-kontejnerové procesy
   (`WATCH_PROC`, např. honeypot) a **počet běžících `tmux` session** (napříč
   uživateli, jen když nějaká běží — informativně).
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
| `REBOOT_TIME` | 02:30 | **nepoužívá se** (auto-reboot vypnutý; ponecháno pro zpětnou kompat.) |
| `UPGRADE_TIME` | 02:00 | UTC — kdy běží instalace updatů |
| `F2B_MAXRETRY` / `F2B_BANTIME` | 5 / 1h | fail2ban |
| `F2B_IGNOREIP` | 127.0.0.1/8 ::1 | whitelist (přidej pevnou IP, máš-li) |
| `WATCH_CRITICAL` | *(prázdné)* | kontejnery: dole = ❌ alert. **Per server** → default prázdný, hodnoty v `/etc/vps-setup.env`. (1P-32GB: `is-next-php-1 is-next-database-1 is-next-nginx-1 paperclip-postgres open-webui`) |
| `WATCH_OPTIONAL` | *(prázdné)* | kontejnery: dole = ⚠ warning |
| `WATCH_IGNORE` | *(prázdné)* | glob vzory mimo auto-detekci (1P-32GB: `is-next-mailer-1` = mailpit, záměrně vypnutý) |
| `PIPELINE_LOGS` | *(prázdné)* | cron pipeliny: `název:log` nebo `název:log:max_min` (default práh 120 min; čerstvý=✅ zeleně, starší/chybí=⚠ oranžově). (1P-16GB: `import-felix:/data/bot/import-felix/logs/cron.log`) |
| `WATCH_PROC` | *(prázdné)* | kritické procesy: `název:pgrep-pattern` — neběží = ❌ alert. (1P-16GB: `honeypot:honeypot.js`) |
| `SRV_LABEL` | `$(hostname -s)` | čitelný název serveru — jde do From a předmětu mailu (IP se doplní sama). **Unikátní per server** → default je hostname, ne natvrdo konkrétní server. Tento server (`1p`) má `1P-16GB` v `/etc/vps-setup.env`. |
| `HEALTH_DAILY_TIME` | `04:00` | UTC — kdy chodí denní health-check (heartbeat po upgrade+reboot okně) |

> 💾 **Per-server konfigurace** se na konci běhu uloží do **`/etc/vps-setup.env`**
> (bez hesla — to zůstává jen v `/etc/msmtprc`). Health skripty ho čtou **za
> běhu** → úprava souboru platí od příští kontroly, bez re-runu setup.sh.
> Přednost: cmdline env > `/etc/vps-setup.env` > default. Chceš jiný název
> serveru nebo práh pipeline? Uprav to přímo v tom souboru (mimo git).

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
     SRV_LABEL="Ollama-32GB" \
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
> 2. Se mnou potvrď per-server proměnné (hlavně `WATCH_CRITICAL/OPTIONAL`, `PIPELINE_LOGS`
>    vč. prahu stáří, SMTP údaje). Auto-reboot je vypnutý (restart ručně). Kontejnery
>    s policy `no` neřeš (pokusné).
> 3. Spusť `sudo … bash setup.sh` s těmi proměnnými (heslo zadám interaktivně).
> 4. Ověř podle sekce „Ověření" a nech mě zkontrolovat testovací e-mail.
> Security gate: heslo nikdy do gitu ani do logu; `/etc/msmtprc` musí být 0600.
