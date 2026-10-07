#!/usr/bin/env node
// Stage the distributable payload into dist/ so the published npm tarball
// carries it without depending on npm's handling of dot-directories
// (.agents, .opencode). Runs on `npm pack` / `npm publish` via "prepack".
"use strict";

const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
const skillSrc = path.join(root, ".agents", "skills", "clean-image");
const skillDst = path.join(root, "dist", "clean-image");
const cmdSrc = path.join(root, ".opencode", "command", "clean-image.md");
const cmdDst = path.join(root, "dist", "command", "clean-image.md");

if (!fs.existsSync(path.join(skillSrc, "SKILL.md"))) {
  console.error(`stage-skill: missing source skill at ${skillSrc}`);
  process.exit(1);
}
if (!fs.existsSync(cmdSrc)) {
  console.error(`stage-skill: missing source command at ${cmdSrc}`);
  process.exit(1);
}

fs.rmSync(skillDst, { recursive: true, force: true });
fs.mkdirSync(path.dirname(skillDst), { recursive: true });
fs.cpSync(skillSrc, skillDst, { recursive: true });

fs.rmSync(cmdDst, { force: true });
fs.mkdirSync(path.dirname(cmdDst), { recursive: true });
fs.cpSync(cmdSrc, cmdDst);

const count = (dir) =>
  fs.readdirSync(dir, { withFileTypes: true }).reduce(
    (n, e) => n + (e.isDirectory() ? count(path.join(dir, e.name)) : 1),
    0
  );

console.log(
  `stage-skill: staged ${count(skillDst)} skill files and the clean-image command -> dist/`
);
