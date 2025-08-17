#!/bin/bash
set -euo pipefail

# Claude Code Router - GCP Free Tier Deployment Script
# This script orchestrates the deployment of Claude Code Router to GCP using only free tier resources

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/${ENVIRONMENT:-production}.env"
LOG_FILE="${SCRIPT_DIR}/logs/deployment-$(date +%Y%m%d_%H%M%S).log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Usage function
usage() {
  cat << EOF
Usage: $0 [OPTIONS] [PHASES...]

Deploy Claude Code Router to GCP Free Tier

OPTIONS:
  -e, --environment ENV    Environment (production, staging, dev) [default: production]
  -p, --phase PHASE        Run specific phase only (1-6)
  -c, --cleanup           Run cleanup/rollback
  -v, --verbose           Verbose output
  --validate-free-tier    Validate free tier compliance only
  -h, --help             Show this help

PHASES:
  1. predeploy     - Validate environment and prerequisites
  2. infrastructure - Create GCP resources (VPC, compute instance)
  3. security      - Security hardening and authentication
  4. application   - Build and deploy application
  5. monitoring    - Setup logging and monitoring
  6. healthcheck   - Validate deployment

EXAMPLES:
  $0                           # Deploy all phases (free tier)
  $0 --phase 1,2,3            # Deploy phases 1-3 only
  $0 --environment staging    # Deploy to staging environment
  $0 --cleanup                # Cleanup/rollback deployment
  $0 --validate-free-tier     # Validate free tier compliance

⚠️  FREE TIER NOTICE:
This deployment is designed to use ONLY GCP free tier resources.
- Single e2-micro instance (1 vCPU, 1GB RAM)
- 30GB standard persistent disk
- Ephemeral IP (no static IP charges)
- Basic monitoring within free quotas
- Budget alerts configured to prevent charges

EOF
}

# Logging functions
log() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_info() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}INFO${NC}: $*" | tee -a "$LOG_FILE"
}

log_success() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}SUCCESS${NC}: $*" | tee -a "$LOG_FILE"
}

log_warning() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}WARNING${NC}: $*" | tee -a "$LOG_FILE"
}

log_error() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}ERROR${NC}: $*" | tee -a "$LOG_FILE" >&2
}

error() {
  log_error "$*"
  echo -e "${RED}Deployment failed. Check logs at: $LOG_FILE${NC}" >&2
  exit 1
}

# Validate prerequisites
validate_prerequisites() {
  log_info "Validating prerequisites..."
  
  # Check if gcloud is installed
  if ! command -v gcloud &> /dev/null; then
    error "gcloud CLI is not installed. Please install it first."
  fi
  
  # Check if gcloud is authenticated
  if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
    error "gcloud is not authenticated. Run 'gcloud auth login' first."
  fi
  
  # Check if project is set
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
  if [[ -z "$PROJECT_ID" ]]; then
    error "No GCP project set. Run 'gcloud config set project PROJECT_ID' first."
  fi
  
  log_success "Prerequisites validated. Project: $PROJECT_ID"
}

# Parse command line arguments
PHASES=()
CLEANUP=false
VERBOSE=false
ENVIRONMENT="production"
VALIDATE_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -e|--environment)
      ENVIRONMENT="$2"
      shift 2
      ;;
    -p|--phase)
      IFS=',' read -ra PHASES <<< "$2"
      shift 2
      ;;
    -c|--cleanup)
      CLEANUP=true
      shift
      ;;
    -v|--verbose)
      VERBOSE=true
      set -x
      shift
      ;;
    --validate-free-tier)
      VALIDATE_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      ;;
  esac
done

# Create necessary directories
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "${SCRIPT_DIR}/config"
mkdir -p "${SCRIPT_DIR}/scripts"

# Validate prerequisites
validate_prerequisites

# Source configuration if it exists
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
  log_info "Loaded configuration from: $CONFIG_FILE"
else
  log_warning "Configuration file not found: $CONFIG_FILE"
  log_info "Using default values. You may want to create this file."
fi

# Set default values if not in config
PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}
REGION=${REGION:-"us-central1"}
ZONE=${ZONE:-"us-central1-a"}
MACHINE_TYPE=${MACHINE_TYPE:-"e2-micro"}
DISK_SIZE=${DISK_SIZE:-"30GB"}
DISK_TYPE=${DISK_TYPE:-"pd-standard"}
RESOURCE_PREFIX="${PROJECT_ID}-claude-router"

# Set default phases if none specified
if [[ ${#PHASES[@]} -eq 0 ]]; then
  PHASES=(1 2 3 4 5 6)
fi

log_info "Starting deployment to $ENVIRONMENT environment"
log_info "Project: $PROJECT_ID"
log_info "Region: $REGION"
log_info "Zone: $ZONE"
log_info "Phases to run: ${PHASES[*]}"

# Validate free tier compliance if requested
if [[ "$VALIDATE_ONLY" == "true" ]]; then
  log_info "Running free tier validation only..."
  "${SCRIPT_DIR}/scripts/01-predeploy.sh" --environment "$ENVIRONMENT" --validate-only
  exit 0
fi

# Run cleanup if requested
if [[ "$CLEANUP" == "true" ]]; then
  log_info "Running cleanup..."
  if [[ -f "${SCRIPT_DIR}/scripts/cleanup.sh" ]]; then
    "${SCRIPT_DIR}/scripts/cleanup.sh" --environment "$ENVIRONMENT"
  else
    log_warning "Cleanup script not found. Manual cleanup may be required."
  fi
  exit 0
fi

# Execute phases
for phase in "${PHASES[@]}"; do
  case $phase in
    1)
      log_info "Running Phase 1: Pre-deployment validation"
      "${SCRIPT_DIR}/scripts/01-predeploy.sh" --environment "$ENVIRONMENT"
      ;;
    2)
      log_info "Running Phase 2: Infrastructure deployment"
      "${SCRIPT_DIR}/scripts/02-infrastructure.sh" --environment "$ENVIRONMENT"
      ;;
    3)
      log_info "Running Phase 3: Security setup"
      "${SCRIPT_DIR}/scripts/03-security.sh" --environment "$ENVIRONMENT"
      ;;
    4)
      log_info "Running Phase 4: Application deployment"
      "${SCRIPT_DIR}/scripts/04-application.sh" --environment "$ENVIRONMENT"
      ;;
    5)
      log_info "Running Phase 5: Monitoring setup"
      "${SCRIPT_DIR}/scripts/05-monitoring.sh" --environment "$ENVIRONMENT"
      ;;
    6)
      log_info "Running Phase 6: Health checks"
      "${SCRIPT_DIR}/scripts/06-healthcheck.sh" --environment "$ENVIRONMENT"
      ;;
    *)
      error "Invalid phase: $phase"
      ;;
  esac
  
  if [[ $? -ne 0 ]]; then
    error "Phase $phase failed. Check logs at $LOG_FILE"
  fi
  
  log_success "Phase $phase completed successfully"
done

# Get ephemeral IP instead of static IP (free tier)
EXTERNAL_IP=$(gcloud compute instances describe "${RESOURCE_PREFIX}-vm" --zone="$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "")

log_success "Deployment completed successfully!"
if [[ -n "$EXTERNAL_IP" ]]; then
  log_info "Access your application at: https://${EXTERNAL_IP}"
  log_warning "⚠️  Note: This is an ephemeral IP. It may change if the instance is stopped/started."
else
  log_info "Application deployed. Use 'gcloud compute instances describe ${RESOURCE_PREFIX}-vm --zone=$ZONE' to get the IP address."
fi

log_info "Deployment logs saved to: $LOG_FILE"
echo -e "\n${GREEN}🎉 Claude Code Router successfully deployed to GCP Free Tier!${NC}"
echo -e "${YELLOW}💰 Remember: This deployment uses only free tier resources ($0/month)${NC}"
echo -e "${BLUE}📊 Monitor usage at: https://console.cloud.google.com/billing${NC}"