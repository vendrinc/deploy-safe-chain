#!/bin/bash

set -u

# Version policy:
#   latest (default) — upgrade whenever installed != GitHub latest (always resolves latest from API).
#   minimum — upgrade only when missing, below SAFE_CHAIN_MINIMUM_VERSION, or shell integration missing.
#             GitHub latest is fetched only when an install run is needed.
SAFE_CHAIN_VERSION_POLICY="${SAFE_CHAIN_VERSION_POLICY:-latest}"
SAFE_CHAIN_MINIMUM_VERSION="${SAFE_CHAIN_MINIMUM_VERSION:-}"

ROOT_LOG="/var/log/safe-chain-kandji/remediate_root.log"
USER_LOG="/var/log/safe-chain-kandji/remediate_user.log"
LOG_DIR="/var/log/safe-chain-kandji"

mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"
touch "$ROOT_LOG" "$USER_LOG"
chmod 644 "$ROOT_LOG" "$USER_LOG"

log_root() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$ROOT_LOG"
}

log_user() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$USER_LOG"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

fetch_latest_version() {
    local latest_version=""
    if command_exists curl; then
        latest_version=$(curl -fsSL "https://api.github.com/repos/AikidoSec/safe-chain/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    elif command_exists wget; then
        latest_version=$(wget -qO- "https://api.github.com/repos/AikidoSec/safe-chain/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    fi

    if [ -z "$latest_version" ]; then
        log_root "ERROR: Unable to fetch latest safe-chain version from GitHub API."
        return 1
    fi

    echo "$latest_version"
}

normalize_version() {
    local s t
    s=$(printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^[vV]//')
    [ -z "$s" ] && { printf '%s' ''; return 0; }
    t=$(printf '%s' "$s" | sed -E 's/^([0-9]+(\.[0-9]+)*).*/\1/')
    printf '%s' "$t"
}

version_is_less() {
    local a b first
    a=$(normalize_version "$1")
    b=$(normalize_version "$2")
    if [ -z "$a" ] || [ -z "$b" ]; then
        return 1
    fi
    first=$(printf '%s\n%s' "$a" "$b" | sort -V | head -n 1)
    [ "$first" = "$a" ] && [ "$a" != "$b" ]
}

get_installed_version_for_user() {
    local user_home="$1"
    local safe_chain_bin="${user_home}/.safe-chain/bin/safe-chain"
    local installed_version=""
    local out

    if [ ! -x "$safe_chain_bin" ]; then
        echo ""
        return 0
    fi

    if out=$("$safe_chain_bin" --version 2>/dev/null); then
        installed_version=$(printf '%s\n' "$out" | sed -n 's/.*Current safe-chain version:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)
    fi
    if [ -z "$installed_version" ]; then
        installed_version=$("$safe_chain_bin" -v 2>/dev/null | sed -n 's/.*Current safe-chain version:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)
    fi
    echo "$installed_version"
}

has_shell_integration() {
    local user_home="$1"
    local shell_file
    for shell_file in \
        "${user_home}/.zshrc" \
        "${user_home}/.zprofile" \
        "${user_home}/.bashrc" \
        "${user_home}/.bash_profile" \
        "${user_home}/.profile"; do
        if [ -f "$shell_file" ] && grep -Eq 'safe-chain|\.safe-chain' "$shell_file"; then
            return 0
        fi
    done
    return 1
}

list_target_users() {
    dscl . -list /Users UniqueID | while read -r user uid; do
        if [ "$uid" -lt 500 ]; then
            continue
        fi

        if [ "$user" = "nobody" ]; then
            continue
        fi

        home_dir=$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        if [ -z "$home_dir" ] || [ ! -d "$home_dir" ]; then
            continue
        fi

        shell=$(dscl . -read "/Users/${user}" UserShell 2>/dev/null | awk '{print $2}')
        case "$shell" in
            */false|*/nologin)
                continue
                ;;
        esac

        echo "${user}:${uid}:${home_dir}"
    done
}

run_install_for_user() {
    local user="$1"
    local uid="$2"
    local home_dir="$3"
    local latest_version="$4"

    local tmp_script
    tmp_script=$(mktemp "/tmp/safe-chain-install-${user}.XXXXXX.sh")

    cat > "$tmp_script" <<EOF
#!/bin/bash
set -u
export HOME="${home_dir}"
export USER="${user}"
export LOGNAME="${user}"
export PATH="\$HOME/.safe-chain/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"

INSTALLER_URL="https://github.com/AikidoSec/safe-chain/releases/download/${latest_version}/install-safe-chain.sh"
if curl -fsSL "\$INSTALLER_URL" | sh; then
    exit 0
fi

# Fallback path: install binary directly if installer fails (for example, due to local nvm cleanup errors).
OS="macos"
ARCH=""
case "\$(uname -m)" in
    x86_64|amd64) ARCH="x64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) exit 1 ;;
esac

mkdir -p "\$HOME/.safe-chain/bin"
BINARY_URL="https://github.com/AikidoSec/safe-chain/releases/download/${latest_version}/safe-chain-\${OS}-\${ARCH}"
if ! curl -fsSL "\$BINARY_URL" -o "\$HOME/.safe-chain/bin/safe-chain"; then
    exit 1
fi
chmod +x "\$HOME/.safe-chain/bin/safe-chain"
"\$HOME/.safe-chain/bin/safe-chain" setup
EOF

    chmod 700 "$tmp_script"
    chown "${user}" "$tmp_script" 2>/dev/null || true

    # shellcheck disable=SC2024
    if launchctl asuser "$uid" sudo -u "$user" -H /bin/bash "$tmp_script" >> "$USER_LOG" 2>&1; then
        rm -f "$tmp_script"
        return 0
    fi

    # Fallback for users without active GUI bootstrap context
    # shellcheck disable=SC2024
    if sudo -u "$user" -H HOME="$home_dir" USER="$user" LOGNAME="$user" /bin/bash "$tmp_script" >> "$USER_LOG" 2>&1; then
        rm -f "$tmp_script"
        return 0
    fi

    rm -f "$tmp_script"
    return 1
}

log_root "Starting safe-chain remediation."
case "$SAFE_CHAIN_VERSION_POLICY" in
    latest | minimum) ;;
    *)
        log_root "ERROR: SAFE_CHAIN_VERSION_POLICY must be 'latest' or 'minimum' (got: ${SAFE_CHAIN_VERSION_POLICY})."
        exit 1
        ;;
esac

if [ "$SAFE_CHAIN_VERSION_POLICY" = "minimum" ] && [ -z "$SAFE_CHAIN_MINIMUM_VERSION" ]; then
    log_root "ERROR: SAFE_CHAIN_MINIMUM_VERSION must be set when SAFE_CHAIN_VERSION_POLICY=minimum."
    exit 1
fi

latest_version=""
latest_version_clean=""
min_clean=""
if [ "$SAFE_CHAIN_VERSION_POLICY" = "latest" ]; then
    latest_version=$(fetch_latest_version)
    if [ -z "${latest_version:-}" ]; then
        log_root "Remediation failed: latest version lookup failed."
        exit 1
    fi
    latest_version_clean=$(normalize_version "$latest_version")
    log_root "Policy=latest. Latest GitHub release is ${latest_version}."
else
    min_clean=$(normalize_version "$SAFE_CHAIN_MINIMUM_VERSION")
    log_root "Policy=minimum. Required minimum is ${SAFE_CHAIN_MINIMUM_VERSION}; will fetch GitHub latest only when a user needs installation."
fi

ensure_install_release_tag() {
    if [ -n "$latest_version" ]; then
        return 0
    fi
    latest_version=$(fetch_latest_version)
    if [ -z "${latest_version:-}" ]; then
        return 1
    fi
    latest_version_clean=$(normalize_version "$latest_version")
    log_root "Fetched latest GitHub release ${latest_version} for installation."
    return 0
}

users_checked=0
users_remediated=0
users_failed=0

while IFS=":" read -r user uid home_dir; do
    users_checked=$((users_checked + 1))
    installed_version=$(get_installed_version_for_user "$home_dir")
    installed_version_clean=$(normalize_version "$installed_version")

    should_install=0

    if [ -z "$installed_version" ]; then
        log_root "Installing safe-chain for ${user}: not installed."
        should_install=1
    elif [ "$SAFE_CHAIN_VERSION_POLICY" = "latest" ]; then
        if [ "$installed_version_clean" != "$latest_version_clean" ]; then
            log_root "Installing safe-chain for ${user}: ${installed_version} -> ${latest_version}."
            should_install=1
        fi
    else
        if version_is_less "$installed_version_clean" "$min_clean"; then
            log_root "Installing safe-chain for ${user}: ${installed_version} below minimum ${SAFE_CHAIN_MINIMUM_VERSION}."
            should_install=1
        fi
    fi

    if [ "$should_install" -eq 0 ] && ! has_shell_integration "$home_dir"; then
        log_root "Installing safe-chain for ${user}: shell integration markers missing."
        should_install=1
    fi

    if [ "$should_install" -eq 0 ]; then
        log_root "Skipping ${user}: already compliant (${installed_version})."
        continue
    fi

    if ! ensure_install_release_tag; then
        users_failed=$((users_failed + 1))
        log_user "ERROR: could not resolve latest release for installing safe-chain for ${user}."
        continue
    fi

    if run_install_for_user "$user" "$uid" "$home_dir" "$latest_version"; then
        post_version=$(get_installed_version_for_user "$home_dir")
        post_version_clean=$(normalize_version "$post_version")
        version_ok=0
        if [ "$SAFE_CHAIN_VERSION_POLICY" = "latest" ]; then
            [ "$post_version_clean" = "$latest_version_clean" ] && version_ok=1
        else
            if [ -n "$post_version_clean" ] && ! version_is_less "$post_version_clean" "$min_clean"; then
                version_ok=1
            fi
        fi
        if [ "$version_ok" -eq 1 ] && has_shell_integration "$home_dir"; then
            users_remediated=$((users_remediated + 1))
            log_user "SUCCESS: ${user} now has safe-chain ${post_version} with shell integration markers."
        else
            users_failed=$((users_failed + 1))
            log_user "ERROR: ${user} install command ran but verification failed (version=${post_version})."
        fi
    else
        users_failed=$((users_failed + 1))
        log_user "ERROR: installation failed for ${user}."
    fi
done < <(list_target_users)

log_root "Remediation complete. users_checked=${users_checked}, users_remediated=${users_remediated}, users_failed=${users_failed}."

if [ "$users_failed" -gt 0 ]; then
    exit 1
fi

exit 0
