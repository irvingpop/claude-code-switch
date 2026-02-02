#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NO_COLOR=false

set_no_color() {
    if [[ "$NO_COLOR" == "true" ]]; then
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        NC=''
    fi
}

CONFIG_FILE="$HOME/.ccm_config"
ACCOUNTS_FILE="$HOME/.ccm_accounts"
KEYCHAIN_SERVICE="${CCM_KEYCHAIN_SERVICE:-Claude Code-credentials}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LANG_DIR="$SCRIPT_DIR/lang"

load_translations() {
    local lang_code="${1:-en}"
    local lang_file="$LANG_DIR/${lang_code}.json"

    if [[ ! -f "$lang_file" ]]; then
        lang_code="en"
        lang_file="$LANG_DIR/en.json"
    fi

    if [[ ! -f "$lang_file" ]]; then
        return 0
    fi

    local vars
    vars=$(set | grep '^TRANS_' | LC_ALL=C cut -d= -f1 || true)
    if [[ -n "$vars" ]]; then
        eval "unset $vars" 2>/dev/null || true
    fi

    while IFS='|' read -r key value; do
        if [[ -n "$key" && -n "$value" ]]; then
            value="${value//\\\"/\"}"
            value="${value//\\\\/\\}"
            eval "TRANS_${key}=\"\$value\""
        fi
    done < <(grep -o '"[^"]*":[[:space:]]*"[^"]*"' "$lang_file" | sed 's/^"\([^"]*\)":[[:space:]]*"\([^"]*\)"$/\1|\2/')
}

t() {
    local key="$1"
    local default="${2:-$key}"
    local var_name="TRANS_${key}"
    local value
    eval "value=\"\${${var_name}:-}\""
    echo "${value:-$default}"
}

detect_language() {
    echo "en"
}

mktemp_secure() {
    local tmpfile
    tmpfile=$(mktemp -t ccm.XXXXXXXXXX) || return 1
    chmod 600 "$tmpfile"
    trap 'rm -f "$tmpfile" 2>/dev/null' EXIT INT TERM
    echo "$tmpfile"
}

sanitize_account_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "$(t 'error_invalid_account_name' 'Error: Invalid account name. Use only letters, numbers, hyphens, and underscores.')" >&2
        return 1
    fi
    if [[ ${#name} -gt 64 ]]; then
        echo "$(t 'error_account_name_too_long' 'Error: Account name too long (max 64 characters).')" >&2
        return 1
    fi
    echo "$name"
}

validate_model_name() {
    local model="$1"
    case "$model" in
        sonnet|s|opus|o|haiku|h)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

load_config() {
    load_translations "en"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        local old_umask
        old_umask=$(umask)
        umask 077
        cat > "$CONFIG_FILE" << 'EOF'
SONNET_MODEL=claude-sonnet-4-5-20250929
OPUS_MODEL=claude-opus-4-5-20251101
HAIKU_MODEL=claude-haiku-4-5
EOF
        umask "$old_umask"
        chmod 600 "$CONFIG_FILE"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        set +u
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            value="${value%%#*}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            case "$key" in
                SONNET_MODEL|OPUS_MODEL|HAIKU_MODEL)
                    export "$key=$value"
                    ;;
            esac
        done < "$CONFIG_FILE"
        set -u
    fi
}

mask_token() {
    local token="$1"
    local len=${#token}

    if [[ $len -le 8 ]]; then
        echo "****"
    else
        local first="${token:0:4}"
        local last="${token: -4}"
        echo "${first}...${last}"
    fi
}

clean_env() {
    unset ANTHROPIC_BASE_URL
    unset ANTHROPIC_MODEL
    unset ANTHROPIC_SMALL_FAST_MODEL
}

read_keychain_credentials() {
    local account_name="$1"
    local keychain_account="ccm-${account_name}"

    if ! command -v security >/dev/null 2>&1; then
        return 1
    fi

    local result
    result=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$keychain_account" -w 2>/dev/null) || return 1
    echo "$result"
}

write_keychain_credentials() {
    local account_name="$1"
    local token="$2"
    local keychain_account="ccm-${account_name}"

    if ! command -v security >/dev/null 2>&1; then
        echo "$(t 'error_keychain_unavailable' 'Error: macOS Keychain not available')" >&2
        return 1
    fi

    security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$keychain_account" 2>/dev/null || true

    security add-generic-password \
        -s "$KEYCHAIN_SERVICE" \
        -a "$keychain_account" \
        -w "$token" \
        -U 2>/dev/null
}

save_account() {
    set_no_color

    if [[ $# -lt 1 ]]; then
        echo "$(t 'error_account_name_required' 'Error: Account name required')" >&2
        echo "$(t 'usage_save_account' 'Usage: ccm save-account <name>')" >&2
        return 1
    fi

    local account_name
    account_name=$(sanitize_account_name "$1") || return 1

    local token="${ANTHROPIC_AUTH_TOKEN:-}"

    if [[ -z "$token" ]]; then
        echo -e "${RED}$(t 'error_no_token' 'Error: ANTHROPIC_AUTH_TOKEN not set')${NC}"
        echo "$(t 'hint_set_token' 'Set the token first with: export ANTHROPIC_AUTH_TOKEN=your_token')"
        return 1
    fi

    local old_umask
    old_umask=$(umask)
    umask 077
    touch "$ACCOUNTS_FILE"
    umask "$old_umask"
    chmod 600 "$ACCOUNTS_FILE"

    if grep -q "^$account_name|" "$ACCOUNTS_FILE" 2>/dev/null; then
        echo -e "${YELLOW}$(t 'warn_account_exists' "Account '$account_name' already exists. Updating...")${NC}"
        local temp_file
        temp_file=$(mktemp_secure)
        grep -v "^$account_name|" "$ACCOUNTS_FILE" > "$temp_file" || true
        mv "$temp_file" "$ACCOUNTS_FILE"
    fi

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "$account_name|$timestamp" >> "$ACCOUNTS_FILE"

    if write_keychain_credentials "$account_name" "$token"; then
        echo -e "${GREEN}$(t 'success_account_saved_keychain' "Account '$account_name' saved to Keychain")${NC}"
    else
        echo -e "${RED}$(t 'error_keychain_failed' 'Failed to save to Keychain')${NC}"
        return 1
    fi
}

switch_account() {
    set_no_color

    if [[ $# -lt 1 ]]; then
        echo "$(t 'error_account_name_required' 'Error: Account name required')" >&2
        echo "$(t 'usage_switch_account' 'Usage: ccm switch-account <name>')" >&2
        return 1
    fi

    local account_name
    account_name=$(sanitize_account_name "$1") || return 1

    if [[ ! -f "$ACCOUNTS_FILE" ]] || ! grep -q "^$account_name|" "$ACCOUNTS_FILE" 2>/dev/null; then
        echo -e "${RED}$(t 'error_account_not_found' "Account '$account_name' not found")${NC}"
        echo "$(t 'hint_list_accounts' 'Use: ccm list-accounts')"
        return 1
    fi

    local token
    token=$(read_keychain_credentials "$account_name")

    if [[ -z "$token" ]]; then
        echo -e "${RED}$(t 'error_read_keychain_failed' "Failed to read credentials for '$account_name' from Keychain")${NC}"
        return 1
    fi

    export ANTHROPIC_AUTH_TOKEN="$token"

    echo -e "${GREEN}$(t 'success_account_switched' "Switched to account: $account_name")${NC}"
    echo "$(t 'hint_auth_token_set' 'ANTHROPIC_AUTH_TOKEN has been set in your environment')"
}

list_accounts() {
    set_no_color

    if [[ ! -f "$ACCOUNTS_FILE" ]]; then
        echo "$(t 'info_no_accounts' 'No saved accounts found')"
        echo "$(t 'hint_save_account' 'Use: ccm save-account <name>')"
        return 0
    fi

    local current_token="${ANTHROPIC_AUTH_TOKEN:-}"
    local count=0

    echo -e "${BLUE}$(t 'header_saved_accounts' 'Saved Accounts:')${NC}"
    echo "----------------------------------------"

    while IFS='|' read -r account_name timestamp; do
        [[ -z "$account_name" ]] && continue

        count=$((count + 1))

        local status=""
        if [[ -n "$current_token" ]]; then
            local stored_token
            stored_token=$(read_keychain_credentials "$account_name" 2>/dev/null)
            if [[ "$stored_token" == "$current_token" ]]; then
                status=" ${GREEN}[current]${NC}"
            fi
        fi

        echo -e "${GREEN}$account_name${NC} ($(t 'label_saved' 'saved'): $timestamp)$status"
    done < "$ACCOUNTS_FILE"

    if [[ $count -eq 0 ]]; then
        echo "$(t 'info_no_accounts' 'No saved accounts found')"
    else
        echo "----------------------------------------"
        echo "$(t 'info_total_accounts' "Total: $count account(s)")"
    fi
}

delete_account() {
    set_no_color

    if [[ $# -lt 1 ]]; then
        echo "$(t 'error_account_name_required' 'Error: Account name required')" >&2
        echo "$(t 'usage_delete_account' 'Usage: ccm delete-account <name>')" >&2
        return 1
    fi

    local account_name
    account_name=$(sanitize_account_name "$1") || return 1

    if [[ ! -f "$ACCOUNTS_FILE" ]] || ! grep -q "^$account_name|" "$ACCOUNTS_FILE" 2>/dev/null; then
        echo -e "${RED}$(t 'error_account_not_found' "Account '$account_name' not found")${NC}"
        return 1
    fi

    local temp_file
    temp_file=$(mktemp_secure)
    grep -v "^$account_name|" "$ACCOUNTS_FILE" > "$temp_file" || true
    mv "$temp_file" "$ACCOUNTS_FILE"

    echo -e "${GREEN}$(t 'success_account_deleted' "Account '$account_name' deleted from accounts file")${NC}"
    echo -e "${YELLOW}$(t 'warn_keychain_manual' 'Note: Keychain entry must be deleted manually if needed')${NC}"
    echo "$(t 'hint_keychain_delete' "Use: security delete-generic-password -s '$KEYCHAIN_SERVICE' -a 'ccm-$account_name'")"
}

current_account() {
    set_no_color

    local current_token="${ANTHROPIC_AUTH_TOKEN:-}"

    if [[ -z "$current_token" ]]; then
        echo "$(t 'info_no_active_account' 'No account currently active (ANTHROPIC_AUTH_TOKEN not set)')"
        return 0
    fi

    if [[ ! -f "$ACCOUNTS_FILE" ]]; then
        echo "$(t 'info_token_set_unknown' 'ANTHROPIC_AUTH_TOKEN is set, but no saved accounts found')"
        echo "$(t 'hint_masked_token' "Token (masked): $(mask_token "$current_token")")"
        return 0
    fi

    local found=false
    while IFS='|' read -r account_name timestamp; do
        [[ -z "$account_name" ]] && continue

        local stored_token
        stored_token=$(read_keychain_credentials "$account_name" 2>/dev/null)

        if [[ "$stored_token" == "$current_token" ]]; then
            echo -e "${GREEN}$(t 'info_current_account' "Current account: $account_name")${NC}"
            echo "$(t 'label_saved' 'Saved'): $timestamp"
            echo "$(t 'hint_masked_token' "Token (masked): $(mask_token "$current_token")")"
            found=true
            break
        fi
    done < "$ACCOUNTS_FILE"

    if [[ "$found" == "false" ]]; then
        echo "$(t 'info_token_set_unknown' 'ANTHROPIC_AUTH_TOKEN is set, but does not match any saved account')"
        echo "$(t 'hint_masked_token' "Token (masked): $(mask_token "$current_token")")"
    fi
}

switch_to_claude() {
    clean_env
    export ANTHROPIC_MODEL="${SONNET_MODEL:-claude-sonnet-4-5-20250929}"
    export ANTHROPIC_SMALL_FAST_MODEL="${SONNET_MODEL:-claude-sonnet-4-5-20250929}"
}

switch_to_opus() {
    clean_env
    export ANTHROPIC_MODEL="${OPUS_MODEL:-claude-opus-4-5-20251101}"
    export ANTHROPIC_SMALL_FAST_MODEL="${HAIKU_MODEL:-claude-haiku-4-5}"
}

switch_to_haiku() {
    clean_env
    export ANTHROPIC_MODEL="${HAIKU_MODEL:-claude-haiku-4-5}"
    export ANTHROPIC_SMALL_FAST_MODEL="${HAIKU_MODEL:-claude-haiku-4-5}"
}

show_status() {
    echo "$(t 'header_current_config' '=== Current Configuration ===')"
    echo ""

    local token="${ANTHROPIC_AUTH_TOKEN:-}"
    if [[ -n "$token" ]]; then
        echo "$(t 'label_auth_token' 'ANTHROPIC_AUTH_TOKEN'): $(mask_token "$token")"
    else
        echo "$(t 'label_auth_token' 'ANTHROPIC_AUTH_TOKEN'): $(t 'status_not_set' 'not set')"
    fi
    echo ""

    echo "$(t 'header_models' '=== Models ===')"
    local current_model="${ANTHROPIC_MODEL:-none}"
    local current_small="${ANTHROPIC_SMALL_FAST_MODEL:-none}"
    echo "$(t 'label_current_model' 'Current model'): $current_model"
    echo "$(t 'label_small_fast_model' 'Small/fast model'): $current_small"
    echo ""

    echo "$(t 'header_configured_models' '=== Configured Models ===')"
    echo "$(t 'label_sonnet' 'Sonnet'): ${SONNET_MODEL:-claude-sonnet-4-5-20250929}"
    echo "$(t 'label_opus' 'Opus'): ${OPUS_MODEL:-claude-opus-4-5-20251101}"
    echo "$(t 'label_haiku' 'Haiku'): ${HAIKU_MODEL:-claude-haiku-4-5}"
}

show_help() {
    cat << 'EOF'
Claude Code Account Manager (CCM)

Usage: ccm <command> [options]

Model Switching:
  sonnet, s [account]       Switch to Claude Sonnet 4.5
  opus, o [account]         Switch to Claude Opus 4.5
  haiku, h [account]        Switch to Claude Haiku 4.5

Account Management:
  save-account <name>       Save current ANTHROPIC_AUTH_TOKEN as named account
  switch-account <name>     Switch to a saved account
  list-accounts             List all saved accounts
  delete-account <name>     Delete a saved account
  current-account           Show currently active account

Info & Configuration:
  status, st                Show current configuration
  help, -h, --help          Show this help message

Examples:
  ccm sonnet                Switch to Sonnet model
  ccm opus work             Switch to Opus model using 'work' account
  ccm save-account work     Save current token as 'work' account
  ccm switch-account work   Switch to 'work' account
  ccm list-accounts         List all saved accounts

Configuration:
  Config file: ~/.ccm_config
  Accounts file: ~/.ccm_accounts

  Environment variables:
    ANTHROPIC_AUTH_TOKEN    Your Claude API token
    CCM_LANGUAGE            Language (en/zh)
    SONNET_MODEL            Override Sonnet model ID
    OPUS_MODEL              Override Opus model ID
    HAIKU_MODEL             Override Haiku model ID

For more information, visit: https://github.com/irvingpop/claude-code-switch
EOF
}

main() {
    load_config

    if [[ $# -eq 0 ]]; then
        show_help
        return 0
    fi

    local command="$1"
    shift

    case "$command" in
        sonnet|s)
            if [[ $# -ge 1 ]]; then
                switch_account "$1" || return 1
            fi
            switch_to_claude
            echo "$(t 'success_switched_to' 'Switched to') Claude Sonnet 4.5"
            ;;
        opus|o)
            if [[ $# -ge 1 ]]; then
                switch_account "$1" || return 1
            fi
            switch_to_opus
            echo "$(t 'success_switched_to' 'Switched to') Claude Opus 4.5"
            ;;
        haiku|h)
            if [[ $# -ge 1 ]]; then
                switch_account "$1" || return 1
            fi
            switch_to_haiku
            echo "$(t 'success_switched_to' 'Switched to') Claude Haiku 4.5"
            ;;
        save-account)
            save_account "$@"
            ;;
        switch-account)
            switch_account "$@"
            ;;
        list-accounts)
            list_accounts
            ;;
        delete-account)
            delete_account "$@"
            ;;
        current-account)
            current_account
            ;;
        status|st)
            show_status
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            echo "$(t 'error_unknown_command' "Unknown command: $command")" >&2
            echo "$(t 'hint_use_help' 'Use: ccm help')" >&2
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
