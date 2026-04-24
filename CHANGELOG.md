# Changelog

All notable changes to claude-connect-do will be documented in this file.

## [1.0.2] - 2026-04-24

### Fixed
- **Version consistency across artifacts**:
  - Updated package metadata to `1.0.2`
  - Updated runtime version output in bash launcher (`bin/claude-connect-do`)
  - Updated runtime version output in PowerShell launcher (`bin/claude-connect-do.ps1`)
- **Release documentation correctness**:
  - Corrected `RELEASE_NOTES_1.0.2.md` content to describe v1.0.2
  - Removed stale hardcoded tarball filename version from README examples

### Changed
- README now indicates current stable release (`v1.0.2`)
- `npm pack` install example now uses `claude-connect-do-<version>.tgz` placeholder for future-proof docs

### Notes
- No breaking changes
- Recommended upgrade path:
  - `npm install -g claude-connect-do@latest`

## [1.0.1] - 2026-04-24

### Added
- **Background Proxy Lifecycle Management**: Proxy now stays connected and auto-disconnects properly in all scenarios:
  - Terminal window closed (X button) — proxy cleaned up ✓
  - Shell force-killed (taskkill /F, kill -9) — proxy cleaned up via watchdog ✓
  - System shutdown/reboot — proxy cleaned up ✓
  - Normal exit (Ctrl+D, /exit) — proxy cleaned up ✓
  
- **Watchdog Process for Orphan Prevention**: 
  - Bash: Background subshell monitors parent PID, kills proxy if parent dies (handles SIGKILL scenarios)
  - PowerShell: Detached hidden watchdog process monitors parent, kills proxy on exit
  - Both prevent orphaned proxy processes in force-kill scenarios where signal traps cannot fire

- **Full Claude CLI Passthrough**:
  - All Claude flags now pass through: `--dangerously-skip-permissions`, `--model`, `--permission-mode`, `--add-dir`, `--agents`, `--mcp-config`, `-c`, `-r`, `-p`, `--print`, `--verbose`, etc.
  - All Claude subcommands pass through: `auth`, `mcp`, `agents`, `plugin`, `update`, `setup-token`, `auto-mode`, etc.
  - Examples:
    ```bash
    claude-connect-do --dangerously-skip-permissions
    claude-connect-do --model claude-sonnet-4-6 -p "hello"
    claude-connect-do -c                    # continue last session
    claude-connect-do --add-dir ./src --permission-mode acceptEdits
    ```

- **Command Collision Resolution**:
  - Added `cc-*` aliases for all wrapper commands: `cc-install`, `cc-setup`, `cc-doctor`, `cc-status`, `cc-stop-all`, `cc-models`, `cc-version`, `cc-help`
  - Allows unambiguous wrapper command invocation even if Claude adds conflicting subcommands in the future
  - Added `--` separator for forcing passthrough of colliding commands:
    ```bash
    claude-connect-do -- doctor            # runs Claude's doctor, not wrapper's
    claude-connect-do -- install stable    # runs Claude's installer
    claude-connect-do -- --help            # shows Claude's full help
    ```

- **Enhanced Help Documentation**:
  - Help text now clearly documents passthrough behavior
  - Documents the 3 colliding subcommands (install, doctor, help)
  - Shows examples of all passthrough modes
  - Explains cc-* aliases and -- separator

### Fixed
- **Critical (Bash)**: Fixed watchdog variable initialization syntax error that prevented script execution
- **Critical (PowerShell)**: Added force-kill protection via detached watchdog process (taskkill /F now properly cleans up)
- **Improved (Both)**: Added idempotency guards to Cleanup functions to prevent double-cleanup races
- **Improved (Both)**: Added signal coverage (QUIT signal on bash, PowerShell Exiting event + watchdog process)

### Changed
- Bash script: `trap cleanup EXIT INT TERM HUP QUIT` (added QUIT)
- PowerShell script: Replaced unreliable `Register-EngineEvent PowerShell.Exiting` with robust detached watchdog process
- Both scripts: Restructured command dispatch to support `--` separator and `cc-*` aliases

### Security
- No new security vulnerabilities introduced
- Audited for: command injection (clean), variable escaping (proper quoting), signal handling (comprehensive), process cleanup (robust)
- Watchdog processes isolated with restricted permissions and detached execution
- All environment variables sanitized before passing to proxy/claude

### Testing
- Tested on Windows (PowerShell), Linux (bash), macOS (bash)
- Verified proxy cleanup in all scenarios:
  - Normal exit ✓
  - Ctrl+C ✓
  - Terminal close ✓
  - Force-kill ✓
  - System shutdown ✓
- Verified flag passthrough: 20+ Claude flags tested ✓
- Verified command aliases: all 8 cc-* commands tested ✓
- Verified -- separator: colliding commands tested ✓

### Technical Details
- **Bash watchdog**: Monitors parent via `kill -0` check every 2 seconds, escalates from SIGTERM to SIGKILL
- **PowerShell watchdog**: Separate hidden powershell process checks parent PID every 2 seconds, escalates from graceful close to force-kill
- Both watchdogs survive parent process death (not affected by parent's termination signal)
- Cleanup idempotency: Double-cleanup calls are guarded with flag checks, safe to call multiple times

---

## [1.0.0] - 2025-01-01

### Initial Release
- Proxy startup and health check
- API key setup and model discovery
- Basic proxy lifecycle (trap EXIT INT TERM HUP)
- Command dispatch for install, setup, doctor, status, stop-all, models, version, help
