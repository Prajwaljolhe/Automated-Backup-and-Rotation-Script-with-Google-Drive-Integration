#!/bin/bash

set -u

# ==========================================================
# Automated Backup and Google Drive Rotation Script
# ==========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/backup.conf"
LOG_FILE="$SCRIPT_DIR/backup.log"

# ----------------------------------------------------------
# Load configuration
# ----------------------------------------------------------

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# ----------------------------------------------------------
# Command-line options
# ----------------------------------------------------------

NO_NOTIFY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-notify)
            NO_NOTIFY=true
            shift
            ;;
        --help)
            echo "Usage:"
            echo "  $0"
            echo "  $0 --no-notify"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ----------------------------------------------------------
# Logging function
# ----------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ----------------------------------------------------------
# Validate configuration
# ----------------------------------------------------------

if [ ! -d "$SOURCE_DIR" ]; then
    log "ERROR: Source directory does not exist: $SOURCE_DIR"
    exit 1
fi

if ! command -v zip >/dev/null 2>&1; then
    log "ERROR: zip command not installed."
    exit 1
fi

if ! command -v rclone >/dev/null 2>&1; then
    log "ERROR: rclone command not installed."
    exit 1
fi

# ----------------------------------------------------------
# Timestamp
# ----------------------------------------------------------

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
YEAR=$(date '+%Y')
MONTH=$(date '+%m')
DAY=$(date '+%d')

BACKUP_FILENAME="${PROJECT_NAME}_${TIMESTAMP}.zip"

# ----------------------------------------------------------
# Local backup directory
# ----------------------------------------------------------

BACKUP_DIR="$BACKUP_BASE/$PROJECT_NAME/$YEAR/$MONTH/$DAY"

mkdir -p "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/$BACKUP_FILENAME"

# ----------------------------------------------------------
# Start backup
# ----------------------------------------------------------

log "=========================================================="
log "Starting backup"
log "Project       : $PROJECT_NAME"
log "Source        : $SOURCE_DIR"
log "Backup file   : $BACKUP_FILE"
log "=========================================================="

# ----------------------------------------------------------
# Create ZIP
# ----------------------------------------------------------

log "Creating ZIP archive..."

SOURCE_PARENT=$(dirname "$SOURCE_DIR")
SOURCE_NAME=$(basename "$SOURCE_DIR")

if (
    cd "$SOURCE_PARENT" &&
    zip -r "$BACKUP_FILE" "$SOURCE_NAME" \
        -x "$SOURCE_NAME/.git/*"
); then

    log "ZIP backup created successfully."

else

    log "ERROR: ZIP creation failed."
    exit 1

fi

# ----------------------------------------------------------
# Check backup file
# ----------------------------------------------------------

if [ ! -f "$BACKUP_FILE" ]; then
    log "ERROR: Backup file was not created."
    exit 1
fi

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | awk '{print $1}')

log "Backup size: $BACKUP_SIZE"

# ----------------------------------------------------------
# Upload to Google Drive
# ----------------------------------------------------------

log "Uploading backup to Google Drive..."

if rclone copy "$BACKUP_FILE" \
    "$RCLONE_REMOTE:$DRIVE_FOLDER"; then

    log "Google Drive upload successful."

else

    log "ERROR: Google Drive upload failed."
    exit 1

fi

# ----------------------------------------------------------
# Rotation function
# ----------------------------------------------------------

rotate_backups() {

    log "Starting backup rotation..."

    BACKUP_ROOT="$BACKUP_BASE/$PROJECT_NAME"

    if [ ! -d "$BACKUP_ROOT" ]; then
        log "No backup directory found for rotation."
        return
    fi

    # ------------------------------------------------------
    # Daily backups
    # Keep latest DAILY_RETENTION backup files
    # ------------------------------------------------------

    DAILY_FILES=$(find "$BACKUP_ROOT" \
        -type f \
        -name "${PROJECT_NAME}_*.zip" \
        -printf '%T@ %p\n' |
        sort -nr |
        awk '{print $2}')

    DAILY_COUNT=0
    DAILY_DELETED=0

    while IFS= read -r file; do

        [ -z "$file" ] && continue

        DAILY_COUNT=$((DAILY_COUNT + 1))

        if [ "$DAILY_COUNT" -gt "$DAILY_RETENTION" ]; then
            rm -f "$file"
            DAILY_DELETED=$((DAILY_DELETED + 1))
            log "Deleted old daily backup: $file"
        fi

    done <<< "$DAILY_FILES"

    log "Daily rotation completed. Deleted: $DAILY_DELETED"

    # ------------------------------------------------------
    # Weekly backups
    # Keep latest WEEKLY_RETENTION Sunday backups
    # ------------------------------------------------------

    WEEKLY_DIR="$BACKUP_ROOT/.weekly"

    mkdir -p "$WEEKLY_DIR"

    # Current day: 1=Monday ... 7=Sunday
    DAY_OF_WEEK=$(date '+%u')

    if [ "$DAY_OF_WEEK" -eq 7 ]; then

        WEEKLY_BACKUP="$WEEKLY_DIR/${BACKUP_FILENAME}"

        cp "$BACKUP_FILE" "$WEEKLY_BACKUP"

        log "Sunday backup copied to weekly retention."

    fi

    WEEKLY_FILES=$(find "$WEEKLY_DIR" \
        -type f \
        -name "${PROJECT_NAME}_*.zip" \
        -printf '%T@ %p\n' |
        sort -nr |
        awk '{print $2}')

    WEEKLY_COUNT=0
    WEEKLY_DELETED=0

    while IFS= read -r file; do

        [ -z "$file" ] && continue

        WEEKLY_COUNT=$((WEEKLY_COUNT + 1))

        if [ "$WEEKLY_COUNT" -gt "$WEEKLY_RETENTION" ]; then

            rm -f "$file"

            WEEKLY_DELETED=$((WEEKLY_DELETED + 1))

            log "Deleted old weekly backup: $file"

        fi

    done <<< "$WEEKLY_FILES"

    log "Weekly rotation completed. Deleted: $WEEKLY_DELETED"

    # ------------------------------------------------------
    # Monthly backups
    # Keep latest MONTHLY_RETENTION monthly snapshots
    # ------------------------------------------------------

    MONTHLY_DIR="$BACKUP_ROOT/.monthly"

    mkdir -p "$MONTHLY_DIR"

    # Create monthly backup on the first day of month
    CURRENT_DAY=$(date '+%d')

    if [ "$CURRENT_DAY" = "01" ]; then

        MONTHLY_BACKUP="$MONTHLY_DIR/${BACKUP_FILENAME}"

        cp "$BACKUP_FILE" "$MONTHLY_BACKUP"

        log "Monthly backup created."

    fi

    MONTHLY_FILES=$(find "$MONTHLY_DIR" \
        -type f \
        -name "${PROJECT_NAME}_*.zip" \
        -printf '%T@ %p\n' |
        sort -nr |
        awk '{print $2}')

    MONTHLY_COUNT=0
    MONTHLY_DELETED=0

    while IFS= read -r file; do

        [ -z "$file" ] && continue

        MONTHLY_COUNT=$((MONTHLY_COUNT + 1))

        if [ "$MONTHLY_COUNT" -gt "$MONTHLY_RETENTION" ]; then

            rm -f "$file"

            MONTHLY_DELETED=$((MONTHLY_DELETED + 1))

            log "Deleted old monthly backup: $file"

        fi

    done <<< "$MONTHLY_FILES"

    log "Monthly rotation completed. Deleted: $MONTHLY_DELETED"

    # ------------------------------------------------------
    # Remove empty directories
    # ------------------------------------------------------

    find "$BACKUP_ROOT" \
        -type d \
        -empty \
        -not -path "$BACKUP_ROOT" \
        -delete 2>/dev/null || true

    log "Backup rotation completed."
}

# ----------------------------------------------------------
# Run rotation
# ----------------------------------------------------------

rotate_backups

# ----------------------------------------------------------
# Send notification
# ----------------------------------------------------------

if [ "$NO_NOTIFY" = false ] && [ "$NOTIFY_ENABLED" = true ]; then

    log "Sending success notification..."

    BACKUP_DATE=$(date '+%Y-%m-%d %H:%M:%S')

    RESPONSE=$(curl -s -o /dev/null \
        -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{\"project\":\"$PROJECT_NAME\",\"date\":\"$BACKUP_DATE\",\"test\":\"BackupSuccessful\"}" \
        "$WEBHOOK_URL")

    if [[ "$RESPONSE" =~ ^2 ]]; then

        log "Notification sent successfully. HTTP status: $RESPONSE"

    else

        log "WARNING: Notification failed. HTTP status: $RESPONSE"

    fi

else

    log "Notification disabled."

fi

# ----------------------------------------------------------
# Final result
# ----------------------------------------------------------

log "Backup completed successfully."
log "Backup file: $BACKUP_FILE"
log "=========================================================="

exit 0