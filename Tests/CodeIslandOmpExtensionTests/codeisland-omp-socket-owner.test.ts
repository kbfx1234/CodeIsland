import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, lstatSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { createServer } from "net";
import { tmpdir } from "os";
import { join } from "path";

// CodeIsland's default socket is a predictable name in /tmp, which another
// user can create first: the extension sends nothing to a socket this user
// does not own. A stand-in island (never the real one), reached directly and
// through a symlink, which connect() follows and lstat does not; and a HOME
// with no bridge. The module reads the socket path while loading, so each
// path gets a copy of its own.
const dir = mkdtempSync(join(tmpdir(), "codeisland-omp-owner-"));
const socketPath = join(dir, "island.sock");
const linkPath = join(dir, "link.sock");
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
symlinkSync(socketPath, linkPath);

const saved = {
  CODEISLAND_SOCKET_PATH: process.env.CODEISLAND_SOCKET_PATH,
  HOME: process.env.HOME,
};
process.env.HOME = dir;
process.env.CODEISLAND_SOCKET_PATH = socketPath;
const direct = await import("../../Sources/CodeIsland/Resources/codeisland-omp?omp-owner-direct");
process.env.CODEISLAND_SOCKET_PATH = linkPath;
const throughLink = await import("../../Sources/CodeIsland/Resources/codeisland-omp?omp-owner-link");

afterAll(async () => {
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  await new Promise<void>((resolve) => island.close(() => resolve()));
  rmSync(dir, { recursive: true, force: true });
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

/** One copy of the extension bound to a main OMP session; returns a way to fire its events. */
function load(extension: (pi: never) => void, sessionId: string) {
  const handlers = new Map<string, Handler>();
  extension({
    zod: { string: fakeSchema, number: fakeSchema, boolean: fakeSchema, array: fakeSchema, object: fakeSchema },
    pi: { AskTool: FakeAskTool, settings: {} },
    getSessionName: () => undefined,
    registerTool: () => undefined,
    on: (name: string, handler: Handler) => {
      handlers.set(name, handler);
    },
  } as never);
  const ctx = {
    cwd: "/repo",
    hasUI: false,
    sessionManager: { getSessionId: () => sessionId, getSessionFile: () => null, getEntries: () => [] },
    agent: { kind: "main", id: "Main", name: "main", depth: 0 },
  };
  return async (name: string, event: Record<string, unknown> = {}) => {
    await handlers.get(name)?.({ type: name, ...event }, ctx);
  };
}

const { socketIsOwnedByUser } = direct;
const uid = process.getuid!();
const stat = (isSocket: boolean, owner: number) => () => ({ isSocket: () => isSocket, uid: owner });

describe("socketIsOwnedByUser", () => {
  test("a socket this user owns", () => {
    expect(socketIsOwnedByUser(socketPath)).toBe(true);
    expect(socketIsOwnedByUser("/any", stat(true, uid), uid)).toBe(true);
  });

  test("another user's socket", () => {
    expect(socketIsOwnedByUser(socketPath, stat(true, uid + 1), uid)).toBe(false);
    // syslogd's, root's on every Mac.
    if (existsSync("/var/run/syslog") && lstatSync("/var/run/syslog").uid !== uid) {
      expect(socketIsOwnedByUser("/var/run/syslog")).toBe(false);
    }
  });

  test("not a socket: a symlink, even to ours, a file, a folder", () => {
    const file = join(dir, "file.sock");
    writeFileSync(file, "");
    expect(socketIsOwnedByUser(linkPath)).toBe(false);
    expect(socketIsOwnedByUser(file)).toBe(false);
    expect(socketIsOwnedByUser(dir)).toBe(false);
    expect(socketIsOwnedByUser("/any", stat(false, uid), uid)).toBe(false);
  });

  test("nothing there", () => {
    expect(socketIsOwnedByUser(join(dir, "missing.sock"))).toBe(false);
    const unreadable = () => {
      throw new Error("EACCES");
    };
    expect(socketIsOwnedByUser("/any", unreadable, uid)).toBe(false);
  });
});

describe("events", () => {
  test("reach a socket this user owns, and nothing goes through a symlink", async () => {
    await load(throughLink.default, "via-link")("session_start");
    await load(direct.default, "direct")("session_start");
    for (let i = 0; i < 300 && !received.some((p) => String(p.session_id).endsWith("direct")); i++) {
      await new Promise((r) => setTimeout(r, 10));
    }
    await new Promise((r) => setTimeout(r, 100));
    expect(received.length).toBe(1);
    expect(String(received[0].session_id)).toEndWith("direct");
  });
});
