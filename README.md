# vps-setup

Provozní baseline pro Ubuntu VPS + přenos "Claude kontextu".

- **setup.sh** — auto-updaty (bez auto-rebootu; nutný restart hlásí červeně), fail2ban, SMTP notifikace (msmtp),
  health-check (po startu + denní heartbeat) + MOTD. Idempotentní. `sudo bash setup.sh`
  (na SMTP heslo se ptá jen poprvé). Dva HTML maily se stejnou šablonou: **health-check** (chodí
  vždy → ticho = problém) a **apt-upgrade** report (nahrazuje ošklivý plaintext).
- **scripts/** — health skripty; do `/usr/local/sbin` se symlinkují. Změny kódu
  (edit/`git pull`) i konfigurace (`/etc/vps-setup.env`) platí od příští kontroly
  **bez re-runu setup.sh**.
- **runbook.md** — dokumentace, per-server proměnné, ověření, rollback, „zadání pro Claude".
- **install-claude-context.sh** — cut&paste přenos CLAUDE.md + skill + settings + paměti na nový server.

Bezpečnost: hesla nikdy v repu (skripty se ptají / čtou z env). `.gitignore` kryje běžné secret soubory.
