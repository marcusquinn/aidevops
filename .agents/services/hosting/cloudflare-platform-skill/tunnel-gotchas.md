# Tunnel Gotchas

## Security (Critical)

- Use remotely-managed tunnels for centralized control.
- Enable Cloudflare Access policies for sensitive services.
- Rotate tunnel credentials regularly; use environment variables for secrets.
- Verify TLS certs in production (`noTLSVerify: false`).
- Restrict `bastion` service type usage.

## Operations & Configuration

- **High Availability**: Run multiple replicas; place `cloudflared` close to origin.
- **Performance**: Use HTTP/2 for gRPC (`http2Origin: true`); tune `keepAliveTimeout`.
- **Validation**: Run `cloudflared tunnel ingress validate` (locally-managed only).
- **Rules**: Test with `cloudflared tunnel ingress rule <URL>` (locally-managed only).
- **Maintenance**: Keep `cloudflared` updated (1 year support); use `--no-autoupdate` in prod.
- **Monitoring**: Set up disconnect alerts in dashboard.

## Common Issues & Troubleshooting

**Error 1016 (Origin DNS Error)** — tunnel not running or connected.

```bash
cloudflared tunnel info <tunnel>     # Check status
ps aux | grep cloudflared             # Verify process
journalctl -u cloudflared -n 100      # Check logs
```

**Certificate Errors** — self-signed certs rejected by default.

```yaml
originRequest:
  noTLSVerify: true      # Dev only
  caPool: /path/to/ca.pem  # Custom CA
```

**Connection Timeouts** — origin slow to respond.

```yaml
originRequest:
  connectTimeout: 60s
  tlsTimeout: 20s
  keepAliveTimeout: 120s
```

**Tunnel Not Starting**

```bash
cloudflared tunnel ingress validate  # Validate local config
ls -la ~/.cloudflared/*.json         # Verify credentials
cloudflared tunnel list              # Verify tunnel exists
```

**Debugging**

```bash
cloudflared tunnel --loglevel debug run <tunnel>
cloudflared tunnel ingress rule https://app.example.com
```

## Limitations

- **Free tier**: Unlimited tunnels and traffic.
- **Replicas**: Max 1000 per tunnel.
- **Persistence**: Long-lived connections (WebSocket, SSH, UDP) drop during replica updates.

## Migration

**From Ngrok** (`ngrok http 8000`)

```yaml
ingress:
  - hostname: app.example.com
    service: http://localhost:8000
  - service: http_status:404
```

**From VPN** (Private Network Routing)

```yaml
warp-routing:
  enabled: true
```

```bash
cloudflared tunnel route ip add 10.0.0.0/8 <tunnel>
```

Users install WARP client instead of VPN.
