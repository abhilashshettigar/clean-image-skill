# Source rebuild reference

Use when `patch-build.sh` exits `3` (distroless/scratch) or when a patch build
still leaves CVEs. Goal: rebuild the image from its upstream source with
**targeted** dependency bumps — only the packages trivy says are fixable — then
build for `linux/amd64` and rescan.

## 1. Find the source repo and ref

Read OCI labels from `reports/clean/<slug>.labels.json`:

```bash
jq -r '.labels | to_entries[] | "\(.key)=\(.value)"' reports/clean/<slug>.labels.json
```

Prefer, in order:

- `org.opencontainers.image.source` — repo URL
- `org.opencontainers.image.revision` — exact commit to check out
- `org.opencontainers.image.version` — fallback tag

If `source` is missing, search the web for the upstream project
(`"<image-name> github"`, or the label `org.opencontainers.image.title`), then
pick the tag matching the image tag. Record the repo + ref you used in the note.

```bash
git clone --depth 1 --branch "<tag-or-branch>" <repo> build/<slug>/src
# or, when a revision is given:
git clone <repo> build/<slug>/src && git -C build/<slug>/src checkout <revision>
```

## 2. Detect the build system

| File present | Language / tool | Targeted bump |
|---|---|---|
| `go.mod` | Go | `go get <module>@v<fixed>` then `go mod tidy` |
| `package.json` / `package-lock.json` | Node/npm | `npm install <pkg>@<fixed>` (commit lockfile) |
| `yarn.lock` | Node/yarn | `yarn add <pkg>@<fixed>` |
| `requirements.txt` / `pyproject.toml` | Python | pin `pkg==<fixed>` (pip/poetry) |
| `pom.xml` | Java/Maven | set the dependency `<version>` to `<fixed>` |
| `build.gradle` | Java/Gradle | bump dependency version to `<fixed>` |
| `Cargo.toml` | Rust | `cargo update -p <crate> --precise <fixed>` |

Get the exact list of targeted fixes from the trivy JSON:

```bash
jq -r '
  [.Results[]? | .Vulnerabilities[]?
   | select(.FixedVersion != null and .FixedVersion != "")]
  | unique_by(.PkgName)
  | .[] | "\(.PkgName)\t\(.FixedVersion)"' reports/clean/<slug>.before.json
```

Bump **only** those. Do not run blanket upgrades unless the targeted path cannot
reach zero and the user agrees.

## 3. Rebuild with the project's own Dockerfile

```bash
ls build/<slug>/src/Dockerfile* build/<slug>/src/**/Dockerfile* 2>/dev/null
```

- Use the repo's Dockerfile at the checked-out revision as the recipe.
- If the **base image** is the CVE source, bump its tag to a patched equivalent
  (same distro/version line, newer patch), or swap Alpine→distroless when the
  project already supports it.
- Build the project's own build steps (e.g. `make build`, `go build ./cmd/...`,
  `npm ci && npm run build`) so the dependency bumps are compiled in.

```bash
docker buildx build --platform linux/amd64 --load \
  -t "clean/<slug>:local" build/<slug>/src
```

## 4. Rescan and iterate

```bash
trivy image --scanners vuln --platform linux/amd64 \
  --skip-db-update --no-progress --timeout 20m \
  --format json -o reports/clean/<slug>.after.json "clean/<slug>:local"
jq '[.Results[]?|.Vulnerabilities[]?]|length' reports/clean/<slug>.after.json
```

Repeat targeted bumps until total is `0`, or until the remaining CVEs have no
`FixedVersion` (then stop — they are unfixable by this method).

## 5. Push and report

When a rebuilt image exists:

```bash
scripts/push.sh "<image>" "<tag>"
scripts/report.sh "<image>" PUSHED-CLEAN "<pushed-ref>"       # if after total == 0
scripts/report.sh "<image>" PUSHED-WITH-NOTES "<pushed-ref>" # if residual unfixable CVEs remain
```

If nothing could be fixed and no build succeeded:

```bash
scripts/report.sh "<image>" NOT-PATCHABLE
```

## Cautions

- Only bump versions trivy marks fixable; verify the app still builds.
- Keep the source `git checkout` at the image's own revision so behaviour is
  otherwise unchanged.
- If a Go module bump cascades (transitive conflicts), prefer the smallest
  version that clears the CVE, and note any upgrade you could not apply.
- If the repo is private or missing, stop and report `NOT-PATCHABLE` with the
  reason; do not invent a source.
