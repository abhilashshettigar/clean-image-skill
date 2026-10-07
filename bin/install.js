#!/usr/bin/env node
// clean-image-skill installer: copy the bundled clean-image Agent Skill (and,
// where supported, the /clean-image slash command) into coding agents' config
// directories. Zero runtime dependencies.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

const SKILL_NAME = "clean-image";
const COMMAND_FILE = "clean-image.md";
const pkg = require(path.join(__dirname, "..", "package.json"));

// Per-agent destinations: [global (under $HOME), project (under cwd)].
// `commands` is omitted for agents with no slash-command support.
const AGENTS = {
  opencode: {
    skills: ["~/.config/opencode/skills", ".opencode/skills"],
    commands: ["~/.config/opencode/command", ".opencode/command"],
  },
  claude: {
    skills: ["~/.claude/skills", ".claude/skills"],
    commands: ["~/.claude/commands", ".claude/commands"],
  },
  cursor: { skills: ["~/.cursor/skills", ".cursor/skills"] },
  codex: { skills: ["~/.codex/skills", ".codex/skills"] },
  agents: { skills: ["~/.agents/skills", ".agents/skills"] },
};

const HELP = `clean-image-skill v${pkg.version}

Install the clean-image Agent Skill (and the /clean-image command for OpenCode
and Claude Code) into your coding agent.

Usage:
  npx @abhilash1995/clean-image-skill [options]

Options:
  -a, --agent <name>   Target agent(s): opencode (default), claude, cursor,
                       codex, agents, or all. Repeatable / comma-separated.
  -p, --project        Install into the current project instead of globally.
  -g, --global         Install to the user directory (default).
      --force          Overwrite an existing installation.
      --remove         Uninstall the skill/command from the targeted location(s).
      --dry-run        Print the actions without changing anything.
  -l, --list           Alias for --dry-run.
  -y, --yes            Skip confirmation prompts (non-interactive).
  -h, --help           Show this help.
  -v, --version        Show the version.

Examples:
  npx @abhilash1995/clean-image-skill
  npx @abhilash1995/clean-image-skill --project -a opencode
  npx @abhilash1995/clean-image-skill -a opencode,claude -g --force
  npx @abhilash1995/clean-image-skill --remove -a all
`;

function fail(msg) {
  console.error(`clean-image-skill: ${msg}`);
  process.exit(1);
}

function parseArgs(argv) {
  const opts = { agents: [], scope: "global", force: false, remove: false, dryRun: false };

  const addAgents = (value) => {
    for (const raw of String(value).split(",")) {
      const name = raw.trim().toLowerCase();
      if (!name) continue;
      if (name !== "all" && !AGENTS[name]) {
        fail(`unknown agent "${name}". Known: ${Object.keys(AGENTS).join(", ")}, all`);
      }
      if (!opts.agents.includes(name)) opts.agents.push(name);
    }
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => {
      const v = argv[++i];
      if (v === undefined) fail(`option ${arg} requires a value`);
      return v;
    };
    switch (arg) {
      case "-a":
      case "--agent":
        addAgents(next());
        break;
      case "-p":
      case "--project":
        opts.scope = "project";
        break;
      case "-g":
      case "--global":
        opts.scope = "global";
        break;
      case "--force":
        opts.force = true;
        break;
      case "--remove":
        opts.remove = true;
        break;
      case "--dry-run":
      case "-l":
      case "--list":
        opts.dryRun = true;
        break;
      case "-y":
      case "--yes":
        break;
      case "-h":
      case "--help":
        process.stdout.write(HELP);
        process.exit(0);
        break;
      case "-v":
      case "--version":
        process.stdout.write(`${pkg.version}\n`);
        process.exit(0);
        break;
      default:
        if (arg.startsWith("-")) fail(`unknown option "${arg}" (try --help)`);
        fail(`unexpected argument "${arg}" (try --help)`);
    }
  }

  if (opts.agents.length === 0) opts.agents = ["opencode"];
  if (opts.agents.includes("all")) opts.agents = Object.keys(AGENTS);
  return opts;
}

// Locate bundled payloads: dist/ in the published package, falling back to the
// source tree when running from a checkout.
function resolvePayloads() {
  const pkgRoot = path.join(__dirname, "..");
  const firstExisting = (...candidates) => candidates.find((p) => fs.existsSync(p));
  const skill = firstExisting(
    path.join(pkgRoot, "dist", SKILL_NAME),
    path.join(pkgRoot, ".agents", "skills", SKILL_NAME)
  );
  if (!skill || !fs.existsSync(path.join(skill, "SKILL.md"))) {
    fail("bundled skill payload not found (run `npm run stage`)");
  }
  const command = firstExisting(
    path.join(pkgRoot, "dist", "command", COMMAND_FILE),
    path.join(pkgRoot, ".opencode", "command", COMMAND_FILE)
  );
  return { skill, command };
}

function baseDir(scope, rel) {
  return scope === "global"
    ? path.join(os.homedir(), rel.replace(/^~[/\\]/, ""))
    : path.join(process.cwd(), rel);
}

function installOne({ src, dest, label, force, dryRun }) {
  const exists = fs.existsSync(dest);
  if (exists && !force) {
    console.log(`skip   ${label}: already installed — use --force to overwrite\n       ${dest}`);
    return false;
  }
  if (!dryRun) {
    if (exists) fs.rmSync(dest, { recursive: true, force: true });
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.cpSync(src, dest, { recursive: true });
  }
  console.log(`${dryRun ? "would install" : "installed"} ${dest}`);
  return true;
}

function removeOne({ dest, label, dryRun }) {
  if (!fs.existsSync(dest)) {
    console.log(`skip   ${label}: not installed`);
    return false;
  }
  if (!dryRun) fs.rmSync(dest, { recursive: true, force: true });
  console.log(`${dryRun ? "would remove" : "removed"} ${dest}`);
  return true;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const payload = resolvePayloads();
  let changed = 0;

  for (const agent of opts.agents) {
    const spec = AGENTS[agent];
    const skillDest = path.join(baseDir(opts.scope, spec.skills[opts.scope === "global" ? 0 : 1]), SKILL_NAME);
    const targets = [{ src: payload.skill, dest: skillDest, label: `${agent} skill` }];

    if (spec.commands && payload.command) {
      const cmdBase = baseDir(opts.scope, spec.commands[opts.scope === "global" ? 0 : 1]);
      targets.push({ src: payload.command, dest: path.join(cmdBase, COMMAND_FILE), label: `${agent} command` });
    }

    for (const t of targets) {
      const ok = opts.remove
        ? removeOne({ ...t, dryRun: opts.dryRun })
        : installOne({ ...t, force: opts.force, dryRun: opts.dryRun });
      if (ok) changed++;
    }
  }

  if (opts.dryRun) {
    console.log(`\ndry run: no changes made (${opts.remove ? "remove" : "install"} plan for ${opts.agents.join(", ")})`);
  } else if (!opts.remove && changed > 0) {
    console.log("\nRestart your agent, then use /clean-image <image> (OpenCode/Claude Code).");
  }
}

main();
