# Cloudflare Network Interconnect (CNI)

Private, high-performance connectivity to Cloudflare's network. **Enterprise-only** and **not SLA-backed**, so keep backup Internet connectivity.

## Quick Choices

### Connection type

| Type | Use when | Notes |
|------|----------|-------|
| **Direct** | You share a datacenter with Cloudflare | Physical fiber cross-connect, 10/100 Gbps |
| **Partner** | You want a faster virtual handoff | Via Console Connect, Equinix, Megaport, or similar SDN partner |
| **Cloud** | You connect from AWS Direct Connect or GCP Cloud Interconnect | Magic WAN only |

### Dataplane version

| Version | Prefer when | Limits |
|---------|-------------|--------|
| **v1 (Classic)** | You need GRE, VLAN, BFD, LACP, or peering | Asymmetric MTU (1500↓/1476↑) |
| **v2 (Beta)** | You want native 1500-byte MTU and simpler routing | No GRE, VLAN, BFD, or LACP; uses ECMP |

Default to **v2** unless you need a v1-only feature.

## Supported deployments

- **Magic Transit DSR**: DDoS protection, egress via ISP (v1/v2)
- **Magic Transit + Egress**: DDoS protection plus egress via Cloudflare (v1/v2)
- **Magic WAN + Zero Trust**: Private backbone; v1 needs GRE, v2 is native
- **Peering**: Public routes at a PoP (v1 only)
- **App Security**: WAF, Cache, or Load Balancing over Magic Transit (v1/v2)

## Requirements and limits

- Enterprise plan
- IPv4 /24+ or IPv6 /48+ prefixes
- BGP ASN for v1
- /31 point-to-point subnets
- 10 km max optical distance
- 10G requires 10GBASE-LR single-mode optics
- 100G requires 100GBASE-LR4 single-mode optics
- Location availability: [locations PDF](https://developers.cloudflare.com/network-interconnect/static/cni-locations-30-10-2025.pdf)

## Throughput

| Direction | 10G | 100G |
|-----------|-----|------|
| CF → Customer | 10 Gbps | 100 Gbps |
| Customer → CF (peering) | 10 Gbps | 100 Gbps |
| Customer → CF (Magic) | 1 Gbps per tunnel or CNI | 1 Gbps per tunnel or CNI |

## Delivery timeline

Typical lead time is **2-4 weeks**: request → config review → order connection → configure → test → enable health checks → activate → monitor.

## See also

- [network-interconnect-patterns.md](./network-interconnect-patterns.md) - HA, hybrid cloud, failover
- [network-interconnect-gotchas.md](./network-interconnect-gotchas.md) - Troubleshooting, limits
