#!/bin/bash

# Log file for root-level operations
LOG_FILE="/var/log/vendr-dev-proxy/detect.log"
mkdir -p "$(dirname "$LOG_FILE")"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Log current PATH and environment
log_message "Current PATH: $PATH"
log_message "Current working directory: $(pwd)"

# Common Docker locations
DOCKER_LOCATIONS=(
    "/usr/local/bin/docker"
    "/usr/bin/docker"
    "/opt/homebrew/bin/docker"
    "/opt/vboxdrv/docker"
    "$(which docker 2>/dev/null)"
)

# Find Docker binary
DOCKER_BINARY=""
for location in "${DOCKER_LOCATIONS[@]}"; do
    if [[ -x "$location" ]]; then
        DOCKER_BINARY="$location"
        log_message "Found Docker at: $location"
        break
    fi
done

if [[ -z "$DOCKER_BINARY" ]]; then
    log_message "Docker not found in any common locations. Exiting clean."
    exit 0
fi

# Check if Docker is installed
if ! "$DOCKER_BINARY" --version &> /dev/null; then
    log_message "Docker binary found but not working. Exiting clean."
    exit 0
fi

# Check if Docker daemon is running
if ! "$DOCKER_BINARY" info &> /dev/null; then
    log_message "Docker daemon is not running. Exiting clean."
    exit 0
fi

# Get logged in user
loggedInUser=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && $3 != "loginwindow" { print $3 }')

# Check if user is logged in
if [[ -z "$loggedInUser" ]]; then
    log_message "No user logged in. Exiting clean."
    exit 0
fi

# Check for certificate file
if [[ ! -f "/Users/${loggedInUser}/Library/vendr/devproxy/local.vendr-dev.com.crt" ]]; then
    log_message "Certificate file not found. Exiting clean."
    exit 0
fi

# Check for nginx configuration file
if [[ ! -f "/Users/${loggedInUser}/Library/vendr/devproxy/ironzion-proxy-v1_7.conf" ]]; then
    log_message "Ironzion proxy configuration file not found. Remediation required."
    exit 1
fi

# Check for overrides configuration file
if [[ ! -f "/Users/${loggedInUser}/Library/vendr/devproxy/_overrides_v3.conf" ]]; then
    log_message "Overrides configuration file not found. Remediation required."
    exit 1
fi

# Check if container exists
if ! "$DOCKER_BINARY" ps -a --format '{{.Names}}' | grep -q "vendr-dev-local-proxy"; then
    log_message "Container 'vendr-dev-local-proxy' does not exist. Remediation required."
    exit 1
fi

log_message "All conditions met. No remediation required."
exit 0