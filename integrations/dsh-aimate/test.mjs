/**
 * Behavioural tests for the plugin: the approval answerer (where `next` is faked
 * the way dsh composes it, a promise resolving to an outcome) and the session
 * forwarder, whose host seam is `session/event`.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  chmodSync, existsSync, mkdtempSync, readFileSync, readdirSync, utimesSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { apply } from "./index.js";
import { createForwarder, endOf, isoString, oneLine, toolDetail } from "./forwarder.js";

const CLI = new URL("./fixtures/fake-cli.mjs", import.meta.url).pathname;
chmodSync(CLI, 0o755);

/** The parts of a cordis context this plugin touches. */
function fakeCtx() {
  const listeners = new Map();
  const disposers = [];
  return {
    on(event, fn) {
      if (!listeners.has(event)) listeners.set(event, []);
      listeners.get(event).push(fn);
    },
    effect(fn) { disposers.push(fn()); },
    /** dsh's `ctx.emit` hands back the last listener's value; one listener per event here. */
    emit(event, ...args) {
      let last;
      for (const fn of listeners.get(event) ?? []) last = fn(...args);
      return last;
    },
    dispose() { for (const dispose of disposers) dispose?.(); },
    count: (event) => (listeners.get(event) ?? []).length,
  };
}

function harness({ petAlive = true, mode = "silent", waitSeconds = 2 } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "aimate-dsh-"));
  const stateFile = join(dir, "live.stamp");
  const log = join(dir, "fake.log");
  if (petAlive) writeFileSync(stateFile, "now");
  else {
    writeFileSync(stateFile, "old");
    const old = new Date(Date.now() - 60_000);
    utimesSync(stateFile, old, old);
  }
  const ctx = fakeCtx();
  apply(ctx, {
    petCLI: CLI, stateFile, waitSeconds,
    petDir: join(dir, "pet"), stampFile: join(dir, "stamp.json"),
  });
  assert.equal(ctx.count("approval/request"), 1);
  assert.equal(JSON.parse(readFileSync(join(dir, "stamp.json"), "utf8")).pid, process.pid);
  process.env.FAKE_MODE = mode;
  process.env.FAKE_LOG = log;

  const ask = (next, signal) => ctx.emit("approval/request",
    { agent: {}, toolName: "bash", callId: "call-1", reason: "需要写入 /etc/hosts", signal },
    next);

  const ran = () => {
    try { return readFileSync(log, "utf8"); } catch { return ""; }
  };
  return { ask, ran, dir, ctx };
}

const outcome = (value, delay = 0) =>
  () => new Promise((resolve) => setTimeout(() => resolve(value), delay));

test("a closed pet changes nothing", async () => {
  const h = harness({ petAlive: false });
  assert.equal(await h.ask(outcome("unavailable")), "unavailable");
  assert.equal(h.ran(), "");
});

test("点击允许 → allowed-once", async () => {
  const h = harness({ mode: "allow" });
  assert.equal(await h.ask(outcome("unavailable")), "allowed-once");
  assert.match(h.ran(), /started .*--source dsh --id call-1/);
  assert.match(h.ran(), /--title 需要写入 \/etc\/hosts --detail bash/);
});

test("点击拒绝 → rejected", async () => {
  const h = harness({ mode: "deny" });
  assert.equal(await h.ask(outcome("unavailable")), "rejected");
});

test("无人应答且桌宠超时 → 原生结果", async () => {
  const h = harness({ mode: "silent", waitSeconds: 0.5 });
  const started = Date.now();
  assert.equal(await h.ask(outcome("unavailable")), "unavailable");
  assert.ok(Date.now() - started < 3000);
});

test("原生批准先到 → 不再等桌宠，并撤回问题", async () => {
  const h = harness({ mode: "silent", waitSeconds: 5 });
  const started = Date.now();
  assert.equal(await h.ask(outcome("allowed-once", 100)), "allowed-once");
  assert.ok(Date.now() - started < 2000);
  await new Promise((resolve) => setTimeout(resolve, 500));
  assert.match(h.ran(), /killed/);
});

test("原生答复 unavailable 不是决定 → 仍然等桌宠", async () => {
  const h = harness({ mode: "slow-allow", waitSeconds: 5 });
  assert.equal(await h.ask(outcome("unavailable")), "allowed-once");
});

test("取消 → 撤回问题并交还原生结果", async () => {
  const h = harness({ mode: "silent", waitSeconds: 5 });
  const controller = new AbortController();
  const pending = h.ask(outcome("unavailable"), controller.signal);
  setTimeout(() => controller.abort(), 150);
  assert.equal(await pending, "unavailable");
  await new Promise((resolve) => setTimeout(resolve, 400));
  assert.match(h.ran(), /killed/);
});

// MARK: - 会话状态转发

function forwarding() {
  const dir = mkdtempSync(join(tmpdir(), "aimate-dsh-fwd-"));
  const actorsDir = join(dir, "actors");
  const claimFile = join(dir, "dsh-plugin-4242.json");
  let now = Date.parse("2026-10-29T12:00:00Z");
  const forwarder = createForwarder({ actorsDir, claimFile, pid: 4242, clock: () => now });
  const session = { id: "s-1", header: { cwd: "/Users/me/Project A" } };
  const cardPath = join(actorsDir, "live-dsh-s-1.json");
  return {
    forwarder,
    session,
    cardPath,
    claimFile,
    advance(seconds) { now += seconds * 1000; },
    card() { return JSON.parse(readFileSync(cardPath, "utf8")); },
    claim() { return JSON.parse(readFileSync(claimFile, "utf8")); },
    has: (path) => existsSync(path),
    emit(event) { forwarder.event(session, event); },
  };
}

test("isoString 去掉毫秒（桌宠的 iso8601 解码器只认秒）", () => {
  assert.equal(isoString(Date.parse("2026-10-29T12:00:00.123Z")), "2026-10-29T12:00:00Z");
});

test("oneLine 压平换行并按字截断", () => {
  assert.equal(oneLine("第一行\n\n第二行  "), "第一行 第二行");
  assert.equal(Array.from(oneLine("字".repeat(80))).length, 72);
  assert.ok(oneLine("字".repeat(80)).endsWith("…"));
});

test("toolDetail 取一个能认出来的参数", () => {
  assert.equal(toolDetail("Bash", JSON.stringify({ command: "rm -rf build", timeout: 5 })),
    "Bash · rm -rf build");
  assert.equal(toolDetail("Read", "{not json"), "Read");
  assert.equal(toolDetail("Read", "{}"), "Read");
});

test("endOf 把四种收尾原因读成卡面", () => {
  assert.deepEqual(endOf({ kind: "completed" }), { state: "review", detail: "本轮结束，等你确认" });
  assert.equal(endOf({ kind: "error", error: { message: "usage limit reached" } }).state, "failed");
  assert.equal(endOf({ kind: "aborted", reason: "user" }).state, "review");
});

test("turn/start 发一张 running 卡，带 host pid 与秒级时间", () => {
  const f = forwarding();
  f.emit({ type: "turn/start", data: { turn: 1 } });
  const card = f.card();
  assert.equal(card.id, "live:dsh:s-1");
  assert.equal(card.source, "dsh");
  assert.equal(card.state, "running");
  assert.equal(card.thread, "s-1");
  assert.equal(card.pid, 4242);
  assert.equal(card.ttl, 180);
  assert.equal(card.updatedAt, "2026-10-29T12:00:00Z");
  assert.equal(card.title, "DeepSeek · Project A");
  assert.equal(card.detail, undefined);
});

test("用户消息成为标题，注入的插件消息不算", () => {
  const f = forwarding();
  f.emit({ type: "turn/start", data: { turn: 1 } });
  f.emit({
    type: "user/message",
    data: { role: "user", source: { kind: "plugin", plugin: "fs" }, content: [{ type: "text", text: "注入内容" }] },
  });
  assert.equal(f.card().title, "DeepSeek · Project A");
  f.emit({
    type: "user/message",
    data: { role: "user", source: { kind: "user" }, content: [{ type: "text", text: "  修一下\n构建脚本 " }] },
  });
  assert.equal(f.card().title, "修一下 构建脚本");
});

test("工具调用与失败写进 detail，状态仍是 running", () => {
  const f = forwarding();
  f.emit({ type: "turn/start", data: { turn: 1 } });
  f.emit({
    type: "tool/call",
    data: { turn: 1, step: 1, callId: "c1", name: "Bash", arguments: "{\"command\":\"swift build\"}" },
  });
  assert.equal(f.card().detail, "Bash · swift build");
  f.emit({
    type: "tool/result",
    data: {
      turn: 1, step: 1,
      message: { source: { kind: "tool", callId: "c1" }, content: [] },
      error: { name: "ToolError", code: "EACCES" },
    },
  });
  assert.equal(f.card().detail, "Bash 失败 · EACCES");
  assert.equal(f.card().state, "running");
});

test("turn/end 把卡片交给 review，ttl 与磁盘适配器一致", () => {
  const f = forwarding();
  f.emit({ type: "turn/start", data: { turn: 1 } });
  f.emit({ type: "turn/end", data: { turn: 1, reason: { kind: "completed" } } });
  assert.equal(f.card().state, "review");
  assert.equal(f.card().ttl, 90);
  assert.equal(f.card().detail, "本轮结束，等你确认");
});

test("错误收尾是 failed 并带上失败原因", () => {
  const f = forwarding();
  f.emit({ type: "turn/start", data: { turn: 1 } });
  f.emit({ type: "turn/end", data: { turn: 1, reason: { kind: "error", error: { message: "usage limit reached" } } } });
  assert.equal(f.card().state, "failed");
  assert.equal(f.card().detail, "usage limit reached");
});

test("心跳文件声明本机会话，供磁盘适配器让位", () => {
  const f = forwarding();
  f.emit({ type: "turn/start", data: { turn: 1 } });
  assert.deepEqual(f.claim(), { pid: 4242, at: "2026-10-29T12:00:00Z", sessions: ["s-1"] });
  f.forwarder.drop("s-1");
  assert.equal(f.has(f.cardPath), false);
  assert.deepEqual(f.claim().sessions, []);
});

test("review 卡 90 秒后自行消失，心跳同步收回", () => {
  const f = forwarding();
  f.emit({ type: "turn/start", data: { turn: 1 } });
  f.emit({ type: "turn/end", data: { turn: 1, reason: { kind: "completed" } } });
  f.advance(60);
  f.forwarder.tick();
  assert.equal(f.has(f.cardPath), true);
  f.advance(40);
  f.forwarder.tick();
  assert.equal(f.has(f.cardPath), false);
  assert.deepEqual(f.claim().sessions, []);
});

test("running 卡靠心跳续命，但卡住的回合最终会被放下", () => {
  const f = forwarding();
  f.emit({ type: "turn/start", data: { turn: 1 } });
  for (let i = 0; i < 5; i += 1) { f.advance(60); f.forwarder.tick(); }
  assert.equal(f.card().updatedAt, "2026-10-29T12:05:00Z");
  // 15 分钟没有任何事件：不再刷新，交给 ttl 到点删除。
  f.advance(16 * 60);
  f.forwarder.tick();
  f.advance(200);
  f.forwarder.tick();
  assert.equal(f.has(f.cardPath), false);
  assert.deepEqual(f.claim().sessions, []);
});

test("插件卸载时清卡并收回心跳", () => {
  const f = forwarding();
  f.emit({ type: "turn/start", data: { turn: 1 } });
  f.forwarder.shutdown();
  assert.equal(f.has(f.cardPath), false);
  assert.equal(f.has(f.claimFile), false);
});

test("apply 接上 session/event 与 session/disposed，dispose 后不留卡", () => {
  const dir = mkdtempSync(join(tmpdir(), "aimate-dsh-wire-"));
  const ctx = fakeCtx();
  apply(ctx, {
    petCLI: CLI, petDir: join(dir, "pet"), stateFile: join(dir, "live.stamp"),
    actorsDir: join(dir, "actors"), stampFile: join(dir, "stamp.json"),
  });
  assert.equal(ctx.count("session/event"), 1);
  assert.equal(ctx.count("session/disposed"), 1);
  const session = { id: "s-9", header: { cwd: "/tmp/项目" } };
  ctx.emit("session/event", session, { type: "turn/start", data: { turn: 1 } });
  const claimFile = join(dir, "pet", `dsh-plugin-${process.pid}.json`);
  const cardPath = join(dir, "actors", "live-dsh-s-9.json");
  assert.equal(existsSync(cardPath), true);
  assert.deepEqual(JSON.parse(readFileSync(claimFile, "utf8")).sessions, ["s-9"]);
  ctx.emit("session/disposed", session);
  assert.equal(existsSync(cardPath), false);
  ctx.emit("session/event", session, { type: "turn/start", data: { turn: 1 } });
  ctx.dispose();
  assert.equal(existsSync(cardPath), false);
  assert.equal(existsSync(claimFile), false);
});

test("forwardStatus: false 只留审批接管", () => {
  const dir = mkdtempSync(join(tmpdir(), "aimate-dsh-off-"));
  const ctx = fakeCtx();
  apply(ctx, {
    petCLI: CLI, petDir: join(dir, "pet"), stampFile: join(dir, "stamp.json"),
    forwardStatus: false,
  });
  assert.equal(ctx.count("session/event"), 0);
  assert.equal(ctx.count("approval/request"), 1);
  assert.equal(existsSync(join(dir, "stamp.json")), true);
  assert.equal(existsSync(join(dir, "pet")), false);
});

test("残留的旧心跳（宿主已退出）在加载时清掉", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aimate-dsh-prune-"));
  const petDir = join(dir, "pet");
  const ended = join(petDir, "dsh-plugin-999999.json");
  const { mkdirSync, writeFileSync } = await import("node:fs");
  mkdirSync(petDir, { recursive: true });
  writeFileSync(ended, JSON.stringify({ pid: 999999, at: "2026-10-29T00:00:00Z", sessions: [] }));
  const ctx = fakeCtx();
  apply(ctx, { petCLI: CLI, petDir, stampFile: join(dir, "stamp.json"), forwardStatus: false });
  assert.equal(existsSync(ended), false);
  ctx.dispose();
});
