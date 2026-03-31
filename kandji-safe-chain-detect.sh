#!/bin/bash

set -u

# Version policy:
#   latest — compare installed version to the expected release (see SAFE_CHAIN_RELEASE_TAG).
#   minimum — non‑compliant only if missing, below SAFE_CHAIN_MINIMUM_VERSION, or shell integration missing.
#             Does not call the GitHub API for version comparison (only local vs minimum).
#
# Default is pinned to release 1.4.6 (no GitHub API). To track GitHub "latest" instead, clear the pin, e.g.:
#   export SAFE_CHAIN_RELEASE_TAG=""
# (Use ${VAR-default} below so an explicit empty value means “no pin”.)
SAFE_CHAIN_VERSION_POLICY="${SAFE_CHAIN_VERSION_POLICY:-latest}"
SAFE_CHAIN_MINIMUM_VERSION="${SAFE_CHAIN_MINIMUM_VERSION:-}"
# Exact GitHub release tag for URLs; must match the tag on github.com/AikidoSec/safe-chain/releases
SAFE_CHAIN_RELEASE_TAG="${SAFE_CHAIN_RELEASE_TAG-1.4.6}"
# Optional: sha256 of install-safe-chain.sh; must be set together with SAFE_CHAIN_RELEASE_TAG (remediate only).

LOG_FILE="/var/log/safe-chain-kandji/detect.log"
LOG_DIR="$(dirname "$LOG_FILE")"
mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
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
        log "ERROR: Unable to fetch latest safe-chain version from GitHub API."
        return 1
    fi

    echo "$latest_version"
}

# Strip leading v/whitespace; keep a token sort -V can compare (1.4.6, 2.5.0a, 2.5.0-rc.1, 1.0.0+build).
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

# True if the string is usable for version compare (minimum, pins, equality checks).
is_valid_version_compare_token() {
    [ -z "${1:-}" ] && return 1
    printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)*(-[0-9a-zA-Z.]+)?(\+[0-9a-zA-Z.]+)?$' && return 0
    printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)*[a-zA-Z][0-9a-zA-Z]*$' && return 0
    printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)*$' && return 0
    return 1
}

# GitHub release tag used in URL path: allow only safe characters.
is_safe_release_tag() {
    [ -n "${1:-}" ] && printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+$'
}

# True if normalized semver a is strictly less than b (uses sort -V; 1.2.2 < 1.4.6).
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

log "Starting safe-chain detection."
case "$SAFE_CHAIN_VERSION_POLICY" in
    latest | minimum) ;;
    *)
        log "ERROR: SAFE_CHAIN_VERSION_POLICY must be 'latest' or 'minimum' (got: ${SAFE_CHAIN_VERSION_POLICY})."
        exit 1
        ;;
esac

if [ "$SAFE_CHAIN_VERSION_POLICY" = "minimum" ] && [ -z "$SAFE_CHAIN_MINIMUM_VERSION" ]; then
    log "ERROR: SAFE_CHAIN_MINIMUM_VERSION must be set when SAFE_CHAIN_VERSION_POLICY=minimum."
    exit 1
fi

latest_version=""
latest_version_clean=""
min_clean=""
if [ "$SAFE_CHAIN_VERSION_POLICY" = "latest" ]; then
    if [ -n "$SAFE_CHAIN_RELEASE_TAG" ]; then
        if ! is_safe_release_tag "$SAFE_CHAIN_RELEASE_TAG"; then
            log "ERROR: SAFE_CHAIN_RELEASE_TAG has invalid characters (use only [A-Za-z0-9._-])."
            exit 1
        fi
        latest_version=$(printf '%s' "$SAFE_CHAIN_RELEASE_TAG")
        latest_version_clean=$(normalize_version "$latest_version")
        if ! is_valid_version_compare_token "$latest_version_clean"; then
            log "ERROR: SAFE_CHAIN_RELEASE_TAG must normalize to a dotted version (e.g. 1.4.6); got tag=${SAFE_CHAIN_RELEASE_TAG} normalized=${latest_version_clean}."
            exit 1
        fi
        log "Policy=latest (pinned). Expected release tag ${latest_version} (compare as ${latest_version_clean})."
    else
        latest_version=$(fetch_latest_version)
        if [ -z "${latest_version:-}" ]; then
            log "Detection failed: could not resolve latest version."
            exit 1
        fi
        latest_version_clean=$(normalize_version "$latest_version")
        log "Policy=latest. Latest GitHub release is ${latest_version}."
    fi
else
    # Sanity-check minimum: normalize must yield a valid token and match trim-only (no silent truncation).
    min_stripped=$(printf '%s' "$SAFE_CHAIN_MINIMUM_VERSION" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^[vV]//')
    min_clean=$(normalize_version "$SAFE_CHAIN_MINIMUM_VERSION")
    if ! is_valid_version_compare_token "$min_clean"; then
        log "ERROR: SAFE_CHAIN_MINIMUM_VERSION normalized to an invalid version (value=${SAFE_CHAIN_MINIMUM_VERSION}, normalized=${min_clean})."
        exit 1
    fi
    if ! is_valid_version_compare_token "$min_stripped"; then
        log "ERROR: SAFE_CHAIN_MINIMUM_VERSION is not a valid version string after trim (value=${SAFE_CHAIN_MINIMUM_VERSION}, stripped=${min_stripped})."
        exit 1
    fi
    if [ "$min_clean" != "$min_stripped" ]; then
        log "ERROR: SAFE_CHAIN_MINIMUM_VERSION could not be normalized cleanly — reject extra or invalid characters (value=${SAFE_CHAIN_MINIMUM_VERSION}, stripped=${min_stripped}, normalized=${min_clean})."
        exit 1
    fi
    log "Policy=minimum. Required minimum version is ${SAFE_CHAIN_MINIMUM_VERSION} (normalized ${min_clean})."
fi

users_checked=0

while IFS=":" read -r user uid home_dir; do
    users_checked=$((users_checked + 1))
    installed_version=$(get_installed_version_for_user "$home_dir")

    if [ -z "$installed_version" ]; then
        log "REMEDIATE: ${user} has no safe-chain binary in ${home_dir}/.safe-chain/bin."
        exit 1
    fi

    installed_version_clean=$(normalize_version "$installed_version")
    if [ "$SAFE_CHAIN_VERSION_POLICY" = "latest" ]; then
        if [ "$installed_version_clean" != "$latest_version_clean" ]; then
            log "REMEDIATE: ${user} has safe-chain ${installed_version}, expected ${latest_version}."
            exit 1
        fi
    else
        if version_is_less "$installed_version_clean" "$min_clean"; then
            log "REMEDIATE: ${user} has safe-chain ${installed_version}, below minimum ${SAFE_CHAIN_MINIMUM_VERSION}."
            exit 1
        fi
    fi

    if ! has_shell_integration "$home_dir"; then
        log "REMEDIATE: ${user} missing shell integration markers in profile files."
        exit 1
    fi

    log "OK: ${user} is on ${installed_version} with shell integration markers."
done < <(list_target_users)

if [ "$users_checked" -eq 0 ]; then
    log "No eligible local user profiles found. No remediation needed."
    exit 0
fi

log "Detection complete: all eligible users compliant."
exit 0
