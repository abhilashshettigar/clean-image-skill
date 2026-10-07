---
description: Clean one Docker/OCI image (repo:tag) of CVEs and EOL components, rebuild it, and push the fixed image
agent: build
---

Use the `clean-image` skill. Load it, then process this single image reference:

$ARGUMENTS

Requirements:
- Exactly one image per invocation. If no image reference was provided, ask for
  one and stop.
- Follow the skill's procedure end to end: preflight, trivy scan at
  `linux/amd64`, component EOL check, patch/rebuild only when needed, push, then
  write the per-image note.
- Never claim success without a post-build rescan.
