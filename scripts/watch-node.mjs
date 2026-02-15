#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const args = process.argv.slice(2);
const env = { ...process.env };
const cwd = process.cwd();
const compiler = "tsdown";
const watchSession = `${Date.now()}-${process.pid}`;
env.OPENCLAW_WATCH_MODE = "1";
env.OPENCLAW_WATCH_SESSION = watchSession;
if (args.length > 0) {
  env.OPENCLAW_WATCH_COMMAND = args.join(" ");
}

const initialBuild = spawnSync("pnpm", ["exec", compiler, "--no-clean"], {
  cwd,
  env,
  stdio: "inherit",
});

if (initialBuild.status !== 0) {
  process.exit(initialBuild.status ?? 1);
}

const restartStampRel = path.join("dist", ".watch-restart");
const restartStampAbs = path.join(cwd, restartStampRel);

function touchRestartStamp() {
  try {
    fs.mkdirSync(path.dirname(restartStampAbs), { recursive: true });
    // In-place write (no rename) so file watchers can reliably observe changes.
    fs.writeFileSync(restartStampAbs, `${Date.now()}\n`);
  } catch {
    // Best-effort; the watch runner can still operate without restart stamping.
  }
}

touchRestartStamp();

// In watch mode, tsdown defaults to cleaning the output directory. That can race with
// the Node runner on startup (dist temporarily missing), so keep outputs in place.
const compilerProcess = spawn("pnpm", ["exec", compiler, "--watch", "--no-clean"], {
  cwd,
  env,
  stdio: ["inherit", "pipe", "pipe"],
});

let restartTimer = null;
function scheduleRestartStamp() {
  if (restartTimer) {
    clearTimeout(restartTimer);
  }
  // Debounce: tsdown prints multiple "Build complete" lines per run (multi-entry config).
  restartTimer = setTimeout(() => {
    restartTimer = null;
    touchRestartStamp();
  }, 250);
}

function attachCompilerStream(stream, sink) {
  let buf = "";
  stream.on("data", (chunk) => {
    sink.write(chunk);
    buf += chunk.toString("utf8");
    let idx = buf.indexOf("\n");
    while (idx !== -1) {
      const raw = buf.slice(0, idx);
      buf = buf.slice(idx + 1);
      const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
      if (line.includes("Build complete") || line.includes("Rebuilt in")) {
        scheduleRestartStamp();
      }
      idx = buf.indexOf("\n");
    }
  });
}

if (compilerProcess.stdout) {
  attachCompilerStream(compilerProcess.stdout, process.stdout);
}
if (compilerProcess.stderr) {
  attachCompilerStream(compilerProcess.stderr, process.stderr);
}

// openclaw.mjs loads dist/* via dynamic import(), which Node's watch-mode dependency
// graph does not reliably track. Instead, watch a single stamp file that we touch
// after successful rebuilds (so we restart once per build, not once per chunk write).
const nodeProcess = spawn(
  process.execPath,
  ["--watch", "--watch-path", restartStampRel, "openclaw.mjs", ...args],
  {
    cwd,
    env,
    stdio: "inherit",
  },
);

let exiting = false;

function cleanup(code = 0) {
  if (exiting) {
    return;
  }
  exiting = true;
  nodeProcess.kill("SIGTERM");
  compilerProcess.kill("SIGTERM");
  process.exit(code);
}

process.on("SIGINT", () => cleanup(130));
process.on("SIGTERM", () => cleanup(143));

compilerProcess.on("exit", (code) => {
  if (exiting) {
    return;
  }
  cleanup(code ?? 1);
});

nodeProcess.on("exit", (code, signal) => {
  if (signal || exiting) {
    return;
  }
  cleanup(code ?? 1);
});
