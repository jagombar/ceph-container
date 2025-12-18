# Podman Migration Quick Start Guide

## TL;DR - Fast Track Migration

If you're experienced with Podman and just need the commands:

### On Source Server
```bash
# 1. Stop containers
podman stop $(podman ps -q)

# 2. Export images
mkdir -p /tmp/migration/{images,volumes}
for img in $(podman ps -a --format "{{.Image}}" | sort -u); do
    podman save $img | gzip > /tmp/migration/images/$(echo $img | tr '/:' '_').tar.gz
done

# 3. Backup volumes (adjust paths)
tar -czpf /tmp/migration/volumes/myapp_data.tar.gz -C /var/lib/myapp/data .

# 4. Transfer
rsync -avz /tmp/migration/ user@dest:/tmp/migration/
```

### On Destination Server
```bash
# 1. Load images
for img in /tmp/migration/images/*.tar.gz; do
    gunzip -c $img | podman load
done

# 2. Restore volumes (adjust paths)
mkdir -p /var/lib/myapp/data
tar -xzpf /tmp/migration/volumes/myapp_data.tar.gz -C /var/lib/myapp/data

# 3. Recreate containers (adjust parameters)
podman run -d --name myapp -v /var/lib/myapp/data:/app/data -p 8080:8080 myapp:latest
```

---

## Pre-Migration Checklist

Before starting the migration, ensure you have:

- [ ] SSH access between source and destination servers
- [ ] Sufficient disk space on both servers (at least 2x container + volume size)
- [ ] Root/sudo access on both servers
- [ ] Podman installed on destination server (same or newer version)
- [ ] Documented list of containers to migrate
- [ ] Known volume mount paths for each container
- [ ] Scheduled maintenance window (if applicable)
- [ ] Backup of critical data (just in case)
- [ ] Tested the process on a non-critical container first

---

## Migration Scenarios

### Scenario 1: Single Container with One Volume

**Source Server:**
```bash
# Container: myapp
# Volume: /var/lib/myapp/data -> /app/data
# Port: 8080:8080

# Stop container
podman stop myapp

# Export image
podman save myapp:latest | gzip > /tmp/myapp-image.tar.gz

# Backup volume
tar -czpf /tmp/myapp-data.tar.gz -C /var/lib/myapp/data .

# Transfer
scp /tmp/myapp-*.tar.gz user@dest:/tmp/
```

**Destination Server:**
```bash
# Load image
gunzip -c /tmp/myapp-image.tar.gz | podman load

# Restore volume
mkdir -p /var/lib/myapp/data
tar -xzpf /tmp/myapp-data.tar.gz -C /var/lib/myapp/data

# Recreate container
podman run -d \
  --name myapp \
  -v /var/lib/myapp/data:/app/data \
  -p 8080:8080 \
  myapp:latest

# Verify
podman ps
podman logs myapp
curl http://localhost:8080
```

### Scenario 2: Database Container (PostgreSQL)

**Source Server:**
```bash
# Stop database gracefully
podman exec postgres pg_ctl stop -D /var/lib/postgresql/data -m fast
podman stop postgres

# Export image
podman save postgres:15 | gzip > /tmp/postgres-image.tar.gz

# Backup data directory
tar -czpf /tmp/postgres-data.tar.gz -C /var/lib/postgresql/data .

# Transfer
rsync -avz /tmp/postgres-*.tar.gz user@dest:/tmp/
```

**Destination Server:**
```bash
# Load image
gunzip -c /tmp/postgres-image.tar.gz | podman load

# Restore data
mkdir -p /var/lib/postgresql/data
chown -R 999:999 /var/lib/postgresql/data  # PostgreSQL UID
tar -xzpf /tmp/postgres-data.tar.gz -C /var/lib/postgresql/data

# Recreate container
podman run -d \
  --name postgres \
  -v /var/lib/postgresql/data:/var/lib/postgresql/data \
  -p 5432:5432 \
  -e POSTGRES_PASSWORD=yourpassword \
  postgres:15

# Verify
podman logs postgres
podman exec postgres psql -U postgres -c "SELECT version();"
```

### Scenario 3: Multiple Containers with Shared Network

**Source Server:**
```bash
# Containers: webapp, api, database
# Network: myapp-network

# Document network
podman network inspect myapp-network > /tmp/network-config.json

# Stop all containers
podman stop webapp api database

# Export images
for container in webapp api database; do
    image=$(podman inspect $container --format='{{.ImageName}}')
    podman save $image | gzip > /tmp/${container}-image.tar.gz
done

# Backup volumes
tar -czpf /tmp/webapp-data.tar.gz -C /var/lib/webapp .
tar -czpf /tmp/api-data.tar.gz -C /var/lib/api .
tar -czpf /tmp/database-data.tar.gz -C /var/lib/postgresql/data .

# Transfer
rsync -avz /tmp/*.tar.gz /tmp/network-config.json user@dest:/tmp/
```

**Destination Server:**
```bash
# Create network
podman network create myapp-network

# Load images
for img in /tmp/*-image.tar.gz; do
    gunzip -c $img | podman load
done

# Restore volumes
mkdir -p /var/lib/{webapp,api,postgresql/data}
tar -xzpf /tmp/webapp-data.tar.gz -C /var/lib/webapp
tar -xzpf /tmp/api-data.tar.gz -C /var/lib/api
tar -xzpf /tmp/database-data.tar.gz -C /var/lib/postgresql/data

# Recreate containers in order
podman run -d \
  --name database \
  --network myapp-network \
  -v /var/lib/postgresql/data:/var/lib/postgresql/data \
  postgres:15

podman run -d \
  --name api \
  --network myapp-network \
  -v /var/lib/api:/app/data \
  -e DATABASE_URL=postgresql://database:5432/mydb \
  api:latest

podman run -d \
  --name webapp \
  --network myapp-network \
  -v /var/lib/webapp:/app/data \
  -p 80:80 \
  -e API_URL=http://api:8080 \
  webapp:latest

# Verify
podman ps
podman logs webapp
podman logs api
podman logs database
```

### Scenario 4: Container with Named Volumes

**Source Server:**
```bash
# Container using named volume instead of bind mount
# podman run -d --name myapp -v myapp-data:/app/data myapp:latest

# Stop container
podman stop myapp

# Export image
podman save myapp:latest | gzip > /tmp/myapp-image.tar.gz

# Find volume location
VOLUME_PATH=$(podman volume inspect myapp-data --format '{{.Mountpoint}}')
echo "Volume path: $VOLUME_PATH"

# Backup volume
tar -czpf /tmp/myapp-data.tar.gz -C "$VOLUME_PATH" .

# Transfer
scp /tmp/myapp-*.tar.gz user@dest:/tmp/
```

**Destination Server:**
```bash
# Load image
gunzip -c /tmp/myapp-image.tar.gz | podman load

# Create named volume
podman volume create myapp-data

# Get volume path
VOLUME_PATH=$(podman volume inspect myapp-data --format '{{.Mountpoint}}')

# Restore data
tar -xzpf /tmp/myapp-data.tar.gz -C "$VOLUME_PATH"

# Recreate container
podman run -d \
  --name myapp \
  -v myapp-data:/app/data \
  -p 8080:8080 \
  myapp:latest

# Verify
podman ps
podman exec myapp ls -la /app/data
```

### Scenario 5: Rootless Podman Migration

**Source Server (as regular user):**
```bash
# No sudo needed for rootless podman
podman stop myapp

# Export
podman save myapp:latest | gzip > ~/migration/myapp-image.tar.gz

# Backup volume (rootless volumes are in user's home)
VOLUME_PATH=$(podman volume inspect myapp-data --format '{{.Mountpoint}}')
tar -czpf ~/migration/myapp-data.tar.gz -C "$VOLUME_PATH" .

# Transfer
rsync -avz ~/migration/ user@dest:~/migration/
```

**Destination Server (as same user):**
```bash
# Load image
gunzip -c ~/migration/myapp-image.tar.gz | podman load

# Create volume
podman volume create myapp-data
VOLUME_PATH=$(podman volume inspect myapp-data --format '{{.Mountpoint}}')

# Restore data
tar -xzpf ~/migration/myapp-data.tar.gz -C "$VOLUME_PATH"

# Recreate container
podman run -d \
  --name myapp \
  -v myapp-data:/app/data \
  -p 8080:8080 \
  myapp:latest
```

---

## Common Issues and Solutions

### Issue 1: Permission Denied on Volume Mount

**Problem:** Container can't access mounted volume

**Solution:**
```bash
# Check ownership
ls -ln /path/to/volume

# Fix ownership (use container's UID:GID)
chown -R 1000:1000 /path/to/volume

# Or check SELinux context
ls -Z /path/to/volume

# Fix SELinux
chcon -Rt svirt_sandbox_file_t /path/to/volume
```

### Issue 2: Port Already in Use

**Problem:** `Error: address already in use`

**Solution:**
```bash
# Check what's using the port
ss -tulpn | grep :8080

# Use different host port
podman run -d -p 8081:8080 myapp:latest

# Or stop conflicting service
systemctl stop conflicting-service
```

### Issue 3: Container Exits Immediately

**Problem:** Container starts but exits right away

**Solution:**
```bash
# Check logs
podman logs myapp

# Run interactively to debug
podman run -it --rm myapp:latest /bin/bash

# Check if volume data is present
podman run -it --rm -v /var/lib/myapp/data:/app/data myapp:latest ls -la /app/data
```

### Issue 4: Network Connectivity Issues

**Problem:** Containers can't communicate

**Solution:**
```bash
# Verify network exists
podman network ls

# Inspect network
podman network inspect myapp-network

# Reconnect container to network
podman network connect myapp-network myapp

# Test connectivity
podman exec webapp ping api
```

### Issue 5: Image Not Found After Load

**Problem:** `podman load` succeeds but image not available

**Solution:**
```bash
# Check loaded images
podman images

# Image might have different name/tag
podman images --all

# Retag if needed
podman tag <image-id> myapp:latest
```

---

## Verification Checklist

After migration, verify:

- [ ] All images loaded: `podman images`
- [ ] All containers created: `podman ps -a`
- [ ] All containers running: `podman ps`
- [ ] Volume data present: `podman exec <container> ls -la /mount/path`
- [ ] Logs show no errors: `podman logs <container>`
- [ ] Application responds: `curl http://localhost:port/health`
- [ ] Database connections work (if applicable)
- [ ] File permissions correct: `podman exec <container> ls -ln /mount/path`
- [ ] Network connectivity between containers (if applicable)
- [ ] External access works (test from outside server)

---

## Rollback Plan

If migration fails:

1. **Keep source server intact** - Don't delete anything until migration is verified
2. **Document issues** - Save error messages and logs
3. **Stop destination containers** - `podman stop $(podman ps -q)`
4. **Restart source containers** - `podman start <container_name>`
5. **Update DNS/routing** - Point back to source server if changed
6. **Investigate and retry** - Fix issues and attempt migration again

---

## Performance Tips

### For Large Volumes
```bash
# Use compression level 1 for faster backup (less compression)
tar -cz1pf volume.tar.gz -C /path .

# Use pigz for parallel compression (if available)
tar -cpf - -C /path . | pigz > volume.tar.gz

# Use rsync with compression for transfer
rsync -avz --compress-level=1 /source/ user@dest:/dest/
```

### For Many Small Files
```bash
# Increase tar buffer size
tar --blocking-factor=512 -czpf volume.tar.gz -C /path .

# Use rsync with appropriate options
rsync -avz --inplace --no-whole-file /source/ user@dest:/dest/
```

### For Slow Networks
```bash
# Use rsync with progress and partial transfer support
rsync -avz --progress --partial /source/ user@dest:/dest/

# Resume interrupted transfer
rsync -avz --progress --partial --append-verify /source/ user@dest:/dest/
```

---

## Automation Tips

### Create Container Recreation Script
```bash
# On source server, generate recreation commands
for container in $(podman ps -a --format "{{.Names}}"); do
    echo "# Container: $container"
    echo "podman run -d \\"
    echo "  --name $container \\"
    
    # Add volume mounts
    podman inspect $container --format='{{range .Mounts}}  -v {{.Source}}:{{.Destination}} \\{{"\n"}}{{end}}'
    
    # Add port mappings
    podman inspect $container --format='{{range $p, $conf := .NetworkSettings.Ports}}  -p {{(index $conf 0).HostPort}}:{{$p}} \\{{"\n"}}{{end}}'
    
    # Add image
    podman inspect $container --format='  {{.ImageName}}'
    
    echo ""
done > recreate-containers.sh
```

### Monitor Migration Progress
```bash
# Watch transfer progress
watch -n 1 'du -sh /tmp/podman-migration'

# Monitor container startup
watch -n 1 'podman ps -a'

# Tail all container logs
podman logs -f $(podman ps -q)
```

---

## Next Steps

1. Review the detailed [Migration Plan](podman-migration-plan.md)
2. Use the [Automation Scripts](migration-scripts.md) for larger migrations
3. Test with one container first
4. Document your specific container configurations
5. Schedule maintenance window if needed
6. Execute migration during low-traffic period
7. Keep source server available for rollback
8. Monitor destination server for 24-48 hours
9. Update documentation with new server details
10. Decommission source server only after full verification

---

## Support Resources

- [Podman Documentation](https://docs.podman.io/)
- [Podman Migration Guide](https://docs.podman.io/en/latest/markdown/podman-migrate.1.html)
- [Container Best Practices](https://developers.redhat.com/articles/2021/11/11/best-practices-building-images-pass-red-hat-container-certification)

---

**Remember:** Always test the migration process with a non-critical container first!