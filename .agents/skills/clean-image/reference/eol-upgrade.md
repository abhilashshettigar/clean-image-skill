# Component EOL upgrade reference

Use when `scripts/eol-check.sh` exits `1` (EOL found): an EOL base OS/runtime, or
a dependency whose upstream is archived (`status: "eol"`). `stale` deps are a
warning, not a blocker — note them, don't force an upgrade unless asked.

The goal is a rebuilt `linux/amd64` image where `eol-check.sh` reports
`EOL_FOUND=false` and trivy reports zero CVEs, pushed under the usual
`<tag>-cvefixed-amd64` ref.

## 1. Base OS / runtime EOL

`patch-build.sh` (`FROM <image>` + `apk/apt upgrade`) can **never** move an image
off an EOL distro release — the version's package repos are frozen. Bump the
distro cycle instead:

- **Static binary (Go/Rust)** — "rebase" the binary onto a
  supported base. The app binary carries no distro coupling, so:

  ```dockerfile
  FROM <distro>:<latest-supported-cycle>   # e.g. alpine:3.24
  WORKDIR /
  COPY --from=<original-image> /path/to/app-prod /app-prod
  # copy any non-glibc/musl runtime config the entrypoint needs
  ENTRYPOINT ["/app-prod"]
  ```

  `eol-check.sh` prints the `latest` cycle and patch for the OS (from
  endoflife.date). Build with `docker buildx build --platform linux/amd64 --load`.

- **Dynamically linked app** — prefer the source rebuild path in
  `source-rebuild.md`, bumping the base image tag in the project's own
  Dockerfile to the latest supported cycle, then rebuild the app against it.

- **EOL language toolchain** (e.g. an old Go `stdlib`): rebuild with a newer
  toolchain base (`golang:<supported>`) and rescan. Many Go projects pin the Go
  version in the image's build stage, so bump it there and rebuild.

## 2. Dependency EOL (archived upstream)

Replace the EOL dependency with its maintained successor and rebuild from
source. `eol-check.sh` reports the successor when it is in the curated registry
(`reference/eol-deps.tsv`); otherwise use the archived repo's README to find it.

### Go

If the project vendors its dependencies (`vendor/`), both the import path and the
vendor tree must change.

**Direct replacement (works when the successor keeps the package API):**

```bash
cd build/<slug>/src
# 1. add the successor at latest
go get gopkg.in/yaml.v3@latest
# 2. rewrite import paths across the tree
grep -rl 'gopkg.in/yaml.v2' --include='*.go' . | xargs \
  sed -i '' 's#gopkg.in/yaml.v2#gopkg.in/yaml.v3#g'
# 3. drop the old module, tidy, vendor
go mod tidy && go mod vendor
```

**Transitive dependency** (the EOL module is not imported directly): find who
pulls it and bump that parent, or pin a `replace` when APIs are compatible:

```bash
go mod why -m gopkg.in/yaml.v2          # who needs it
go mod graph | grep yaml.v2             # the incoming edge
go mod edit -replace=gopkg.in/yaml.v2=gopkg.in/yaml.v3@v3.0.1
go mod tidy && go mod vendor
```

Notes:
- `yaml.v2` → `v3` is API-compatible for common use; the repo's own
  `yaml.v3` doc lists the differences (`UnmarshalStrict` semantics, etc.). Always
  compile to confirm.
- **v2-only APIs** (`UnmarshalStrict`, `MapSlice`) do not exist in v3. When the
  codebase relies on them, add a tiny internal shim whose *package name is
  `yaml`* and which wraps `go.yaml.in/yaml/v3` (re-export `Marshal`/`Unmarshal`/
  `Marshaler`/`Unmarshaler`, add `UnmarshalStrict` via `Decoder.KnownFields`),
  then repoint the import path only. Call sites stay untouched and the SBOM lists
  only `go.yaml.in/yaml/v3`.
- Go embeds the module list in the binary build info; verify the swap really
  landed with `go version -m <binary> | grep yaml` (should show only the
  successor, never `gopkg.in/yaml.v2`).
- If a `replace` to a *different module path* is used, Go compiles the successor
  code under the old import path; that removes the archived module from the SBOM,
  but prefer rewriting imports where practical so the SBOM names the real module.
- Re-check that the archived module is gone from the built binary:
  `trivy image --list-all-pkgs ...` must no longer list it (gobinary inventory).

### Other ecosystems

| Ecosystem | Replace | Verify |
|---|---|---|
| npm | `npm install <successor>@latest`, update imports | `npm ls <old>` empty |
| PyPI | pin `successor==<ver>`, update imports | `pip show <old>` absent |
| Maven | change `<groupId>/<artifactId>` + version in `pom.xml` | `mvn dependency:tree` |
| Cargo | `cargo add <successor>`, `cargo update` | `cargo tree` |

Same rule everywhere: **targeted** replacement of the EOL component only, not a
blanket upgrade.

## 3. Rebuild, rescan, iterate

```bash
docker buildx build --platform linux/amd64 --load -t "clean/<slug>:local" build/<slug>/src
rm -f reports/clean/<slug>.eol.json      # force a fresh EOL verdict
CLEAN_IMAGE_ROOT=$PWD scripts/eol-check.sh "<image>"   # -> EOL_FOUND=false
CLEAN_IMAGE_ROOT=$PWD scripts/scan.sh "<image>"        # (re-scan the rebuilt local image)
trivy image --scanners vuln --platform linux/amd64 --skip-db-update --no-progress \
  --format json -o reports/clean/<slug>.after.json "clean/<slug>:local"
```

Iterate until `eol-check.sh` reports `EOL_FOUND=false` and the trivy total is `0`,
or until the remainder is genuinely unfixable (record it in the note).

## 4. Push and report

```bash
scripts/push.sh "<image>" "<tag>"
scripts/report.sh "<image>" PUSHED-CLEAN "<pushed-ref>"
```

The note's "Component end-of-life" section records the before/after EOL status;
the verdict table covers CVEs.
