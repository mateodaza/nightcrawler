# Task Queue — {Project Name}

> This file is consumed by Nightcrawler. Tasks are executed in order, respecting dependencies.
> Only Mateo adds or reorders tasks. Nightcrawler marks completion status.
> Tasks use stable IDs (NC-001, NC-002, etc.) that never change when tasks are reordered.

## Status Legend
- [ ] Queued — ready for Nightcrawler
- [~] In Progress (session: {session-id})
- [x] Completed (session: {session-id}, commit: {hash})
- [!] Blocked — needs manual action (see BLOCKERS.md)
- [?] Needs Clarification — escalated to Telegram
- [🔒] Locked — Opus/Codex disagreement, needs your decision
- [⛓️] DEP_BLOCKED — dependency is BLOCKED/SKIPPED/LOCKED, auto-skipped

## Tasks

#### NC-001 [ ] {Task title}
- **What:** {clear description of what to build}
- **Acceptance criteria:**
  - {criterion 1}
  - {criterion 2}
  - {criterion 3}
- **Dependencies:** None
- **Constraints:** {any specific rules for this task}
- **Files:** {expected files to create/modify, if known}

#### NC-002 [ ] {Task title}
- **What:** {description}
- **Acceptance criteria:**
  - {criterion}
- **Dependencies:** NC-001
- **Constraints:** {constraints}

#### NC-003 [ ] {Task title}
- **What:** {description}
- **Acceptance criteria:**
  - {criterion}
- **Dependencies:** NC-001, NC-002
- **Constraints:** {constraints}
