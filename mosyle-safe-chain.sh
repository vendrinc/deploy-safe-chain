#!/bin/bash
#
# Mosyle (single custom command): combines Kandji-style detect + remediate.
# Set SAFE_CHAIN_MOSYLE_MODE=detect | remediate | both (default: both).
#

set -u

SAFE_CHAIN_VERSION_POLICY="${SAFE_CHAIN_VERSION_POLICY:-latest}"
SAFE_CHAIN_MINIMUM_VERSION="${SAFE_CHAIN_MINIMUM_VERSION:-}"
SAFE_CHAIN_RELEASE_TAG="${SAFE_CHAIN_RELEASE_TAG-1.4.6}"
SAFE_CHAIN_INSTALLER_SHA256="${SAFE_CHAIN_INSTALLER_SHA256:-}"
# detect | remediate | both — default runs detect then remediates if anything is non-compliant.
SAFE_CHAIN_MOSYLE_MODE="${SAFE_CHAIN_MOSYLE_MODE:-both}"

LOG_DIR="/var/log/safe-chain-mosyle"
MAIN_LOG="${LOG_DIR}/safe-chain.log"
USER_LOG="${LOG_DIR}/user.log"

mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"
touch "$MAIN_LOG" "$USER_LOG"
chmod 644 "$MAIN_LOG" "$USER_LOG"

log_main() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$MAIN_LOG"
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
        log_main "ERROR: Unable to fetch latest safe-chain version from GitHub API."
        return 1
    fi

    echo "$latest_version"
}

normalize_version() {
    local s
    s=$(printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^[vV]//')
    [ -z "$s" ] && { printf '%s' ''; return 0; }
    if printf '%s' "$s" | grep -Eq '^[0-9]+(\.[0-9]+)*(-[0-9a-zA-Z.]+)?(\+[0-9a-zA-Z.]+)?$'; then
        printf '%s' "$s"
        return 0
    fi
    if printf '%s' "$s" | grep -Eq '^[0-9]+(\.[0-9]+)*[a-zA-Z][0-9a-zA-Z]*$'; then
        printf '%s' "$s"
        return 0
    fi
    if printf '%s' "$s" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
        printf '%s' "$s"
        return 0
    fi
    printf '%s' "$s" | sed -E 's/^([0-9]+(\.[0-9]+)*).*/\1/'
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

is_valid_version_compare_token() {
    [ -z "${1:-}" ] && return 1
    printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)*(-[0-9a-zA-Z.]+)?(\+[0-9a-zA-Z.]+)?$' && return 0
    printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)*[a-zA-Z][0-9a-zA-Z]*$' && return 0
    printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)*$' && return 0
    return 1
}

is_safe_release_tag() {
    [ -n "${1:-}" ] && printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+$'
}

is_valid_sha256_hex() {
    [ -n "${1:-}" ] && printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{64}$'
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
        "${user_home}/.profile" \
        "${user_home}/.config/fish/config.fish"; do
        if [ -f "$shell_file" ] && grep -Eq 'safe-chain|\.safe-chain' "$shell_file"; then
            return 0
        fi
    done
    if [ -d "${user_home}/.config/fish/conf.d" ]; then
        for shell_file in "${user_home}/.config/fish/conf.d"/*.fish; do
            if [ -f "$shell_file" ] && grep -Eq 'safe-chain|\.safe-chain' "$shell_file"; then
                return 0
            fi
        done
    fi
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
    local release_tag="$4"
    local installer_sha256="$5"

    local tmp_script
    tmp_script=$(mktemp "/tmp/safe-chain-install-${user}.XXXXXX.sh")

    cat > "$tmp_script" <<EOF
#!/bin/bash
set -u
export HOME="${home_dir}"
export USER="${user}"
export LOGNAME="${user}"
export PATH="\$HOME/.safe-chain/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"

INSTALLER_URL="https://github.com/AikidoSec/safe-chain/releases/download/${release_tag}/install-safe-chain.sh"
INSTALLER_SHA256="${installer_sha256}"

run_installer() {
    if [ -z "\$INSTALLER_SHA256" ]; then
        curl -fsSL "\$INSTALLER_URL" | sh
        return \$?
    fi
    local tmp_inst
    tmp_inst=\$(mktemp "/tmp/safe-chain-installer-${user}.XXXXXX.sh")
    if ! curl -fsSL "\$INSTALLER_URL" -o "\$tmp_inst"; then
        rm -f "\$tmp_inst"
        return 1
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        if ! echo "\$INSTALLER_SHA256  \$tmp_inst" | sha256sum -c -; then
            rm -f "\$tmp_inst"
            return 1
        fi
    elif command -v shasum >/dev/null 2>&1; then
        if ! echo "\$INSTALLER_SHA256  \$tmp_inst" | shasum -a 256 -c -; then
            rm -f "\$tmp_inst"
            return 1
        fi
    else
        rm -f "\$tmp_inst"
        return 1
    fi
    sh "\$tmp_inst"
    local st=\$?
    rm -f "\$tmp_inst"
    return \$st
}

if run_installer; then
    exit 0
fi

OS="macos"
ARCH=""
case "\$(uname -m)" in
    x86_64|amd64) ARCH="x64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) exit 1 ;;
esac

mkdir -p "\$HOME/.safe-chain/bin"
BINARY_URL="https://github.com/AikidoSec/safe-chain/releases/download/${release_tag}/safe-chain-\${OS}-\${ARCH}"
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

    # shellcheck disable=SC2024
    if sudo -u "$user" -H HOME="$home_dir" USER="$user" LOGNAME="$user" /bin/bash "$tmp_script" >> "$USER_LOG" 2>&1; then
        rm -f "$tmp_script"
        return 0
    fi

    rm -f "$tmp_script"
    return 1
}

# --- Globals set by resolve_version_context (must run before detect/remediate) ---
latest_version=""
latest_version_clean=""
min_clean=""

resolve_version_context() {
    latest_version=""
    latest_version_clean=""
    min_clean=""

    case "$SAFE_CHAIN_VERSION_POLICY" in
        latest | minimum) ;;
        *)
            log_main "ERROR: SAFE_CHAIN_VERSION_POLICY must be 'latest' or 'minimum' (got: ${SAFE_CHAIN_VERSION_POLICY})."
            return 1
            ;;
    esac

    if [ "$SAFE_CHAIN_VERSION_POLICY" = "minimum" ] && [ -z "$SAFE_CHAIN_MINIMUM_VERSION" ]; then
        log_main "ERROR: SAFE_CHAIN_MINIMUM_VERSION must be set when SAFE_CHAIN_VERSION_POLICY=minimum."
        return 1
    fi

    if [ -n "$SAFE_CHAIN_INSTALLER_SHA256" ] && [ -z "$SAFE_CHAIN_RELEASE_TAG" ]; then
        log_main "ERROR: SAFE_CHAIN_INSTALLER_SHA256 requires SAFE_CHAIN_RELEASE_TAG."
        return 1
    fi

    if [ -n "$SAFE_CHAIN_INSTALLER_SHA256" ] && ! is_valid_sha256_hex "$SAFE_CHAIN_INSTALLER_SHA256"; then
        log_main "ERROR: SAFE_CHAIN_INSTALLER_SHA256 must be 64 hexadecimal characters."
        return 1
    fi

    if [ "$SAFE_CHAIN_VERSION_POLICY" = "latest" ]; then
        if [ -n "$SAFE_CHAIN_RELEASE_TAG" ]; then
            if ! is_safe_release_tag "$SAFE_CHAIN_RELEASE_TAG"; then
                log_main "ERROR: SAFE_CHAIN_RELEASE_TAG has invalid characters (use only [A-Za-z0-9._-])."
                return 1
            fi
            latest_version=$(printf '%s' "$SAFE_CHAIN_RELEASE_TAG")
            latest_version_clean=$(normalize_version "$latest_version")
            if ! is_valid_version_compare_token "$latest_version_clean"; then
                log_main "ERROR: SAFE_CHAIN_RELEASE_TAG must normalize to a valid version (tag=${SAFE_CHAIN_RELEASE_TAG}, normalized=${latest_version_clean})."
                return 1
            fi
            log_main "Policy=latest (pinned). Release tag ${latest_version}."
        else
            latest_version=$(fetch_latest_version)
            if [ -z "${latest_version:-}" ]; then
                log_main "Failed: could not resolve latest version from GitHub API."
                return 1
            fi
            latest_version_clean=$(normalize_version "$latest_version")
            log_main "Policy=latest. GitHub latest is ${latest_version}."
        fi
    else
        local min_stripped
        min_stripped=$(printf '%s' "$SAFE_CHAIN_MINIMUM_VERSION" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^[vV]//')
        min_clean=$(normalize_version "$SAFE_CHAIN_MINIMUM_VERSION")
        if ! is_valid_version_compare_token "$min_clean"; then
            log_main "ERROR: SAFE_CHAIN_MINIMUM_VERSION normalized to an invalid version (value=${SAFE_CHAIN_MINIMUM_VERSION}, normalized=${min_clean})."
            return 1
        fi
        if ! is_valid_version_compare_token "$min_stripped"; then
            log_main "ERROR: SAFE_CHAIN_MINIMUM_VERSION is not a valid version string after trim (value=${SAFE_CHAIN_MINIMUM_VERSION}, stripped=${min_stripped})."
            return 1
        fi
        if [ "$min_clean" != "$min_stripped" ]; then
            log_main "ERROR: SAFE_CHAIN_MINIMUM_VERSION could not be normalized cleanly (value=${SAFE_CHAIN_MINIMUM_VERSION}, stripped=${min_stripped}, normalized=${min_clean})."
            return 1
        fi
        log_main "Policy=minimum. Required minimum is ${SAFE_CHAIN_MINIMUM_VERSION}."
    fi

    if [ -n "$SAFE_CHAIN_RELEASE_TAG" ] && [ "$SAFE_CHAIN_VERSION_POLICY" = "minimum" ]; then
        if ! is_safe_release_tag "$SAFE_CHAIN_RELEASE_TAG"; then
            log_main "ERROR: SAFE_CHAIN_RELEASE_TAG has invalid characters."
            return 1
        fi
        local _pin_clean
        _pin_clean=$(normalize_version "$SAFE_CHAIN_RELEASE_TAG")
        if ! is_valid_version_compare_token "$_pin_clean"; then
            log_main "ERROR: SAFE_CHAIN_RELEASE_TAG must normalize to a valid version (tag=${SAFE_CHAIN_RELEASE_TAG}, normalized=${_pin_clean})."
            return 1
        fi
    fi

    return 0
}

ensure_install_release_tag() {
    if [ -n "$latest_version" ]; then
        return 0
    fi
    if [ -n "$SAFE_CHAIN_RELEASE_TAG" ]; then
        latest_version=$(printf '%s' "$SAFE_CHAIN_RELEASE_TAG")
        latest_version_clean=$(normalize_version "$latest_version")
        if ! is_valid_version_compare_token "$latest_version_clean"; then
            return 1
        fi
        log_main "Using pinned release tag ${latest_version} for installation."
        return 0
    fi
    latest_version=$(fetch_latest_version)
    if [ -z "${latest_version:-}" ]; then
        return 1
    fi
    latest_version_clean=$(normalize_version "$latest_version")
    log_main "Fetched GitHub latest ${latest_version} for installation."
    return 0
}

# Returns 0 if all eligible users compliant, 1 if remediation needed, 2 if fatal (config/API — do not remediate).
run_detect_phase() {
    log_main "Starting detection phase (mode=${SAFE_CHAIN_MOSYLE_MODE})."

    if ! resolve_version_context; then
        return 2
    fi

    local users_checked=0
    while IFS=":" read -r user uid home_dir; do
        users_checked=$((users_checked + 1))
        local installed_version
        installed_version=$(get_installed_version_for_user "$home_dir")

        if [ -z "$installed_version" ]; then
            log_main "REMEDIATE: ${user} has no safe-chain binary in ${home_dir}/.safe-chain/bin."
            return 1
        fi

        local installed_version_clean
        installed_version_clean=$(normalize_version "$installed_version")
        if [ "$SAFE_CHAIN_VERSION_POLICY" = "latest" ]; then
            if [ "$installed_version_clean" != "$latest_version_clean" ]; then
                log_main "REMEDIATE: ${user} has safe-chain ${installed_version}, expected ${latest_version}."
                return 1
            fi
        else
            if version_is_less "$installed_version_clean" "$min_clean"; then
                log_main "REMEDIATE: ${user} has safe-chain ${installed_version}, below minimum ${SAFE_CHAIN_MINIMUM_VERSION}."
                return 1
            fi
        fi

        if ! has_shell_integration "$home_dir"; then
            log_main "REMEDIATE: ${user} missing shell integration markers."
            return 1
        fi

        log_main "OK: ${user} is on ${installed_version} with shell integration markers."
    done < <(list_target_users)

    if [ "$users_checked" -eq 0 ]; then
        log_main "No eligible local user profiles found."
        return 0
    fi

    log_main "Detection complete: all eligible users compliant."
    return 0
}

run_remediate_phase() {
    log_main "Starting remediation phase."

    if ! resolve_version_context; then
        return 1
    fi

    local users_checked=0
    local users_remediated=0
    local users_failed=0

    while IFS=":" read -r user uid home_dir; do
        users_checked=$((users_checked + 1))
        local installed_version
        installed_version=$(get_installed_version_for_user "$home_dir")
        local installed_version_clean
        installed_version_clean=$(normalize_version "$installed_version")

        local should_install=0

        if [ -z "$installed_version" ]; then
            log_main "Installing safe-chain for ${user}: not installed."
            should_install=1
        elif [ "$SAFE_CHAIN_VERSION_POLICY" = "latest" ]; then
            if [ "$installed_version_clean" != "$latest_version_clean" ]; then
                log_main "Installing safe-chain for ${user}: ${installed_version} -> ${latest_version}."
                should_install=1
            fi
        else
            if version_is_less "$installed_version_clean" "$min_clean"; then
                log_main "Installing safe-chain for ${user}: ${installed_version} below minimum ${SAFE_CHAIN_MINIMUM_VERSION}."
                should_install=1
            fi
        fi

        if [ "$should_install" -eq 0 ] && ! has_shell_integration "$home_dir"; then
            log_main "Installing safe-chain for ${user}: shell integration markers missing."
            should_install=1
        fi

        if [ "$should_install" -eq 0 ]; then
            log_main "Skipping ${user}: already compliant (${installed_version})."
            continue
        fi

        if ! ensure_install_release_tag; then
            users_failed=$((users_failed + 1))
            log_user "ERROR: could not resolve release for installing safe-chain for ${user}."
            continue
        fi

        if run_install_for_user "$user" "$uid" "$home_dir" "$latest_version" "${SAFE_CHAIN_INSTALLER_SHA256:-}"; then
            local post_version
            post_version=$(get_installed_version_for_user "$home_dir")
            local post_version_clean
            post_version_clean=$(normalize_version "$post_version")
            local version_ok=0
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
                log_user "ERROR: ${user} install ran but verification failed (version=${post_version})."
            fi
        else
            users_failed=$((users_failed + 1))
            log_user "ERROR: installation failed for ${user}."
        fi
    done < <(list_target_users)

    log_main "Remediation complete. users_checked=${users_checked}, users_remediated=${users_remediated}, users_failed=${users_failed}."

    if [ "$users_failed" -gt 0 ]; then
        return 1
    fi
    return 0
}

# --- main ---
log_main "mosyle-safe-chain.sh starting (SAFE_CHAIN_MOSYLE_MODE=${SAFE_CHAIN_MOSYLE_MODE})."

case "$SAFE_CHAIN_MOSYLE_MODE" in
    detect)
        run_detect_phase
        rc=$?
        if [ "$rc" -eq 0 ]; then exit 0; fi
        if [ "$rc" -eq 2 ]; then exit 1; fi
        exit 1
        ;;
    remediate)
        if run_remediate_phase; then
            exit 0
        fi
        exit 1
        ;;
    both)
        run_detect_phase
        rc=$?
        if [ "$rc" -eq 0 ]; then
            log_main "Mosyle run finished: no remediation needed."
            exit 0
        fi
        if [ "$rc" -eq 2 ]; then
            log_main "Mosyle run finished: fatal error during detection (not running remediation)."
            exit 1
        fi
        log_main "Detect reported non-compliance; running remediation."
        if run_remediate_phase; then
            log_main "Mosyle run finished: remediation succeeded."
            exit 0
        fi
        log_main "Mosyle run finished: remediation had failures."
        exit 1
        ;;
    *)
        log_main "ERROR: SAFE_CHAIN_MOSYLE_MODE must be detect, remediate, or both (got: ${SAFE_CHAIN_MOSYLE_MODE})."
        exit 1
        ;;
esac
