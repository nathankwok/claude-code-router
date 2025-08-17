# Claude Code Router - GCP Free Tier Deployment PRD

## Executive Summary

This PRD outlines the deployment of the Claude Code Router application to Google Cloud Platform (GCP) using only free tier resources. The deployment is optimized for the constraints of GCP's Always Free tier while maintaining security, basic monitoring, and automated deployment capabilities.

## Project Overview

### Objective
Deploy the Claude Code Router (a TypeScript/Node.js Express-based LLM proxy service) to GCP Compute Engine free tier with:
- Public internet accessibility via direct VM external IP
- Essential security hardening within resource constraints
- Basic monitoring and logging within free tier quotas
- Cost-optimized deployment automation
- Strict adherence to free tier limits to avoid charges

### Current Architecture Analysis
- **Application**: Express.js server (port 3456) with TypeScript
- **Framework**: Uses @musistudio/llms (Fastify-based)
- **Dependencies**: OpenAI SDK, tiktoken, UUID, JSON5
- **Build System**: ESBuild with TypeScript
- **Containerization**: Existing Dockerfile using Node.js 20 Alpine
- **Configuration**: File-based config at `~/.claude-code-router/config.json`

## Requirements

### Functional Requirements

#### FR1: Infrastructure Deployment
- Deploy to GCP Compute Engine e2-micro instance (free tier)
- Configure default VPC network with firewall rules
- Direct VM HTTPS using Caddy reverse proxy with Let's Encrypt
- Configure firewall rules for HTTP/HTTPS traffic only
- Ensure deployment in free tier eligible regions (us-central1, us-east1, us-west1)

#### FR2: Security Implementation
- **Authentication**: Implement API key-based authentication middleware
- **Rate Limiting**: Add request throttling to prevent abuse
- **Security Headers**: Implement Helmet.js security headers
- **Input Validation**: Add request validation and sanitization
- **HTTPS Enforcement**: Force HTTPS redirects and HSTS headers
- **IP Filtering**: Optional IP allowlisting capability

#### FR3: Monitoring and Logging
- Cloud Logging integration for structured application logs
- Cloud Monitoring with custom metrics and alerts
- Health check endpoints (`/health`, `/metrics`)
- Performance monitoring and alerting
- Log rotation and retention policies

#### FR4: Deployment Automation
- Idempotent deployment scripts using gcloud CLI
- Modular phase-based deployment architecture
- Rollback and cleanup capabilities
- Environment-specific configuration support
- Comprehensive error handling and validation

### Non-Functional Requirements

#### NFR1: Security
- No API keys or secrets in deployment scripts
- Secure secret management using Google Secret Manager
- Minimal attack surface with least privilege access
- Regular security updates and vulnerability scanning

#### NFR2: Reliability
- Service availability > 99.5%
- Automatic restart on failure via systemd
- Load balancer health checks
- Graceful shutdown handling

#### NFR3: Performance
- Response time < 2s for proxy requests
- Support for concurrent connections > 100
- Efficient resource utilization

#### NFR4: Maintainability
- Clear deployment documentation
- Modular and reusable deployment components
- Comprehensive logging for troubleshooting
- Version-controlled configuration

## Technical Specifications

### Infrastructure Architecture

```
Internet → Caddy Reverse Proxy (HTTPS) → Compute Engine e2-micro VM (HTTP:3456)
                    ↓                              ↓
         Let's Encrypt SSL                 Cloud Logging (free tier)
                                                   ↓
                                          Cloud Monitoring (free tier)
```

### Deployment Script Architecture

#### Phase 1: Pre-deployment (`scripts/01-predeploy.sh`)
**Purpose**: Environment validation and free tier compliance verification

**Tasks**:
- Verify gcloud CLI installation and authentication
- **Validate Free Tier Eligibility**:
  - Check account is within 90-day free trial OR has free tier resources available
  - Verify deployment region is free tier eligible (us-central1, us-east1, us-west1)
  - Confirm no existing billable resources that would trigger charges
- Check required GCP APIs are enabled:
  - Compute Engine API (`compute.googleapis.com`)
  - Cloud Logging API (`logging.googleapis.com`) 
  - Cloud Monitoring API (`monitoring.googleapis.com`)
  - Secret Manager API (`secretmanager.googleapis.com`)
- Validate project permissions and quotas
- **Free Tier Resource Validation**:
  - Ensure no existing e2-micro instance in selected region
  - Verify persistent disk usage under 30GB limit
  - Check that no static IP addresses are allocated
- Check environment variables and configuration files
- Set up billing alerts and budget (even for free tier)

**Free Tier Validation Script**:
```bash
#!/bin/bash
# Validate free tier compliance before deployment

validate_free_tier() {
  echo "🔍 Validating GCP Free Tier compliance..."
  
  # Check region eligibility
  if [[ ! "$REGION" =~ ^(us-central1|us-east1|us-west1)$ ]]; then
    echo "❌ Error: Region $REGION is not free tier eligible"
    echo "   Use: us-central1, us-east1, or us-west1"
    exit 1
  fi
  
  # Check for existing e2-micro instances
  EXISTING_INSTANCES=$(gcloud compute instances list \
    --filter="machineType:e2-micro AND zone:($REGION-a OR $REGION-b OR $REGION-c)" \
    --format="value(name)" | wc -l)
  
  if [[ $EXISTING_INSTANCES -gt 0 ]]; then
    echo "❌ Error: Free tier allows only 1 e2-micro instance globally"
    echo "   Found $EXISTING_INSTANCES existing e2-micro instances"
    exit 1
  fi
  
  # Check persistent disk usage
  DISK_USAGE=$(gcloud compute disks list \
    --filter="type:pd-standard" \
    --format="value(sizeGb)" | awk '{sum+=$1} END {print sum+0}')
  
  if [[ $DISK_USAGE -gt 20 ]]; then
    echo "⚠️  Warning: Current persistent disk usage: ${DISK_USAGE}GB"
    echo "   Free tier limit: 30GB. Deployment will use additional 30GB."
    echo "   Total after deployment: $((DISK_USAGE + 30))GB"
    if [[ $((DISK_USAGE + 30)) -gt 30 ]]; then
      echo "❌ Error: Would exceed free tier disk limit"
      exit 1
    fi
  fi
  
  # Check for static IP addresses
  STATIC_IPS=$(gcloud compute addresses list --format="value(name)" | wc -l)
  if [[ $STATIC_IPS -gt 0 ]]; then
    echo "⚠️  Warning: Found $STATIC_IPS static IP addresses"
    echo "   Static IPs incur charges (~$3/month each)"
    echo "   This deployment uses ephemeral IP (free)"
  fi
  
  echo "✅ Free tier validation passed"
}
```

**Error Handling**: 
- Exit early if prerequisites not met
- Provide clear error messages with remediation steps
- Support `--force` flag to skip non-critical validations
- **NEVER** skip free tier compliance checks (prevent accidental charges)

#### Phase 2: Infrastructure (`scripts/02-infrastructure.sh`)
**Purpose**: Create GCP network and compute resources

**Tasks**:
- Create VPC network with custom subnet
- Create firewall rules for HTTP/HTTPS traffic
- Create Compute Engine instance with specific configuration:
  - Machine type: e2-micro (1 vCPU, 1GB RAM - free tier)
  - Boot disk: 30GB standard persistent disk with Ubuntu 20.04 LTS (free tier limit)
  - Network tags for firewall targeting
  - Service account with minimal permissions
- Use ephemeral external IP (no static IP to avoid charges)
- Configure Caddy for HTTPS termination (replaces load balancer)

**Resource Naming Convention**:
```bash
RESOURCE_PREFIX="${PROJECT_ID}-claude-router"
VPC_NAME="${RESOURCE_PREFIX}-vpc"
SUBNET_NAME="${RESOURCE_PREFIX}-subnet"
FIREWALL_NAME="${RESOURCE_PREFIX}-allow-http"
INSTANCE_NAME="${RESOURCE_PREFIX}-vm"
```

**Idempotency Checks**:
```bash
# Check if VPC exists
if gcloud compute networks describe $VPC_NAME 2>/dev/null; then
  echo "VPC $VPC_NAME already exists"
else
  gcloud compute networks create $VPC_NAME --subnet-mode=custom
fi

# Check if instance exists
if gcloud compute instances describe $INSTANCE_NAME --zone=$ZONE 2>/dev/null; then
  echo "Instance $INSTANCE_NAME already exists"
else
  # Create instance
fi
```

#### Phase 3: Security (`scripts/03-security.sh`)
**Purpose**: Implement essential security hardening within free tier constraints

**Tasks**:
- Generate API keys for application authentication
- Store secrets in Google Secret Manager (free tier: 6 active secret versions)
- Configure Let's Encrypt SSL certificates via Caddy
- Set up VM-level firewall rules for HTTP/HTTPS only
- Configure service account with minimal permissions (free)
- Basic intrusion detection (simplified, no fail2ban due to resource constraints)
- Configure Caddy for automatic HTTPS and security headers

**Security Enhancements to Application**:

**Authentication Middleware** (`src/middleware/auth.ts`):
```typescript
import { FastifyRequest, FastifyReply } from 'fastify';

export async function authMiddleware(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const apiKey = request.headers['x-api-key'];
  
  if (!apiKey || !validateApiKey(apiKey)) {
    reply.code(401).send({ error: 'Unauthorized' });
    return;
  }
}

function validateApiKey(key: string): boolean {
  // Implement secure API key validation
  // Consider using crypto.timingSafeEqual for comparison
}
```

**Rate Limiting (Free Tier Optimized)**:
```typescript
import rateLimit from '@fastify/rate-limit';

// Reduced limits for single micro instance
await fastify.register(rateLimit, {
  max: 30, // requests per windowMs (reduced for e2-micro)
  timeWindow: '1 minute',
  // Memory-efficient storage
  store: new Map()
});
```

**Security Headers** (using Helmet.js equivalent):
```typescript
await fastify.register(helmet, {
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      styleSrc: ["'self'", "'unsafe-inline'"],
      scriptSrc: ["'self'"],
      imgSrc: ["'self'", "data:", "https:"],
    },
  },
  hsts: {
    maxAge: 31536000,
    includeSubDomains: true,
    preload: true
  }
});
```

#### Phase 4: Application (`scripts/04-application.sh`)
**Purpose**: Build and deploy the application container

**Tasks**:
- Build Docker image with security optimizations
- Push image to Google Container Registry or Artifact Registry
- Deploy container to Compute Engine instance
- Configure environment variables from Secret Manager
- Set up systemd service for auto-restart
- Configure log forwarding to Cloud Logging

**Memory-Optimized Dockerfile** (`Dockerfile.freetier`):
```dockerfile
# Multi-stage build optimized for 1GB RAM constraint
FROM node:20-alpine AS builder

WORKDIR /app
COPY package*.json pnpm-lock.yaml ./
# Limit memory during build
RUN npm install -g pnpm && NODE_OPTIONS="--max-old-space-size=512" pnpm install --frozen-lockfile --production=false
COPY . .
RUN NODE_OPTIONS="--max-old-space-size=512" pnpm run build

FROM node:20-alpine AS runtime

# Install Caddy for reverse proxy
RUN apk add --no-cache caddy

# Create non-root user
RUN addgroup -g 1001 -S nodejs && adduser -S nodejs -u 1001

WORKDIR /app

# Copy only production dependencies and built application
COPY package*.json pnpm-lock.yaml ./
RUN npm install -g pnpm && pnpm install --frozen-lockfile --production=true && pnpm cache clean --force

COPY --from=builder --chown=nodejs:nodejs /app/dist ./dist
COPY caddy/Caddyfile /etc/caddy/Caddyfile

# Limit Node.js memory usage for 1GB constraint
ENV NODE_OPTIONS="--max-old-space-size=768"

# Health check with lower frequency to reduce resource usage
HEALTHCHECK --interval=60s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3456/health', (res) => { process.exit(res.statusCode === 200 ? 0 : 1) })"

EXPOSE 80 443 3456

# Start both Caddy and Node.js application
COPY start.sh /start.sh
RUN chmod +x /start.sh
CMD ["/start.sh"]
```

**Caddyfile Configuration** (`caddy/Caddyfile`):
```caddy
# Automatic HTTPS with Let's Encrypt
:80 {
	# Redirect HTTP to HTTPS
	redir https://{host}{uri} permanent
}

:443 {
	# Automatic HTTPS
	tls internal
	
	# Security headers
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		X-XSS-Protection "1; mode=block"
		Referrer-Policy "strict-origin-when-cross-origin"
		Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
	}
	
	# Rate limiting at reverse proxy level
	rate_limit {
		zone static_ip_10rs {
			key {remote_ip}
			window 1m
			request_limit 30
		}
	}
	
	# Reverse proxy to Node.js application
	reverse_proxy localhost:3456 {
		header_up Host {host}
		header_up X-Real-IP {remote_ip}
		header_up X-Forwarded-For {remote_ip}
		header_up X-Forwarded-Proto {scheme}
	}
	
	# Health check endpoint
	handle /health {
		reverse_proxy localhost:3456
	}
}
```

**Startup Script** (`start.sh`):
```bash
#!/bin/sh
set -e

# Start Caddy in background
caddy start --config /etc/caddy/Caddyfile &

# Wait for Caddy to start
sleep 2

# Start Node.js application in foreground
exec node dist/cli.js start
```

**Systemd Services** - Dual service setup for free tier:

**Node.js Service** (`/etc/systemd/system/claude-router.service`):
```ini
[Unit]
Description=Claude Code Router Node.js Service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=5
User=claude-router
Environment=NODE_OPTIONS=--max-old-space-size=768
Environment=NODE_ENV=production
ExecStart=/usr/bin/node /app/dist/cli.js start
MemoryMax=800M
MemorySwapMax=0

[Install]
WantedBy=multi-user.target
```

**Caddy Service** (`/etc/systemd/system/caddy.service`):
```ini
[Unit]
Description=Caddy Web Server
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
MemoryMax=200M

[Install]
WantedBy=multi-user.target
```

#### Phase 5: Monitoring (`scripts/05-monitoring.sh`)
**Purpose**: Set up comprehensive monitoring and logging

**Tasks**:
- Install and configure Cloud Logging agent
- Set up application metrics collection
- Create basic Cloud Monitoring dashboard (free tier)
- Configure essential alerting policies within free limits:
  - Critical: Instance downtime (basic uptime check)
  - Warning: High memory usage (>90% for 15 minutes)
  - Info: Application restart events
- Implement log-based basic metrics (within 50GB monthly limit)
- Set up budget alerts to prevent cost overruns

**Application Health Endpoints**:
```typescript
// Health check endpoint
fastify.get('/health', async (request, reply) => {
  try {
    // Check database connectivity, external services, etc.
    const health = {
      status: 'healthy',
      timestamp: new Date().toISOString(),
      uptime: process.uptime(),
      version: process.env.npm_package_version
    };
    reply.send(health);
  } catch (error) {
    reply.code(503).send({ status: 'unhealthy', error: error.message });
  }
});

// Metrics endpoint for monitoring
fastify.get('/metrics', async (request, reply) => {
  const metrics = {
    requests_total: requestCounter,
    response_time_ms: averageResponseTime,
    active_connections: activeConnections,
    memory_usage: process.memoryUsage(),
    cpu_usage: process.cpuUsage()
  };
  reply.send(metrics);
});
```

**Free Tier Monitoring Setup**:
```bash
# Basic uptime check (free tier)
gcloud alpha monitoring policies create \
  --policy-from-file=monitoring/basic-uptime-alert.yaml

# Memory usage alert (free tier)
gcloud alpha monitoring policies create \
  --policy-from-file=monitoring/memory-alert.yaml

# Budget alert to prevent overages
gcloud billing budgets create \
  --billing-account=${BILLING_ACCOUNT_ID} \
  --display-name="Free Tier Budget" \
  --budget-amount=1USD \
  --threshold-percent=50,90,100
```

#### Phase 6: Health Check (`scripts/06-healthcheck.sh`)
**Purpose**: Validate deployment and perform integration tests

**Tasks**:
- Verify service is responding on all endpoints
- Test authentication and authorization
- Validate security headers are present
- Check monitoring dashboards are receiving data
- Perform basic load testing
- Validate SSL certificate and HTTPS enforcement
- Test failover and recovery scenarios

**Health Check Tests**:
```bash
#!/bin/bash
# Basic connectivity test
curl -f https://${LOAD_BALANCER_IP}/health || exit 1

# Authentication test
curl -H "X-API-Key: ${TEST_API_KEY}" \
     -f https://${LOAD_BALANCER_IP}/v1/messages || exit 1

# Security headers test
response=$(curl -I https://${LOAD_BALANCER_IP}/health)
echo "$response" | grep -q "Strict-Transport-Security" || exit 1
echo "$response" | grep -q "X-Content-Type-Options" || exit 1

# Load test (basic)
ab -n 100 -c 10 https://${LOAD_BALANCER_IP}/health
```

### Configuration Management

#### Environment Configuration
Create environment-specific configuration files:

**`config/production.env`**:
```bash
# GCP Configuration (Free Tier Regions Only)
PROJECT_ID=your-project-id
REGION=us-central1  # Free tier eligible region
ZONE=us-central1-a  # Free tier eligible zone
# Alternative free tier regions: us-east1, us-west1

# Instance Configuration (Free Tier)
MACHINE_TYPE=e2-micro
DISK_SIZE=30GB
DISK_TYPE=pd-standard
INSTANCE_NAME_PREFIX=claude-router

# Application Configuration
NODE_ENV=production
PORT=3456
LOG_LEVEL=info

# Security Configuration (Free Tier Optimized)
API_KEY_SECRET_NAME=claude-router-api-key
RATE_LIMIT_MAX=30
RATE_LIMIT_WINDOW=60000
MAX_CONNECTIONS=50

# Monitoring Configuration
ENABLE_METRICS=true
METRICS_PORT=9090
```

#### Secret Management
```bash
# Store API keys in Secret Manager
gcloud secrets create claude-router-api-key \
  --data-file=secrets/api-key.txt

# Grant service account access
gcloud secrets add-iam-policy-binding claude-router-api-key \
  --member="serviceAccount:claude-router-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"
```

### Main Deployment Script

**`deploy.sh`** - Master orchestration script:
```bash
#!/bin/bash
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/${ENVIRONMENT:-production}.env"
LOG_FILE="${SCRIPT_DIR}/logs/deployment-$(date +%Y%m%d_%H%M%S).log"

# Source configuration
source "$CONFIG_FILE"

# Usage function
usage() {
  cat << EOF
Usage: $0 [OPTIONS] [PHASES...]

Deploy Claude Code Router to GCP Compute Engine

OPTIONS:
  -e, --environment ENV    Environment (production, staging, dev) [default: production]
  -p, --phase PHASE        Run specific phase only (1-6)
  -c, --cleanup           Run cleanup/rollback
  -v, --verbose           Verbose output
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

EOF
}

# Logging function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error() {
  log "ERROR: $*" >&2
  exit 1
}

# Parse command line arguments
PHASES=()
CLEANUP=false
VERBOSE=false
ENVIRONMENT="production"

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

# Set default phases if none specified
if [[ ${#PHASES[@]} -eq 0 ]]; then
  PHASES=(1 2 3 4 5 6)
fi

# Create log directory
mkdir -p "$(dirname "$LOG_FILE")"

log "Starting deployment to $ENVIRONMENT environment"
log "Phases to run: ${PHASES[*]}"

# Run cleanup if requested
if [[ "$CLEANUP" == "true" ]]; then
  log "Running cleanup..."
  "${SCRIPT_DIR}/scripts/cleanup.sh" --environment "$ENVIRONMENT"
  exit 0
fi

# Execute phases
for phase in "${PHASES[@]}"; do
  case $phase in
    1)
      log "Running Phase 1: Pre-deployment validation"
      "${SCRIPT_DIR}/scripts/01-predeploy.sh" --environment "$ENVIRONMENT"
      ;;
    2)
      log "Running Phase 2: Infrastructure deployment"
      "${SCRIPT_DIR}/scripts/02-infrastructure.sh" --environment "$ENVIRONMENT"
      ;;
    3)
      log "Running Phase 3: Security setup"
      "${SCRIPT_DIR}/scripts/03-security.sh" --environment "$ENVIRONMENT"
      ;;
    4)
      log "Running Phase 4: Application deployment"
      "${SCRIPT_DIR}/scripts/04-application.sh" --environment "$ENVIRONMENT"
      ;;
    5)
      log "Running Phase 5: Monitoring setup"
      "${SCRIPT_DIR}/scripts/05-monitoring.sh" --environment "$ENVIRONMENT"
      ;;
    6)
      log "Running Phase 6: Health checks"
      "${SCRIPT_DIR}/scripts/06-healthcheck.sh" --environment "$ENVIRONMENT"
      ;;
    *)
      error "Invalid phase: $phase"
      ;;
  esac
  
  if [[ $? -ne 0 ]]; then
    error "Phase $phase failed. Check logs at $LOG_FILE"
  fi
  
  log "Phase $phase completed successfully"
done

log "Deployment completed successfully!"
# Get ephemeral IP instead of static IP (free tier)
EXTERNAL_IP=$(gcloud compute instances describe ${INSTANCE_NAME} --zone=${ZONE} --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
log "Access your application at: https://${EXTERNAL_IP}" 
log "⚠️  Note: This is an ephemeral IP. It may change if the instance is stopped/started."
```

## Security Considerations

### Network Security
- VPC with custom subnets and minimal firewall rules
- Load balancer with DDoS protection
- No direct SSH access (use Cloud Console or IAP)
- Private Google Access for API calls

### Application Security  
- API key authentication required for all endpoints
- Rate limiting to prevent abuse
- Input validation and sanitization
- Security headers (HSTS, CSP, XSS protection)
- Regular dependency updates and vulnerability scanning

### Data Security
- No sensitive data stored on instance
- Secrets managed via Google Secret Manager
- Encrypted communication (HTTPS only)
- Audit logging for all access

## Monitoring and Alerting

### Key Metrics
- **Application**: Request rate, response time, error rate, active connections
- **Infrastructure**: CPU usage, memory usage, disk I/O, network traffic
- **Security**: Failed authentication attempts, unusual traffic patterns

### Alert Policies
- **Critical**: Service down, high error rate (>5%), severe performance degradation
- **Warning**: High resource usage (>80%), elevated response times
- **Info**: Deployment events, configuration changes

### Dashboards
- **Application Performance**: Request metrics, error rates, response times
- **Infrastructure Health**: Resource utilization, instance status
- **Security Overview**: Authentication metrics, security events

## Testing Strategy

### Pre-deployment Testing
- Unit tests for all new security middleware
- Integration tests for authentication flow
- Load testing for performance validation
- Security scanning of Docker images

### Post-deployment Validation
- Automated health checks
- Security header validation
- SSL certificate verification
- Performance baseline establishment

## Rollback Strategy

### Automated Rollback Triggers
- Health check failures for >5 minutes
- Error rate >10% for >2 minutes
- Manual rollback command

### Rollback Process
1. Stop application service
2. Revert to previous Docker image
3. Restore previous configuration
4. Validate service health
5. Update monitoring dashboards

## Documentation Requirements

### Deployment Documentation
- **Setup Guide**: Prerequisites and initial setup
- **Deployment Guide**: Step-by-step deployment instructions
- **Troubleshooting Guide**: Common issues and solutions
- **Security Guide**: Security configurations and best practices

### Operational Documentation
- **Monitoring Guide**: Dashboard usage and alert response
- **Maintenance Guide**: Update procedures and backup strategies
- **Incident Response**: Emergency procedures and contacts

## Success Criteria

### Deployment Success (Free Tier)
- [ ] All phases complete without errors
- [ ] Application accessible via HTTPS (Caddy + Let's Encrypt)
- [ ] Authentication working correctly
- [ ] Basic monitoring dashboard populated (within free limits)
- [ ] Health checks passing
- [ ] Security headers present (via Caddy)
- [ ] SSL certificate valid (Let's Encrypt)
- [ ] Budget alerts configured
- [ ] Memory usage within 1GB limit
- [ ] No unexpected charges incurred

### Operational Success (30 days post-deployment)
- [ ] Service availability >95% (adjusted for single instance)
- [ ] Average response time <5s (adjusted for e2-micro performance)
- [ ] Zero security incidents
- [ ] Basic monitoring alerts functioning
- [ ] No cost overruns (stayed within free tier)
- [ ] Memory usage consistently under 900MB
- [ ] Successful basic security validation

## Implementation Timeline

### Phase 1-2: Infrastructure (Week 1)
- Environment validation scripts
- GCP resource creation scripts
- Basic connectivity testing

### Phase 3-4: Security & Application (Week 2)  
- Security middleware implementation
- Application deployment scripts
- SSL certificate configuration

### Phase 5-6: Monitoring & Validation (Week 3)
- Monitoring setup scripts
- Health check implementation
- Load testing and validation

### Documentation & Handoff (Week 4)
- Complete documentation
- Training materials
- Operational handoff

## Cost Estimation

### Monthly Costs (USD) - Free Tier
- **Compute Engine** (e2-micro): $0 (always free)
- **Persistent Disk** (30GB standard): $0 (always free)
- **Cloud Logging**: $0 (within 50GB free allowance)
- **Cloud Monitoring**: $0 (within free tier limits)
- **Ephemeral External IP**: $0 (no static IP)
- **SSL Certificate**: $0 (Let's Encrypt)
- **Egress Traffic**: $0 (1GB/month free to most regions)

**Total Estimated Monthly Cost**: $0 (within free tier limits)

**⚠️ Important**: Exceeding free tier limits will incur charges. Monitor usage closely.

## Risk Mitigation

### High-Priority Risks (Free Tier Specific)
1. **Unexpected Charges**: Mitigated by budget alerts, usage monitoring, free tier validation
2. **Resource Exhaustion**: Mitigated by memory limits, connection limits, resource monitoring
3. **Performance Degradation**: Mitigated by optimized code, reduced resource usage, connection pooling
4. **IP Address Changes**: Mitigated by documentation, DNS setup instructions, IP monitoring

### Medium-Priority Risks
1. **Free Tier Quota Exhaustion**: Mitigated by usage monitoring, log rotation, connection limits
2. **Single Point of Failure**: Accepted trade-off for free tier (no load balancer redundancy)
3. **Limited Monitoring**: Mitigated by essential health checks, basic alerting within free limits

## Conclusion

This PRD provides a cost-optimized plan for deploying the Claude Code Router to GCP using only free tier resources. The deployment maintains essential security and monitoring capabilities while strictly adhering to free tier limits to avoid any charges.

### Key Free Tier Constraints & Adaptations:
- **Compute**: Single e2-micro instance (1 vCPU, 1GB RAM)
- **Storage**: 30GB standard persistent disk
- **Network**: Ephemeral IP, no load balancer, Caddy for HTTPS
- **Monitoring**: Basic alerts within free quotas
- **Memory Management**: Node.js heap limited to 768MB
- **Rate Limiting**: Reduced to 30 requests/minute

### Implementation Requirements:
- Google Cloud Platform free tier account
- Basic understanding of gcloud CLI
- Familiarity with Caddy reverse proxy
- Node.js/TypeScript development knowledge
- Linux system administration basics
- Cost monitoring and budget management

### Important Limitations:
- **Single Point of Failure**: No load balancer redundancy
- **Performance**: Limited by 1GB RAM and single vCPU
- **Availability**: Lower SLA due to single instance
- **Monitoring**: Basic alerts only
- **IP Stability**: Ephemeral IP may change

### Cost Protection:
- Budget alerts at $0.50, $0.90, and $1.00
- Usage monitoring to prevent quota overruns
- Automatic resource limits to prevent scaling

Upon successful implementation, this deployment provides a **completely free** LLM proxy service suitable for development, testing, and light production use cases while maintaining essential security practices.