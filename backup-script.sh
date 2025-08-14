#!/bin/bash

# Plex Docker Container Backup Script
# Integrates with ChuckPa's DBRepair tool for database maintenance

set -e

# Configuration
HOSTNAME="${HOSTNAME:-$(hostname)}"
PLEX_CONTAINER="${PLEX_CONTAINER:-plex}"
CONFIG_PATH="${CONFIG_PATH:-/config}"
NFS_SERVER="${NFS_SERVER:-hadm.net}"
NFS_PATH="${NFS_PATH:-/storage}"
NFS_MOUNT="${NFS_MOUNT:-/mnt/nfs}"
BACKUP_PATH="${BACKUP_PATH:-/storage/backups/docker}"
LOG_FILE="/var/log/backup/backup.log"

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
    
    # Start Plex container if it was stopped
    if [ "$PLEX_WAS_RUNNING" = "true" ]; then
        log "Starting Plex container: $PLEX_CONTAINER"
        docker start "$PLEX_CONTAINER" || log "WARNING: Failed to start Plex container"
    fi
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Create log directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"

log "=== Starting Plex backup process ==="
log "Hostname: $HOSTNAME"
log "Plex Container: $PLEX_CONTAINER"
log "Config Path: $CONFIG_PATH"

# Check if Docker socket is accessible
if ! docker ps >/dev/null 2>&1; then
    error_exit "Cannot access Docker daemon. Is docker.sock mounted?"
fi

# Check if Plex container exists
if ! docker ps -a --format "{{.Names}}" | grep -q "^${PLEX_CONTAINER}$"; then
    error_exit "Plex container '$PLEX_CONTAINER' not found"
fi

# Check if Plex is running
PLEX_WAS_RUNNING="false"
if docker ps --format "{{.Names}}" | grep -q "^${PLEX_CONTAINER}$"; then
    PLEX_WAS_RUNNING="true"
    log "Plex container is running, will stop for maintenance"
else
    log "Plex container is not running"
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

# Stop Plex container for maintenance
if [ "$PLEX_WAS_RUNNING" = "true" ]; then
    log "Stopping Plex container for database maintenance"
    if ! docker stop "$PLEX_CONTAINER"; then
        error_exit "Failed to stop Plex container"
    fi
    
    # Wait for container to fully stop
    sleep 5
fi

# Run DBRepair tool for database maintenance
log "Running ChuckPa's DBRepair tool with PRUN/PURG operations"
DB_PATH="$CONFIG_PATH/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"

if [ -f "$DB_PATH" ]; then
    # Create backup of database before repair
    log "Creating database backup before repair"
    cp "$DB_PATH" "$DB_PATH.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Run DBRepair with PRUN and PURG operations
    log "Running DBRepair with PRUN operation"
    if ! /usr/local/bin/DBRepair.sh PRUN "$DB_PATH"; then
        log "WARNING: DBRepair PRUN operation failed or had issues"
    fi
    
    log "Running DBRepair with PURG operation"
    if ! /usr/local/bin/DBRepair.sh PURG "$DB_PATH"; then
        log "WARNING: DBRepair PURG operation failed or had issues"
    fi
    
    # Check for corruption
    log "Checking database for corruption"
    if sqlite3 "$DB_PATH" "PRAGMA integrity_check;" | grep -v "ok" >/dev/null; then
        log "WARNING: Database corruption detected"
        log "Running database repair..."
        sqlite3 "$DB_PATH" ".recover" | sqlite3 "$DB_PATH.repaired"
        if [ -f "$DB_PATH.repaired" ]; then
            mv "$DB_PATH" "$DB_PATH.corrupted.$(date +%Y%m%d_%H%M%S)"
            mv "$DB_PATH.repaired" "$DB_PATH"
            log "Database repaired and replaced"
        else
            log "ERROR: Database repair failed"
        fi
    else
        log "Database integrity check passed"
    fi
else
    log "WARNING: Plex database not found at expected path: $DB_PATH"
fi

# Start Plex container back up
if [ "$PLEX_WAS_RUNNING" = "true" ]; then
    log "Starting Plex container back up"
    if ! docker start "$PLEX_CONTAINER"; then
        error_exit "Failed to start Plex container"
    fi
    
    # Wait for container to start
    sleep 10
    
    # Verify container is running
    if ! docker ps --format "{{.Names}}" | grep -q "^${PLEX_CONTAINER}$"; then
        error_exit "Plex container failed to start properly"
    fi
    log "Plex container started successfully"
fi

# Perform incremental backup using rsync
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
Plug-in Support/Caches/
Plug-in Support/Data/com.plexapp.system/DataItems/
Media/localhost/
EOF

# Run rsync with incremental backup
BACKUP_TARGET="$BACKUP_DIR/$CURRENT_DATE"
log "Creating backup: $BACKUP_TARGET"

rsync_cmd=(
    rsync
    -avH
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
    BACKUP_SIZE=$(du -sh "$BACKUP_TARGET" | cut -f1)
    log "Backup size: $BACKUP_SIZE"
else
    error_exit "Rsync backup failed"
fi

# Cleanup old backups (keep last 7 days)
log "Cleaning up old backups (keeping last 7 days)"
find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" -mtime +7 -exec rm -rf {} \; 2>/dev/null || true

# Generate backup report
TOTAL_BACKUPS=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" | wc -l)
log "Backup cleanup completed. Total backups: $TOTAL_BACKUPS"

# Cleanup temporary files
rm -f "$EXCLUDE_FILE"

log "=== Backup process completed successfully ==="
log "Backup location: $BACKUP_TARGET"
log "Latest backup link: $LATEST_LINK"

# Send success notification (optional - can be extended)
if command -v curl >/dev/null 2>&1 && [ -n "${NOTIFICATION_URL:-}" ]; then
    curl -s -X POST "$NOTIFICATION_URL" -d "Plex backup completed successfully for $HOSTNAME" >/dev/null || true
fi

# Return success
exit 0