#!/bin/bash

# Plex Backup Setup Script

set -e

echo "=== Plex Backup Solution Setup ==="

# Create required directories
echo "Creating required directories..."
mkdir -p config logs homebridge

# Set proper permissions
echo "Setting permissions..."
chmod +x backup-script.sh

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker is not installed or not in PATH"
    exit 1
fi

# Check if docker-compose is available
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo "ERROR: docker-compose is not installed"
    exit 1
fi

# Verify docker.sock access
if [ ! -S /var/run/docker.sock ]; then
    echo "ERROR: Docker socket not found at /var/run/docker.sock"
    exit 1
fi

# Check network connectivity to NFS server
echo "Testing NFS server connectivity..."
if ! ping -c 1 hadm.net &> /dev/null; then
    echo "WARNING: Cannot reach NFS server hadm.net"
    echo "Please verify network connectivity and NFS server availability"
fi

echo ""
echo "Setup completed successfully!"
echo ""
echo "Next steps:"
echo "1. Edit docker-compose.yaml to configure your environment variables"
echo "2. Update HOSTNAME, PLEX_CONTAINER name, and paths as needed"
echo "3. Run: docker-compose up -d"
echo "4. Test with: docker exec plex-backup /scripts/backup-script.sh"
echo ""
echo "Monitor logs with: tail -f logs/backup.log"