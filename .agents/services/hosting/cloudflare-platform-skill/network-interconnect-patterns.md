<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# CNI Patterns

See [README.md](./README.md) for overview.

## High Availability

Design for resilience from day one. Requirements: device-level diversity, backup Internet (no SLA on CNI), network-resilient locations, regular failover testing.

```text
Your Network A ──10G CNI v2──> CF CCR Device 1
                                     │
Your Network B ──10G CNI v2──> CF CCR Device 2
                                     │
                            CF Global Network (AS13335)
```

Capacity planning: plan across all links, account for failover scenarios.

## Pattern: Magic Transit + CNI v2

DDoS protection + private connectivity without GRE overhead.

```typescript
// 1. Create interconnect
const ic = await client.networkInterconnects.interconnects.create({
  account_id: id,
  type: 'direct',
  facility: 'EWR1',
  speed: '10G',
  name: 'magic-transit-primary',
});

// 2. Poll until active
const status = await pollUntilActive(id, ic.id);

// 3. Configure Magic Transit tunnel via Dashboard/API
```

**Benefits:** 1500 MTU both ways, simplified routing.

## Pattern: Multi-Cloud Hybrid

AWS/GCP workloads with Cloudflare.

**AWS Direct Connect:**

```typescript
// 1. Order Direct Connect in AWS Console
// 2. Get LOA + VLAN from AWS
// 3. Send to CF account team (no API)
// 4. Configure static routes in Magic WAN

await configureStaticRoutes(id, {
  prefix: '10.0.0.0/8',
  nexthop: 'aws-direct-connect',
});
```

**GCP Cloud Interconnect:**

```typescript
// 1. Get VLAN pairing key from GCP
// 2. Create via Dashboard (no SDK yet)
// 3. Configure static routes in Magic WAN
// 4. Configure BGP in GCP Cloud Router

const ic = await client.networkInterconnects.interconnects.create({
  account_id: id,
  type: 'cloud',
  cloud_provider: 'gcp',
  pairing_key: 'gcp_key',
  name: 'gcp-interconnect',
});
```

## Pattern: Multi-Location HA

99.99%+ uptime via geographic diversity.

```typescript
// Primary (NY)
const primary = await client.networkInterconnects.interconnects.create({
  account_id: id,
  type: 'direct',
  facility: 'EWR1',
  speed: '10G',
  name: 'primary-ewr1',
});

// Secondary (NY, different hardware)
const secondary = await client.networkInterconnects.interconnects.create({
  account_id: id,
  type: 'direct',
  facility: 'EWR2',
  speed: '10G',
  name: 'secondary-ewr2',
});

// Tertiary (LA, different geography)
const tertiary = await client.networkInterconnects.interconnects.create({
  account_id: id,
  type: 'partner',
  facility: 'LAX1',
  speed: '10G',
  name: 'tertiary-lax1',
});

// BGP local preferences:
// Primary: 200
// Secondary: 150
// Tertiary: 100
// Internet: Last resort
```

## Pattern: Partner Interconnect (Equinix)

Quick deployment without colocation. Setup: order virtual circuit in Equinix Fabric Portal → select Cloudflare → choose facility → send details to CF account team → CF accepts → configure BGP. No API automation (partner portals managed separately).

## Failover & Security

**Failover:** BGP local preferences for priority, BFD for fast detection (v1), regular traffic-shift testing, documented runbooks.

**Security:** BGP password auth + route filtering, monitor unexpected routes, Magic Firewall for DDoS/threats, minimum API token permissions, rotate credentials.

## Decision Matrix

| Requirement | Recommended |
|-------------|-------------|
| Collocated with CF | Direct |
| Not collocated | Partner |
| AWS/GCP workloads | Cloud |
| 1500 MTU both ways | v2 |
| VLAN tagging | v1 |
| Public peering | v1 |
| Simplest config | v2 |
| BFD fast failover | v1 |
| LACP bundling | v1 |

## Resources

[Magic Transit](https://developers.cloudflare.com/magic-transit/) · [Magic WAN](https://developers.cloudflare.com/magic-wan/) · [Argo Smart Routing](https://developers.cloudflare.com/argo/)
