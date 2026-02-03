# Git Commit Rules

**CRITICAL: Never add Co-Authored-By lines**

When creating git commits in this repository:

1. **DO NOT add** `Co-Authored-By: Claude` or any Claude attribution lines
2. Commits should appear as authored solely by the user (KTanmay1)
3. Keep commit messages clean without AI attribution

## Commit Message Format

```
<type>: <short description>

- Bullet point details if needed
- Another detail
```

Types: `fix:`, `feat:`, `chore:`, `tune:`, `docs:`

## Example - CORRECT

```
fix: Fix SWE-hard compatibility

- Change USE_SWELANCER_MONOLITH default to false
- Add /repo to REPO_LOCATIONS
```

## Example - WRONG (DO NOT DO THIS)

```
fix: Fix SWE-hard compatibility

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
```
