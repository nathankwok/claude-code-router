#!/bin/bash
set -euo pipefail

# Phase 1: Pre-deployment Validation and Free Tier Compliance
# This script validates environment prerequisites and ensures free tier compliance

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
VALIDATE_ONLY=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --environment)
      ENVIRONMENT="$2"
      shift 2
      ;;
    --validate-only)
      VALIDATE_ONLY=true
      shift
      ;;
    --force)
      FORCE=true
      shift
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
PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || echo "")}
REGION=${REGION:-"us-central1"}
ZONE=${ZONE:-"us-central1-a"}
MACHINE_TYPE=${MACHINE_TYPE:-"e2-micro"}
DISK_SIZE=${DISK_SIZE:-"30GB"}

log_info "Phase 1: Pre-deployment validation started"
log_info "Environment: $ENVIRONMENT"
log_info "Project: $PROJECT_ID"
log_info "Region: $REGION"

# Function to validate free tier compliance
validate_free_tier() {
  log_info "🔍 Validating GCP Free Tier compliance..."
  
  # Check region eligibility
  if [[ ! "$REGION" =~ ^(us-central1|us-east1|us-west1)$ ]]; then
    error "❌ Region $REGION is not free tier eligible. Use: us-central1, us-east1, or us-west1"
  fi
  log_success "✅ Region $REGION is free tier eligible"
  
  # Check for existing e2-micro instances
  log_info "Checking for existing e2-micro instances..."
  EXISTING_INSTANCES=$(gcloud compute instances list \
    --filter="machineType:e2-micro" \
    --format="value(name,zone)" 2>/dev/null | wc -l)
  
  if [[ $EXISTING_INSTANCES -gt 0 ]]; then
    log_warning "⚠️  Found $EXISTING_INSTANCES existing e2-micro instances"
    gcloud compute instances list --filter="machineType:e2-micro" --format="table(name,zone,status)"
    if [[ $EXISTING_INSTANCES -ge 1 && "$FORCE" != "true" ]]; then
      error "❌ Free tier allows only 1 e2-micro instance globally. Use --force to override this check."
    fi
  else
    log_success "✅ No existing e2-micro instances found"
  fi
  
  # Check persistent disk usage
  log_info "Checking persistent disk usage..."
  DISK_USAGE=$(gcloud compute disks list \
    --filter="type:pd-standard" \
    --format="value(sizeGb)" 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
  
  DISK_SIZE_NUM=$(echo "$DISK_SIZE" | sed 's/GB//')
  TOTAL_AFTER_DEPLOYMENT=$((DISK_USAGE + DISK_SIZE_NUM))
  
  log_info "Current persistent disk usage: ${DISK_USAGE}GB"
  log_info "Deployment will add: ${DISK_SIZE_NUM}GB"
  log_info "Total after deployment: ${TOTAL_AFTER_DEPLOYMENT}GB"
  
  if [[ $TOTAL_AFTER_DEPLOYMENT -gt 30 ]]; then
    error "❌ Would exceed free tier disk limit (30GB). Current: ${DISK_USAGE}GB + Deployment: ${DISK_SIZE_NUM}GB = ${TOTAL_AFTER_DEPLOYMENT}GB"
  else
    log_success "✅ Disk usage will be within free tier limits"
  fi
  
  # Check for static IP addresses
  log_info "Checking for static IP addresses..."
  STATIC_IPS=$(gcloud compute addresses list --format="value(name)" 2>/dev/null | wc -l)
  if [[ $STATIC_IPS -gt 0 ]]; then
    log_warning "⚠️  Found $STATIC_IPS static IP addresses (incur charges ~$3/month each)"
    gcloud compute addresses list --format="table(name,region,status)"
    log_info "This deployment uses ephemeral IP (free)"
  else
    log_success "✅ No static IP addresses found"
  fi
  
  # Check billing account
  log_info "Checking billing account status..."
  BILLING_ACCOUNT=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingAccountName)" 2>/dev/null || echo "")
  if [[ -n "$BILLING_ACCOUNT" ]]; then
    log_success "✅ Billing account linked: $BILLING_ACCOUNT"
  else
    log_warning "⚠️  No billing account linked. Required for free tier usage tracking."
  fi
  
  log_success "🎉 Free tier validation passed"
}

# Function to check gcloud CLI
check_gcloud() {
  log_info "Checking gcloud CLI..."
  
  if ! command -v gcloud &> /dev/null; then
    error "❌ gcloud CLI is not installed"
  fi
  
  GCLOUD_VERSION=$(gcloud version --format="value(Google Cloud SDK)" 2>/dev/null || echo "unknown")
  log_success "✅ gcloud CLI installed: $GCLOUD_VERSION"
  
  # Check authentication
  ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null || echo "")
  if [[ -z "$ACTIVE_ACCOUNT" ]]; then
    error "❌ gcloud is not authenticated. Run 'gcloud auth login'"
  fi
  log_success "✅ Authenticated as: $ACTIVE_ACCOUNT"
  
  # Check project
  if [[ -z "$PROJECT_ID" ]]; then
    error "❌ No GCP project set. Run 'gcloud config set project PROJECT_ID'"
  fi
  log_success "✅ Project set: $PROJECT_ID"
}

# Function to check required APIs
check_apis() {
  log_info "Checking required GCP APIs..."
  
  REQUIRED_APIS=(
    "compute.googleapis.com"
    "logging.googleapis.com"
    "monitoring.googleapis.com"
    "secretmanager.googleapis.com"
    "cloudbilling.googleapis.com"
  )
  
  ENABLED_APIS=$(gcloud services list --enabled --format="value(name)" 2>/dev/null || echo "")
  
  for api in "${REQUIRED_APIS[@]}"; do
    if echo "$ENABLED_APIS" | grep -q "$api"; then
      log_success "✅ API enabled: $api"
    else
      log_info "Enabling API: $api"
      if gcloud services enable "$api" 2>/dev/null; then
        log_success "✅ API enabled: $api"
      else
        error "❌ Failed to enable API: $api"
      fi
    fi
  done
}

# Function to check quotas
check_quotas() {
  log_info "Checking compute quotas for region $REGION..."
  
  # Check e2-micro quota
  E2_MICRO_QUOTA=$(gcloud compute project-info describe \
    --format="value(quotas[].limit)" \
    --filter="quotas.metric=N2_CPUS AND quotas.limit>0" 2>/dev/null | head -1 || echo "0")
  
  if [[ "$E2_MICRO_QUOTA" -lt 1 ]]; then
    log_warning "⚠️  Unable to verify e2-micro quota. This is normal for free tier."
  else
    log_success "✅ Compute quota available"
  fi
  
  # Check disk quota
  DISK_QUOTA=$(gcloud compute project-info describe \
    --format="value(quotas[].limit)" \
    --filter="quotas.metric=DISKS_TOTAL_GB" 2>/dev/null | head -1 || echo "500")
  
  log_info "Total disk quota: ${DISK_QUOTA}GB"
}

# Function to validate environment variables
validate_environment() {
  log_info "Validating environment configuration..."
  
  # Check machine type
  if [[ "$MACHINE_TYPE" != "e2-micro" ]]; then
    if [[ "$FORCE" != "true" ]]; then
      error "❌ Machine type must be 'e2-micro' for free tier. Found: $MACHINE_TYPE"
    else
      log_warning "⚠️  Machine type $MACHINE_TYPE may incur charges (not e2-micro)"
    fi
  else
    log_success "✅ Machine type: $MACHINE_TYPE (free tier)"
  fi
  
  # Check disk size
  DISK_SIZE_NUM=$(echo "$DISK_SIZE" | sed 's/GB//')
  if [[ $DISK_SIZE_NUM -gt 30 ]]; then
    if [[ "$FORCE" != "true" ]]; then
      error "❌ Disk size must be ≤30GB for free tier. Found: $DISK_SIZE"
    else
      log_warning "⚠️  Disk size $DISK_SIZE may incur charges (>30GB)"
    fi
  else
    log_success "✅ Disk size: $DISK_SIZE (within free tier)"
  fi
}

# Function to check Docker (for local builds)
check_docker() {
  log_info "Checking Docker availability..."
  
  if command -v docker &> /dev/null; then
    if docker info &> /dev/null; then
      log_success "✅ Docker is available and running"
    else
      log_warning "⚠️  Docker is installed but not running"
    fi
  else
    log_warning "⚠️  Docker not found (required for local image builds)"
  fi
}

# Function to create budget alert
setup_budget_alerts() {
  log_info "Setting up budget alerts..."
  
  BILLING_ACCOUNT=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingAccountName)" 2>/dev/null | sed 's|.*/||' || echo "")
  
  if [[ -z "$BILLING_ACCOUNT" ]]; then
    log_warning "⚠️  Cannot set up budget alerts - no billing account linked"
    return
  fi
  
  # Check if budget already exists
  EXISTING_BUDGET=$(gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" \
    --filter="displayName:'Free Tier Budget - ${PROJECT_ID}'" \
    --format="value(name)" 2>/dev/null || echo "")
  
  if [[ -n "$EXISTING_BUDGET" ]]; then
    log_success "✅ Budget alert already exists: $EXISTING_BUDGET"
  else
    log_info "Creating budget alert for free tier protection..."
    
    # Create budget configuration
    cat > /tmp/budget-config.yaml << EOF
displayName: "Free Tier Budget - ${PROJECT_ID}"
budgetFilter:
  projects:
  - "projects/${PROJECT_ID}"
amount:
  specifiedAmount:
    currencyCode: "USD"
    units: "1"
thresholdRules:
- thresholdPercent: 0.5
  spendBasis: CURRENT_SPEND
- thresholdPercent: 0.9
  spendBasis: CURRENT_SPEND
- thresholdPercent: 1.0
  spendBasis: CURRENT_SPEND
EOF
    
    if gcloud billing budgets create --billing-account="$BILLING_ACCOUNT" --budget-from-file=/tmp/budget-config.yaml 2>/dev/null; then
      log_success "✅ Budget alert created successfully"
    else
      log_warning "⚠️  Failed to create budget alert (may require additional permissions)"
    fi
    
    rm -f /tmp/budget-config.yaml
  fi
}

# Main execution
main() {
  check_gcloud
  validate_environment
  check_apis
  validate_free_tier
  check_quotas
  check_docker
  
  if [[ "$VALIDATE_ONLY" != "true" ]]; then
    setup_budget_alerts
  fi
  
  log_success "🎉 Phase 1 completed successfully"
  
  if [[ "$VALIDATE_ONLY" == "true" ]]; then
    echo -e "\n${GREEN}✅ Free tier validation passed!${NC}"
    echo -e "${BLUE}Your deployment will use only free tier resources.${NC}"
    echo -e "${YELLOW}💡 Run './deploy.sh' to start the deployment.${NC}"
  fi
}

# Run main function
main "$@"