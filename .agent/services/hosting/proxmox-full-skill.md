---
description: "Complete Proxmox VE hypervisor management via REST API - VMs, containers, snapshots, backups, storage"
mode: subagent
imported_from: clawdhub
clawdhub_slug: "proxmox-full"
clawdhub_version: "1.0.0"
---
# Proxmox VE - Full Management

Complete control over Proxmox VE hypervisor via REST API.

## Setup

```bash
export PVE_URL="https://192.168.1.10:8006"
export PVE_TOKEN="user@pam!tokenid=secret-uuid"
AUTH="Authorization: PVEAPIToken=$PVE_TOKEN"
```

## Cluster & Nodes

```bash
# Cluster status
curl -sk -H "$AUTH" "$PVE_URL/api2/json/cluster/status" | jq

# List nodes
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes" | jq '.data[] | {node, status, cpu, mem: (.mem/.maxmem*100|round)}'

# Node details
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/status" | jq
```

## List VMs & Containers

```bash
# VMs on a node
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu" | jq '.data[] | {vmid, name, status}'

# Containers on a node
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/lxc" | jq '.data[] | {vmid, name, status}'

# Cluster-wide resources
curl -sk -H "$AUTH" "$PVE_URL/api2/json/cluster/resources?type=vm" | jq '.data[] | {vmid, name, node, status, type}'
```

## VM/Container Control

```bash
# Start
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/status/start"

# Stop (immediate)
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/status/stop"

# Shutdown (graceful ACPI)
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/status/shutdown"

# Reboot
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/status/reboot"
```

Replace `qemu` with `lxc` for containers.

## Create LXC Container

```bash
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/lxc" \
  -d "vmid=200" \
  -d "hostname=mycontainer" \
  -d "ostemplate=local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst" \
  -d "storage=local-lvm" \
  -d "rootfs=local-lvm:8" \
  -d "memory=2048" \
  -d "swap=512" \
  -d "cores=2" \
  -d "net0=name=eth0,bridge=vmbr0,ip=dhcp" \
  -d "password=changeme" \
  -d "start=1" \
  -d "unprivileged=1"
```

## Create VM

```bash
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu" \
  -d "vmid=100" \
  -d "name=myvm" \
  -d "memory=4096" \
  -d "cores=4" \
  -d "sockets=1" \
  -d "cpu=host" \
  -d "net0=virtio,bridge=vmbr0" \
  -d "scsi0=local-lvm:32" \
  -d "scsihw=virtio-scsi-single" \
  -d "ide2=local:iso/debian-12.iso,media=cdrom" \
  -d "boot=order=scsi0;ide2" \
  -d "ostype=l26"
```

## Clone VM/Container

```bash
# Full clone
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/clone" \
  -d "newid=101" \
  -d "name=clone-vm" \
  -d "full=1"

# Linked clone (faster, shares base)
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/clone" \
  -d "newid=102" \
  -d "name=linked-clone" \
  -d "full=0"
```

## Convert to Template

```bash
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/template"
```

## Snapshots

```bash
# List snapshots
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/snapshot" | jq

# Create snapshot
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/snapshot" \
  -d "snapname=before-upgrade" \
  -d "description=Pre-upgrade snapshot" \
  -d "vmstate=1"

# Rollback
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/snapshot/{snapname}/rollback"

# Delete snapshot
curl -sk -X DELETE -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/snapshot/{snapname}"
```

## Backups

```bash
# Start backup
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/vzdump" \
  -d "vmid={vmid}" \
  -d "storage=local" \
  -d "mode=snapshot" \
  -d "compress=zstd"

# List backups
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/storage/local/content?content=backup" | jq

# Restore
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu" \
  -d "vmid=100" \
  -d "archive=local:backup/vzdump-qemu-100-2026_01_15.vma.zst" \
  -d "storage=local-lvm"
```

## Storage & Templates

```bash
# List storage
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/storage" | jq '.data[] | {storage, type, active, content}'

# List templates
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/storage/local/content?content=vztmpl" | jq

# List ISOs
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/storage/local/content?content=iso" | jq

# Download template
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/aplinfo" \
  -d "storage=local" \
  -d "template=debian-12-standard_12.2-1_amd64.tar.zst"
```

## Tasks

```bash
# List recent tasks
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/tasks?limit=10" | jq

# Task status
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/tasks/{upid}/status" | jq

# Task log
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/tasks/{upid}/log" | jq
```

## Delete VM/Container

```bash
# Normal delete (must be stopped)
curl -sk -X DELETE -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}"

# Force purge (removes all related data)
curl -sk -X DELETE -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}?purge=1&destroy-unreferenced-disks=1"
```

## Quick Reference

| Operation | Endpoint |
|-----------|----------|
| List nodes | `GET /nodes` |
| List VMs | `GET /nodes/{node}/qemu` |
| List LXC | `GET /nodes/{node}/lxc` |
| Create VM | `POST /nodes/{node}/qemu` |
| Create LXC | `POST /nodes/{node}/lxc` |
| Clone | `POST /nodes/{node}/qemu/{vmid}/clone` |
| Start | `POST /nodes/{node}/qemu/{vmid}/status/start` |
| Stop | `POST /nodes/{node}/qemu/{vmid}/status/stop` |
| Snapshot | `POST /nodes/{node}/qemu/{vmid}/snapshot` |
| Delete | `DELETE /nodes/{node}/qemu/{vmid}` |
| Next ID | `GET /cluster/nextid` |

## Notes

- Use `-k` flag for self-signed certificates
- API tokens don't need CSRF tokens (unlike cookie auth)
- Replace `{node}`, `{vmid}`, `{snapname}`, `{upid}` with actual values
- All create/clone operations return a task UPID for tracking
- Get next available VMID: `curl -sk -H "$AUTH" "$PVE_URL/api2/json/cluster/nextid" | jq '.data'`
