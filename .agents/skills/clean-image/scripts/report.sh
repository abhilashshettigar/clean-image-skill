#!/usr/bin/env bash
# Write the per-image markdown note: reports/clean/<slug>.md
# usage: report.sh <image:tag> <verdict> [pushed-ref]
set -uo pipefail

ROOT="${CLEAN_IMAGE_ROOT:-$PWD}"
OUT="$ROOT/reports/clean"
mkdir -p "$OUT"

image="${1:-}"
verdict="${2:-}"
pushed="${3:-}"
if [[ -z "$image" || -z "$verdict" ]]; then
  echo "usage: report.sh <image:tag> <verdict> [pushed-ref]" >&2
  exit 2
fi

slug=$(echo "$image" | sed 's#[/:]#_#g')
before="$OUT/$slug.before.json"
after="$OUT/$slug.after.json"
labels="$OUT/$slug.labels.json"
eoljson="$OUT/$slug.eol.json"
eolbefore="$OUT/$slug.eol.before.json"
note="$OUT/$slug.md"

counts() { # $1 = json file, $2 = severity
  jq --arg s "$2" '[.Results[]?|.Vulnerabilities[]?|select(.Severity==$s)]|length' "$1" 2>/dev/null || echo "?"
}
total_of() { jq '[.Results[]?|.Vulnerabilities[]?]|length' "$1" 2>/dev/null || echo "?"; }

digest="-"
src="-"; rev="-"; ver="-"
if [[ -s "$labels" ]]; then
  digest=$(jq -r '.repodigests[0] // "-"' "$labels")
  src=$(jq -r '.labels["org.opencontainers.image.source"] // "-"' "$labels")
  rev=$(jq -r '.labels["org.opencontainers.image.revision"] // "-"' "$labels")
  ver=$(jq -r '.labels["org.opencontainers.image.version"] // "-"' "$labels")
fi

trivy_ver=$(trivy --version 2>/dev/null | head -n1 | sed 's/Version: //')
db_date=$(trivy --version 2>/dev/null | grep -m1 UpdatedAt | sed 's/.*UpdatedAt: //')

{
  echo "# Clean-image note: \`$image\`"
  echo
  echo "- **Verdict:** \`$verdict\`"
  echo "- **Original ref:** \`$image\`"
  echo "- **Digest:** \`$digest\`"
  echo "- **Source repo:** $src"
  echo "- **Source revision:** \`$rev\`"
  echo "- **Source version label:** \`$ver\`"
  echo "- **Trivy:** $trivy_ver (DB $db_date)"
  echo "- **Generated:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [[ -n "$pushed" ]] && echo "- **Pushed:** \`$pushed\`"
  echo

  if [[ -s "$before" ]]; then
    echo "## Severity counts"
    echo
    if [[ -s "$after" ]]; then
      echo "| Severity | Before | After |"
      echo "|---|---|---|"
      for s in CRITICAL HIGH MEDIUM LOW UNKNOWN; do
        echo "| $s | $(counts "$before" "$s") | $(counts "$after" "$s") |"
      done
      echo "| **Total** | **$(total_of "$before")** | **$(total_of "$after")** |"
    else
      echo "| Severity | Before |"
      echo "|---|---|"
      for s in CRITICAL HIGH MEDIUM LOW UNKNOWN; do
        echo "| $s | $(counts "$before" "$s") |"
      done
      echo "| **Total** | **$(total_of "$before")** |"
    fi
    echo

    echo "## Fixable findings (had a FixedVersion)"
    echo
    jq -r '
      [.Results[]? | .Target as $t | .Vulnerabilities[]?
        | select(.FixedVersion != null and .FixedVersion != "")
        | {s:.Severity,id:.VulnerabilityID,p:.PkgName,iv:.InstalledVersion,fv:.FixedVersion,t:$t}]
      | sort_by(.s,.id)
      | if length==0 then "None."
        else "| Severity | CVE | Package | Installed | Fixed | Target |\n|---|---|---|---|---|---|",
             (.[] | "| \(.s) | \(.id) | \(.p) | \(.iv) | \(.fv) | \(.t) |")
        end' "$before"
    echo

    echo "## Unfixable findings (no fixed version published)"
    echo
    jq -r '
      [.Results[]? | .Target as $t | .Vulnerabilities[]?
        | select(.FixedVersion == null or .FixedVersion == "")
        | {s:.Severity,id:.VulnerabilityID,p:.PkgName,iv:.InstalledVersion,t:$t}]
      | sort_by(.s,.id)
      | if length==0 then "None."
        else "| Severity | CVE | Package | Installed | Target |\n|---|---|---|---|---|",
             (.[] | "| \(.s) | \(.id) | \(.p) | \(.iv) | \(.t) |")
        end' "$before"
    echo
  else
    echo "_No scan JSON found for this image._"
    echo
  fi

  echo "## Component end-of-life"
  echo
  if [[ -s "$eolbefore" ]]; then
    echo "Before rebuild (original image):"
    echo
    jq -r '
      ([.os_components[]?|select(.status=="eol")]|length) as $os
      | ([.dependencies[]?|select(.status=="eol")]|length) as $d
      | "- EOL base/runtime components: \($os); EOL dependencies: \($d)"' "$eolbefore"
    jq -r '[.dependencies[]?|select(.status=="eol")]|.[]|"- `\(.name)` \(.version) → \(.successor // (.repo // "?"))"' "$eolbefore" 2>/dev/null
    echo
    echo "After rebuild (final image):"
    echo
  fi
  if [[ -s "$eoljson" ]]; then
    echo "Policy: an upstream-archived dependency is \`eol\` (critical, even with zero CVEs);"
    echo "\`stale\` means no upstream activity within $(jq -r '.policy.stale_days // 1095' "$eoljson") days (warning)."
    echo
    echo "### Base OS / runtime (source: endoflife.date)"
    echo
    jq -r '
      if (.os_components|length)==0 then "None."
      else "| Status | Component | Installed | Cycle | EOL | Latest |\n|---|---|---|---|---|---|",
           (.os_components[] | "| \(.status) | \(.component) | \(.installed) | \(.cycle//"-") | \(if .eol==null then "-" else (.eol|tostring) end) | \(.latest//"-") |")
      end' "$eoljson"
    echo
    echo "### Dependencies (source: ecosyste.ms + curated registry)"
    echo
    jq -r '
      [.dependencies[]? | select(.status!="maintained")] as $d
      | if ($d|length)==0 then "All checked dependencies maintained."
        else "| Status | Ecosystem | Dependency | Installed | Successor / Repo |\n|---|---|---|---|---|",
             ($d[] | "| \(.status) | \(.ecosystem) | \(.name) | \(.version) | \(.successor // .repo // "-") |")
        end' "$eoljson"
    echo
  else
    echo "_No EOL check found for this image (run scripts/eol-check.sh)._"
    echo
  fi

  echo "## Notes"
  echo
  echo "- Scan/build platform: \`linux/amd64\`."
  echo "- \"Unfixable\" means trivy reports no \`FixedVersion\` for the installed package;"
  echo "  such CVEs cannot be cleared by an OS package upgrade or a targeted dependency bump."
  echo "  They typically need an upstream base-image or application release."
} > "$note"

echo "NOTE=$note"
