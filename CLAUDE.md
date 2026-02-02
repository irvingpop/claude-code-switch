# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Claude Code Account Manager (CCM)** is a secure account manager for Claude Code with multi-model support. Pure Bash implementation (523 lines) focused on Claude models with macOS Keychain integration and security hardening.

**Supported Models:** Claude Sonnet 4.5, Claude Opus 4.5, Claude Haiku 4.5

## Repository Structure

```
Claude-Code-Switch/
├── ccm.sh              # Core script (523 lines) - Main implementation
├── install.sh          # Installer - Sets up shell functions
├── uninstall.sh        # Uninstaller - Removes shell functions
├── ccc                 # Launcher script - One-command launcher for Claude Code
├── claudecode.plugin.zsh  # Oh-my-zsh plugin
├── lang/               # English translations only (en.json)
└── README.md / REFACTORING_SUMMARY.md
```

## Key Architecture & Design Patterns

### 1. **Installation Methods**

- **Direct execution:** `./ccc sonnet` / `./ccm sonnet` (no installation)
- **Standalone install:** `./install.sh` injects functions into `~/.zshrc` or `~/.bashrc`
- **Oh-My-Zsh plugin:** Clone to `~/.oh-my-zsh/custom/plugins/claudecode`
  - Installer copies `ccm.sh` and `lang/` to `${XDG_DATA_HOME:-$HOME/.local/share}/ccm`
  - Idempotent: safe to run multiple times

### 2. **Configuration (Simplified)**

Config file (`~/.ccm_config`) contains only model overrides:
- `SONNET_MODEL` - Default: claude-sonnet-4-5-20250929
- `OPUS_MODEL` - Default: claude-opus-4-5-20251101
- `HAIKU_MODEL` - Default: claude-haiku-4-5

Authentication via `ANTHROPIC_AUTH_TOKEN` environment variable (not stored in config).

### 3. **Account Management**

- Accounts stored in `~/.ccm_accounts` (metadata only: name|timestamp)
- Credentials stored in macOS Keychain via `security` command
- Service name: `Claude Code-credentials`, account format: `ccm-{name}`

### 4. **Model Switching**

Model switching functions export environment variables directly:
```bash
export ANTHROPIC_MODEL=...
export ANTHROPIC_SMALL_FAST_MODEL=...
```
Use `source <(ccm model)` to apply to current shell (avoids shell history exposure).

## Common Commands & Workflows

### Installation & Setup

```bash
# Install (one-time setup)
chmod +x install.sh ccm.sh
./install.sh
source ~/.zshrc

# Or use as oh-my-zsh plugin
git clone ... ~/.oh-my-zsh/custom/plugins/claudecode
# Add "claudecode" to plugins=() in ~/.zshrc
```

### Model Switching Workflows

```bash
ccm sonnet                # Switch to Sonnet in current shell
ccm opus work             # Switch to Opus with 'work' account
ccc opus:work             # Switch and launch Claude Code
```

### Model Shortcuts

```bash
ccm sonnet / ccm s       # Claude Sonnet 4.5
ccm opus / ccm o         # Claude Opus 4.5
ccm haiku / ccm h        # Claude Haiku 4.5
```

### Account Management Commands

```bash
ccm save-account <name>       # Save current token to Keychain
ccm switch-account <name>     # Load token from Keychain
ccm list-accounts             # List saved accounts
ccm delete-account <name>     # Delete account metadata
ccm current-account           # Show active account
ccm status / ccm st           # Show config (tokens masked)
ccm help / ccm -h             # Show help
```

### Testing & Verification

```bash
# Verify setup
ccm status               # Check current configuration
echo $ANTHROPIC_MODEL    # Verify model set correctly
cat ~/.ccm_config        # View config file

# Syntax check
bash -n ccm.sh           # Validate syntax
shellcheck ccm.sh        # Lint with shellcheck
```

## Development Workflow

### Code Organization in ccm.sh

Key functions and their line ranges (approximately):
- `load_translations()` - Load i18n from JSON
- `load_config()` - Load model overrides from config file
- `sanitize_account_name()` - Validate account names (alphanumeric + hyphen/underscore, max 64 chars)
- `mask_token()` - Mask secrets for status output
- `switch_to_claude()`, `switch_to_opus()`, `switch_to_haiku()` - Model switching (exports env vars)
- `save_account()`, `switch_account()`, `list_accounts()`, `delete_account()`, `current_account()` - Account management
- `read_keychain_credentials()`, `write_keychain_credentials()` - macOS Keychain integration
- `show_status()` - Display masked configuration
- `show_help()` - Display help information
- `main()` - Entry point with argument parsing

### Security Patterns

- **File permissions:** All config files created with `umask 077` and `chmod 600`
- **Input validation:** `sanitize_account_name()` - only `[a-zA-Z0-9_-]`, max 64 chars
- **Temp files:** `mktemp_secure()` creates with 600 perms and trap cleanup
- **Shell history:** Use `source <(ccm cmd)` not `eval "$(ccm cmd)"` to avoid credential exposure
- **Token masking:** Only show first 4 + last 4 characters in output

### Bash Compatibility Notes

- **Bash 3.x (macOS default):** No associative arrays - use `TRANS_*` prefix with eval
- **set -euo pipefail:** Requires `|| true` for commands that may fail (grep with no match)
- **SC2155 warning:** Separate declare and assign: `local var; var=$(cmd)` not `local var=$(cmd)`
- **Trap quoting:** Use single quotes: `trap 'cmd' EXIT` not `trap "cmd" EXIT`

## Supported Models & API Endpoints

| Model | Official API | PPINFRA Alt | Base URL |
|-------|-------------|-------------|----------|
| Claude Sonnet 4.5 | claude-sonnet-4-5-20250929 | N/A | Anthropic default |
| Claude Opus 4.5 | claude-opus-4-5-20251101 | N/A | Anthropic default |
| Claude Haiku 4.5 | claude-haiku-4-5 | N/A | Anthropic default |

## Version History

- **v3.0.0** (Feb 2026) - Refactored to Claude-only, security hardened, 69.5% code reduction
- **v2.x** - Multi-model support with PPINFRA fallback (deprecated)

## Debugging Tips

```bash
# Verify installation
type ccm                      # Show function/script path
wc -l ccm.sh                  # Should be ~523 lines

# Trace execution
bash -x ./ccm.sh sonnet       # Run with debug output

# Verify environment
ccm status                    # Show masked config
cat ~/.ccm_config             # View config file (should be 3 lines)
cat ~/.ccm_accounts           # View account metadata
env | grep ANTHROPIC          # Check ANTHROPIC_* vars

# Verify Keychain
security find-generic-password -s "Claude Code-credentials" -a "ccm-work"

# Check file permissions (should be 600)
ls -la ~/.ccm_config ~/.ccm_accounts
```

## Documentation References

- **User Guide:** README.md
- **Refactoring Notes:** REFACTORING_SUMMARY.md
