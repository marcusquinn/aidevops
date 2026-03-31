# Tunnel Gotchas

## Security (check first)

- Use remotely-managed tunnels for centralized control
- Enable Access policies for sensitive services
- Rotate tunnel credentials regularly
- Verify TLS certs (`noTLSVerify: false` in prod)
- Restrict `bastion` service type
- Use environment variables for secrets, never hardcode

## Common Issues

**Error 1016 (Origin DNS Error)** -- tunnel not running or not connected:

```bash
cloudflared tunnel info my-tunnel     # Check status
ps aux | grep cloudflared             # Verify running
journalctl -u cloudflared -n 100      # Check logs
```

**Certificate errors** -- self-signed certs rejected:

```yaml
originRequest:
  noTLSVerify: true      # Dev only
  caPool: /path/to/ca.pem  # Custom CA
```

**Connection timeouts** -- origin slow to respond:

```yaml
originRequest:
  connectTimeout: 60s
  tlsTimeout: 20s
  keepAliveTimeout: 120s
```

**Tunnel not starting**:

```bash
cloudflared tunnel ingress validate  # Validate config
ls -la ~/.cloudflared/*.json         # Verify credentials
cloudflared tunnel list              # Verify tunnel exists
```

## Debug

```bash
cloudflared tunnel --loglevel debug run my-tunnel
cloudflared tunnel ingress rule https://app.example.com
```

## Operations & Configuration

- Run multiple replicas for HA; place `cloudflared` close to origin (same network)
- Use HTTP/2 for gRPC (`http2Origin: true`); tune keepalive for long-lived connections
- Monitor tunnel health in dashboard; set up disconnect alerts
- Validate before deploying (`cloudflared tunnel ingress validate`)
- Test rules (`cloudflared tunnel ingress rule <URL>`); document rule order (first match wins)
- Version control config files; graceful shutdown for config updates
- Keep `cloudflared` updated (1 year support); use `--no-autoupdate` in prod

## Limitations

- **Free tier**: Unlimited tunnels and traffic
- **Replicas**: Max 1000 per tunnel
- **Connection duration**: No hard limit (hours to days)
- **Long-lived connections**: Drop during replica updates (WebSocket, SSH, UDP)

## Migration

**From Ngrok** (`ngrok http 8000`):

```yaml
ingress:
  - hostname: app.example.com
    service: http://localhost:8000
  - service: http_status:404
```

**From VPN** -- replace with private network routing:

```yaml
warp-routing:
  enabled: true
```

```bash
cloudflared tunnel route ip add 10.0.0.0/8 my-tunnel
```

Users install WARP client instead of VPN.
