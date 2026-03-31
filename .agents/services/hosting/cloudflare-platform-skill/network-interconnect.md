# Cloudflare Network Interconnect (CNI)

Private, high-performance connectivity to Cloudflare's network. **Enterprise-only**.

## Connection Model

| Type | Best for | Notes |
|------|----------|-------|
| **Direct** | Physical presence in a shared datacenter | Physical fiber, 10/100 Gbps, you order the cross-connect |
| **Partner** | Faster virtual handoff | Via Console Connect, Equinix, Megaport, or similar partner SDN |
| **Cloud** | AWS Direct Connect or GCP Cloud Interconnect | Magic WAN only |

## Dataplane Choice

| Version | Use when | Trade-offs |
|---------|----------|------------|
| **v1 (Classic)** | You need GRE, VLAN, BFD, LACP, or peering | Asymmetric MTU (1500↓/1476↑) |
| **v2 (Beta)** | You want native 1500-byte MTU and simpler routing | No GRE, VLAN, BFD, or LACP yet; uses ECMP |

## Supported Fits

- **Magic Transit DSR**: DDoS protection, egress via ISP (v1/v2)
- **Magic Transit + Egress**: DDoS protection plus egress via Cloudflare (v1/v2)
- **Magic WAN + Zero Trust**: Private backbone; v1 needs GRE, v2 is native
- **Peering**: Public routes at a PoP (v1 only)
- **App Security**: WAF, Cache, or Load Balancing over Magic Transit (v1/v2)

## Requirements & Physical Limits

- Enterprise plan
- IPv4 /24+ or IPv6 /48+ prefixes
- BGP ASN for v1
- /31 point-to-point subnets
- 10 km max optical distance
- 10G requires 10GBASE-LR single-mode optics
- 100G requires 100GBASE-LR4 single-mode optics
- **No SLA**; keep backup Internet connectivity
- Location availability: [locations PDF](https://developers.cloudflare.com/network-interconnect/static/cni-locations-30-10-2025.pdf)

## Throughput

| Direction | 10G | 100G |
|-----------|-----|------|
| CF → Customer | 10 Gbps | 100 Gbps |
| Customer → CF (peering) | 10 Gbps | 100 Gbps |
| Customer → CF (Magic) | 1 Gbps per tunnel or CNI | 1 Gbps per tunnel or CNI |

## Delivery Timeline

Typical lead time is **2-4 weeks**: request → config review → order connection → configure → test → enable health checks → activate → monitor.

## See Also

- [network-interconnect-patterns.md](./network-interconnect-patterns.md) - HA, hybrid cloud, failover
- [network-interconnect-gotchas.md](./network-interconnect-gotchas.md) - Troubleshooting, limits
