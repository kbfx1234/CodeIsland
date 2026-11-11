# Hook edge protocol

An *edge* is whatever sits between an AI coding agent's hook and the island:
`codeisland-bridge` on the Mac, the Python remote hook on SSH hosts, the
plugins (OpenCode, pi, Oh My Pi, OpenClaw), the community Windows bridge.

What a hook *means* — which agent sent it, which session, whether the agent
waits for an answer and in what form — is decided in one place:
`HookIntake` (`Sources/CodeIslandCore/HookIntake.swift`). The bridge runs it
itself. An edge that cannot run Swift sends the **facts** it observed instead,
and the island runs HookIntake on them when the payload arrives. A provider
quirk is then fixed once, in HookIntake, for every edge.

## Transport

- One Unix-domain stream connection per hook invocation, to
  `$CODEISLAND_SOCKET_PATH`, else `/tmp/codeisland-<uid>.sock` (on a remote
  host, the path the installer forwarded: `/tmp/codeisland-<uid>/island.sock`).
- On a remote host that socket sits in a folder of the SSH user's own,
  which the island makes on the host, as that user, before anything is
  forwarded there: 0700 — 0711 where agents run as other users, who may then
  reach the socket by name and nothing else — and checked to be that user's,
  that mode and no symlink, beneath a `/tmp` that does not let other users
  move it. sshd picks the forwarded socket's mode itself; in that folder it
  does not matter. Once the tunnel is up, the socket is checked too —
  waited for a while first, since sshd makes it a moment after ssh starts
  — and, where agents run as other users, made 0666 without following a
  symlink, before anything is installed; a folder or a socket that fails
  closes the tunnel, and the host says why. A hook command an older install
  wrote names `/tmp/codeisland-<uid>.sock`, and an agent started before the
  reinstall still runs it. The remote hook on the host is the one the
  newest island installed, and only such an island listens in the folder:
  for that command it tries `/tmp/codeisland-<uid>/island.sock` first, and
  the old path only where no island answers in the folder (nothing there,
  or the socket a finished tunnel left behind), for an older island that
  still forwards to it. Whatever else still listens at the old path — the
  tunnel of an older island whose app died, which forwards to a main socket
  that refuses it, or an sshd whose client is gone, which never answers —
  never takes the island's events. A host connected to two Macs of
  different versions at once gives these agents' events to the newer one.
- Only to a socket owned by the edge's own user, never through a symlink
  (`lstat`): the path is a predictable name in `/tmp`, and a socket another
  user created there first would get every event and could answer it. On a
  remote host the island's socket is sshd's, made as the SSH user; a host
  whose agents run as other users (containers, sudo) has the installer set
  `CODEISLAND_SOCKET_OWNER_UID` to the SSH user's uid in each hook command,
  and an edge then uses a socket that user owns instead. Once connected, the
  remote hook also asks the kernel who listens behind the socket
  (`SO_PEERCRED` on Linux and OpenBSD, `LOCAL_PEERCRED` on macOS and
  FreeBSD) and sends
  nothing unless it is that same user: sshd's forward listens as the SSH
  user. Where the platform has no way to ask, the `lstat` stands alone. The
  remote OpenCode plugin sends every event through the remote hook (Node
  gives a Unix socket's peer credentials no API).
- **The socket names the host, not the payload.** On the Mac, each remote
  host's forward ends at a socket the island bound for that host alone
  (`codeisland-hosts/h-<digest>.sock` in the user's own temporary folder,
  `/var/folders/…/T/`, which only the Mac's user can enter and nobody can
  make first; an island on a `$CODEISLAND_SOCKET_PATH` of its own keeps them
  in `<that path without .sock>-hosts/`), never at the main socket. Every
  request arriving there is filed under that host: its `_remote_host_id`,
  `_remote_host_name` and `_edge.host` are replaced with the host's own
  before anything reads them, so an edge that names another host, or none,
  changes nothing. A host with a blank id, which would be filed under no
  host at all, gets no socket and never connects. The
  main socket, which no remote edge reaches, answers a request that claims a
  remote host (a non-blank `_remote_host_id` or `_remote_host_name`, or an
  `_edge` with `host`) with nothing.
- A remote host's socket gives the host a bounded share of the island
  (`HookSocketLimits.remoteHost`), so whoever reaches the island's socket on
  that host cannot starve this Mac's hooks of descriptors, memory or cards: a
  request of at most 1 MB (this Mac's hooks keep 10 MB), complete within
  5 minutes however steadily it arrives, at most 64 connections open and
  32 requests waiting on an answer at once, and 8 MB of unfinished requests
  between them. A connection past that is closed at once; a request past
  the held cap, or over the size limit, is answered with nothing, so its
  agent asks in its own way (so is this Mac's request over its 10 MB). The
  remote hook sends text as it is, in UTF-8, not as `\uXXXX` escapes that
  would double a CJK request against that limit.
- Write one JSON object, then half-close the write side (`shutdown(SHUT_WR)`).
- A hook that waits for an answer (below) reads it to EOF, as long as it
  takes, prints it to stdout exactly as received (an empty answer means print
  nothing) and exits.
- A hook nobody waits on prints nothing. The island keeps the event of a hook
  that closed right after its half-close: it accepts and reads every
  connection off the main thread, however early its hook went. Older islands
  accepted connections on their main thread and lost such events, so a
  lifecycle event (a start, a prompt, a finished turn, a session end) reads
  the reply for a short while anyway (the remote hook 2 s, the bridge 1 s):
  losing one left a card behind. A tool step (an event that maps to
  `PreToolUse`, `PostToolUse` or `PostToolUseFailure`) may close at once: it
  fires on every tool call while the agent waits for the hook to exit, and a
  reply would add a round trip to each of them. An older island loses nearly
  every such step — its main thread reached the connection only after the
  hook had closed — so there the card shows neither the running tool nor
  the tool history; the lifecycle events, which read their reply, still keep
  the session's state right. Steps that close at once may also arrive out of
  order (a long `PostToolUse` after the next `PreToolUse`); the island tells
  them apart by their tool use id, where the agent gives one.
- If the island is not running, exit 0 silently.

## Payload

The agent's stdin object at the top level, plus `_edge`:

```json
{
  "hook_event_name": "PermissionRequest",
  "session_id": "c1a0de00-…",
  "tool_name": "Bash",
  "tool_input": { "command": "make" },
  "_edge": {
    "v": 1,
    "source": "claude",
    "cwd": "/home/dev/project",
    "tty": "/dev/pts/3",
    "host": { "id": "devbox", "name": "Dev Box" },
    "stdin_sha256": "9f2c…",
    "waits": true
  }
}
```

An edge changes the stdin object only to:

- add what only it can read, under the keys the island already knows (the
  remote hook adds transcript fields such as `last_assistant_message`, and
  `_hermes_store`);
- name, for islands that predate `_edge` (see *Older islands*), the host
  (`_remote_host_id`, `_remote_host_name`; an island that binds a socket
  per host takes the host from the socket instead) and the agent the hook
  was installed for (`_source`) — except under Claude Code's own hook, which
  Cursor runs too, where the island decides the source — unless the stdin
  names them already;
- drop a `_ppid` / `_hook_ppid` it is given: a pid of its machine is no
  process of the Mac's.

It adds no other `_` field (`_tty`, `_term_*`, `_via_plugin`, …): those are
HookIntake's.

### `_` fields a remote payload carries

The remote OpenCode plugin pipes its events through the remote hook with
fields of its own (`_tty`, `_env`, `_server_port`, and before v6 `_ppid`).
What the island does with an `_` field in a remote edge's payload:

| Field | |
|---|---|
| `_remote_host_id`, `_remote_host_name` | Replaced with the host whose socket the request arrived on: the session is filed under that host, whatever these say. On the Mac's main socket a request that sets either is refused. |
| `_source` | Under Claude Code's hook (`source: claude`), a supported one names the agent; one the island does not support is left, and the island drops the event, as it does the bridge's. Under any other `source`, the declared source wins. |
| `_tty` | Honoured as the session's terminal; the edge then sends no `tty`. |
| `_env` | Kept: the island reads terminal and multiplexer ids from it, as from a local plugin's. |
| `_hermes_store` | Honoured: the session's title and messages, read from the store on the remote host. |
| `_ppid`, `_hook_ppid` | Dropped: no process of another machine is tracked. |
| `_server_port` | Ignored: nothing reads it. |
| anything else | Passed on as sent. |

### `_edge` fields

| Field | Type | Meaning |
|---|---|---|
| `v` | int | Facts version, `1`. Fields are added without changing it. |
| `source` | string | The agent the hook was installed for (the bridge's `--source`). `claude` means Claude Code's own `settings.json` hook — which Cursor and other agents also run — so the payload decides, with Claude as the default. |
| `event` | string | The bridge's `--event`, for agents whose stdin names no event. |
| `cwd` | string | The hook process's working directory. Used when the payload has no `cwd`, or a blank one (after Grok's workspace root). |
| `tty` | string | The controlling terminal, if any. |
| `stdin_sha256` | hex string | SHA-256 of the stdin bytes exactly as the agent wrote them. Cursor runs two hooks per step with one stdin; the digest lets the island keep one (#377). |
| `waits` | bool | Whether this edge waits for the answer (see below). The island never holds a hook nobody waits on. |
| `host` | `{id, name}` | The machine the edge runs on: the id and name the island gave it (`CODEISLAND_REMOTE_HOST_ID` / `_NAME`). The island replaces it with the host whose socket the request arrived on before HookIntake reads it, and refuses a request with `host` on the main socket. Every edge that sends facts runs on another machine — on the Mac, the bridge reads its own facts and the plugins send their own interpretation — so whatever `host` says, or if it is missing or malformed, HookIntake tracks no pid for the hook and reads no home or file of the Mac to interpret it. |
| `env` | object | Only the variables in `HookIntake.environmentKeys` (terminal and multiplexer ids, `GROK_*`, `HERMES_HOME`, `CODEISLAND_SKIP`). Never anything else. Terminal ids of another machine are no use on the Mac: the remote hook sends no `env`. |
| `tmux_client_tty` | string | `tmux display-message -p -t $TMUX_PANE '#{client_tty}'`, if the edge ran it. |

Never send the argv of ancestor processes or more environment than listed,
nor a process id: no pid of another machine is one the island can track, and
`ppid` is not read.

## Waiting for the answer

Decide locally, from the stdin, so that no other hook pays a round trip, and
send the decision as `waits`. Wait if the event name (`hook_event_name`, else
`event`; an empty name is no name) is one of `PermissionRequest`,
`permission_request`, `BeforeTool`; or one of `Notification`, `notification`,
`afterAgentThought`, `errorOccurred` **and** `question` is a string.
Otherwise do not wait: read the reply for a short while only (*Transport*).

The island has the last word: a hook HookIntake does not hold — one Cursor
runs, whose stdout Cursor reads against its own schema — is answered at once
with nothing, and its edge prints nothing; a hook its edge does not wait on
(`waits: false`, whatever its event is spelled) gets no card. The answer it
does send is already in the form the agent reads (Gemini CLI and Google
Antigravity get `{"decision":"allow"|"deny"}`), so print it verbatim. Only
the user decides: a request the island drops for any other reason — its
agent got past it, its session ended — is answered `{}`, no decision, and
the agent asks in its own prompt.

One answer cannot wait for the island: Google Antigravity refuses a tool call
whose `PreToolUse` hook prints nothing, so the bridge prints
`{"decision":"ask"}` first, before anything can make it exit
(`HookIntake.immediateStdout`, #339). The island cannot give that answer for
an edge — it would come a round trip late — so an edge that serves
Antigravity prints it itself. The remote hook does not: the remote installer
wires no Antigravity hook.

## What the island derives

From the facts and the stdin, in this order (HookIntake is normative):

1. Dropped: `CODEISLAND_SKIP` set; inside Grok (`GROK_SESSION_ID` /
   `GROK_HOOK_EVENT`), any hook but Grok's own.
2. A non-blank `cursor_version` marks a hook Cursor ran: source `cursor`
   (or `cursor-cli` under cursor-agent) unless a source is declared, never
   held for an answer, `stdin_sha256` kept as the delivery digest.
3. Aliases, when `hook_event_name` is absent or empty: `hookEventName` /
   `eventName` / `event` / `--event` → `hook_event_name`; `sessionId`,
   `payload.session_id`, `data.session_id`, `conversationId` → `session_id`;
   `transcriptPath` → `transcript_path`. Copilot and Cline payload shapes are
   mapped by source.
4. Source: the declared one, else a supported `_source` in the payload, else
   Cursor's payload, else (bridge only) the process ancestry, else the
   default (an edge's `claude`: Claude) — unless the payload names a `_source`
   the island does not support, which is left for the island to drop. A hook
   the ancestry attributes to an agent other than Claude Code is another
   agent firing Claude Code's hook, marked `_via_plugin`.
5. Bridge only: `_ppid` (the long-lived agent process), and a
   `<source>-ppid-<pid>` session id when the agent sends none. An edge's
   payload loses any `_ppid` / `_hook_ppid`. A hook still without a session
   id is dropped.
6. Terminal context from `env`, `tty`, `cwd` (for an edge, a blank `cwd` is
   none: Grok's workspace root, else `_edge.cwd`, stands in);
   `_remote_host_id` / `_remote_host_name`: the host whose socket the
   request arrived on, stamped on the payload and on `host` before
   HookIntake runs.

## Compatibility

- A payload without `_edge` is its edge's own interpretation and is taken as
  it is: hooks installed before this protocol keep working unchanged.
- The Mac's end of a host's forward moved to the host's own socket, and the
  remote end from `/tmp/codeisland-<uid>.sock` into the SSH user's folder
  (`/tmp/codeisland-<uid>/island.sock`). Each connect reinstalls the remote
  hook and rewrites every hook command; an agent started before that still
  runs a command naming the old path, which the reinstalled hook takes to
  the folder (*Transport*). What a remote hook of any version names as its
  host is replaced by the socket's.
- An island reads another `v` for the fields it knows.
- Do not pipe facts through `codeisland-bridge`: it observes its own and
  drops an `_edge` it finds in its stdin.

## Older islands

Several Macs can share one remote host, and not all of them run an island
that reads `_edge`. An older island ignores `_edge` and takes the top level
as the edge's own interpretation, as it took the 0.3.1 remote hook's:

- It files the session under the host the top level names, with the source
  the top level names. That is why the remote hook names both there: without
  them, every remote session was a local Claude card. Under Claude Code's
  hook the remote hook names no source, so an older island shows Claude —
  also for a hook Cursor runs (the 0.3.1 hook named Cursor there).
- It takes that host from the payload, not from the socket: its forward ends
  at its main socket, so whatever reaches the forwarded socket can name any
  host, or none, and pass for a session of the Mac.
- It never sees a pid of the remote host: the remote hook drops one, and the
  remote OpenCode plugin sends none since v6. (A v5 plugin's `_ppid` reached
  an older island as a local process to monitor — and to SIGTERM as an
  orphan.)
- It reads the event and the session id only as HookEvent spells them
  (`hook_event_name` and a few camelCase forms; `session_id`, `sessionId`),
  none of HookIntake's other aliases, and a cwd only where the agent sent
  one: a remote event with none is dropped on a host with a cwd allow-list
  (#240). The 0.3.1 hook put its own directory in place of one.
- It holds a permission or a question by its own reading, and answers in its
  own form, which the remote hook prints verbatim: an agent that reads
  `{"decision": …}` (Gemini CLI) gets Claude Code's `hookSpecificOutput`
  instead.
- It accepts connections on its main thread, so it lost the event of a hook
  that had closed before it got there; the remote hook therefore reads its
  reply for a lifecycle event even when nothing waits on it (*Transport*).

## For the Windows bridge

The Windows port runs its own island, so it cannot hand facts to HookIntake.
It should follow the same rules — in particular rule 2 (Cursor runs Claude
Code's hooks; without it, Cursor's events show as Claude and every step that
both configs wire arrives twice) and the waiting rule above. The golden
fixtures in `Tests/CodeIslandCoreTests/BridgeGoldenFixtures.swift`, with the
output recorded in `BridgeGoldenExpectations.swift`, are worked examples for
every agent the bridge serves.
