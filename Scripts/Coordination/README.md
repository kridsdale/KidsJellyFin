# Local Agent Mail wake adapter

This user LaunchAgent observes local committed Agent Mail metadata through macOS
kqueue filesystem events. It has no timer, model polling, remote enrollment,
credentials, or Mail-server patch. It sends only message IDs and canonical Bead
IDs through `turn/start` with empty `input` and a named `toolOutput`. Peer text
remains untrusted data in Mail. The adapter never starts or resumes a chat,
starts an app server, restarts Desktop, or changes backend services.

## Install

Use the existing chat ID. The installer stages the adapter in the user's private
CodexAgentMail/wake directory and one user LaunchAgent. `--load` loads only that
watcher. Installation initializes the cursor past existing unread messages so
historical mail does not unexpectedly start model work. Existing state survives
reinstallation. No system LaunchDaemon, sudo, or administrator interaction is used.

```sh
python3 Scripts/Coordination/install.py --thread EXISTING_CHAT_ID --load
```

`status.json` reports `WAITING_FOR_DESKTOP_SOCKET` until a compatible listener
exists. Startup does not launch the missing server. `check` performs read-only
initialize and `thread/read` requests; it never calls `thread/resume`:

```sh
python3 "$HOME/Library/Application Support/CodexAgentMail/wake/agent_mail_wake.py" \
  --config "$HOME/Library/Application Support/CodexAgentMail/wake/config.json" check
```

## Future Desktop launch migration

The installed Desktop source explicitly checks
`CODEX_APP_SERVER_USE_LOCAL_DAEMON=1` when selecting transport. Its user daemon
must already be running and report a compatible version. It otherwise uses its
stdio app server, which cannot acquire a listener after startup. There must be
no forced CLI mode, explicit CLI override, or extra transport configuration.

After the existing Desktop exits naturally, these are the future user-level
commands. The installer does **not** execute them:

```sh
/opt/homebrew/bin/codex app-server daemon bootstrap
CODEX_APP_SERVER_USE_LOCAL_DAEMON=1 \
  /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
```

Open the existing chat normally in that Desktop. The adapter refuses an unloaded
chat. Do not start/resume an active chat from another server. This migration is
source-proven for the installed app, but requires live validation on a future
launch; installation is not proof of end-to-end wake success.

## Delivery and receipts

One coalesced batch is outstanding at a time. Before sending, the adapter
atomically records its message IDs and highest ID. Successful acceptance marks
the batch `accepted`; timeout/crash leaves `sending`. Either state prevents an
automatic resend or a second queued batch, including after process restart.
Subsequent mailbox events accumulate durably in Mail. Receipt by the owning chat
releases that gate and advances the cursor only after processing the batch:

```sh
python3 "$HOME/Library/Application Support/CodexAgentMail/wake/agent_mail_wake.py" \
  --config "$HOME/Library/Application Support/CodexAgentMail/wake/config.json" \
  receipt --through HIGHEST_MESSAGE_ID
```

The receipt must exactly match the outstanding batch. If sending was ambiguous,
inspect/process the named local Mail messages before receipt; there is no blind
retry. Receipts do not mark Mail read or acknowledge a peer message. Socket
creation, database/WAL writes, and receipt writes are event hints; committed
SQLite data and durable adapter state decide actual eligibility. Filesystem
hints are registered before reading, and registrations are rebuilt after each
hint so WAL rotation and newly created socket directories are handled.

The service does not restart on a timer after an unexpected fatal error. Inspect
its private status/stderr and reload this user LaunchAgent after repair. A stale
socket or rejected protocol waits for another real filesystem event.

## Unload and rollback

```sh
launchctl bootout "gui/$(id -u)/local.codex.agent-mail-wake"
```

Keep config/state and Mail data for recovery. The source and installer never
modify existing Mail data, permission settings, Desktop configuration, or
backend services. Remove only the new adapter LaunchAgent/files if desired.

## Short tests

```sh
python3 -m unittest discover -s Scripts/Coordination -p 'test_*.py' -v
```

Tests use a temporary Mail schema and a real temporary Unix WebSocket mock. They
verify metadata scoping, durable coalescing/receipts, ambiguous-send deduplication,
unloaded-chat refusal, socket gating, actual kqueue events, and protocol shape.
They do not invoke a model or claim live Desktop compatibility.
