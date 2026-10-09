# AgentBar

A black island at the top center of the screen, around the notch. It lists every live Claude Code
session and the codex runs each session dispatched.

- Pill: busy sessions on the left of the notch, total sessions and codex runs on the right.
- Hover the island to open it. Move the pointer off to close it.
- Rows are sorted by your last message, newest first. Each row shows the first 90 characters, the folder and the message age.
- Sessions with no typed message are hidden. The theme follows the system light or dark setting.
- Rest the pointer on a row to grow it: it shows your full message, its codex runs and the last reply of each run.
- Click a row to focus that session's kitty window.
- Codex runs are hidden until the row grows. The row shows a gear count when it has runs.
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
