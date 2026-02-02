0="${${ZERO:-${0:#$ZSH_ARGZERO}}:-${(%):-%N}}"
0="${${(M)0:#/*}:-$PWD/$0}"
CCM_PLUGIN_DIR="${0:h}"
CCM_SCRIPT="${CCM_PLUGIN_DIR}/ccm.sh"

if [[ ! -f "$CCM_SCRIPT" ]]; then
  echo "ccm plugin error: ccm.sh not found at $CCM_SCRIPT" >&2
  return 1
fi

if [[ ! -x "$CCM_SCRIPT" ]]; then
  chmod +x "$CCM_SCRIPT" 2>/dev/null || true
fi

unalias ccm 2>/dev/null || true
unset -f ccm 2>/dev/null || true

ccm() {
  local script="$CCM_SCRIPT"

  if [[ ! -f "$script" ]]; then
    echo "ccm error: script not found at $script" >&2
    return 1
  fi

  case "$1" in
    ""|"help"|"-h"|"--help"|"status"|"st"|"save-account"|"switch-account"|"list-accounts"|"delete-account"|"current-account")
      "$script" "$@"
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
    cat <<'EOF'
Usage: ccc <model> [claude-options]
       ccc <account> [claude-options]
       ccc <model>:<account> [claude-options]

Examples:
  ccc sonnet                          # Launch with Sonnet
  ccc opus                            # Launch with Opus
  ccc work                            # Switch to 'work' account and launch
  ccc opus:work                       # Switch to 'work' account and launch Opus
  ccc sonnet --dangerously-skip-permissions

Available models:
  sonnet, s    Claude Sonnet 4.5 (default)
  opus, o      Claude Opus 4.5
  haiku, h     Claude Haiku 4.5
EOF
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

  if [[ "$model" == *:* ]]; then
    echo "🔄 Switching to $model..."
    IFS=':' read -r model_part account_part <<< "$model"
    ccm switch-account "$account_part" || return 1
    if [[ -z "$model_part" ]] || [[ "$model_part" == "claude" ]] || [[ "$model_part" == "sonnet" ]]; then
      ccm sonnet || return 1
    elif [[ "$model_part" == "opus" ]] || [[ "$model_part" == "o" ]]; then
      ccm opus || return 1
    elif [[ "$model_part" == "haiku" ]] || [[ "$model_part" == "h" ]]; then
      ccm haiku || return 1
    else
      echo "❌ Unknown model: $model_part" >&2
      return 1
    fi
  elif _is_known_model "$model"; then
    echo "🔄 Switching to $model..."
    ccm "$model" || return 1
  else
    local account="$model"
    echo "🔄 Switching account to $account..."
    ccm switch-account "$account" || return 1
    ccm sonnet || return 1
  fi

  echo ""
  echo "🚀 Launching Claude Code..."
  echo "   Model: $ANTHROPIC_MODEL"
  if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    echo "   Token: Set"
  fi
  echo ""

  if ! type -p claude >/dev/null 2>&1; then
    echo "❌ 'claude' CLI not found. Install: npm install -g @anthropic-ai/claude-code" >&2
    return 127
  fi

  if [[ ${#claude_args[@]} -eq 0 ]]; then
    exec claude
  else
    exec claude "${claude_args[@]}"
  fi
}
