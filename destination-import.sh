#!/bin/bash

# Podman Container Import Script
# Run this on the DESTINATION server
# Usage: sudo ./destination-import.sh

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
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Podman Container Migration - Import Script ===${NC}"
echo "Import directory: ${IMPORT_DIR}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root (use sudo)${NC}"
    exit 1
fi

# Check if import directory exists
if [ ! -d "$IMPORT_DIR" ]; then
    echo -e "${RED}Error: Import directory not found: ${IMPORT_DIR}${NC}"
    echo "Please transfer files from source server first:"
    echo "  rsync -avz --progress user@source:/tmp/podman-migration/ ${IMPORT_DIR}/"
    exit 1
fi

# Check if manifest exists
if [ ! -f "$MANIFEST" ]; then
    echo -e "${RED}Error: Migration manifest not found: ${MANIFEST}${NC}"
    exit 1
fi

echo -e "${BLUE}Import directory contents:${NC}"
ls -lh "$IMPORT_DIR"

# Load images
echo -e "\n${YELLOW}Loading container images...${NC}"
if [ -d "$IMAGES_DIR" ]; then
    IMAGE_COUNT=0
    for IMAGE_ARCHIVE in "${IMAGES_DIR}"/*.tar.gz; do
        if [ -f "$IMAGE_ARCHIVE" ]; then
            IMAGE_COUNT=$((IMAGE_COUNT + 1))
            echo "  - Loading: $(basename "$IMAGE_ARCHIVE")"
            gunzip -c "$IMAGE_ARCHIVE" | podman load
        fi
    done
    echo -e "${GREEN}Loaded ${IMAGE_COUNT} images${NC}"
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
VOLUME_COUNT=0

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
                VOLUME_COUNT=$((VOLUME_COUNT + 1))
                echo "  - Restoring volume: ${CURRENT_VOLUME}"
                echo "    Destination: ${CURRENT_SOURCE}"
                
                # Create destination directory
                mkdir -p "$CURRENT_SOURCE"
                
                # Extract archive
                tar -xzpf "$ARCHIVE" -C "$CURRENT_SOURCE"
                
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

echo -e "${GREEN}Restored ${VOLUME_COUNT} volumes${NC}"

# Generate container recreation script
RECREATE_SCRIPT="${IMPORT_DIR}/recreate-containers.sh"
echo "#!/bin/bash" > "$RECREATE_SCRIPT"
echo "# Container Recreation Script" >> "$RECREATE_SCRIPT"
echo "# Generated: $(date)" >> "$RECREATE_SCRIPT"
echo "" >> "$RECREATE_SCRIPT"

echo -e "\n${YELLOW}Generating container recreation commands...${NC}"

CURRENT_CONTAINER=""
CURRENT_IMAGE=""
declare -a VOLUMES
declare -a PORTS
declare -a ENV_VARS
declare -a NETWORKS

while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    
    if [[ "$line" =~ ^##\ Container:\ (.+)$ ]]; then
        # Print previous container command if exists
        if [ -n "$CURRENT_CONTAINER" ] && [ -n "$CURRENT_IMAGE" ]; then
            echo "echo 'Creating container: ${CURRENT_CONTAINER}'" >> "$RECREATE_SCRIPT"
            echo -n "podman run -d --name ${CURRENT_CONTAINER}" >> "$RECREATE_SCRIPT"
            
            for vol in "${VOLUMES[@]}"; do
                echo -n " -v ${vol}" >> "$RECREATE_SCRIPT"
            done
            
            for port in "${PORTS[@]}"; do
                echo -n " -p ${port}" >> "$RECREATE_SCRIPT"
            done
            
            for net in "${NETWORKS[@]}"; do
                echo -n " --network ${net}" >> "$RECREATE_SCRIPT"
            done
            
            for env in "${ENV_VARS[@]}"; do
                # Escape quotes in environment variables
                escaped_env=$(echo "$env" | sed 's/"/\\"/g')
                echo -n " -e \"${escaped_env}\"" >> "$RECREATE_SCRIPT"
            done
            
            echo " ${CURRENT_IMAGE}" >> "$RECREATE_SCRIPT"
            echo "" >> "$RECREATE_SCRIPT"
        fi
        
        # Reset for new container
        CURRENT_CONTAINER="${BASH_REMATCH[1]}"
        CURRENT_IMAGE=""
        VOLUMES=()
        PORTS=()
        ENV_VARS=()
        NETWORKS=()
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
    
    if [[ "$line" =~ ^Ports:$ ]]; then
        # Read port mappings
        while IFS= read -r port_line; do
            [[ -z "$port_line" ]] && break
            [[ "$port_line" =~ ^[A-Z] ]] && break
            if [[ "$port_line" =~ ([0-9]+/tcp)\ -\>\ ([0-9]+) ]]; then
                PORTS+=("${BASH_REMATCH[2]}:${BASH_REMATCH[1]}")
            fi
        done
        continue
    fi
    
    if [[ "$line" =~ ^Environment:$ ]]; then
        # Read environment variables
        while IFS= read -r env_line; do
            [[ -z "$env_line" ]] && break
            [[ "$env_line" =~ ^[A-Z#] ]] && break
            ENV_VARS+=("$env_line")
        done
        continue
    fi
    
    if [[ "$line" =~ ^Networks:$ ]]; then
        # Read networks
        while IFS= read -r net_line; do
            [[ -z "$net_line" ]] && break
            [[ "$net_line" =~ ^[A-Z#] ]] && break
            NETWORKS+=("$net_line")
        done
        continue
    fi
done < "$MANIFEST"

# Print last container
if [ -n "$CURRENT_CONTAINER" ] && [ -n "$CURRENT_IMAGE" ]; then
    echo "echo 'Creating container: ${CURRENT_CONTAINER}'" >> "$RECREATE_SCRIPT"
    echo -n "podman run -d --name ${CURRENT_CONTAINER}" >> "$RECREATE_SCRIPT"
    
    for vol in "${VOLUMES[@]}"; do
        echo -n " -v ${vol}" >> "$RECREATE_SCRIPT"
    done
    
    for port in "${PORTS[@]}"; do
        echo -n " -p ${port}" >> "$RECREATE_SCRIPT"
    done
    
    for net in "${NETWORKS[@]}"; do
        echo -n " --network ${net}" >> "$RECREATE_SCRIPT"
    done
    
    echo " ${CURRENT_IMAGE}" >> "$RECREATE_SCRIPT"
    echo "" >> "$RECREATE_SCRIPT"
fi

chmod +x "$RECREATE_SCRIPT"

# Display summary
echo -e "\n${GREEN}=== Import Summary ===${NC}"
echo "Images loaded: $(podman images | tail -n +2 | wc -l)"
echo "Volumes restored: ${VOLUME_COUNT}"
echo ""
echo -e "${BLUE}Container recreation script created: ${RECREATE_SCRIPT}${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Review the recreation script:"
echo "   ${BLUE}cat ${RECREATE_SCRIPT}${NC}"
echo ""
echo "2. Edit the script if needed (adjust ports, volumes, environment variables)"
echo ""
echo "3. Run the script to create containers:"
echo "   ${BLUE}bash ${RECREATE_SCRIPT}${NC}"
echo ""
echo "4. Verify containers are running:"
echo "   ${BLUE}podman ps -a${NC}"
echo ""
echo "5. Check container logs:"
echo "   ${BLUE}podman logs <container_name>${NC}"
echo ""
echo "6. Test application functionality"
echo ""
echo -e "${GREEN}Import complete!${NC}"