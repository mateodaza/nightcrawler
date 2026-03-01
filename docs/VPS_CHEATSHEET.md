# VPS Cheat Sheet — Nightcrawler Maintenance

## File Locations

| What | VPS Path |
|------|----------|
| Nightcrawler repo | `/root/nightcrawler/` |
| Clout repo | `/home/nightcrawler/projects/clout` |
| OpenClaw config | `~/.openclaw/openclaw.json` |
| OpenClaw workspace | `~/.openclaw/workspace/` |
| Budget state | `/root/nightcrawler/sessions/` |
| Kill switch | `/tmp/nightcrawler-budget-kill` |

## Updating Workspace Files

When you edit IDENTITY.md, SOUL.md, or NIGHTCRAWLER.md locally (on your Mac), you need to paste the updated content onto the VPS.

**Option A — Paste directly:**
```bash
cat > ~/.openclaw/workspace/NIGHTCRAWLER.md << 'ENDOFFILE'
<paste full file content here>
ENDOFFILE
```

**Option B — If the nightcrawler repo has the file, pull it:**
```bash
cd ~/nightcrawler && git pull origin main
cp ~/nightcrawler/workspace/NIGHTCRAWLER.md ~/.openclaw/workspace/
cp ~/nightcrawler/workspace/IDENTITY.md ~/.openclaw/workspace/
cp ~/nightcrawler/workspace/SOUL.md ~/.openclaw/workspace/
```

**After updating ANY workspace file:**
```bash
openclaw gateway restart
```

**Verify the bot picked it up** — ask on Telegram:
```
read ~/.openclaw/workspace/NIGHTCRAWLER.md and tell me what rule #3 says
```

## Daily Routine

```
1. SSH into VPS
2. Check budget:    python3 ~/nightcrawler/scripts/budget.py daily-total
3. Check credits:   (Anthropic console → Billing)
4. Start session:   Send "start clout --budget 5" on Telegram
5. Wait ~30 min for task cycle
6. Review:          cd /home/nightcrawler/projects/clout && git log --oneline -5
7. Continue/stop:   Send "continue" or "stop" on Telegram
8. End of day:      python3 ~/nightcrawler/scripts/budget.py daily-total
```

## Emergency Commands

```bash
# STOP everything immediately
touch /tmp/nightcrawler-budget-kill

# Resume after emergency stop
rm /tmp/nightcrawler-budget-kill

# Check if kill switch is active
ls -la /tmp/nightcrawler-budget-kill

# Check budget status for a session
python3 ~/nightcrawler/scripts/budget.py check <session_id>

# Check daily spend
python3 ~/nightcrawler/scripts/budget.py daily-total

# Check monthly spend
python3 ~/nightcrawler/scripts/budget.py monthly-total
```

## Gateway Commands

```bash
openclaw gateway restart    # Restart (reloads workspace files)
openclaw gateway start      # Start
openclaw gateway stop       # Stop
openclaw gateway status     # Check if running
```

## Git — Clout Repo

```bash
cd /home/nightcrawler/projects/clout

# Check current branch (should be nightcrawler/session-001)
git branch --show-current

# See recent commits from Nightcrawler
git log --oneline -10

# Review last commit diff
git diff HEAD~1

# If something went wrong, revert last commit
git revert HEAD --no-edit
```

## Environment Variables (in ~/.bashrc)

```bash
NIGHTCRAWLER_STATE_PATH=/root/nightcrawler
ANTHROPIC_API_KEY=sk-ant-...  (pulled from OpenClaw auth)
```

## Preflight Checks (run before first session of the day)

```bash
# 1. Budget gate works
~/nightcrawler/scripts/budget_gate.sh test-session echo "GATE OK"

# 2. Kill switch not active
ls /tmp/nightcrawler-budget-kill 2>/dev/null && echo "KILL ACTIVE" || echo "CLEAR"

# 3. Workspace loaded
head -3 ~/.openclaw/workspace/NIGHTCRAWLER.md

# 4. API key works
curl -s https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-sonnet-4-5-20250929","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' | head -1

# 5. Correct branch
cd /home/nightcrawler/projects/clout && git branch --show-current
```

## Safety Nets

- **Credits:** $18.20 remaining, auto-reload OFF (natural hard cap)
- **Budget gate:** Blocks every script call if budget exceeded
- **Kill switch:** `touch /tmp/nightcrawler-budget-kill` halts everything
- **Branch protection:** `main` requires PR — Nightcrawler can only push to `nightcrawler/session-001`
- **Codex audit:** Every plan and implementation is reviewed before commit
