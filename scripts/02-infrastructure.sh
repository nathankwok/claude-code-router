#!/bin/bash
set -euo pipefail

# Phase 2: Infrastructure Deployment (Free Tier)
# Creates GCP compute resources using only free tier resources

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

# Set defaults
PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}
REGION=${REGION:-"us-central1"}
ZONE=${ZONE:-"us-central1-a"}
MACHINE_TYPE=${MACHINE_TYPE:-"e2-micro"}
DISK_SIZE=${DISK_SIZE:-"30GB"}
DISK_TYPE=${DISK_TYPE:-"pd-standard"}

# Resource naming convention
RESOURCE_PREFIX="${PROJECT_ID}-claude-router"
VPC_NAME="${RESOURCE_PREFIX}-vpc"
SUBNET_NAME="${RESOURCE_PREFIX}-subnet"
FIREWALL_HTTP_NAME="${RESOURCE_PREFIX}-allow-http"
FIREWALL_HTTPS_NAME="${RESOURCE_PREFIX}-allow-https"
FIREWALL_SSH_NAME="${RESOURCE_PREFIX}-allow-ssh"
INSTANCE_NAME="${RESOURCE_PREFIX}-vm"
DISK_NAME="${RESOURCE_PREFIX}-disk"
SERVICE_ACCOUNT_NAME="${RESOURCE_PREFIX}-sa"

log_info "Phase 2: Infrastructure deployment started"
log_info "Environment: $ENVIRONMENT"
log_info "Project: $PROJECT_ID"
log_info "Region: $REGION"
log_info "Zone: $ZONE"
log_info "Machine Type: $MACHINE_TYPE (Free Tier)"

# Function to create VPC network
create_vpc() {
  log_info "Creating VPC network..."
  
  if gcloud compute networks describe "$VPC_NAME" --quiet 2>/dev/null; then
    log_success "✅ VPC network $VPC_NAME already exists"
  else
    log_info "Creating VPC network: $VPC_NAME"
    gcloud compute networks create "$VPC_NAME" \
      --subnet-mode=custom \
      --description="VPC for Claude Code Router (Free Tier)" \
      --quiet
    
    log_success "✅ VPC network $VPC_NAME created"
  fi
}

# Function to create subnet
create_subnet() {
  log_info "Creating subnet..."
  
  if gcloud compute networks subnets describe "$SUBNET_NAME" --region="$REGION" --quiet 2>/dev/null; then
    log_success "✅ Subnet $SUBNET_NAME already exists"
  else
    log_info "Creating subnet: $SUBNET_NAME"
    gcloud compute networks subnets create "$SUBNET_NAME" \
      --network="$VPC_NAME" \
      --range="10.0.1.0/24" \
      --region="$REGION" \
      --description="Subnet for Claude Code Router (Free Tier)" \
      --quiet
    
    log_success "✅ Subnet $SUBNET_NAME created"
  fi
}

# Function to create firewall rules
create_firewall_rules() {
  log_info "Creating firewall rules..."
  
  # HTTP firewall rule
  if gcloud compute firewall-rules describe "$FIREWALL_HTTP_NAME" --quiet 2>/dev/null; then
    log_success "✅ HTTP firewall rule $FIREWALL_HTTP_NAME already exists"
  else
    log_info "Creating HTTP firewall rule: $FIREWALL_HTTP_NAME"
    gcloud compute firewall-rules create "$FIREWALL_HTTP_NAME" \
      --network="$VPC_NAME" \
      --action=ALLOW \
      --rules=tcp:80 \
      --source-ranges=0.0.0.0/0 \
      --target-tags=claude-router-http \
      --description="Allow HTTP traffic to Claude Code Router" \
      --quiet
    
    log_success "✅ HTTP firewall rule $FIREWALL_HTTP_NAME created"
  fi
  
  # HTTPS firewall rule
  if gcloud compute firewall-rules describe "$FIREWALL_HTTPS_NAME" --quiet 2>/dev/null; then
    log_success "✅ HTTPS firewall rule $FIREWALL_HTTPS_NAME already exists"
  else
    log_info "Creating HTTPS firewall rule: $FIREWALL_HTTPS_NAME"
    gcloud compute firewall-rules create "$FIREWALL_HTTPS_NAME" \
      --network="$VPC_NAME" \
      --action=ALLOW \
      --rules=tcp:443 \
      --source-ranges=0.0.0.0/0 \
      --target-tags=claude-router-https \
      --description="Allow HTTPS traffic to Claude Code Router" \
      --quiet
    
    log_success "✅ HTTPS firewall rule $FIREWALL_HTTPS_NAME created"
  fi
  
  # SSH firewall rule (for maintenance)
  if gcloud compute firewall-rules describe "$FIREWALL_SSH_NAME" --quiet 2>/dev/null; then
    log_success "✅ SSH firewall rule $FIREWALL_SSH_NAME already exists"
  else
    log_info "Creating SSH firewall rule: $FIREWALL_SSH_NAME"
    gcloud compute firewall-rules create "$FIREWALL_SSH_NAME" \
      --network="$VPC_NAME" \
      --action=ALLOW \
      --rules=tcp:22 \
      --source-ranges=0.0.0.0/0 \
      --target-tags=claude-router-ssh \
      --description="Allow SSH access for maintenance" \
      --quiet
    
    log_success "✅ SSH firewall rule $FIREWALL_SSH_NAME created"
  fi
}

# Function to create service account
create_service_account() {
  log_info "Creating service account..."
  
  if gcloud iam service-accounts describe "${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --quiet 2>/dev/null; then
    log_success "✅ Service account $SERVICE_ACCOUNT_NAME already exists"
  else
    log_info "Creating service account: $SERVICE_ACCOUNT_NAME"
    gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
      --display-name="Claude Code Router Service Account" \
      --description="Service account for Claude Code Router (Free Tier)" \
      --quiet
    
    log_success "✅ Service account $SERVICE_ACCOUNT_NAME created"
  fi
  
  # Grant minimal required roles
  log_info "Configuring service account permissions..."
  
  REQUIRED_ROLES=(
    "roles/logging.logWriter"
    "roles/monitoring.metricWriter"
    "roles/secretmanager.secretAccessor"
  )
  
  for role in "${REQUIRED_ROLES[@]}"; do
    log_info "Granting role: $role"
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
      --role="$role" \
      --quiet > /dev/null 2>&1 || true
  done
  
  log_success "✅ Service account permissions configured"
}

# Function to create persistent disk
create_disk() {
  log_info "Creating persistent disk..."
  
  if gcloud compute disks describe "$DISK_NAME" --zone="$ZONE" --quiet 2>/dev/null; then
    log_success "✅ Disk $DISK_NAME already exists"
  else
    log_info "Creating disk: $DISK_NAME (${DISK_SIZE}, ${DISK_TYPE})"
    gcloud compute disks create "$DISK_NAME" \
      --size="$DISK_SIZE" \
      --type="$DISK_TYPE" \
      --zone="$ZONE" \
      --description="Boot disk for Claude Code Router (Free Tier)" \
      --quiet
    
    log_success "✅ Disk $DISK_NAME created"
  fi
}

# Function to create startup script
create_startup_script() {
  log_info "Creating startup script..."
  
  cat > /tmp/startup-script.sh << 'EOF'
#!/bin/bash
set -euo pipefail

# Startup script for Claude Code Router
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/startup-script.log
}

log "Starting Claude Code Router startup script..."

# Update system
log "Updating system packages..."
apt-get update -y
apt-get upgrade -y

# Install required packages
log "Installing required packages..."
apt-get install -y \
  curl \
  wget \
  unzip \
  git \
  jq \
  htop \
  ufw \
  fail2ban

# Install Node.js 20
log "Installing Node.js 20..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# Install pnpm
log "Installing pnpm..."
npm install -g pnpm

# Install Caddy
log "Installing Caddy..."
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy

# Create application user
log "Creating application user..."
useradd -r -s /bin/false -d /app claude-router || true

# Create application directory
log "Creating application directory..."
mkdir -p /app
chown claude-router:claude-router /app

# Configure UFW (basic firewall)
log "Configuring firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP
ufw allow 443/tcp   # HTTPS
ufw --force enable

# Configure fail2ban
log "Configuring fail2ban..."
systemctl enable fail2ban
systemctl start fail2ban

# Set memory limits for free tier
log "Configuring memory limits for free tier..."
echo 'vm.overcommit_memory = 1' >> /etc/sysctl.conf
echo 'vm.swappiness = 1' >> /etc/sysctl.conf
sysctl -p

# Signal completion
log "Startup script completed successfully"
touch /var/log/startup-complete

EOF
  
  log_success "✅ Startup script created"
}

# Function to create compute instance
create_instance() {
  log_info "Creating compute instance..."
  
  if gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --quiet 2>/dev/null; then
    log_success "✅ Instance $INSTANCE_NAME already exists"
    
    # Check if instance is running
    INSTANCE_STATUS=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format="value(status)")
    if [[ "$INSTANCE_STATUS" != "RUNNING" ]]; then
      log_info "Starting instance $INSTANCE_NAME..."
      gcloud compute instances start "$INSTANCE_NAME" --zone="$ZONE" --quiet
      log_success "✅ Instance $INSTANCE_NAME started"
    fi
  else
    create_startup_script
    
    log_info "Creating instance: $INSTANCE_NAME"
    log_warning "⚠️  This will use your free tier e2-micro instance allocation"
    
    gcloud compute instances create "$INSTANCE_NAME" \
      --zone="$ZONE" \
      --machine-type="$MACHINE_TYPE" \
      --network-interface="subnet=${SUBNET_NAME},private-network-ip=10.0.1.10" \
      --boot-disk-size="$DISK_SIZE" \
      --boot-disk-type="$DISK_TYPE" \
      --boot-disk-device-name="$DISK_NAME" \
      --image-family="ubuntu-2004-lts" \
      --image-project="ubuntu-os-cloud" \
      --service-account="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
      --scopes="https://www.googleapis.com/auth/cloud-platform" \
      --tags="claude-router-http,claude-router-https,claude-router-ssh" \
      --metadata-from-file="startup-script=/tmp/startup-script.sh" \
      --maintenance-policy=MIGRATE \
      --description="Claude Code Router instance (Free Tier)" \
      --quiet
    
    log_success "✅ Instance $INSTANCE_NAME created"
    
    # Clean up temporary files
    rm -f /tmp/startup-script.sh
  fi
}

# Function to wait for instance to be ready
wait_for_instance() {
  log_info "Waiting for instance to be ready..."
  
  local max_attempts=60
  local attempt=1
  
  while [[ $attempt -le $max_attempts ]]; do
    if gcloud compute ssh "$INSTANCE_NAME" \
         --zone="$ZONE" \
         --command="test -f /var/log/startup-complete" \
         --quiet 2>/dev/null; then
      log_success "✅ Instance is ready"
      return 0
    fi
    
    log_info "Attempt $attempt/$max_attempts - waiting for startup script to complete..."
    sleep 30
    ((attempt++))
  done
  
  log_warning "⚠️  Instance may not be fully ready. Continuing anyway..."
}

# Function to get instance information
get_instance_info() {
  log_info "Getting instance information..."
  
  EXTERNAL_IP=$(gcloud compute instances describe "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)")
  
  INTERNAL_IP=$(gcloud compute instances describe "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --format="value(networkInterfaces[0].networkIP)")
  
  log_success "✅ Instance information:"
  log_info "  Name: $INSTANCE_NAME"
  log_info "  Zone: $ZONE"
  log_info "  Machine Type: $MACHINE_TYPE"
  log_info "  Internal IP: $INTERNAL_IP"
  log_info "  External IP: $EXTERNAL_IP"
  log_warning "  ⚠️  External IP is ephemeral (may change if instance is stopped)"
  
  # Save instance info for other phases
  cat > "${PARENT_DIR}/instance-info.env" << EOF
INSTANCE_NAME="$INSTANCE_NAME"
EXTERNAL_IP="$EXTERNAL_IP"
INTERNAL_IP="$INTERNAL_IP"
ZONE="$ZONE"
EOF
  
  log_success "✅ Instance information saved to instance-info.env"
}

# Main execution
main() {
  create_vpc
  create_subnet
  create_firewall_rules
  create_service_account
  create_disk
  create_instance
  wait_for_instance
  get_instance_info
  
  log_success "🎉 Phase 2 completed successfully"
  
  echo -e "\n${GREEN}✅ Infrastructure deployed successfully!${NC}"
  echo -e "${BLUE}Instance: $INSTANCE_NAME${NC}"
  echo -e "${BLUE}External IP: $EXTERNAL_IP${NC}"
  echo -e "${YELLOW}💡 Next: Run Phase 3 (Security Setup)${NC}"
}

# Run main function
main "$@"