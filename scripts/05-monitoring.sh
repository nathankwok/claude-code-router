#!/bin/bash
set -euo pipefail

# Phase 5: Monitoring Setup (Free Tier)
# Sets up basic monitoring and logging within free tier constraints

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
NOTIFICATION_EMAIL=${NOTIFICATION_EMAIL:-""}

# Resource names
RESOURCE_PREFIX="${PROJECT_ID}-claude-router"

log_info "Phase 5: Monitoring setup started"
log_info "Environment: $ENVIRONMENT"
log_info "Instance: $INSTANCE_NAME"

# Function to configure Cloud Logging agent
setup_cloud_logging() {
  log_info "Setting up Cloud Logging..."
  
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    echo 'Configuring Cloud Logging agent...'
    
    # Install Google Cloud Logging agent
    curl -sSO https://dl.google.com/cloudagents/add-logging-agent-repo.sh
    sudo bash add-logging-agent-repo.sh --also-install
    
    # Configure logging for Claude Router application
    sudo tee /etc/google-fluentd/config.d/claude-router.conf > /dev/null << 'FLUENTD_EOF'
<source>
  @type tail
  path /var/log/syslog
  pos_file /var/lib/google-fluentd/pos/claude-router-syslog.log.pos
  read_from_head true
  tag claude-router.syslog
  format syslog
</source>

<source>
  @type tail
  path /var/log/caddy/access.log
  pos_file /var/lib/google-fluentd/pos/caddy-access.log.pos
  read_from_head true
  tag claude-router.caddy
  format json
</source>

<filter claude-router.**>
  @type record_transformer
  <record>
    hostname \"#{Socket.gethostname}\"
    environment \"$ENVIRONMENT\"
    service \"claude-router\"
  </record>
</filter>
FLUENTD_EOF
    
    # Restart logging agent
    sudo systemctl restart google-fluentd
    sudo systemctl enable google-fluentd
    
    echo 'Cloud Logging configured successfully'
  "
  
  log_success "✅ Cloud Logging configured"
}

# Function to install Cloud Monitoring agent
setup_cloud_monitoring() {
  log_info "Setting up Cloud Monitoring..."
  
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    echo 'Installing Cloud Monitoring agent...'
    
    # Install Google Cloud Monitoring agent
    curl -sSO https://dl.google.com/cloudagents/add-monitoring-agent-repo.sh
    sudo bash add-monitoring-agent-repo.sh --also-install
    
    # Configure monitoring agent
    sudo tee /etc/stackdriver/collectd.d/claude-router.conf > /dev/null << 'COLLECTD_EOF'
# Claude Router monitoring configuration

# Memory monitoring (important for free tier)
LoadPlugin memory
<Plugin memory>
  ValuesAbsolute true
  ValuesPercentage false
</Plugin>

# CPU monitoring
LoadPlugin cpu
<Plugin cpu>
  ReportByCpu true
  ReportByState true
  ValuesPercentage true
</Plugin>

# Network monitoring
LoadPlugin interface
<Plugin interface>
  Interface \"eth0\"
  IgnoreSelected false
</Plugin>

# Process monitoring for Claude Router
LoadPlugin processes
<Plugin processes>
  ProcessMatch \"claude-router\" \"node.*cli.js\"
  ProcessMatch \"caddy\" \"caddy\"
</Plugin>

# Custom metrics via StatsD
LoadPlugin statsd
<Plugin statsd>
  Host \"localhost\"
  Port \"8125\"
  DeleteCounters false
  DeleteTimers   false
  DeleteGauges   false
  DeleteSets     false
  TimerPercentile 90.0
</Plugin>
COLLECTD_EOF
    
    # Restart monitoring agent
    sudo systemctl restart stackdriver-agent
    sudo systemctl enable stackdriver-agent
    
    echo 'Cloud Monitoring agent configured successfully'
  "
  
  log_success "✅ Cloud Monitoring agent configured"
}

# Function to create basic uptime check
create_uptime_check() {
  log_info "Creating uptime check..."
  
  if [[ -z "${EXTERNAL_IP:-}" ]]; then
    log_warning "⚠️  No external IP found, skipping uptime check"
    return
  fi
  
  # Check if uptime check already exists
  EXISTING_CHECK=$(gcloud monitoring uptime-checks list \
    --filter="displayName:'Claude Router Uptime Check'" \
    --format="value(name)" 2>/dev/null | head -1 || echo "")
  
  if [[ -n "$EXISTING_CHECK" ]]; then
    log_success "✅ Uptime check already exists: $EXISTING_CHECK"
    return
  fi
  
  # Create uptime check configuration
  cat > /tmp/uptime-check.yaml << EOF
displayName: "Claude Router Uptime Check"
monitoredResource:
  type: "uptime_url"
  labels:
    host: "$EXTERNAL_IP"
httpCheck:
  path: "/health"
  port: 443
  useSsl: true
  validateSsl: false
period: "300s"
timeout: "10s"
selectedRegions:
  - "USA"
EOF
  
  # Create the uptime check
  if gcloud monitoring uptime-checks create --uptime-check-config-from-file=/tmp/uptime-check.yaml 2>/dev/null; then
    log_success "✅ Uptime check created"
  else
    log_warning "⚠️  Failed to create uptime check (may require additional permissions)"
  fi
  
  rm -f /tmp/uptime-check.yaml
}

# Function to create alerting policies
create_alert_policies() {
  log_info "Creating alert policies..."
  
  # Basic uptime alert policy
  cat > /tmp/uptime-alert.yaml << EOF
displayName: "Claude Router Instance Down"
conditions:
  - displayName: "Uptime check failure"
    conditionThreshold:
      filter: 'resource.type="uptime_url" AND metric.type="monitoring.googleapis.com/uptime_check/check_passed"'
      comparison: COMPARISON_EQUAL
      thresholdValue: 0
      duration: "300s"
      aggregations:
        - alignmentPeriod: "300s"
          perSeriesAligner: ALIGN_FRACTION_TRUE
          crossSeriesReducer: REDUCE_MEAN
          groupByFields:
            - "resource.label.host"
combiner: OR
enabled: true
EOF

  # Memory usage alert policy
  cat > /tmp/memory-alert.yaml << EOF
displayName: "Claude Router High Memory Usage"
conditions:
  - displayName: "Memory usage over 90%"
    conditionThreshold:
      filter: 'resource.type="gce_instance" AND metric.type="compute.googleapis.com/instance/memory/utilization" AND resource.label.instance_id="$INSTANCE_NAME"'
      comparison: COMPARISON_GREATER_THAN
      thresholdValue: 0.9
      duration: "900s"
      aggregations:
        - alignmentPeriod: "300s"
          perSeriesAligner: ALIGN_MEAN
combiner: OR
enabled: true
EOF

  # Create alert policies
  for policy_file in /tmp/uptime-alert.yaml /tmp/memory-alert.yaml; do
    policy_name=$(grep "displayName:" "$policy_file" | cut -d'"' -f2)
    
    # Check if policy already exists
    EXISTING_POLICY=$(gcloud alpha monitoring policies list \
      --filter="displayName:'$policy_name'" \
      --format="value(name)" 2>/dev/null | head -1 || echo "")
    
    if [[ -n "$EXISTING_POLICY" ]]; then
      log_success "✅ Alert policy already exists: $policy_name"
    else
      if gcloud alpha monitoring policies create --policy-from-file="$policy_file" 2>/dev/null; then
        log_success "✅ Alert policy created: $policy_name"
      else
        log_warning "⚠️  Failed to create alert policy: $policy_name"
      fi
    fi
  done
  
  # Clean up
  rm -f /tmp/uptime-alert.yaml /tmp/memory-alert.yaml
}

# Function to create notification channels
create_notification_channels() {
  log_info "Setting up notification channels..."
  
  if [[ -z "$NOTIFICATION_EMAIL" ]]; then
    log_warning "⚠️  No notification email configured, skipping email notifications"
    log_info "To set up email notifications, set NOTIFICATION_EMAIL in your config file"
    return
  fi
  
  # Check if notification channel already exists
  EXISTING_CHANNEL=$(gcloud alpha monitoring channels list \
    --filter="type=email AND labels.email_address='$NOTIFICATION_EMAIL'" \
    --format="value(name)" 2>/dev/null | head -1 || echo "")
  
  if [[ -n "$EXISTING_CHANNEL" ]]; then
    log_success "✅ Email notification channel already exists for $NOTIFICATION_EMAIL"
    return
  fi
  
  # Create notification channel
  cat > /tmp/notification-channel.yaml << EOF
type: "email"
displayName: "Claude Router Alerts"
labels:
  email_address: "$NOTIFICATION_EMAIL"
enabled: true
EOF
  
  if gcloud alpha monitoring channels create --channel-from-file=/tmp/notification-channel.yaml 2>/dev/null; then
    log_success "✅ Email notification channel created for $NOTIFICATION_EMAIL"
  else
    log_warning "⚠️  Failed to create notification channel"
  fi
  
  rm -f /tmp/notification-channel.yaml
}

# Function to setup log-based metrics
setup_log_metrics() {
  log_info "Setting up log-based metrics..."
  
  # Error rate metric
  cat > /tmp/error-metric.yaml << EOF
name: "claude_router_error_rate"
description: "Claude Router error rate from logs"
filter: 'resource.type="gce_instance" AND jsonPayload.service="claude-router" AND (jsonPayload.level="error" OR jsonPayload.level="ERROR")'
metricDescriptor:
  displayName: "Claude Router Error Rate"
  metricKind: COUNTER
  valueType: INT64
EOF

  # Request count metric
  cat > /tmp/request-metric.yaml << EOF
name: "claude_router_requests"
description: "Claude Router request count from logs"
filter: 'resource.type="gce_instance" AND jsonPayload.service="claude-router" AND jsonPayload.msg=~".*request.*"'
metricDescriptor:
  displayName: "Claude Router Request Count"
  metricKind: COUNTER
  valueType: INT64
EOF

  # Create metrics
  for metric_file in /tmp/error-metric.yaml /tmp/request-metric.yaml; do
    metric_name=$(grep "name:" "$metric_file" | cut -d'"' -f2)
    
    # Check if metric already exists
    if gcloud logging metrics describe "$metric_name" --quiet 2>/dev/null; then
      log_success "✅ Log-based metric already exists: $metric_name"
    else
      if gcloud logging metrics create "$metric_name" --config-from-file="$metric_file" 2>/dev/null; then
        log_success "✅ Log-based metric created: $metric_name"
      else
        log_warning "⚠️  Failed to create log-based metric: $metric_name"
      fi
    fi
  done
  
  # Clean up
  rm -f /tmp/error-metric.yaml /tmp/request-metric.yaml
}

# Function to configure log rotation
configure_log_rotation() {
  log_info "Configuring log rotation for free tier limits..."
  
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    echo 'Configuring log rotation...'
    
    # Configure logrotate for Caddy logs
    sudo tee /etc/logrotate.d/caddy > /dev/null << 'LOGROTATE_EOF'
/var/log/caddy/*.log {
    daily
    missingok
    rotate 7
    compress
    notifempty
    create 644 caddy caddy
    postrotate
        sudo systemctl reload caddy > /dev/null 2>&1 || true
    endscript
}
LOGROTATE_EOF
    
    # Configure logrotate for system logs (more aggressive for free tier)
    sudo tee /etc/logrotate.d/claude-router > /dev/null << 'LOGROTATE_EOF'
/var/log/syslog {
    daily
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        sudo systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}

/var/log/auth.log {
    daily
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        sudo systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}
LOGROTATE_EOF
    
    # Test logrotate configuration
    sudo logrotate -d /etc/logrotate.d/caddy
    sudo logrotate -d /etc/logrotate.d/claude-router
    
    echo 'Log rotation configured successfully'
  "
  
  log_success "✅ Log rotation configured"
}

# Function to create basic dashboard
create_dashboard() {
  log_info "Creating basic monitoring dashboard..."
  
  # Create dashboard configuration
  cat > /tmp/dashboard.json << EOF
{
  "displayName": "Claude Router Free Tier Dashboard",
  "mosaicLayout": {
    "tiles": [
      {
        "width": 6,
        "height": 4,
        "widget": {
          "title": "Instance CPU Usage",
          "xyChart": {
            "dataSets": [
              {
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "resource.type=\\\"gce_instance\\\" AND metric.type=\\\"compute.googleapis.com/instance/cpu/utilization\\\" AND resource.label.instance_id=\\\"$INSTANCE_NAME\\\"",
                    "aggregation": {
                      "alignmentPeriod": "60s",
                      "perSeriesAligner": "ALIGN_MEAN"
                    }
                  }
                },
                "plotType": "LINE"
              }
            ]
          }
        }
      },
      {
        "width": 6,
        "height": 4,
        "xPos": 6,
        "widget": {
          "title": "Instance Memory Usage",
          "xyChart": {
            "dataSets": [
              {
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "resource.type=\\\"gce_instance\\\" AND metric.type=\\\"compute.googleapis.com/instance/memory/utilization\\\" AND resource.label.instance_id=\\\"$INSTANCE_NAME\\\"",
                    "aggregation": {
                      "alignmentPeriod": "60s",
                      "perSeriesAligner": "ALIGN_MEAN"
                    }
                  }
                },
                "plotType": "LINE"
              }
            ]
          }
        }
      },
      {
        "width": 12,
        "height": 4,
        "yPos": 4,
        "widget": {
          "title": "Uptime Check Status",
          "xyChart": {
            "dataSets": [
              {
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "resource.type=\\\"uptime_url\\\" AND metric.type=\\\"monitoring.googleapis.com/uptime_check/check_passed\\\"",
                    "aggregation": {
                      "alignmentPeriod": "300s",
                      "perSeriesAligner": "ALIGN_FRACTION_TRUE"
                    }
                  }
                },
                "plotType": "STACKED_BAR"
              }
            ]
          }
        }
      }
    ]
  }
}
EOF

  # Check if dashboard already exists
  EXISTING_DASHBOARD=$(gcloud monitoring dashboards list \
    --filter="displayName:'Claude Router Free Tier Dashboard'" \
    --format="value(name)" 2>/dev/null | head -1 || echo "")
  
  if [[ -n "$EXISTING_DASHBOARD" ]]; then
    log_success "✅ Dashboard already exists: Claude Router Free Tier Dashboard"
  else
    if gcloud monitoring dashboards create --config-from-file=/tmp/dashboard.json 2>/dev/null; then
      log_success "✅ Dashboard created: Claude Router Free Tier Dashboard"
    else
      log_warning "⚠️  Failed to create dashboard"
    fi
  fi
  
  rm -f /tmp/dashboard.json
}

# Function to verify monitoring setup
verify_monitoring() {
  log_info "Verifying monitoring setup..."
  
  # Check if agents are running
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    echo 'Checking monitoring agents...'
    
    # Check Google Cloud Logging agent
    if systemctl is-active --quiet google-fluentd; then
        echo '✅ Google Cloud Logging agent is running'
    else
        echo '❌ Google Cloud Logging agent is not running'
        exit 1
    fi
    
    # Check Google Cloud Monitoring agent
    if systemctl is-active --quiet stackdriver-agent; then
        echo '✅ Google Cloud Monitoring agent is running'
    else
        echo '❌ Google Cloud Monitoring agent is not running'
        exit 1
    fi
    
    echo 'All monitoring agents are running successfully'
  "
  
  log_success "✅ Monitoring agents verified"
  
  # Test that we can query some basic metrics
  log_info "Testing metric queries..."
  
  # Query instance metrics
  METRICS_FOUND=$(gcloud monitoring metrics list \
    --filter="metric.type:compute.googleapis.com/instance/cpu/utilization" \
    --format="value(name)" | wc -l)
  
  if [[ $METRICS_FOUND -gt 0 ]]; then
    log_success "✅ Compute metrics are available"
  else
    log_warning "⚠️  Compute metrics not yet available (may take a few minutes)"
  fi
}

# Main execution
main() {
  setup_cloud_logging
  setup_cloud_monitoring
  configure_log_rotation
  create_uptime_check
  setup_log_metrics
  create_notification_channels
  create_alert_policies
  create_dashboard
  verify_monitoring
  
  log_success "🎉 Phase 5 completed successfully"
  
  echo -e "\n${GREEN}✅ Monitoring setup completed!${NC}"
  echo -e "${BLUE}Configured components:${NC}"
  echo -e "  • Cloud Logging agent"
  echo -e "  • Cloud Monitoring agent" 
  echo -e "  • Uptime checks"
  echo -e "  • Alert policies"
  echo -e "  • Log rotation (free tier optimized)"
  echo -e "  • Basic dashboard"
  
  if [[ -n "$NOTIFICATION_EMAIL" ]]; then
    echo -e "  • Email notifications: $NOTIFICATION_EMAIL"
  fi
  
  echo -e ""
  echo -e "${BLUE}Access monitoring:${NC}"
  echo -e "  • Console: https://console.cloud.google.com/monitoring"
  echo -e "  • Logs: https://console.cloud.google.com/logs"
  echo -e ""
  echo -e "${YELLOW}💡 Next: Run Phase 6 (Health Check)${NC}"
}

# Run main function
main "$@"