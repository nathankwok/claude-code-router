# Claude Code Router - GCP Free Tier Deployment

This directory contains deployment scripts for deploying Claude Code Router to Google Cloud Platform using only free tier resources, ensuring **$0/month** cost.

## 🎯 Overview

The deployment creates a complete, production-ready Claude Code Router service using:
- **Single e2-micro instance** (1 vCPU, 1GB RAM) - FREE
- **30GB standard persistent disk** - FREE  
- **Ephemeral external IP** - FREE
- **Caddy reverse proxy with Let's Encrypt SSL** - FREE
- **Basic monitoring and logging** - FREE (within quotas)
- **Total cost: $0/month** 💰

## 📋 Prerequisites

1. **GCP Account** with free tier available
2. **gcloud CLI** installed and configured
3. **Active GCP project** with billing enabled
4. **Required APIs** enabled (script will enable them)
5. **Docker** installed (for local builds)

### Quick Setup

```bash
# Install gcloud CLI (if not installed)
curl https://sdk.cloud.google.com | bash
exec -l $SHELL

# Authenticate and set project
gcloud auth login
gcloud config set project YOUR-PROJECT-ID

# Verify free tier eligibility
./deploy.sh --validate-free-tier
```

## 🚀 Deployment

### Quick Start (One Command)

```bash
# Deploy everything with defaults
./deploy.sh
```

### Step by Step

```bash
# 1. Validate environment and free tier compliance
./deploy.sh --phase 1

# 2. Create infrastructure (VPC, firewall, compute instance)
./deploy.sh --phase 2

# 3. Configure security (SSL, authentication, firewall)
./deploy.sh --phase 3

# 4. Deploy application
./deploy.sh --phase 4

# 5. Setup monitoring and logging
./deploy.sh --phase 5

# 6. Run health checks
./deploy.sh --phase 6
```

### Environment-Specific Deployment

```bash
# Deploy to staging
./deploy.sh --environment staging

# Deploy to development
./deploy.sh --environment development
```

## 📁 File Structure

```
.
├── deploy.sh                 # Main deployment orchestrator
├── scripts/
│   ├── 01-predeploy.sh      # Environment validation & free tier compliance
│   ├── 02-infrastructure.sh # GCP infrastructure creation
│   ├── 03-security.sh       # Security setup & SSL configuration
│   ├── 04-application.sh    # Application build & deployment
│   ├── 05-monitoring.sh     # Monitoring & logging setup
│   ├── 06-healthcheck.sh    # Comprehensive health validation
│   └── cleanup.sh           # Complete resource cleanup
├── config/
│   ├── production.env       # Production environment configuration
│   ├── staging.env          # Staging environment configuration
│   └── development.env      # Development environment configuration
└── README-deployment.md     # This file
```

## ⚙️ Configuration

### Environment Files

Edit the appropriate configuration file before deployment:

```bash
# Production deployment
cp config/production.env config/production.env.local
nano config/production.env

# Required changes:
PROJECT_ID=your-actual-project-id
NOTIFICATION_EMAIL=your-email@example.com  # Optional
```

### Key Configuration Options

| Setting | Description | Default | Free Tier Limit |
|---------|-------------|---------|-----------------|
| `MACHINE_TYPE` | Instance type | `e2-micro` | **Must be e2-micro** |
| `DISK_SIZE` | Boot disk size | `30GB` | **Max 30GB** |
| `REGION` | GCP region | `us-central1` | **us-central1, us-east1, us-west1 only** |
| `RATE_LIMIT_MAX` | Requests/minute | `30` | Optimized for e2-micro |
| `MAX_CONNECTIONS` | Concurrent connections | `50` | Memory-optimized |

## 🔧 Phase Details

### Phase 1: Pre-deployment Validation
- ✅ Validates gcloud CLI and authentication
- ✅ Checks free tier eligibility and quotas
- ✅ Verifies no existing e2-micro instances
- ✅ Confirms disk usage under 30GB limit
- ✅ Enables required GCP APIs
- ✅ Sets up budget alerts

### Phase 2: Infrastructure
- 🏗️ Creates VPC network and subnet
- 🔥 Configures firewall rules (HTTP/HTTPS/SSH)
- 💻 Deploys e2-micro compute instance
- 🔑 Creates service account with minimal permissions
- 📦 Installs base system packages and Node.js

### Phase 3: Security
- 🔐 Generates and stores API keys in Secret Manager
- 🌐 Configures Caddy reverse proxy with Let's Encrypt
- 🛡️ Sets up security headers and basic firewall
- 🚫 Configures fail2ban for SSH protection
- 👤 Creates application user with restricted permissions

### Phase 4: Application
- 📦 Builds application locally with memory constraints
- 📤 Uploads to instance and installs dependencies
- ⚙️ Configures systemd services for auto-restart
- 🚀 Starts Caddy and Claude Router services
- ✅ Verifies application startup and basic functionality

### Phase 5: Monitoring
- 📊 Installs Cloud Logging and Monitoring agents
- 📈 Creates basic dashboard and uptime checks
- 🚨 Sets up essential alert policies
- 📝 Configures log rotation for free tier limits
- 💰 Implements cost monitoring and alerts

### Phase 6: Health Check
- 🏥 Comprehensive service status validation
- 🌐 Tests HTTP/HTTPS access and redirects
- 🔐 Validates API authentication and rate limiting
- 📊 Checks monitoring agent functionality
- 📈 Performs basic load testing
- 📋 Generates detailed health report

## 🎛️ Usage Examples

### Basic Deployment Commands

```bash
# Full deployment with all phases
./deploy.sh

# Deploy specific phases only
./deploy.sh --phase 1,2,3

# Deploy to different environment
./deploy.sh --environment staging

# Dry run to see what would be deployed
./deploy.sh --validate-free-tier

# Verbose output for troubleshooting
./deploy.sh --verbose
```

### Cleanup Commands

```bash
# Interactive cleanup (asks for confirmation)
./scripts/cleanup.sh

# Force cleanup without confirmation
./scripts/cleanup.sh --force

# See what would be deleted without deleting
./scripts/cleanup.sh --dry-run

# Cleanup specific environment
./scripts/cleanup.sh --environment staging
```

### Health Check Commands

```bash
# Run comprehensive health check
./scripts/06-healthcheck.sh

# Skip load testing (for minimal resource usage)
./scripts/06-healthcheck.sh --skip-load-test

# Check specific environment
./scripts/06-healthcheck.sh --environment staging
```

## 🌐 Accessing Your Deployment

After successful deployment, you'll get:

```bash
✅ Deployment completed successfully!
🌐 Access URL: https://YOUR-EXTERNAL-IP
🔑 API Key: your-generated-api-key
📊 Monitor usage: https://console.cloud.google.com/billing
💰 Remember: This deployment costs $0/month (free tier)
```

### Making API Requests

```bash
# Health check
curl -H "X-API-Key: YOUR-API-KEY" https://YOUR-EXTERNAL-IP/health

# Route to an LLM (configure providers first)
curl -H "X-API-Key: YOUR-API-KEY" \
     -H "Content-Type: application/json" \
     -d '{"model": "claude-3-sonnet", "messages": [{"role": "user", "content": "Hello!"}]}' \
     https://YOUR-EXTERNAL-IP/v1/messages
```

## 🚨 Troubleshooting

### Common Issues

#### 1. Free Tier Quota Exceeded
```bash
❌ Error: Would exceed free tier disk limit (30GB)
```
**Solution**: Check existing disk usage and cleanup unused resources
```bash
gcloud compute disks list --format="table(name,sizeGb,zone)"
```

#### 2. SSL Certificate Not Ready
```bash
⚠️ HTTPS not ready yet (certificate may still be provisioning)
```
**Solution**: Wait 5-15 minutes for Let's Encrypt certificate provisioning

#### 3. Instance Out of Memory
```bash
⚠️ High memory usage detected (>90%)
```
**Solution**: This is normal for e2-micro. Monitor and restart if needed:
```bash
gcloud compute instances reset INSTANCE-NAME --zone=ZONE
```

#### 4. API Authentication Fails
```bash
❌ Request without API key not properly rejected
```
**Solution**: Check Secret Manager and restart services:
```bash
./scripts/04-application.sh --environment production
```

### Logs and Monitoring

```bash
# View application logs
gcloud compute ssh INSTANCE-NAME --zone=ZONE --command="sudo journalctl -u claude-router -f"

# View Caddy logs
gcloud compute ssh INSTANCE-NAME --zone=ZONE --command="sudo journalctl -u caddy -f"

# Check service status
gcloud compute ssh INSTANCE-NAME --zone=ZONE --command="sudo systemctl status claude-router caddy"

# Monitor resource usage
gcloud compute ssh INSTANCE-NAME --zone=ZONE --command="htop"
```

### Emergency Procedures

#### Complete Reset
```bash
# Clean up everything and redeploy
./scripts/cleanup.sh --force
./deploy.sh
```

#### Instance Recovery
```bash
# If instance becomes unresponsive
gcloud compute instances reset INSTANCE-NAME --zone=ZONE

# Re-run application deployment
./scripts/04-application.sh
```

## 💰 Cost Monitoring

### Verify Free Tier Usage

1. **Billing Console**: https://console.cloud.google.com/billing
2. **Compute Engine**: Check for single e2-micro instance
3. **Persistent Disks**: Verify ≤30GB standard disks
4. **Static IPs**: Should be 0 (using ephemeral)

### Budget Alerts

The deployment automatically creates budget alerts at:
- 50% of $1 ($0.50)
- 90% of $1 ($0.90)  
- 100% of $1 ($1.00)

### Monthly Free Tier Allowances

| Resource | Free Tier Limit | Usage |
|----------|-----------------|-------|
| e2-micro instance | 1 instance | ✅ 1 instance |
| Standard persistent disk | 30GB | ✅ 30GB |
| Egress traffic | 1GB/month | ✅ Minimal |
| Cloud Logging | 50GB/month | ✅ <1GB |
| Cloud Monitoring | Basic tier | ✅ Basic |

## 🛡️ Security Considerations

### Built-in Security Features

- 🔐 **API Key Authentication**: All requests require valid API key
- 🌐 **HTTPS Only**: Automatic HTTP→HTTPS redirect
- 🛡️ **Security Headers**: HSTS, CSP, XSS protection
- 🚫 **Rate Limiting**: 30 requests/minute per IP
- 🔥 **Firewall**: Only HTTP/HTTPS/SSH ports open
- 👤 **Non-root Execution**: Application runs as restricted user
- 🚫 **fail2ban**: SSH brute force protection

### Security Best Practices

1. **Rotate API Keys Regularly**
```bash
# Generate new API key
openssl rand -hex 32
# Update in Secret Manager
gcloud secrets versions add claude-router-api-key --data-file=new-key.txt
# Restart services
./scripts/04-application.sh
```

2. **Monitor Access Logs**
```bash
# Check access patterns
gcloud logging read "resource.type=gce_instance AND jsonPayload.service=claude-router" --limit=50
```

3. **Keep System Updated**
```bash
# SSH to instance and update
gcloud compute ssh INSTANCE-NAME --zone=ZONE --command="sudo apt update && sudo apt upgrade -y"
```

## 📈 Scaling Considerations

### Free Tier Limitations

This deployment is intentionally limited to free tier resources:

- **Single Instance**: No load balancer or auto-scaling
- **Memory**: 1GB RAM limits concurrent requests
- **CPU**: 1 vCPU limits processing power
- **Network**: No premium network tier

### Upgrade Path

To scale beyond free tier:

1. **Machine Type**: Upgrade to e2-small or e2-medium
2. **Load Balancer**: Add Cloud Load Balancer
3. **Static IP**: Reserve static external IP
4. **Auto-scaling**: Implement managed instance groups
5. **Premium Network**: Use premium network tier

**⚠️ Warning**: Any upgrades will incur charges!

## 🤝 Contributing

To improve the deployment scripts:

1. Test changes in development environment
2. Ensure free tier compliance
3. Update documentation
4. Test cleanup procedures

## 📝 License

Same as Claude Code Router project license.

---

## 🎉 Success!

Your Claude Code Router is now deployed on GCP's free tier with:

- ✅ **$0/month cost**
- ✅ **HTTPS with automatic SSL**
- ✅ **API authentication** 
- ✅ **Basic monitoring**
- ✅ **Auto-restart capabilities**
- ✅ **Security hardening**

**Happy routing!** 🚀