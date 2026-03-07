# Plan: Generalize Nightcrawler with `nightcrawler init` CLI

## Context

Nightcrawler currently runs Clout successfully (30 tasks completed). The pipeline is 90% generic — `nightcrawler.sh` and `diagnose.sh` already read from config variables. The remaining 10% is:

1. `start.sh` section 6: dep detection hardcoded to `node_modules`
2. `start.sh` section 9: `.claude/settings.json` hardcoded with Foundry-specific perms (`forge *`, `cast *`) and only generated if missing (never updates)
3. `workspace/NIGHTCRAWLER.md`: all commands hardcoded to `clout`
4. `config/openclaw.yaml`: single project entry

**Goal:** Create a `nightcrawler init` interactive CLI that onboards any project, plus update start.sh to be fully config-driven. Zero changes to `nightcrawler.sh` core loop (it already works generically).

**Branch:** `nightcrawler/generalize`

---

## Codex Audit Findings (addressed)

1. **HIGH — diagnose.sh claim**: Codex said `diagnose.sh` doesn't read DEPS_CHECK/TOOLS. **Verified in local source at `scripts/diagnose.sh`**: line 53 declares `DEPS_CHECK=""`, line 56 sources config.sh, line 134 runs `eval "$DEPS_CHECK"`, line 144 iterates `for tool in $TOOLS`. This is the current committed code. No changes needed.

2. **HIGH — settings.json never refreshes**: Fixed. Section 9 now **always regenerates** from config on every session start (unconditional overwrite). The file is auto-generated, not hand-edited — so always regenerating is the correct policy. See updated Section 4 below.

3. **MEDIUM — generate-workspace.sh underspecified**: Fixed. The script now uses a template approach: static sections (helpers, observation commands, rules) are literal strings preserved exactly. Only the per-project session control + diagnostics blocks are generated. See updated Section 2 below.

4. **MEDIUM — eval injection from free-form input**: Fixed. `nightcrawler-init.sh` validates all command inputs: rejects shell metacharacters (`;&|$\`()`), max 200 chars, and shows a preview before writing. See updated Section 1 below.

5. **LOW — Python BUILD_CMD**: Changed from `pytest --collect-only` to `python -c "import compileall; compileall.compile_dir('src', quiet=1)"` for actual compilation check. Falls back to `echo "No build step"` if no `src/` dir.

---

## Files to Create

### 1. `scripts/nightcrawler-init.sh` (NEW — ~250 lines)

Interactive CLI with auto-detection. Happy path is **1 typed answer + 2 enters**:

```
$ nightcrawler init
🕷️ Nightcrawler — Project Setup

Project name: my-api
Project path [/home/user/my-api]:

Detected: package.json, tsconfig.json, turbo.json
Stack: Node.js/TypeScript, Turborepo

  BUILD_CMD="pnpm turbo build"
  TEST_CMD="pnpm turbo test"
  INSTALL_CMD="pnpm install"
  DEPS_CHECK="test -d node_modules"
  TOOLS="node pnpm turbo"
  BASE_BRANCH="main"
  TELEGRAM_THREAD_ID=""

Look good? [Y/n]: y

Creating .nightcrawler/config.sh ✓
Verifying tools... node ✓ pnpm ✓ turbo ✓
Creating .nightcrawler/CLAUDE.md (scaffold) ✓
Adding to openclaw.yaml ✓
Updating workspace commands ✓

Done. Run 'start my-api --budget 5' from Telegram.
```

If user answers `n`, drops into per-field edit mode:

```
Look good? [Y/n]: n

Build command [pnpm turbo build]: pnpm turbo build && forge build
Test command [pnpm turbo test]: pnpm turbo test && forge test -v
Install command [pnpm install]:
Dependency check [test -d node_modules]:
Required tools [node pnpm turbo]: node pnpm turbo forge
Base branch [main]:
Telegram thread ID []: 48291

  BUILD_CMD="pnpm turbo build && forge build"
  ...

Look good? [Y/n]: y
Done.
```

**Input validation (addresses Codex finding #4):**
```bash
validate_cmd() {
    local cmd="$1" label="$2"
    if [[ ${#cmd} -gt 200 ]]; then
        echo "ERROR: $label too long (max 200 chars)" >&2; return 1
    fi
    # Strip allowed '&&' sequences, then check for dangerous metacharacters
    local stripped="${cmd//&&/}"
    if [[ "$stripped" =~ [;\|\&\$\`\(\)] ]]; then
        echo "ERROR: $label contains shell metacharacters" >&2; return 1
    fi
    return 0
}
```

**Explicit rule:** `&&` is allowed (chained commands like `pnpm turbo build && forge test`). Single `&` (background), `;`, `|` (pipe), `$`, backticks, and `()` are rejected. The validator strips `&&` before checking, so `&&` passes but `&` alone doesn't.

**Detection logic (auto-suggest based on files found):**

| File Found | Stack | BUILD_CMD | TEST_CMD | INSTALL_CMD | DEPS_CHECK | TOOLS |
|---|---|---|---|---|---|---|
| `foundry.toml` | Solidity/Foundry | `forge build` | `forge test -v` | — | `test -d lib` | `forge` |
| `Cargo.toml` | Rust | `cargo build` | `cargo test` | — | `test -f Cargo.lock` | `cargo rustc` |
| `requirements.txt` | Python | `echo "no build step"` | `python -m pytest -v` | `pip install -r requirements.txt` | `test -d .venv` | `python3 pip pytest` |
| `pyproject.toml` | Python | `echo "no build step"` | `python -m pytest -v` | `pip install -e .` | `test -d .venv` | `python3 pip` |
| `go.mod` | Go | `go build ./...` | `go test ./...` | — | `test -f go.sum` | `go` |
| `pnpm-lock.yaml` | Node/pnpm | `pnpm build` | `pnpm test` | `pnpm install` | `test -d node_modules` | `node pnpm` |
| `package-lock.json` | Node/npm | `npm run build` | `npm test` | `npm install` | `test -d node_modules` | `node npm` |
| `turbo.json` | Turborepo | `pnpm turbo build` | `pnpm turbo test` | `pnpm install` | `test -d node_modules` | `node pnpm turbo` |

**Flow:**
1. Prompt for project name (validate: alphanumeric + hyphens only)
2. Prompt for project path (default: cwd, validate: directory exists)
3. Auto-detect stack from files in project dir (multi-stack: accumulates all matches)
4. Set all config values from detection defaults (base branch = `main`, telegram thread = empty)
5. **Preview**: show full config.sh content, ask "Look good? [Y/n]"
6. If `Y` (or Enter): proceed directly — skip per-field prompts
7. If `n`: drop into per-field edit mode (build, test, install, deps check, tools, branch, telegram thread ID). Each field shows detected default, Enter accepts. Validate each command input. Show preview again after edits.
8. Write `.nightcrawler/config.sh`
9. **Verify tools**: iterate `TOOLS`, check `command -v` for each. Print ✓/✗ per tool. If any missing, print warning but don't block — user may install later before first session.
10. Write `.nightcrawler/CLAUDE.md` (scaffold with detected project structure)
11. Append project to `config/openclaw.yaml`
12. Run `generate-workspace.sh` to rebuild `workspace/NIGHTCRAWLER.md`
13. Print summary + next steps

**Tool verification (step 9):**
```bash
_verify_tools() {
    local missing=()
    for tool in $TOOLS; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo "  $tool ✓"
        else
            echo "  $tool ✗"
            missing+=("$tool")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "WARNING: ${missing[*]} not found in PATH. Install before running sessions."
    fi
}
```

This reuses the same `command -v` check that `diagnose.sh` already does at runtime. Surfacing it at init time means the user knows immediately if their environment is missing something, instead of finding out when a session fails at 2am.

### 2. `scripts/generate-workspace.sh` (NEW — ~120 lines)

**Template approach (addresses Codex finding #3):**

The generator builds NIGHTCRAWLER.md from three sections, each defined by content (not line numbers):

**STATIC_HEADER** (heredoc, no substitution) — from the top of the file through `## Commands`. Contains: title, `MANDATORY BEHAVIOR` rules, example exchange, helper bash blocks (AP, LP, PP). Never references a specific project name.

**GENERATED_PROJECT_BLOCKS** (for-loop per project + one-time generic commands):
- `### Session Control` — per project: `start <proj>`, `start <proj> --budget N`, `start <proj> --budget 0`, `start <proj> --dry-run`
- `### Write Actions` — per project: `install <proj>` → `diagnose.sh <proj> --install`, `diagnose <proj>` → `diagnose.sh <proj>`
- `skip <id>` — appended once after the per-project loops (uses AP helper, project-agnostic)

**STATIC_FOOTER** (heredoc, no substitution) — all commands that use the AP/LP/PP dynamic helpers and never reference a project name: `stop`, `status`, `alive`, `log`, `progress`, `cost`, `queue`, `branch`, `tasks`, `queue add`, `note`, unrecognized message handler, `## Rules`.

**Verification:** For a single registered project (e.g. clout), `grep -c 'clout' workspace/NIGHTCRAWLER.md` should return exactly 6 (4 session + 2 write). For N projects, each project name appears exactly 6 times. STATIC_HEADER and STATIC_FOOTER are byte-identical regardless of how many projects are registered.

```bash
#!/usr/bin/env bash
# generate-workspace.sh — Rebuilds NIGHTCRAWLER.md from project registry
# Preserves all generic commands exactly. Only generates per-project session/diagnose blocks.

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
NC_ROOT="$(dirname "$SCRIPTS")"
WORKSPACE="$NC_ROOT/workspace/NIGHTCRAWLER.md"
YAML="$NC_ROOT/config/openclaw.yaml"

# Extract project names from openclaw.yaml (PyYAML for safe parsing)
PROJECTS=$(python3 -c "
import yaml
with open('$YAML') as f:
    data = yaml.safe_load(f)
projects = data.get('projects', {}) or {}
print(' '.join(projects.keys()))
")

# Write static header (dispatcher rules + helpers — EXACT current content)
cat > "$WORKSPACE" << 'HEADER'
[STATIC_HEADER content — from title through ## Commands heading]
HEADER

# --- GENERATED_PROJECT_BLOCKS ---

# Per-project session control
echo "" >> "$WORKSPACE"
echo "### Session Control" >> "$WORKSPACE"
for proj in $PROJECTS; do
    cat >> "$WORKSPACE" << EOF
- \`start $proj\` → exec: \`bash /root/nightcrawler/scripts/start.sh $proj\`
- \`start $proj --budget N\` → exec: \`bash /root/nightcrawler/scripts/start.sh $proj --budget N\`
- \`start $proj --budget 0\` → exec: \`bash /root/nightcrawler/scripts/start.sh $proj --budget 0\`
- \`start $proj --dry-run\` → exec: \`bash /root/nightcrawler/scripts/start.sh $proj --dry-run\`
EOF
done

# Per-project write actions
echo "" >> "$WORKSPACE"
echo "### Write Actions (require explicit project)" >> "$WORKSPACE"
for proj in $PROJECTS; do
    cat >> "$WORKSPACE" << EOF
- \`install $proj\` → exec: \`bash /root/nightcrawler/scripts/diagnose.sh $proj --install\`
- \`diagnose $proj\` → exec: \`bash /root/nightcrawler/scripts/diagnose.sh $proj\`
EOF
done

# One-time generic commands (use AP helper, not project-specific)
cat >> "$WORKSPACE" << 'GENERIC'
- `skip <id>` → exec: `AP=$(cat /tmp/nightcrawler-active-project 2>/dev/null | head -1); if [ -z "$AP" ]; then echo "No active session — specify project"; exit 0; fi; mkdir -p /tmp/nightcrawler/$AP && echo "<id>" >> /tmp/nightcrawler/$AP/skip && echo "Skipping <id>"`
GENERIC

# --- STATIC_FOOTER (stop, live state, observation, tasks, notes, rules) ---
cat >> "$WORKSPACE" << 'FOOTER'
[STATIC_FOOTER content — starts with stop command, then live state, observation, tasks, notes, rules]
FOOTER
```

The static sections are embedded as heredocs — no templating, no variable substitution, exact byte-for-byte copies of the working content. Only the per-project blocks are generated.

---

## Files to Modify

### 3. `scripts/start.sh` — Section 6: Config-driven dep detection

**Current (lines 69-84):** Hardcoded `node_modules` check
**After:** Uses `DEPS_CHECK` from config.sh, falls back to legacy auto-detect

```bash
# 6. Install dependencies if needed
INSTALL_DIR="$PROJECT_PATH"
[[ -n "$WORKDIR" ]] && INSTALL_DIR="$PROJECT_PATH/$WORKDIR"

NEED_INSTALL=false
if [[ -n "$DEPS_CHECK" ]]; then
    # Config-driven check (generic)
    if ! (cd "$INSTALL_DIR" && eval "$DEPS_CHECK") >/dev/null 2>&1; then
        NEED_INSTALL=true
    fi
elif [[ -d "$INSTALL_DIR" ]] && [[ ! -d "$INSTALL_DIR/node_modules" ]]; then
    # Legacy fallback: check node_modules (preserves existing Clout behavior)
    if [[ -f "$INSTALL_DIR/pnpm-lock.yaml" ]] || [[ -f "$INSTALL_DIR/package-lock.json" ]]; then
        NEED_INSTALL=true
    fi
fi

if [[ "$NEED_INSTALL" == true ]] && [[ -n "$INSTALL_CMD" ]]; then
    echo "Installing dependencies..."
    (cd "$INSTALL_DIR" && eval "$INSTALL_CMD" 2>&1 | tail -5)
elif [[ "$NEED_INSTALL" == true ]]; then
    # Auto-detect (legacy fallback)
    if [[ -f "$INSTALL_DIR/pnpm-lock.yaml" ]]; then
        (cd "$INSTALL_DIR" && pnpm install 2>&1 | tail -5)
    elif [[ -f "$INSTALL_DIR/package-lock.json" ]]; then
        (cd "$INSTALL_DIR" && npm install 2>&1 | tail -5)
    fi
fi
```

**Key:** Legacy fallback preserves exact current Clout behavior. Config-driven path only activates when `DEPS_CHECK` is set.

**On `eval` safety:** `DEPS_CHECK` and `INSTALL_CMD` are executed via `eval` — this is the existing pattern in both `start.sh` and `diagnose.sh`. These values come from `.nightcrawler/config.sh` which is authored by the operator (Mateo), not by untrusted input. The init CLI validates input at creation time, but manual config edits bypass validation. This is acceptable: config.sh is a trusted file in a trusted repo, same as any Makefile or build script. A comment at the top of generated config.sh files will note: `# WARNING: Commands are executed via eval. Only edit if you trust the content.`

### 4. `scripts/start.sh` — Section 9: Config-driven permissions (ALWAYS regenerate)

**Current (lines 121-171):** Hardcoded, only generated if missing
**After:** Always regenerates from config (addresses Codex finding #2)

```bash
# 9. Generate .claude/settings.json from config (always refresh)
_generate_settings() {
    local allow_tools="${TOOLS_ALLOW:-}"
    if [[ -z "$allow_tools" ]]; then
        # Default safe set + TOOLS from config
        allow_tools="cat ls find mkdir cp mv head tail wc diff"
        for t in $TOOLS; do
            allow_tools="$allow_tools $t"
        done
    fi

    python3 -c "
import json, sys
tools = '${allow_tools}'.split()
allow = [f'Bash({t} *)' for t in tools]
allow += ['Bash(git status*)', 'Bash(git diff*)', 'Bash(git log*)', 'Read', 'Write', 'Edit', 'Glob', 'Grep']
deny = ['Bash(curl*)', 'Bash(wget*)', 'Bash(ssh*)', 'Bash(scp*)', 'Bash(git push*)', 'Bash(git reset*)', 'Bash(sudo*)', 'Bash(rm -rf /*)', 'Bash(rm -rf ~*)', 'Bash(chmod 777*)', 'Bash(pkill*)', 'Bash(kill*)']
json.dump({'permissions': {'allow': allow, 'deny': deny}}, sys.stdout, indent=2)
" > "$PROJECT_PATH/.claude/settings.json"
}

# Always regenerate — config changes must propagate to permissions
_generate_settings
echo "Generated .claude/settings.json from config"
```

**Why always regenerate:** The file is auto-generated, not hand-edited. If the user changes TOOLS in config.sh, the next session start picks it up immediately. This is the correct behavior for a "config-driven" design.

**Backward compatibility for Clout:** Once we add `TOOLS="pnpm turbo forge node"` to Clout's config.sh, the generated permissions will include `forge *`, `pnpm *`, `turbo *`, `node *` plus the safe defaults. This matches the current hardcoded list minus `cast *` and `npx *` — we add those to Clout's `TOOLS_ALLOW` explicitly:

```bash
TOOLS_ALLOW="forge cast pnpm npm npx turbo node"  # Clout-specific: includes cast for Foundry
```

### 5. `config/openclaw.yaml` — Upsert project entries (idempotent)

`nightcrawler init` upserts projects by name — if the project already exists, it updates the path/branch. If not, it appends. Uses Python for safe YAML manipulation:

```bash
upsert_project() {
    local name="$1" path="$2" branch="$3" yaml="$4"
    NC_PROJ_NAME="$name" NC_PROJ_PATH="$path" NC_PROJ_BRANCH="$branch" \
    python3 - "$yaml" << 'PYEOF'
import yaml, sys, os

yaml_path = sys.argv[1]
name = os.environ['NC_PROJ_NAME']
path = os.environ['NC_PROJ_PATH']
branch = os.environ['NC_PROJ_BRANCH']

with open(yaml_path, 'r') as f:
    data = yaml.safe_load(f)

if 'projects' not in data or data['projects'] is None:
    data['projects'] = {}

data['projects'][name] = {
    'path': path,
    'base_branch': branch
}

with open(yaml_path, 'w') as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
PYEOF
}
```

Uses `yaml.safe_load` / `yaml.safe_dump` (PyYAML) for structural YAML manipulation. Running `nightcrawler init` twice for the same project updates it instead of duplicating. PyYAML is pre-installed on Python 3.x on most systems; if missing, `pip install pyyaml` as a prerequisite.

**Note:** `safe_dump` may reformat comments and whitespace. Since `openclaw.yaml` is machine-consumed (by scripts, not Haiku directly), this is acceptable. Comments can be preserved in a header block if needed.

### 6. Clout's `.nightcrawler/config.sh` — Add DEPS_CHECK, TOOLS, TOOLS_ALLOW

Add three lines (non-breaking):

```bash
DEPS_CHECK="test -d node_modules"
TOOLS="pnpm turbo forge node"
TOOLS_ALLOW="forge cast pnpm npm npx turbo node"
```

---

## What Does NOT Change

- **`scripts/nightcrawler.sh`** — zero modifications. Already fully config-driven.
- **`scripts/diagnose.sh`** — zero modifications. Already reads DEPS_CHECK (line 134) and TOOLS (line 144). Verified in source.
- **`workspace/SOUL.md`, `workspace/IDENTITY.md`** — personality is project-agnostic.
- **`config/models.yaml`, `config/budget.yaml`** — shared across all projects.
- **Core task loop, budget system, journal, crash recovery** — all generic.

---

## Verification

1. **Clout backward compat:** After changes, run `start clout --budget 1 --dry-run` on VPS. Verify: deps detected via DEPS_CHECK, `.claude/settings.json` generated with forge/cast/pnpm/turbo/node, session starts normally.
2. **Init creates valid config:** Run `nightcrawler init` in a test directory with a `package.json`. Verify `.nightcrawler/config.sh` has correct defaults, `.nightcrawler/CLAUDE.md` exists, openclaw.yaml updated.
3. **Input validation:** Run `nightcrawler init` and try entering `; rm -rf /` as a build command. Verify it rejects with clear error.
4. **Workspace regeneration:** Run `generate-workspace.sh`. Diff output against current NIGHTCRAWLER.md — observation commands (status, alive, log, progress, cost, queue, branch, note) must be identical. Only per-project session blocks should differ.
5. **New project e2e:** Clone a test Node.js repo on VPS, run `nightcrawler init`, then `start <project> --budget 1 --dry-run`. Verify full pre-flight completes.

---

## Prerequisites

- **PyYAML**: Required for YAML parsing in `generate-workspace.sh` and `upsert_project()`. Install: `pip install pyyaml`. Check: `python3 -c "import yaml"`. Add to `scripts/nightcrawler-init.sh` as a pre-flight check — if missing, prompt to install before proceeding.

---

## Implementation Order (Phased — reduces regression risk from ~50% to ~15%)

**Branch:** `nightcrawler/generalize` — created from current HEAD. Each phase gets its own commit. Mateo merges to main after VPS verification. Ultimate rollback = switch branches.

Each phase gets its own commit. Clout smoke test after every phase. If any phase breaks Clout, revert that commit only.

### Phase 1: Safe config additions (ZERO behavior change)
- Add `DEPS_CHECK`, `TOOLS`, `TOOLS_ALLOW` to Clout's `.nightcrawler/config.sh`
- These vars are declared but unused in `start.sh` — adding them changes nothing
- **Smoke test:** `start clout --budget 1 --dry-run` → must pass identically
- **Rollback:** revert 3 lines in config.sh

### Phase 2: start.sh section 6 — config-driven deps
- Update dep detection with `DEPS_CHECK`, keep legacy fallback
- **Smoke test:** `start clout --budget 1 --dry-run` → deps detected via DEPS_CHECK now instead of hardcoded check. Same result, different code path.
- **Rollback:** `git checkout HEAD -- scripts/start.sh`

### Phase 3: start.sh section 9 — config-driven permissions
- Always regenerate `.claude/settings.json` from TOOLS/TOOLS_ALLOW
- **Before changing:** backup current Clout `.claude/settings.json`, diff after generation to verify equivalent output
- **Smoke test:** `start clout --budget 1 --dry-run` → generated permissions must include forge, cast, pnpm, npm, npx, turbo, node (same as current hardcoded)
- **Rollback:** `git checkout HEAD -- scripts/start.sh`

### Phase 4: nightcrawler-init.sh (NEW file, no existing changes)
- Create the interactive CLI
- This only creates new files — zero risk to existing flow
- **Test:** run `nightcrawler init` in a test directory, inspect output
- **Rollback:** `rm scripts/nightcrawler-init.sh`

### Phase 5: generate-workspace.sh (HIGHEST RISK — do last)
- Create workspace regenerator
- **Before running:** `cp workspace/NIGHTCRAWLER.md workspace/NIGHTCRAWLER.md.backup`
- **Golden file test:** generate new NIGHTCRAWLER.md, diff against backup. Observation commands (status, alive, log, progress, cost, queue, branch, note) must be byte-identical. Only per-project session block differs.
- **Smoke test:** `start clout --budget 1 --dry-run` via OpenClaw/Telegram
- **Rollback:** `cp workspace/NIGHTCRAWLER.md.backup workspace/NIGHTCRAWLER.md`

### Risk summary per phase:
| Phase | Risk to Clout | Rollback time |
|-------|---------------|---------------|
| 1. Config vars | Zero | 10 sec |
| 2. Dep detection | Low (legacy fallback) | 10 sec |
| 3. Permissions | Medium (must match current output) | 10 sec |
| 4. Init CLI | Zero (new file) | 10 sec |
| 5. Workspace gen | Highest (Haiku-facing) | 10 sec (backup file) |
