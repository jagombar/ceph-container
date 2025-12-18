# Podman Container Migration Scripts

Complete toolkit for migrating Podman containers with their volumes from one server to another.

## 📦 What's Included

### Shell Scripts (Ready to Use)
- **`source-export.sh`** - Export containers and volumes from source server
- **`destination-import.sh`** - Import containers and volumes on destination server
- **`verify-migration.sh`** - Verify migration success and troubleshoot issues
- **`quick-migrate.sh`** - One-command migration (combines export + transfer)

### Documentation
- **`podman-migration-plan.md`** - Detailed step-by-step migration guide
- **`migration-scripts.md`** - Script documentation and examples
- **`migration-quickstart.md`** - Quick reference and common scenarios

## 🚀 Quick Start

### Option 1: Automated Migration (Recommended)

On the **source server**:

```bash
# Make scripts executable (already done)
chmod +x *.sh

# Run quick migration
sudo ./quick-migrate.sh username destination-server
```

Then follow the on-screen instructions to complete the migration on the destination server.

### Option 2: Manual Step-by-Step

#### On Source Server:

```bash
# 1. Export containers and volumes
sudo ./source-export.sh

# 2. Transfer to destination
rsync -avz --progress /tmp/podman-migration/ user@destination:/tmp/podman-migration/
```

#### On Destination Server:

```bash
# 3. Import images and volumes
sudo ./destination-import.sh

# 4. Review and run container recreation script
cat /tmp/podman-migration/recreate-containers.sh
bash /tmp/podman-migration/recreate-containers.sh

# 5. Verify migration
./verify-migration.sh
```

## 📋 Prerequisites

- **Both servers:**
  - Podman installed
  - Root/sudo access
  - Sufficient disk space (2x container + volume size)

- **Network:**
  - SSH access between servers
  - SSH keys configured (or password access)

## 🔧 Script Details

### source-export.sh

**Purpose:** Export all containers, images, and volumes from source server

**What it does:**
- Discovers all containers automatically
- Exports container configurations
- Saves container images as tar.gz files
- Backs up all mounted volumes
- Creates detailed manifest with checksums
- Optionally stops containers for consistency

**Usage:**
```bash
sudo ./source-export.sh
```

**Output:** `/tmp/podman-migration/` directory containing:
- `images/` - Container images
- `volumes/` - Volume backups
- `configs/` - Container configurations and manifests

### destination-import.sh

**Purpose:** Import containers and volumes on destination server

**What it does:**
- Loads all container images
- Restores volume data to correct locations
- Generates container recreation script
- Preserves permissions and ownership

**Usage:**
```bash
sudo ./destination-import.sh
```

**Output:** 
- Loaded images in Podman
- Restored volumes in original paths
- `/tmp/podman-migration/recreate-containers.sh` - Script to recreate containers

### verify-migration.sh

**Purpose:** Verify migration success and identify issues

**What it does:**
- Checks loaded images
- Verifies container status
- Validates volume mounts and data
- Tests port bindings
- Checks resource usage
- Provides troubleshooting guidance

**Usage:**
```bash
./verify-migration.sh
```

### quick-migrate.sh

**Purpose:** One-command migration from source to destination

**What it does:**
- Runs export on source
- Transfers files via rsync
- Copies scripts to destination
- Provides next-step instructions

**Usage:**
```bash
sudo ./quick-migrate.sh username destination-server
```

## 📖 Common Scenarios

### Scenario 1: Single Container Migration

```bash
# Source server
sudo ./source-export.sh
rsync -avz /tmp/podman-migration/ user@dest:/tmp/podman-migration/

# Destination server
sudo ./destination-import.sh
bash /tmp/podman-migration/recreate-containers.sh
./verify-migration.sh
```

### Scenario 2: Database Container

For databases (PostgreSQL, MySQL, etc.), ensure:
1. Stop the database gracefully before export
2. Verify data directory ownership after import
3. Test database connectivity after recreation

```bash
# Source: Stop database gracefully
podman exec postgres pg_ctl stop -D /var/lib/postgresql/data -m fast
sudo ./source-export.sh

# Destination: Fix ownership if needed
sudo chown -R 999:999 /var/lib/postgresql/data
```

### Scenario 3: Multiple Containers with Network

The scripts automatically handle:
- Custom networks (documented in manifest)
- Container dependencies
- Port mappings
- Environment variables

Review the generated `recreate-containers.sh` to adjust network settings if needed.

## 🔍 Troubleshooting

### Issue: Permission Denied on Volumes

```bash
# Check ownership
ls -ln /path/to/volume

# Fix ownership (use container's UID:GID)
sudo chown -R 1000:1000 /path/to/volume

# Fix SELinux context (if applicable)
sudo chcon -Rt svirt_sandbox_file_t /path/to/volume
```

### Issue: Container Won't Start

```bash
# Check logs
podman logs container_name

# Run interactively to debug
podman run -it --rm image_name /bin/bash

# Check volume data
podman exec container_name ls -la /mount/path
```

### Issue: Port Already in Use

```bash
# Find what's using the port
ss -tulpn | grep :8080

# Use different host port
podman run -d -p 8081:8080 myapp:latest
```

### Issue: Network Connectivity

```bash
# Verify network exists
podman network ls

# Reconnect container
podman network connect network_name container_name

# Test connectivity
podman exec webapp ping api
```

## ✅ Verification Checklist

After migration, verify:

- [ ] All images loaded: `podman images`
- [ ] All containers created: `podman ps -a`
- [ ] Containers running: `podman ps`
- [ ] Volume data present: `podman exec <container> ls /mount/path`
- [ ] No errors in logs: `podman logs <container>`
- [ ] Application responds: `curl http://localhost:port`
- [ ] Database connections work (if applicable)
- [ ] File permissions correct
- [ ] Network connectivity between containers
- [ ] External access works

## 🎯 Best Practices

1. **Test First** - Always test with a non-critical container first
2. **Backup** - Create backups before migration
3. **Document** - Save all commands and configurations
4. **Verify** - Use the verification script after migration
5. **Monitor** - Watch destination server for 24-48 hours
6. **Keep Source** - Don't delete source until fully verified
7. **Plan Downtime** - Schedule maintenance window if needed
8. **Update DNS** - Update DNS/load balancer after verification

## 📊 Migration Workflow

```
Source Server                    Destination Server
─────────────                    ──────────────────
1. Run source-export.sh
   ├─ Stop containers
   ├─ Export images
   └─ Backup volumes
         │
         ├─ Transfer via rsync ──────> 2. Receive files
         │                              │
         │                              ├─ Run destination-import.sh
         │                              ├─ Load images
         │                              └─ Restore volumes
         │                              │
         │                              ├─ Run recreate-containers.sh
         │                              └─ Start containers
         │                              │
         │                              └─ Run verify-migration.sh
         │
         └─ Keep stopped until verified
```

## 🔐 Security Notes

- Scripts require root/sudo access for volume operations
- SSH keys recommended for automated transfers
- Review generated scripts before execution
- Sensitive data (passwords, keys) in environment variables will be exported
- Consider encrypting transfers for sensitive data: `rsync -avz -e "ssh -c aes256-ctr"`

## 📝 File Locations

**Source Server:**
- Export directory: `/tmp/podman-migration/`
- Scripts: Current directory

**Destination Server:**
- Import directory: `/tmp/podman-migration/`
- Recreation script: `/tmp/podman-migration/recreate-containers.sh`

## 🆘 Support

For detailed information, see:
- `podman-migration-plan.md` - Complete migration guide
- `migration-quickstart.md` - Quick reference and examples
- [Podman Documentation](https://docs.podman.io/)

## 📄 License

These scripts are provided as-is for container migration purposes.

## ⚠️ Important Notes

- **Always test in non-production first**
- **Backup critical data before migration**
- **Keep source server intact until verified**
- **Monitor destination server after migration**
- **Update documentation with new server details**

---

**Quick Command Reference:**

```bash
# Source server
sudo ./quick-migrate.sh user destination-server

# Destination server (after transfer)
sudo ./destination-import.sh
bash /tmp/podman-migration/recreate-containers.sh
./verify-migration.sh
```

Good luck with your migration! 🚀