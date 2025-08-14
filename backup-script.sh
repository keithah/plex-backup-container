#!/bin/bash

# Plex Docker Container Backup Script
# Integrates with ChuckPa's DBRepair tool for database maintenance
# Handles multiple Plex containers and empties trash

set -e

# Configuration
HOSTNAME="${HOSTNAME:-$(hostname)}"
CONFIG_PATH="${CONFIG_PATH:-/config}"
NFS_SERVER="${NFS_SERVER:-hadm.net}"
NFS_PATH="${NFS_PATH:-/storage}"
NFS_MOUNT="${NFS_MOUNT:-/mnt/nfs}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
LOG_FILE="/var/log/backup/backup.log"

# Arrays to track multiple containers
declare -a PLEX_CONTAINERS
declare -a STOPPED_CONTAINERS

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Error handling function
error_exit() {
    log "ERROR: $1"
    cleanup
    exit 1
}

# Cleanup function
cleanup() {
    log "Performing cleanup..."
    
    # Unmount NFS if mounted
    if mountpoint -q "$NFS_MOUNT" 2>/dev/null; then
        log "Unmounting NFS: $NFS_MOUNT"
        umount "$NFS_MOUNT" || log "WARNING: Failed to unmount NFS"
    fi
    
    # Start all stopped Plex containers
    for container in "${STOPPED_CONTAINERS[@]}"; do
        log "Starting Plex container: $container"
        docker start "$container" || log "WARNING: Failed to start Plex container $container"
    done
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Function to discover Plex containers by image
discover_plex_containers() {
    log "Discovering Plex containers by image..."
    
    # Find all containers running Plex images
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            container=$(echo "$line" | cut -d' ' -f1)
            image=$(echo "$line" | cut -d' ' -f2-)
            PLEX_CONTAINERS+=("$container")
            log "Found Plex container: $container (image: $image)"
        fi
    done < <(docker ps -a --format "{{.Names}} {{.Image}}" | grep -i plex)
    
    if [ ${#PLEX_CONTAINERS[@]} -eq 0 ]; then
        error_exit "No Plex containers found (looking for containers with 'plex' in image name)"
    fi
    
    log "Total Plex containers found: ${#PLEX_CONTAINERS[@]}"
}

# Function to empty Plex trash
empty_plex_trash() {
    local config_path="$1"
    local container_name="$2"
    
    log "Emptying trash for container: $container_name"
    
    # Empty trash using Plex's database
    local db_path="$config_path/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"
    
    if [ -f "$db_path" ]; then
        # Empty the trash by deleting trashed items
        log "Removing trashed media items from database"
        sqlite3 "$db_path" "DELETE FROM metadata_items WHERE deleted_at IS NOT NULL;"
        sqlite3 "$db_path" "DELETE FROM media_items WHERE deleted_at IS NOT NULL;"
        sqlite3 "$db_path" "DELETE FROM media_parts WHERE deleted_at IS NOT NULL;"
        sqlite3 "$db_path" "VACUUM;"
        log "Trash emptied successfully for $container_name"
    else
        log "WARNING: Database not found for $container_name at: $db_path"
    fi
}

# Function to perform database maintenance
perform_db_maintenance() {
    local config_path="$1"
    local container_name="$2"
    
    log "Running database maintenance for container: $container_name"
    
    local db_path="$config_path/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"
    
    if [ -f "$db_path" ]; then
        # Create backup of database before repair
        log "Creating database backup before maintenance"
        cp "$db_path" "$db_path.backup.$(date +%Y%m%d_%H%M%S)"
        
        # Empty trash first
        empty_plex_trash "$config_path" "$container_name"
        
        # Run DBRepair with PRUN and PURG operations
        log "Running DBRepair with PRUN operation"
        if ! /usr/local/bin/DBRepair.sh PRUN "$db_path"; then
            log "WARNING: DBRepair PRUN operation failed or had issues"
        fi
        
        log "Running DBRepair with PURG operation"
        if ! /usr/local/bin/DBRepair.sh PURG "$db_path"; then
            log "WARNING: DBRepair PURG operation failed or had issues"
        fi
        
        # Check for corruption
        log "Checking database for corruption"
        if sqlite3 "$db_path" "PRAGMA integrity_check;" | grep -v "ok" >/dev/null; then
            log "WARNING: Database corruption detected"
            log "Running database repair..."
            sqlite3 "$db_path" ".recover" | sqlite3 "$db_path.repaired"
            if [ -f "$db_path.repaired" ]; then
                mv "$db_path" "$db_path.corrupted.$(date +%Y%m%d_%H%M%S)"
                mv "$db_path.repaired" "$db_path"
                log "Database repaired and replaced"
            else
                log "ERROR: Database repair failed"
            fi
        else
            log "Database integrity check passed"
        fi
    else
        log "WARNING: Plex database not found for $container_name at: $db_path"
    fi
}

# Create log directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"

log "=== Starting Multi-Plex backup process ==="
log "Hostname: $HOSTNAME"
log "Config Path: $CONFIG_PATH"

# Check if Docker socket is accessible
if ! docker ps >/dev/null 2>&1; then
    error_exit "Cannot access Docker daemon. Is docker.sock mounted?"
fi

# Discover all Plex containers
discover_plex_containers

# Check which containers are running and stop them
for container in "${PLEX_CONTAINERS[@]}"; do
    if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
        log "Stopping running Plex container: $container"
        if docker stop "$container"; then
            STOPPED_CONTAINERS+=("$container")
            log "Successfully stopped: $container"
        else
            log "WARNING: Failed to stop container: $container"
        fi
    else
        log "Container $container is already stopped"
    fi
done

# Wait for containers to fully stop
if [ ${#STOPPED_CONTAINERS[@]} -gt 0 ]; then
    log "Waiting for containers to fully stop..."
    sleep 10
fi

# Create NFS mount point
mkdir -p "$NFS_MOUNT"

# Mount NFS
log "Mounting NFS: $NFS_SERVER:$NFS_PATH to $NFS_MOUNT"
if ! mount -t nfs "$NFS_SERVER:$NFS_PATH" "$NFS_MOUNT"; then
    error_exit "Failed to mount NFS"
fi

# Verify NFS mount
if ! mountpoint -q "$NFS_MOUNT"; then
    error_exit "NFS mount verification failed"
fi

# Create backup directory structure
mkdir -p "$NFS_MOUNT/backups/docker"
log "NFS backup area ready: $NFS_MOUNT/backups/docker"

# Perform database maintenance (all containers share the same config directory)
log "=== Running database maintenance on shared config directory ==="
log "Config path: $CONFIG_PATH"

# Process database maintenance for all containers (they share the same database)
for container in "${PLEX_CONTAINERS[@]}"; do
    log "Processing database maintenance for container: $container"
    perform_db_maintenance "$CONFIG_PATH" "$container"
    
    # Since all containers share the same database, we only need to run this once
    # But we'll log each container for tracking purposes
    break
done

log "Database maintenance completed for all containers"

# Start all stopped containers back up
for container in "${STOPPED_CONTAINERS[@]}"; do
    log "Starting Plex container back up: $container"
    if ! docker start "$container"; then
        log "WARNING: Failed to start Plex container $container"
    else
        log "Successfully started: $container"
    fi
done

# Wait for containers to start and verify
if [ ${#STOPPED_CONTAINERS[@]} -gt 0 ]; then
    log "Waiting for containers to start up..."
    sleep 15
    
    # Verify containers are running
    for container in "${STOPPED_CONTAINERS[@]}"; do
        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
            log "Container $container is running successfully"
        else
            log "WARNING: Container $container may not have started properly"
        fi
    done
fi

# Perform simple rsync backup of the shared config directory
log "Starting rsync backup of config directory"

# Create exclude file for rsync
EXCLUDE_FILE="/tmp/rsync_excludes"
cat > "$EXCLUDE_FILE" << EOF
Cache/
Codecs/
Crash Reports/
Diagnostics/
Logs/
Updates/
*.log
*.tmp
*.lock
*.backup.*
*.corrupted.*
Plug-in Support/Caches/
Plug-in Support/Data/com.plexapp.system/DataItems/
Media/localhost/
EOF

# Skip backup if config path doesn't exist
if [[ ! -d "$CONFIG_PATH" ]]; then
    error_exit "Config path does not exist: $CONFIG_PATH"
fi

# Backup directly to /storage/backups/docker/$HOSTNAME/ (no timestamps)
BACKUP_TARGET="$NFS_MOUNT/backups/docker/$HOSTNAME"
mkdir -p "$BACKUP_TARGET"

log "Syncing config to: $BACKUP_TARGET"

# Simple rsync - just sync the differences
rsync_cmd=(
    rsync
    -av
    --delete
    --delete-excluded
    --exclude-from="$EXCLUDE_FILE"
    "$CONFIG_PATH/"
    "$BACKUP_TARGET/"
)

if "${rsync_cmd[@]}"; then
    log "Rsync backup completed successfully"
    
    # Get backup size
    BACKUP_SIZE=$(du -sh "$BACKUP_TARGET" 2>/dev/null | cut -f1)
    log "Backup size: $BACKUP_SIZE"
else
    error_exit "Rsync backup failed"
fi

log "Config directory synchronized successfully"

# Cleanup temporary files
rm -f "$EXCLUDE_FILE"

log "=== Multi-Plex backup process completed successfully ==="
log "Processed containers: ${PLEX_CONTAINERS[*]}"
log "Backup location: $BACKUP_TARGET"

# Send success notification (optional - can be extended)
if command -v curl >/dev/null 2>&1 && [ -n "${NOTIFICATION_URL:-}" ]; then
    container_list="${PLEX_CONTAINERS[*]}"
    curl -s -X POST "$NOTIFICATION_URL" -d "Multi-Plex backup completed successfully for $HOSTNAME. Processed containers: $container_list" >/dev/null || true
fi

# Return success
exit 0