import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "fs";
import { createServer } from "net";
import { tmpdir } from "os";
import { join } from "path";

// A stand-in for CodeIsland's socket — never the real one — and a HOME with
// no bridge, so nothing here can reach a running CodeIsland. The module reads
// both while loading, so they are set before the import.
const dir = mkdtempSync(join(tmpdir(), "codeisland-omp-"));
const socketPath = join(dir, "island.sock");
const received: Record<string, unknown>[] = [];
const island = createServer((sock) => {
  let buf = "";
  sock.on("data", (d) => {
    buf += d;
  });
  sock.on("end", () => {
    received.push(JSON.parse(buf));
  });
});
await new Promise<void>((resolve) => island.listen(socketPath, resolve));

const saved = {
  CODEISLAND_SOCKET_PATH: process.env.CODEISLAND_SOCKET_PATH,
  HOME: process.env.HOME,
};
process.env.CODEISLAND_SOCKET_PATH = socketPath;
process.env.HOME = dir;

const {
  default: codeislandExtension,
  ompAgentCards,
  ompAgentIdentity,
} = await import("../../Sources/CodeIsland/Resources/codeisland-omp?subagent-tests");

afterAll(async () => {
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  await new Promise<void>((resolve) => island.close(() => resolve()));
  rmSync(dir, { recursive: true, force: true });
});

beforeEach(() => {
  ompAgentCards().clear();
});

interface FakeSchema {
  optional: () => FakeSchema;
  describe: () => FakeSchema;
  refine: () => FakeSchema;
  min: () => FakeSchema;
}

function fakeSchema(): FakeSchema {
  const schema: FakeSchema = {
    optional: () => schema,
    describe: () => schema,
    refine: () => schema,
    min: () => schema,
  };
  return schema;
}

class FakeAskTool {
  readonly label = "Ask";
  readonly description = "Native Ask";
  constructor(_session: unknown) {}
}

type Handler = (event: unknown, ctx: unknown) => unknown;
type Agent = Record<string, unknown> | undefined;

/**
 * One OMP session with this extension bound to it, as OMP rebinds it to the
 * main session and to every subagent session in the same process.
 */
function session(sessionId: string, agent: Agent) {
  const handlers = new Map<string, Handler>();
  codeislandExtension({
    zod: {
      string: fakeSchema,
      number: fakeSchema,
      boolean: fakeSchema,
      array: fakeSchema,
      object: fakeSchema,
    },
    pi: { AskTool: FakeAskTool, settings: {} },
    getSessionName: () => undefined,
    registerTool: () => undefined,
    on: (name: string, handler: Handler) => {
      handlers.set(name, handler);
    },
  } as never);
  const ctx = (as: Agent = agent) => ({
    cwd: "/repo",
    hasUI: false,
    sessionManager: {
      getSessionId: () => sessionId,
      getSessionFile: () => null,
      getEntries: () => [],
    },
    ...(as ? { agent: as } : {}),
  });
  return async (name: string, event: Record<string, unknown> = {}, as?: Agent) => {
    await handlers.get(name)?.({ type: name, ...event }, ctx(as ?? agent));
  };
}

const main = (id = "Main") => ({ kind: "main", id, name: "main", depth: 0 });
const sub = (id: string, parentId: string, name = "explore") =>
  ({ kind: "sub", id, name, depth: 1, parentId });

/** Payloads for one session, once `count` of them have arrived. */
async function payloadsFor(sessionId: string, count: number) {
  const mine = () => received.filter((p) => p.session_id === sessionId);
  for (let i = 0; i < 300 && mine().length < count; i++) {
    await new Promise((r) => setTimeout(r, 10));
  }
  return mine();
}

const tagOf = (payload: Record<string, unknown>) => ({
  parent: payload._parent_session_id,
  type: payload.agent_type,
});

describe("OMP subagent sessions (#378)", () => {
  test("a subagent names its parent's card and its agent on every payload", async () => {
    const parent = session("main-1", main());
    const child = session("sub-1", sub("0-Explore", "Main"));

    await parent("session_start");
    await child("session_start");
    await child("before_agent_start", { prompt: "Find the config loader" });
    await child("tool_call", { toolName: "read", toolCallId: "c1", input: { path: "a.ts" } });
    await child("tool_result", { toolName: "read", toolCallId: "c1" });
    await child("agent_end", { messages: [{ role: "assistant", content: [{ type: "text", text: "found" }] }] });
    await child("session_shutdown");

    const payloads = await payloadsFor("pi-sub-1", 6);
    expect(payloads.map((p) => p.hook_event_name)).toEqual([
      "SessionStart",
      "UserPromptSubmit",
      "PreToolUse",
      "PostToolUse",
      "Stop",
      "SessionEnd",
    ]);
    for (const payload of payloads) {
      expect(tagOf(payload)).toEqual({ parent: "pi-main-1", type: "explore" });
    }
    const [parentStart] = await payloadsFor("pi-main-1", 1);
    expect("_parent_session_id" in parentStart).toBe(false);
    expect("agent_type" in parentStart).toBe(false);
  });

  test("a nested subagent names the subagent that spawned it", async () => {
    const parent = session("main-2", main());
    const child = session("sub-2", sub("0-Task", "Main", "task"));
    const grandchild = session("sub-2-1", sub("0-Task.0-Explore", "0-Task"));

    await parent("session_start");
    await child("session_start");
    await grandchild("session_start");

    const [start] = await payloadsFor("pi-sub-2-1", 1);
    expect(tagOf(start)).toEqual({ parent: "pi-sub-2", type: "explore" });
  });

  test("stays untagged until its parent is known, then keeps that parent", async () => {
    const parent = session("main-3", main());
    const child = session("sub-3", sub("1-Explore", "Main"));

    // The parent's extension has not registered yet (loaded mid-session).
    await child("session_start");
    // Its next turn registers it; subagents are only spawned during a turn.
    await parent("before_agent_start", { prompt: "go" });
    await child("tool_call", { toolName: "read", toolCallId: "c2", input: { path: "b.ts" } });
    // The parent ending does not unlink a child that already found it.
    await parent("session_shutdown");
    await child("agent_end", { messages: [] });

    const payloads = await payloadsFor("pi-sub-3", 3);
    expect(payloads.map((p) => p.hook_event_name)).toEqual(["SessionStart", "PreToolUse", "Stop"]);
    expect("_parent_session_id" in payloads[0]).toBe(false);
    expect(tagOf(payloads[1])).toEqual({ parent: "pi-main-3", type: "explore" });
    expect(tagOf(payloads[2])).toEqual({ parent: "pi-main-3", type: "explore" });
  });

  test("an advisor's tool calls stay the session's own", async () => {
    const parent = session("main-4", main());
    await parent("session_start");
    // OMP reports an advisor working for this session as a subagent of it.
    await parent(
      "tool_call",
      { toolName: "grep", toolCallId: "c3", input: { pattern: "TODO" } },
      { kind: "sub", id: "advisor", name: "advisor", depth: 0, parentId: "Main" },
    );

    const payloads = await payloadsFor("pi-main-4", 2);
    expect(payloads.map((p) => p.hook_event_name)).toEqual(["SessionStart", "PreToolUse"]);
    for (const payload of payloads) {
      expect("_parent_session_id" in payload).toBe(false);
    }
  });

  test("a newer session keeps the registry id the old one gives up", async () => {
    const first = session("main-5a", main());
    const second = session("main-5b", main());
    await first("session_start");
    await second("session_start");
    await first("session_shutdown");

    const child = session("sub-5", sub("0-Explore", "Main"));
    await child("session_start");
    const [start] = await payloadsFor("pi-sub-5", 1);
    expect(tagOf(start)).toEqual({ parent: "pi-main-5b", type: "explore" });
  });

  test("an OMP without ctx.agent is unchanged", async () => {
    const parent = session("main-6", undefined);
    const child = session("sub-6", undefined);
    await parent("session_start");
    await child("session_start");

    const [start] = await payloadsFor("pi-sub-6", 1);
    expect("_parent_session_id" in start).toBe(false);
    expect(ompAgentCards().size).toBe(0);
  });

  test("reads only a well-formed ctx.agent", () => {
    expect(ompAgentIdentity({ agent: sub("0-Explore", "Main") })).toEqual({
      kind: "sub",
      id: "0-Explore",
      name: "explore",
      parentId: "Main",
    });
    expect(ompAgentIdentity({ agent: { kind: "main", id: "Main", name: "", depth: 0 } })).toEqual({
      kind: "main",
      id: "Main",
    });
    expect(ompAgentIdentity({ agent: { kind: "other", id: "x" } })).toBeUndefined();
    expect(ompAgentIdentity({ agent: { kind: "sub", id: "" } })).toBeUndefined();
    expect(ompAgentIdentity({ agent: "Main" })).toBeUndefined();
    expect(ompAgentIdentity({})).toBeUndefined();
    expect(ompAgentIdentity(undefined)).toBeUndefined();
  });
});
