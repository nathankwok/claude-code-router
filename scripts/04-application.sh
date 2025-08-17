#!/bin/bash
set -euo pipefail

# Phase 4: Application Deployment (Free Tier)
# Builds and deploys the Claude Code Router application

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

# Load API key
API_KEY_FILE="${PARENT_DIR}/api-key.env"
if [[ -f "$API_KEY_FILE" ]]; then
  source "$API_KEY_FILE"
else
  error "API key not found. Run Phase 3 first."
fi

# Set defaults
PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}
REGION=${REGION:-"us-central1"}
API_KEY_SECRET_NAME=${API_KEY_SECRET_NAME:-"claude-router-api-key"}
RATE_LIMIT_MAX=${RATE_LIMIT_MAX:-30}
MAX_CONNECTIONS=${MAX_CONNECTIONS:-50}

log_info "Phase 4: Application deployment started"
log_info "Environment: $ENVIRONMENT"
log_info "Instance: $INSTANCE_NAME"

# Function to build the application locally
build_application() {
  log_info "Building application locally..."
  
  # Check if we're in the right directory
  if [[ ! -f "${PARENT_DIR}/package.json" ]]; then
    error "package.json not found. Please run from the project root directory."
  fi
  
  cd "$PARENT_DIR"
  
  # Install dependencies with memory constraints
  log_info "Installing dependencies..."
  if command -v pnpm &> /dev/null; then
    NODE_OPTIONS="--max-old-space-size=2048" pnpm install --frozen-lockfile
  else
    log_warning "pnpm not found, using npm..."
    NODE_OPTIONS="--max-old-space-size=2048" npm install
  fi
  
  # Build the application
  log_info "Building application..."
  if command -v pnpm &> /dev/null; then
    NODE_OPTIONS="--max-old-space-size=2048" pnpm run build
  else
    NODE_OPTIONS="--max-old-space-size=2048" npm run build
  fi
  
  # Verify build output
  if [[ ! -d "dist" ]]; then
    error "Build failed - dist directory not found"
  fi
  
  if [[ ! -f "dist/cli.js" ]]; then
    error "Build failed - dist/cli.js not found"
  fi
  
  log_success "✅ Application built successfully"
}

# Function to create deployment package
create_deployment_package() {
  log_info "Creating deployment package..."
  
  cd "$PARENT_DIR"
  
  # Create temporary deployment directory
  DEPLOY_DIR="/tmp/claude-router-deploy"
  rm -rf "$DEPLOY_DIR"
  mkdir -p "$DEPLOY_DIR"
  
  # Copy necessary files
  log_info "Copying application files..."
  cp -r dist "$DEPLOY_DIR/"
  cp package.json "$DEPLOY_DIR/"
  cp pnpm-lock.yaml "$DEPLOY_DIR/" 2>/dev/null || cp package-lock.json "$DEPLOY_DIR/" 2>/dev/null || true
  
  # Copy UI if it exists
  if [[ -d "ui/dist" ]]; then
    log_info "Copying UI files..."
    mkdir -p "$DEPLOY_DIR/ui"
    cp -r ui/dist "$DEPLOY_DIR/ui/"
  fi
  
  # Create production package.json (remove dev dependencies)
  log_info "Creating production package.json..."
  node -e "
    const pkg = require('./package.json');
    delete pkg.devDependencies;
    delete pkg.scripts.build;
    pkg.scripts = pkg.scripts || {};
    pkg.scripts.start = 'node dist/cli.js start';
    require('fs').writeFileSync('$DEPLOY_DIR/package.json', JSON.stringify(pkg, null, 2));
  "
  
  # Create configuration template
  log_info "Creating configuration template..."
  cat > "$DEPLOY_DIR/config.template.json" << EOF
{
  "LOG": true,
  "HOST": "127.0.0.1",
  "PORT": 3456,
  "APIKEY": "API_KEY_PLACEHOLDER",
  "API_TIMEOUT_MS": 300000,
  "LOG_LEVEL": "info",
  "RATE_LIMIT_MAX": ${RATE_LIMIT_MAX},
  "MAX_CONNECTIONS": ${MAX_CONNECTIONS},
  "Providers": [],
  "Router": {
    "default": "",
    "background": "",
    "think": "",
    "longContext": "",
    "webSearch": ""
  },
  "NON_INTERACTIVE_MODE": true
}
EOF

  # Create environment setup script
  cat > "$DEPLOY_DIR/setup-env.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

# Environment setup script for Claude Code Router

echo "Setting up Claude Code Router environment..."

# Get API key from Secret Manager
API_KEY=$(gcloud secrets versions access latest --secret="claude-router-api-key" 2>/dev/null || echo "")

if [[ -z "$API_KEY" ]]; then
    echo "ERROR: Could not retrieve API key from Secret Manager"
    exit 1
fi

# Create configuration directory
mkdir -p ~/.claude-code-router

# Create configuration file from template
sed "s/API_KEY_PLACEHOLDER/$API_KEY/g" /app/config.template.json > ~/.claude-code-router/config.json
chmod 600 ~/.claude-code-router/config.json

echo "Environment setup completed successfully"
EOF
  
  chmod +x "$DEPLOY_DIR/setup-env.sh"
  
  # Create tarball
  log_info "Creating deployment tarball..."
  cd "$DEPLOY_DIR"
  tar -czf "/tmp/claude-router-app.tar.gz" .
  
  log_success "✅ Deployment package created: /tmp/claude-router-app.tar.gz"
}

# Function to upload application to instance
upload_application() {
  log_info "Uploading application to instance..."
  
  # Upload the tarball
  log_info "Uploading deployment package..."
  gcloud compute scp "/tmp/claude-router-app.tar.gz" "$INSTANCE_NAME":/tmp/claude-router-app.tar.gz --zone="$ZONE" --quiet
  
  log_success "✅ Application uploaded to instance"
}

# Function to install application on instance
install_application() {
  log_info "Installing application on instance..."
  
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    echo 'Installing Claude Code Router application...'
    
    # Stop services if running
    sudo systemctl stop claude-router || true
    sudo systemctl stop caddy || true
    
    # Clean up existing installation
    sudo rm -rf /app/*
    
    # Extract application
    cd /tmp
    tar -xzf claude-router-app.tar.gz -C /app
    
    # Set ownership
    sudo chown -R claude-router:claude-router /app
    
    # Install production dependencies with memory constraints
    cd /app
    echo 'Installing production dependencies...'
    sudo -u claude-router NODE_OPTIONS='--max-old-space-size=512' npm install --production --no-audit --no-fund
    
    # Set up environment
    echo 'Setting up environment...'
    sudo -u claude-router bash /app/setup-env.sh
    
    # Clean up npm cache to save space
    sudo -u claude-router npm cache clean --force
    
    # Verify installation
    if [[ ! -f /app/dist/cli.js ]]; then
        echo 'ERROR: Application installation failed - cli.js not found'
        exit 1
    fi
    
    if [[ ! -f /home/claude-router/.claude-code-router/config.json ]]; then
        echo 'ERROR: Configuration setup failed'
        exit 1
    fi
    
    # Test that the application can start (quick test)
    echo 'Testing application startup...'
    cd /app
    timeout 10s sudo -u claude-router NODE_OPTIONS='--max-old-space-size=768' node dist/cli.js --version || true
    
    echo 'Application installation completed successfully'
  "
  
  log_success "✅ Application installed on instance"
}

# Function to start services
start_services() {
  log_info "Starting services..."
  
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    echo 'Starting Caddy service...'
    sudo systemctl start caddy
    sudo systemctl status caddy --no-pager
    
    echo 'Starting Claude Router service...'
    sudo systemctl start claude-router
    
    # Wait a moment for services to initialize
    sleep 10
    
    echo 'Checking service status...'
    sudo systemctl status caddy --no-pager
    sudo systemctl status claude-router --no-pager
    
    # Check if services are listening on expected ports
    echo 'Checking port listeners...'
    ss -tlnp | grep ':80\|:443\|:3456' || true
    
    echo 'Services started successfully'
  "
  
  log_success "✅ Services started"
}

# Function to verify deployment
verify_deployment() {
  log_info "Verifying deployment..."
  
  # Wait for services to be fully ready
  log_info "Waiting for services to be ready..."
  sleep 30
  
  # Test local health endpoint
  log_info "Testing health endpoint..."
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    # Test health endpoint
    curl -f http://localhost:3456/health || {
        echo 'Health check failed on localhost:3456'
        exit 1
    }
    
    echo 'Local health check passed'
  "
  
  # Test external access (if we have external IP)
  if [[ -n "${EXTERNAL_IP:-}" ]]; then
    log_info "Testing external access via HTTP..."
    
    # Test HTTP (should redirect to HTTPS)
    if curl -s -I "http://$EXTERNAL_IP" | grep -q "301\|302"; then
      log_success "✅ HTTP redirect to HTTPS working"
    else
      log_warning "⚠️  HTTP redirect may not be working"
    fi
    
    # Test HTTPS (may take time for certificate)
    log_info "Testing HTTPS access (certificate may take a few minutes)..."
    if curl -k -s -f "https://$EXTERNAL_IP/health" >/dev/null 2>&1; then
      log_success "✅ HTTPS health check passed"
    else
      log_warning "⚠️  HTTPS not ready yet (certificate may still be provisioning)"
    fi
  fi
  
  log_success "✅ Deployment verification completed"
}

# Function to create application configuration
create_app_config() {
  log_info "Creating application configuration..."
  
  # Create a basic configuration file for the application
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    # Ensure config directory exists
    sudo -u claude-router mkdir -p /home/claude-router/.claude-code-router
    
    # Create logs directory
    sudo -u claude-router mkdir -p /home/claude-router/.claude-code-router/logs
    
    # Set proper permissions
    sudo chown -R claude-router:claude-router /home/claude-router/.claude-code-router
    sudo chmod 755 /home/claude-router/.claude-code-router
    
    echo 'Application configuration completed'
  "
  
  log_success "✅ Application configuration created"
}

# Function to cleanup temporary files
cleanup_temp_files() {
  log_info "Cleaning up temporary files..."
  
  rm -rf "/tmp/claude-router-deploy"
  rm -f "/tmp/claude-router-app.tar.gz"
  
  # Clean up on instance
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    rm -f /tmp/claude-router-app.tar.gz
  " || true
  
  log_success "✅ Temporary files cleaned up"
}

# Function to save deployment information
save_deployment_info() {
  log_info "Saving deployment information..."
  
  cat > "${PARENT_DIR}/deployment-info.env" << EOF
# Claude Code Router Deployment Information
DEPLOYED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
INSTANCE_NAME="$INSTANCE_NAME"
EXTERNAL_IP="$EXTERNAL_IP"
ENVIRONMENT="$ENVIRONMENT"
PROJECT_ID="$PROJECT_ID"
API_KEY_SECRET_NAME="$API_KEY_SECRET_NAME"

# Access URLs
HTTP_URL="http://$EXTERNAL_IP"
HTTPS_URL="https://$EXTERNAL_IP"
HEALTH_URL="https://$EXTERNAL_IP/health"
EOF
  
  log_success "✅ Deployment information saved to deployment-info.env"
}

# Main execution
main() {
  build_application
  create_deployment_package
  upload_application
  install_application
  create_app_config
  start_services
  verify_deployment
  save_deployment_info
  cleanup_temp_files
  
  log_success "🎉 Phase 4 completed successfully"
  
  echo -e "\n${GREEN}✅ Application deployed successfully!${NC}"
  
  if [[ -n "${EXTERNAL_IP:-}" ]]; then
    echo -e "${BLUE}Access URLs:${NC}"
    echo -e "  HTTP:  http://$EXTERNAL_IP (redirects to HTTPS)"
    echo -e "  HTTPS: https://$EXTERNAL_IP"
    echo -e "  Health: https://$EXTERNAL_IP/health"
    echo -e ""
    echo -e "${YELLOW}🔑 API Key: ${API_KEY}${NC}"
    echo -e "${YELLOW}   Use this in the X-API-Key header for requests${NC}"
    echo -e ""
    echo -e "${YELLOW}⚠️  HTTPS certificate may take a few minutes to provision${NC}"
    echo -e "${YELLOW}💡 Next: Run Phase 5 (Monitoring Setup)${NC}"
  else
    echo -e "${BLUE}Application deployed to instance: $INSTANCE_NAME${NC}"
    echo -e "${YELLOW}💡 Next: Run Phase 5 (Monitoring Setup)${NC}"
  fi
}

# Run main function
main "$@"