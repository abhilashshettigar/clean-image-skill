#!/usr/bin/env node
// clean-image-skill installer: copy the bundled clean-image Agent Skill into
// one or more coding agents' skills directories. Zero runtime dependencies.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

const SKILL_NAME = "clean-image";
const pkg = require(path.join(__dirname, "..", "package.json"));

// Agent skill directories: [global (under $HOME), project (under cwd)].
const AGENTS = {
  opencode: ["~/.config/opencode/skills", ".opencode/skills"],
  claude: ["~/.claude/skills", ".claude/skills"],
  cursor: ["~/.cursor/skills", ".cursor/skills"],
  codex: ["~/.codex/skills", ".codex/skills"],
  agents: ["~/.agents/skills", ".agents/skills"],
};

const HELP = `clean-image-skill v${pkg.version}

Install the clean-image Agent Skill into your coding agent.

Usage:
  npx clean-image-skill [options]

Options:
  -a, --agent <name>   Target agent(s): opencode (default), claude, cursor,
                       codex, agents, or all. Repeatable / comma-separated.
  -p, --project        Install into the current project instead of globally.
  -g, --global         Install to the user directory (default).
      --force          Overwrite an existing installation.
      --remove         Uninstall the skill from the targeted location(s).
      --dry-run        Print the actions without changing anything.
  -l, --list           Alias for --dry-run.
  -y, --yes            Skip confirmation prompts (non-interactive).
  -h, --help           Show this help.
  -v, --version        Show the version.

Examples:
  npx clean-image-skill
  npx clean-image-skill --project -a opencode
  npx clean-image-skill -a opencode,claude -g --force
  npx clean-image-skill --remove -a all
`;

function fail(msg) {
  console.error(`clean-image-skill: ${msg}`);
  process.exit(1);
}

function parseArgs(argv) {
  const opts = {
    agents: [],
    scope: "global",
    force: false,
    remove: false,
    dryRun: false,
  };

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

// Resolve the bundled skill: dist/clean-image (published package), falling back
// to .agents/skills/clean-image when running from a source checkout.
function payloadDir() {
  const pkgRoot = path.join(__dirname, "..");
  const candidates = [
    path.join(pkgRoot, "dist", SKILL_NAME),
    path.join(pkgRoot, ".agents", "skills", SKILL_NAME),
  ];
  for (const dir of candidates) {
    if (fs.existsSync(path.join(dir, "SKILL.md"))) return dir;
  }
  fail("bundled skill payload not found (run `npm run stage`)");
}

function targetDir(agent, scope) {
  const [globalRel, projectRel] = AGENTS[agent];
  const base =
    scope === "global"
      ? path.join(os.homedir(), globalRel.replace(/^~[/\\]/, ""))
      : path.join(process.cwd(), projectRel);
  return path.join(base, SKILL_NAME);
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const payload = payloadDir();
  const verb = opts.remove ? "remove" : "install";

  let changed = 0;
  for (const agent of opts.agents) {
    const dest = targetDir(agent, opts.scope);
    const exists = fs.existsSync(dest);

    if (opts.remove) {
      if (!exists) {
        console.log(`skip   ${agent} (${opts.scope}): not installed`);
        continue;
      }
      if (!opts.dryRun) fs.rmSync(dest, { recursive: true, force: true });
      console.log(`${opts.dryRun ? "would remove" : "removed"} ${dest}`);
      changed++;
      continue;
    }

    if (exists && !opts.force) {
      console.log(`skip   ${agent} (${opts.scope}): already installed — use --force to overwrite\n       ${dest}`);
      continue;
    }

    if (!opts.dryRun) {
      if (exists) fs.rmSync(dest, { recursive: true, force: true });
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.cpSync(payload, dest, { recursive: true });
    }
    console.log(`${opts.dryRun ? "would install" : "installed"} ${dest}`);
    changed++;
  }

  if (opts.dryRun) {
    console.log(`\ndry run: no changes made (${verb} plan for ${opts.agents.join(", ")})`);
  } else if (!opts.remove && changed > 0) {
    console.log("\nRestart your agent to pick up the new skill, then ask it to clean an image.");
  }
}

main();
