# Domain docs

This is a single-context repository. Engineering skills consume one shared
domain vocabulary and architectural decision log for the Swift app and Python
ASR server.

## Before exploring

Read, when present:

1. `CONTEXT.md` at the repository root.
2. Relevant ADRs under `docs/adr/`.
3. `docs/plans/README.md` and the relevant feature plan under `docs/plans/`.

If `CONTEXT.md` or `docs/adr/` does not exist, proceed silently. Do not propose
empty placeholders. The `grill-with-docs` skill creates or updates them lazily
when terminology or architectural decisions are resolved.

## Layout

```text
/
├── CONTEXT.md
├── docs/
│   ├── adr/
│   ├── agents/
│   └── plans/
├── app/
└── server/
```

Do not create `CONTEXT-MAP.md` or per-component context files unless the
repository is deliberately migrated to a multi-context layout.

## Vocabulary

Use terms exactly as defined in `CONTEXT.md` in issues, plans, hypotheses,
tests, and implementation. If a required concept is missing, reconsider the
new terminology or flag it for `grill-with-docs`.

## Architectural decisions

Read ADRs touching the area before changing code. If work contradicts an ADR,
surface the conflict explicitly rather than silently overriding it.

Plans predate future ADRs. When an ADR and a plan disagree, the ADR wins unless
the decision is intentionally reopened and documented.
