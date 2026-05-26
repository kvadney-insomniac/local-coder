# local-coder-bot GitHub identity — setup checklist

Today the worker assigns issues to `${BOARD_OWNER:-your-github-handle}` (the operator's personal
account). To switch to a dedicated bot identity, complete these human-only
steps, then flip one env var.

1. Create GitHub account `local-coder-bot` with email `local-coder@example.com`.
2. Invite to org `YourProject-Hedge-Fund-Guy` with **write** access on `backend`
   and `frontend` repos.
3. Generate a PAT (or SSH key) for the bot; store it in macOS Keychain.
4. In `~/.zshrc` (or the overnight runner's exported env):
   ```bash
   export BOARD_ASSIGNEE=local-coder-bot
   ```
5. Verify: launch one worker, confirm the next claim assigns to
   `local-coder-bot` (`gh issue view <N> --json assignees`).

No code change needed — `BOARD_ASSIGNEE` is consumed by every
`add-assignee`/`remove-assignee` call in `board-lib.sh`.
