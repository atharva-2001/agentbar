# AgentBar

A black island at the top center of the screen, around the notch. It lists every live Claude Code
session and the codex runs each session dispatched.

- Pill: busy sessions on the left of the notch, total sessions and codex runs on the right.
- Hover the island to open it. Move the pointer off to close it.
- Each row shows your last message (first 90 characters) and the session folder.
- Hover the bubble icon to see the full message. For a codex run, it shows the last codex reply.
- Click a row to focus that session's kitty window.
- Codex rows show run time and the age of the last rollout write. After 12 minutes with no write the
  row turns orange (the RUNBOOK_CODEX stall rule).

Sources: `~/.claude/sessions/*.json`, `~/.claude/projects/*/<session>.jsonl`, `ps`, `~/.codex/run-owners/`,
and the codex rollout found with `lsof`.

```sh
./build.sh          # build AgentBar.app
./build.sh test     # parser self-check
open AgentBar.app
AgentBar.app/Contents/MacOS/AgentBar --dump   # print the scan as text
```

Focus works through the session tty: kitty has `allow_remote_control yes` but no `listen_on` socket.
