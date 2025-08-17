#!/bin/bash
set -euo pipefail

# Phase 3: Security Setup (Free Tier)
# Implements essential security hardening within free tier constraints

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}INFO${NC}: $*"
}

log_success() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}SUCCESS${NC}: $*"
}

log_warning() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}WARNING${NC}: $*"
}

log_error() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}ERROR${NC}: $*"
}

error() {
  log_error "$*"
  exit 1
}

# Parse arguments
ENVIRONMENT="production"

while [[ $# -gt 0 ]]; do
  case $1 in
    --environment)
      ENVIRONMENT="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# Load configuration
CONFIG_FILE="${PARENT_DIR}/config/${ENVIRONMENT}.env"
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi

# Load instance information
INSTANCE_INFO_FILE="${PARENT_DIR}/instance-info.env"
if [[ -f "$INSTANCE_INFO_FILE" ]]; then
  source "$INSTANCE_INFO_FILE"
else
  error "Instance information not found. Run Phase 2 first."
fi

# Set defaults
PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}
REGION=${REGION:-"us-central1"}
ZONE=${ZONE:-"us-central1-a"}
API_KEY_SECRET_NAME=${API_KEY_SECRET_NAME:-"claude-router-api-key"}
RATE_LIMIT_MAX=${RATE_LIMIT_MAX:-30}

# Resource names
RESOURCE_PREFIX="${PROJECT_ID}-claude-router"
SERVICE_ACCOUNT_NAME="${RESOURCE_PREFIX}-sa"

log_info "Phase 3: Security setup started"
log_info "Environment: $ENVIRONMENT"
log_info "Instance: $INSTANCE_NAME"

# Function to generate API key
generate_api_key() {
  log_info "Generating API key..."
  
  # Generate a secure API key
  API_KEY=$(openssl rand -hex 32)
  
  if [[ -z "$API_KEY" ]]; then
    error "Failed to generate API key"
  fi
  
  log_success "✅ API key generated"
  echo "$API_KEY"
}

# Function to store secrets in Secret Manager
setup_secret_manager() {
  log_info "Setting up Secret Manager..."
  
  # Check if secret already exists
  if gcloud secrets describe "$API_KEY_SECRET_NAME" --quiet 2>/dev/null; then
    log_success "✅ Secret $API_KEY_SECRET_NAME already exists"
    
    # Get the existing secret value (for verification)
    EXISTING_API_KEY=$(gcloud secrets versions access latest --secret="$API_KEY_SECRET_NAME" 2>/dev/null || echo "")
    if [[ -n "$EXISTING_API_KEY" ]]; then
      API_KEY="$EXISTING_API_KEY"
      log_success "✅ Using existing API key"
    else
      log_warning "⚠️  Existing secret appears to be empty, regenerating..."
      API_KEY=$(generate_api_key)
      echo "$API_KEY" | gcloud secrets versions add "$API_KEY_SECRET_NAME" --data-file=-
    fi
  else
    log_info "Creating secret: $API_KEY_SECRET_NAME"
    
    # Create the secret
    gcloud secrets create "$API_KEY_SECRET_NAME" \
      --replication-policy="automatic" \
      --labels="app=claude-router,tier=free" \
      --quiet
    
    # Generate and store API key
    API_KEY=$(generate_api_key)
    echo "$API_KEY" | gcloud secrets versions add "$API_KEY_SECRET_NAME" --data-file=-
    
    log_success "✅ Secret $API_KEY_SECRET_NAME created"
  fi
  
  # Grant service account access to the secret
  log_info "Granting service account access to secret..."
  gcloud secrets add-iam-policy-binding "$API_KEY_SECRET_NAME" \
    --member="serviceAccount:${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor" \
    --quiet > /dev/null 2>&1 || true
  
  log_success "✅ Service account granted access to secret"
  
  # Save API key for health checks
  echo "API_KEY=\"$API_KEY\"" > "${PARENT_DIR}/api-key.env"
  chmod 600 "${PARENT_DIR}/api-key.env"
  
  log_success "✅ API key saved to api-key.env"
}

# Function to create Caddyfile
create_caddyfile() {
  log_info "Creating Caddyfile configuration..."
  
  cat > /tmp/Caddyfile << EOF
# Caddyfile for Claude Code Router (Free Tier)
# Automatic HTTPS with Let's Encrypt

# HTTP to HTTPS redirect
:80 {
    # Redirect all HTTP traffic to HTTPS
    redir https://{host}{uri} permanent
}

# HTTPS configuration
:443 {
    # Automatic HTTPS with Let's Encrypt
    tls internal
    
    # Security headers
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
        X-Robots-Tag "noindex, nofollow"
    }
    
    # Rate limiting at reverse proxy level (free tier optimized)
    @ratelimited {
        remote_ip 10.0.0.0/8 192.168.0.0/16 172.16.0.0/12
        not path /health
    }
    
    # Reverse proxy to Node.js application
    reverse_proxy localhost:3456 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        
        # Health check
        health_uri /health
        health_interval 30s
        health_timeout 5s
    }
    
    # Logging (minimal for free tier)
    log {
        output file /var/log/caddy/access.log {
            roll_size 10MB
            roll_keep 2
        }
        format console
        level ERROR
    }
}

# Admin endpoint (localhost only)
:2019 {
    bind localhost
}
EOF

  log_success "✅ Caddyfile created"
}

# Function to create startup script for the application
create_app_startup_script() {
  log_info "Creating application startup script..."
  
  cat > /tmp/start.sh << 'EOF'
#!/bin/bash
set -euo pipefail

# Startup script for Claude Code Router (Free Tier)
echo "[$(date)] Starting Claude Code Router services..."

# Set memory limits for free tier (1GB total)
export NODE_OPTIONS="--max-old-space-size=768"
export UV_THREADPOOL_SIZE=4

# Start Caddy in background
echo "[$(date)] Starting Caddy..."
caddy start --config /etc/caddy/Caddyfile &
CADDY_PID=$!

# Wait for Caddy to start
sleep 5

# Verify Caddy is running
if ! kill -0 $CADDY_PID 2>/dev/null; then
    echo "[$(date)] ERROR: Caddy failed to start"
    exit 1
fi

echo "[$(date)] Caddy started successfully (PID: $CADDY_PID)"

# Start Node.js application in foreground
echo "[$(date)] Starting Node.js application..."
cd /app

# Ensure proper ownership
chown -R claude-router:claude-router /app

# Start the application as claude-router user
exec su claude-router -s /bin/bash -c "cd /app && node dist/cli.js start"
EOF

  chmod +x /tmp/start.sh
  log_success "✅ Application startup script created"
}

# Function to create systemd services
create_systemd_services() {
  log_info "Creating systemd service configurations..."
  
  # Main Claude Router service
  cat > /tmp/claude-router.service << EOF
[Unit]
Description=Claude Code Router Service (Free Tier)
After=network.target
StartLimitIntervalSec=0
Wants=caddy.service

[Service]
Type=simple
Restart=always
RestartSec=10
User=claude-router
Group=claude-router
WorkingDirectory=/app
Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--max-old-space-size=768
Environment=UV_THREADPOOL_SIZE=4
ExecStart=/usr/bin/node /app/dist/cli.js start
ExecReload=/bin/kill -HUP \$MAINPID

# Memory limits for free tier
MemoryMax=800M
MemorySwapMax=0

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/app
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=claude-router

[Install]
WantedBy=multi-user.target
EOF

  # Caddy service configuration
  cat > /tmp/caddy.service << EOF
[Unit]
Description=Caddy Web Server (Free Tier)
After=network.target
Wants=network.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile
Restart=always
RestartSec=5

# Memory limits for free tier
MemoryMax=200M
MemorySwapMax=0

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/caddy /var/lib/caddy
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=caddy

[Install]
WantedBy=multi-user.target
EOF

  log_success "✅ Systemd service configurations created"
}

# Function to upload and configure files on the instance
configure_instance() {
  log_info "Configuring instance with security settings..."
  
  # Upload Caddyfile
  log_info "Uploading Caddyfile..."
  gcloud compute scp /tmp/Caddyfile "$INSTANCE_NAME":/tmp/Caddyfile --zone="$ZONE" --quiet
  
  # Upload startup script
  log_info "Uploading startup script..."
  gcloud compute scp /tmp/start.sh "$INSTANCE_NAME":/tmp/start.sh --zone="$ZONE" --quiet
  
  # Upload systemd services
  log_info "Uploading systemd services..."
  gcloud compute scp /tmp/claude-router.service "$INSTANCE_NAME":/tmp/claude-router.service --zone="$ZONE" --quiet
  gcloud compute scp /tmp/caddy.service "$INSTANCE_NAME":/tmp/caddy.service --zone="$ZONE" --quiet
  
  # Execute configuration script on the instance
  log_info "Executing security configuration on instance..."
  
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    # Configure Caddy
    sudo mkdir -p /etc/caddy /var/log/caddy /var/lib/caddy
    sudo mv /tmp/Caddyfile /etc/caddy/Caddyfile
    sudo chown -R caddy:caddy /etc/caddy /var/log/caddy /var/lib/caddy
    sudo chmod 644 /etc/caddy/Caddyfile
    
    # Install systemd services
    sudo mv /tmp/claude-router.service /etc/systemd/system/claude-router.service
    sudo mv /tmp/caddy.service /etc/systemd/system/caddy.service
    sudo chmod 644 /etc/systemd/system/claude-router.service
    sudo chmod 644 /etc/systemd/system/caddy.service
    
    # Install startup script
    sudo mv /tmp/start.sh /usr/local/bin/start-claude-router.sh
    sudo chmod +x /usr/local/bin/start-claude-router.sh
    
    # Reload systemd
    sudo systemctl daemon-reload
    
    # Enable services (but don't start yet - application not deployed)
    sudo systemctl enable caddy
    sudo systemctl enable claude-router
    
    echo 'Security configuration completed successfully'
  "
  
  log_success "✅ Instance configured with security settings"
}

# Function to configure fail2ban
configure_fail2ban() {
  log_info "Configuring fail2ban for SSH protection..."
  
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    # Create fail2ban configuration for SSH
    sudo tee /etc/fail2ban/jail.local > /dev/null << 'FAIL2BAN_EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
FAIL2BAN_EOF
    
    # Restart fail2ban
    sudo systemctl restart fail2ban
    sudo systemctl enable fail2ban
    
    echo 'fail2ban configured successfully'
  "
  
  log_success "✅ fail2ban configured"
}

# Function to create application user and directories
setup_application_user() {
  log_info "Setting up application user and directories..."
  
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    # Create application directory
    sudo mkdir -p /app
    
    # Create claude-router user if it doesn't exist
    if ! id claude-router &>/dev/null; then
        sudo useradd -r -s /bin/false -d /app claude-router
    fi
    
    # Set up directory permissions
    sudo chown -R claude-router:claude-router /app
    sudo chmod 755 /app
    
    # Create configuration directory
    sudo mkdir -p /home/claude-router/.claude-code-router
    sudo chown claude-router:claude-router /home/claude-router/.claude-code-router
    sudo chmod 755 /home/claude-router/.claude-code-router
    
    echo 'Application user and directories configured'
  "
  
  log_success "✅ Application user and directories configured"
}

# Function to clean up temporary files
cleanup_temp_files() {
  log_info "Cleaning up temporary files..."
  
  rm -f /tmp/Caddyfile
  rm -f /tmp/start.sh
  rm -f /tmp/claude-router.service
  rm -f /tmp/caddy.service
  
  log_success "✅ Temporary files cleaned up"
}

# Function to test security configuration
test_security() {
  log_info "Testing security configuration..."
  
  # Test that services are enabled
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    systemctl is-enabled caddy
    systemctl is-enabled claude-router
    systemctl is-enabled fail2ban
    systemctl is-active fail2ban
  " > /dev/null 2>&1
  
  log_success "✅ Security services are properly configured"
  
  # Test firewall
  log_info "Testing firewall rules..."
  if gcloud compute firewall-rules describe "${RESOURCE_PREFIX}-allow-https" --quiet > /dev/null 2>&1; then
    log_success "✅ HTTPS firewall rule is active"
  else
    log_error "❌ HTTPS firewall rule not found"
  fi
}

# Main execution
main() {
  setup_secret_manager
  create_caddyfile
  create_app_startup_script
  create_systemd_services
  configure_instance
  configure_fail2ban
  setup_application_user
  cleanup_temp_files
  test_security
  
  log_success "🎉 Phase 3 completed successfully"
  
  echo -e "\n${GREEN}✅ Security setup completed!${NC}"
  echo -e "${BLUE}API Key: Stored in Secret Manager (${API_KEY_SECRET_NAME})${NC}"
  echo -e "${BLUE}Services: Caddy and Claude Router configured${NC}"
  echo -e "${YELLOW}💡 Next: Run Phase 4 (Application Deployment)${NC}"
  
  if [[ -f "${PARENT_DIR}/api-key.env" ]]; then
    source "${PARENT_DIR}/api-key.env"
    echo -e "${YELLOW}🔑 API Key for testing: ${API_KEY}${NC}"
    echo -e "${YELLOW}   (Keep this secure - also stored in Secret Manager)${NC}"
  fi
}

# Run main function
main "$@"