#!/usr/bin/env bash
# install-claude-context.sh — přenese "Claude kontext" na nový server.
# NEobsahuje přihlášení/creds — na novém stroji se do Claude Code přihlas zvlášť.
#
# ⚠️ Přenáší jen UNIVERZÁLNÍ kontext (styl práce, coding discipline, security gate,
#    obecné preference/paměti). Serverově specifické věci NEHARDCODOVAT — na každém
#    serveru jsou jiné projekty v jiných složkách. Následující se vždy donastaví
#    podle reality daného serveru (společně s uživatelem):
#      • PROJ                      = cesta k projektu tohoto serveru
#      • projektový allow-list     = podle nástrojů, které server reálně používá
#      • skilly + projektové paměti = dle konkrétního projektu
set -euo pipefail

PROJ="${PROJ:?nastav PROJ na cestu projektu tohoto serveru, např. PROJ=/data/xxx bash install-claude-context.sh}"
MEM_DIR="$HOME/.claude/projects/${PROJ//\//-}/memory"   # odvozeno z PROJ (/ → -)
mkdir -p "$PROJ/.claude" "$MEM_DIR" "$HOME/.claude"
echo "→ zapisuji do $PROJ a $MEM_DIR"

# ── 1) HLAVNÍ CLAUDE.md ───────────────────────────────────────────────────────
cat > "$PROJ/CLAUDE.md" <<'CLAUDEMD'
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Role
Jsi interní provozní/dev asistent pro administrativní a provozní úkoly.

# Cíl
Pomáhej mi se strukturou práce, návrhy postupů, přípravou souborů a jednoduchými automatizacemi.

# Chování
- Odpovídej stručně a věcně.
- Když něco nevíš, řekni to.
- Neprováděj destruktivní příkazy bez potvrzení.
- Navrhuj další krok po malých krocích.
- Preferuj práci se soubory v tomto projektu.

# Coding discipline

- **Think first:** State assumptions; if multiple readings exist, ask — don't pick silently. Push back when a simpler approach exists.

- **Simplicity:** Minimum code that solves the problem. No speculative features, abstractions, or configurability that wasn't asked for.

- **Surgical edits:** Touch only what the task requires. Don't refactor or reformat adjacent code; match existing style. Flag unrelated dead code — don't delete it.

- **Verify:** Turn the task into a checkable goal (write the failing test, then make it pass) and loop until it's green.

# Paměť
- Pamatuj si důležité preference pro tento projekt.
- Udržuj si přehled o tom, co jsme už nastavili.

# Security gate (před každým `git commit` a před každým `git push`)

Tyto kontroly **vždy** spusť — nezávisle na projektu, jazyku ani velikosti změny.
Pokud něco selže, **NEPOMITOVAT** a zeptat se uživatele.

## 1. Pre-commit secret scan
Spusť `git diff --cached` a hledej patterny:
- `sk-[A-Za-z0-9]{20,}` (OpenAI/Anthropic-style klíče)
- `pk_live_`, `sk_live_`, `pk_test_`, `sk_test_` (Stripe)
- `AKIA[0-9A-Z]{16}` (AWS access key)
- `ghp_`, `gho_`, `ghs_`, `github_pat_` (GitHub tokens)
- `-----BEGIN .*PRIVATE KEY-----` (RSA/SSH klíče)
- `password\s*[:=]\s*['"][^'"]+['"]` (hardcoded heslo v kódu)
- `Bearer\s+[A-Za-z0-9._-]{20,}` (auth tokeny)
- `(api[_-]?key|api[_-]?secret|access[_-]?token|client[_-]?secret)\s*[:=]\s*['"][^'"]+['"]`
- `mongodb(\+srv)?://[^:]+:[^@]+@`, `postgres(ql)?://[^:]+:[^@]+@`, `mysql://[^:]+:[^@]+@`
  (connection stringy s heslem)
- FTP creds (config s hesly nesmí do gitu)

Pokud match nalezen: ukázat řádek + soubor, zeptat se uživatele, jestli je to false-positive nebo má být odstraněno před commitem.

## 2. .gitignore baseline (per stack)
Před prvním commitem nového repa zkontrolovat, že `.gitignore` obsahuje minimálně:
- **Vždy**: `.env`, `.env.*`, `*.local`, `*.key`, `*.pem`, `*.p12`, `*.pfx`, `id_rsa*`, `secrets.json`, `credentials.json`
- **Node**: `node_modules/`, `dist/`, `.astro/`, `.next/`, `.vercel/`
- **Python**: `__pycache__/`, `*.pyc`, `.venv/`, `venv/`, `*.egg-info/`
- **Logs/výstupy**: `logs/`, `*.log`, `*.sqlite`, `*.db` (pokud obsahuje data)
- **Importy/feedy** (import-felix-like): `data/feeds/*.xml`, `data/feeds/*.CSV`, `data/output/*.xml`

Pokud `.gitignore` chybí nebo má díru, **nabídnout doplnění** (ne automaticky commitnout).

## 3. Logy bez citlivých údajů
Nikdy v logu (`logger.info`, `print`, `console.log`, `echo`):
- API klíče, OAuth tokeny, Bearer tokeny, session tokens
- Hesla — ani plaintext, ani hash
- Plné čísla karet / CVV / PII

V diff hledat: `log|print|console.log` ve stejné řádce s pattern z bodu 1.

## 4. Boundary check (risk-based — jen kde to dává smysl)
Aplikuj na NOVĚ přidané funkce, které:
- přijímají vstup z HTTP / formuláře / CLI args
- volají externí API
- pracují s DB

Kontrola:
- **Hardcoded credentials = NIKDY** (ani v testech — používat env vars / fixtures)
- **SQL**: parametrizované queries, ne string concat (`f"... WHERE id={x}"` → ne)
- **N+1**: žádný DB call uvnitř `for`/`while` loopu bez batchingu
- **Vstup**: u API endpointů validace typů (Pydantic/zod/yup) — u utility funkcí netřeba

`Multi-tenant filter` a `explicit null-path` přidat **až** když to projekt opravdu má.

## 5. Risk-tier gate pro `git push` / FTP / deploy

Před pushem / nasazením self-classify změnu:

| Tier | Typ změny | Akce |
|---|---|---|
| **Low** | Typo, copy edit, doc-only, formatting | Push automaticky, krátká zpráva v reportu |
| **Medium** | Feature, refactor, závislosti, nový endpoint | Souhrn co mění + secret scan výsledek v reportu |
| **High** | Auth, platby, FTP creds, DB schema, deploy/rollback, smazání produkčních dat | Explicitní potvrzení uživatelem před akcí |

Pokud nejsi jistý tierem, klasifikuj výš.

# Workflow po dokončení úkolu
Po každém větším úkolu v textovém shrnutí uveď:
- **Security gate**: ✓ no secrets / ✓ gitignore OK / ✓ no creds in logs
- **Risk tier**: low / medium / high (a proč)
- **Co je v commitu**: 1 věta
- **Kam se to nasadilo**: GitHub / FTP / nikam
CLAUDEMD

# ── 2) SKILLY — per-projekt, netransferovat (na každém serveru jiné; doplní se
#      podle konkrétního projektu společně s uživatelem) ────────────────────────

# ── 3) GLOBÁLNÍ settings ──────────────────────────────────────────────────────
cat > "$HOME/.claude/settings.json" <<'SETJSON'
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  },
  "skipDangerousModePermissionPrompt": true,
  "agentPushNotifEnabled": true,
  "tui": "fullscreen"
}
SETJSON

cat > "$HOME/.claude/settings.local.json" <<'SETLOCAL'
{
  "permissions": {
    "allow": [
      "Bash(sudo apt:*)",
      "Skill(update-config)"
    ]
  }
}
SETLOCAL

# ── 4) PROJEKTOVÝ settings — allow-list doplnit per-server podle nástrojů,
#      které server reálně používá (zjistí se za provozu / se uživatelem) ───────
cat > "$PROJ/.claude/settings.local.json" <<'PROJSET'
{
  "permissions": {
    "allow": []
  }
}
PROJSET

# ── 5) UNIVERZÁLNÍ PAMĚTI (feedback + reference) ──────────────────────────────
cat > "$MEM_DIR/feedback_plain_text_tables.md" <<'M1'
---
name: plain text tabulky místo markdown
description: Tabulky v odpovědích psát jako plain text, ne markdown — kvůli kopírování
type: feedback
---
Tabulky v odpovědích psát jako **plain text v hlavním proudu textu**, NE markdown pipe-tabulky `| --- |` ANI obalené v code blocích.

**Why:** User kopíruje celou odpověď naráz drag-selectem. Markdown pipe tabulky se přenášejí špatně; code blocky rozbíjejí continuous select.

**How to apply:** Sloupce zarovnané mezerami, vsazené přímo do plynulého textu (žádné code bloky). Čitelné a kopírovatelné jako součást celé odpovědi.
M1

cat > "$MEM_DIR/feedback_local_urls_with_ip.md" <<'M2'
---
name: lokální URL vždy s IP, ne localhost
description: URL k běžícímu lokálnímu serveru sdílet s IP serveru, ne `localhost`
type: feedback
---
Když předávám URL k službě běžící na tomto serveru (dev server, prototyp, n8n, NocoDB…), píšu vždy plnou adresu s **IP serveru**, ne `localhost`.

**Why:** User přistupuje k serveru vzdáleně — `localhost` míří na jeho stroj, ne na server.

**How to apply:** IP zjisti přes `hostname -I | awk '{print $1}'` a piš `http://<IP>:PORT/cesta`. (Na novém serveru bude IP jiná — nikdy nehardcoduj, zjisti aktuální.)
M2

cat > "$MEM_DIR/feedback_git_push_batching.md" <<'M3'
---
name: feedback_git_push_batching
description: U projektů s auto-deploy (Vercel) pushovat jen jednou po dokončení dávky, ne po každém commitu
type: feedback
---
Nepushovat po každém commitu — u repo napojených na auto-deploy (Vercel) každý push spustí build a žere kredity.

**Why:** Auto-deploy při každém push.

**How to apply:** Commitovat průběžně lokálně, push až po poslední změně v dávce — nebo až uživatel řekne "pushni". Před pushem zkontrolovat git log.
M3

cat > "$MEM_DIR/feedback_file_upload.md" <<'M4'
---
name: Nahrávání souborů přes GitHub
description: Uživatel nahrává soubory na server přes GitHub (git pull), ne SCP/SFTP
type: feedback
---
Uživatel nahrává soubory výhradně přes GitHub — commitne do repa a udělá se `git pull`.

**Why:** Preferuje GitHub workflow / nemá přímý SCP.

**How to apply:** Když řekne "nahrál jsem soubor" / "tam jsem to dal", udělej `git pull` v příslušném repu. Neptat se na SCP/SFTP.
M4

cat > "$MEM_DIR/reference_vps_baseline.md" <<'M5'
---
name: reference_vps_baseline
description: "VPS baseline (auto-updaty+reboot, fail2ban, SMTP notifikace, post-boot health-check) — skript+runbook, reusable na další servery"
metadata:
  type: reference
---
**VPS baseline setup** — `setup.sh` (idempotentní) + `runbook.md`. Spustit `sudo bash setup.sh` (zeptá se na SMTP heslo přes read -s, uloží jen do /etc/msmtprc 0600).

Nastaví: unattended-upgrades (+`-updates`, noční reboot jen když reboot-required; upgrade timer PŘED reboot), fail2ban sshd (5 pokusů→ban 1h, bez eskalace, ufw/nftables, backend=systemd), msmtp SMTP relay, post-boot health-check (`/usr/local/sbin/post-boot-check.sh` + systemd oneshot + MOTD).

Health-check: dvouúrovňový watch-list `WATCH_CRITICAL` (❌)/`WATCH_OPTIONAL` (⚠) + auto-detekce ostatních always/unless-stopped kontejnerů; policy `no` (pokusné) se ignoruje; kontroluje cron + stáří logů cron pipeline (`PIPELINE_LOGS`). Vše přes env = per-server.

**Poznatky:** SMTP 1pmail.cz = port **587 STARTTLS** (ne 465). Časy v configu jsou **UTC** (systémová zóna). Docker publikuje porty tak, že **obchází UFW** → DB porty hlídat cloud firewallem / bindovat na 127.0.0.1.
M5

# ── 6) MEMORY.md index (jen přenesené položky) ────────────────────────────────
cat > "$MEM_DIR/MEMORY.md" <<'MEMIDX'
# Memory Index

## Reference
- [reference_vps_baseline.md](reference_vps_baseline.md) – VPS baseline (auto-updaty+reboot, fail2ban, SMTP, health-check); SMTP 1pmail.cz=587 STARTTLS; Docker obchází UFW

## Feedback
- [feedback_plain_text_tables.md](feedback_plain_text_tables.md) – tabulky jako plain text, ne markdown/code blocky
- [feedback_local_urls_with_ip.md](feedback_local_urls_with_ip.md) – lokální URL s IP serveru (hostname -I), ne localhost
- [feedback_git_push_batching.md](feedback_git_push_batching.md) – u auto-deploy pushovat až po dávce
- [feedback_file_upload.md](feedback_file_upload.md) – soubory přes GitHub → git pull
MEMIDX

echo
echo "✅ Hotovo. Přenesen univerzální kontext:"
echo "   • $PROJ/CLAUDE.md (role, coding discipline, security gate)"
echo "   • $HOME/.claude/settings.json + settings.local.json"
echo "   • $PROJ/.claude/settings.local.json (allow-list PRÁZDNÝ — doplnit per-server)"
echo "   • $MEM_DIR/ (4 feedback + 1 reference + MEMORY.md)"
echo
echo "Donastavit per-server (podle reality tohoto serveru, společně s uživatelem):"
echo "   • projektový allow-list v $PROJ/.claude/settings.local.json"
echo "   • skilly + projektové paměti dle konkrétního projektu"
echo "   • MCP servery / pluginy, pokud je projekt používá"
echo "   • Přihlášení do Claude Code proveď znovu (creds se nepřenášejí)."
