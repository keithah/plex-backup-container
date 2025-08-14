FROM alpine:latest

# Install required packages
RUN apk add --no-cache \
    curl \
    rsync \
    nfs-utils \
    sqlite \
    bash \
    docker-cli \
    python3 \
    py3-pip \
    wget \
    dcron \
    tzdata \
    && rm -rf /var/cache/apk/*

# Download ChuckPa's DBRepair tool
RUN wget -O /usr/local/bin/DBRepair.sh https://raw.githubusercontent.com/ChuckPa/PlexDBRepair/master/DBRepair.sh \
    && chmod +x /usr/local/bin/DBRepair.sh

# Create backup script directory
RUN mkdir -p /scripts

# Copy backup script
COPY backup-script.sh /scripts/backup-script.sh
RUN chmod +x /scripts/backup-script.sh

# Create directories for backups and logs
RUN mkdir -p /var/log/backup

# Set timezone
ENV TZ=America/Los_Angeles
RUN cp /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Environment variables
ENV HOSTNAME=""
ENV BACKUP_SCHEDULE="0 2 * * *"
ENV PLEX_CONTAINER="plex"
ENV CONFIG_PATH="/config"
ENV NFS_SERVER="hadm.net"
ENV NFS_PATH="/storage"
ENV NFS_MOUNT="/mnt/nfs"
ENV BACKUP_PATH="/storage/backups/docker"

# Create cron entry
RUN echo "0 2 * * * /scripts/backup-script.sh >> /var/log/backup/backup.log 2>&1" > /etc/crontabs/root

# Start cron daemon and keep container running
CMD ["sh", "-c", "crond -f -d 8"]