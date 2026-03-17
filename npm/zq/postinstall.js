#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

const PLATFORMS = {
  "linux-x64": "@zqjson/linux-x64",
  "linux-arm64": "@zqjson/linux-arm64",
  "darwin-x64": "@zqjson/darwin-x64",
  "darwin-arm64": "@zqjson/darwin-arm64",
  "win32-x64": "@zqjson/win32-x64",
  "freebsd-x64": "@zqjson/freebsd-x64",
};

const platformKey = `${process.platform}-${process.arch}`;
const pkg = PLATFORMS[platformKey];

if (!pkg) {
  // Unsupported platform — leave the JS fallback shim intact
  process.exit(0);
}

const ext = process.platform === "win32" ? ".exe" : "";

let binSource;
try {
  binSource = require.resolve(`${pkg}/bin/zq${ext}`);
} catch {
  // Optional dependency not installed — leave the JS fallback shim intact
  process.exit(0);
}

const binDir = path.join(__dirname, "bin");
const binTarget = path.join(binDir, `zq${ext}`);

// Compute the relative path from bin/ to the platform binary
const relPath = path.relative(binDir, binSource);

if (process.platform === "win32") {
  // Write a .cmd that invokes the native binary directly (no node)
  const cmdPath = path.join(binDir, "zq.cmd");
  fs.writeFileSync(
    cmdPath,
    `@"${binSource.replace(/\//g, "\\")}" %*\r\n`
  );
  // Also copy the .exe so bin/zq.exe works directly
  fs.copyFileSync(binSource, binTarget);
  fs.chmodSync(binTarget, 0o755);
} else {
  // Write a POSIX shell script that execs the native binary — zero Node overhead
  fs.writeFileSync(
    binTarget,
    `#!/bin/sh\nexec "$(dirname "$0")/${relPath}" "$@"\n`
  );
  fs.chmodSync(binTarget, 0o755);
}
