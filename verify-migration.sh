#!/bin/bash

# Podman Migration Verification Script
# Run this on the DESTINATION server after importing
# Usage: ./verify-migration.sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Podman Migration Verification ===${NC}"
echo "Generated: $(date)"
echo "Host: $(hostname)"
echo ""

# Check if podman is available
if ! command -v podman &> /dev/null; then
    echo -e "${RED}Error: podman command not found${NC}"
    exit 1
fi

# 1. Check loaded images
echo -e "${BLUE}1. Checking loaded images:${NC}"
IMAGE_COUNT=$(podman images | tail -n +2 | wc -l)
if [ "$IMAGE_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ Found ${IMAGE_COUNT} images${NC}"
    podman images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.Created}}"
else
    echo -e "${RED}✗ No images found${NC}"
fi
echo ""

# 2. Check containers
echo -e "${BLUE}2. Checking containers:${NC}"
CONTAINER_COUNT=$(podman ps -a | tail -n +2 | wc -l)
if [ "$CONTAINER_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ Found ${CONTAINER_COUNT} containers${NC}"
    podman ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
else
    echo -e "${YELLOW}⚠ No containers found (may need to be created)${NC}"
fi
echo ""

# 3. Check running containers
echo -e "${BLUE}3. Checking running containers:${NC}"
RUNNING_COUNT=$(podman ps | tail -n +2 | wc -l)
if [ "$RUNNING_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ ${RUNNING_COUNT} containers running${NC}"
    podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
else
    echo -e "${YELLOW}⚠ No containers running${NC}"
fi
echo ""

# 4. Check container logs
if [ "$CONTAINER_COUNT" -gt 0 ]; then
    echo -e "${BLUE}4. Checking container logs (last 5 lines each):${NC}"
    for container in $(podman ps -a --format "{{.Names}}"); do
        echo -e "${YELLOW}--- Logs for: $container ---${NC}"
        STATUS=$(podman inspect "$container" --format='{{.State.Status}}')
        echo "Status: $STATUS"
        
        if [ "$STATUS" = "running" ]; then
            podman logs --tail 5 "$container" 2>&1 || echo -e "${RED}No logs available${NC}"
        else
            echo -e "${YELLOW}Container not running${NC}"
        fi
        echo ""
    done
else
    echo -e "${YELLOW}4. Skipping log check (no containers)${NC}"
    echo ""
fi

# 5. Check volume mounts
if [ "$CONTAINER_COUNT" -gt 0 ]; then
    echo -e "${BLUE}5. Checking volume mounts:${NC}"
    for container in $(podman ps -a --format "{{.Names}}"); do
        echo -e "${YELLOW}--- Volumes for: $container ---${NC}"
        MOUNTS=$(podman inspect "$container" --format='{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Type}}){{"\n"}}{{end}}')
        
        if [ -n "$MOUNTS" ]; then
            echo "$MOUNTS"
            
            # Check if volume paths exist and have content
            while IFS= read -r mount; do
                if [[ "$mount" =~ ^(.+)\ -\>\ (.+)\ \((.+)\)$ ]]; then
                    SOURCE="${BASH_REMATCH[1]}"
                    if [ -d "$SOURCE" ]; then
                        FILE_COUNT=$(find "$SOURCE" -type f 2>/dev/null | wc -l)
                        SIZE=$(du -sh "$SOURCE" 2>/dev/null | cut -f1)
                        echo "  ✓ Path exists: $SOURCE (${FILE_COUNT} files, ${SIZE})"
                    else
                        echo -e "  ${RED}✗ Path not found: $SOURCE${NC}"
                    fi
                fi
            done <<< "$MOUNTS"
        else
            echo "No volumes mounted"
        fi
        echo ""
    done
else
    echo -e "${YELLOW}5. Skipping volume check (no containers)${NC}"
    echo ""
fi

# 6. Check port bindings
if [ "$RUNNING_COUNT" -gt 0 ]; then
    echo -e "${BLUE}6. Checking port bindings:${NC}"
    for container in $(podman ps --format "{{.Names}}"); do
        echo -e "${YELLOW}--- Ports for: $container ---${NC}"
        PORTS=$(podman port "$container" 2>/dev/null)
        
        if [ -n "$PORTS" ]; then
            echo "$PORTS"
            
            # Test if ports are listening
            while IFS= read -r port_line; do
                if [[ "$port_line" =~ ([0-9]+)/tcp\ -\>\ 0.0.0.0:([0-9]+) ]]; then
                    HOST_PORT="${BASH_REMATCH[2]}"
                    if ss -tuln | grep -q ":${HOST_PORT} "; then
                        echo -e "  ${GREEN}✓ Port ${HOST_PORT} is listening${NC}"
                    else
                        echo -e "  ${RED}✗ Port ${HOST_PORT} not listening${NC}"
                    fi
                fi
            done <<< "$PORTS"
        else
            echo "No ports exposed"
        fi
        echo ""
    done
else
    echo -e "${YELLOW}6. Skipping port check (no running containers)${NC}"
    echo ""
fi

# 7. Check networks
echo -e "${BLUE}7. Checking networks:${NC}"
NETWORKS=$(podman network ls --format "{{.Name}}" | grep -v "^podman$")
if [ -n "$NETWORKS" ]; then
    echo -e "${GREEN}✓ Custom networks found${NC}"
    podman network ls --format "table {{.Name}}\t{{.Driver}}\t{{.ID}}"
else
    echo -e "${YELLOW}⚠ No custom networks (using default)${NC}"
fi
echo ""

# 8. Resource usage
if [ "$RUNNING_COUNT" -gt 0 ]; then
    echo -e "${BLUE}8. Resource usage:${NC}"
    podman stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
    echo ""
else
    echo -e "${YELLOW}8. Skipping resource check (no running containers)${NC}"
    echo ""
fi

# Summary
echo -e "${GREEN}=== Verification Summary ===${NC}"
echo "Images: ${IMAGE_COUNT}"
echo "Containers (total): ${CONTAINER_COUNT}"
echo "Containers (running): ${RUNNING_COUNT}"
echo ""

# Overall status
ISSUES=0

if [ "$IMAGE_COUNT" -eq 0 ]; then
    echo -e "${RED}✗ No images loaded${NC}"
    ISSUES=$((ISSUES + 1))
fi

if [ "$CONTAINER_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}⚠ No containers created yet${NC}"
    ISSUES=$((ISSUES + 1))
fi

if [ "$CONTAINER_COUNT" -gt 0 ] && [ "$RUNNING_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}⚠ Containers exist but none are running${NC}"
    ISSUES=$((ISSUES + 1))
fi

if [ "$ISSUES" -eq 0 ] && [ "$RUNNING_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ Migration appears successful!${NC}"
    echo ""
    echo "Recommended next steps:"
    echo "1. Test application functionality"
    echo "2. Check application logs for errors"
    echo "3. Verify data integrity"
    echo "4. Update DNS/load balancer if needed"
    echo "5. Monitor for 24-48 hours before decommissioning source"
elif [ "$CONTAINER_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}⚠ Containers need to be created${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Run the container recreation script:"
    echo "   bash /tmp/podman-migration/recreate-containers.sh"
    echo "2. Run this verification script again"
else
    echo -e "${YELLOW}⚠ Some issues detected${NC}"
    echo ""
    echo "Troubleshooting steps:"
    echo "1. Check container logs: podman logs <container_name>"
    echo "2. Try starting stopped containers: podman start <container_name>"
    echo "3. Check volume permissions: ls -la /path/to/volume"
    echo "4. Verify image availability: podman images"
fi

echo ""
echo -e "${BLUE}For detailed troubleshooting, check:${NC}"
echo "- Container logs: podman logs <container_name>"
echo "- Container inspect: podman inspect <container_name>"
echo "- System events: podman events --since 1h"
echo "- System info: podman info"