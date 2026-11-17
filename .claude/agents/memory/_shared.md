# Shared lessons

- The production-safety Bash hook blocks any command that contains `rm ` plus any flag with the letter `r` and any flag with the letter `f`, anywhere in the same command (for example `rm file; terraform init -migrate-state -force-copy`). Rule: run `rm` in its own Bash call, with no other flags. Evidence: two blocked calls on 2026-11-18 during the bootstrap state migration; the single `rm <file>` call passed.
- Cloud Domains does not support `.click`. Rule: check a domain ending with `gcloud domains registrations get-register-parameters <name>` before you offer it. Evidence: `availability: UNSUPPORTED` on 2026-11-18.
- `git add -A` staged an agent worktree under `.claude/worktrees/` as an embedded repository. Rule: `.claude/worktrees/` stays in `.gitignore`; read `git status --short` before the commit, not after. Evidence: commit on 2026-11-18 contained the gitlink; removed in the next commit.
