# vps-setup

Provozní baseline pro Ubuntu VPS + přenos "Claude kontextu".

- **setup.sh** — auto-updaty(+noční reboot), fail2ban, SMTP notifikace (msmtp),
  health-check (po startu + denní heartbeat) + MOTD. Idempotentní. `sudo bash setup.sh`
  (ptá se na SMTP heslo). Dva HTML maily se stejnou šablonou: **health-check** (chodí
  vždy → ticho = problém) a **apt-upgrade** report (nahrazuje ošklivý plaintext).
- **runbook.md** — dokumentace, per-server proměnné, ověření, rollback, „zadání pro Claude".
- **install-claude-context.sh** — cut&paste přenos CLAUDE.md + skill + settings + paměti na nový server.

Bezpečnost: hesla nikdy v repu (skripty se ptají / čtou z env). `.gitignore` kryje běžné secret soubory.
