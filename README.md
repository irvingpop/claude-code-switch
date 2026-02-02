# Claude Code Account Manager (CCM) 🔧

> A secure account manager for Claude Code with multi-model support and macOS Keychain integration

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Language-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/Platform-macOS-blue.svg)](https://github.com/irvingpop/claude-code-switch)
[![Security](https://img.shields.io/badge/Security-Hardened-green.svg)](https://github.com/irvingpop/claude-code-switch)

## 🎯 Quick Start

Install and start using Claude Code Account Manager in 3 steps:

```bash
# 1. Clone and install
git clone https://github.com/irvingpop/claude-code-switch.git
cd claude-code-switch
./install.sh

# 2. Reload shell
source ~/.zshrc  # or source ~/.bashrc for bash

# 3. Use it!
ccm sonnet                  # Switch to Sonnet model
ccm save-account work       # Save your current token as 'work'
ccm opus work               # Switch to Opus using 'work' account
```

## 🌟 Features

- 🔐 **Secure Account Management**: Store multiple Claude Pro accounts securely in macOS Keychain
- 🤖 **Multi-Model Support**: Easily switch between Claude Sonnet 4.5, Opus 4.5, and Haiku 4.5
- ⚡ **Quick Switching**: One-command model and account switching
- 🚀 **One-Command Launch**: `ccc` command switches model and launches Claude Code instantly
- 🛡️ **Security Hardened**:
  - Secure file permissions (600) for all config files
  - Input validation on account names
  - No credentials in shell history
  - Secure temporary file handling
  - Token masking in status output
- 🎨 **Clean Interface**: Color-coded output with clear status messages
- 🔌 **Oh-My-Zsh Plugin**: Install as a zsh plugin or use standalone

## 📦 Supported Models

| Model | Model ID | Description |
|-------|----------|-------------|
| 🧠 **Sonnet 4.5** | claude-sonnet-4-5-20250929 | Balanced performance (default) |
| 🚀 **Opus 4.5** | claude-opus-4-5-20251101 | Strongest reasoning capability |
| 🔷 **Haiku 4.5** | claude-haiku-4-5 | Fast and efficient |

## 🛠️ Installation

### Method 1: Standalone Installation (Bash/Zsh)

```bash
git clone https://github.com/irvingpop/claude-code-switch.git
cd claude-code-switch
./install.sh
source ~/.zshrc  # or source ~/.bashrc
```

This installs `ccm()` and `ccc()` shell functions to your rc file.

### Method 2: Oh-My-Zsh Plugin

```bash
# Clone to oh-my-zsh custom plugins directory
git clone https://github.com/irvingpop/claude-code-switch.git \
  ~/.oh-my-zsh/custom/plugins/claudecode

# Add to your ~/.zshrc plugins list
plugins=(git docker ... claudecode)

# Reload shell
source ~/.zshrc
```

### Method 3: Direct Usage (No Installation)

```bash
git clone https://github.com/irvingpop/claude-code-switch.git
cd claude-code-switch
./ccc sonnet  # Launch directly
```

## 📖 Usage

### Model Switching

Switch between Claude models in your current shell:

```bash
ccm sonnet                  # Switch to Sonnet 4.5
ccm opus                    # Switch to Opus 4.5
ccm haiku                   # Switch to Haiku 4.5

# Short aliases
ccm s                       # Sonnet
ccm o                       # Opus
ccm h                       # Haiku
```

### Account Management

Manage multiple Claude Pro accounts:

```bash
# Save current account
export ANTHROPIC_AUTH_TOKEN=sk-ant-your-token-here
ccm save-account work       # Save as 'work' account

# Switch between accounts
ccm switch-account work     # Switch to 'work' account
ccm switch-account personal # Switch to 'personal' account

# List all saved accounts
ccm list-accounts

# Show current account
ccm current-account

# Delete an account
ccm delete-account old-account
```

### Combined Model + Account Switching

Switch both model and account in one command:

```bash
# Switch to account first, then model
ccm opus work              # Switch to 'work' account, then Opus
ccm sonnet personal        # Switch to 'personal' account, then Sonnet
```

### Launch Claude Code

Use `ccc` to switch and launch Claude Code in one command:

```bash
ccc sonnet                 # Launch with Sonnet
ccc opus                   # Launch with Opus
ccc work                   # Launch with 'work' account (default model)
ccc opus:work              # Launch with 'work' account using Opus

# Pass options to Claude Code
ccc sonnet --dangerously-skip-permissions
```

### Configuration & Status

```bash
ccm status                 # Show current configuration
ccm st                     # Short alias for status
ccm help                   # Show help message
```

## 📋 Configuration

### Configuration File

Location: `~/.ccm_config`

```bash
# Model overrides (optional)
SONNET_MODEL=claude-sonnet-4-5-20250929
OPUS_MODEL=claude-opus-4-5-20251101
HAIKU_MODEL=claude-haiku-4-5
```

This file is automatically created with secure permissions (600) on first use.

### Accounts File

Location: `~/.ccm_accounts`

Stores account metadata (names and timestamps). Credentials are stored securely in macOS Keychain.

File format:
```
account_name|timestamp
work|2026-02-02T10:30:00Z
personal|2026-02-01T15:45:00Z
```

### Environment Variables

```bash
# Claude authentication token (set by ccm switch-account)
ANTHROPIC_AUTH_TOKEN=sk-ant-...

# Model configuration (set by ccm model commands)
ANTHROPIC_MODEL=claude-sonnet-4-5-20250929
ANTHROPIC_SMALL_FAST_MODEL=claude-sonnet-4-5-20250929

# Model overrides (override config file)
SONNET_MODEL=claude-sonnet-4-5-20250929
OPUS_MODEL=claude-opus-4-5-20251101
HAIKU_MODEL=claude-haiku-4-5

# Keychain service name (advanced)
CCM_KEYCHAIN_SERVICE="Claude Code-credentials"
```

## 🔐 Security Features

### Implemented Security Hardening

1. **Secure File Permissions**
   - All config files created with umask 077 and chmod 600
   - Prevents unauthorized access to configuration data

2. **Input Validation**
   - Account names validated: alphanumeric, hyphens, underscores only
   - Maximum 64 character length
   - Prevents command injection and path traversal

3. **No Credentials in Shell History**
   - Uses `source <(ccm command)` instead of `eval "$(ccm command)"`
   - Credentials never appear in shell history

4. **Secure Temporary Files**
   - Uses mktemp with secure permissions (600)
   - Automatic cleanup with trap handlers

5. **Token Masking**
   - Status output shows only first 4 + last 4 characters
   - Full tokens never printed to terminal

6. **Keychain Integration**
   - Credentials stored in macOS Keychain, not config files
   - Leverages OS-level encryption and access control

### Security Best Practices

```bash
# Verify config file permissions
ls -la ~/.ccm_config        # Should show -rw------- (600)
ls -la ~/.ccm_accounts      # Should show -rw------- (600)

# Manual keychain operations (if needed)
# List CCM keychain entries
security find-generic-password -s "Claude Code-credentials" -a "ccm-work"

# Delete keychain entry manually
security delete-generic-password -s "Claude Code-credentials" -a "ccm-work"
```

## 🎯 Common Workflows

### Daily Development Workflow

```bash
# Morning: switch to work account and start coding
ccm switch-account work
ccc sonnet

# Need more power? Switch to Opus
ccm opus

# Quick testing with Haiku
ccm haiku
```

### Managing Multiple Accounts

```bash
# Save accounts
export ANTHROPIC_AUTH_TOKEN=sk-ant-work-token
ccm save-account work

export ANTHROPIC_AUTH_TOKEN=sk-ant-personal-token
ccm save-account personal

# List and verify
ccm list-accounts

# Switch between them
ccm switch-account work
ccm switch-account personal
```

### One-Command Launch Patterns

```bash
# Launch with specific model
ccc sonnet
ccc opus
ccc haiku

# Launch with specific account (uses default model)
ccc work
ccc personal

# Launch with both account and model
ccc opus:work
ccc sonnet:personal

# Launch with account using colon syntax
ccc :work                  # Uses default model (Sonnet)
```

## 📊 Command Reference

### Model Commands

| Command | Aliases | Description |
|---------|---------|-------------|
| `ccm sonnet` | `ccm s`, `ccm claude` | Switch to Claude Sonnet 4.5 |
| `ccm opus` | `ccm o` | Switch to Claude Opus 4.5 |
| `ccm haiku` | `ccm h` | Switch to Claude Haiku 4.5 |

### Account Management Commands

| Command | Description |
|---------|-------------|
| `ccm save-account <name>` | Save current ANTHROPIC_AUTH_TOKEN as named account |
| `ccm switch-account <name>` | Switch to a saved account |
| `ccm list-accounts` | List all saved accounts |
| `ccm delete-account <name>` | Delete a saved account |
| `ccm current-account` | Show currently active account |

### Info Commands

| Command | Aliases | Description |
|---------|---------|-------------|
| `ccm status` | `ccm st` | Show current configuration |
| `ccm help` | `ccm -h`, `ccm --help` | Show help message |

### Launch Commands

| Command | Description |
|---------|-------------|
| `ccc <model>` | Switch model and launch Claude Code |
| `ccc <account>` | Switch account and launch Claude Code |
| `ccc <model>:<account>` | Switch both and launch Claude Code |

## 🔄 Migration from v2.x

If you're upgrading from the multi-model version (v2.x):

1. **Account data is preserved** - Existing accounts in `~/.ccm_accounts` continue to work
2. **Config file changes** - Old config file is automatically migrated
3. **Removed commands**:
   - `ccm deepseek`, `ccm glm`, `ccm kimi`, `ccm qwen`, etc.
   - `ccm pp <model>` (PPINFRA routing)
   - `ccm config` (simplified config doesn't need editor)
   - `ccm env <model>` (simplified away)

## 🐛 Troubleshooting

### Keychain Issues

If you encounter keychain errors:

```bash
# Manually verify keychain entry
security find-generic-password -s "Claude Code-credentials" -a "ccm-work"

# Delete and re-save account
ccm delete-account work
export ANTHROPIC_AUTH_TOKEN=sk-ant-your-token
ccm save-account work
```

### Permission Issues

```bash
# Fix config file permissions
chmod 600 ~/.ccm_config
chmod 600 ~/.ccm_accounts

# Verify
ls -la ~/.ccm_*
```

### Account Not Switching

```bash
# Verify account exists
ccm list-accounts

# Check current account
ccm current-account

# Try switching again
ccm switch-account work

# Verify token is set
echo $ANTHROPIC_AUTH_TOKEN | head -c 10
```

### Shell Function Not Found

```bash
# Reload shell configuration
source ~/.zshrc  # or source ~/.bashrc

# Verify function is loaded
type ccm

# Re-install if needed
cd claude-code-switch
./install.sh
```

## 🤝 Contributing

Contributions welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📄 License

MIT License - see [LICENSE](LICENSE) for details

## 🙏 Acknowledgments

- Original multi-model CCM project by [@foreveryh](https://github.com/foreveryh)
- Claude Code by Anthropic
- Community contributors

## 📞 Support

- GitHub Issues: https://github.com/irvingpop/claude-code-switch/issues
- Documentation: https://github.com/irvingpop/claude-code-switch

## 🗺️ Roadmap

- [x] Claude-only model support
- [x] Secure account management with Keychain
- [x] Security hardening
- [x] Oh-my-zsh plugin support
- [ ] Bash completion
- [ ] Zsh completion
- [ ] Account import/export
- [ ] Token expiration warnings
