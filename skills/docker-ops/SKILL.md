---
name: docker-ops
description: Provoz a diagnostika Docker kontejnerů na serveru — stav, logy, restart, compose, čištění místa.
tags: [docker, ops, containers, compose]
---

Použij tento skill, když uživatel chce:
- zjistit stav kontejnerů (co běží / co spadlo / co je unhealthy)
- podívat se do logů kontejneru nebo je sledovat živě
- restartovat / zastavit / nasadit službu (i přes docker compose)
- uvolnit místo na disku (images, volumes, build cache)
- diagnostikovat, proč kontejner nenaběhl po rebootu

Pravidla:
- **Nedestruktivní příkazy bez potvrzení** (`ps`, `logs`, `inspect`, `stats`) jdou rovnou.
- **Destruktivní** (`rm`, `down -v`, `prune`, `system prune`, mazání volumes) — vždy
  nejdřív ukázat, co se smaže, a počkat na potvrzení. `-v` (volumes) = data pryč.
- Nikdy nepatlej produkční data. Volume s DB = poklad.
- Publikované porty přes Docker **obcházejí UFW** — expozici řešit cloud firewallem
  / bindovat na `127.0.0.1`, ne spoléhat na `ufw`.
- Tajemství (env, hesla) z `inspect`/`logs` nikdy nevypisovat do reportu.

Postup diagnostiky:
1. `docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'` — přehled.
2. U spadlého: `docker logs --tail 50 <name>` a `docker inspect -f '{{.State.Status}} {{.State.ExitCode}} {{.State.Error}}' <name>`.
3. Compose stack: `docker compose ps` v adresáři se `compose.yaml`; restart `docker compose up -d`.
4. Místo na disku: `docker system df`; čištění napřed `--dry-run`, pak s potvrzením.
5. Health po rebootu: ověř `restart` policy (`always`/`unless-stopped`) — bez ní kontejner po startu nenaběhne.

Kontrolní checklist:
- vím, proč kontejner spadl (exit code + poslední logy), než něco restartuju
- destruktivní krok potvrzen uživatelem a předem vypsán
- žádná credentials v reportu
- po zásahu ověřen stav (`docker ps`, healthcheck)
