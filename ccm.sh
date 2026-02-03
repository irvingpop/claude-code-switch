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

CCM_DIR="$HOME/.ccm"
CCM_OAUTH_DIR="$CCM_DIR/oauth"
CCM_CONFIGS_DIR="$CCM_DIR/configs"

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

ensure_ccm_dirs() {
    local old_umask
    old_umask=$(umask)
    umask 077
    mkdir -p "$CCM_DIR" "$CCM_OAUTH_DIR" "$CCM_CONFIGS_DIR"
    umask "$old_umask"
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

detect_token_type() {
    local token="$1"

    # OAuth token pattern: sk-ant-oat01-*
    if [[ "$token" =~ ^sk-ant-oat01- ]]; then
        echo "oauth"
        return 0
    fi

    # API token patterns: sk-ant-api*, sk-ant-sid*, or legacy sk-ant-*
    if [[ "$token" =~ ^sk-ant-(api|sid).*- ]] || [[ "$token" =~ ^sk-ant-[^o] ]]; then
        echo "api"
        return 0
    fi

    # Default to API for unknown patterns
    echo "api"
    return 1
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

migrate_accounts_v4() {
    local migration_marker="$CCM_DIR/.migrated_v4"

    # Already migrated, skip
    if [[ -f "$migration_marker" ]]; then
        return 0
    fi

    ensure_ccm_dirs

    # Backup old accounts file if it exists
    if [[ -f "$ACCOUNTS_FILE" ]]; then
        cp "$ACCOUNTS_FILE" "$ACCOUNTS_FILE.backup" 2>/dev/null || true

        local temp_file
        temp_file=$(mktemp_secure) || return 1

        # Migrate existing accounts to new 4-field format
        while IFS='|' read -r account_name timestamp rest; do
            [[ -z "$account_name" ]] && continue

            # Skip if already in new format (has 3+ fields)
            if [[ -n "$rest" ]]; then
                echo "$account_name|$timestamp|$rest" >> "$temp_file"
                continue
            fi

            # Try to detect token type
            local token_type="api"
            local email=""

            # Try reading from Keychain (API tokens)
            local token
            token=$(read_keychain_credentials "$account_name" 2>/dev/null || true)

            if [[ -n "$token" ]]; then
                token_type=$(detect_token_type "$token")
            elif [[ -f "$CCM_OAUTH_DIR/${account_name}.token" ]]; then
                # Check OAuth directory
                token=$(cat "$CCM_OAUTH_DIR/${account_name}.token" 2>/dev/null || true)
                if [[ -n "$token" ]]; then
                    token_type=$(detect_token_type "$token")
                fi

                # Read email if available
                if [[ -f "$CCM_OAUTH_DIR/${account_name}.email" ]]; then
                    email=$(cat "$CCM_OAUTH_DIR/${account_name}.email" 2>/dev/null || true)
                fi
            fi

            # Write in new format
            echo "$account_name|$token_type|$timestamp|$email" >> "$temp_file"
        done < "$ACCOUNTS_FILE"

        # Replace old file with migrated version
        mv "$temp_file" "$ACCOUNTS_FILE"
        chmod 600 "$ACCOUNTS_FILE"
    fi

    # Scan OAuth directory for profiles not in accounts file
    if [[ -d "$CCM_OAUTH_DIR" ]]; then
        for token_file in "$CCM_OAUTH_DIR"/*.token; do
            [[ -f "$token_file" ]] || continue

            local profile_name
            profile_name=$(basename "$token_file" .token)

            # Skip if already in accounts file
            if [[ -f "$ACCOUNTS_FILE" ]] && grep -q "^${profile_name}|" "$ACCOUNTS_FILE" 2>/dev/null; then
                continue
            fi

            # Add to accounts file
            local email=""
            local email_file="$CCM_OAUTH_DIR/${profile_name}.email"
            if [[ -f "$email_file" ]]; then
                email=$(cat "$email_file" 2>/dev/null || true)
            fi

            local timestamp
            timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

            local old_umask
            old_umask=$(umask)
            umask 077
            echo "$profile_name|oauth|$timestamp|$email" >> "$ACCOUNTS_FILE"
            umask "$old_umask"
        done
    fi

    # Create migration marker
    touch "$migration_marker"
    echo "$(t 'success_migration_complete' 'Account data migrated to unified format')" >&2
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

    # Check for --oauth flag
    local oauth_mode=false
    local account_name=""

    if [[ "$1" == "--oauth" ]]; then
        oauth_mode=true
        shift
    fi

    if [[ $# -lt 1 ]]; then
        echo "$(t 'error_account_name_required' 'Error: Account name required')" >&2
        echo "$(t 'usage_save_account' 'Usage: ccm save-account [--oauth] <name>')" >&2
        return 1
    fi

    account_name=$(sanitize_account_name "$1") || return 1

    # OAuth mode: generate token via claude setup-token
    if [[ "$oauth_mode" == "true" ]]; then
        if ! command -v claude >/dev/null 2>&1; then
            echo -e "${RED}$(t 'error_claude_not_found' "Error: 'claude' CLI not found")${NC}" >&2
            echo "$(t 'hint_install_claude' 'Install: npm install -g @anthropic-ai/claude-code')" >&2
            return 1
        fi

        if ! command -v jq >/dev/null 2>&1; then
            echo -e "${RED}$(t 'error_jq_not_found' "Error: 'jq' not found")${NC}" >&2
            echo "$(t 'hint_install_jq' 'Install: brew install jq')" >&2
            return 1
        fi

        ensure_ccm_dirs

        echo -e "${BLUE}$(t 'info_oauth_setup_token' 'Generating OAuth token from current Claude session...')${NC}"
        echo "If you're not logged in to Claude, run 'claude' first to authenticate."
        echo ""

        local token_output
        token_output=$(claude setup-token 2>&1)

        local token
        token=$(echo "$token_output" | grep -o 'sk-ant-oat01-[^[:space:]]*' | tr -d '\n')

        if [[ -z "$token" ]]; then
            echo -e "${RED}$(t 'error_oauth_setup_token_failed' 'Failed to generate OAuth token')${NC}" >&2
            echo "Make sure you're logged in to Claude. Run 'claude' to log in first." >&2
            echo "Output was:" >&2
            echo "$token_output" >&2
            return 1
        fi

        # Save OAuth token to file
        local token_file="$CCM_OAUTH_DIR/${account_name}.token"
        local email_file="$CCM_OAUTH_DIR/${account_name}.email"
        local config_file="$CCM_CONFIGS_DIR/${account_name}.claude.json"

        local old_umask
        old_umask=$(umask)
        umask 077
        echo "$token" > "$token_file"
        chmod 600 "$token_file"
        umask "$old_umask"

        # Extract email from ~/.claude.json
        local email=""
        local claude_json="$HOME/.claude.json"
        if [[ -f "$claude_json" ]]; then
            email=$(jq -r '.oauthAccount.emailAddress // empty' "$claude_json" 2>/dev/null || true)
            if [[ -n "$email" ]]; then
                echo "$email" > "$email_file"
                chmod 600 "$email_file"
            fi

            # Backup claude config
            cp "$claude_json" "$config_file"
            chmod 600 "$config_file"
        fi

        # Save metadata to accounts file
        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        local old_umask
        old_umask=$(umask)
        umask 077
        touch "$ACCOUNTS_FILE"
        umask "$old_umask"
        chmod 600 "$ACCOUNTS_FILE"

        if grep -q "^$account_name|" "$ACCOUNTS_FILE" 2>/dev/null; then
            local temp_file
            temp_file=$(mktemp_secure)
            grep -v "^$account_name|" "$ACCOUNTS_FILE" > "$temp_file" || true
            mv "$temp_file" "$ACCOUNTS_FILE"
        fi

        echo "$account_name|oauth|$timestamp|$email" >> "$ACCOUNTS_FILE"

        echo ""
        echo -e "${GREEN}$(t 'success_oauth_created' "OAuth account '$account_name' saved")${NC}"
        if [[ -n "$email" ]]; then
            echo "$(t 'label_email' 'Email'): $email"
        fi
        echo ""
        echo "To activate this account, run:"
        echo "  source <(ccm switch-account $account_name)"

    else
        # Regular mode: auto-detect token type
        local token="${ANTHROPIC_AUTH_TOKEN:-}"

        if [[ -z "$token" ]]; then
            echo -e "${RED}$(t 'error_no_token' 'Error: ANTHROPIC_AUTH_TOKEN not set')${NC}"
            echo "$(t 'hint_set_token' 'Set the token first with: export ANTHROPIC_AUTH_TOKEN=your_token')"
            echo "For OAuth accounts, use: ccm save-account --oauth <name>"
            return 1
        fi

        # Auto-detect token type
        local token_type
        token_type=$(detect_token_type "$token")

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

        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        if [[ "$token_type" == "oauth" ]]; then
            # Save OAuth token to file
            ensure_ccm_dirs

            local token_file="$CCM_OAUTH_DIR/${account_name}.token"
            echo "$token" > "$token_file"
            chmod 600 "$token_file"

            # Extract email if ~/.claude.json exists
            local email=""
            local claude_json="$HOME/.claude.json"
            if [[ -f "$claude_json" ]] && command -v jq >/dev/null 2>&1; then
                email=$(jq -r '.oauthAccount.emailAddress // empty' "$claude_json" 2>/dev/null || true)
                if [[ -n "$email" ]]; then
                    local email_file="$CCM_OAUTH_DIR/${account_name}.email"
                    echo "$email" > "$email_file"
                    chmod 600 "$email_file"
                fi

                # Backup config
                local config_file="$CCM_CONFIGS_DIR/${account_name}.claude.json"
                cp "$claude_json" "$config_file"
                chmod 600 "$config_file"
            fi

            echo "$account_name|oauth|$timestamp|$email" >> "$ACCOUNTS_FILE"
            echo -e "${GREEN}$(t 'success_account_saved' "OAuth account '$account_name' saved")${NC}"
            if [[ -n "$email" ]]; then
                echo "Email: $email"
            fi
        else
            # Save API token to Keychain
            echo "$account_name|api|$timestamp|" >> "$ACCOUNTS_FILE"

            if write_keychain_credentials "$account_name" "$token"; then
                echo -e "${GREEN}$(t 'success_account_saved_keychain' "API account '$account_name' saved to Keychain")${NC}"
            else
                echo -e "${RED}$(t 'error_keychain_failed' 'Failed to save to Keychain')${NC}"
                return 1
            fi
        fi
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
        echo "Error: Account '$account_name' not found" >&2
        echo "Use: ccm list-accounts" >&2
        return 1
    fi

    # Read account metadata
    local token_type="api"
    local email=""
    while IFS='|' read -r acc_name acc_type timestamp acc_email rest; do
        if [[ "$acc_name" == "$account_name" ]]; then
            token_type="${acc_type:-api}"
            email="$acc_email"
            break
        fi
    done < "$ACCOUNTS_FILE"

    # Route based on token type
    if [[ "$token_type" == "oauth" ]]; then
        # OAuth account: read from file and restore config
        local token_file="$CCM_OAUTH_DIR/${account_name}.token"
        local config_file="$CCM_CONFIGS_DIR/${account_name}.claude.json"

        if [[ ! -f "$token_file" ]]; then
            echo "Error: OAuth token file for '$account_name' not found" >&2
            echo "Expected: $token_file" >&2
            return 1
        fi

        local token
        token=$(cat "$token_file")

        if [[ -z "$token" ]]; then
            echo "Error: Token file for '$account_name' is empty" >&2
            return 1
        fi

        # Restore Claude config if available
        if [[ -f "$config_file" ]]; then
            cp "$config_file" "$HOME/.claude.json" 2>/dev/null
            chmod 600 "$HOME/.claude.json" 2>/dev/null
        fi

        # Update active profile marker
        echo "$account_name" > "$CCM_OAUTH_DIR/active"
        chmod 600 "$CCM_OAUTH_DIR/active"

        echo "Switched to OAuth account: $account_name" >&2
        if [[ -n "$email" ]]; then
            echo "Email: $email" >&2
        fi
        echo "CLAUDE_CODE_OAUTH_TOKEN has been set" >&2

        echo "export CLAUDE_CODE_OAUTH_TOKEN=\"$token\""

    else
        # API account: read from Keychain
        local token
        token=$(read_keychain_credentials "$account_name")

        if [[ -z "$token" ]]; then
            echo "Error: Failed to read credentials for '$account_name' from Keychain" >&2
            return 1
        fi

        echo "Switched to API account: $account_name" >&2
        echo "ANTHROPIC_AUTH_TOKEN has been set" >&2

        echo "export ANTHROPIC_AUTH_TOKEN=\"$token\""
    fi
}

list_accounts() {
    set_no_color

    if [[ ! -f "$ACCOUNTS_FILE" ]]; then
        echo "$(t 'info_no_accounts' 'No saved accounts found')"
        echo "$(t 'hint_save_account' 'Use: ccm save-account <name>')"
        return 0
    fi

    local current_api_token="${ANTHROPIC_AUTH_TOKEN:-}"
    local current_oauth_token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
    local count=0
    local api_count=0
    local oauth_count=0

    echo -e "${BLUE}$(t 'header_saved_accounts' 'Saved Accounts:')${NC}"
    echo "----------------------------------------"

    while IFS='|' read -r account_name token_type timestamp email rest; do
        [[ -z "$account_name" ]] && continue

        # Default to API if token_type is missing (old format)
        token_type="${token_type:-api}"

        count=$((count + 1))

        # Count by type
        if [[ "$token_type" == "oauth" ]]; then
            oauth_count=$((oauth_count + 1))
        else
            api_count=$((api_count + 1))
        fi

        # Determine if current/active
        local status=""
        if [[ "$token_type" == "oauth" ]]; then
            # Check OAuth token
            if [[ -n "$current_oauth_token" ]]; then
                local stored_token
                if [[ -f "$CCM_OAUTH_DIR/${account_name}.token" ]]; then
                    stored_token=$(cat "$CCM_OAUTH_DIR/${account_name}.token" 2>/dev/null)
                    if [[ "$stored_token" == "$current_oauth_token" ]]; then
                        status=" ${GREEN}[active]${NC}"
                    fi
                fi
            fi
        else
            # Check API token
            if [[ -n "$current_api_token" ]]; then
                local stored_token
                stored_token=$(read_keychain_credentials "$account_name" 2>/dev/null)
                if [[ "$stored_token" == "$current_api_token" ]]; then
                    status=" ${GREEN}[current]${NC}"
                fi
            fi
        fi

        # Display account with type indicator
        local type_label
        if [[ "$token_type" == "oauth" ]]; then
            type_label="${BLUE}[OAuth]${NC}"
        else
            type_label="${YELLOW}[API]${NC}"
        fi

        # Format output
        if [[ "$token_type" == "oauth" && -n "$email" ]]; then
            echo -e "${GREEN}$account_name${NC} $type_label ($email)$status"
        else
            echo -e "${GREEN}$account_name${NC} $type_label ($(t 'label_saved' 'saved'): $timestamp)$status"
        fi
    done < "$ACCOUNTS_FILE"

    if [[ $count -eq 0 ]]; then
        echo "$(t 'info_no_accounts' 'No saved accounts found')"
    else
        echo "----------------------------------------"
        echo "$(t 'label_account_stats' "Total: $count account(s)") ($api_count API, $oauth_count OAuth)"
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

    # Read account metadata to determine token type
    local token_type="api"
    while IFS='|' read -r acc_name acc_type timestamp email rest; do
        if [[ "$acc_name" == "$account_name" ]]; then
            token_type="${acc_type:-api}"
            break
        fi
    done < "$ACCOUNTS_FILE"

    # Remove from accounts file
    local temp_file
    temp_file=$(mktemp_secure)
    grep -v "^$account_name|" "$ACCOUNTS_FILE" > "$temp_file" || true
    mv "$temp_file" "$ACCOUNTS_FILE"

    # Route deletion based on token type
    if [[ "$token_type" == "oauth" ]]; then
        # Delete OAuth files
        rm -f "$CCM_OAUTH_DIR/${account_name}.token" 2>/dev/null
        rm -f "$CCM_OAUTH_DIR/${account_name}.email" 2>/dev/null
        rm -f "$CCM_CONFIGS_DIR/${account_name}.claude.json" 2>/dev/null

        # Clear active profile if deleting active
        if [[ -f "$CCM_OAUTH_DIR/active" ]]; then
            local active_profile
            active_profile=$(cat "$CCM_OAUTH_DIR/active" 2>/dev/null || true)
            if [[ "$active_profile" == "$account_name" ]]; then
                rm -f "$CCM_OAUTH_DIR/active"
            fi
        fi

        echo -e "${GREEN}$(t 'success_account_deleted' "OAuth account '$account_name' deleted")${NC}"
    else
        # Delete from Keychain
        local keychain_account="ccm-${account_name}"
        if security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$keychain_account" 2>/dev/null; then
            echo -e "${GREEN}$(t 'success_account_deleted' "API account '$account_name' deleted")${NC}"
            echo "Removed from Keychain"
        else
            echo -e "${GREEN}$(t 'success_account_deleted' "API account '$account_name' deleted from accounts file")${NC}"
            echo -e "${YELLOW}Note: Keychain entry not found or already deleted${NC}"
        fi
    fi
}

current_account() {
    set_no_color

    local current_api_token="${ANTHROPIC_AUTH_TOKEN:-}"
    local current_oauth_token="${CLAUDE_CODE_OAUTH_TOKEN:-}"

    if [[ -z "$current_api_token" && -z "$current_oauth_token" ]]; then
        echo "$(t 'info_no_active_account' 'No account currently active')"
        echo "Environment variables not set: ANTHROPIC_AUTH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi

    if [[ ! -f "$ACCOUNTS_FILE" ]]; then
        if [[ -n "$current_api_token" ]]; then
            echo "ANTHROPIC_AUTH_TOKEN is set, but no saved accounts found"
            echo "$(t 'hint_masked_token' "Token (masked): $(mask_token "$current_api_token")")"
        fi
        if [[ -n "$current_oauth_token" ]]; then
            echo "CLAUDE_CODE_OAUTH_TOKEN is set, but no saved accounts found"
            echo "$(t 'hint_masked_token' "Token (masked): $(mask_token "$current_oauth_token")")"
        fi
        return 0
    fi

    local found=false
    while IFS='|' read -r account_name token_type timestamp email rest; do
        [[ -z "$account_name" ]] && continue

        token_type="${token_type:-api}"

        if [[ "$token_type" == "oauth" ]]; then
            # Check OAuth token
            if [[ -n "$current_oauth_token" && -f "$CCM_OAUTH_DIR/${account_name}.token" ]]; then
                local stored_token
                stored_token=$(cat "$CCM_OAUTH_DIR/${account_name}.token" 2>/dev/null)

                if [[ "$stored_token" == "$current_oauth_token" ]]; then
                    echo -e "${GREEN}Current account: $account_name [OAuth]${NC}"
                    echo "$(t 'label_saved' 'Saved'): $timestamp"
                    if [[ -n "$email" ]]; then
                        echo "$(t 'label_email' 'Email'): $email"
                    fi
                    echo "$(t 'hint_masked_token' "Token (masked): $(mask_token "$current_oauth_token")")"
                    echo "Environment: CLAUDE_CODE_OAUTH_TOKEN"
                    found=true
                    break
                fi
            fi
        else
            # Check API token
            if [[ -n "$current_api_token" ]]; then
                local stored_token
                stored_token=$(read_keychain_credentials "$account_name" 2>/dev/null)

                if [[ "$stored_token" == "$current_api_token" ]]; then
                    echo -e "${GREEN}Current account: $account_name [API]${NC}"
                    echo "$(t 'label_saved' 'Saved'): $timestamp"
                    echo "$(t 'hint_masked_token' "Token (masked): $(mask_token "$current_api_token")")"
                    echo "Environment: ANTHROPIC_AUTH_TOKEN"
                    found=true
                    break
                fi
            fi
        fi
    done < "$ACCOUNTS_FILE"

    if [[ "$found" == "false" ]]; then
        if [[ -n "$current_api_token" ]]; then
            echo "ANTHROPIC_AUTH_TOKEN is set, but does not match any saved account"
            echo "$(t 'hint_masked_token' "Token (masked): $(mask_token "$current_api_token")")"
        fi
        if [[ -n "$current_oauth_token" ]]; then
            echo "CLAUDE_CODE_OAUTH_TOKEN is set, but does not match any saved account"
            echo "$(t 'hint_masked_token' "Token (masked): $(mask_token "$current_oauth_token")")"
        fi
    fi
}


switch_to_claude() {
    echo "unset ANTHROPIC_BASE_URL"
    echo "export ANTHROPIC_MODEL=\"${SONNET_MODEL:-claude-sonnet-4-5-20250929}\""
    echo "export ANTHROPIC_SMALL_FAST_MODEL=\"${SONNET_MODEL:-claude-sonnet-4-5-20250929}\""
}

switch_to_opus() {
    echo "unset ANTHROPIC_BASE_URL"
    echo "export ANTHROPIC_MODEL=\"${OPUS_MODEL:-claude-opus-4-5-20251101}\""
    echo "export ANTHROPIC_SMALL_FAST_MODEL=\"${HAIKU_MODEL:-claude-haiku-4-5}\""
}

switch_to_haiku() {
    echo "unset ANTHROPIC_BASE_URL"
    echo "export ANTHROPIC_MODEL=\"${HAIKU_MODEL:-claude-haiku-4-5}\""
    echo "export ANTHROPIC_SMALL_FAST_MODEL=\"${HAIKU_MODEL:-claude-haiku-4-5}\""
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

Account Management (API Token):
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
  ccm save-account --oauth personal  Create OAuth account 'personal'

Launcher (ccc):
  ccc personal              Switch to 'personal' account and launch
  ccc opus:work             Switch to 'work' account with Opus model

Configuration:
  Config file: ~/.ccm_config
  Accounts file: ~/.ccm_accounts
  OAuth profiles: ~/.ccm/oauth/

  Environment variables:
    ANTHROPIC_AUTH_TOKEN      Your Claude API token
    CLAUDE_CODE_OAUTH_TOKEN   OAuth token for Claude.ai subscription
    CCM_LANGUAGE              Language (en/zh)
    SONNET_MODEL              Override Sonnet model ID
    OPUS_MODEL                Override Opus model ID
    HAIKU_MODEL               Override Haiku model ID

For more information, visit: https://github.com/irvingpop/claude-code-switch
EOF
}

main() {
    load_config
    migrate_accounts_v4

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
            echo "Switched to Claude Sonnet 4.5" >&2
            ;;
        opus|o)
            if [[ $# -ge 1 ]]; then
                switch_account "$1" || return 1
            fi
            switch_to_opus
            echo "Switched to Claude Opus 4.5" >&2
            ;;
        haiku|h)
            if [[ $# -ge 1 ]]; then
                switch_account "$1" || return 1
            fi
            switch_to_haiku
            echo "Switched to Claude Haiku 4.5" >&2
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
