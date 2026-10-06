#!/usr/bin/env bash
# Remote trivy scan of a single image at linux/amd64, all severities.
# Writes reports/clean/<slug>.before.json + <slug>.labels.json and prints counts.
# usage: scan.sh <image:tag>
set -uo pipefail

ROOT="${CLEAN_IMAGE_ROOT:-$PWD}"
OUT="$ROOT/reports/clean"
mkdir -p "$OUT"

image="${1:-}"
if [[ -z "$image" ]]; then
  echo "usage: scan.sh <image:tag>" >&2
  exit 2
fi

for t in trivy jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }
done

slug=$(echo "$image" | sed 's#[/:]#_#g')
before="$OUT/$slug.before.json"
labels="$OUT/$slug.labels.json"

trivy image --download-db-only --no-progress >/dev/null 2>&1 || true

echo "==> scanning $image (linux/amd64, all severities)"
if ! trivy image --scanners vuln --image-src remote --platform linux/amd64 \
      --skip-db-update --no-progress --timeout 20m --list-all-pkgs \
      --format json -o "$before" "$image"; then
  echo "SCAN_FAILED: $image" >&2
  exit 1
fi

jq '{
      labels: (.Metadata.ImageConfig.config.Labels // {}),
      os: (.Metadata.OS // {}),
      repodigests: (.Metadata.RepoDigests // []),
      repotags: (.Metadata.RepoTags // []),
      user: (.Metadata.ImageConfig.config.User // ""),
      os_pkg_results: ([.Results[]? | select(.Class == "os-pkgs")] | length)
    }' "$before" > "$labels"

count() { jq --arg s "$1" '[.Results[]?|.Vulnerabilities[]?|select(.Severity==$s)]|length' "$before"; }
crit=$(count CRITICAL); high=$(count HIGH); med=$(count MEDIUM); low=$(count LOW); unk=$(count UNKNOWN)
total=$(jq '[.Results[]?|.Vulnerabilities[]?]|length' "$before")
digest=$(jq -r '.Metadata.RepoDigests[0] // "-"' "$before")

echo "TOTAL=$total CRITICAL=$crit HIGH=$high MEDIUM=$med LOW=$low UNKNOWN=$unk"
echo "DIGEST=$digest"
echo "LABELS=$labels"
echo "BEFORE=$before"
