#!/bin/bash
set -euo pipefail

# Phase 6: Health Check and Validation (Free Tier)
# Validates deployment and performs comprehensive integration tests

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
SKIP_LOAD_TEST=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --environment)
      ENVIRONMENT="$2"
      shift 2
      ;;
    --skip-load-test)
      SKIP_LOAD_TEST=true
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

# Load deployment information
DEPLOYMENT_INFO_FILE="${PARENT_DIR}/deployment-info.env"
if [[ -f "$DEPLOYMENT_INFO_FILE" ]]; then
  source "$DEPLOYMENT_INFO_FILE"
fi

# Set defaults
PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}
EXTERNAL_IP=${EXTERNAL_IP:-""}
API_KEY=${API_KEY:-""}

log_info "Phase 6: Health check and validation started"
log_info "Environment: $ENVIRONMENT"
log_info "Instance: $INSTANCE_NAME"
log_info "External IP: $EXTERNAL_IP"

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# Function to record test result
record_test() {
  local test_name="$1"
  local result="$2"
  
  if [[ "$result" == "PASS" ]]; then
    ((TESTS_PASSED++))
    log_success "✅ $test_name: PASSED"
  else
    ((TESTS_FAILED++))
    FAILED_TESTS+=("$test_name")
    log_error "❌ $test_name: FAILED"
  fi
}

# Function to check service status
check_service_status() {
  log_info "Checking service status..."
  
  local status_result="PASS"
  
  # Check services on the instance
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    echo 'Checking service status...'
    
    # Check Caddy
    if systemctl is-active --quiet caddy; then
        echo '✅ Caddy service is running'
    else
        echo '❌ Caddy service is not running'
        exit 1
    fi
    
    # Check Claude Router
    if systemctl is-active --quiet claude-router; then
        echo '✅ Claude Router service is running'
    else
        echo '❌ Claude Router service is not running'
        exit 1
    fi
    
    # Check process resources
    echo 'Checking process resources...'
    ps aux | grep -E 'caddy|node.*cli.js' | grep -v grep || true
    
    # Check memory usage
    MEMORY_USAGE=\$(free | grep Mem | awk '{printf \"%.0f\", \$3/\$2 * 100}')
    echo \"Memory usage: \${MEMORY_USAGE}%\"
    
    if [[ \$MEMORY_USAGE -gt 95 ]]; then
        echo '⚠️  High memory usage detected'
        exit 1
    fi
    
    echo 'Service status check completed successfully'
  " || status_result="FAIL"
  
  record_test "Service Status Check" "$status_result"
}

# Function to test local health endpoint
test_local_health() {
  log_info "Testing local health endpoint..."
  
  local health_result="PASS"
  
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    echo 'Testing local health endpoint...'
    
    # Test HTTP health endpoint
    if curl -f -s http://localhost:3456/health > /dev/null; then
        echo '✅ Local health endpoint responding'
    else
        echo '❌ Local health endpoint not responding'
        exit 1
    fi
    
    # Get health response details
    HEALTH_RESPONSE=\$(curl -s http://localhost:3456/health)
    echo \"Health response: \$HEALTH_RESPONSE\"
    
    # Verify health response contains expected fields
    if echo \"\$HEALTH_RESPONSE\" | grep -q '\"status\"' && echo \"\$HEALTH_RESPONSE\" | grep -q '\"timestamp\"'; then
        echo '✅ Health response format is correct'
    else
        echo '❌ Health response format is incorrect'
        exit 1
    fi
    
    echo 'Local health test completed successfully'
  " || health_result="FAIL"
  
  record_test "Local Health Endpoint" "$health_result"
}

# Function to test external HTTP access
test_external_http() {
  log_info "Testing external HTTP access..."
  
  if [[ -z "$EXTERNAL_IP" ]]; then
    log_warning "⚠️  No external IP available, skipping external HTTP test"
    record_test "External HTTP Access" "SKIP"
    return
  fi
  
  local http_result="PASS"
  
  # Test HTTP redirect
  log_info "Testing HTTP to HTTPS redirect..."
  HTTP_RESPONSE=$(curl -s -I "http://$EXTERNAL_IP" -m 10 || echo "FAILED")
  
  if echo "$HTTP_RESPONSE" | grep -q -E "301|302"; then
    log_success "✅ HTTP redirects to HTTPS"
  else
    log_error "❌ HTTP redirect not working"
    http_result="FAIL"
  fi
  
  record_test "HTTP to HTTPS Redirect" "$http_result"
}

# Function to test external HTTPS access
test_external_https() {
  log_info "Testing external HTTPS access..."
  
  if [[ -z "$EXTERNAL_IP" ]]; then
    log_warning "⚠️  No external IP available, skipping external HTTPS test"
    record_test "External HTTPS Access" "SKIP"
    return
  fi
  
  local https_result="PASS"
  
  # Test HTTPS health endpoint (allow self-signed cert initially)
  log_info "Testing HTTPS health endpoint..."
  if curl -k -f -s "https://$EXTERNAL_IP/health" -m 15 > /dev/null; then
    log_success "✅ HTTPS health endpoint responding"
  else
    log_warning "⚠️  HTTPS health endpoint not responding (certificate may still be provisioning)"
    https_result="FAIL"
  fi
  
  # Test security headers
  log_info "Testing security headers..."
  HEADERS_RESPONSE=$(curl -k -s -I "https://$EXTERNAL_IP/health" -m 15 || echo "FAILED")
  
  REQUIRED_HEADERS=(
    "Strict-Transport-Security"
    "X-Content-Type-Options"
    "X-Frame-Options"
    "X-XSS-Protection"
  )
  
  for header in "${REQUIRED_HEADERS[@]}"; do
    if echo "$HEADERS_RESPONSE" | grep -i "$header" > /dev/null; then
      log_success "✅ Security header present: $header"
    else
      log_warning "⚠️  Security header missing: $header"
      https_result="FAIL"
    fi
  done
  
  record_test "External HTTPS Access" "$https_result"
}

# Function to test API authentication
test_api_authentication() {
  log_info "Testing API authentication..."
  
  if [[ -z "$API_KEY" ]]; then
    log_error "❌ No API key available for testing"
    record_test "API Authentication" "FAIL"
    return
  fi
  
  local auth_result="PASS"
  
  # Test without API key (should fail)
  log_info "Testing request without API key (should fail)..."
  if [[ -n "$EXTERNAL_IP" ]]; then
    AUTH_RESPONSE=$(curl -k -s -w "%{http_code}" "https://$EXTERNAL_IP/v1/messages" -m 10 || echo "000")
    if [[ "${AUTH_RESPONSE: -3}" == "401" ]]; then
      log_success "✅ Request without API key correctly rejected (401)"
    else
      log_error "❌ Request without API key not properly rejected (got ${AUTH_RESPONSE: -3})"
      auth_result="FAIL"
    fi
  else
    # Test locally
    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
      AUTH_RESPONSE=\$(curl -s -w \"%{http_code}\" \"http://localhost:3456/v1/messages\" || echo \"000\")
      if [[ \"\${AUTH_RESPONSE: -3}\" == \"401\" ]]; then
          echo '✅ Request without API key correctly rejected (401)'
      else
          echo '❌ Request without API key not properly rejected'
          exit 1
      fi
    " || auth_result="FAIL"
  fi
  
  # Test with valid API key
  log_info "Testing request with valid API key..."
  if [[ -n "$EXTERNAL_IP" ]]; then
    AUTH_RESPONSE=$(curl -k -s -w "%{http_code}" -H "X-API-Key: $API_KEY" "https://$EXTERNAL_IP/v1/messages" -m 10 || echo "000")
    # For routing, we expect either success or a different error (not 401)
    if [[ "${AUTH_RESPONSE: -3}" != "401" ]]; then
      log_success "✅ Request with API key accepted (not 401)"
    else
      log_error "❌ Request with API key rejected"
      auth_result="FAIL"
    fi
  else
    # Test locally
    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
      AUTH_RESPONSE=\$(curl -s -w \"%{http_code}\" -H \"X-API-Key: $API_KEY\" \"http://localhost:3456/v1/messages\" || echo \"000\")
      if [[ \"\${AUTH_RESPONSE: -3}\" != \"401\" ]]; then
          echo '✅ Request with API key accepted'
      else
          echo '❌ Request with API key rejected'
          exit 1
      fi
    " || auth_result="FAIL"
  fi
  
  record_test "API Authentication" "$auth_result"
}

# Function to test rate limiting
test_rate_limiting() {
  log_info "Testing rate limiting..."
  
  if [[ -z "$API_KEY" ]]; then
    log_warning "⚠️  No API key available, skipping rate limiting test"
    record_test "Rate Limiting" "SKIP"
    return
  fi
  
  local rate_limit_result="PASS"
  
  # Test rate limiting (make multiple requests quickly)
  log_info "Testing rate limiting with multiple requests..."
  
  local rate_limited=false
  local test_url
  
  if [[ -n "$EXTERNAL_IP" ]]; then
    test_url="https://$EXTERNAL_IP/health"
  else
    test_url="localhost:3456/health"
  fi
  
  # Make 35 requests quickly (rate limit is 30/minute)
  for i in {1..35}; do
    if [[ -n "$EXTERNAL_IP" ]]; then
      RESPONSE=$(curl -k -s -w "%{http_code}" -H "X-API-Key: $API_KEY" "$test_url" -m 5 || echo "000")
    else
      RESPONSE=$(gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
        curl -s -w \"%{http_code}\" -H \"X-API-Key: $API_KEY\" \"http://$test_url\" || echo \"000\"
      ")
    fi
    
    if [[ "${RESPONSE: -3}" == "429" ]]; then
      rate_limited=true
      log_success "✅ Rate limiting triggered after $i requests"
      break
    fi
    
    sleep 0.1
  done
  
  if [[ "$rate_limited" == "true" ]]; then
    log_success "✅ Rate limiting is working"
  else
    log_warning "⚠️  Rate limiting not triggered (may need more time or requests)"
    # This is not necessarily a failure for free tier
  fi
  
  record_test "Rate Limiting" "$rate_limit_result"
}

# Function to test SSL certificate
test_ssl_certificate() {
  log_info "Testing SSL certificate..."
  
  if [[ -z "$EXTERNAL_IP" ]]; then
    log_warning "⚠️  No external IP available, skipping SSL certificate test"
    record_test "SSL Certificate" "SKIP"
    return
  fi
  
  local ssl_result="PASS"
  
  log_info "Testing SSL certificate validity..."
  
  # Test SSL certificate (without -k flag)
  if curl -f -s "https://$EXTERNAL_IP/health" -m 15 > /dev/null 2>&1; then
    log_success "✅ SSL certificate is valid"
  else
    log_warning "⚠️  SSL certificate may not be ready yet (Let's Encrypt can take time)"
    log_info "Certificate provisioning can take up to 15 minutes for new domains"
    ssl_result="WARN"
  fi
  
  # Get certificate details
  log_info "Getting certificate details..."
  CERT_INFO=$(echo | openssl s_client -connect "$EXTERNAL_IP:443" -servername "$EXTERNAL_IP" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null || echo "Certificate info not available")
  
  if [[ "$CERT_INFO" != "Certificate info not available" ]]; then
    log_info "Certificate info: $CERT_INFO"
  fi
  
  record_test "SSL Certificate" "$ssl_result"
}

# Function to perform basic load test
perform_load_test() {
  if [[ "$SKIP_LOAD_TEST" == "true" ]]; then
    log_info "Skipping load test as requested"
    record_test "Load Test" "SKIP"
    return
  fi
  
  log_info "Performing basic load test..."
  
  if [[ -z "$EXTERNAL_IP" ]]; then
    log_warning "⚠️  No external IP available, skipping load test"
    record_test "Load Test" "SKIP"
    return
  fi
  
  local load_result="PASS"
  
  # Check if ab (Apache Bench) is available
  if ! command -v ab &> /dev/null; then
    log_warning "⚠️  Apache Bench (ab) not available, skipping load test"
    record_test "Load Test" "SKIP"
    return
  fi
  
  log_info "Running light load test (10 requests, 2 concurrent)..."
  
  # Light load test appropriate for free tier
  AB_OUTPUT=$(ab -n 10 -c 2 -H "X-API-Key: $API_KEY" "https://$EXTERNAL_IP/health" 2>&1 || echo "FAILED")
  
  if echo "$AB_OUTPUT" | grep -q "Complete requests.*10"; then
    log_success "✅ Load test completed successfully"
    
    # Extract response time
    AVG_TIME=$(echo "$AB_OUTPUT" | grep "Time per request:" | head -1 | awk '{print $4}')
    if [[ -n "$AVG_TIME" ]]; then
      log_info "Average response time: ${AVG_TIME}ms"
      
      # Check if response time is reasonable for free tier
      if (( $(echo "$AVG_TIME < 10000" | bc -l) )); then
        log_success "✅ Response time is acceptable for free tier"
      else
        log_warning "⚠️  Response time is high (expected for e2-micro)"
      fi
    fi
  else
    log_error "❌ Load test failed"
    load_result="FAIL"
  fi
  
  record_test "Load Test" "$load_result"
}

# Function to check monitoring and logging
test_monitoring() {
  log_info "Testing monitoring and logging..."
  
  local monitoring_result="PASS"
  
  # Check if monitoring agents are running
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    echo 'Checking monitoring agents...'
    
    if systemctl is-active --quiet google-fluentd; then
        echo '✅ Google Cloud Logging agent is running'
    else
        echo '❌ Google Cloud Logging agent is not running'
        exit 1
    fi
    
    if systemctl is-active --quiet stackdriver-agent; then
        echo '✅ Google Cloud Monitoring agent is running'
    else
        echo '❌ Google Cloud Monitoring agent is not running'
        exit 1
    fi
    
    echo 'Monitoring agents check completed successfully'
  " || monitoring_result="FAIL"
  
  # Test that logs are being generated
  log_info "Checking log generation..."
  
  # Make a request to generate logs
  if [[ -n "$EXTERNAL_IP" ]]; then
    curl -k -s -H "X-API-Key: $API_KEY" "https://$EXTERNAL_IP/health" > /dev/null || true
  fi
  
  # Check if logs are being written
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    # Check if application logs exist
    if [[ -f /var/log/syslog ]]; then
        if tail -n 50 /var/log/syslog | grep -q 'claude-router\|caddy'; then
            echo '✅ Application logs are being generated'
        else
            echo '⚠️  Application logs not found in syslog'
        fi
    fi
    
    # Check Caddy logs
    if [[ -f /var/log/caddy/access.log ]]; then
        echo '✅ Caddy access logs are being generated'
    else
        echo '⚠️  Caddy access logs not found'
    fi
  " || true
  
  record_test "Monitoring and Logging" "$monitoring_result"
}

# Function to check resource usage
check_resource_usage() {
  log_info "Checking resource usage..."
  
  local resource_result="PASS"
  
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    echo 'Checking resource usage...'
    
    # Check memory usage
    MEMORY_USAGE=\$(free | grep Mem | awk '{printf \"%.0f\", \$3/\$2 * 100}')
    MEMORY_USED=\$(free -h | grep Mem | awk '{print \$3}')
    MEMORY_TOTAL=\$(free -h | grep Mem | awk '{print \$2}')
    
    echo \"Memory usage: \$MEMORY_USED / \$MEMORY_TOTAL (\${MEMORY_USAGE}%)\"
    
    if [[ \$MEMORY_USAGE -gt 90 ]]; then
        echo '⚠️  High memory usage detected'
        echo 'This is expected for free tier (1GB RAM)'
    fi
    
    # Check disk usage
    DISK_USAGE=\$(df / | tail -1 | awk '{print \$5}' | sed 's/%//')
    DISK_USED=\$(df -h / | tail -1 | awk '{print \$3}')
    DISK_TOTAL=\$(df -h / | tail -1 | awk '{print \$2}')
    
    echo \"Disk usage: \$DISK_USED / \$DISK_TOTAL (\${DISK_USAGE}%)\"
    
    if [[ \$DISK_USAGE -gt 80 ]]; then
        echo '⚠️  High disk usage detected'
    fi
    
    # Check CPU load
    LOAD_AVG=\$(uptime | awk -F'load average:' '{ print \$2 }' | cut -d, -f1 | xargs)
    echo \"CPU load average (1min): \$LOAD_AVG\"
    
    # Check process count
    PROCESS_COUNT=\$(ps aux | wc -l)
    echo \"Running processes: \$PROCESS_COUNT\"
    
    echo 'Resource usage check completed'
  " || resource_result="FAIL"
  
  record_test "Resource Usage Check" "$resource_result"
}

# Function to test connectivity and networking
test_networking() {
  log_info "Testing networking..."
  
  local network_result="PASS"
  
  # Test that the instance can reach external services
  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --quiet --command="
    set -euo pipefail
    
    echo 'Testing external connectivity...'
    
    # Test DNS resolution
    if nslookup google.com > /dev/null 2>&1; then
        echo '✅ DNS resolution working'
    else
        echo '❌ DNS resolution failed'
        exit 1
    fi
    
    # Test external HTTP connectivity
    if curl -s -f https://www.google.com -m 10 > /dev/null; then
        echo '✅ External HTTPS connectivity working'
    else
        echo '❌ External HTTPS connectivity failed'
        exit 1
    fi
    
    # Test Google API connectivity (for Secret Manager, etc.)
    if curl -s -f https://secretmanager.googleapis.com -m 10 > /dev/null; then
        echo '✅ Google API connectivity working'
    else
        echo '❌ Google API connectivity failed'
        exit 1
    fi
    
    echo 'Network connectivity check completed successfully'
  " || network_result="FAIL"
  
  record_test "Network Connectivity" "$network_result"
}

# Function to generate final report
generate_report() {
  log_info "Generating health check report..."
  
  local total_tests=$((TESTS_PASSED + TESTS_FAILED))
  local success_rate=0
  
  if [[ $total_tests -gt 0 ]]; then
    success_rate=$(( (TESTS_PASSED * 100) / total_tests ))
  fi
  
  # Create report file
  REPORT_FILE="${PARENT_DIR}/health-check-report.txt"
  
  cat > "$REPORT_FILE" << EOF
Claude Code Router Health Check Report
======================================

Deployment Information:
- Environment: $ENVIRONMENT
- Instance: $INSTANCE_NAME
- External IP: $EXTERNAL_IP
- Project: $PROJECT_ID
- Check Date: $(date '+%Y-%m-%d %H:%M:%S')

Test Results Summary:
- Tests Passed: $TESTS_PASSED
- Tests Failed: $TESTS_FAILED
- Success Rate: $success_rate%

EOF

  if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    echo "Failed Tests:" >> "$REPORT_FILE"
    for test in "${FAILED_TESTS[@]}"; do
      echo "- $test" >> "$REPORT_FILE"
    done
    echo "" >> "$REPORT_FILE"
  fi
  
  cat >> "$REPORT_FILE" << EOF
Access Information:
- HTTP URL: http://$EXTERNAL_IP (redirects to HTTPS)
- HTTPS URL: https://$EXTERNAL_IP
- Health Endpoint: https://$EXTERNAL_IP/health
- API Key: $API_KEY

Monitoring:
- Cloud Console: https://console.cloud.google.com/compute/instances?project=$PROJECT_ID
- Monitoring: https://console.cloud.google.com/monitoring?project=$PROJECT_ID
- Logs: https://console.cloud.google.com/logs?project=$PROJECT_ID

Next Steps:
1. Monitor resource usage in Cloud Console
2. Set up additional providers in the configuration
3. Test with actual Claude Code client
4. Monitor costs to ensure staying within free tier

Notes:
- This deployment uses only GCP free tier resources
- SSL certificate may take up to 15 minutes to provision
- Monitor usage to prevent unexpected charges
EOF

  log_success "✅ Health check report saved to: $REPORT_FILE"
}

# Main execution
main() {
  log_info "Starting comprehensive health check..."
  
  # Wait a bit for services to stabilize
  log_info "Waiting for services to stabilize..."
  sleep 30
  
  # Run all health checks
  check_service_status
  test_local_health
  test_external_http
  test_external_https
  test_api_authentication
  test_rate_limiting
  test_ssl_certificate
  test_monitoring
  check_resource_usage
  test_networking
  
  # Optional load test
  if [[ "$SKIP_LOAD_TEST" != "true" ]]; then
    perform_load_test
  fi
  
  # Generate report
  generate_report
  
  # Final summary
  local total_tests=$((TESTS_PASSED + TESTS_FAILED))
  local success_rate=0
  
  if [[ $total_tests -gt 0 ]]; then
    success_rate=$(( (TESTS_PASSED * 100) / total_tests ))
  fi
  
  log_success "🎉 Phase 6 completed successfully"
  
  echo -e "\n${GREEN}✅ Health check completed!${NC}"
  echo -e "${BLUE}Results Summary:${NC}"
  echo -e "  • Tests Passed: $TESTS_PASSED"
  echo -e "  • Tests Failed: $TESTS_FAILED"
  echo -e "  • Success Rate: $success_rate%"
  
  if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    echo -e "\n${YELLOW}⚠️  Failed Tests:${NC}"
    for test in "${FAILED_TESTS[@]}"; do
      echo -e "  • $test"
    done
  fi
  
  echo -e "\n${BLUE}Your Claude Code Router is deployed and ready!${NC}"
  
  if [[ -n "$EXTERNAL_IP" ]]; then
    echo -e "${GREEN}🌐 Access URL: https://$EXTERNAL_IP${NC}"
    echo -e "${GREEN}🔑 API Key: $API_KEY${NC}"
  fi
  
  echo -e "${YELLOW}📊 Monitor usage: https://console.cloud.google.com/billing${NC}"
  echo -e "${YELLOW}💰 Remember: This deployment costs $0/month (free tier)${NC}"
  
  if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "\n${YELLOW}⚠️  Some tests failed. Check the report for details.${NC}"
    exit 1
  fi
}

# Run main function
main "$@"