/**
 * Session-state forwarding: what the pet shows while dsh is working.
 *
 * `session/event` is the firehose every dsh subsystem reads a session through —
 * the persistence plugin takes it on `ctx.on("session/event", (session, event))`,
 * and so do we. The five event types below are the whole of what a card needs:
 * a turn opening and closing, the human prompt that names it, the tool being run,
 * and a failed turn. Everything else (steps, assistant streams, request headers)
 * is model plumbing the card would only blur over.
 *
 * Ownership is claimed, not assumed. The disk adapter reads the same sessions
 * from the projection cache, so while this plugin is live it writes a claim
 * heartbeat naming the sessions it forwards and the adapter stands down for
 * exactly those. A crashed or disabled plugin stops refreshing the heartbeat, the
 * adapter resumes from disk, and nobody ever sees two cards for one session.
 */
import { mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

/** Matches `ActorRules.ttl` in AimateCore, so a plugin card and an observed card age alike. */
export const TTL = { running: 180, review: 90, failed: 180 };

/** A turn that goes this long without a single event is wedged, not working; stop refreshing. */
const RUNNING_REFRESH_LIMIT = 900;

const TOOL_ARGUMENT_KEYS = ["file_path", "path", "command", "pattern", "query", "url"];

/** Second precision: the pet decodes ISO-8601 with `JSONDecoder.iso8601`, which rejects milliseconds. */
export function isoString(at) {
  return new Date(at).toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** Mirrors `Actor.fileName(for:)` so ids stay readable and unique on disk. */
export function actorFileName(id) {
  return id.replace(/[^\p{L}\p{N}_\-.]/gu, "-") + ".json";
}

/** One-line, length-bounded card text. Counts code points, so a CJK title is trimmed by glyphs. */
export function oneLine(text, limit = 72) {
  const flat = String(text ?? "").split(/\r?\n/).map((part) => part.trim())
    .filter(Boolean).join(" ");
  const glyphs = Array.from(flat);
  return glyphs.length > limit ? glyphs.slice(0, limit - 1).join("") + "…" : flat;
}

/** `Bash · rm -rf build` — the tool and the one argument a human recognises. */
export function toolDetail(name, rawArguments) {
  let hint = "";
  try {
    const parsed = typeof rawArguments === "string" ? JSON.parse(rawArguments) : rawArguments;
    for (const key of TOOL_ARGUMENT_KEYS) {
      const value = parsed?.[key];
      if (typeof value === "string" && value.trim().length > 0) {
        hint = oneLine(value, 48);
        break;
      }
    }
  } catch { /* a model can emit invalid JSON; the tool name alone still reads */ }
  return hint ? `${name} · ${hint}` : String(name);
}

/** `turn/end` reason → the card the pet shows once the turn is over. */
export function endOf(reason) {
  switch (reason?.kind) {
    case "error": {
      const failure = oneLine(reason.error?.message ?? reason.error?.code ?? "未知错误", 60);
      return { state: "failed", detail: failure };
    }
    case "aborted": return { state: "review", detail: "已中止，等你确认" };
    case "blocked": return { state: "review", detail: "被阻塞，等你确认" };
    case "max-tokens": return { state: "review", detail: "达到输出上限，等你确认" };
    default: return { state: "review", detail: "本轮结束，等你确认" };
  }
}

export function sessionTitle(session) {
  const cwd = session?.header?.cwd;
  if (typeof cwd === "string" && cwd.length > 0) {
    const name = cwd.replace(/\/+$/, "").split("/").pop();
    if (name) return `DeepSeek · ${name}`;
  }
  return "DeepSeek 会话";
}

/** Concatenated text of a message's text blocks — the prompt a human typed. */
export function messageText(message) {
  const blocks = Array.isArray(message?.content) ? message.content : [];
  return blocks.filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text).join(" ");
}

/**
 * @param {object} options
 * @param {string} options.actorsDir - `~/.aimate/pet/actors`.
 * @param {string} options.claimFile - this host's `dsh-plugin-<pid>.json`.
 * @param {number} options.pid - host pid; the pet drops the cards when it dies.
 * @param {() => number} [options.clock] - injectable for tests.
 */
export function createForwarder({ actorsDir, claimFile, pid, clock = () => Date.now() }) {
  /** sid → { state, title, detail, at (last published), eventAt (last real event) } */
  const tracked = new Map();
  /** `${sid}:${callId}` → tool name, so a result can name the tool it failed in. */
  const calls = new Map();

  function actorFor(sid, entry) {
    return {
      id: `live:dsh:${sid}`,
      source: "dsh",
      state: entry.state,
      title: entry.title,
      ...(entry.detail ? { detail: entry.detail } : {}),
      thread: sid,
      ttl: TTL[entry.state],
      updatedAt: isoString(entry.at),
      pid,
    };
  }

  /** Atomic: the pet's 2s poll must never read a half-written card. */
  function write(sid, entry) {
    try {
      mkdirSync(actorsDir, { recursive: true });
      const target = join(actorsDir, actorFileName(`live:dsh:${sid}`));
      const temp = `${target}.${pid}.tmp`;
      writeFileSync(temp, JSON.stringify(actorFor(sid, entry)));
      renameSync(temp, target);
    } catch { /* a pet that cannot be written to must not break the host */ }
  }

  function erase(sid) {
    try { rmSync(join(actorsDir, actorFileName(`live:dsh:${sid}`)), { force: true }); } catch { }
  }

  function writeClaim() {
    try {
      mkdirSync(dirname(claimFile), { recursive: true });
      const temp = `${claimFile}.${pid}.tmp`;
      writeFileSync(temp, JSON.stringify({
        pid,
        at: isoString(clock()),
        sessions: [...tracked.keys()],
      }));
      renameSync(temp, claimFile);
    } catch { }
  }

  function update(sid, session, patch) {
    const previous = tracked.get(sid);
    const now = clock();
    const entry = {
      ...previous,
      title: patch.title ?? previous?.title ?? sessionTitle(session),
      state: patch.state ?? previous?.state ?? "running",
      detail: patch.detail !== undefined ? patch.detail : (previous?.detail ?? null),
      at: now,
      // Progress, not publication: the refresh cap in `tick` reads this one.
      eventAt: now,
    };
    tracked.set(sid, entry);
    write(sid, entry);
    writeClaim();
  }

  function forget(sid) {
    if (!tracked.delete(sid)) return;
    erase(sid);
    writeClaim();
  }

  return {
    /** One `session/event` frame. Unknown and log-only types are ignored by design. */
    event(session, event) {
      const sid = session?.id;
      if (typeof sid !== "string" || sid.length === 0) return;
      const data = event?.data ?? {};
      switch (event?.type) {
        case "turn/start":
          update(sid, session, { state: "running", detail: null });
          break;
        case "user/message": {
          // `source.kind === "user"` is the human; plugin injections (file-change
          // notices, skill content, subdir AGENTS.md) also travel as user messages.
          if (data.source?.kind !== "user") return;
          const text = oneLine(messageText(data));
          if (text) update(sid, session, { state: "running", title: text });
          break;
        }
        case "tool/call":
          if (typeof data.callId === "string") calls.set(`${sid}:${data.callId}`, data.name);
          update(sid, session, { state: "running", detail: toolDetail(data.name, data.arguments) });
          break;
        case "tool/result": {
          if (!data.error) return;
          const name = calls.get(`${sid}:${data.message?.source?.callId}`) ?? "工具";
          update(sid, session, {
            state: "running",
            detail: `${name} 失败 · ${data.error.code ?? data.error.name ?? "unknown"}`,
          });
          break;
        }
        case "turn/end":
          update(sid, session, endOf(data.reason));
          break;
        default:
          break;
      }
    },

    /** 5s beat: keep live cards fresh and republish the claim every tick. */
    tick() {
      const now = clock();
      for (const [sid, entry] of [...tracked]) {
        if (now - entry.at > TTL[entry.state] * 1000) { forget(sid); continue; }
        if (entry.state === "running" && now - entry.eventAt <= RUNNING_REFRESH_LIMIT * 1000) {
          entry.at = now;
          write(sid, entry);
        }
      }
      writeClaim();
    },

    /** A disposed session's card goes with it. */
    drop(sid) {
      if (typeof sid === "string") forget(sid);
    },

    /** Plugin unload: remove every card and the claim, so the disk adapter resumes. */
    shutdown() {
      for (const sid of [...tracked.keys()]) erase(sid);
      tracked.clear();
      calls.clear();
      try { rmSync(claimFile, { force: true }); } catch { }
    },

    /** Diagnostics and tests: the sessions this host currently owns. */
    claimed() {
      return [...tracked.keys()];
    },
  };
}
