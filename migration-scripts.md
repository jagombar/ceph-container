# Podman Migration Automation Scripts

This document contains ready-to-use shell scripts to automate the Podman container migration process.

## Source Server Scripts

### Script 1: Export Containers and Volumes (source-export.sh)

Save this script on your **source server** and run it to export all containers and volumes:

```bash
#!/bin/bash

# Podman Container Export Script
# Run this on the SOURCE server

set -e  # Exit on error

# Configuration
EXPORT_DIR="/tmp/podman-migration"
IMAGES_DIR="${EXPORT_DIR}/images"
VOLUMES_DIR="${EXPORT_DIR}/volumes"
CONFIGS_DIR="${EXPORT_DIR}/configs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Podman Container Migration - Export Script ===${NC}"
echo "Export directory: ${EXPORT_DIR}"

# Create directories
echo -e "\n${YELLOW}Creating export directories...${NC}"
mkdir -p "${IMAGES_DIR}" "${VOLUMES_DIR}" "${CONFIGS_DIR}"

# Get list of all containers
echo -e "\n${YELLOW}Discovering containers...${NC}"
CONTAINERS=$(podman ps -a --format "{{.Names}}")

if [ -z "$CONTAINERS" ]; then
    echo -e "${RED}No containers found!${NC}"
    exit 1
fi

echo "Found containers:"
echo "$CONTAINERS"

# Create migration manifest
MANIFEST="${CONFIGS_DIR}/migration-manifest.txt"
echo "# Podman Migration Manifest" > "$MANIFEST"
echo "# Generated: $(date)" >> "$MANIFEST"
echo "" >> "$MANIFEST"

# Process each container
for CONTAINER in $CONTAINERS; do
    echo -e "\n${GREEN}Processing container: ${CONTAINER}${NC}"
    
    # Export container configuration
    echo "  - Exporting configuration..."
    podman inspect "$CONTAINER" > "${CONFIGS_DIR}/${CONTAINER}_config.json"
    
    # Get container details
    IMAGE=$(podman inspect "$CONTAINER" --format='{{.ImageName}}')
    STATUS=$(podman inspect "$CONTAINER" --format='{{.State.Status}}')
    
    echo "    Image: $IMAGE"
    echo "    Status: $STATUS"
    
    # Add to manifest
    echo "## Container: ${CONTAINER}" >> "$MANIFEST"
    echo "Image: ${IMAGE}" >> "$MANIFEST"
    echo "Status: ${STATUS}" >> "$MANIFEST"
    
    # Get and document volume mounts
    echo "  - Documenting volume mounts..."
    MOUNTS=$(podman inspect "$CONTAINER" --format='{{range .Mounts}}{{.Source}}:{{.Destination}}:{{.Type}}{{"\n"}}{{end}}')
    
    if [ -n "$MOUNTS" ]; then
        echo "Volumes:" >> "$MANIFEST"
        echo "$MOUNTS" >> "$MANIFEST"
        
        # Backup each volume
        VOLUME_COUNT=0
        while IFS=: read -r SOURCE DEST TYPE; do
            if [ -n "$SOURCE" ] && [ -d "$SOURCE" ]; then
                VOLUME_COUNT=$((VOLUME_COUNT + 1))
                VOLUME_NAME="${CONTAINER}_vol${VOLUME_COUNT}"
                ARCHIVE="${VOLUMES_DIR}/${VOLUME_NAME}.tar.gz"
                
                echo "  - Backing up volume: ${SOURCE}"
                echo "    Archive: ${VOLUME_NAME}.tar.gz"
                
                # Create tar archive with preserved permissions
                sudo tar -czpf "$ARCHIVE" -C "$SOURCE" . 2>/dev/null || {
                    echo -e "    ${RED}Warning: Failed to backup ${SOURCE}${NC}"
                    continue
                }
                
                # Calculate checksum
                CHECKSUM=$(sha256sum "$ARCHIVE" | awk '{print $1}')
                echo "Volume Archive: ${VOLUME_NAME}.tar.gz" >> "$MANIFEST"
                echo "Source Path: ${SOURCE}" >> "$MANIFEST"
                echo "Container Path: ${DEST}" >> "$MANIFEST"
                echo "Checksum: ${CHECKSUM}" >> "$MANIFEST"
            fi
        done <<< "$MOUNTS"
    else
        echo "Volumes: None" >> "$MANIFEST"
    fi
    
    # Get port mappings
    PORTS=$(podman inspect "$CONTAINER" --format='{{range $p, $conf := .NetworkSettings.Ports}}{{$p}} -> {{(index $conf 0).HostPort}}{{"\n"}}{{end}}')
    if [ -n "$PORTS" ]; then
        echo "Ports:" >> "$MANIFEST"
        echo "$PORTS" >> "$MANIFEST"
    fi
    
    # Get environment variables
    echo "Environment:" >> "$MANIFEST"
    podman inspect "$CONTAINER" --format='{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' >> "$MANIFEST"
    
    echo "" >> "$MANIFEST"
done

# Stop all containers
echo -e "\n${YELLOW}Stopping all containers for consistent export...${NC}"
read -p "Stop all containers now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    for CONTAINER in $CONTAINERS; do
        echo "  - Stopping ${CONTAINER}..."
        podman stop "$CONTAINER" 2>/dev/null || echo "    Already stopped"
    done
else
    echo -e "${YELLOW}Warning: Containers not stopped. Data may be inconsistent.${NC}"
fi

# Export images
echo -e "\n${YELLOW}Exporting container images...${NC}"
IMAGES=$(podman ps -a --format "{{.Image}}" | sort -u)

for IMAGE in $IMAGES; do
    echo "  - Exporting image: ${IMAGE}"
    FILENAME=$(echo "$IMAGE" | tr '/:' '_')
    ARCHIVE="${IMAGES_DIR}/${FILENAME}.tar"
    
    podman save -o "$ARCHIVE" "$IMAGE"
    
    # Compress
    echo "    Compressing..."
    gzip "$ARCHIVE"
    
    # Calculate checksum
    CHECKSUM=$(sha256sum "${ARCHIVE}.gz" | awk '{print $1}')
    echo "Image: ${IMAGE}" >> "${CONFIGS_DIR}/images-manifest.txt"
    echo "Archive: ${FILENAME}.tar.gz" >> "${CONFIGS_DIR}/images-manifest.txt"
    echo "Checksum: ${CHECKSUM}" >> "${CONFIGS_DIR}/images-manifest.txt"
    echo "" >> "${CONFIGS_DIR}/images-manifest.txt"
done

# Create summary
echo -e "\n${GREEN}=== Export Summary ===${NC}"
echo "Export directory: ${EXPORT_DIR}"
echo "Containers exported: $(echo "$CONTAINERS" | wc -l)"
echo "Images exported: $(ls -1 "${IMAGES_DIR}" | wc -l)"
echo "Volume archives: $(ls -1 "${VOLUMES_DIR}" | wc -l)"
echo ""
echo "Total size: $(du -sh "${EXPORT_DIR}" | cut -f1)"
echo ""
echo -e "${GREEN}Export complete!${NC}"
echo ""
echo "Next steps:"
echo "1. Review the manifest: ${MANIFEST}"
echo "2. Transfer files to destination server:"
echo "   rsync -avz --progress ${EXPORT_DIR}/ user@destination:/tmp/podman-migration/"
echo "3. Run the import script on the destination server"
```

### How to Use the Export Script

```bash
# On source server
# 1. Save the script
cat > source-export.sh << 'EOF'
[paste script above]
EOF

# 2. Make it executable
chmod +x source-export.sh

# 3. Run the script (requires sudo for volume backups)
sudo ./source-export.sh

# 4. Transfer to destination server
rsync -avz --progress /tmp/podman-migration/ user@destination-server:/tmp/podman-migration/
```

## Destination Server Scripts

### Script 2: Import Containers and Volumes (destination-import.sh)

Save this script on your **destination server** and run it to import all containers and volumes:

```bash
#!/bin/bash

# Podman Container Import Script
# Run this on the DESTINATION server

set -e  # Exit on error

# Configuration
IMPORT_DIR="/tmp/podman-migration"
IMAGES_DIR="${IMPORT_DIR}/images"
VOLUMES_DIR="${IMPORT_DIR}/volumes"
CONFIGS_DIR="${IMPORT_DIR}/configs"
MANIFEST="${CONFIGS_DIR}/migration-manifest.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Podman Container Migration - Import Script ===${NC}"
echo "Import directory: ${IMPORT_DIR}"

# Check if import directory exists
if [ ! -d "$IMPORT_DIR" ]; then
    echo -e "${RED}Error: Import directory not found: ${IMPORT_DIR}${NC}"
    echo "Please transfer files from source server first."
    exit 1
fi

# Check if manifest exists
if [ ! -f "$MANIFEST" ]; then
    echo -e "${RED}Error: Migration manifest not found: ${MANIFEST}${NC}"
    exit 1
fi

# Load images
echo -e "\n${YELLOW}Loading container images...${NC}"
if [ -d "$IMAGES_DIR" ]; then
    for IMAGE_ARCHIVE in "${IMAGES_DIR}"/*.tar.gz; do
        if [ -f "$IMAGE_ARCHIVE" ]; then
            echo "  - Loading: $(basename "$IMAGE_ARCHIVE")"
            gunzip -c "$IMAGE_ARCHIVE" | podman load
        fi
    done
else
    echo -e "${RED}Warning: Images directory not found${NC}"
fi

# Verify images loaded
echo -e "\n${YELLOW}Verifying loaded images...${NC}"
podman images

# Parse manifest and restore volumes
echo -e "\n${YELLOW}Restoring volumes...${NC}"

CURRENT_CONTAINER=""
CURRENT_VOLUME=""
CURRENT_SOURCE=""
CURRENT_DEST=""

while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    
    # Parse container name
    if [[ "$line" =~ ^##\ Container:\ (.+)$ ]]; then
        CURRENT_CONTAINER="${BASH_REMATCH[1]}"
        echo -e "\n${GREEN}Processing container: ${CURRENT_CONTAINER}${NC}"
        continue
    fi
    
    # Parse volume archive
    if [[ "$line" =~ ^Volume\ Archive:\ (.+)$ ]]; then
        CURRENT_VOLUME="${BASH_REMATCH[1]}"
        continue
    fi
    
    # Parse source path
    if [[ "$line" =~ ^Source\ Path:\ (.+)$ ]]; then
        CURRENT_SOURCE="${BASH_REMATCH[1]}"
        continue
    fi
    
    # Parse container path and restore
    if [[ "$line" =~ ^Container\ Path:\ (.+)$ ]]; then
        CURRENT_DEST="${BASH_REMATCH[1]}"
        
        if [ -n "$CURRENT_VOLUME" ] && [ -n "$CURRENT_SOURCE" ]; then
            ARCHIVE="${VOLUMES_DIR}/${CURRENT_VOLUME}"
            
            if [ -f "$ARCHIVE" ]; then
                echo "  - Restoring volume: ${CURRENT_VOLUME}"
                echo "    Destination: ${CURRENT_SOURCE}"
                
                # Create destination directory
                sudo mkdir -p "$CURRENT_SOURCE"
                
                # Extract archive
                sudo tar -xzpf "$ARCHIVE" -C "$CURRENT_SOURCE"
                
                echo "    ✓ Restored"
            else
                echo -e "    ${RED}Warning: Archive not found: ${ARCHIVE}${NC}"
            fi
        fi
        
        # Reset variables
        CURRENT_VOLUME=""
        CURRENT_SOURCE=""
        CURRENT_DEST=""
    fi
done < "$MANIFEST"

# Display container configurations
echo -e "\n${YELLOW}Container configurations available in: ${CONFIGS_DIR}${NC}"
echo "Review the JSON files to recreate containers with correct settings."
echo ""
echo "Example commands to recreate containers:"
echo ""

# Parse manifest for container recreation commands
CURRENT_CONTAINER=""
CURRENT_IMAGE=""
declare -a VOLUMES
declare -a PORTS
declare -a ENV_VARS

while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    
    if [[ "$line" =~ ^##\ Container:\ (.+)$ ]]; then
        # Print previous container command if exists
        if [ -n "$CURRENT_CONTAINER" ] && [ -n "$CURRENT_IMAGE" ]; then
            echo "# Container: ${CURRENT_CONTAINER}"
            echo -n "podman run -d --name ${CURRENT_CONTAINER}"
            
            for vol in "${VOLUMES[@]}"; do
                echo -n " -v ${vol}"
            done
            
            for port in "${PORTS[@]}"; do
                echo -n " -p ${port}"
            done
            
            for env in "${ENV_VARS[@]}"; do
                echo -n " -e \"${env}\""
            done
            
            echo " ${CURRENT_IMAGE}"
            echo ""
        fi
        
        # Reset for new container
        CURRENT_CONTAINER="${BASH_REMATCH[1]}"
        CURRENT_IMAGE=""
        VOLUMES=()
        PORTS=()
        ENV_VARS=()
        continue
    fi
    
    if [[ "$line" =~ ^Image:\ (.+)$ ]]; then
        CURRENT_IMAGE="${BASH_REMATCH[1]}"
        continue
    fi
    
    if [[ "$line" =~ ^Source\ Path:\ (.+)$ ]]; then
        SOURCE_PATH="${BASH_REMATCH[1]}"
        # Read next line for container path
        read -r next_line
        if [[ "$next_line" =~ ^Container\ Path:\ (.+)$ ]]; then
            CONTAINER_PATH="${BASH_REMATCH[1]}"
            VOLUMES+=("${SOURCE_PATH}:${CONTAINER_PATH}")
        fi
        continue
    fi
done < "$MANIFEST"

# Print last container
if [ -n "$CURRENT_CONTAINER" ] && [ -n "$CURRENT_IMAGE" ]; then
    echo "# Container: ${CURRENT_CONTAINER}"
    echo -n "podman run -d --name ${CURRENT_CONTAINER}"
    
    for vol in "${VOLUMES[@]}"; do
        echo -n " -v ${vol}"
    done
    
    echo " ${CURRENT_IMAGE}"
    echo ""
fi

echo -e "\n${GREEN}=== Import Summary ===${NC}"
echo "Images loaded: $(podman images | tail -n +2 | wc -l)"
echo "Volumes restored: $(ls -1 "${VOLUMES_DIR}" 2>/dev/null | wc -l)"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Review container configurations in: ${CONFIGS_DIR}"
echo "2. Recreate containers using the commands above (adjust as needed)"
echo "3. Start containers: podman start <container_name>"
echo "4. Verify: podman ps -a"
echo "5. Check logs: podman logs <container_name>"
```

### How to Use the Import Script

```bash
# On destination server
# 1. Ensure files are transferred
ls -la /tmp/podman-migration/

# 2. Save the script
cat > destination-import.sh << 'EOF'
[paste script above]
EOF

# 3. Make it executable
chmod +x destination-import.sh

# 4. Run the script (requires sudo for volume restoration)
sudo ./destination-import.sh

# 5. Follow the output to recreate containers
```

## Quick Migration Script (One-Liner Transfer)

For direct server-to-server migration with SSH access:

```bash
#!/bin/bash
# Quick migration from source to destination
# Run this on SOURCE server

SOURCE_DIR="/tmp/podman-migration"
DEST_USER="username"
DEST_HOST="destination-server"
DEST_DIR="/tmp/podman-migration"

# Export on source
sudo ./source-export.sh

# Transfer to destination
rsync -avz --progress \
  -e "ssh -o StrictHostKeyChecking=no" \
  "${SOURCE_DIR}/" \
  "${DEST_USER}@${DEST_HOST}:${DEST_DIR}/"

echo "Transfer complete!"
echo "Now SSH to destination server and run: sudo ./destination-import.sh"
```

## Verification Script

Run this on the destination server after importing to verify everything:

```bash
#!/bin/bash
# Verification script for destination server

echo "=== Podman Migration Verification ==="
echo ""

echo "1. Checking loaded images:"
podman images
echo ""

echo "2. Checking containers:"
podman ps -a
echo ""

echo "3. Checking running containers:"
podman ps
echo ""

echo "4. Checking container logs (last 10 lines each):"
for container in $(podman ps -a --format "{{.Names}}"); do
    echo "--- Logs for: $container ---"
    podman logs --tail 10 "$container" 2>&1 || echo "No logs available"
    echo ""
done

echo "5. Checking volume mounts:"
for container in $(podman ps -a --format "{{.Names}}"); do
    echo "--- Volumes for: $container ---"
    podman inspect "$container" --format='{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
    echo ""
done

echo "=== Verification Complete ==="
```

## Troubleshooting Commands

```bash
# Check if volumes are properly mounted
podman inspect <container_name> --format='{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'

# Verify volume data exists
ls -la /path/to/volume

# Check container logs for errors
podman logs <container_name>

# Test container interactively
podman run -it --rm <image_name> /bin/bash

# Check SELinux context (if applicable)
ls -Z /path/to/volume

# Fix SELinux context
sudo chcon -Rt svirt_sandbox_file_t /path/to/volume

# Restart a container
podman restart <container_name>

# Remove and recreate a container
podman rm <container_name>
podman run -d --name <container_name> [options] <image>
```

## Notes

- All scripts include error handling and colored output for better visibility
- Checksums are calculated for verification of transferred files
- Scripts preserve file permissions and ownership using tar's `-p` flag
- The manifest file documents all container configurations for easy recreation
- Scripts require sudo access for volume operations
- Always test with a single container first before migrating all containers