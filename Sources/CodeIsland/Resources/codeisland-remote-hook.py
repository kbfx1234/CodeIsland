#!/usr/bin/env python3
# CodeIsland's hook on a remote host. It does not interpret the hook: it sends
# the agent's stdin as is, with what it observed in `_edge` (source, cwd, tty,
# host, a digest of the stdin), and the island reads both with HookIntake, the
# interpretation codeisland-bridge runs on the Mac (docs/hook-edge-protocol.md).
# What only this host can see — transcripts, the Hermes store — is read here.
# For islands that predate `_edge`, the host and the source are named at the
# top level too.
import hashlib
import json
import os
import socket
import stat
import struct
import subprocess
import sys

VERSION = "0.4.4"
# The `_edge` facts version (HookEdgeFacts.version on the island).
EDGE_FACTS_VERSION = 1
# Per-user socket path (#193): CodeIsland injects CODEISLAND_SOCKET_PATH via the hook
# command, but fall back to the uid-scoped path it forwards to, in the SSH user's own
# folder, so multiple users on a shared host never collide on one socket.
SOCKET_PATH = os.environ.get("CODEISLAND_SOCKET_PATH") or f"/tmp/codeisland-{os.getuid()}/island.sock"
# Who owns the island's socket here: sshd makes it as the SSH user. A hook run
# as that user, as hooks usually are, uses only a socket of its own user's. On
# a host whose agents run as other users (containers, sudo), the installer
# names the SSH user's uid in CODEISLAND_SOCKET_OWNER_UID: a hook run as
# another user then uses that user's socket, and still nobody else's.
_SOCKET_OWNER = os.environ.get("CODEISLAND_SOCKET_OWNER_UID", "").strip()
SOCKET_OWNER_UID = int(_SOCKET_OWNER) if _SOCKET_OWNER and all(c in "0123456789" for c in _SOCKET_OWNER) else os.getuid()
REMOTE_HOST_ID = os.environ.get("CODEISLAND_REMOTE_HOST_ID", "")
REMOTE_HOST_NAME = os.environ.get("CODEISLAND_REMOTE_HOST_NAME", "")
SOURCE = os.environ.get("CODEISLAND_SOURCE", "")
TIMEOUT_SECONDS = 300
# A blocking approval waits on a human, so it must not be capped at the
# fire-and-forget budget: the hook is registered with an 86400s timeout on the
# agent side, and a socket timeout of 5 minutes would silently drop the decision
# of anyone who stepped away (#306).
BLOCKING_TIMEOUT_SECONDS = 86400
# How long a hook nobody waits on waits for the island's reply (`{}`, or
# nothing), which normally takes one round trip over the SSH link. Short, so
# a busy island never holds up the agent long; within Codex's 3 s cap on its
# SessionEnd hook. A tool step doesn't wait at all (see _TOOL_STEP_EVENTS).
REPLY_TIMEOUT_SECONDS = 2
TRANSCRIPT_TAIL_BYTES = 262144


# Whether the hook waits for the island's answer: a permission request, or a
# question. Decided here so that no other hook waits on a round trip, and sent
# with the facts (`waits`): the island never holds a hook nobody waits on, and
# answers a hook it does not hold (one Cursor runs) at once, with nothing. The
# event names are those EventNormalizer maps to PermissionRequest and
# Notification.
_PERMISSION_EVENTS = {"PermissionRequest", "permission_request", "BeforeTool"}
_NOTIFICATION_EVENTS = {"Notification", "notification", "afterAgentThought", "errorOccurred"}


def _event_name(data):
    name = data.get("hook_event_name") or data.get("event")
    return name if isinstance(name, str) else None


def _waits_for_answer(data):
    name = _event_name(data)
    if name in _PERMISSION_EVENTS:
        return True
    return name in _NOTIFICATION_EVENTS and isinstance(data.get("question"), str)


# A tool step fires on every tool call, and the agent waits for the hook to
# exit before it goes on, so its hook does not stay for the island's reply: the
# island keeps the event of a hook that closed at once, and an older island
# losing one tool step is harmless. A lifecycle event (a start, a prompt, a
# finished turn, a session end) stays for it, so that an older island does not
# lose it and leave a card behind. The names are those EventNormalizer maps to
# PreToolUse, PostToolUse and PostToolUseFailure.
_TOOL_STEP_EVENTS = {
    "PreToolUse", "PostToolUse", "PostToolUseFailure",
    "preToolUse", "postToolUse",
    "pre_tool_use", "post_tool_use", "post_tool_use_failure",
    "pre_tool_call", "post_tool_call",
    "beforeShellExecution", "afterShellExecution", "beforeReadFile",
    "afterFileEdit", "beforeMCPExecution", "afterMCPExecution", "AfterTool",
}


def _stays_for_reply(data, waits):
    return waits or _event_name(data) not in _TOOL_STEP_EVENTS


def _claude_config_dir():
    """Claude Code's config dir: $CLAUDE_CONFIG_DIR when set, else ~/.claude (#271).

    The hook runs as a child of Claude Code, so the variable here is the one that
    Claude Code itself used — authoritative, with no fallback to ~/.claude when it
    is set. Same rules as _claude_config_dir() in the remote install script, and
    deliberately NO Unicode normalization: ext4/xfs are byte-preserving, so an
    NFC-normalized path can name a directory that does not exist.
    """
    raw = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip()
    if raw:
        expanded = os.path.expanduser(raw)
        if os.path.isabs(expanded) and expanded.strip("/") != "":
            return expanded
    return os.path.join(os.path.expanduser("~"), ".claude")


def _claude_jsonl_path(session_id, cwd):
    if not session_id or not cwd:
        return None
    project_dir = cwd.replace("/", "-").replace(".", "-")
    path = os.path.join(_claude_config_dir(), "projects", project_dir, f"{session_id}.jsonl")
    return path if os.path.exists(path) else None


def _codeisland_project_dir_encoded(cwd):
    return "".join("-" if ch == "/" or ch == " " or ord(ch) > 127 else ch for ch in cwd)


def _qoder_jsonl_path(session_id, cwd):
    if not session_id or not cwd:
        return None
    home = os.path.expanduser("~")
    project_dir = _codeisland_project_dir_encoded(cwd)
    path = os.path.join(home, ".qoder", "projects", project_dir, f"{session_id}.jsonl")
    return path if os.path.exists(path) else None


def _codebuddy_jsonl_path(session_id, cwd):
    if not session_id or not cwd:
        return None
    home = os.path.expanduser("~")
    project_dir = cwd.replace("/", "-").replace(".", "-")
    path = os.path.join(home, ".codebuddy", "projects", project_dir, f"{session_id}.jsonl")
    return path if os.path.exists(path) else None


def _extract_text(content):
    """Mirror of the Mac-side JSONLTailer.extractText: a bare string (minus any
    <USER_REQUEST> wrapper), or every `text` block of a content array joined by
    newlines. tool_use / tool_result / thinking blocks carry no chat text."""
    if isinstance(content, str):
        text = content
        start = text.find("<USER_REQUEST>")
        if start != -1:
            end = text.find("</USER_REQUEST>", start + len("<USER_REQUEST>"))
            if end != -1:
                text = text[start + len("<USER_REQUEST>"):end]
        return text.strip() or None
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
                text = block["text"].strip()
                if text:
                    parts.append(text)
        return "\n".join(parts) if parts else None
    return None


def _scan_session_jsonl(path):
    if not path:
        return {}

    summary = None
    first_user = None
    last_user = None
    last_assistant = None

    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    payload = json.loads(line)
                except Exception:
                    continue
                # isMeta rows (local-command caveats etc.) are not chat — the Mac
                # side skips them too.
                if not isinstance(payload, dict) or payload.get("isMeta") is True:
                    continue

                # Current Claude Code (and Qoder) rows nest the chat message:
                # {"type":"assistant","message":{"role":"assistant","content":[...]}}.
                # The older top-level {"role":..,"content":".."} shape stays as the
                # fallback. Same resolution as the Mac-side Claude transcript reader.
                msg_type = payload.get("type")
                message = payload.get("message")
                nested = isinstance(message, dict)
                if not nested:
                    message = payload
                role = message.get("role") or msg_type
                role = role.lower() if isinstance(role, str) else None
                content = message.get("content")

                if not nested and isinstance(content, str) and content.strip():
                    # Legacy shape only, unchanged: its summary / first prompt
                    # titles the session. Nested Claude rows never do — the Mac
                    # titles Claude sessions from custom-title / ai-title records,
                    # never from the first prompt.
                    if msg_type == "summary" and not summary:
                        summary = content
                    if role == "user" and not first_user:
                        first_user = content

                if role == "user":
                    text = _extract_text(content)
                    if text:
                        last_user = text
                elif role == "assistant":
                    text = _extract_text(content)
                    if not text and isinstance(message.get("thinking"), str):
                        text = message["thinking"].strip() or None
                    if text:
                        last_assistant = text
    except Exception:
        return {}

    return {
        "session_title": summary or first_user,
        "last_user_message": last_user,
        "last_assistant_message": last_assistant,
    }


def _scan_claude_jsonl(session_id, cwd):
    return _scan_session_jsonl(_claude_jsonl_path(session_id, cwd))


def _scan_qoder_jsonl(session_id, cwd):
    return _scan_session_jsonl(_qoder_jsonl_path(session_id, cwd))


def _scan_codebuddy_jsonl(session_id, cwd):
    return _scan_session_jsonl(_codebuddy_jsonl_path(session_id, cwd))


def _codex_public_text(payload, allow_agent_message=False):
    """Return only Codex text that is intended for the user-facing transcript."""
    if not isinstance(payload, dict):
        return None

    item_type = payload.get("type")
    if allow_agent_message and item_type == "agent_message":
        message = payload.get("message")
        return message.strip() if isinstance(message, str) and message.strip() else None

    blocks = None
    accepted_types = set()
    if item_type == "message" and payload.get("role") == "assistant":
        blocks = payload.get("content")
        accepted_types = {"output_text"}
    if not isinstance(blocks, list):
        return None
    parts = []
    for block in blocks:
        if not isinstance(block, dict) or block.get("type") not in accepted_types:
            continue
        text = block.get("text")
        if isinstance(text, str) and text.strip():
            parts.append(text.strip())
    return "\n".join(parts) if parts else None


def _scan_codex_jsonl(path):
    """Read a bounded rollout tail and return the current turn's public output."""
    if not isinstance(path, str) or not path.strip():
        return {}
    path = os.path.expanduser(path)
    if not os.path.isfile(path):
        return {}

    event_user_indices = []
    fallback_user_indices = []
    public_messages = []
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            start = max(0, size - TRANSCRIPT_TAIL_BYTES)
            handle.seek(start)
            if start:
                handle.readline()  # discard a partial JSONL record
            lines = handle.read().decode("utf-8", errors="ignore").splitlines()

        for index, line in enumerate(lines):
            try:
                record = json.loads(line)
            except Exception:
                continue
            record_type = record.get("type")
            payload = record.get("payload")
            if not isinstance(payload, dict):
                continue

            payload_type = payload.get("type")
            if record_type == "event_msg" and payload_type == "user_message":
                event_user_indices.append(index)
            elif (record_type == "response_item" and payload_type == "message"
                  and payload.get("role") == "user"):
                fallback_user_indices.append(index)

            if record_type == "event_msg" and payload_type == "agent_message":
                text = _codex_public_text(payload, allow_agent_message=True)
            elif record_type == "response_item":
                text = _codex_public_text(payload)
            else:
                text = None
            if text:
                public_messages.append((index, text))
    except Exception:
        return {}

    if not public_messages:
        return {}
    last_user_index = max(event_user_indices + fallback_user_indices, default=-1)
    output_index, output = public_messages[-1]
    if output_index <= last_user_index:
        return {}
    return {"last_assistant_message": output[:4000]}


HERMES_STORE_MESSAGE_BYTES = 65536
HERMES_NON_TEXT_PARTS = ("image", "image_url", "input_image", "audio", "input_audio")
HERMES_CONTENT_JSON_PREFIX = "\x00json:"


def _hermes_home():
    # Hermes runs every hook with the firing profile's HERMES_HOME.
    raw = (os.environ.get("HERMES_HOME") or "").strip()
    if raw:
        return os.path.expanduser(os.path.expandvars(raw))
    return os.path.join(os.path.expanduser("~"), ".hermes")


def _hermes_visible_text(value):
    return value if isinstance(value, str) and value.strip() else None


def _hermes_text_part(part):
    if isinstance(part, str):
        return part
    if not isinstance(part, dict):
        return None
    if str(part.get("type") or "").strip().lower() in HERMES_NON_TEXT_PARTS:
        return None
    for key in ("text", "content", "input_text", "output_text", "summary_text"):
        if isinstance(part.get(key), str):
            return part[key]
    return None


def _hermes_stored_text(content):
    """Mirror of HermesSessionStore.text(fromStoredContent:): structured content
    is stored as a "\\x00json:" prefix + JSON, of which only text parts show."""
    if not content.startswith(HERMES_CONTENT_JSON_PREFIX):
        return _hermes_visible_text(content)
    try:
        value = json.loads(content[len(HERMES_CONTENT_JSON_PREFIX):])
    except Exception:
        return None
    if isinstance(value, list):
        texts = [text for text in (_hermes_text_part(part) for part in value) if text]
        value = "\n".join(texts) if texts else None
    elif not isinstance(value, str):
        value = _hermes_text_part(value)
    return _hermes_visible_text(value)


def _scan_hermes_store(session_id):
    """Mirror of HermesSessionStore.read on the Mac: the session title and the
    newest visible prompt / reply from $HERMES_HOME/state.db, which no hook
    carries in full. Hermes writes that database (WAL) while it runs, so it is
    opened read-only, waits on a lock only briefly, and an unexpected schema
    just yields nothing."""
    path = os.path.join(_hermes_home(), "state.db")
    if not session_id or not os.path.isfile(path):
        return None
    try:
        import sqlite3
        from urllib.parse import quote
        conn = sqlite3.connect("file:" + quote(path) + "?mode=ro", uri=True, timeout=0.15)
    except Exception:
        return None
    try:
        def columns(table):
            return {row[1] for row in conn.execute("PRAGMA table_info(%s)" % table)}

        store = {}
        if {"id", "title"} <= columns("sessions"):
            row = conn.execute("SELECT title FROM sessions WHERE id = ? LIMIT 1", (session_id,)).fetchone()
            title = _hermes_visible_text(row[0]) if row else None
            if title:
                store["title"] = title
        message_columns = columns("messages")
        if {"id", "session_id", "role", "content"} <= message_columns:
            filters = ""
            if "active" in message_columns:
                filters += " AND active = 1"
            if "display_kind" in message_columns:
                filters += " AND COALESCE(display_kind, '') NOT IN ('hidden', 'internal_notification')"
            if "_compressed_summary" in message_columns:
                filters += " AND _compressed_summary = 0"
            for role in ("user", "assistant"):
                row = conn.execute(
                    "SELECT id, substr(CAST(content AS BLOB), 1, ?) FROM messages"
                    " WHERE session_id = ? AND role = ? AND content IS NOT NULL AND content <> ''"
                    + filters + " ORDER BY id DESC LIMIT 1",
                    (HERMES_STORE_MESSAGE_BYTES, session_id, role),
                ).fetchone()
                if not row:
                    continue
                raw = row[1]
                content = raw.decode("utf-8", "ignore") if isinstance(raw, bytes) else raw
                text = _hermes_stored_text(content) if isinstance(content, str) else None
                if text:
                    store[role] = {"id": row[0], "text": text}
        return store or None
    except Exception:
        return None
    finally:
        conn.close()


def _read_stdin():
    try:
        return sys.stdin.buffer.read()
    except Exception:
        return b""


def _parse_object(raw):
    try:
        data = json.loads(raw)
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def _socket_is_ours(path):
    """Whether `path` is a socket the island's user here owns: the SSH user
    CODEISLAND_SOCKET_OWNER_UID names, else this user (SOCKET_OWNER_UID). The
    path is a predictable name in /tmp, where any user on this host can create
    a socket first: theirs would get the event and could answer it. lstat, not
    stat: a symlink, even to the island's socket, stays its owner's to repoint,
    while a socket in sticky /tmp is its owner's alone to remove. sshd creates
    the island's forwarded socket as the SSH user."""
    try:
        info = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISSOCK(info.st_mode) and info.st_uid == SOCKET_OWNER_UID


def _peer_uid(sock):
    """The uid of whoever listens at the other end of the connected socket
    `sock`, as the kernel tells it — the credentials it had when it called
    listen(), which no file at the socket's path can change: Linux's
    SO_PEERCRED (a struct ucred: pid, uid, gid), OpenBSD's (a struct
    sockpeercred: uid, gid, pid), the LOCAL_PEERCRED of macOS and FreeBSD (a
    struct xucred, cr_uid after cr_version). None where the platform has no
    way to ask; -1, which is nobody's, when asking failed."""
    try:
        if sys.platform.startswith("linux") and hasattr(socket, "SO_PEERCRED"):
            creds = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("iII"))
            return struct.unpack("iII", creds)[1]
        if sys.platform.startswith("openbsd") and hasattr(socket, "SO_PEERCRED"):
            creds = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("IIi"))
            return struct.unpack("IIi", creds)[0]
        if sys.platform == "darwin" or sys.platform.startswith("freebsd"):
            level = getattr(socket, "SOL_LOCAL", 0)
            option = getattr(socket, "LOCAL_PEERCRED", 0x001)
            creds = sock.getsockopt(level, option, 256)
            return struct.unpack_from("=II", creds)[1]
    except (OSError, struct.error):
        return -1
    return None


def _peer_is_island(sock):
    """Whether the island's user here (SOCKET_OWNER_UID) listens at the other
    end of `sock`: sshd's forward, which listens as the SSH user. The lstat
    before connect() looked at a file; this is who answers through it. Where
    the platform cannot say, the lstat stands alone."""
    uid = _peer_uid(sock)
    return uid is None or uid == SOCKET_OWNER_UID


def _island_sockets():
    """The sockets to try, in order: SOCKET_PATH, the one the hook command
    names — but for the path older installs wrote into each command,
    /tmp/codeisland-<uid>.sock, where the island forwarded before its socket
    had a folder of its own. An agent started before this host's hooks were
    reinstalled still runs that command, and this script is the one the
    newest island installed: that user's socket in its folder,
    /tmp/codeisland-<uid>/island.sock, where only such an island listens,
    comes first. The old path comes after it, for an older island that still
    forwards there while the folder has no tunnel (nothing there, or the
    socket a finished tunnel left behind, which sshd never removes). So
    whatever else still listens at the old path never takes the island's
    events: a tunnel an older island left running when its app died, which
    forwards to a Mac's main socket that refuses them now, or an sshd whose
    client is gone, which never answers. A host connected to two Macs of
    different versions at once gives these agents' events to the newer."""
    folder, name = os.path.split(SOCKET_PATH)
    prefix, suffix = "codeisland-", ".sock"
    if folder != "/tmp" or not name.startswith(prefix) or not name.endswith(suffix):
        return [SOCKET_PATH]
    uid = name[len(prefix):-len(suffix)]
    if not uid or not all(c in "0123456789" for c in uid):
        return [SOCKET_PATH]
    return ["/tmp/codeisland-%s/island.sock" % uid, SOCKET_PATH]


def _connect_to_island():
    """A socket connected to the island: the first of _island_sockets() that
    is the island's user's (_socket_is_ours), takes the connection, and has
    that user listening behind it (_peer_is_island). None when none does."""
    for path in _island_sockets():
        if not _socket_is_ours(path):
            continue
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(path)
            if _peer_is_island(sock):
                return sock
        except (OSError, socket.error):
            pass
        try:
            sock.close()
        except Exception:
            pass
    return None


def _wire(payload):
    """The payload as it is sent: in UTF-8 as it is — `\\uXXXX` escapes would
    double a CJK text against the island's limit on a remote host's request —
    or escaped where it cannot be (a lone surrogate)."""
    try:
        return json.dumps(payload, ensure_ascii=False).encode("utf-8")
    except UnicodeEncodeError:
        return json.dumps(payload).encode("utf-8")


def _send_event(payload, expects_response, stays_for_reply=True):
    """Sends the event and reads the island's reply to EOF; returns the reply
    when the hook waits for one. A hook nobody waits on reads it too, for a
    short while, unless it is a tool step (`stays_for_reply`, see
    _TOOL_STEP_EVENTS): an older island, which accepted connections on its main
    thread, lost the event of a hook that had closed before it got there.
    Nothing is sent to a socket the island's user does not own, nor to one
    whose listener is not that user: as if the island were not there."""
    sock = _connect_to_island()
    if sock is None:
        return None
    sock.settimeout(BLOCKING_TIMEOUT_SECONDS if expects_response else TIMEOUT_SECONDS)
    try:
        sock.sendall(_wire(payload))
        sock.shutdown(socket.SHUT_WR)
        if not expects_response:
            if not stays_for_reply:
                return None
            sock.settimeout(REPLY_TIMEOUT_SECONDS)
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
        response = b"".join(chunks)
        return response.decode("utf-8") if expects_response and response else None
    except (OSError, socket.error):
        # Socket may not exist or server may have shut down — fail silently (#45)
        return None
    finally:
        try:
            sock.close()
        except Exception:
            pass


def _get_tty():
    pid = os.getppid()
    for _ in range(20):
        if pid <= 1:
            break
        try:
            result = subprocess.run(
                ["ps", "-p", str(pid), "-o", "tty=,ppid="],
                capture_output=True,
                text=True,
                timeout=2,
            )
            parts = result.stdout.strip().split()
            if not parts:
                break
            tty = parts[0]
            if tty and tty not in {"??", "-"}:
                return tty if tty.startswith("/dev/") else f"/dev/{tty}"
            if len(parts) >= 2:
                pid = int(parts[1])
            else:
                break
        except Exception:
            break
    return None


def _getcwd():
    try:
        return os.getcwd()
    except OSError:
        return None


def _edge_facts(raw, data, waits):
    """What this hook observed, for the island to interpret (HookEdgeFacts)."""
    edge = {
        "v": EDGE_FACTS_VERSION,
        "source": SOURCE,
        "host": {"id": REMOTE_HOST_ID, "name": REMOTE_HOST_NAME},
        "stdin_sha256": hashlib.sha256(raw).hexdigest(),
        "waits": waits,
    }
    cwd = _getcwd()
    if cwd:
        edge["cwd"] = cwd
    # A payload that names its terminal already (the remote OpenCode plugin's)
    # spares the process walk.
    if not data.get("_tty"):
        tty = _get_tty()
        if tty:
            edge["tty"] = tty
    return edge


def _for_islands_without_facts(payload):
    """An island that predates `_edge` reads the top level only: name this host
    there (a host the payload names stands, here and on the island), and the
    agent the hook was installed for — except Claude Code's own hook, which
    Cursor runs too (#377), so the island decides that one from the payload.
    A process id of this host is never sent: no island can track it, and one
    that took it for a local pid (an older island filing a session without a
    host) would monitor, and could signal, an unrelated process of its own."""
    for key in ("_ppid", "_hook_ppid"):
        payload.pop(key, None)
    if REMOTE_HOST_ID and not payload.get("_remote_host_id"):
        payload["_remote_host_id"] = REMOTE_HOST_ID
    if REMOTE_HOST_NAME and not payload.get("_remote_host_name"):
        payload["_remote_host_name"] = REMOTE_HOST_NAME
    if SOURCE and SOURCE != "claude" and not payload.get("_source"):
        payload["_source"] = SOURCE


def _merge_extras(payload, extras, event_name):
    for key, value in extras.items():
        if value and not payload.get(key):
            payload[key] = value
    if event_name == "UserPromptSubmit" and not payload.get("prompt"):
        prompt = extras.get("last_user_message")
        if prompt:
            payload["prompt"] = prompt


def main():
    if "--version" in sys.argv:
        print(VERSION)
        return 0

    raw = _read_stdin()
    data = _parse_object(raw)
    if not data:
        return 1

    event_name = _event_name(data)
    session_id = data.get("session_id")
    cwd = data.get("cwd") or _getcwd()
    payload = dict(data)

    # What only this host can read: the agent's transcript, Hermes's store.
    if SOURCE == "claude":
        _merge_extras(payload, _scan_claude_jsonl(session_id, cwd), event_name)

    if SOURCE == "qoder":
        _merge_extras(payload, _scan_qoder_jsonl(session_id, cwd), event_name)

    if SOURCE == "codebuddy":
        _merge_extras(payload, _scan_codebuddy_jsonl(session_id, cwd), event_name)

    if SOURCE == "codex" and event_name not in {"SessionStart", "UserPromptSubmit"}:
        extras = _scan_codex_jsonl(payload.get("transcript_path"))
        if extras.get("last_assistant_message") and not payload.get("last_assistant_message"):
            payload["last_assistant_message"] = extras["last_assistant_message"]

    if SOURCE == "hermes":
        # The whole conversation rides along on every pre/post_llm_call; the
        # Mac never reads it, so it doesn't cross the SSH link.
        extra = payload.get("extra")
        if isinstance(extra, dict) and "conversation_history" in extra:
            payload["extra"] = {k: v for k, v in extra.items() if k != "conversation_history"}
        store = _scan_hermes_store(session_id)
        if store:
            payload["_hermes_store"] = store

    _for_islands_without_facts(payload)
    waits = _waits_for_answer(data)
    payload["_edge"] = _edge_facts(raw, data, waits)
    response = _send_event(payload, waits, _stays_for_reply(data, waits))
    # The island sends the answer as the agent reads it (Gemini's decision
    # included), or nothing when there is none to give.
    if response:
        print(response)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
