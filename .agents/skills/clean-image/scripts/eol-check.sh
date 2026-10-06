#!/usr/bin/env bash
# Component end-of-life check for an image.
#
# Two scopes:
#   1. Base OS + runtime (source: endoflife.date) - alpine/debian/ubuntu cycles, Go toolchain.
#   2. Language dependencies (source: ecosyste.ms) - every package Trivy inventoried,
#      across Go/npm/PyPI/Maven/... A dependency whose upstream repo is archived is
#      "eol" (critical, even with zero CVEs); an abandoned-but-not-archived one is
#      "stale" (warning).
#
# usage: eol-check.sh <image:tag>
# writes reports/clean/<slug>.eol.json
# exit: 0 clean/stale-only | 1 EOL found | 2 usage/precondition | 3 no data source reachable
#
# env: EOL_STALE_DAYS (default 1095)  - no-upstream-activity threshold for the "stale" warning
#      EOL_FAIL_ON_STALE=1            - treat stale as EOL (exit 1)
#      EOL_MAX_LOOKUPS (default 400)  - cap on live dependency lookups per run
set -uo pipefail

ROOT="${CLEAN_IMAGE_ROOT:-$PWD}"
OUT="$ROOT/reports/clean"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY_TSV="$SCRIPT_DIR/../reference/eol-deps.tsv"

image="${1:-}"
if [[ -z "$image" ]]; then
  echo "usage: eol-check.sh <image:tag> [scan.json]" >&2
  exit 2
fi
for t in jq curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }
done

slug=$(echo "$image" | sed 's#[/:]#_#g')
before="${2:-$OUT/$slug.before.json}"
eoljson="${EOL_OUT:-$OUT/$slug.eol.json}"
if [[ ! -s "$before" ]]; then
  echo "no scan found ($before); run scan.sh \"$image\" first" >&2
  exit 2
fi

ENDOFLIFE_API="https://endoflife.date/api"
ECOSYSTEMS_API="https://packages.ecosyste.ms/api/v1/packages/lookup"
CACHE="$OUT/.eol-cache.json"
STALE_DAYS="${EOL_STALE_DAYS:-1095}"
MAX_LOOKUPS="${EOL_MAX_LOOKUPS:-400}"
TODAY="$(date -u +%F)"
if cutoff=$(date -u -v-"${STALE_DAYS}"d +%F 2>/dev/null); then :; else
  cutoff=$(date -u -d "${STALE_DAYS} days ago" +%F 2>/dev/null || echo "1970-01-01")
fi
[[ -f "$CACHE" ]] || echo '{}' > "$CACHE"

OS_LINES="$(mktemp)"; DEP_LINES="$(mktemp)"; DEPS="$(mktemp)"
osfile="$(mktemp)"; depfile="$(mktemp)"
trap 'rm -f "$OS_LINES" "$DEP_LINES" "$DEPS" "$osfile" "$depfile"' EXIT

# ---- helpers ---------------------------------------------------------------

os_product() { # Trivy OS family -> endoflife.date product slug
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    alpine) echo alpine-linux ;;
    debian) echo debian ;;
    ubuntu) echo ubuntu ;;
    redhat) echo rhel ;;
    centos) echo centos ;;
    fedora) echo fedora ;;
    amazon) echo amazon-linux ;;
    oracle) echo oracle-linux ;;
    alma)   echo almalinux ;;
    rocky)  echo rocky-linux ;;
    suse|sles|opensuse) echo sles ;;
    *)      echo "" ;;
  esac
}

# Trivy lang result Type -> ecosyste.ms ecosystem name.
lang_eco() {
  case "$1" in
    gobinary) echo go ;;
    node-pkg|npm) echo npm ;;
    python-pkg) echo pypi ;;
    jar|java-archive|gradle|pom) echo maven ;;
    cargo) echo cargo ;;
    gem|bundler) echo rubygems ;;
    composer) echo packagist ;;
    nuget) echo nuget ;;
    *) echo "" ;;
  esac
}

urlenc() { printf '%s' "$1" | sed -e 's#/#%2F#g' -e 's/ /%20/g'; }

# ---- 1. OS + runtime EOL (endoflife.date) ----------------------------------

fam=$(jq -r '.Metadata.OS.Family // empty' "$before")
osname=$(jq -r '.Metadata.OS.Name // empty' "$before")
oprod=$(os_product "$fam")
if [[ -n "$fam" && -n "$oprod" && -n "$osname" ]]; then
  rel=$(curl -sL --max-time 30 "$ENDOFLIFE_API/$oprod.json" 2>/dev/null)
  if printf '%s' "$rel" | jq -e 'type=="array" and length>0' >/dev/null 2>&1; then
    printf '%s' "$rel" | jq -c --arg c "$fam" --arg p "$oprod" --arg v "$osname" --arg today "$TODAY" '
      def match_cycle($ver):
        ($ver|split(".")) as $vp
        | [ .[] | select(
              (.cycle|tostring|split(".")) as $cp
              | ($cp|length) <= ($vp|length)
                and ([range(0;($cp|length))] | all(. as $i | $cp[$i] == $vp[$i]))
          ) ]
        | sort_by(.cycle|tostring|split(".")|length) | last;
      ($v | sub("^v";"")) as $ver
      | (match_cycle($ver)) as $m
      | ([.[] | select((.eol==false) or ((.eol|type=="string") and (.eol >= $today)))] | first) as $latest
      | if $m == null then
          {component:$c,product:$p,installed:$v,status:"unknown",reason:"version not in EOL dataset"}
        else
          ($m.eol) as $e
          | (if $e == true then "eol"
             elif ($e|type=="string" and $e < $today) then "eol"
             else "supported" end) as $st
          | {component:$c,product:$p,installed:$v,cycle:($m.cycle|tostring),eol:$e,status:$st,
             latest_cycle:($latest.cycle//null),latest:($latest.latest//null)}
        end
    ' >> "$OS_LINES"
  else
    jq -nc --arg c "$fam" --arg p "$oprod" --arg v "$osname" \
      '{component:$c,product:$p,installed:$v,status:"unknown",reason:"endoflife.date unreachable"}' >> "$OS_LINES"
  fi
fi

# Go toolchain from the scanned binary.
gover=$(jq -r '[.Results[]?|select(.Class=="lang-pkgs")|.Packages[]?|select(.Name=="stdlib")|.Version]|first // empty' "$before")
if [[ -n "$gover" ]]; then
  rel=$(curl -sL --max-time 30 "$ENDOFLIFE_API/go.json" 2>/dev/null)
  if printf '%s' "$rel" | jq -e 'type=="array" and length>0' >/dev/null 2>&1; then
    printf '%s' "$rel" | jq -c --arg c "go" --arg p "go" --arg v "$gover" --arg today "$TODAY" '
      def match_cycle($ver):
        ($ver|split(".")) as $vp
        | [ .[] | select(
              (.cycle|tostring|split(".")) as $cp
              | ($cp|length) <= ($vp|length)
                and ([range(0;($cp|length))] | all(. as $i | $cp[$i] == $vp[$i]))
          ) ]
        | sort_by(.cycle|tostring|split(".")|length) | last;
      ($v | sub("^v";"")) as $ver
      | (match_cycle($ver)) as $m
      | ([.[] | select((.eol==false) or ((.eol|type=="string") and (.eol >= $today)))] | first) as $latest
      | if $m == null then
          {component:$c,product:$p,installed:$v,status:"unknown",reason:"version not in EOL dataset"}
        else
          ($m.eol) as $e
          | (if $e == true then "eol"
             elif ($e|type=="string" and $e < $today) then "eol"
             else "supported" end) as $st
          | {component:$c,product:$p,installed:$v,cycle:($m.cycle|tostring),eol:$e,status:$st,
             latest_cycle:($latest.cycle//null),latest:($latest.latest//null)}
        end
    ' >> "$OS_LINES"
  fi
fi

# ---- 2. Dependency EOL (ecosyste.ms) ---------------------------------------

jq -r '.Results[]?|select(.Class=="lang-pkgs")|.Type as $t|.Packages[]?|"\($t)\t\(.Name)\t\(.Version)"' "$before" \
| while IFS=$'\t' read -r typ name ver; do
    [[ "$name" == "stdlib" ]] && continue
    eco=$(lang_eco "$typ")
    [[ -z "$eco" ]] && continue
    printf '%s\t%s\t%s\n' "$eco" "$name" "$ver"
  done | sort -u > "$DEPS"

total_deps=$(grep -c . "$DEPS" 2>/dev/null || echo 0)
lookups=0; truncated=0
while IFS=$'\t' read -r eco name ver; do
  [[ -z "$name" ]] && continue
  # Curated registry first (authoritative, offline).
  succ=$(awk -F'\t' -v e="$eco" -v n="$name" '!/^#/ && $1==e && $2==n {print $3; exit}' "$REGISTRY_TSV" 2>/dev/null)
  if [[ -n "$succ" ]]; then
    jq -nc --arg e "$eco" --arg n "$name" --arg v "$ver" --arg s "$succ" \
      '{ecosystem:$e,name:$n,version:$v,status:"eol",successor:$s,reason:"curated EOL registry"}' >> "$DEP_LINES"
    continue
  fi

  key="$eco:$name"
  verdict=$(jq -c --arg k "$key" '.[$k] // empty' "$CACHE" 2>/dev/null)
  if [[ -z "$verdict" ]]; then
    if [[ "$lookups" -ge "$MAX_LOOKUPS" ]]; then
      truncated=$((truncated+1)); continue
    fi
    lookups=$((lookups+1))
    resp=$(curl -sL --max-time 30 "$ECOSYSTEMS_API?name=$(urlenc "$name")" 2>/dev/null)
    if printf '%s' "$resp" | jq -e 'type=="array" and length>0' >/dev/null 2>&1; then
      verdict=$(printf '%s' "$resp" | jq -c --arg cutoff "$cutoff" '
        (.[0] // {}) as $p
        | {repo:($p.repository_url//null),
           archived:($p.repo_metadata.archived//false),
           pushed_at:($p.repo_metadata.pushed_at//null),
           latest_release:($p.latest_release_published_at//null)}
        | .status = (if .archived then "eol"
                     elif .repo == null then "unknown"
                     elif (.pushed_at != null and (.pushed_at[0:10] < $cutoff)) then "stale"
                     else "maintained" end)
        | .reason = (if .status=="eol" then "upstream repo archived"
                     elif .status=="stale" then "no upstream activity since \(.pushed_at[0:10])"
                     elif .status=="unknown" then "repository not resolved"
                     else "maintained upstream" end)
      ')
    else
      verdict='{"repo":null,"status":"unknown","reason":"ecosyste.ms lookup failed"}'
    fi
    printf '%s' "$verdict" | jq -c --arg k "$key" --argjson v "$verdict" '.[$k]=$v' "$CACHE" > "$CACHE.tmp" 2>/dev/null && mv "$CACHE.tmp" "$CACHE"
  fi
  printf '%s' "$verdict" | jq -c --arg e "$eco" --arg n "$name" --arg v "$ver" '. + {ecosystem:$e,name:$n,version:$v}' >> "$DEP_LINES"
done < "$DEPS"

# ---- assemble + report -----------------------------------------------------

jq -s '.' "$OS_LINES" > "$osfile" 2>/dev/null || echo '[]' > "$osfile"
jq -s '.' "$DEP_LINES" > "$depfile" 2>/dev/null || echo '[]' > "$depfile"

jq -n --slurpfile os "$osfile" --slurpfile deps "$depfile" \
  --arg image "$image" --arg g "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson stale "$STALE_DAYS" \
  '{image:$image, generated:$g,
    policy:{archived:"eol", stale_days:$stale, source_os:"endoflife.date", source_deps:"ecosyste.ms"},
    eol_found:((($os[0]//[])|any(.[];.status=="eol")) or (($deps[0]//[])|any(.[];.status=="eol"))),
    stale_found:(($deps[0]//[])|any(.[];.status=="stale")),
    os_components:($os[0]//[]), dependencies:($deps[0]//[])}' > "$eoljson"

echo "==> Component EOL check for $image (as of $TODAY)"
echo "-- base OS / runtime --"
printf '%-10s %-10s %-12s %-10s %-12s %s\n' STATUS COMPONENT INSTALLED CYCLE EOL LATEST
jq -r '.os_components[]? | [.status,.component,.installed,(.cycle//"-"),(if .eol==null then "-" else (.eol|tostring) end),(.latest//"-")]|@tsv' "$eoljson" \
  | while IFS=$'\t' read -r st c i cy e l; do printf '%-10s %-10s %-12s %-10s %-12s %s\n' "$st" "$c" "$i" "$cy" "$e" "$l"; done
echo "-- dependencies (archived = EOL, stale = warning) --"
jq -r '.dependencies[]? | select(.status!="maintained") | [.status,.ecosystem,.name,.version,(.repo//"-"),(.successor)]|@tsv' "$eoljson" \
  | while IFS=$'\t' read -r st eco n v r s; do
      printf '%-10s %-8s %-45s %-12s %s\n' "$st" "$eco" "$n" "$v" "${s:-$r}"
    done
eol_deps=$(jq '[.dependencies[]?|select(.status=="eol")]|length' "$eoljson")
stale_deps=$(jq '[.dependencies[]?|select(.status=="stale")]|length' "$eoljson")
maint_deps=$(jq '[.dependencies[]?|select(.status=="maintained")]|length' "$eoljson")
unk_deps=$(jq '[.dependencies[]?|select(.status=="unknown")]|length' "$eoljson")
echo "DEPS total=$total_deps maintained=$maint_deps eol=$eol_deps stale=$stale_deps unknown=$unk_deps lookups=$lookups truncated=$truncated"
echo "EOL_JSON=$eoljson"

if jq -e '.eol_found==true' "$eoljson" >/dev/null 2>&1; then
  echo "EOL_FOUND=true"; exit 1
fi
if [[ "${EOL_FAIL_ON_STALE:-0}" == "1" ]] && jq -e '.stale_found==true' "$eoljson" >/dev/null 2>&1; then
  echo "EOL_FOUND=true (stale)"; exit 1
fi
echo "EOL_FOUND=false"; exit 0
