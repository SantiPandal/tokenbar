#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync, cpSync } from "node:fs";
import { homedir, platform, userInfo } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const label = "io.github.santipandal.tokenbar";
const oldLabel = "local.santiago.tokenbar";
const appName = "TokenBar.app";
const builtApp = path.join(root, "build", appName);
const installDir = path.join(homedir(), "Applications");
const installedApp = path.join(installDir, appName);
const launchAgentDir = path.join(homedir(), "Library", "LaunchAgents");
const launchAgent = path.join(launchAgentDir, `${label}.plist`);
const oldLaunchAgent = path.join(launchAgentDir, `${oldLabel}.plist`);
const executablePath = path.join(installedApp, "Contents", "MacOS", "TokenBar");

const command = process.argv[2] ?? "install";
const args = new Set(process.argv.slice(3));
const noLogin = args.has("no-login") || args.has("--no-login");

try {
  switch (command) {
    case "install":
      install();
      break;
    case "build":
      assertMacOS();
      build();
      break;
    case "start":
      start();
      break;
    case "stop":
      stop();
      break;
    case "restart":
      stop();
      start();
      break;
    case "status":
      status();
      break;
    case "doctor":
      doctor();
      break;
    case "uninstall":
      uninstall();
      break;
    case "help":
    case "--help":
    case "-h":
      usage();
      break;
    default:
      console.error(`Unknown command: ${command}`);
      usage();
      process.exit(1);
  }
} catch (error) {
  console.error(`\nTokenBar: ${error.message}`);
  process.exit(1);
}

function install() {
  assertMacOS();
  assertCommand("swift", "Swift is required. Install Xcode Command Line Tools with: xcode-select --install");

  build();
  stop({ quiet: true });

  mkdirSync(installDir, { recursive: true });
  rmSync(installedApp, { recursive: true, force: true });
  cpSync(builtApp, installedApp, { recursive: true });

  if (!noLogin) {
    writeLaunchAgent();
    run("launchctl", ["bootstrap", launchTarget(), launchAgent], { allowFailure: true, quiet: true });
    run("launchctl", ["enable", `${launchTarget()}/${label}`], { allowFailure: true, quiet: true });
  } else {
    rmSync(launchAgent, { force: true });
    rmSync(oldLaunchAgent, { force: true });
  }

  run("open", [installedApp]);
  console.log(`TokenBar installed at ${installedApp}`);
  if (!noLogin) {
    console.log("It will start automatically when you log in.");
  }
}

function build() {
  const packageVersion = process.env.npm_package_version ?? "0.1.0";
  run(path.join(root, "scripts", "build_app.sh"), [], {
    env: { ...process.env, TOKENBAR_VERSION: packageVersion }
  });
}

function start() {
  assertMacOS();
  if (!existsSync(installedApp)) {
    throw new Error("TokenBar is not installed yet. Run: npx tokenbar install");
  }
  run("open", [installedApp]);
  console.log("TokenBar started.");
}

function stop(options = {}) {
  assertMacOS();
  unloadLaunchAgent(label, launchAgent);
  unloadLaunchAgent(oldLabel, oldLaunchAgent);
  run("pkill", ["-f", executablePath], { allowFailure: true, quiet: options.quiet });
  run("pkill", ["-f", "/Applications/TokenBar.app/Contents/MacOS/TokenBar"], { allowFailure: true, quiet: true });
  run("pkill", ["-f", `${homedir()}/Applications/TokenBar.app/Contents/MacOS/TokenBar`], { allowFailure: true, quiet: true });
  if (!options.quiet) {
    console.log("TokenBar stopped.");
  }
}

function status() {
  assertMacOS();
  const result = run("pgrep", ["-fl", "TokenBar.app/Contents/MacOS/TokenBar"], {
    allowFailure: true,
    capture: true
  });

  if (result.status === 0 && result.stdout.trim()) {
    console.log(result.stdout.trim());
  } else {
    console.log("TokenBar is not running.");
  }

  console.log(existsSync(installedApp) ? `Installed: ${installedApp}` : "Installed: no");
  console.log(existsSync(launchAgent) ? `Login item: ${launchAgent}` : "Login item: no");
}

function doctor() {
  console.log(`macOS: ${platform() === "darwin" ? "ok" : "required"}`);
  console.log(`Swift: ${commandExists("swift") ? "ok" : "missing"}`);
  console.log(`Codex logs: ${existsSync(path.join(homedir(), ".codex")) ? "found" : "not found"}`);
  console.log(`Claude logs: ${existsSync(path.join(homedir(), ".claude")) ? "found" : "not found"}`);
  console.log(existsSync(installedApp) ? `Installed app: ${installedApp}` : "Installed app: not installed");
  console.log(existsSync(launchAgent) ? `LaunchAgent: ${launchAgent}` : "LaunchAgent: not installed");
}

function uninstall() {
  assertMacOS();
  stop({ quiet: true });
  rmSync(installedApp, { recursive: true, force: true });
  rmSync(launchAgent, { force: true });
  rmSync(oldLaunchAgent, { force: true });
  console.log("TokenBar uninstalled.");
}

function writeLaunchAgent() {
  mkdirSync(launchAgentDir, { recursive: true });
  rmSync(oldLaunchAgent, { force: true });
  writeFileSync(launchAgent, launchAgentPlist(executablePath));
}

function unloadLaunchAgent(agentLabel, plistPath) {
  run("launchctl", ["bootout", launchTarget(), plistPath], { allowFailure: true, quiet: true });
  run("launchctl", ["disable", `${launchTarget()}/${agentLabel}`], { allowFailure: true, quiet: true });
}

function launchAgentPlist(programPath) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${escapePlist(programPath)}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
`;
}

function launchTarget() {
  return `gui/${userInfo().uid}`;
}

function assertMacOS() {
  if (platform() !== "darwin") {
    throw new Error("TokenBar is a native macOS menu bar app. macOS is required.");
  }
}

function assertCommand(name, message) {
  if (!commandExists(name)) {
    throw new Error(message);
  }
}

function commandExists(name) {
  return spawnSync("which", [name], { stdio: "ignore" }).status === 0;
}

function run(commandName, commandArgs = [], options = {}) {
  const result = spawnSync(commandName, commandArgs, {
    cwd: root,
    env: options.env ?? process.env,
    encoding: "utf8",
    stdio: options.capture ? ["ignore", "pipe", "pipe"] : options.quiet ? "ignore" : "inherit"
  });

  if (result.error && !options.allowFailure) {
    throw result.error;
  }

  if (result.status !== 0 && !options.allowFailure) {
    throw new Error(`${commandName} ${commandArgs.join(" ")} failed`);
  }

  return result;
}

function escapePlist(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function usage() {
  console.log(`TokenBar

Usage:
  npx tokenbar install        Build, install, launch, and start at login
  npx tokenbar install no-login
  npx tokenbar status
  npx tokenbar stop
  npx tokenbar start
  npx tokenbar restart
  npx tokenbar doctor
  npx tokenbar uninstall

Before npm publish:
  npx github:SantiPandal/tokenbar install
`);
}
