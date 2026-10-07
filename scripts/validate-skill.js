#!/usr/bin/env node
// Validate Agent Skill frontmatter so a malformed SKILL.md never ships.
"use strict";

const fs = require("fs");
const path = require("path");

const skillsRoot = path.join(__dirname, "..", ".agents", "skills");
const NAME_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;

function skillFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const f = path.join(dir, entry.name, "SKILL.md");
    if (fs.existsSync(f)) out.push(f);
  }
  return out;
}

function parseFrontmatter(text) {
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/);
  if (!m) return null;
  const fm = {};
  for (const line of m[1].split(/\r?\n/)) {
    const kv = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (kv) fm[kv[1]] = kv[2].trim();
  }
  return fm;
}

let failed = false;
const files = skillFiles(skillsRoot);

if (files.length === 0) {
  console.error(`no SKILL.md found under ${skillsRoot}`);
  process.exit(1);
}

for (const file of files) {
  const dirName = path.basename(path.dirname(file));
  const fm = parseFrontmatter(fs.readFileSync(file, "utf8"));
  const errors = [];

  if (!fm) {
    errors.push("missing YAML frontmatter");
  } else {
    if (!fm.name) errors.push("missing `name`");
    else if (!NAME_RE.test(fm.name)) errors.push(`invalid name "${fm.name}" (lowercase-hyphen)`);
    else if (fm.name !== dirName) errors.push(`name "${fm.name}" != directory "${dirName}"`);
    if (!fm.description) errors.push("missing `description`");
    else if (fm.description.length > 1024) errors.push(`description too long (${fm.description.length} > 1024)`);
    const extra = Object.keys(fm).filter((k) => !["name", "description", "license", "compatibility", "metadata"].includes(k));
    if (extra.length) errors.push(`unknown frontmatter field(s): ${extra.join(", ")}`);
  }

  if (errors.length) {
    failed = true;
    console.error(`FAIL ${path.relative(process.cwd(), file)}`);
    for (const e of errors) console.error(`  - ${e}`);
  } else {
    console.log(`ok   ${path.relative(process.cwd(), file)} (name=${fm.name}, description=${fm.description.length} chars)`);
  }
}

process.exit(failed ? 1 : 0);
