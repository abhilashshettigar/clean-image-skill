# clean-image

An [Agent Skill](https://opencode.ai/docs/skills) that turns a single Docker/OCI
image reference (`repo:tag`) into a CVE-clean, EOL-free image.

Give an agent the image and it will:

1. **Scan** the image with [Trivy](https://trivy.dev) at `linux/amd64` across all
   severities.
2. **Check end-of-life** for the base OS/runtime and every inventoried
   dependency. An upstream-archived dependency (e.g. `gopkg.in/yaml.v2`) counts as
   critical even with zero CVEs, because no fix will ever ship.
3. **Fix what can be fixed** — patch OS packages first; if that is not enough,
   rebuild from upstream source with targeted dependency bumps/replacements.
4. **Push** the clean result to a registry under a `-cvefixed-amd64` tag.
5. **Write a note** for every image, including anything that is genuinely
   unfixable.

If an image is already clean, it is reported `CLEAN-AS-IS` and nothing is rebuilt
or pushed.

## What it does not do

- It is not a runtime protector or a policy engine; it produces cleaner images.
- It does not invent an upstream source. If a repo cannot be found, the verdict is
  `NOT-PATCHABLE` and the reason is recorded.
- It never stores credentials. Registry credentials are read from environment
  variables only.

## Prerequisites

| Requirement | Why |
|---|---|
| `docker` with `buildx` | build and push images |
| `linux/amd64` emulation | every build/scan targets amd64 |
| `trivy` | vulnerability scanning |
| `jq` | parse scan JSON |
| `curl` | EOL data lookups (endoflife.date, ecosyste.ms) |
| `git` | clone upstream source for rebuilds |

Enable amd64 emulation once (needs Docker running):

```bash
docker run --privileged --rm tonistiigi/binfmt --install amd64
docker buildx inspect --bootstrap | grep -o 'linux/amd64'
```

### Environment variables

Export these before running the skill:

| Variable | Meaning |
|---|---|
| `REGISTRY` | Push registry host, e.g. `ghcr.io` |
| `TARGET_REPO` | Namespace/path prefix, e.g. `myorg/clean-images` |
| `REGISTRY_USER` | Registry username |
| `REGISTRY_PASSWORD` | Registry password/token |

Optional: set `CLEAN_IMAGE_ROOT` to choose where `build/` and `reports/` are
written (defaults to the current working directory).

## Install

The skill lives at `.agents/skills/clean-image/`, a portable location understood by
OpenCode, Claude Code, Cursor, and Codex. Clone the repo and copy (or symlink) the
folder into your agent's skills directory.

```bash
git clone https://github.com/abhilashshettigar/clean-image-skill
```

**OpenCode — global (recommended):**

```bash
mkdir -p ~/.config/opencode/skills
cp -R clean-image-skill/.agents/skills/clean-image ~/.config/opencode/skills/
```

**OpenCode — project only:**

```bash
mkdir -p .opencode/skills
cp -R clean-image-skill/.agents/skills/clean-image .opencode/skills/
```

**OpenCode — without copying**, point at the repo via `opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "skills": { "paths": [".agents/skills"] }
}
```

**Claude Code:**

```bash
mkdir -p ~/.claude/skills
cp -R clean-image-skill/.agents/skills/clean-image ~/.claude/skills/
```

**Cursor / Codex:** keep `.agents/skills/clean-image/` in your project (or your
agent's global skills directory).

Restart your agent after installing; skills are loaded at startup.

## Usage

Ask your agent with a single image reference:

```
Clean this image: docker.io/library/nginx:1.27
```

The agent scans first and decides:

- **Zero CVEs, no EOL components** → `CLEAN-AS-IS`. Use the original tag.
- **OS package CVEs** → patches the image and rescans.
- **App/dependency CVEs, distroless, or EOL components** → rebuilds from upstream
  source with targeted fixes, then rescans.
- **Rebuilt clean** → pushes `$REGISTRY/$TARGET_REPO/<image-name>:<tag>-cvefixed-amd64`
  and reports `PUSHED-CLEAN` (or `PUSHED-WITH-NOTES` if residual unfixable CVEs
  remain).

Every run writes `reports/clean/<slug>.md`. See
[`examples/sample-note.md`](examples/sample-note.md) for the shape of that note.

### Verdicts

| Verdict | Meaning | Pushed? |
|---|---|---|
| `CLEAN-AS-IS` | Zero CVEs and no EOL components already | no |
| `PUSHED-CLEAN` | Rebuilt and zero CVEs | yes |
| `PUSHED-WITH-NOTES` | Rebuilt with all available fixes; residual unfixable CVEs noted | yes |
| `NOT-PATCHABLE` | No shell/pkg manager and no usable source; note only | no |

## Supported platforms

Skills are an open format; this repo uses the portable `.agents/skills/` layout.

| Agent | Discovery path | Status |
|---|---|---|
| OpenCode | `.agents/skills/`, `.opencode/skills/`, `~/.config/opencode/skills/` | Primary, verified |
| Claude Code | `.agents/skills/`, `.claude/skills/`, `~/.claude/skills/` | Portable layout |
| Cursor | `.agents/skills/`, `.cursor/skills/` | Portable layout |
| Codex | `.agents/skills/` | Portable layout |

Frontmatter deliberately uses only `name` and `description` for maximum
cross-agent compatibility. The skill is verified on OpenCode; other agents read
the same files but have not been individually exercised.

## Repository layout

```
.
├── README.md
├── LICENSE
├── examples/sample-note.md
└── .agents/skills/clean-image/
    ├── SKILL.md
    ├── scripts/       # scan, patch-build, eol-check, push, report
    └── reference/     # source-rebuild, eol-upgrade, eol-deps registry
```

## License

MIT — see [LICENSE](LICENSE).
