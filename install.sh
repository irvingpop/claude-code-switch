#!/usr/bin/env bash
set -euo pipefail

GITHUB_REPO="irvingpop/claude-code-switch"
GITHUB_BRANCH="main"
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}"

if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LOCAL_MODE=true
else
  SCRIPT_DIR=""
  LOCAL_MODE=false
fi

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ccm"
DEST_SCRIPT_PATH="$INSTALL_DIR/ccm.sh"
BEGIN_MARK="# >>> ccm function begin >>>"
END_MARK="# <<< ccm function end <<<"

detect_rc_file() {
  local shell_name
  shell_name="${SHELL##*/}"
  case "$shell_name" in
    zsh)
      echo "$HOME/.zshrc"
      ;;
    bash)
      echo "$HOME/.bashrc"
      ;;
    *)
      echo "$HOME/.zshrc"
      ;;
  esac
}

create_rc_if_needed() {
  local rc="$1"
  if [[ ! -f "$rc" ]]; then
    local old_umask
    old_umask=$(umask)
    umask 077
    touch "$rc"
    umask "$old_umask"
  fi
}

remove_existing_block() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0
  if grep -qF "$BEGIN_MARK" "$rc"; then
    local tmp
    tmp="$(mktemp)"
    chmod 600 "$tmp"
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
      $0==b {inblock=1; next}
      $0==e {inblock=0; next}
      !inblock {print}
    ' "$rc" > "$tmp" && mv "$tmp" "$rc"
  fi
}

append_function_block() {
  local rc="$1"
  mkdir -p "$(dirname "$rc")"
  create_rc_if_needed "$rc"
  cat >> "$rc" <<'EOF'
# >>> ccm function begin >>>
unalias ccm 2>/dev/null || true
unset -f ccm 2>/dev/null || true
ccm() {
  local script="$DEST_SCRIPT_PATH"
  if [[ ! -f "$script" ]]; then
    local default1="${XDG_DATA_HOME:-$HOME/.local/share}/ccm/ccm.sh"
    local default2="$HOME/.ccm/ccm.sh"
    if [[ -f "$default1" ]]; then
      script="$default1"
    elif [[ -f "$default2" ]]; then
      script="$default2"
    fi
  fi
  if [[ ! -f "$script" ]]; then
    echo "ccm error: script not found at $script" >&2
    return 1
  fi

  case "$1" in
    ""|"help"|"-h"|"--help"|"status"|"st"|"save-account"|"switch-account"|"list-accounts"|"delete-account"|"current-account"|"oauth-create"|"oauth-list"|"oauth-delete"|"oauth-status")
      "$script" "$@"
      ;;
    "oauth-switch")
      source <("$script" "$@")
      ;;
    *)
      source <("$script" "$@")
      ;;
  esac
}

unalias ccc 2>/dev/null || true
unset -f ccc 2>/dev/null || true
ccc() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: ccc <model> [claude-options]"
    echo "       ccc <account> [claude-options]"
    echo "       ccc <model>:<account> [claude-options]"
    echo "       ccc oauth:<profile> [claude-options]"
    echo "       ccc <model>:oauth:<profile> [claude-options]"
    echo ""
    echo "Examples:"
    echo "  ccc sonnet                          # Launch with Sonnet"
    echo "  ccc opus                            # Launch with Opus"
    echo "  ccc work                            # Switch to 'work' account and launch"
    echo "  ccc opus:work                       # Switch to 'work' account and launch Opus"
    echo "  ccc sonnet --dangerously-skip-permissions"
    echo ""
    echo "OAuth Examples:"
    echo "  ccc oauth:personal                  # Switch to OAuth profile 'personal'"
    echo "  ccc opus:oauth:work                 # Switch to OAuth 'work' with Opus"
    echo ""
    echo "Available models:"
    echo "  sonnet, s    Claude Sonnet 4.5 (default)"
    echo "  opus, o      Claude Opus 4.5"
    echo "  haiku, h     Claude Haiku 4.5"
    return 1
  fi

  local model="$1"
  shift
  local claude_args=("$@")

  _is_known_model() {
    case "$1" in
      claude|sonnet|s|opus|o|haiku|h)
        return 0 ;;
      *)
        return 1 ;;
    esac
  }

  _switch_model() {
    local model_name="$1"
    case "$model_name" in
      ""|claude|sonnet|s)
        ccm sonnet || return 1
        ;;
      opus|o)
        ccm opus || return 1
        ;;
      haiku|h)
        ccm haiku || return 1
        ;;
      *)
        echo "Error: Unknown model: $model_name" >&2
        return 1
        ;;
    esac
  }

  if [[ "$model" == oauth:* ]]; then
    local oauth_profile="${model#oauth:}"
    echo ">> Switching to OAuth profile $oauth_profile..."
    ccm oauth-switch "$oauth_profile" || return 1
    _switch_model "sonnet" || return 1
  elif [[ "$model" == *:oauth:* ]]; then
    IFS=':' read -r model_part _ oauth_profile <<< "$model"
    echo ">> Switching to OAuth profile $oauth_profile with $model_part..."
    ccm oauth-switch "$oauth_profile" || return 1
    _switch_model "$model_part" || return 1
  elif [[ "$model" == *:* ]]; then
    echo ">> Switching to $model..."
    IFS=':' read -r model_part account_part <<< "$model"
    ccm switch-account "$account_part" || return 1
    _switch_model "$model_part" || return 1
  elif _is_known_model "$model"; then
    echo ">> Switching to $model..."
    ccm "$model" || return 1
  else
    local account="$model"
    echo ">> Switching account to $account..."
    ccm switch-account "$account" || return 1
    ccm sonnet || return 1
  fi

  echo ""
  echo ">> Launching Claude Code..."
  echo "   Model: $ANTHROPIC_MODEL"
  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    echo "   OAuth: Set"
  elif [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    echo "   Token: Set"
  fi
  echo ""

  if ! type -p claude >/dev/null 2>&1; then
    echo "Error: 'claude' CLI not found. Install: npm install -g @anthropic-ai/claude-code" >&2
    return 127
  fi

  if [[ ${#claude_args[@]} -eq 0 ]]; then
    exec claude
  else
    exec claude "${claude_args[@]}"
  fi
}
# <<< ccm function end <<<
EOF
}

download_from_github() {
  local url="$1"
  local dest="$2"
  echo "Downloading from $url..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
  else
    echo "Error: neither curl nor wget found" >&2
    return 1
  fi
}

main() {
  local old_umask
  old_umask=$(umask)
  umask 077
  mkdir -p "$INSTALL_DIR"
  mkdir -p "$HOME/.ccm/oauth"
  mkdir -p "$HOME/.ccm/configs"
  umask "$old_umask"

  if $LOCAL_MODE && [[ -f "$SCRIPT_DIR/ccm.sh" ]]; then
    echo "Installing from local directory..."
    cp -f "$SCRIPT_DIR/ccm.sh" "$DEST_SCRIPT_PATH"
    chmod 600 "$DEST_SCRIPT_PATH"
    if [[ -d "$SCRIPT_DIR/lang" ]]; then
      rm -rf "$INSTALL_DIR/lang"
      cp -R "$SCRIPT_DIR/lang" "$INSTALL_DIR/lang"
      chmod -R 600 "$INSTALL_DIR/lang"/*
    fi
  else
    echo "Installing from GitHub..."
    download_from_github "${GITHUB_RAW}/ccm.sh" "$DEST_SCRIPT_PATH" || {
      echo "Error: failed to download ccm.sh" >&2
      exit 1
    }
    chmod 600 "$DEST_SCRIPT_PATH"

    mkdir -p "$INSTALL_DIR/lang"
    download_from_github "${GITHUB_RAW}/lang/en.json" "$INSTALL_DIR/lang/en.json" || true
    download_from_github "${GITHUB_RAW}/lang/zh.json" "$INSTALL_DIR/lang/zh.json" || true
    chmod -R 600 "$INSTALL_DIR/lang"/* 2>/dev/null || true
  fi

  chmod +x "$DEST_SCRIPT_PATH"

  local rc
  rc="$(detect_rc_file)"
  remove_existing_block "$rc"
  append_function_block "$rc"

  echo "OK: Installed ccm and ccc functions into: $rc"
  echo "   Script installed to: $DEST_SCRIPT_PATH"
  echo "   Reload your shell or run: source $rc"
  echo ""
  echo "   Then use:"
  echo "     ccm sonnet         # Switch to Sonnet model"
  echo "     ccm opus           # Switch to Opus model"
  echo "     ccc sonnet         # Switch model and launch Claude Code"
  echo "     ccm save-account work    # Save current token as 'work' account"
  echo "     ccm switch-account work  # Switch to 'work' account"
}

main "$@"
