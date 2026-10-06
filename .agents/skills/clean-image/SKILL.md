---
name: clean-image
description: Use when the user gives a Docker/OCI image reference (repo:tag) and wants it scanned for CVEs and made clean. Triggers on "scan this image", "clean image", "zero CVEs", "trivy image", "rebuild image with fixes", "CVE free image", "component end of life", "EOL/unmaintained/archived dependency". Scans with trivy at linux/amd64, checks base OS/runtime and every inventoried dependency for end-of-life (an archived dependency such as gopkg.in/yaml.v2 is treated as critical even with zero CVEs), rebuilds locally when CVEs or EOL components exist (OS package patch first, then upstream source rebuild with targeted dependency bumps/replacements), pushes clean results to a registry, and writes a per-image markdown note for anything unfixable.
---

# Clean Image

Turn a single `repo:tag` into a CVE-clean image. Scan first, patch/build only when
needed, always push the best artifact, and always write a note.

## Rules

- **One image per invocation.** The user pastes a single reference, e.g.
  `docker.io/library/nginx:1.27`.
- **Everything is built for `linux/amd64`**, even on this arm64 host. Every
  `trivy image` and every `docker buildx build` must carry `--platform linux/amd64`.
- **Clean means zero vulnerabilities across ALL severities** (CRITICAL, HIGH,
  MEDIUM, LOW, UNKNOWN). There is no severity threshold.
- **EOL components count too.** Check the base OS/runtime and every inventoried
  dependency for end-of-life. An upstream-archived dependency (e.g.
  `gopkg.in/yaml.v2`) is treated as critical **even with zero CVEs**, because no
  fix will ever ship. `stale` (no upstream activity) is a warning to record, not
  a blocker. Neither can be cleared by an OS package patch: an EOL distro cycle
  is frozen and an archived Go module is compiled into the binary.
- **Never store credentials in files.** Read them from env vars only.
- **Do not claim success without a rescan.** The post-build trivy JSON is the
  only source of truth for "clean".

## Required env vars

Export before running (the skill reads them, never writes them):

| Var | Meaning |
|---|---|
| `REGISTRY` | Push registry host, e.g. `ghcr.io` |
| `TARGET_REPO` | Target namespace/path prefix, e.g. `myorg/clean-images` |
| `REGISTRY_USER` | Registry username |
| `REGISTRY_PASSWORD` | Registry password/token |

If any are missing, stop and ask the user for them.

**The pushed ref always ends in the source image name.** The final reference is
`$REGISTRY/$TARGET_REPO/<image-name>:<tag>-cvefixed-amd64`, where `<image-name>` is
the last path segment of the original reference (e.g. `myapp`). So
`TARGET_REPO` is only the namespace/path *prefix*, never the final repo name.

Registry constraint for `TARGET_REPO`:

- **Flat registries (Docker Hub `docker.io`)** allow only `namespace/repo`, so
  `TARGET_REPO` must be just the namespace (e.g. `<your-namespace>`). The image
  name becomes the repo, giving e.g.
  `docker.io/<your-namespace>/nginx:1.27-cvefixed-amd64`.
  A `TARGET_REPO` that already contains a repo name (e.g. `<your-namespace>/public`)
  would produce an invalid nested ref like `<your-namespace>/public/nginx` — do not
  use it.
- **Nested-path registries (e.g. `ghcr.io`)** allow a multi-segment prefix such as
  `myorg/clean-images`, giving `ghcr.io/myorg/clean-images/nginx:<tag>-cvefixed-amd64`.

## Directory conventions

All paths are relative to the current working directory (the project root, i.e.
the dir containing this skill's `.opencode/`). Override with `CLEAN_IMAGE_ROOT`.

- `reports/clean/<slug>.before.json` / `.after.json` — trivy JSON
- `reports/clean/<slug>.md` — per-image note (the required deliverable)
- `reports/clean/<slug>.labels.json` — OCI labels + OS family
- `reports/clean/<slug>.eol.json` — component EOL report (OS/runtime + dependencies)
- `build/<slug>/Dockerfile` — generated patch recipe

`<slug>` = image with `/` and `:` replaced by `_` (same convention as `scan.sh`).

## Procedure

### 0. Preflight

```bash
command -v docker trivy jq git
docker buildx inspect | grep -q 'linux/amd64' || echo "amd64 emulation MISSING"
```

If `linux/amd64` is missing from the builder, run once (needs Docker running):

```bash
docker run --privileged --rm tonistiigi/binfmt --install amd64
docker buildx inspect --bootstrap | grep -o 'linux/amd64'
```

Do not proceed to any build until amd64 is listed.

### 1. Scan (remote, no pull needed)

```bash
scripts/scan.sh "<image>"
```

This writes `<slug>.before.json` + `<slug>.labels.json` and prints severity
counts. It also prints `TOTAL=<n>`. Read the JSON for details:

```bash
jq -r '[.Results[]?|.Vulnerabilities[]?]|length' reports/clean/<slug>.before.json
jq -r '.Metadata.ImageConfig.config.Labels' reports/clean/<slug>.labels.json
```

Capture the image **digest** (`.Metadata.RepoDigests[0]`) — record it in the note
so "use this tag" is pinned to a digest.

### 1b. Component EOL check

```bash
scripts/eol-check.sh "<image>"
```

Reads the scan JSON and checks two scopes: the base OS/runtime (source
`endoflife.date`) and **every inventoried language dependency** (source
`ecosyste.ms` + the curated `reference/eol-deps.tsv`). Writes `<slug>.eol.json`
and prints `EOL_FOUND=`. Exit `1` = EOL found, `0` = clean or stale-only, `3` =
data source unreachable (skip, note it).

- `eol_found` (an archived dependency, or an EOL OS/runtime) — **must be fixed**;
  follow `reference/eol-upgrade.md` and rebuild. `patch-build.sh` cannot fix it.
- `stale` dependencies — warning only; record them in the note unless the user
  asks to upgrade.
- After any rebuild, `rm` `<slug>.eol.json` and re-run this step to prove
  `EOL_FOUND=false`.

### 2. Verdict: clean as-is

If `TOTAL == 0` **and** `EOL_FOUND=false`:

1. Run `scripts/report.sh "<image>" CLEAN-AS-IS`
2. Tell the user the original tag is clean and safe to use. **Do not rebuild or push.**

If `TOTAL == 0` but `EOL_FOUND=true`, the image is CVE-clean but must still be
rebuilt: go to step 4 and follow `reference/eol-upgrade.md` to replace the EOL
component, then push.

### 3. Patch build (OS packages)

If `TOTAL > 0` and the image has OS packages (trivy `Results[].Class == "os-pkgs"`):

```bash
scripts/patch-build.sh "<image>"
```

This generates `build/<slug>/Dockerfile` (`FROM <image>` + full package upgrade +
targeted pins for every fixable finding), builds `linux/amd64` as
`clean/<slug>:local`, and rescans to `<slug>.after.json`. It exits:

- `0` — build ok; read `after.json` counts
- `3` — not patchable (distroless/scratch, no shell/pkg manager) → go to step 4
- other — build failed; capture the error into the note and go to step 4

If `after` total is `0` → push (step 5) and report `PUSHED-CLEAN`.

### 4. Source rebuild (app/dependency CVEs, EOL components, distroless, or patch left CVEs)

Follow `reference/source-rebuild.md`. In short:

0. If the trigger is an EOL OS/runtime or an archived dependency (step 1b), start
   from `reference/eol-upgrade.md` — replace the EOL component with its
   maintained successor — then resume the CVE-targeted bumps below.

1. Get repo + exact ref from OCI labels in `<slug>.labels.json`
   (`org.opencontainers.image.source`, `...revision`, `...version`). If absent,
   web-search `"<image-name> github"` to find the upstream repo.
2. `git clone <repo> && git checkout <revision-or-tag>`.
3. Detect the language/build system from repo files.
4. **Targeted only**: for each trivy finding that has a `FixedVersion`, bump just
   that dependency to the fixed version (`go get m@v`, `npm i p@v`,
   `pkg==ver`, pom/gradle version bump). Do not blanket-upgrade.
5. Rebuild with the repo's own Dockerfile, bumping the base image to a patched
   equivalent if the base itself is the problem.
6. Build `linux/amd64` and rescan. Iterate until zero or no further fixes exist.

If the repo cannot be found/cloned or nothing more is fixable → `NOT-PATCHABLE`
(or `PUSHED-WITH-NOTES` if a partial build succeeded).

### 5. Push

Only for images that were rebuilt locally:

```bash
scripts/push.sh "<image>" "<tag>"
```

Tags the local build as
`$REGISTRY/$TARGET_REPO/<image-name>:<tag>-cvefixed-amd64`, logs in with the env
credentials, and pushes. `<image-name>` is the last path segment of the original
reference (e.g. `nginx`), so the source image name is **always** part of
the pushed ref (see the registry constraint under "Required env vars").

If the env credentials are unavailable but Docker is already logged in to the
target registry (e.g. a `credsStore` entry in `~/.docker/config.json`), skip the
env login and push directly with the same ref:

```bash
docker tag "clean/<slug>:local" "$REGISTRY/$TARGET_REPO/<image-name>:<tag>-cvefixed-amd64"
docker push "$REGISTRY/$TARGET_REPO/<image-name>:<tag>-cvefixed-amd64"
```

Always rescan the pushed ref (`trivy image --image-src remote ...`) to confirm it
is still clean before reporting.

### 6. Report (always)

```bash
scripts/report.sh "<image>" "<VERDICT>" "<pushed-ref-or-empty>"
```

Writes `reports/clean/<slug>.md`. The note must contain: verdict; original ref +
digest; trivy version/DB date; before/after severity counts; component-EOL status
(OS/runtime + dependencies, before/after, with successors for replaced deps);
every fixed CVE (ID, package, from→to); every **unfixable** CVE (ID, package,
installed version, severity, reason — normally "no fixed version published");
source repo + ref used; build method; and the final pushed ref.

Then summarize to the user in a few lines: verdict, before→after counts, pushed
ref, any unfixable CVEs, and any EOL/stale components.

## Verdicts

| Verdict | Meaning | Pushed? |
|---|---|---|
| `CLEAN-AS-IS` | Zero CVEs and no EOL components already; use the original tag | no |
| `PUSHED-CLEAN` | Rebuilt and zero CVEs | yes |
| `PUSHED-WITH-NOTES` | Rebuilt with all available fixes; residual unfixable CVEs noted | yes |
| `NOT-PATCHABLE` | No shell/pkg manager and no usable source; note only | no |

## Reference

- `reference/source-rebuild.md` — repo discovery and per-language targeted-bump recipes.
- `reference/eol-upgrade.md` — resolving an EOL base OS/runtime and replacing archived dependencies with maintained successors.
- `reference/eol-deps.tsv` — curated EOL dependency registry (with successors) used by `scripts/eol-check.sh`.
