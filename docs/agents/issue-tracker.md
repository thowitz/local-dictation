# Issue tracker: GitHub

Issues and PRDs for this repo live in GitHub Issues at
`omcdowell/local-dictation`. Use the `gh` CLI for all operations.

## Conventions

- **Create:** `gh issue create --title "..." --body "..."`
- **Read:** `gh issue view <number> --comments`
- **List:** `gh issue list --state open --json number,title,body,labels,comments`
- **List immediately grabbable work:** `gh issue list --state open --label ready-for-agent --search '-label:blocked'`
- **Comment:** `gh issue comment <number> --body "..."`
- **Label:** `gh issue edit <number> --add-label "..."` or `--remove-label "..."`
- **Close:** `gh issue close <number> --comment "..."`

Infer the repository from `git remote -v`; `gh` does this automatically inside
the clone.

## Skill terminology

- When a skill says **publish to the issue tracker**, create a GitHub issue.
- When a skill says **fetch the relevant ticket**, run
  `gh issue view <number> --comments` and include its labels.

## Implementation plans

GitHub issues remain authoritative for scope, acceptance criteria, and workflow
state. Detailed implementation plans live in `docs/plans/` and link back to
issues #1–#5. Read `docs/plans/README.md` for their integration contract and
landing order.

If an issue and its plan disagree, surface the conflict and reconcile them
before implementation rather than silently choosing one.

A fully specified issue waiting on a predecessor uses `ready-for-agent` plus the
auxiliary `blocked` label. Its `## Blocked by` section names the dependency.
Remove `blocked` when that dependency lands; do not send the issue back through
`needs-triage` unless its specification actually needs maintainer evaluation.
