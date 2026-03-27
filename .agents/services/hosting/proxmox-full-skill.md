---
name: proxmox-full
description: "Complete Proxmox VE hypervisor management via REST API - VMs, containers, snapshots, backups, storage"
mode: subagent
imported_from: clawdhub
clawdhub_slug: "proxmox-full"
clawdhub_version: "1.0.0"
---
# Proxmox VE - Full Management

Complete control over Proxmox VE hypervisor via REST API. Use `-k` for self-signed certs. API tokens don't need CSRF tokens (unlike cookie auth). All create/clone ops return a task UPID for tracking. Replace `{node}`, `{vmid}`, `{snapname}`, `{upid}` with actual values. Replace `qemu` with `lxc` for container equivalents.

## Setup

```bash
export PVE_URL="https://192.168.1.10:8006"
export PVE_TOKEN="user@pam!tokenid=secret-uuid"
AUTH="Authorization: PVEAPIToken=$PVE_TOKEN"
```

API tokens don't need CSRF tokens (unlike cookie auth). Use `-k` for self-signed certs.

## Cluster & Nodes

```bash
curl -sk -H "$AUTH" "$PVE_URL/api2/json/cluster/status" | jq                    # Cluster status
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes" | jq '.data[] | {node, status, cpu, mem: (.mem/.maxmem*100|round)}'  # List nodes
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/status" | jq               # Node details
```

## List VMs & Containers

```bash
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu" | jq '.data[] | {vmid, name, status}'   # VMs
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/lxc" | jq '.data[] | {vmid, name, status}'    # Containers
curl -sk -H "$AUTH" "$PVE_URL/api2/json/cluster/resources?type=vm" | jq '.data[] | {vmid, name, node, status, type}'  # Cluster-wide
curl -sk -H "$AUTH" "$PVE_URL/api2/json/cluster/nextid" | jq '.data'            # Next available VMID
```

## VM/Container Control

Actions: `start`, `stop` (immediate), `shutdown` (graceful ACPI), `reboot`. Replace `qemu` with `lxc` for containers.

```bash
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/status/{action}"
```

## Create LXC Container

```bash
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/lxc" \
  -d "vmid=200" -d "hostname=mycontainer" \
  -d "ostemplate=local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst" \
  -d "storage=local-lvm" -d "rootfs=local-lvm:8" \
  -d "memory=2048" -d "swap=512" -d "cores=2" \
  -d "net0=name=eth0,bridge=vmbr0,ip=dhcp" \
  -d "password=${LXC_PASSWORD:?set LXC_PASSWORD}" -d "start=1" -d "unprivileged=1"
```

## Create VM

```bash
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu" \
  -d "vmid=100" -d "name=myvm" -d "memory=4096" -d "cores=4" -d "sockets=1" -d "cpu=host" \
  -d "net0=virtio,bridge=vmbr0" -d "scsi0=local-lvm:32" -d "scsihw=virtio-scsi-single" \
  -d "ide2=local:iso/debian-12.iso,media=cdrom" -d "boot=order=scsi0;ide2" -d "ostype=l26"
```

## Clone & Template

```bash
# Full clone
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/clone" \
  -d "newid=101" -d "name=clone-vm" -d "full=1"
# Linked clone (faster, shares base)
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/clone" \
  -d "newid=102" -d "name=linked-clone" -d "full=0"
# Convert to template
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/template"
```

## Snapshots

```bash
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/snapshot" | jq  # List
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/snapshot" \
  -d "snapname=before-upgrade" -d "description=Pre-upgrade snapshot" -d "vmstate=1"  # Create
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/snapshot/{snapname}/rollback"  # Rollback
curl -sk -X DELETE -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}/snapshot/{snapname}"         # Delete
```

## Backups

```bash
# Start backup
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/vzdump" \
  -d "vmid={vmid}" -d "storage=local" -d "mode=snapshot" -d "compress=zstd"
# List backups
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/storage/local/content?content=backup" | jq
# Restore (qemu — use lxc endpoint for containers)
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu" \
  -d "vmid=100" -d "archive=local:backup/vzdump-qemu-100-2026_01_15.vma.zst" -d "storage=local-lvm"
```

## Storage & Templates

```bash
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/storage" | jq '.data[] | {storage, type, active, content}'  # List storage
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/storage/local/content?content=vztmpl" | jq  # Templates
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/storage/local/content?content=iso" | jq     # ISOs
curl -sk -X POST -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/aplinfo" \
  -d "storage=local" -d "template=debian-12-standard_12.2-1_amd64.tar.zst"  # Download template
```

## Tasks

```bash
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/tasks?limit=10" | jq       # Recent tasks
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/tasks/{upid}/status" | jq   # Task status
curl -sk -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/tasks/{upid}/log" | jq      # Task log
```

## Delete VM/Container

```bash
curl -sk -X DELETE -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}"                                    # Normal (must be stopped)
curl -sk -X DELETE -H "$AUTH" "$PVE_URL/api2/json/nodes/{node}/qemu/{vmid}?purge=1&destroy-unreferenced-disks=1"  # Force purge
```
