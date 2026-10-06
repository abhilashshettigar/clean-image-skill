#!/usr/bin/env bash
# Patch an image in place: FROM <image>, upgrade the OS packages, pin every
# fixable package to its trivy FixedVersion, rebuild for linux/amd64, rescan.
# usage: patch-build.sh <image:tag>
# exit: 0 ok | 2 usage/precondition | 3 not patchable (no shell/pkg manager) | 1 build/scan failed
set -uo pipefail

ROOT="${CLEAN_IMAGE_ROOT:-$PWD}"
OUT="$ROOT/reports/clean"
BUILD="$ROOT/build"
mkdir -p "$OUT" "$BUILD"

image="${1:-}"
if [[ -z "$image" ]]; then
  echo "usage: patch-build.sh <image:tag>" >&2
  exit 2
fi

for t in docker trivy jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }
done

slug=$(echo "$image" | sed 's#[/:]#_#g')
before="$OUT/$slug.before.json"
after="$OUT/$slug.after.json"
bdir="$BUILD/$slug"
local_ref="clean/$slug:local"

if [[ ! -s "$before" ]]; then
  echo "no scan found; run scan.sh \"$image\" first" >&2
  exit 2
fi

os_pkgs=$(jq '[.Results[]?|select(.Class=="os-pkgs")]|length' "$before")
if [[ "$os_pkgs" -eq 0 ]]; then
  echo "NOT_PATCHABLE: no OS packages (distroless/scratch) -> source rebuild" >&2
  exit 3
fi

# Confirm the image has a shell + a known package manager (also warms the amd64 pull).
mgr_path=$(docker run --rm --platform linux/amd64 --entrypoint sh "$image" -c \
  'for c in apk apt-get dnf yum microdnf; do command -v "$c" && break; done' 2>/dev/null) || true
mgr=$(basename "${mgr_path:-}" 2>/dev/null)
case "$mgr" in
  apk|apt-get|dnf|yum|microdnf) ;;
  *) echo "NOT_PATCHABLE: no shell/package manager found -> source rebuild" >&2; exit 3 ;;
esac

orig_user=$(jq -r '.Metadata.ImageConfig.config.User // ""' "$before")

mkdir -p "$bdir"
# Unique package -> fixed version list (fixable findings only).
jq -r '[.Results[]?|.Vulnerabilities[]?|select(.FixedVersion != null and .FixedVersion != "")]|unique_by(.PkgName)|.[]|"\(.PkgName)\t\(.FixedVersion)"' \
  "$before" > "$bdir/pins.tsv"
pins_n=$(grep -c . "$bdir/pins.tsv" 2>/dev/null || echo 0)

case "$mgr" in
  apk)
    pkg_upgrade='apk update && apk upgrade --no-cache'
    pkg_pin='while IFS=$'"'"'\t'"'"' read -r p v; do [ -z "$p" ] && continue; apk add --no-cache "$p>=$v" || true; done < /tmp/clean-image-pins.tsv'
    ;;
  apt-get)
    pkg_upgrade='apt-get update && apt-get -y upgrade'
    pkg_pin='while IFS=$'"'"'\t'"'"' read -r p v; do [ -z "$p" ] && continue; apt-get -y --no-install-recommends install "$p=$v" || true; done < /tmp/clean-image-pins.tsv'
    ;;
  dnf|yum|microdnf)
    pkg_upgrade="$mgr -y upgrade || $mgr -y update"
    pkg_pin="while IFS=\$'\\t' read -r p v; do [ -z \"\$p\" ] && continue; $mgr -y install \"\$p-\$v\" || true; done < /tmp/clean-image-pins.tsv"
    ;;
esac

{
  echo "FROM $image"
  echo "USER root"
  echo "COPY pins.tsv /tmp/clean-image-pins.tsv"
  echo "RUN set -eux; $pkg_upgrade"
  echo "RUN set -eux; $pkg_pin"
  if [[ "$mgr" == "apt-get" ]]; then
    echo "RUN rm -rf /var/lib/apt/lists/*"
  elif [[ "$mgr" != "apk" ]]; then
    echo "RUN $mgr clean all || true"
  fi
  [[ -n "$orig_user" ]] && echo "USER $orig_user"
} > "$bdir/Dockerfile"

echo "==> patch recipe ($mgr, $pins_n fixable packages pinned)"
cat "$bdir/Dockerfile"
echo "==> building $local_ref (linux/amd64)"
if ! docker buildx build --platform linux/amd64 --load -t "$local_ref" "$bdir"; then
  echo "BUILD_FAILED: $image" >&2
  exit 1
fi

echo "==> rescanning $local_ref"
if ! trivy image --scanners vuln --platform linux/amd64 \
      --skip-db-update --no-progress --timeout 20m --list-all-pkgs \
      --format json -o "$after" "$local_ref"; then
  echo "RESCAN_FAILED: $local_ref" >&2
  exit 1
fi

count() { jq --arg s "$1" '[.Results[]?|.Vulnerabilities[]?|select(.Severity==$s)]|length' "$after"; }
total=$(jq '[.Results[]?|.Vulnerabilities[]?]|length' "$after")
echo "AFTER_TOTAL=$total CRITICAL=$(count CRITICAL) HIGH=$(count HIGH) MEDIUM=$(count MEDIUM) LOW=$(count LOW) UNKNOWN=$(count UNKNOWN)"
echo "AFTER=$after"
exit 0
