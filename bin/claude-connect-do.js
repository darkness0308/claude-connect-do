#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const args = process.argv.slice(2);

function run(cmd, cmdArgs) {
  const result = spawnSync(cmd, cmdArgs, { stdio: "inherit" });
  if (result.error) {
    return { ok: false, error: result.error };
  }
  return { ok: true, code: result.status ?? 1 };
}

if (process.platform === "win32") {
  const psScript = path.join(__dirname, "claude-connect-do.ps1");
  const pwshArgs = [
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    psScript,
    ...args,
  ];

  let result = run("pwsh", pwshArgs);
  if (!result.ok && result.error && result.error.code === "ENOENT") {
    result = run("powershell", pwshArgs);
  }

  if (!result.ok) {
    console.error("error: PowerShell was not found. Install PowerShell and retry.");
    process.exit(1);
  }

  process.exit(result.code);
}

const bashScript = path.join(__dirname, "claude-connect-do");
const result = run("bash", [bashScript, ...args]);
if (!result.ok) {
  console.error("error: bash was not found. Install bash and retry.");
  process.exit(1);
}

process.exit(result.code);
