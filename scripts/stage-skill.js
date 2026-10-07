#!/usr/bin/env node
// Stage the skill payload into dist/clean-image so the published npm tarball
// carries it without depending on npm's handling of the .agents dot-directory.
// Runs automatically on `npm pack` / `npm publish` via the "prepack" script.
"use strict";

const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
const src = path.join(root, ".agents", "skills", "clean-image");
const dst = path.join(root, "dist", "clean-image");

if (!fs.existsSync(path.join(src, "SKILL.md"))) {
  console.error(`stage-skill: missing source skill at ${src}`);
  process.exit(1);
}

fs.rmSync(dst, { recursive: true, force: true });
fs.mkdirSync(path.dirname(dst), { recursive: true });
fs.cpSync(src, dst, { recursive: true });

const count = (dir) =>
  fs.readdirSync(dir, { withFileTypes: true }).reduce((n, e) => {
    return n + (e.isDirectory() ? count(path.join(dir, e.name)) : 1);
  }, 0);

console.log(`stage-skill: staged ${count(dst)} files -> ${path.relative(root, dst)}`);
