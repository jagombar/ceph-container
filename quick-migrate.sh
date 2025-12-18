#!/bin/bash

# Quick Podman Migration Script
# One-command migration from source to destination
# Run this on the SOURCE server
# Usage: ./quick-migrate.sh <destination_user> <destination_host>

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check arguments
if [ "$#" -ne 2 ]; then
    echo -e "${RED}Usage: $0 <destination_user> <destination_host>${NC}"
    echo ""
    echo "Example:"
    echo "  $0 admin destination-server.example.com"
    echo "  $0 root 192.168.1.100"
    exit 1
fi

DEST_USER="$1"
DEST_HOST="$2"
SOURCE_DIR="/tmp/podman-migration"
DEST_DIR="/tmp/podman-migration"

echo -e "${GREEN}=== Quick Podman Migration ===${NC}"
echo "Source: $(hostname)"
echo "Destination: ${DEST_USER}@${DEST_HOST}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root (use sudo)${NC}"
    exit 1
fi

# Test SSH connection
echo -e "${YELLOW}Testing SSH connection...${NC}"
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${DEST_USER}@${DEST_HOST}" "echo 'SSH connection successful'" 2>/dev/null; then
    echo -e "${RED}Error: Cannot connect to ${DEST_USER}@${DEST_HOST}${NC}"
    echo "Please ensure:"
    echo "1. SSH is configured and running on destination"
    echo "2. SSH keys are set up (or use ssh-copy-id)"
    echo "3. User has appropriate permissions"
    exit 1
fi
echo -e "${GREEN}✓ SSH connection successful${NC}"
echo ""

# Check if source-export.sh exists
if [ ! -f "source-export.sh" ]; then
    echo -e "${RED}Error: source-export.sh not found in current directory${NC}"
    echo "Please ensure all migration scripts are in the same directory"
    exit 1
fi

# Run export script
echo -e "${YELLOW}Step 1: Exporting containers and volumes...${NC}"
bash source-export.sh

if [ ! -d "$SOURCE_DIR" ]; then
    echo -e "${RED}Error: Export failed - directory not created${NC}"
    exit 1
fi

# Calculate total size
TOTAL_SIZE=$(du -sh "$SOURCE_DIR" | cut -f1)
echo -e "${GREEN}✓ Export complete (${TOTAL_SIZE})${NC}"
echo ""

# Transfer files
echo -e "${YELLOW}Step 2: Transferring files to destination...${NC}"
echo "This may take a while depending on data size and network speed..."
echo ""

rsync -avz --progress \
    -e "ssh -o StrictHostKeyChecking=no" \
    "${SOURCE_DIR}/" \
    "${DEST_USER}@${DEST_HOST}:${DEST_DIR}/"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Transfer complete${NC}"
else
    echo -e "${RED}Error: Transfer failed${NC}"
    exit 1
fi
echo ""

# Copy import script to destination
echo -e "${YELLOW}Step 3: Copying import script to destination...${NC}"
if [ -f "destination-import.sh" ]; then
    scp destination-import.sh "${DEST_USER}@${DEST_HOST}:${DEST_DIR}/"
    echo -e "${GREEN}✓ Import script copied${NC}"
else
    echo -e "${YELLOW}⚠ destination-import.sh not found, skipping${NC}"
fi

# Copy verification script to destination
if [ -f "verify-migration.sh" ]; then
    scp verify-migration.sh "${DEST_USER}@${DEST_HOST}:${DEST_DIR}/"
    echo -e "${GREEN}✓ Verification script copied${NC}"
else
    echo -e "${YELLOW}⚠ verify-migration.sh not found, skipping${NC}"
fi
echo ""

# Summary
echo -e "${GREEN}=== Migration Transfer Complete ===${NC}"
echo ""
echo "Files transferred to: ${DEST_USER}@${DEST_HOST}:${DEST_DIR}"
echo "Total size: ${TOTAL_SIZE}"
echo ""
echo -e "${BLUE}Next steps on DESTINATION server:${NC}"
echo ""
echo "1. SSH to destination server:"
echo "   ${YELLOW}ssh ${DEST_USER}@${DEST_HOST}${NC}"
echo ""
echo "2. Run the import script:"
echo "   ${YELLOW}cd ${DEST_DIR}${NC}"
echo "   ${YELLOW}sudo bash destination-import.sh${NC}"
echo ""
echo "3. Review and run the container recreation script:"
echo "   ${YELLOW}cat ${DEST_DIR}/recreate-containers.sh${NC}"
echo "   ${YELLOW}bash ${DEST_DIR}/recreate-containers.sh${NC}"
echo ""
echo "4. Verify the migration:"
echo "   ${YELLOW}bash ${DEST_DIR}/verify-migration.sh${NC}"
echo ""
echo -e "${GREEN}Source server containers are stopped.${NC}"
echo -e "${YELLOW}Keep them stopped until migration is verified successful!${NC}"