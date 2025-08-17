# Claude Code Router - GCP Compute Engine Deployment PRD

## Executive Summary

This PRD outlines the comprehensive deployment of the Claude Code Router application to Google Cloud Platform (GCP) Compute Engine with public internet access. The deployment includes security hardening, monitoring, logging, and automated deployment scripts that are idempotent and modular.

## Project Overview

### Objective
Deploy the Claude Code Router (a TypeScript/Node.js Express-based LLM proxy service) to GCP Compute Engine with:
- Public internet accessibility via load balancer
- Comprehensive security hardening
- Production-ready monitoring and logging
- Idempotent deployment automation

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
- Deploy to GCP Compute Engine instance (e2-medium minimum)
- Configure VPC network with proper security groups
- Set up Cloud Load Balancer with SSL termination
- Configure firewall rules for HTTP/HTTPS traffic only

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
Internet → Cloud Load Balancer (HTTPS) → VPC Firewall → Compute Engine VM (HTTP:3456)
                                                      ↓
                                              Cloud Logging & Monitoring
```

### Deployment Script Architecture

#### Phase 1: Pre-deployment (`scripts/01-predeploy.sh`)
**Purpose**: Environment validation and prerequisite setup

**Tasks**:
- Verify gcloud CLI installation and authentication
- Check required GCP APIs are enabled:
  - Compute Engine API (`compute.googleapis.com`)
  - Cloud Logging API (`logging.googleapis.com`) 
  - Cloud Monitoring API (`monitoring.googleapis.com`)
  - Cloud Load Balancing API (`clouddns.googleapis.com`)
- Validate project permissions and quotas
- Check environment variables and configuration files
- Verify Docker installation (for image building)

**Idempotency**: Use `gcloud services list --enabled` to check existing API enablement

**Error Handling**: 
- Exit early if prerequisites not met
- Provide clear error messages with remediation steps
- Support `--force` flag to skip some validations

#### Phase 2: Infrastructure (`scripts/02-infrastructure.sh`)
**Purpose**: Create GCP network and compute resources

**Tasks**:
- Create VPC network with custom subnet
- Create firewall rules for HTTP/HTTPS traffic
- Create Compute Engine instance with specific configuration:
  - Machine type: e2-medium (2 vCPU, 4GB RAM)
  - Boot disk: 20GB SSD with Ubuntu 20.04 LTS
  - Network tags for firewall targeting
  - Service account with minimal permissions
- Create external IP address
- Set up Cloud Load Balancer (optional)

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
**Purpose**: Implement security hardening and authentication

**Tasks**:
- Generate API keys for application authentication
- Store secrets in Google Secret Manager
- Configure SSL certificates (Let's Encrypt or Google-managed)
- Set up firewall rules with strict port access
- Configure service account with minimal permissions
- Install and configure fail2ban for intrusion prevention

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

**Rate Limiting**:
```typescript
import rateLimit from '@fastify/rate-limit';

await fastify.register(rateLimit, {
  max: 100, // requests per windowMs
  timeWindow: '1 minute'
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

**Enhanced Dockerfile** (`Dockerfile.production`):
```dockerfile
# Multi-stage build for security and size optimization
FROM node:20-alpine AS builder

WORKDIR /app
COPY package*.json pnpm-lock.yaml ./
RUN npm install -g pnpm && pnpm install --frozen-lockfile --production=false
COPY . .
RUN pnpm run build

FROM node:20-alpine AS runtime

# Create non-root user
RUN addgroup -g 1001 -S nodejs && adduser -S nodejs -u 1001

WORKDIR /app

# Copy only production dependencies and built application
COPY package*.json pnpm-lock.yaml ./
RUN npm install -g pnpm && pnpm install --frozen-lockfile --production=true

COPY --from=builder --chown=nodejs:nodejs /app/dist ./dist

# Security: Run as non-root user
USER nodejs

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3456/health', (res) => { process.exit(res.statusCode === 200 ? 0 : 1) })"

EXPOSE 3456

CMD ["node", "dist/cli.js", "start"]
```

**Systemd Service** (`/etc/systemd/system/claude-router.service`):
```ini
[Unit]
Description=Claude Code Router Service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=claude-router
ExecStart=/usr/bin/docker run --rm \
  --name claude-router \
  -p 127.0.0.1:3456:3456 \
  -e NODE_ENV=production \
  --log-driver=gcplogs \
  gcr.io/${PROJECT_ID}/claude-router:latest

[Install]
WantedBy=multi-user.target
```

#### Phase 5: Monitoring (`scripts/05-monitoring.sh`)
**Purpose**: Set up comprehensive monitoring and logging

**Tasks**:
- Install and configure Cloud Logging agent
- Set up application metrics collection
- Create Cloud Monitoring dashboards
- Configure alerting policies for:
  - High error rates (>5% over 5 minutes)
  - High response times (>5s average over 5 minutes)
  - Instance downtime
  - High CPU/memory usage (>80% for 10 minutes)
- Set up log-based metrics for custom monitoring

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

**Cloud Monitoring Alert Policies**:
```bash
# High error rate alert
gcloud alpha monitoring policies create \
  --policy-from-file=monitoring/error-rate-alert.yaml

# Instance down alert  
gcloud alpha monitoring policies create \
  --policy-from-file=monitoring/instance-down-alert.yaml
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
# GCP Configuration
PROJECT_ID=your-project-id
REGION=us-central1
ZONE=us-central1-a

# Instance Configuration  
MACHINE_TYPE=e2-medium
DISK_SIZE=20GB
INSTANCE_NAME_PREFIX=claude-router

# Application Configuration
NODE_ENV=production
PORT=3456
LOG_LEVEL=info

# Security Configuration
API_KEY_SECRET_NAME=claude-router-api-key
RATE_LIMIT_MAX=100
RATE_LIMIT_WINDOW=60000

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
  $0                           # Deploy all phases
  $0 --phase 1,2,3            # Deploy phases 1-3 only
  $0 --environment staging    # Deploy to staging environment
  $0 --cleanup                # Cleanup/rollback deployment

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
log "Access your application at: https://$(gcloud compute addresses describe ${INSTANCE_NAME}-ip --region=${REGION} --format='value(address)')"
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

### Deployment Success
- [ ] All phases complete without errors
- [ ] Application accessible via HTTPS
- [ ] Authentication working correctly
- [ ] Monitoring dashboards populated
- [ ] Health checks passing
- [ ] Security headers present
- [ ] SSL certificate valid

### Operational Success (30 days post-deployment)
- [ ] Service availability >99.5%
- [ ] Average response time <2s
- [ ] Zero security incidents
- [ ] Monitoring alerts functioning
- [ ] Successful security scans
- [ ] Cost within budget parameters

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

### Monthly Costs (USD)
- **Compute Engine** (e2-medium): ~$25
- **Load Balancer**: ~$20
- **Cloud Logging**: ~$5 (first 50GB free)
- **Cloud Monitoring**: ~$10 (basic tier)
- **Static IP**: ~$3
- **SSL Certificate**: $0 (Google-managed)

**Total Estimated Monthly Cost**: ~$63

## Risk Mitigation

### High-Priority Risks
1. **Security Breach**: Mitigated by comprehensive security hardening, regular updates, monitoring
2. **Service Downtime**: Mitigated by health checks, auto-restart, load balancer redundancy
3. **Cost Overrun**: Mitigated by monitoring alerts, resource quotas, cost budgets
4. **Performance Issues**: Mitigated by load testing, performance monitoring, auto-scaling

### Medium-Priority Risks
1. **Configuration Drift**: Mitigated by Infrastructure as Code, version control
2. **Dependency Vulnerabilities**: Mitigated by automated security scanning, update policies
3. **Compliance Issues**: Mitigated by audit logging, access controls, documentation

## Conclusion

This PRD provides a comprehensive plan for deploying the Claude Code Router to GCP Compute Engine with enterprise-grade security, monitoring, and automation. The modular, idempotent deployment scripts ensure reliable and repeatable deployments while maintaining security best practices throughout the process.

The implementation team should have expertise in:
- Google Cloud Platform services and gcloud CLI
- Docker containerization and security
- Node.js/TypeScript application development
- Linux system administration and security
- Monitoring and logging best practices

Upon successful implementation, the deployed service will provide a secure, scalable, and maintainable LLM proxy service accessible from the public internet while maintaining the highest security standards.