#!/bin/bash

# Plex Docker Container Backup Script
# Integrates with ChuckPa's DBRepair tool for database maintenance
# Handles multiple Plex containers and empties trash

set -e

# Configuration
HOSTNAME="${HOSTNAME:-$(hostname)}"
PLEX_CONTAINER_PATTERN="${PLEX_CONTAINER_PATTERN:-plex}"
CONFIG_PATH="${CONFIG_PATH:-/config}"
NFS_SERVER="${NFS_SERVER:-hadm.net}"
NFS_PATH="${NFS_PATH:-/storage}"
NFS_MOUNT="${NFS_MOUNT:-/mnt/nfs}"
BACKUP_PATH="${BACKUP_PATH:-/storage/backups/docker}"
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

# Function to discover Plex containers
discover_plex_containers() {
    log "Discovering Plex containers..."
    
    # Find all containers that match the pattern
    while IFS= read -r container; do
        if [[ -n "$container" ]]; then
            PLEX_CONTAINERS+=("$container")
            log "Found Plex container: $container"
        fi
    done < <(docker ps -a --format "{{.Names}}" | grep -i "$PLEX_CONTAINER_PATTERN")
    
    if [ ${#PLEX_CONTAINERS[@]} -eq 0 ]; then
        error_exit "No Plex containers found matching pattern: $PLEX_CONTAINER_PATTERN"
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
log "Plex Container Pattern: $PLEX_CONTAINER_PATTERN"
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

# Create backup directory
BACKUP_DIR="$NFS_MOUNT/backups/docker/$HOSTNAME"
mkdir -p "$BACKUP_DIR"
log "Backup directory: $BACKUP_DIR"

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

# Perform incremental backup of the shared config directory
log "Starting incremental backup with rsync"
CURRENT_DATE=$(date +%Y-%m-%d_%H-%M-%S)
LATEST_LINK="$BACKUP_DIR/latest"

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

log "Backing up shared config directory: $CONFIG_PATH"
BACKUP_TARGET="$BACKUP_DIR/$CURRENT_DATE"

log "Creating backup: $BACKUP_TARGET"

# Build rsync command with proper options for incremental backup (only differences)
rsync_cmd=(
    rsync
    -avH
    --numeric-ids
    --delete
    --delete-excluded
    --exclude-from="$EXCLUDE_FILE"
    --link-dest="$LATEST_LINK"
    "$CONFIG_PATH/"
    "$BACKUP_TARGET/"
)

if "${rsync_cmd[@]}"; then
    log "Rsync backup completed successfully"
    
    # Update latest symlink
    rm -f "$LATEST_LINK"
    ln -s "$CURRENT_DATE" "$LATEST_LINK"
    log "Updated latest backup symlink"
    
    # Get backup size
    BACKUP_SIZE=$(du -sh "$BACKUP_TARGET" 2>/dev/null | cut -f1)
    log "Backup size: $BACKUP_SIZE"
else
    error_exit "Rsync backup failed"
fi

log "Backup completed for all Plex containers (shared config)"

# Cleanup old backups (keep last 7 days)
log "Cleaning up old backups (keeping last 7 days)"
find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" -mtime +7 -exec rm -rf {} \; 2>/dev/null || true

# Generate backup report
TOTAL_BACKUPS=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" | wc -l)
log "Backup cleanup completed. Total backups: $TOTAL_BACKUPS"

# Cleanup temporary files
rm -f "$EXCLUDE_FILE"

log "=== Multi-Plex backup process completed successfully ==="
log "Processed containers: ${PLEX_CONTAINERS[*]}"
log "Backup location: $BACKUP_TARGET"
log "Latest backup link: $LATEST_LINK"

# Send success notification (optional - can be extended)
if command -v curl >/dev/null 2>&1 && [ -n "${NOTIFICATION_URL:-}" ]; then
    container_list="${PLEX_CONTAINERS[*]}"
    curl -s -X POST "$NOTIFICATION_URL" -d "Multi-Plex backup completed successfully for $HOSTNAME. Processed containers: $container_list" >/dev/null || true
fi

# Return success
exit 0