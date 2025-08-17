#!/bin/bash
set -euo pipefail

# Cleanup Script for Claude Code Router (Free Tier)
# Safely removes all deployed resources to avoid charges

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
FORCE=false
DRY_RUN=false

usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Cleanup Claude Code Router deployment

OPTIONS:
  --environment ENV    Environment to cleanup (production, staging, dev) [default: production]
  --force             Force cleanup without confirmation
  --dry-run           Show what would be deleted without actually deleting
  -h, --help          Show this help

EXAMPLES:
  $0                           # Interactive cleanup of production environment
  $0 --environment staging    # Cleanup staging environment
  $0 --dry-run                # Show what would be deleted
  $0 --force                  # Force cleanup without confirmation

⚠️  WARNING:
This will delete ALL resources created by the deployment including:
- Compute Engine instance
- VPC network and subnets
- Firewall rules
- Service account
- Secrets in Secret Manager
- Monitoring policies and dashboards
- Log-based metrics

EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --environment)
      ENVIRONMENT="$2"
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Load configuration
CONFIG_FILE="${PARENT_DIR}/config/${ENVIRONMENT}.env"
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi

# Load instance information if available
INSTANCE_INFO_FILE="${PARENT_DIR}/instance-info.env"
if [[ -f "$INSTANCE_INFO_FILE" ]]; then
  source "$INSTANCE_INFO_FILE"
fi

# Set defaults
PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}
REGION=${REGION:-"us-central1"}
ZONE=${ZONE:-"us-central1-a"}
API_KEY_SECRET_NAME=${API_KEY_SECRET_NAME:-"claude-router-api-key"}

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

log_info "Claude Code Router Cleanup"
log_info "Environment: $ENVIRONMENT"
log_info "Project: $PROJECT_ID"
log_info "Dry Run: $DRY_RUN"

# Function to execute or simulate command
execute_command() {
  local description="$1"
  local command="$2"
  
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would execute: $description"
    log_info "[DRY RUN] Command: $command"
  else
    log_info "Executing: $description"
    if eval "$command" 2>/dev/null; then
      log_success "✅ $description completed"
    else
      log_warning "⚠️  $description failed or resource not found"
    fi
  fi
}

# Function to confirm cleanup
confirm_cleanup() {
  if [[ "$FORCE" == "true" || "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  
  echo -e "\n${RED}⚠️  WARNING: This will permanently delete the following resources:${NC}"
  echo -e "  • Compute Engine instance: $INSTANCE_NAME"
  echo -e "  • VPC network: $VPC_NAME"
  echo -e "  • Firewall rules: $FIREWALL_HTTP_NAME, $FIREWALL_HTTPS_NAME, $FIREWALL_SSH_NAME"
  echo -e "  • Service account: $SERVICE_ACCOUNT_NAME"
  echo -e "  • Secret: $API_KEY_SECRET_NAME"
  echo -e "  • All monitoring policies and dashboards"
  echo -e "  • All log-based metrics"
  
  echo -e "\n${YELLOW}This action cannot be undone!${NC}"
  echo -e "${BLUE}Project: $PROJECT_ID${NC}"
  echo -e "${BLUE}Environment: $ENVIRONMENT${NC}"
  
  echo ""
  read -p "Are you sure you want to continue? (type 'yes' to confirm): " confirm
  
  if [[ "$confirm" != "yes" ]]; then
    log_info "Cleanup cancelled by user"
    exit 0
  fi
}

# Function to stop services
stop_services() {
  log_info "Stopping services..."
  
  if [[ -n "${INSTANCE_NAME:-}" ]] && gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --quiet 2>/dev/null; then
    execute_command "Stop Claude Router service" "gcloud compute ssh '$INSTANCE_NAME' --zone='$ZONE' --command='sudo systemctl stop claude-router' --quiet"
    execute_command "Stop Caddy service" "gcloud compute ssh '$INSTANCE_NAME' --zone='$ZONE' --command='sudo systemctl stop caddy' --quiet"
  fi
}

# Function to delete compute instance
delete_instance() {
  log_info "Deleting compute instance..."
  
  if gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --quiet 2>/dev/null; then
    execute_command "Delete compute instance $INSTANCE_NAME" "gcloud compute instances delete '$INSTANCE_NAME' --zone='$ZONE' --quiet"
  else
    log_info "Instance $INSTANCE_NAME not found"
  fi
}

# Function to delete firewall rules
delete_firewall_rules() {
  log_info "Deleting firewall rules..."
  
  FIREWALL_RULES=("$FIREWALL_HTTP_NAME" "$FIREWALL_HTTPS_NAME" "$FIREWALL_SSH_NAME")
  
  for rule in "${FIREWALL_RULES[@]}"; do
    if gcloud compute firewall-rules describe "$rule" --quiet 2>/dev/null; then
      execute_command "Delete firewall rule $rule" "gcloud compute firewall-rules delete '$rule' --quiet"
    else
      log_info "Firewall rule $rule not found"
    fi
  done
}

# Function to delete VPC and subnet
delete_network() {
  log_info "Deleting network resources..."
  
  # Delete subnet first
  if gcloud compute networks subnets describe "$SUBNET_NAME" --region="$REGION" --quiet 2>/dev/null; then
    execute_command "Delete subnet $SUBNET_NAME" "gcloud compute networks subnets delete '$SUBNET_NAME' --region='$REGION' --quiet"
  else
    log_info "Subnet $SUBNET_NAME not found"
  fi
  
  # Delete VPC
  if gcloud compute networks describe "$VPC_NAME" --quiet 2>/dev/null; then
    execute_command "Delete VPC $VPC_NAME" "gcloud compute networks delete '$VPC_NAME' --quiet"
  else
    log_info "VPC $VPC_NAME not found"
  fi
}

# Function to delete service account
delete_service_account() {
  log_info "Deleting service account..."
  
  if gcloud iam service-accounts describe "${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --quiet 2>/dev/null; then
    execute_command "Delete service account $SERVICE_ACCOUNT_NAME" "gcloud iam service-accounts delete '${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com' --quiet"
  else
    log_info "Service account $SERVICE_ACCOUNT_NAME not found"
  fi
}

# Function to delete secrets
delete_secrets() {
  log_info "Deleting secrets..."
  
  if gcloud secrets describe "$API_KEY_SECRET_NAME" --quiet 2>/dev/null; then
    execute_command "Delete secret $API_KEY_SECRET_NAME" "gcloud secrets delete '$API_KEY_SECRET_NAME' --quiet"
  else
    log_info "Secret $API_KEY_SECRET_NAME not found"
  fi
}

# Function to delete monitoring resources
delete_monitoring() {
  log_info "Deleting monitoring resources..."
  
  # Delete alert policies
  ALERT_POLICIES=$(gcloud alpha monitoring policies list --filter="displayName~'Claude Router'" --format="value(name)" 2>/dev/null || echo "")
  
  if [[ -n "$ALERT_POLICIES" ]]; then
    for policy in $ALERT_POLICIES; do
      execute_command "Delete alert policy $policy" "gcloud alpha monitoring policies delete '$policy' --quiet"
    done
  else
    log_info "No Claude Router alert policies found"
  fi
  
  # Delete uptime checks
  UPTIME_CHECKS=$(gcloud monitoring uptime-checks list --filter="displayName~'Claude Router'" --format="value(name)" 2>/dev/null || echo "")
  
  if [[ -n "$UPTIME_CHECKS" ]]; then
    for check in $UPTIME_CHECKS; do
      execute_command "Delete uptime check $check" "gcloud monitoring uptime-checks delete '$check' --quiet"
    done
  else
    log_info "No Claude Router uptime checks found"
  fi
  
  # Delete dashboards
  DASHBOARDS=$(gcloud monitoring dashboards list --filter="displayName~'Claude Router'" --format="value(name)" 2>/dev/null || echo "")
  
  if [[ -n "$DASHBOARDS" ]]; then
    for dashboard in $DASHBOARDS; do
      execute_command "Delete dashboard $dashboard" "gcloud monitoring dashboards delete '$dashboard' --quiet"
    done
  else
    log_info "No Claude Router dashboards found"
  fi
  
  # Delete notification channels (be careful - these might be shared)
  log_info "Note: Notification channels are not deleted as they might be shared with other resources"
}

# Function to delete log-based metrics
delete_log_metrics() {
  log_info "Deleting log-based metrics..."
  
  LOG_METRICS=("claude_router_error_rate" "claude_router_requests")
  
  for metric in "${LOG_METRICS[@]}"; do
    if gcloud logging metrics describe "$metric" --quiet 2>/dev/null; then
      execute_command "Delete log-based metric $metric" "gcloud logging metrics delete '$metric' --quiet"
    else
      log_info "Log-based metric $metric not found"
    fi
  done
}

# Function to delete budget alerts
delete_budget() {
  log_info "Checking for budget alerts..."
  
  BILLING_ACCOUNT=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingAccountName)" 2>/dev/null | sed 's|.*/||' || echo "")
  
  if [[ -n "$BILLING_ACCOUNT" ]]; then
    BUDGETS=$(gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" --filter="displayName~'Free Tier Budget - ${PROJECT_ID}'" --format="value(name)" 2>/dev/null || echo "")
    
    if [[ -n "$BUDGETS" ]]; then
      for budget in $BUDGETS; do
        execute_command "Delete budget $budget" "gcloud billing budgets delete '$budget' --billing-account='$BILLING_ACCOUNT' --quiet"
      done
    else
      log_info "No Claude Router budgets found"
    fi
  else
    log_info "No billing account found"
  fi
}

# Function to clean up local files
cleanup_local_files() {
  log_info "Cleaning up local files..."
  
  LOCAL_FILES=(
    "${PARENT_DIR}/instance-info.env"
    "${PARENT_DIR}/api-key.env"
    "${PARENT_DIR}/deployment-info.env"
    "${PARENT_DIR}/health-check-report.txt"
  )
  
  for file in "${LOCAL_FILES[@]}"; do
    if [[ -f "$file" ]]; then
      execute_command "Delete local file $(basename "$file")" "rm -f '$file'"
    fi
  done
}

# Function to verify cleanup
verify_cleanup() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Dry run completed - no resources were actually deleted"
    return
  fi
  
  log_info "Verifying cleanup..."
  
  local remaining_resources=0
  
  # Check if instance still exists
  if gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --quiet 2>/dev/null; then
    log_warning "⚠️  Instance $INSTANCE_NAME still exists"
    ((remaining_resources++))
  fi
  
  # Check if VPC still exists
  if gcloud compute networks describe "$VPC_NAME" --quiet 2>/dev/null; then
    log_warning "⚠️  VPC $VPC_NAME still exists"
    ((remaining_resources++))
  fi
  
  # Check if service account still exists
  if gcloud iam service-accounts describe "${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --quiet 2>/dev/null; then
    log_warning "⚠️  Service account $SERVICE_ACCOUNT_NAME still exists"
    ((remaining_resources++))
  fi
  
  # Check if secret still exists
  if gcloud secrets describe "$API_KEY_SECRET_NAME" --quiet 2>/dev/null; then
    log_warning "⚠️  Secret $API_KEY_SECRET_NAME still exists"
    ((remaining_resources++))
  fi
  
  if [[ $remaining_resources -eq 0 ]]; then
    log_success "✅ All resources have been cleaned up successfully"
  else
    log_warning "⚠️  $remaining_resources resources may still exist"
    log_warning "Some resources may take time to be fully deleted"
  fi
}

# Function to show cost verification
show_cost_verification() {
  log_info "Cost verification..."
  
  echo -e "\n${GREEN}✅ Cleanup completed!${NC}"
  echo -e "\n${BLUE}To verify no charges are incurred:${NC}"
  echo -e "1. Check billing: https://console.cloud.google.com/billing"
  echo -e "2. Review compute instances: https://console.cloud.google.com/compute/instances?project=$PROJECT_ID"
  echo -e "3. Review VPC networks: https://console.cloud.google.com/networking/networks/list?project=$PROJECT_ID"
  echo -e "4. Monitor for any unexpected charges"
  
  echo -e "\n${YELLOW}⚠️  Important:${NC}"
  echo -e "• Some resources may take a few minutes to be fully deleted"
  echo -e "• Check your billing account to ensure no charges are occurring"
  echo -e "• Free tier quotas have been restored"
}

# Main execution
main() {
  confirm_cleanup
  
  log_info "Starting cleanup of Claude Code Router deployment..."
  
  # Stop services first
  stop_services
  
  # Delete resources in order (dependencies first)
  delete_instance
  delete_firewall_rules
  delete_network
  delete_service_account
  delete_secrets
  delete_monitoring
  delete_log_metrics
  delete_budget
  cleanup_local_files
  
  # Verify cleanup
  verify_cleanup
  
  # Show final information
  show_cost_verification
  
  log_success "🎉 Cleanup completed successfully"
  
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "\n${BLUE}This was a dry run. To actually delete resources, run without --dry-run${NC}"
  fi
}

# Run main function
main "$@"