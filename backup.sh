
#!/bin/bash

# Automatic Backup Linux System Files
# Author: Assistant
# Date: 2025/10/21
# Version: 1.0

# Define Variables
SOURCE_DIRS=("/etc" "/boot" "/var/log")  # 需要备份的目录
TARGET_DIR="/data/backup"                # 备份存储目录
SNAPSHOT_FILE="$TARGET_DIR/snapshot"    # 快照文件路径

# Date Variables
YEAR=$(date +%Y)
MONTH=$(date +%m)
DAY=$(date +%d)
WEEK=$(date +%u)  # 1-7, 1=Monday, 7=Sunday
TIME=$(date +%H%M)

# Color Definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function: Print colored message
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function: Check if source directories exist
check_source_dirs() {
    for dir in "${SOURCE_DIRS[@]}"; do
        if [ ! -d "$dir" ] && [ ! -f "$dir" ]; then
            print_message "$RED" "Error: Source directory/file $dir does not exist!"
            return 1
        fi
    done
    return 0
}

# Function: Create target directory if not exists
create_target_dir() {
    local full_path="$TARGET_DIR/$YEAR/$MONTH/$DAY"
    if [ ! -d "$full_path" ]; then
        mkdir -p "$full_path"
        if [ $? -eq 0 ]; then
            print_message "$GREEN" "Backup directory $full_path created successfully!"
        else
            print_message "$RED" "Error: Failed to create backup directory $full_path!"
            exit 1
        fi
    fi
}

# Function: Full Backup (executed on Sunday)
full_backup() {
    if [ "$WEEK" -eq 7 ]; then
        print_message "$YELLOW" "Starting full backup..."
        
        # Remove old snapshot file for full backup
        rm -f "$SNAPSHOT_FILE"
        
        local backup_file="${TIME}_full_backup.tar.gz"
        cd "$TARGET_DIR/$YEAR/$MONTH/$DAY" || exit 1
        
        tar -g "$SNAPSHOT_FILE" -czvf "$backup_file" "${SOURCE_DIRS[@]}"
        
        if [ $? -eq 0 ]; then
            print_message "$GREEN" "--------------------------------------------------------"
            print_message "$GREEN" "Full backup completed successfully!"
            print_message "$GREEN" "Backup file: $TARGET_DIR/$YEAR/$MONTH/$DAY/$backup_file"
            print_message "$GREEN" "Backup size: $(du -h "$backup_file" | cut -f1)"
        else
            print_message "$RED" "Error: Full backup failed!"
            exit 1
        fi
    fi
}

# Function: Incremental Backup (executed on weekdays except Sunday)
incremental_backup() {
    if [ "$WEEK" -ne 7 ]; then
        print_message "$YELLOW" "Starting incremental backup..."
        
        local backup_file="${TIME}_incremental_backup.tar.gz"
        cd "$TARGET_DIR/$YEAR/$MONTH/$DAY" || exit 1
        
        tar -g "$SNAPSHOT_FILE" -czvf "$backup_file" "${SOURCE_DIRS[@]}"
        
        if [ $? -eq 0 ]; then
            print_message "$GREEN" "--------------------------------------------------------"
            print_message "$GREEN" "Incremental backup completed successfully!"
            print_message "$GREEN" "Backup file: $TARGET_DIR/$YEAR/$MONTH/$DAY/$backup_file"
            print_message "$GREEN" "Backup size: $(du -h "$backup_file" | cut -f1)"
        else
            print_message "$RED" "Error: Incremental backup failed!"
            exit 1
        fi
    fi
}

# Function: Display backup information
show_backup_info() {
    print_message "$YELLOW" "========================================================"
    print_message "$YELLOW" "Backup Information"
    print_message "$YELLOW" "Date: $YEAR-$MONTH-$DAY"
    print_message "$YELLOW" "Day of week: $WEEK"
    print_message "$YELLOW" "Source directories: ${SOURCE_DIRS[*]}"
    print_message "$YELLOW" "Target directory: $TARGET_DIR/$YEAR/$MONTH/$DAY"
    print_message "$YELLOW" "========================================================"
}

# Function: Clean old backups (keep last 30 days)
clean_old_backups() {
    print_message "$YELLOW" "Cleaning backups older than 30 days..."
    find "$TARGET_DIR" -type f -name "*_backup.tar.gz" -mtime +30 -delete
    if [ $? -eq 0 ]; then
        print_message "$GREEN" "Old backups cleanup completed!"
    fi
}

# Main execution
main() {
    print_message "$GREEN" "Linux System Backup Script Started..."
    
    # Check source directories
    if ! check_source_dirs; then
        exit 1
    fi
    
    # Create target directory
    create_target_dir
    
    # Show backup information
    show_backup_info
    
    # Execute backups
    full_backup
    incremental_backup
    
    # Clean old backups
    clean_old_backups
    
    print_message "$GREEN" "Backup process completed!"
}

# Check if script is being sourced or executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi

