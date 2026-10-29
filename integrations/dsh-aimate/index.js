/**
 * The pet inside DeepSeek Harness: one more answerer on the `approval/request`
 * waterfall, and one more observer of the `session/event` firehose.
 *
 * Approvals. dsh composes answerers: each listener may return an outcome, or
 * delegate with `next()`. The built-in prompt the desktop app shows is one of
 * those listeners, so this plugin is **additive**: it calls `next()` before it
 * asks the pet, which means the app's own prompt appears exactly as before and
 * the pet can only ever arrive as a second way to answer. Nothing here can grant
 * a permission by staying silent — a closed pet, a timeout, a crashed CLI or a
 * cancelled turn all resolve to whatever the rest of the chain would have said
 * without us.
 *
 * The one state worth spelling out: `next()` resolving to `"unavailable"` is not
 * a decision, it is "nobody is listening". Treating it as final would make the
 * pet useless in a headless session, so in that case we keep waiting for the
 * click and only then fall through.
 *
 * Status. `session/event` is the same seam dsh's persistence plugin rides; the
 * forwarder turns turn/tool frames into cards and claims those sessions so the
 * pet's disk adapter stands down for them (see `forwarder.js`). Set
 * `forwardStatus: false` to keep only the approval takeover.
 */
import { spawn } from "node:child_process";
import { mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { createForwarder, isoString } from "./forwarder.js";

export const name = "aimate-pet";

const ALLOW = "允许一次";
const DENY = "拒绝";
const OPTIONS = [ALLOW, DENY];

const BEAT_MS = 5_000;

export function apply(ctx, config = {}) {
  const cli = config.petCLI;
  if (typeof cli !== "string" || cli.length === 0) {
    throw new Error("aimate-pet: config.petCLI 必须指向 pet-cli");
  }
  const petDir = config.petDir ?? join(homedir(), ".aimate/pet");
  const settings = {
    cli,
    waitSeconds: Number(config.waitSeconds ?? 170),
    graceSeconds: Number(config.graceSeconds ?? 6),
    stateFile: config.stateFile ?? join(petDir, "live.stamp"),
    stampFile: config.stampFile ?? join(petDir, "dsh-plugin.json"),
    forwardStatus: config.forwardStatus !== false,
  };
  // A plugin inside someone else's process has no window to prove it is there;
  // this stamp is how the pet's owner (and I) tell "loaded" from "misconfigured".
  try {
    mkdirSync(dirname(settings.stampFile), { recursive: true });
    writeFileSync(settings.stampFile,
      JSON.stringify({ pid: process.pid, at: isoString(Date.now()) }));
  } catch { /* diagnostics must never break the host */ }
  ctx.on("approval/request", (req, next) => answer(req, next, settings));

  pruneStaleClaims(petDir);
  if (!settings.forwardStatus) return;

  const forwarder = createForwarder({
    actorsDir: config.actorsDir ?? join(petDir, "actors"),
    // Per host pid: two harness processes share one home, and a single heartbeat
    // file would make them take turns claiming each other's sessions.
    claimFile: join(petDir, `dsh-plugin-${process.pid}.json`),
    pid: process.pid,
  });
  const beat = setInterval(() => forwarder.tick(), BEAT_MS);
  beat.unref?.();
  forwarder.tick();
  ctx.on("session/event", (session, event) => forwarder.event(session, event));
  ctx.on("session/disposed", (session) => forwarder.drop(session?.id));
  ctx.effect?.(() => () => {
    clearInterval(beat);
    forwarder.shutdown();
  });
}

async function answer(req, next, settings) {
  const native = Promise.resolve()
    .then(() => next())
    .then((outcome) => ({ outcome }), () => ({ outcome: "unavailable" }));
  // A closed pet costs one stat and changes nothing.
  if (!petAlive(settings.stateFile, settings.graceSeconds)) return (await native).outcome;

  const ask = askPet(req, settings);
  if (req.signal) req.signal.addEventListener("abort", ask.kill, { once: true });
  const first = await Promise.race([native, ask.promise.then((value) => ({ pet: value }))]);

  if ("pet" in first) {
    if (first.pet === ALLOW) return "allowed-once";
    if (first.pet === DENY) return "rejected";
    // Timed out: the click may still come from the app's own prompt.
    return (await native).outcome;
  }
  if (first.outcome !== "unavailable") {
    // Somebody answered natively; the card must not keep asking.
    ask.kill();
    return first.outcome;
  }
  // No native answerer: the pet is the only thing that can decide now.
  const value = await ask.promise;
  if (value === ALLOW) return "allowed-once";
  if (value === DENY) return "rejected";
  return first.outcome;
}

/** A crashed host leaves its heartbeat behind; nothing else would ever read it. */
function pruneStaleClaims(petDir) {
  try {
    for (const name of readdirSync(petDir)) {
      const match = /^dsh-plugin-(\d+)\.json$/.exec(name);
      if (!match) continue;
      const pid = Number(match[1]);
      if (pid === process.pid) continue;
      try {
        process.kill(pid, 0);
      } catch (error) {
        if (error?.code === "ESRCH") rmSync(join(petDir, name), { force: true });
      }
    }
  } catch { /* an unreadable pet directory is not worth failing the host over */ }
}

function petAlive(stateFile, graceSeconds) {
  try {
    return (Date.now() - statSync(stateFile).mtimeMs) / 1000 <= graceSeconds;
  } catch {
    return false;
  }
}

function askPet(req, settings) {
  const args = [
    "ask",
    "--source", "dsh",
    "--id", String(req.callId ?? randomUUID()),
    "--title", headline(req),
    "--detail", req.toolName,
    "--options", OPTIONS.join(","),
    "--wait", String(settings.waitSeconds),
  ];
  let child;
  try {
    child = spawn(settings.cli, args, { stdio: ["ignore", "pipe", "ignore"] });
  } catch {
    return { promise: Promise.resolve(null), kill() {} };
  }
  let out = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { out += chunk; });
  const promise = new Promise((resolve) => {
    child.on("error", () => resolve(null));
    child.on("close", () => resolve(out.trim() || null));
  });
  // The CLI owns its own timeout; this watchdog only covers a wedged process.
  const watchdog = setTimeout(() => child.kill("SIGTERM"), (settings.waitSeconds + 10) * 1000);
  promise.finally(() => clearTimeout(watchdog));
  return {
    promise,
    kill() {
      try { child.kill("SIGTERM"); } catch { /* already gone */ }
    },
  };
}

function headline(req) {
  const reason = String(req.reason ?? "").split("\n").map((line) => line.trim())
    .filter(Boolean).join(" ");
  if (reason.length === 0) return `${req.toolName} 请求批准`;
  return reason.length > 72 ? `${reason.slice(0, 72)}…` : reason;
}
