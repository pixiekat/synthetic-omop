# AGENTS.md

<!--
  Instructions for AI coding agents (Claude Code, GitHub Copilot, OpenAI Codex,
  Cursor, Gemini CLI, Aider, etc.) working in this repository.

  AGENTS.md is the cross-tool convention (https://agents.md). Tool-specific
  files point back here so the rules live in ONE place (DRY):
    - CLAUDE.md                        -> imports this file
    - .github/copilot-instructions.md  -> points to this file
    - .claude/settings.json            -> enforces the "ask first" rules below
                                          at the permission layer for Claude Code

  Humans: if you change a rule here, you don't need to touch the other files.
-->

These rules apply to **every contributor's agent**, not just the maintainer's.
If you cloned or forked this repo and use an AI assistant, it should follow
this file.

## 1. No unattended GitHub or git automation

The maintainer reviews every change by hand, for QA and so people learn from
it. An agent must **stop and get explicit confirmation from the human in the
current session** before it does any of the following. Approval for one
action does not cover the next one.

| Action                                     | Examples                                         |
| ------------------------------------------ | ------------------------------------------------ |
| Commit                                     | `git commit`, `git commit --amend`               |
| Push or rewrite remote history             | `git push`, `git push --force`, deleting branches |
| Open, edit, merge or close pull requests   | `gh pr create`, `gh pr merge`, web/API calls      |
| Open, edit, comment on or close issues     | `gh issue create`, `gh issue comment`             |
| Create releases, tags, or discussions      | `gh release create`, `git tag` + push             |
| Add or change CI / automation              | `.github/workflows/*`, bots, Dependabot, hooks    |
| Trigger remote runs                        | `gh workflow run`, scheduled agents, webhooks     |

**What to do instead:** make the change in the working tree, then summarise
it and suggest the commit message, PR title, or issue text. The human runs it
or says "go ahead".

**Do not** set up auto-commit, auto-PR, auto-issue, or auto-merge
behaviour (bots, Actions, cron jobs, agent "routines") unless a maintainer
explicitly asks for it.

## 2. Data and secrets

This project builds a **synthetic** OMOP CDM. Keep it that way.

- **Never commit `.env`.** Use `.env.example` for new variables, with
  placeholder values only.
- **Never commit anything under `data/` or `backups/`.** They are gitignored
  because the files are large, generated, or licensed (OHDSI Athena
  vocabularies, NSDUH terms of use). Do not use `git add -f` on them.
- **Never add real patient data (PHI/PII)** to the repo, issues, PRs, test
  fixtures, or prompts sent to external services.
- Do not paste credentials, tokens, or database dumps into issues or PRs.

## 3. Destructive commands need a confirmation too

Ask before running anything that throws away state, for example:

- `docker compose down -v` (deletes the database volumes)
- `git reset --hard`, `git clean -fd`, `git checkout -- .`
- dropping or truncating tables in `omop-db`

## 4. House style (short version)

- Follow `.editorconfig`: 2-space indents, LF line endings, 4 spaces for Python.
- Comment generously. Use docblocks (`@param`, `@return`, `@see`,
  `@deprecated`) on functions and logic blocks, and add short inline comments
  for anything not obvious.
- Docs are for mixed audiences: technical, but readable by non-technical
  project and QA folks. Long-form teaching material goes in `lessons/`.
  Assumptions and run notes go in `docs/`.
