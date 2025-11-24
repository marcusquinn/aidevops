# Web Hosting Helper

The Web Hosting Helper provides seamless local domain management for web applications in your `~/Git` directory, with automatic framework detection and SSL certificate generation.

## 🚀 Features

- **Automatic Framework Detection**: Supports Next.js, React, Vue, Nuxt, Vite, Svelte, Rails, Python, Go, PHP
- **SSL Certificate Generation**: Automatic HTTPS setup with self-signed certificates
- **LocalWP Integration**: Works seamlessly with LocalWP's nginx router
- **Hot Reload Support**: Framework-specific WebSocket configurations
- **Port Management**: Automatic port detection with override options

## 📋 Prerequisites

### Required
- **LocalWP** (recommended) or standalone nginx
- **OpenSSL** for certificate generation
- **sudo access** for hosts file modification

### Optional
- **LocalWP** for WordPress development integration

## 🛠️ Setup

1. **Copy configuration file**:
   ```bash
   cp configs/webhosting-config.json.txt configs/webhosting-config.json
   ```

2. **Make script executable**:
   ```bash
   chmod +x providers/webhosting-helper.sh
   ```

## 📖 Usage

### Setup a New Local Domain

```bash
# Auto-detect framework and port
./providers/webhosting-helper.sh setup myapp

# Specify custom port
./providers/webhosting-helper.sh setup myapp 3001

# Examples for different frameworks
./providers/webhosting-helper.sh setup nextjs-app 3000
./providers/webhosting-helper.sh setup vue-project 3000
./providers/webhosting-helper.sh setup svelte-app 5173
./providers/webhosting-helper.sh setup django-api 8000
```

### List Configured Domains

```bash
./providers/webhosting-helper.sh list
```

Output example:
```
🌐 https://myapp.local → Port 3000 ✅ Running
🌐 https://api-server.local → Port 8000 ❌ Not running
```

### Remove a Domain

```bash
./providers/webhosting-helper.sh remove myapp
```

## 🔧 Framework Support

| Framework | Default Port | WebSocket Support | Auto-Detection |
|-----------|--------------|-------------------|----------------|
| Next.js   | 3000         | ✅ HMR            | ✅             |
| React     | 3000         | ✅ HMR            | ✅             |
| Vue       | 3000         | ✅ HMR            | ✅             |
| Nuxt      | 3000         | ✅ HMR            | ✅             |
| Vite      | 5173         | ✅ HMR            | ✅             |
| Svelte    | 5173         | ✅ HMR            | ✅             |
| Rails     | 3000         | ❌                | ✅             |
| Python    | 8000         | ❌                | ✅             |
| Go        | 8080         | ❌                | ✅             |
| PHP       | 8000         | ❌                | ✅             |

## 🔐 SSL Configuration

The helper automatically generates self-signed SSL certificates for each domain:

- **Certificate Location**: `~/.localhost-setup/certs/`
- **Validity**: 365 days
- **Key Size**: 2048 bits RSA
- **Protocols**: TLSv1.2, TLSv1.3

### Browser Certificate Warnings

When first accessing a domain, browsers will show a security warning for self-signed certificates:

1. **Chrome/Safari**: Click "Advanced" → "Proceed to [domain] (unsafe)"
2. **Firefox**: Click "Advanced" → "Accept the Risk and Continue"

## 🌐 LocalWP Integration

The helper integrates seamlessly with LocalWP's nginx router:

- **Automatic Detection**: Checks for LocalWP installation
- **Router Integration**: Uses existing nginx configuration
- **No Conflicts**: Works alongside WordPress sites
- **Hot Reload**: Preserves development server features

## 📁 Directory Structure

```
~/.localhost-setup/
├── certs/
│   ├── myapp.local.crt
│   ├── myapp.local.key
│   └── ...

~/Library/Application Support/Local/run/router/nginx/conf/
├── route.myapp.local.conf
├── route.api-server.local.conf
└── ...

/etc/hosts
# Contains domain mappings
127.0.0.1 myapp.local
127.0.0.1 api-server.local
```

## 🤖 AI Agent Instructions

### Complete Setup Process

When setting up a local domain for an AI agent, follow these exact steps:

1. **Run the setup command**:
   ```bash
   ./providers/webhosting-helper.sh setup PROJECT_NAME PORT
   ```

2. **⚠️ CRITICAL: Add domain to hosts file**:
   The setup will create nginx config and SSL certificates, but **CANNOT** automatically add the domain to `/etc/hosts` due to sudo requirements.

   **You MUST run this command in a separate terminal session:**
   ```bash
   echo "127.0.0.1 PROJECT_NAME.local" | sudo tee -a /etc/hosts
   ```

   **Replace `PROJECT_NAME` with the actual project name.**

3. **Start the development server**:
   ```bash
   cd ~/Git/PROJECT_NAME
   # Use the appropriate command for the framework:
   PORT=PORT_NUMBER npm run dev    # or pnpm dev, yarn dev
   ```

4. **Test the setup**:
   Visit `https://PROJECT_NAME.local` in browser

5. **Handle SSL Certificate Warning**:
   The browser will show this security warning:
   ```
   Your connection is not private
   Attackers might be trying to steal your information from PROJECT_NAME.local
   (for example, passwords, messages or credit cards).
   net::ERR_CERT_AUTHORITY_INVALID
   This server could not prove that it is PROJECT_NAME.local; its security
   certificate is not trusted by your computer's operating system.
   ```

   **Action Required**: Click **"Proceed to PROJECT_NAME.local (unsafe)"** button to continue.

6. **Verify Success**:
   - HTTP redirect: `http://PROJECT_NAME.local` → redirects to HTTPS
   - HTTPS access: `https://PROJECT_NAME.local` → shows the application
   - Development features: Hot reload should work properly

### Example Complete Workflow

```bash
# 1. Setup domain
./providers/webhosting-helper.sh setup myapp 3000

# 2. Add to hosts file (REQUIRED - run in separate terminal)
echo "127.0.0.1 myapp.local" | sudo tee -a /etc/hosts

# 3. Start development server
cd ~/Git/myapp
PORT=3000 npm run dev

# 4. Visit https://myapp.local and click "Proceed" on SSL warning
```

## 🔍 Troubleshooting

### Domain Not Resolving ("This site can't be reached")
**Cause**: Domain not in hosts file
**Solution**:
```bash
echo "127.0.0.1 PROJECT_NAME.local" | sudo tee -a /etc/hosts
```

### LocalWP Not Found
```bash
# Install LocalWP
open https://localwp.com/

# Or use standalone nginx (manual setup required)
```

### Port Already in Use
```bash
# Check what's using the port
lsof -i :3000

# Use a different port
./providers/webhosting-helper.sh setup myapp 3001
```

### SSL Certificate Issues
```bash
# Regenerate certificates
rm ~/.localhost-setup/certs/myapp.local.*
./providers/webhosting-helper.sh setup myapp
```

### Build Errors (Framework-Specific)
For frameworks that require build steps:
```bash
# Generate required files first
cd ~/Git/PROJECT_NAME
pnpm build  # or npm run build

# Then start development server
PORT=PORT_NUMBER pnpm dev
```

## 🔄 Workflow Example

1. **Create a new project**:
   ```bash
   cd ~/Git
   npx create-next-app@latest myapp
   cd myapp
   ```

2. **Setup local domain**:
   ```bash
   cd ~/Git/aidevops
   ./providers/webhosting-helper.sh setup myapp
   ```

3. **Start development server**:
   ```bash
   cd ~/Git/myapp
   npm run dev
   ```

4. **Access via HTTPS**:
   ```
   https://myapp.local
   ```

## 📚 Related Documentation

- [LocalWP Integration](LOCALHOST.md)
- [SSL Certificate Management](SECURITY.md)
- [Nginx Configuration](../configs/webhosting-config.json.txt)
