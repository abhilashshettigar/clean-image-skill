# Clean-image note: `docker.io/library/nginx:1.27`

> Illustrative example. Values are sanitized and do not correspond to a real
> scan. The real note is written by `scripts/report.sh` to
> `reports/clean/<slug>.md`.

- **Verdict:** `PUSHED-CLEAN`
- **Original ref:** `docker.io/library/nginx:1.27`
- **Digest:** `sha256:0000000000000000000000000000000000000000000000000000000000000000`
- **Source repo:** https://github.com/nginx/nginx
- **Source revision:** `abcdef1234567890abcdef1234567890abcdef12`
- **Source version label:** `1.27`
- **Trivy:** 0.XX.X (DB 2026-01-01T00:00:00Z)
- **Generated:** 2026-01-01T00:00:00Z
- **Pushed:** `ghcr.io/myorg/clean-images/nginx:1.27-cvefixed-amd64`

## Severity counts

| Severity | Before | After |
|---|---|---|
| CRITICAL | 1 | 0 |
| HIGH | 3 | 0 |
| MEDIUM | 5 | 0 |
| LOW | 4 | 0 |
| UNKNOWN | 0 | 0 |
| **Total** | **13** | **0** |

## Fixable findings (had a FixedVersion)

| Severity | CVE | Package | Installed | Fixed | Target |
|---|---|---|---|---|---|
| CRITICAL | CVE-2024-00001 | libssl3 | 3.0.11-1~deb12u2 | 3.0.11-1~deb12u3 | debian:12 (debian) |
| HIGH | CVE-2024-00002 | zlib1g | 1:1.2.13.dfsg-1 | 1:1.2.13.dfsg-1+deb12u1 | debian:12 (debian) |

## Unfixable findings (no fixed version published)

| Severity | CVE | Package | Installed | Target |
|---|---|---|---|---|
| LOW | CVE-2023-00003 | libfoo | 1.2.3 | debian:12 (debian) |

## Component end-of-life

Before rebuild (original image):

- EOL base/runtime components: 0; EOL dependencies: 1
- `gopkg.in/yaml.v2` v2.4.0 → `gopkg.in/yaml.v3` (or `go.yaml.in/yaml/v3`)

After rebuild (final image):

Policy: an upstream-archived dependency is `eol` (critical, even with zero CVEs);
`stale` means no upstream activity within 1095 days (warning).

### Base OS / runtime (source: endoflife.date)

| Status | Component | Installed | Cycle | EOL | Latest |
|---|---|---|---|---|---|
| supported | debian | 12.6 | 12 | 2026-06-30 | 12.7 |

### Dependencies (source: ecosyste.ms + curated registry)

| Status | Ecosystem | Dependency | Installed | Successor / Repo |
|---|---|---|---|---|
| eol | go | gopkg.in/yaml.v2 | v2.4.0 | gopkg.in/yaml.v3 (or go.yaml.in/yaml/v3) |

## Notes

- Scan/build platform: `linux/amd64`.
- "Unfixable" means trivy reports no `FixedVersion` for the installed package;
  such CVEs cannot be cleared by an OS package upgrade or a targeted dependency bump.
  They typically need an upstream base-image or application release.
- After the rebuild, both the CVE total and `EOL_FOUND` were re-checked: zero CVEs,
  no EOL components.
