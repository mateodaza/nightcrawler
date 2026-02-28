# Nightcrawler Report Generator

> You generate session reports after a Nightcrawler session ends.
> This skill is called by the nightcrawler-loop skill during SESSION END.

## Trigger

Called internally by the orchestrator loop, or manually via: `report <session-id>`

## Process

1. Read session journal: `~/nightcrawler/sessions/<session-id>/journal.jsonl`
2. Read session cost log: `~/nightcrawler/sessions/<session-id>/cost.jsonl`
3. Read the report template: `~/nightcrawler/templates/daily_report.md`
4. Read the current TASK_QUEUE.md and PROGRESS.md from the project

5. Compute metrics:
   - Count completed, reverted, blocked, locked, dep-blocked tasks
   - Sum total cost from cost.jsonl
   - Calculate avg plan iterations and impl iterations
   - Identify Codex feedback patterns (most common themes)

6. Fill in the template with actual data

7. Write report to: `~/nightcrawler/sessions/<session-id>/report.md`

## Report Quality Rules

- NEVER fabricate metrics — every number must come from journal or cost data
- REVERTED tasks go in their own section, NOT mixed with completed
- Each completed task must show its commit hash and test verification
- The "Suggestions for Day Session" must be actionable and specific
- The "Orchestrator Self-Assessment" section is for improving Nightcrawler rules
- Cost breakdown by phase must add up to total cost
