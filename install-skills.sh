#!/usr/bin/env bash
# install-skills.sh — selektivní instalátor Claude skillů z katalogu `skills/`.
#
# Filozofie: repo nese KATALOG skillů; každý server si vybere jen relevantní.
# Serverově specifické se nehardcoduje — vybere se ručně nebo přes auto-detekci.
#
# Režimy:
#   bash install-skills.sh                      → vypíše katalog (name · popis · tags)
#   bash install-skills.sh docker-ops astro…    → nainstaluje jen vyjmenované skilly
#   bash install-skills.sh --detect [dir]       → osahá projekt a nainstaluje pasující
#   bash install-skills.sh --gen-readme         → přegeneruje skills/README.md z frontmatterů
#
# Volby:
#   --global      cíl = ~/.claude/skills/  (jinak projektové $PROJ/.claude/skills/)
#
# Cíl instalace je idempotentní (přepíše). PROJ se pro projektový cíl vyžaduje
# (stejně jako install-claude-context.sh) — sjednocené chování.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_SRC="$HERE/skills"

GLOBAL=0
DETECT=0
GEN_README=0
PROBE_DIR=""
names=()

# ── argumenty ─────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --global)     GLOBAL=1 ;;
    --detect)     DETECT=1 ;;
    --gen-readme) GEN_README=1 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    --*)          echo "neznámá volba: $1" >&2; exit 2 ;;
    *)            if [ "$DETECT" = 1 ] && [ -z "$PROBE_DIR" ] && [ -d "$1" ]; then
                    PROBE_DIR="$1"        # --detect <dir>
                  else
                    names+=("$1")         # jméno skillu k instalaci
                  fi ;;
  esac
  shift
done

# ── frontmatter helper: fm_field <soubor> <pole> ──────────────────────────────
fm_field() {
  awk -v f="$2" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---"  { exit }
    infm {
      if (index($0, f":") == 1) {
        sub("^"f":[ \t]*", ""); print; exit
      }
    }' "$1"
}

# seznam dostupných skillů (adresáře se SKILL.md)
available_skills() {
  local d
  for d in "$SKILLS_SRC"/*/; do
    [ -f "${d}SKILL.md" ] || continue
    basename "$d"
  done | sort
}

# ── režim: katalog ────────────────────────────────────────────────────────────
print_catalog() {
  printf '%-16s %-52s %s\n' "SKILL" "KDY POUŽÍT" "TAGY"
  printf '%-16s %-52s %s\n' "----------------" "----------------------------------------------------" "----------------"
  local s desc tags
  while read -r s; do
    [ -n "$s" ] || continue
    desc="$(fm_field "$SKILLS_SRC/$s/SKILL.md" description)"
    tags="$(fm_field "$SKILLS_SRC/$s/SKILL.md" tags)"
    printf '%-16s %-52s %s\n' "$s" "${desc:0:52}" "$tags"
  done < <(available_skills)
}

# ── režim: generuj skills/README.md ───────────────────────────────────────────
gen_readme() {
  local out="$SKILLS_SRC/README.md" s desc tags
  {
    echo "# Katalog skillů"
    echo
    echo "> Generováno automaticky: \`bash install-skills.sh --gen-readme\`. Needituj ručně."
    echo
    echo "Repo nese katalog; každý server si vybere jen relevantní skilly:"
    echo
    echo '```'
    echo "bash install-skills.sh                 # vypíše tento katalog"
    echo "bash install-skills.sh docker-ops      # nainstaluje vyjmenované"
    echo "bash install-skills.sh --detect        # osahá projekt a nainstaluje pasující"
    echo '```'
    echo
    echo "| Skill | Kdy použít | Tagy |"
    echo "|---|---|---|"
    while read -r s; do
      [ -n "$s" ] || continue
      desc="$(fm_field "$SKILLS_SRC/$s/SKILL.md" description)"
      tags="$(fm_field "$SKILLS_SRC/$s/SKILL.md" tags)"
      echo "| \`$s\` | $desc | $tags |"
    done < <(available_skills)
  } > "$out"
  echo "→ přegenerováno: $out"
}

# ── auto-detekce: marker v projektu → doporučený skill ────────────────────────
detect_skills() {
  local dir="$1" found=()
  # docker-ops: docker binárka / socket / compose soubor
  if command -v docker >/dev/null 2>&1 || [ -S /var/run/docker.sock ] \
     || ls "$dir"/docker-compose.y*ml "$dir"/compose.y*ml >/dev/null 2>&1; then
    found+=(docker-ops)
  fi
  # symfony-dev: composer.json (PHP)
  [ -f "$dir/composer.json" ] && found+=(symfony-dev)
  # astro-builder: astro config nebo "astro" v package.json
  if ls "$dir"/astro.config.* >/dev/null 2>&1 \
     || { [ -f "$dir/package.json" ] && grep -q '"astro"' "$dir/package.json" 2>/dev/null; }; then
    found+=(astro-builder)
  fi
  # node-service: package.json bez Astro
  if [ -f "$dir/package.json" ] && ! printf '%s\n' ${found[@]+"${found[@]}"} | grep -qx astro-builder; then
    found+=(node-service)
  fi
  printf '%s\n' ${found[@]+"${found[@]}"}
}

# ── instalace jednoho skillu ──────────────────────────────────────────────────
resolve_dest() {
  if [ "$GLOBAL" = 1 ]; then
    DEST="$HOME/.claude/skills"
  else
    DEST="${PROJ:?nastav PROJ na cestu projektu tohoto serveru (nebo použij --global)}/.claude/skills"
  fi
  mkdir -p "$DEST"
}

install_one() {
  local name="$1"
  if [ ! -f "$SKILLS_SRC/$name/SKILL.md" ]; then
    echo "  ✗ $name — v katalogu není (přeskočeno)"; return 1
  fi
  rm -rf "${DEST:?}/$name"
  cp -r "$SKILLS_SRC/$name" "$DEST/$name"
  echo "  ✓ $name → $DEST/$name"
}

# ── main ──────────────────────────────────────────────────────────────────────
if [ "$GEN_README" = 1 ]; then
  gen_readme
  exit 0
fi

if [ "$DETECT" = 1 ]; then
  PROBE_DIR="${PROBE_DIR:-${PROJ:-$PWD}}"
  echo "→ detekce podle projektu: $PROBE_DIR"
  mapfile -t detected < <(detect_skills "$PROBE_DIR")
  if [ "${#detected[@]}" -eq 0 ]; then
    echo "  nic nedetekováno — vyber ručně: bash install-skills.sh <skill…> (katalog: bez argumentů)"
    exit 0
  fi
  # jen ty, co reálně jsou v katalogu; chybějící vypiš jako doporučení
  avail="$(available_skills)"; to_install=(); missing=()
  for d in "${detected[@]}"; do
    if printf '%s\n' "$avail" | grep -qx "$d"; then to_install+=("$d"); else missing+=("$d"); fi
  done
  [ "${#missing[@]}" -gt 0 ] && echo "  ℹ doporučeno, ale zatím není v katalogu: ${missing[*]}"
  if [ "${#to_install[@]}" -eq 0 ]; then echo "  nic k instalaci z katalogu"; exit 0; fi
  echo "  instaluji: ${to_install[*]}"
  resolve_dest
  for d in "${to_install[@]}"; do install_one "$d"; done
  exit 0
fi

if [ "${#names[@]}" -eq 0 ]; then
  print_catalog
  exit 0
fi

resolve_dest
rc=0
for n in "${names[@]}"; do install_one "$n" || rc=1; done
exit $rc
