import { afterAll, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { createServer } from "net";
import { tmpdir } from "os";
import { join } from "path";

// The remote plugin hands every event to ~/.codeisland/codeisland-remote-hook.py
// on the SSH host, while the island's forwarded socket is there: a socket this
// user owns (sshd makes it as the login user). A stand-in hook in a temp HOME
// records what it would forward; a stand-in socket, never a real one, is the
// island's. The module reads both while loading.
const home = mkdtempSync(join(tmpdir(), "codeisland-remote-plugin-"));
const received = join(home, "received.jsonl");
const socketPath = join(home, "island.sock");
const island = createServer((sock) => sock.end());
await new Promise<void>((resolve) => island.listen(socketPath, resolve));

/** A HOME whose stand-in hook appends what it is handed to `out`. */
function standInHome(dir: string, out: string) {
  mkdirSync(join(dir, ".codeisland"));
  const hook = join(dir, ".codeisland", "codeisland-remote-hook.py");
  writeFileSync(hook, [
    "import sys",
    `with open(${JSON.stringify(out)}, "a") as out:`,
    "    out.write(sys.stdin.read() + \"\\n\")",
    "",
  ].join("\n"));
  chmodSync(hook, 0o755);
}
standInHome(home, received);

const saved = {
  HOME: process.env.HOME,
  CODEISLAND_SOCKET_PATH: process.env.CODEISLAND_SOCKET_PATH,
  CODEISLAND_SOCKET_OWNER_UID: process.env.CODEISLAND_SOCKET_OWNER_UID,
};
const restore = () => {
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
};
process.env.HOME = home;
process.env.CODEISLAND_SOCKET_PATH = socketPath;
const { default: plugin } = await import("../../Sources/CodeIsland/Resources/codeisland-opencode-remote.js");
restore();

afterAll(async () => {
  await new Promise<void>((resolve) => island.close(() => resolve()));
  rmSync(home, { recursive: true, force: true });
});

const forwarded = async (count: number) => {
  for (let i = 0; i < 200; i++) {
    if (existsSync(received)) {
      const lines = readFileSync(received, "utf8").trim().split("\n").filter(Boolean);
      if (lines.length >= count) return lines.map((line) => JSON.parse(line));
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error("the remote hook was not called");
};

describe("remote OpenCode plugin", () => {
  test("the generated title rides Stop as session_title, the key the island reads", async () => {
    const hooks = await plugin.server({ client: undefined, serverUrl: undefined });
    await hooks.event({ event: { type: "session.updated", properties: { info: { id: "s1", title: "Child session - 2026-10-09" } } } });
    await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "idle" } } } });
    await hooks.event({ event: { type: "session.updated", properties: { info: { id: "s1", title: "Fix the login form" } } } });
    await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "idle" } } } });

    const [placeholderStop, titledStop] = await forwarded(2);
    expect(placeholderStop.hook_event_name).toBe("Stop");
    expect(placeholderStop.session_title).toBeUndefined();
    expect(titledStop.hook_event_name).toBe("Stop");
    expect(titledStop.session_id).toBe("opencode-s1");
    expect(titledStop.session_title).toBe("Fix the login form");
    expect(titledStop.codex_title).toBeUndefined();
  });

  // The remote hook sends facts and the island keeps a cwd it is given, so
  // an unknown one is never "": it is the directory OpenCode runs in, which
  // the remote hook used to put in its place.
  test("a session with no known cwd reports the directory OpenCode runs in", async () => {
    const savedPwd = process.env.PWD;
    delete process.env.PWD;
    try {
      const hooks = await plugin.server({ client: undefined, serverUrl: undefined });
      await hooks.event({ event: { type: "session.created", properties: { info: { id: "s2" } } } });
      await hooks.event({ event: { type: "session.next.compaction.started", properties: { sessionID: "s2" } } });
      const events = await forwarded(4);
      const [start, compact] = events.slice(-2);
      expect(start.hook_event_name).toBe("SessionStart");
      expect(start.cwd).toBe(process.cwd());
      expect(compact.hook_event_name).toBe("PreCompact");
      expect(compact.session_id).toBe("opencode-s2");
      expect(compact.cwd).toBe(process.cwd());
      expect(compact._source).toBeUndefined();
      expect(compact._remote_host_id).toBeUndefined();
      // A pid of the remote host is not one the island can track.
      expect(compact._ppid).toBeUndefined();
    } finally {
      process.env.PWD = savedPwd;
    }
  });

  // Another user on the host could have created the socket path first; theirs
  // would get every event and could answer a permission request. Through a
  // symlink (connect() follows one, lstat does not) or to nothing at all, the
  // hook is never run.
  test("nothing is handed on unless the socket is this user's own", async () => {
    for (const [name, path] of [["link", join(home, "link.sock")], ["missing", join(home, "missing.sock")]]) {
      if (name === "link") symlinkSync(socketPath, path);
      const otherHome = join(home, name);
      mkdirSync(otherHome);
      const handedOn = join(otherHome, "received.jsonl");
      standInHome(otherHome, handedOn);
      process.env.HOME = otherHome;
      process.env.CODEISLAND_SOCKET_PATH = path;
      const { default: other } = await import(`../../Sources/CodeIsland/Resources/codeisland-opencode-remote.js?not-ours-${name}`);
      restore();

      const hooks = await other.server({ client: undefined, serverUrl: undefined });
      await hooks.event({ event: { type: "session.created", properties: { info: { id: `s-${name}` } } } });
      await hooks.event({ event: { type: "session.status", properties: { sessionID: `s-${name}`, status: { type: "idle" } } } });
      await new Promise((resolve) => setTimeout(resolve, 300));
      expect(existsSync(handedOn)).toBe(false);
    }
  });

  // On a host whose agents run as other users the installer names the SSH
  // user, who owns the island's socket (sshd made it): the plugin, run as
  // another user, uses that user's socket — and no one else's, its own user's
  // included — and tells the hook the same.
  test("the socket must be the named owner's when one is named", async () => {
    const uid = process.getuid!();
    for (const [name, owner, reaches] of [
      ["owner-is-named", String(uid), true],
      ["owner-is-another", String(uid + 1), false],
    ] as const) {
      const otherHome = join(home, name);
      mkdirSync(otherHome);
      mkdirSync(join(otherHome, ".codeisland"));
      const handedOn = join(otherHome, "received.jsonl");
      const hook = join(otherHome, ".codeisland", "codeisland-remote-hook.py");
      writeFileSync(hook, [
        "import json, os, sys",
        "sys.stdin.read()",
        `with open(${JSON.stringify(handedOn)}, "a") as out:`,
        "    out.write(json.dumps({'owner': os.environ.get('CODEISLAND_SOCKET_OWNER_UID')}) + \"\\n\")",
        "",
      ].join("\n"));
      chmodSync(hook, 0o755);
      process.env.HOME = otherHome;
      process.env.CODEISLAND_SOCKET_PATH = socketPath;
      process.env.CODEISLAND_SOCKET_OWNER_UID = owner;
      const { default: other } = await import(`../../Sources/CodeIsland/Resources/codeisland-opencode-remote.js?${name}`);
      restore();

      const hooks = await other.server({ client: undefined, serverUrl: undefined });
      await hooks.event({ event: { type: "session.created", properties: { info: { id: `s-${name}` } } } });
      await hooks.event({ event: { type: "session.status", properties: { sessionID: `s-${name}`, status: { type: "idle" } } } });
      if (!reaches) {
        await new Promise((resolve) => setTimeout(resolve, 300));
        expect(existsSync(handedOn)).toBe(false);
        continue;
      }
      for (let i = 0; i < 200 && !existsSync(handedOn); i++) {
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
      const first = JSON.parse(readFileSync(handedOn, "utf8").trim().split("\n")[0]);
      expect(first.owner).toBe(owner);
    }
  });

  // A plugin given the path older installs named, /tmp/codeisland-<uid>.sock,
  // checks the sockets the remote hook tries for it, in the hook's order: the
  // island's in that user's folder first, then the old path. With the island
  // in the folder and nothing at the old path, the hook still runs.
  test("the path an older install named finds the island in its folder", async () => {
    const number = String(3_300_000_000 + process.pid);
    const legacy = `/tmp/codeisland-${number}.sock`;
    const folder = `/tmp/codeisland-${number}`;
    mkdirSync(folder, { mode: 0o700 });
    const inFolder = createServer((sock) => sock.end());
    await new Promise<void>((resolve) => inFolder.listen(join(folder, "island.sock"), resolve));
    try {
      const otherHome = join(home, "older-install");
      mkdirSync(otherHome);
      const handedOn = join(otherHome, "received.jsonl");
      standInHome(otherHome, handedOn);
      process.env.HOME = otherHome;
      process.env.CODEISLAND_SOCKET_PATH = legacy;
      const { default: other } = await import("../../Sources/CodeIsland/Resources/codeisland-opencode-remote.js?older-install");
      restore();

      expect(existsSync(legacy)).toBe(false);
      const hooks = await other.server({ client: undefined, serverUrl: undefined });
      await hooks.event({ event: { type: "session.created", properties: { info: { id: "s-older" } } } });
      await hooks.event({ event: { type: "session.status", properties: { sessionID: "s-older", status: { type: "idle" } } } });
      // Within bun's 5 s test timeout, so a miss fails here and cleans up.
      for (let i = 0; i < 120 && !existsSync(handedOn); i++) {
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
      expect(existsSync(handedOn)).toBe(true);
    } finally {
      await new Promise<void>((resolve) => inFolder.close(() => resolve()));
      rmSync(folder, { recursive: true, force: true });
    }
  });
});
