#!/usr/bin/env bash
# start.sh — Pre-flight + launch wrapper for nightcrawler.sh
# Handles all cleanup so "start clout --budget 15" works from phone via OpenClaw.
#
# Usage: start.sh <project> [--budget N] [--dry-run]

set -euo pipefail

PROJECT="${1:?Usage: start.sh <project> [--budget N] [--dry-run]}"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
PROJECT_PATH="${NIGHTCRAWLER_PROJECT_PATH:-/home/nightcrawler/projects/$PROJECT}"
LOCKFILE="/tmp/nightcrawler-${PROJECT}.lock"
CONTROL_DIR="/tmp/nightcrawler/${PROJECT}"

# --- Pre-flight checks ---

# 1. Project exists
if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "FATAL: Project directory not found: $PROJECT_PATH"
    exit 1
fi

# 2. Clear stale lock — only if no live process holds it
if [[ -f "$LOCKFILE" ]]; then
    if flock -n "$LOCKFILE" true 2>/dev/null; then
        echo "Cleared stale lock file"
        rm -f "$LOCKFILE"
    else
        echo "FATAL: Another session is actively running (lock held by live process)"
        exit 1
    fi
fi

# 3. Clear skip file from previous sessions
if [[ -f "$CONTROL_DIR/skip" ]]; then
    echo "Cleared skip file ($(wc -l < "$CONTROL_DIR/skip") entries)"
    rm -f "$CONTROL_DIR/skip"
fi

# 4. Ensure .claude/CLAUDE.md exists for Claude Code CLI context
if [[ ! -f "$PROJECT_PATH/.claude/CLAUDE.md" ]]; then
    echo "Creating .claude/CLAUDE.md for project context"
    mkdir -p "$PROJECT_PATH/.claude"
    cat > "$PROJECT_PATH/.claude/CLAUDE.md" << 'CLAUDEEOF'
# Clout — Solidity/Foundry Project

## Key Files
- RESEARCH.md — canonical struct definitions, state machine, and protocol spec
- GLOBAL_PLAN.md — overall architecture and task sequencing
- foundry.toml — Solidity config (check version here)
- src/ — production contracts
- test/ — Foundry tests

## Rules
- Match the pragma version in foundry.toml
- Follow OpenZeppelin patterns (ReentrancyGuard, Ownable, IERC20)
- All amounts use 6 decimals (stablecoin native)
- Read RESEARCH.md before planning any contract — it's the source of truth for structs and state machines
- Named imports only (`import {X} from "..."`)
- Read memory.md if it exists for project patterns
CLAUDEEOF
fi

# 5. Ensure .claude/settings.json exists for Claude Code CLI permissions
if [[ ! -f "$PROJECT_PATH/.claude/settings.json" ]]; then
    echo "Creating .claude/settings.json for tool permissions"
    cat > "$PROJECT_PATH/.claude/settings.json" << 'SETTINGSEOF'
{
  "permissions": {
    "allow": [
      "Bash(forge *)",
      "Bash(cast *)",
      "Bash(cat *)",
      "Bash(ls *)",
      "Bash(find *)",
      "Bash(mkdir *)",
      "Bash(cp *)",
      "Bash(mv *)",
      "Bash(head *)",
      "Bash(tail *)",
      "Bash(wc *)",
      "Bash(diff *)",
      "Bash(git status*)",
      "Bash(git diff*)",
      "Bash(git log*)",
      "Read",
      "Write",
      "Edit",
      "Glob",
      "Grep"
    ],
    "deny": [
      "Bash(curl*)",
      "Bash(wget*)",
      "Bash(ssh*)",
      "Bash(scp*)",
      "Bash(git push*)",
      "Bash(git reset*)",
      "Bash(sudo*)",
      "Bash(rm -rf /*)",
      "Bash(rm -rf ~*)",
      "Bash(chmod 777*)",
      "Bash(pkill*)",
      "Bash(kill*)"
    ]
  }
}
SETTINGSEOF
fi

# 6. Ensure Solidity/Foundry skill exists for Claude Code CLI
SKILL_DIR="$PROJECT_PATH/.claude/skills/solidity-foundry"
if [[ ! -f "$SKILL_DIR/SKILL.md" ]]; then
    echo "Creating Solidity/Foundry skill"
    mkdir -p "$SKILL_DIR"
    cat > "$SKILL_DIR/SKILL.md" << 'SKILLEOF'
---
name: solidity-foundry
description: Solidity smart contract development with Foundry. Use when writing, modifying, testing, or reviewing Solidity contracts.
user-invocable: false
---

# Solidity/Foundry Development Guide

## Before Writing Any Code

1. Read `RESEARCH.md` — it is the source of truth for struct definitions, state machines, and protocol spec
2. Read `foundry.toml` — match the pragma version exactly
3. Check existing contracts in `src/` — understand what's already built
4. Check existing tests in `test/` — follow established patterns

## Solidity Conventions

### Imports
- Named imports ONLY: `import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";`
- Never use wildcard imports

### Types & Precision
- All monetary amounts use 6 decimals (stablecoin native, NOT 18)
- Use `uint256` for amounts, `uint64` for timestamps
- Define constants for magic numbers: `uint256 constant PRECISION = 1e6;`

### Security Patterns (MANDATORY)
- Checks-Effects-Interactions (CEI) pattern on every external call
- `ReentrancyGuard` on all functions that transfer tokens
- `SafeERC20` for all token transfers (`safeTransfer`, `safeTransferFrom`)
- Never use raw `.call{value:}` for token transfers
- Validate all inputs at function entry (require statements first)
- Access control on all state-changing functions (`onlyOwner`, role-based, or custom)

### Code Style
- Events for every state change (emit before external calls in CEI)
- NatSpec documentation on public/external functions
- Custom errors over require strings: `error Unauthorized();`
- Group functions: external → public → internal → private

## Foundry Testing

### Running Tests
```bash
forge build          # compile
forge test -v        # run all tests (verbose)
forge test -vvvv     # trace-level debugging
forge test --match-test testSpecificFunction  # single test
```

### Test Structure
```solidity
contract MyContractTest is Test {
    MyContract public target;

    function setUp() public {
        // Deploy contracts, set initial state
    }

    function test_normalCase() public {
        // Test happy path
    }

    function test_RevertWhen_InvalidInput() public {
        vm.expectRevert(MyContract.InvalidInput.selector);
        target.doSomething(0);
    }

    function testFuzz_Amount(uint256 amount) public {
        amount = bound(amount, 1, 1e12); // bound to reasonable range
        // Test with fuzzed input
    }
}
```

### Key Forge Cheatcodes
- `vm.prank(address)` — next call from address
- `vm.startPrank(address)` / `vm.stopPrank()` — multiple calls
- `vm.expectRevert(selector)` — expect revert
- `vm.expectEmit(true, true, false, true)` — expect event
- `vm.warp(timestamp)` — set block.timestamp
- `deal(token, address, amount)` — set token balance
- `bound(value, min, max)` — constrain fuzz input

### What to Test
1. Happy path for every function
2. Access control (unauthorized callers revert)
3. Edge cases (zero amounts, max values, empty arrays)
4. State transitions (verify enum state changes)
5. Reentrancy (if applicable)
6. Event emissions

## Common Mistakes to Avoid
- Using 18 decimals instead of 6
- Forgetting reentrancy guard on token transfer functions
- Not reading RESEARCH.md before implementing structs
- Creating contracts not in the plan
- Modifying files outside the plan's scope
- Using `transfer()` instead of `safeTransfer()`
- Missing access control on admin functions
SKILLEOF
fi

# 7. Ensure security-review skill exists
SKILL_DIR="$PROJECT_PATH/.claude/skills/security-review"
if [[ ! -f "$SKILL_DIR/SKILL.md" ]]; then
    echo "Creating security-review skill"
    mkdir -p "$SKILL_DIR"
    cat > "$SKILL_DIR/SKILL.md" << 'SKILLEOF'
---
name: security-review
description: Smart contract security review checklist. Use when reviewing Solidity code for vulnerabilities, before committing, or when auditing contracts.
user-invocable: false
---

# Smart Contract Security Review

## Critical Checks (MUST pass)

### Reentrancy
- All external calls follow CEI (Checks-Effects-Interactions)
- `ReentrancyGuard` on functions with token transfers
- No state reads after external calls that could be manipulated
- Cross-function reentrancy: check if multiple functions share mutable state

### Access Control
- Every state-changing function has access control
- Owner/admin functions use `onlyOwner` or role-based modifiers
- Initialization functions can only be called once
- No unprotected `selfdestruct` or `delegatecall`

### Integer Safety
- Solidity 0.8+ overflow protection is active (no `unchecked` without justification)
- Division before multiplication avoided (precision loss)
- All amounts use consistent decimals (6 for stablecoins)
- `bound()` used in fuzz tests to constrain inputs

### Token Handling
- `SafeERC20` for all transfers
- Return values checked (or use safeTransfer)
- Approve race condition handled (approve 0 first, or use increaseAllowance)
- No assumption about token decimals — read from contract or use constant

### State Machine
- All transitions validated against RESEARCH.md state diagram
- No skippable states
- Expired/timed-out states handled
- Cannot re-enter completed states

## Gas & Efficiency
- Storage reads minimized (cache in memory)
- Mappings preferred over arrays for lookups
- Events indexed on commonly-filtered fields (max 3 indexed per event)
- No unbounded loops over dynamic arrays
SKILLEOF
fi

# 8. Ensure TypeScript/frontend skill exists (for future frontend work)
SKILL_DIR="$PROJECT_PATH/.claude/skills/typescript-frontend"
if [[ ! -f "$SKILL_DIR/SKILL.md" ]]; then
    echo "Creating TypeScript/frontend skill"
    mkdir -p "$SKILL_DIR"
    cat > "$SKILL_DIR/SKILL.md" << 'SKILLEOF'
---
name: typescript-frontend
description: TypeScript and React frontend development. Use when writing TypeScript, React components, hooks, or frontend application code.
user-invocable: false
---

# TypeScript & Frontend Development

## TypeScript Conventions
- Strict mode always (`"strict": true` in tsconfig)
- Explicit return types on exported functions
- Use `interface` for object shapes, `type` for unions/intersections
- Prefer `readonly` properties where mutation isn't needed
- No `any` — use `unknown` and narrow with type guards
- Null safety: use optional chaining (`?.`) and nullish coalescing (`??`)

## React Patterns
- Functional components only (no class components)
- Custom hooks for shared logic (`use` prefix)
- `useMemo` / `useCallback` only when there's a measured performance need
- Colocate state as close to where it's used as possible
- Extract complex logic into hooks, keep components focused on rendering

## Web3 Frontend (Wagmi/Viem)
- Use `viem` for contract interactions (not ethers.js)
- Use `wagmi` hooks for React integration (`useReadContract`, `useWriteContract`)
- Always handle: loading, error, and success states for transactions
- Show transaction hash and link to explorer after submission
- Handle chain switching and wallet connection errors gracefully
- Parse contract amounts with correct decimals (6 for stablecoins)

## Testing
```bash
npm test              # run test suite
npm run type-check    # TypeScript compilation check
npm run lint          # ESLint
```

## Common Mistakes
- Importing from wrong package (wagmi v2 vs v1 APIs differ significantly)
- Not awaiting transaction confirmation before updating UI
- Using `Number` for big token amounts (use `BigInt` or viem's `parseUnits`)
- Missing error boundaries around Web3 components
SKILLEOF
fi

# 9. Ensure code-quality skill exists
SKILL_DIR="$PROJECT_PATH/.claude/skills/code-quality"
if [[ ! -f "$SKILL_DIR/SKILL.md" ]]; then
    echo "Creating code-quality skill"
    mkdir -p "$SKILL_DIR"
    cat > "$SKILL_DIR/SKILL.md" << 'SKILLEOF'
---
name: code-quality
description: Code quality and review standards. Use when implementing features, reviewing code, or making architectural decisions.
user-invocable: false
---

# Code Quality Standards

## Implementation Discipline
- Implement EXACTLY what the plan says — no more, no less
- Do not add features, utilities, or abstractions not in the plan
- Do not refactor surrounding code unless the plan calls for it
- Do not create "helper" or "probe" contracts/files outside the plan
- If something seems missing from the plan, implement what's there — the auditor will catch gaps

## Git Hygiene
- Every file you modify must be justified by the plan
- Do not modify config files unless the plan requires it
- Do not add or remove dependencies without plan approval
- Keep changes minimal and focused

## Testing Standards
- Every public function needs at least one test
- Test the happy path AND the revert cases
- Fuzz tests for any function that takes numeric input
- Test names describe what they verify: `test_RevertWhen_CallerNotOwner`
- Tests must be deterministic — no randomness without `bound()`

## Error Handling
- Custom errors over require strings (gas efficient, clearer)
- Error names describe the condition: `error InsufficientBalance(uint256 required, uint256 available);`
- Validate inputs at function boundaries, trust internal calls
- Never silently swallow errors

## Documentation
- NatSpec on all public/external functions
- @param and @return for every parameter
- @notice for user-facing description
- @dev for implementation notes only when non-obvious
SKILLEOF
fi

# 10. Ensure Ponder indexer skill exists
SKILL_DIR="$PROJECT_PATH/.claude/skills/ponder-indexer"
if [[ ! -f "$SKILL_DIR/SKILL.md" ]]; then
    echo "Creating Ponder indexer skill"
    mkdir -p "$SKILL_DIR"
    cat > "$SKILL_DIR/SKILL.md" << 'SKILLEOF'
---
name: ponder-indexer
description: Ponder blockchain indexer development. Use when writing or modifying indexer schemas, event handlers, or Ponder configuration.
user-invocable: false
---

# Ponder Indexer Development

## What is Ponder
Ponder is a TypeScript indexer for EVM blockchains. It processes contract events into a queryable GraphQL API. Think of it as "The Graph but local-first and TypeScript-native."

## Project Structure
```
ponder/
├── ponder.config.ts    — networks, contracts, ABIs
├── ponder.schema.ts    — database schema (tables)
├── src/
│   └── index.ts        — event handlers
├── abis/               — contract ABIs (JSON)
└── .env.local          — RPC URLs, API keys
```

## Schema (ponder.schema.ts)
- Use `onchainTable()` for indexed data
- Column types: `text`, `integer`, `bigint`, `boolean`, `hex`
- `bigint` for all token amounts (preserves precision)
- Add indexes on frequently queried fields

## Event Handlers (src/index.ts)
- One handler per contract event
- Use `context.db` for database operations (insert, update, upsert)
- Use `context.client` for RPC calls (read contract state)
- Handlers must be idempotent (re-processing same event = same result)
- Use `event.args` for decoded event parameters
- Use `event.block.timestamp` for time data

## Commands
```bash
ponder dev        # start dev server with hot reload
ponder serve      # production server
ponder codegen    # regenerate types from schema
```

## Common Mistakes
- Using `Number` for token amounts (use `BigInt`)
- Not handling the case where an entity doesn't exist yet (use upsert)
- Forgetting to add ABI to ponder.config.ts when adding new events
- Not matching event signatures exactly to the contract ABI
SKILLEOF
fi

# 11. Kill budget-kill flag from previous stop command
rm -f /tmp/nightcrawler-budget-kill

# --- Launch ---
echo "Pre-flight complete. Launching nightcrawler.sh $*"
nohup bash "$SCRIPTS/nightcrawler.sh" "$@" > /tmp/nightcrawler-${PROJECT}-stdout.log 2>&1 &
disown

echo "Session started (PID $!). Use 'status' to monitor."
