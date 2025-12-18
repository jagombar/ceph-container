#!/bin/bash

# Podman Container Export Script
# Run this on the SOURCE server
# Usage: sudo ./source-export.sh

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
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Podman Container Migration - Export Script ===${NC}"
echo "Export directory: ${EXPORT_DIR}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root (use sudo)${NC}"
    exit 1
fi

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

echo -e "${BLUE}Found containers:${NC}"
echo "$CONTAINERS"

# Create migration manifest
MANIFEST="${CONFIGS_DIR}/migration-manifest.txt"
echo "# Podman Migration Manifest" > "$MANIFEST"
echo "# Generated: $(date)" >> "$MANIFEST"
echo "# Source Host: $(hostname)" >> "$MANIFEST"
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
                tar -czpf "$ARCHIVE" -C "$SOURCE" . 2>/dev/null || {
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
    
    # Get network settings
    NETWORKS=$(podman inspect "$CONTAINER" --format='{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{"\n"}}{{end}}')
    if [ -n "$NETWORKS" ]; then
        echo "Networks:" >> "$MANIFEST"
        echo "$NETWORKS" >> "$MANIFEST"
    fi
    
    echo "" >> "$MANIFEST"
done

# Ask to stop containers
echo -e "\n${YELLOW}Stopping all containers for consistent export...${NC}"
echo -e "${RED}WARNING: This will stop all containers!${NC}"
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

IMAGE_MANIFEST="${CONFIGS_DIR}/images-manifest.txt"
echo "# Image Export Manifest" > "$IMAGE_MANIFEST"
echo "# Generated: $(date)" >> "$IMAGE_MANIFEST"
echo "" >> "$IMAGE_MANIFEST"

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
    echo "Image: ${IMAGE}" >> "$IMAGE_MANIFEST"
    echo "Archive: ${FILENAME}.tar.gz" >> "$IMAGE_MANIFEST"
    echo "Checksum: ${CHECKSUM}" >> "$IMAGE_MANIFEST"
    echo "" >> "$IMAGE_MANIFEST"
done

# Create README
README="${EXPORT_DIR}/README.txt"
cat > "$README" << EOF
Podman Container Migration Export
==================================

Generated: $(date)
Source Host: $(hostname)

Contents:
---------
- images/       : Container images (tar.gz)
- volumes/      : Volume data backups (tar.gz)
- configs/      : Container configurations (JSON)

Manifests:
----------
- configs/migration-manifest.txt : Complete migration manifest
- configs/images-manifest.txt    : Image checksums
- configs/*_config.json          : Individual container configs

Next Steps:
-----------
1. Review the migration manifest
2. Transfer this directory to destination server:
   rsync -avz --progress ${EXPORT_DIR}/ user@destination:/tmp/podman-migration/
3. Run destination-import.sh on the destination server

Total Export Size: $(du -sh "${EXPORT_DIR}" | cut -f1)
EOF

# Create summary
echo -e "\n${GREEN}=== Export Summary ===${NC}"
echo "Export directory: ${EXPORT_DIR}"
echo "Containers exported: $(echo "$CONTAINERS" | wc -l)"
echo "Images exported: $(ls -1 "${IMAGES_DIR}" 2>/dev/null | wc -l)"
echo "Volume archives: $(ls -1 "${VOLUMES_DIR}" 2>/dev/null | wc -l)"
echo ""
echo "Total size: $(du -sh "${EXPORT_DIR}" | cut -f1)"
echo ""
echo -e "${GREEN}Export complete!${NC}"
echo ""
echo "Files created:"
echo "  - Migration manifest: ${MANIFEST}"
echo "  - Images manifest: ${IMAGE_MANIFEST}"
echo "  - README: ${README}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "1. Review the manifest: cat ${MANIFEST}"
echo "2. Transfer files to destination server:"
echo "   ${YELLOW}rsync -avz --progress ${EXPORT_DIR}/ user@destination:/tmp/podman-migration/${NC}"
echo "3. Run the import script on the destination server"