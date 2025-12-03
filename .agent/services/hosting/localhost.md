# Localhost Development Environment Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Local development environment management
- **Config**: `configs/localhost-config.json`
- **Commands**: `localhost-helper.sh [environments|start|stop|status|localwp-sites|start-site|stop-site|generate-ssl|list-ports|check-port|kill-port|start-mcp] [env] [args]`
- **LocalWP**: Sites in `/Users/username/Local Sites`, MCP on port 3001
- **SSL**: `generate-ssl`, `install-ssl`, `trust-cert` for local HTTPS
- **Ports**: `list-ports`, `check-port`, `kill-port`, `forward-port`
- **Docker**: `docker-up`, `docker-down`, `docker-logs`, `docker-exec`
- **MCP query**: `mcp-query "SELECT * FROM wp_posts LIMIT 5"`
<!-- AI-CONTEXT-END -->

Localhost development provides local development capabilities with .local domain support, perfect for development workflows and testing environments.

## Provider Overview

### **Localhost Characteristics:**

- **Service Type**: Local development environment management
- **Domain Support**: .local domain resolution and management
- **Development Tools**: Integration with local development stacks
- **SSL Support**: Local SSL certificate management
- **Port Management**: Local port allocation and management
- **Service Discovery**: Local service discovery and routing

### **Best Use Cases:**

- **Local WordPress development** with LocalWP integration
- **Microservices development** with local service discovery
- **API development and testing** with local endpoints
- **Frontend development** with local backend services
- **SSL testing** with local certificate management
- **Development environment isolation** and management

## 🔧 **Configuration**

### **Setup Configuration:**

```bash
# Copy template
cp configs/localhost-config.json.txt configs/localhost-config.json

# Edit with your local development setup
```

### **Configuration Structure:**

```json
{
  "environments": {
    "wordpress": {
      "type": "localwp",
      "sites_path": "/Users/username/Local Sites",
      "description": "LocalWP WordPress development",
      "mcp_enabled": true,
      "mcp_port": 3001
    },
    "nodejs": {
      "type": "nodejs",
      "projects_path": "/Users/username/Projects",
      "description": "Node.js development projects",
      "default_port": 3000
    },
    "docker": {
      "type": "docker",
      "compose_path": "/Users/username/Docker",
      "description": "Docker development environments",
      "network": "dev-network"
    }
  }
}
```

### **Local Domain Setup:**

1. **Configure local DNS** resolution for .local domains
2. **Set up SSL certificates** for HTTPS development
3. **Configure port forwarding** for service access
4. **Set up service discovery** for microservices
5. **Test local domain** resolution

## 🚀 **Usage Examples**

### **Basic Commands:**

```bash
# List local environments
./.agent/scripts/localhost-helper.sh environments

# Start local environment
./.agent/scripts/localhost-helper.sh start wordpress

# Stop local environment
./.agent/scripts/localhost-helper.sh stop wordpress

# Get environment status
./.agent/scripts/localhost-helper.sh status wordpress
```

### **LocalWP Integration:**

```bash
# List LocalWP sites
./.agent/scripts/localhost-helper.sh localwp-sites

# Start LocalWP site
./.agent/scripts/localhost-helper.sh start-site mysite.local

# Stop LocalWP site
./.agent/scripts/localhost-helper.sh stop-site mysite.local

# Get site info
./.agent/scripts/localhost-helper.sh site-info mysite.local

# Start MCP server for LocalWP
./.agent/scripts/localhost-helper.sh start-mcp
```

### **SSL Management:**

```bash
# Generate local SSL certificate
./.agent/scripts/localhost-helper.sh generate-ssl mysite.local

# Install SSL certificate
./.agent/scripts/localhost-helper.sh install-ssl mysite.local

# List SSL certificates
./.agent/scripts/localhost-helper.sh list-ssl

# Renew SSL certificate
./.agent/scripts/localhost-helper.sh renew-ssl mysite.local
```

### **Port Management:**

```bash
# List active ports
./.agent/scripts/localhost-helper.sh list-ports

# Check port availability
./.agent/scripts/localhost-helper.sh check-port 3000

# Kill process on port
./.agent/scripts/localhost-helper.sh kill-port 3000

# Forward port
./.agent/scripts/localhost-helper.sh forward-port 3000 8080
```

## 🛡️ **Security Best Practices**

### **Local Development Security:**

- **Isolated environments**: Keep development environments isolated
- **SSL certificates**: Use valid SSL certificates for HTTPS testing
- **Access control**: Limit access to development services
- **Data protection**: Protect sensitive development data
- **Network isolation**: Use isolated networks for development

### **SSL Certificate Management:**

```bash
# Generate development CA
./.agent/scripts/localhost-helper.sh generate-ca

# Create site certificate
./.agent/scripts/localhost-helper.sh create-cert mysite.local

# Trust certificate in system
./.agent/scripts/localhost-helper.sh trust-cert mysite.local

# Verify certificate
./.agent/scripts/localhost-helper.sh verify-cert mysite.local
```

## 🔍 **Troubleshooting**

### **Common Issues:**

#### **Domain Resolution Issues:**

```bash
# Check DNS resolution
nslookup mysite.local
dig mysite.local

# Verify hosts file
cat /etc/hosts | grep mysite.local

# Test local connectivity
ping mysite.local
```

#### **SSL Certificate Issues:**

```bash
# Check certificate validity
openssl x509 -in cert.pem -text -noout

# Verify certificate chain
./.agent/scripts/localhost-helper.sh verify-chain mysite.local

# Regenerate certificate
./.agent/scripts/localhost-helper.sh regenerate-ssl mysite.local
```

#### **Port Conflicts:**

```bash
# Find process using port
lsof -i :3000
netstat -tulpn | grep :3000

# Kill conflicting process
./.agent/scripts/localhost-helper.sh kill-port 3000

# Use alternative port
./.agent/scripts/localhost-helper.sh start-on-port mysite.local 3001
```

## 📊 **Development Workflow**

### **Environment Management:**

```bash
# Start development stack
./.agent/scripts/localhost-helper.sh start-stack development

# Stop development stack
./.agent/scripts/localhost-helper.sh stop-stack development

# Restart services
./.agent/scripts/localhost-helper.sh restart-services

# Check service health
./.agent/scripts/localhost-helper.sh health-check
```

### **Project Management:**

```bash
# Create new project
./.agent/scripts/localhost-helper.sh create-project myproject

# Clone project template
./.agent/scripts/localhost-helper.sh clone-template react-app myproject

# Set up project environment
./.agent/scripts/localhost-helper.sh setup-env myproject

# Start project services
./.agent/scripts/localhost-helper.sh start-project myproject
```

## 🔄 **Integration & Automation**

### **LocalWP MCP Integration:**

```bash
# Start LocalWP MCP server
./.agent/scripts/localhost-helper.sh start-mcp

# Test MCP connection
./.agent/scripts/localhost-helper.sh test-mcp

# Query WordPress database via MCP
./.agent/scripts/localhost-helper.sh mcp-query "SELECT * FROM wp_posts LIMIT 5"

# Stop MCP server
./.agent/scripts/localhost-helper.sh stop-mcp
```

### **Docker Integration:**

```bash
# Start Docker development environment
./.agent/scripts/localhost-helper.sh docker-up myproject

# Stop Docker environment
./.agent/scripts/localhost-helper.sh docker-down myproject

# View Docker logs
./.agent/scripts/localhost-helper.sh docker-logs myproject

# Execute command in container
./.agent/scripts/localhost-helper.sh docker-exec myproject "npm test"
```

## 📚 **Best Practices**

### **Development Environment:**

1. **Consistent setup**: Use consistent development environments across team
2. **Version control**: Version control development configurations
3. **Documentation**: Document local setup procedures
4. **Automation**: Automate environment setup and teardown
5. **Testing**: Test applications in production-like environments

### **Local Domain Management:**

- **Naming conventions**: Use consistent naming for local domains
- **SSL everywhere**: Use SSL for all local development
- **Service discovery**: Implement service discovery for microservices
- **Port management**: Manage port allocation systematically
- **Environment isolation**: Isolate different project environments

### **Security Practices:**

- **Certificate management**: Properly manage local SSL certificates
- **Access control**: Limit access to development services
- **Data handling**: Handle sensitive data appropriately in development
- **Network security**: Secure local development networks
- **Regular cleanup**: Regularly clean up unused environments

## 🎯 **AI Assistant Integration**

### **Automated Development:**

- **Environment provisioning**: Automated development environment setup
- **Service orchestration**: Automated service startup and management
- **SSL management**: Automated SSL certificate generation and renewal
- **Port management**: Automated port allocation and conflict resolution
- **Health monitoring**: Automated health checks for development services

### **Development Assistance:**

- **Project scaffolding**: Automated project template generation
- **Dependency management**: Automated dependency installation and updates
- **Testing automation**: Automated test execution and reporting
- **Code quality**: Automated code quality checks and formatting
- **Documentation**: Automated documentation generation and updates

---

**Localhost development environment provides comprehensive local development capabilities with excellent integration options for modern development workflows.** 🚀
