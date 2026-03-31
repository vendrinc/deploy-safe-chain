#!/bin/bash

# Log files for both root and user operations
ROOT_LOG="/var/log/vendr-dev-proxy/remediate_root.log"
USER_LOG="/var/log/vendr-dev-proxy/remediate_user.log"

# Configuration
CONTAINER_NAME="vendr-dev-local-proxy"
IMAGE="nginxproxy/nginx-proxy:1.7-alpine"
NETWORK_NAME="vendr-local"

# Get logged in user
loggedInUser=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && $3 != "loginwindow" { print $3 }')

if [[ -z "$loggedInUser" ]]; then
    echo "No user logged in. Cannot proceed with remediation."
    exit 1
fi

# Create log directories with proper permissions
LOG_DIR="/var/log/vendr-dev-proxy"
mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"
touch "$ROOT_LOG" "$USER_LOG"
chmod 644 "$ROOT_LOG" "$USER_LOG"
chown "$loggedInUser" "$USER_LOG"
chown root "$ROOT_LOG"

# Function to log root-level messages
log_root() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$ROOT_LOG"
}

log_root "Starting remediation for user: $loggedInUser"

# Create a temporary script that will be executed as the user
cat > /tmp/container-setup.sh << EOL
#!/bin/bash

# Log file for user-level operations
USER_LOG="/var/log/vendr-dev-proxy/remediate_user.log"

# Function to log user-level messages
log_user() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$USER_LOG"
}

# Configuration
CONTAINER_NAME="$CONTAINER_NAME"
IMAGE="$IMAGE"
CERT_PATH="\${HOME}/Library/vendr/devproxy"
NETWORK_NAME="$NETWORK_NAME"

# Ensure Docker is in PATH
export PATH="/usr/local/bin:/usr/bin:/bin:\$PATH"

log_user "Starting container setup..."
log_user "Current user: \$(whoami)"
log_user "Current directory: \$(pwd)"
log_user "Docker path: \$(which docker)"
log_user "PATH: \$PATH"

# Create network if it doesn't exist
if ! docker network ls | grep -q \$NETWORK_NAME; then
    log_user "Creating Docker network: \$NETWORK_NAME"
    if ! docker network create \$NETWORK_NAME; then
        log_user "ERROR: Failed to create Docker network"
        exit 1
    fi
fi

# Stop and remove existing container if it exists
if docker ps -a | grep -q \$CONTAINER_NAME; then
    log_user "Stopping and removing existing \$CONTAINER_NAME container..."
    if ! docker stop \$CONTAINER_NAME >/dev/null 2>&1; then
        log_user "Warning: Failed to stop existing container"
    fi
    if ! docker rm \$CONTAINER_NAME >/dev/null 2>&1; then
        log_user "Warning: Failed to remove existing container"
    fi
fi

# Ensure certificate directory exists
if ! mkdir -p "\$CERT_PATH"; then
    log_user "ERROR: Failed to create certificate directory: \$CERT_PATH"
    exit 1
fi
log_user "Ensuring certificate directory exists: \$CERT_PATH"

# Verify directory was created successfully
if [[ ! -d "\$CERT_PATH" ]]; then
    log_user "ERROR: Certificate directory does not exist after creation: \$CERT_PATH"
    exit 1
fi

# Write overrides configuration file
log_user "Writing nginx overrides configuration file..."
rmdir "\$CERT_PATH/_overrides_v3.conf"
touch "\$CERT_PATH/_overrides_v3.conf"
cat > "\$CERT_PATH/_overrides_v3.conf" << 'OVERRIDES_CONFIG'
# max request body is 150mb
client_max_body_size 150m;
# stream requests upstream
proxy_request_buffering off;
# stream responses downstream (required for SSE)
proxy_buffering off;
# extended beyond default 60s for LLM streaming responses
proxy_read_timeout 300s;
# increased buffer sizes to handle large headers from upstream
proxy_buffer_size 16k;
proxy_buffers 8 16k;
proxy_busy_buffers_size 32k;
OVERRIDES_CONFIG

# Write nginx configuration file
log_user "Writing nginx configuration file..."
rmdir "\$CERT_PATH/ironzion-proxy-v1_7.conf"
touch "\$CERT_PATH/ironzion-proxy-v1_7.conf"
cat > "\$CERT_PATH/ironzion-proxy-v1_7.conf" << 'NGINX_CONFIG'
# app.local.vendr-dev.com/
upstream app.local.vendr-dev.com {
    # Accessing Ironzion Elm server on the host machine
    server host.docker.internal:3001;
    keepalive 2;
}
server {
    server_name app.local.vendr-dev.com;
    access_log /var/log/nginx/access.log vhost;
    listen 80 ;
    # Do not HTTPS redirect Let's Encrypt ACME challenge
    location ^~ /.well-known/acme-challenge/ {
        auth_basic off;
        auth_request off;
        allow all;
        root /usr/share/nginx/html;
        try_files \$uri =404;
        break;
    }
    location / {
        if (\$request_method ~ (OPTIONS|POST|PUT|PATCH|DELETE)) {
            return 301 https://\$host\$request_uri;
        }
        return 301 https://\$host\$request_uri;
    }
}
server {
    server_name app.local.vendr-dev.com;
    access_log /var/log/nginx/access.log vhost;
    http2 on;
    listen 443 ssl ;
    ssl_session_timeout 5m;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    ssl_certificate /etc/nginx/certs/local.vendr-dev.com.crt;
    ssl_certificate_key /etc/nginx/certs/local.vendr-dev.com.key;
    set \$sts_header "";
    if (\$https) {
        set \$sts_header "max-age=31536000";
    }
    add_header Strict-Transport-Security \$sts_header always;
    location / {
        proxy_pass http://app.local.vendr-dev.com;
        set \$upstream_keepalive true;
    }
}

# graphql.local.vendr-dev.com/
upstream graphql.local.vendr-dev.com {
    # Accessing Ironzion serverless offline on the host machine
    server host.docker.internal:3000;
    keepalive 2;
}
server {
    server_name graphql.local.vendr-dev.com;
    access_log /var/log/nginx/access.log vhost;
    listen 80 ;
    # Do not HTTPS redirect Let's Encrypt ACME challenge
    location ^~ /.well-known/acme-challenge/ {
        auth_basic off;
        auth_request off;
        allow all;
        root /usr/share/nginx/html;
        try_files \$uri =404;
        break;
    }
    location / {
        if (\$request_method ~ (OPTIONS|POST|PUT|PATCH|DELETE)) {
            return 301 https://\$host\$request_uri;
        }
        return 301 https://\$host\$request_uri;
    }
}
server {
    server_name graphql.local.vendr-dev.com;
    access_log /var/log/nginx/access.log vhost;
    http2 on;
    listen 443 ssl ;
    ssl_session_timeout 5m;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    ssl_certificate /etc/nginx/certs/local.vendr-dev.com.crt;
    ssl_certificate_key /etc/nginx/certs/local.vendr-dev.com.key;
    set \$sts_header "";
    if (\$https) {
        set \$sts_header "max-age=31536000";
    }
    add_header Strict-Transport-Security \$sts_header always;
    location / {
        proxy_pass http://graphql.local.vendr-dev.com;
        set \$upstream_keepalive true;
    }
}
NGINX_CONFIG

# Run Nginx container
log_user "Starting Nginx proxy container..."
if ! docker run -d \\
    --name \$CONTAINER_NAME \\
    --network-alias backoffice.local.vendr-dev.com \\
    --network-alias api.local.vendr-dev.com \\
    --network-alias www.local.vendr-dev.com \\
    --network-alias mcp.local.vendr-dev.com \\
    --network-alias mcp-internal.local.vendr-dev.com \\
    --network-alias stratus.local.vendr-dev.com \\
    --network-alias agent.local.vendr-dev.com \\
    -p 80:80 \\
    -p 443:443 \\
    -v \$CERT_PATH:/etc/nginx/certs:ro \\
    -v /var/run/docker.sock:/tmp/docker.sock:ro \\
    -v \$CERT_PATH/_overrides_v3.conf:/etc/nginx/conf.d/_overrides.conf \\
    -v \$CERT_PATH/ironzion-proxy-v1_7.conf:/etc/nginx/conf.d/ironzion-proxy-v1_7.conf \\
    -e TRUST_DOWNSTREAM_PROXY=false \\
    --network \$NETWORK_NAME \\
    --add-host host.docker.internal:host-gateway \\
    --restart unless-stopped \\
    \$IMAGE 2>> "\$USER_LOG"; then
    
    log_user "ERROR: Failed to start container. Check logs for details."
    exit 1
fi

# Verify container is running
if ! docker ps | grep -q \$CONTAINER_NAME; then
    log_user "ERROR: Container failed to start properly"
    exit 1
fi

log_user "Nginx proxy container started successfully!"
EOL

# Make the temporary script executable
chmod +x /tmp/container-setup.sh

# Execute the script as the logged-in user and capture output
log_root "Executing container setup as user: $loggedInUser"
if ! sudo -u "$loggedInUser" -H /tmp/container-setup.sh 2>&1 | tee -a "$USER_LOG"; then
    log_root "ERROR: Container setup failed. Check user logs for details."
    rm /tmp/container-setup.sh
    exit 1
fi

# Clean up
rm /tmp/container-setup.sh

log_root "Remediation completed successfully."
exit 0