#!/bin/bash

# Multi-Container Docker Backup Script
# Handles Plex, Tautulli, and other containers with special SQLite database handling

set -e

# Configuration
HOSTNAME="${HOSTNAME:-$(hostname)}"
CONFIG_PATH="${CONFIG_PATH:-/config/plex}"  # Updated to match actual Plex config path
NFS_SERVER="${NFS_SERVER:-hadm.net}"
NFS_PATH="${NFS_PATH:-/storage}"
NFS_MOUNT="${NFS_MOUNT:-/mnt/nfs}"
LOG_FILE="/var/log/backup/backup.log"
LOCK_FILE="/var/run/multi-container-backup.lock"
HISTORY_FILE="$NFS_MOUNT/backups/docker/.backup-history.csv"

# Arrays to track containers by type
declare -A CONTAINER_TYPES
declare -a ALL_CONTAINERS
declare -a STOPPED_CONTAINERS

# Container configurations based on actual docker-compose setup
# Format: "image_pattern:config_host_path:db_path_relative_to_config:needs_maintenance:description"
CONTAINER_CONFIGS=(
    "plex:/config/plex:Library/Application Support/Plex Media Server/Plug-in Support/Databases:true:Plex Media Server"
    "tautulli:/config/tautulli:tautulli.db:false:Plex Statistics and Monitoring"
    "netdata:/config/netdata:netdatadb:false:System Monitoring (netdata databases)"
    "caddy:/config/caddy:Caddyfile:false:Reverse Proxy Configuration"
    "tailscale:/config/tailscale:tailscaled.state:false:VPN State File"
    "watchtower:none:none:false:Container Updater (no config backup needed)"
    "autoheal:none:none:false:Container Health Monitor (no config backup needed)"
)

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
    
    # Remove lock file
    rm -f "$LOCK_FILE"
    
    # Unmount NFS if mounted
    if mountpoint -q "$NFS_MOUNT" 2>/dev/null; then
        log "Unmounting NFS: $NFS_MOUNT"
        umount "$NFS_MOUNT" || log "WARNING: Failed to unmount NFS"
    fi
    
    # Start all stopped containers
    for container in "${STOPPED_CONTAINERS[@]}"; do
        log "Starting container: $container"
        docker start "$container" || log "WARNING: Failed to start container $container"
    done
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Function to check available space
check_available_space() {
    local mount_point="$1"
    local required_gb="${2:-10}"  # Default 10GB minimum
    
    local available_space=$(df -BG "$mount_point" | awk 'NR==2 {print $4}' | sed 's/G//')
    
    if [ "$available_space" -lt "$required_gb" ]; then
        error_exit "Insufficient space on $mount_point: ${available_space}GB available, ${required_gb}GB required"
    fi
    
    log "Available space on $mount_point: ${available_space}GB"
}

# Function to discover containers by type
discover_containers() {
    log "Discovering containers by image type..."
    
    # Process each container configuration
    for config in "${CONTAINER_CONFIGS[@]}"; do
        IFS=':' read -r pattern config_path db_path needs_maint description <<< "$config"
        
        # Skip containers that don't need backup
        if [[ "$config_path" == "none" ]]; then
            log "Skipping $pattern - $description (no backup needed)"
            continue
        fi
        
        # Find all containers matching this pattern
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                container=$(echo "$line" | cut -d' ' -f1)
                image=$(echo "$line" | cut -d' ' -f2-)
                
                # Store container with its type info
                CONTAINER_TYPES["$container"]="$pattern:$config_path:$db_path:$needs_maint:$description"
                ALL_CONTAINERS+=("$container")
                
                log "Found $pattern container: $container ($description) - Image: $image"
            fi
        done < <(docker ps -a --format "{{.Names}} {{.Image}}" | grep -i "$pattern")
    done
    
    if [ ${#ALL_CONTAINERS[@]} -eq 0 ]; then
        error_exit "No containers found matching configured patterns"
    fi
    
    log "Total containers discovered for backup: ${#ALL_CONTAINERS[@]}"
}

# Function to stop container with timeout
stop_container_with_timeout() {
    local container="$1"
    local timeout="${2:-30}"
    
    log "Stopping container: $container (timeout: ${timeout}s)"
    
    if timeout "$timeout" docker stop "$container" 2>/dev/null; then
        return 0
    else
        log "Container $container did not stop gracefully, forcing..."
        docker kill "$container" 2>/dev/null || return 1
    fi
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

# Function to copy container databases/config files while stopped
copy_container_databases() {
    local container="$1"
    local backup_target="$2"
    
    # Get container configuration
    local config="${CONTAINER_TYPES[$container]}"
    if [[ -z "$config" ]]; then
        log "WARNING: No configuration found for container $container"
        return
    fi
    
    IFS=':' read -r pattern config_path db_path needs_maint description <<< "$config"
    
    log "Copying critical files for $container ($description)"
    
    # Create backup directory for this container
    local container_backup_dir="$backup_target/$container"
    mkdir -p "$container_backup_dir"
    
    # Handle different file types based on container
    case "$pattern" in
        "plex")
            # Plex: Copy entire database directory
            local db_full_path="$config_path/$db_path"
            if [[ -d "$(dirname "$db_full_path")" ]]; then
                log "Copying Plex databases: $db_full_path"
                mkdir -p "$container_backup_dir/databases"
                find "$(dirname "$db_full_path")" -name "*.db*" -type f -exec cp -v {} "$container_backup_dir/databases/" \; 2>/dev/null || true
            else
                log "WARNING: Plex database directory not found: $(dirname "$db_full_path")"
            fi
            ;;
        "tautulli")
            # Tautulli: Copy SQLite database
            if [[ -f "$config_path/$db_path" ]]; then
                log "Copying Tautulli database: $config_path/$db_path"
                cp -v "$config_path/$db_path"* "$container_backup_dir/" 2>/dev/null || true
            else
                log "WARNING: Tautulli database not found: $config_path/$db_path"
            fi
            ;;
        "netdata")
            # Netdata: Copy database directory
            if [[ -d "$config_path/lib" ]]; then
                log "Copying Netdata databases"
                mkdir -p "$container_backup_dir/databases"
                find "$config_path/lib" -name "*.db*" -type f -exec cp -v {} "$container_backup_dir/databases/" \; 2>/dev/null || true
                # Also copy registry files
                find "$config_path/lib/registry" -type f -exec cp -v {} "$container_backup_dir/databases/" \; 2>/dev/null || true
            else
                log "WARNING: Netdata database directory not found: $config_path/lib"
            fi
            ;;
        "caddy")
            # Caddy: Copy important config files
            if [[ -d "$config_path" ]]; then
                log "Copying Caddy configuration and certificates"
                # Copy certificates and config
                rsync -av "$config_path/" "$container_backup_dir/" --exclude="*.log" --exclude="locks" 2>/dev/null || true
            else
                log "WARNING: Caddy config directory not found: $config_path"
            fi
            ;;
        "tailscale")
            # Tailscale: Copy state file
            if [[ -f "$config_path/$db_path" ]]; then
                log "Copying Tailscale state: $config_path/$db_path"
                cp -v "$config_path/$db_path" "$container_backup_dir/" 2>/dev/null || true
            else
                log "WARNING: Tailscale state file not found: $config_path/$db_path"
            fi
            ;;
        *)
            log "WARNING: Unknown container pattern: $pattern"
            ;;
    esac
}

# Function to perform Plex-specific database maintenance
perform_plex_maintenance() {
    local config_path="$1"
    local container_name="$2"
    
    log "Running Plex database maintenance for container: $container_name"
    
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

# Function to verify backup
verify_backup() {
    local backup_target="$1"
    local errors=0
    
    log "=== Verifying backup integrity ==="
    
    # Check critical Plex files (from rsync backup)
    if [[ -f "$backup_target/Preferences.xml" ]]; then
        log "✓ Plex Preferences.xml present"
    else
        log "✗ WARNING: Plex Preferences.xml missing!"
        ((errors++))
    fi
    
    if [[ -d "$backup_target/Metadata" ]]; then
        log "✓ Plex Metadata directory present"
    else
        log "✗ WARNING: Plex Metadata directory missing!"
        ((errors++))
    fi
    
    # Check for container-specific critical files
    for container in "${ALL_CONTAINERS[@]}"; do
        local config="${CONTAINER_TYPES[$container]}"
        IFS=':' read -r pattern config_path db_path needs_maint description <<< "$config"
        
        if [[ -d "$backup_target/$container" ]]; then
            case "$pattern" in
                "plex")
                    local db_count=$(find "$backup_target/$container/databases" -name "*.db" -type f 2>/dev/null | wc -l)
                    if [ "$db_count" -gt 0 ]; then
                        log "✓ $container: $db_count Plex database(s) backed up"
                    else
                        log "✗ WARNING: No Plex databases found for $container"
                        ((errors++))
                    fi
                    ;;
                "tautulli")
                    if [[ -f "$backup_target/$container/tautulli.db" ]]; then
                        log "✓ $container: Tautulli database backed up"
                    else
                        log "✗ WARNING: Tautulli database missing for $container"
                        ((errors++))
                    fi
                    ;;
                "netdata")
                    local db_count=$(find "$backup_target/$container/databases" -name "*.db*" -type f 2>/dev/null | wc -l)
                    if [ "$db_count" -gt 0 ]; then
                        log "✓ $container: $db_count Netdata database(s) backed up"
                    else
                        log "⚠ INFO: No Netdata databases found for $container (may be normal)"
                    fi
                    ;;
                "caddy")
                    if [[ -d "$backup_target/$container" ]]; then
                        log "✓ $container: Caddy configuration backed up"
                    else
                        log "✗ WARNING: Caddy configuration missing for $container"
                        ((errors++))
                    fi
                    ;;
                "tailscale")
                    if [[ -f "$backup_target/$container/tailscaled.state" ]]; then
                        log "✓ $container: Tailscale state backed up"
                    else
                        log "⚠ INFO: Tailscale state missing for $container (may be normal if not configured)"
                    fi
                    ;;
            esac
        else
            log "✗ WARNING: No backup directory found for $container"
            ((errors++))
        fi
    done
    
    return $errors
}

# Create log directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"

log "=== Starting Multi-Container Docker Backup Process ==="
log "Hostname: $HOSTNAME"
log "Backup Time: $(date)"

# Check lock file
if [ -f "$LOCK_FILE" ]; then
    error_exit "Backup already running (lock file exists: $LOCK_FILE)"
fi
touch "$LOCK_FILE"

# Check if Docker socket is accessible
if ! docker ps >/dev/null 2>&1; then
    error_exit "Cannot access Docker daemon. Is docker.sock mounted?"
fi

# Discover all configured containers
discover_containers

# Check which containers are running and stop them
for container in "${ALL_CONTAINERS[@]}"; do
    if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
        if stop_container_with_timeout "$container"; then
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

# Check available space on NFS
check_available_space "$NFS_MOUNT" 20

# Create backup directory structure
BACKUP_TARGET="$NFS_MOUNT/backups/docker/$HOSTNAME"
mkdir -p "$BACKUP_TARGET"
log "Backup target: $BACKUP_TARGET"

# Perform container-specific maintenance and database copying
log "=== Processing container maintenance and database backups ==="

for container in "${ALL_CONTAINERS[@]}"; do
    log "--- Processing container: $container ---"
    
    # Get container configuration
    config="${CONTAINER_TYPES[$container]}"
    IFS=':' read -r pattern config_path db_path needs_maint description <<< "$config"
    
    # Perform maintenance if needed (only Plex containers for now)
    if [[ "$needs_maint" == "true" ]] && [[ "$pattern" == "plex" ]]; then
        perform_plex_maintenance "$config_path" "$container"
    fi
    
    # Copy critical files while container is stopped
    copy_container_databases "$container" "$BACKUP_TARGET"
done

log "Database operations completed for all containers"

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

# Perform rsync backup of the remaining config files (excluding databases already copied)
log "=== Starting rsync backup of remaining config files ==="

# Create exclude file for rsync (excluding databases we already copied)
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
Plug-in Support/Databases/
Plug-in Support/Data/com.plexapp.system/DataItems/
Media/localhost/
EOF

# Skip backup if config path doesn't exist
if [[ ! -d "$CONFIG_PATH" ]]; then
    error_exit "Config path does not exist: $CONFIG_PATH"
fi

log "Syncing remaining config files to: $BACKUP_TARGET"
log "Note: SQLite databases already copied while containers were stopped"

# Simple rsync - sync everything except databases (which we already copied)
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
    log "Rsync backup of config files completed successfully"
    
    # Get backup size
    BACKUP_SIZE=$(du -sh "$BACKUP_TARGET" 2>/dev/null | cut -f1)
    log "Total backup size: $BACKUP_SIZE"
else
    error_exit "Rsync backup failed"
fi

log "Config directory synchronization completed successfully"

# Cleanup temporary files
rm -f "$EXCLUDE_FILE"

# Verify backup integrity
if verify_backup "$BACKUP_TARGET"; then
    log "Backup verification passed"
    BACKUP_STATUS="success"
else
    log "WARNING: Backup verification detected issues"
    BACKUP_STATUS="warning"
fi

# Log backup history
mkdir -p "$(dirname "$HISTORY_FILE")"
if [ ! -f "$HISTORY_FILE" ]; then
    echo "timestamp,hostname,containers,size,status" > "$HISTORY_FILE"
fi
echo "$(date -Iseconds),$HOSTNAME,${#ALL_CONTAINERS[@]},$BACKUP_SIZE,$BACKUP_STATUS" >> "$HISTORY_FILE"

log "=== Multi-Container backup process completed ==="
log "Processed containers: ${ALL_CONTAINERS[*]}"
log "Total containers: ${#ALL_CONTAINERS[@]}"
log "Backup location: $BACKUP_TARGET"
log "Backup size: $BACKUP_SIZE"
log "Status: $BACKUP_STATUS"

# Send success notification (optional - can be extended)
if command -v curl >/dev/null 2>&1 && [ -n "${NOTIFICATION_URL:-}" ]; then
    container_list="${ALL_CONTAINERS[*]}"
    curl -s -X POST "$NOTIFICATION_URL" -d "Multi-container backup completed for $HOSTNAME. Status: $BACKUP_STATUS. Containers: $container_list. Size: $BACKUP_SIZE" >/dev/null || true
fi

# Return appropriate exit code
if [[ "$BACKUP_STATUS" == "success" ]]; then
    exit 0
else
    exit 1
fi