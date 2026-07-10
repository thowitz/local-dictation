# Triage labels

The engineering skills use five canonical triage roles. This table maps each
role to the exact GitHub label used by this repository.

| Canonical role | GitHub label | Meaning |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | Maintainer needs to evaluate this issue |
| `needs-info` | `needs-info` | Waiting on the reporter |
| `ready-for-agent` | `ready-for-agent` | Fully specified and ready for an AFK agent |
| `ready-for-human` | `ready-for-human` | Requires human implementation |
| `wontfix` | `wontfix` | Will not be actioned |

When a skill refers to a role such as “AFK-ready,” use the corresponding label
from this table. Do not substitute generic labels such as `help wanted`,
`question`, or `good first issue`.

Every triaged issue carries exactly one canonical state label. Dependency state
is represented separately.

## Auxiliary coordination labels

| Label | Meaning |
| --- | --- |
| `blocked` | Fully specified but cannot start until its documented dependency is resolved |

`blocked` does not replace a canonical state. A fully specified dependent issue
uses both `ready-for-agent` and `blocked`; remove only `blocked` when its
prerequisite lands. Queries for immediately grabbable work must select
`ready-for-agent` while excluding `blocked`.
