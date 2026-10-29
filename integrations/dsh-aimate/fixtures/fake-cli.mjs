#!/usr/bin/env node
// Stand-in for `pet-cli ask` in the plugin tests. FAKE_MODE decides what it does,
// FAKE_LOG records that it ran (and whether it was killed).
import { appendFileSync } from "node:fs";

const argv = process.argv.slice(2);
const mode = process.env.FAKE_MODE ?? "silent";
const log = process.env.FAKE_LOG;
const note = (line) => { if (log) appendFileSync(log, line + "\n"); };
// `pet-cli ask` stops at its own deadline; the fixture has to as well or the
// plugin's watchdog is the only thing that ends the wait.
const waitIndex = argv.indexOf("--wait");
const waitSeconds = waitIndex >= 0 ? Number(argv[waitIndex + 1]) : 30;

note(`started ${argv.join(" ")}`);
process.on("SIGTERM", () => { note("killed"); process.exit(0); });

if (mode === "silent") {
  setTimeout(() => process.exit(0), waitSeconds * 1000);
} else if (mode === "slow-allow") {
  setTimeout(() => { note("answering"); process.stdout.write("允许一次\n"); process.exit(0); }, 300);
} else {
  process.stdout.write(mode === "allow" ? "允许一次\n" : "拒绝\n");
  process.exit(0);
}
