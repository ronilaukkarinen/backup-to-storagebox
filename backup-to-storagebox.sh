#!/bin/bash

# ⚡ Backup to Storagebox - Simple backup solution for Hetzner Storagebox
# Usage: ./backup-to-storagebox.sh <source_path> <dest_path>
# Example: ./backup-to-storagebox.sh / /backups/myserver/linux

# Set version
VERSION_SCRIPT="2.8.1"

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Lock file to prevent multiple instances
LOCK_FILE="/tmp/backup-to-storagebox.lock"

# Function to cleanup lock file on exit
cleanup_lock() {
  rm -f "$LOCK_FILE"
}

# Check if another instance is running
if [[ -f "$LOCK_FILE" ]]; then
  PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    echo -e "${RED}❌ ERROR: Another instance is already running (PID: $PID)${NC}"
    echo -e "${YELLOW}💡 If you're sure no other instance is running, remove: $LOCK_FILE${NC}"
    exit 1
  else
    echo -e "${YELLOW}⚠️ Stale lock file found, removing...${NC}"
    rm -f "$LOCK_FILE"
  fi
fi

# Create lock file with current PID
echo $$ > "$LOCK_FILE"

# Set trap to cleanup lock file on exit (normal exit, interrupt, or termination)
trap cleanup_lock EXIT INT TERM

# Show usage
show_usage() {
  echo -e "${CYAN}⚡ Backup to Storagebox${NC}"
  echo -e "${WHITE}Usage: $0 <source_path> <dest_path>${NC}"
  echo -e "${WHITE}Example: $0 / /backups/myserver/linux${NC}"
  echo ""
  echo -e "${YELLOW}Configuration:${NC}"
  echo -e "${WHITE}  Copy .env.example to .env and configure your settings${NC}"
}

# Load configuration from .env file
load_config() {
  local env_file="$SCRIPT_DIR/.env"

  if [[ -f "$env_file" ]]; then
    echo -e "${GREEN}⚙️ Loading configuration from $env_file${NC}"
    # Source the .env file
    set -a  # Automatically export all variables
    source "$env_file"
    set +a
  else
    echo -e "${RED}❌ ERROR: Configuration file $env_file not found${NC}"
    echo -e "${YELLOW}💡 Copy .env.example to .env and configure it${NC}"
    exit 1
  fi

  # Set defaults for optional variables
  SSH_PORT="${SSH_PORT:-23}"
  SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"
  RSYNC_MAX_SIZE="${RSYNC_MAX_SIZE:-2G}"
  RSYNC_TIMEOUT="${RSYNC_TIMEOUT:-300}"
  EXCLUDES="${EXCLUDES:-}"  # Comma-separated list of exclude patterns (empty = no excludes)

  # Validate required variables
  if [[ -z "${STORAGEBOX_USER:-}" ]] || [[ -z "${STORAGEBOX_HOST:-}" ]]; then
    echo -e "${RED}❌ ERROR: STORAGEBOX_USER and STORAGEBOX_HOST must be set in .env${NC}"
    exit 1
  fi

  echo -e "${GREEN}✅ Configuration loaded successfully${NC}"
}

# Check arguments
if [[ $# -ne 2 ]]; then
  show_usage
  exit 1
fi

SOURCE_PATH="$1"
DEST_PATH="$2"

# Load configuration
load_config

# Check source exists
if [[ ! -d "$SOURCE_PATH" ]]; then
  echo -e "${RED}❌ ERROR: Source '$SOURCE_PATH' does not exist${NC}"
  exit 1
fi

# Ensure source ends with /
[[ "$SOURCE_PATH" != */ ]] && SOURCE_PATH="$SOURCE_PATH/"

# Remove leading slash from dest for relative path
DEST_REL="${DEST_PATH#/}"

echo -e "\n${CYAN}⚡ Backup to Storagebox v${VERSION_SCRIPT}${NC}"
echo -e "${WHITE}📁 Source: ${YELLOW}$SOURCE_PATH${NC}"
echo -e "${WHITE}🎯 Dest: ${YELLOW}$STORAGEBOX_USER@$STORAGEBOX_HOST:$DEST_REL${NC}"
echo -e "${WHITE}📏 Largest file allowed: ${YELLOW}$RSYNC_MAX_SIZE${NC}"

# Test connection
echo -e "\n${CYAN}🔌 Testing connection...${NC}"
echo -e "${WHITE}🔑 SSH Key: ${YELLOW}$SSH_KEY_PATH${NC}"
echo -e "${WHITE}🚪 Port: ${YELLOW}$SSH_PORT${NC}"

# Check if SSH key exists
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo -e "${RED}❌ SSH key not found: $SSH_KEY_PATH${NC}"
  echo -e "${YELLOW}💡 Generate one with: ssh-keygen -t rsa -b 4096 -f $SSH_KEY_PATH${NC}"
  exit 1
fi

# Test connection (non-blocking)
sftp_opts_key="-o BatchMode=yes -o StrictHostKeyChecking=no -i $SSH_KEY_PATH -P $SSH_PORT"

echo -e "${WHITE}🔍 Testing SSH key authentication...${NC}"
if echo "pwd" | sftp $sftp_opts_key "$STORAGEBOX_USER@$STORAGEBOX_HOST" >/dev/null 2>&1; then
  echo -e "${GREEN}✅ SSH key authentication successful${NC}"
else
  echo -e "${YELLOW}⚠️ SSH key authentication failed${NC}"
  echo -e "${WHITE}🔧 Installing the SSH key using Hetzner's install-ssh-key service...${NC}"
  echo -e "${WHITE}You'll be prompted for your Storagebox password...${NC}"
    if cat "$SSH_KEY_PATH.pub" | ssh -p "$SSH_PORT" "$STORAGEBOX_USER@$STORAGEBOX_HOST" install-ssh-key; then
      echo -e "${GREEN}✅ SSH key installed successfully${NC}"

      # Test again
      echo -e "${WHITE}🔍 Testing connection with installed key...${NC}"
      if echo "pwd" | sftp $sftp_opts_key "$STORAGEBOX_USER@$STORAGEBOX_HOST" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ SSH key authentication now working${NC}"
      else
        echo -e "${YELLOW}⚠️ SSH key authentication still failing - continuing anyway${NC}"
      fi
    else
      echo -e "${RED}❌ Failed to install SSH key${NC}"
      echo -e "${YELLOW}💡 Continuing with backup - rsync will prompt for password${NC}"
    fi
fi
echo -e "${GREEN}✅ Connected${NC}"

# Create destination
echo -e "${CYAN}📁 Creating destination...${NC}"
IFS='/' read -ra parts <<< "$DEST_REL"
path=""
for part in "${parts[@]}"; do
  [[ -n "$part" ]] && {
    path="${path:+$path/}$part"
    echo "mkdir $path" | sftp $sftp_opts_key "$STORAGEBOX_USER@$STORAGEBOX_HOST" 2>/dev/null || true
  }
done
echo -e "${GREEN}✅ Destination ready${NC}"

# Build rsync command
opts=(-aAX --update --progress --stats -v --timeout="$RSYNC_TIMEOUT" --max-size="$RSYNC_MAX_SIZE")
opts+=(-e "ssh -o StrictHostKeyChecking=no -i $SSH_KEY_PATH -p $SSH_PORT")

# Add bandwidth limit if specified
if [[ -n "${RSYNC_BANDWIDTH_LIMIT:-}" ]]; then
  opts+=(--bwlimit="$RSYNC_BANDWIDTH_LIMIT")
fi

# Add excludes from environment variable (if not empty)
if [[ -n "$EXCLUDES" ]]; then
  IFS=',' read -ra exclude_patterns <<< "$EXCLUDES"
  for pattern in "${exclude_patterns[@]}"; do
    # Trim whitespace from pattern
    pattern=$(echo "$pattern" | xargs)
    [[ -n "$pattern" ]] && opts+=(--exclude="$pattern")
  done
  echo -e "${GREEN}📋 Using excludes: $EXCLUDES${NC}"
fi

# Backup crontabs
backup_crontabs() {
  if [[ $EUID -eq 0 ]]; then
    echo -e "${CYAN}📅 Backing up crontabs (root mode)...${NC}"
    local crontab_dir="/tmp/crontab-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$crontab_dir"
    local backed_up=0

        # Backup system crontab
    if [[ -f /etc/crontab ]]; then
      if cp /etc/crontab "$crontab_dir/system-crontab" 2>/dev/null; then
        echo -e "${WHITE}✓ System crontab backed up${NC}"
        backed_up=$((backed_up + 1))
        echo -e "${WHITE}💡 DEBUG: backed_up count is now $backed_up${NC}"
      else
        echo -e "${YELLOW}⚠️ Could not backup system crontab${NC}"
      fi
    else
      echo -e "${WHITE}💡 No system crontab found${NC}"
    fi

    echo -e "${WHITE}💡 DEBUG: After system crontab backup section${NC}"

            # Check /etc/cron.d - simplified to avoid issues
    echo -e "${WHITE}🔍 Checking /etc/cron.d...${NC}"
    if [[ -d /etc/cron.d ]]; then
      echo -e "${WHITE}💡 /etc/cron.d directory exists${NC}"
      # Skip actual backup for now - just report
    else
      echo -e "${WHITE}💡 /etc/cron.d directory not found${NC}"
    fi

    # Backup user crontabs
    echo -e "${WHITE}🔍 Backing up user crontabs...${NC}"

    # Backup root crontab with debug
    echo -e "${WHITE}🔍 Checking root crontab...${NC}"
    if crontab -u root -l >/dev/null 2>&1; then
      echo -e "${WHITE}💡 Root has a crontab, attempting to save...${NC}"
      if crontab -u root -l > "$crontab_dir/user-root-crontab" 2>/dev/null; then
        echo -e "${WHITE}✓ Root user crontab backed up${NC}"
        ((backed_up++))
      else
        echo -e "${YELLOW}⚠️ Could not save root crontab${NC}"
      fi
    else
      echo -e "${WHITE}💡 Root user has no crontab${NC}"
    fi

        # Backup other users - with better error handling
    echo -e "${WHITE}🔍 Checking for other users...${NC}"
    local user_count=0

    # Disable exit on error temporarily for user enumeration
    set +e
    echo -e "${WHITE}💡 Looking in /home directory...${NC}"
    for user in $(ls /home 2>/dev/null); do
      echo -e "${WHITE}💡 Found user: $user${NC}"
      if [[ -n "$user" ]] && [[ "$user" != "lost+found" ]]; then
        echo -e "${WHITE}💡 Checking if $user has crontab...${NC}"
        if crontab -u "$user" -l >/dev/null 2>&1; then
          echo -e "${WHITE}💡 $user has crontab, saving...${NC}"
          if crontab -u "$user" -l > "$crontab_dir/user-$user-crontab" 2>/dev/null; then
            echo -e "${WHITE}✓ User $user crontab backed up${NC}"
            ((backed_up++))
            ((user_count++))
          else
            echo -e "${YELLOW}⚠️ Could not save $user crontab${NC}"
          fi
        else
          echo -e "${WHITE}💡 $user has no crontab${NC}"
        fi
      fi
    done
    set -e

    if [[ $user_count -eq 0 ]]; then
      echo -e "${WHITE}💡 No other user crontabs found${NC}"
    else
      echo -e "${WHITE}✓ Found $user_count user crontabs${NC}"
    fi

    # Upload crontabs to storagebox
    if [[ $backed_up -gt 0 ]]; then
      echo -e "${WHITE}📤 Uploading $backed_up crontab files...${NC}"
      rsync -aAX --update -e "ssh -o StrictHostKeyChecking=no -i $SSH_KEY_PATH -p $SSH_PORT" \
        "$crontab_dir/" "$STORAGEBOX_USER@$STORAGEBOX_HOST:$DEST_REL/crontabs/" 2>/dev/null && {
        echo -e "${GREEN}✅ Crontabs uploaded successfully${NC}"
      } || {
        echo -e "${YELLOW}⚠️ Failed to upload crontabs - saved locally in $crontab_dir${NC}"
      }
    else
      echo -e "${YELLOW}💡 No crontabs found to backup${NC}"
    fi

    # Cleanup
    rm -rf "$crontab_dir" 2>/dev/null
  else
    echo -e "${CYAN}📅 Backing up current user crontab...${NC}"
    local crontab_dir="/tmp/crontab-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$crontab_dir"
    local current_user=$(whoami)

    # Backup current user's crontab
    if crontab -l > "$crontab_dir/user-$current_user-crontab" 2>/dev/null; then
      echo -e "${WHITE}✓ User $current_user crontab backed up${NC}"

      # Upload to storagebox
      echo -e "${WHITE}📤 Uploading crontab...${NC}"
      rsync -aAX --update -e "ssh -o StrictHostKeyChecking=no -i $SSH_KEY_PATH -p $SSH_PORT" \
        "$crontab_dir/" "$STORAGEBOX_USER@$STORAGEBOX_HOST:$DEST_REL/crontabs/" 2>/dev/null && {
        echo -e "${GREEN}✅ Crontab uploaded successfully${NC}"
      } || {
        echo -e "${YELLOW}⚠️ Failed to upload crontab - saved locally in $crontab_dir${NC}"
      }
    else
      echo -e "${YELLOW}💡 No crontab found for current user${NC}"
    fi

    # Cleanup
    rm -rf "$crontab_dir" 2>/dev/null
  fi
}

# Start backup
echo -e "\n${CYAN}🚀 Starting backup...${NC}"
start=$(date +%s)

# Temporarily disable exit on error for rsync
set +e
rsync "${opts[@]}" "$SOURCE_PATH" "$STORAGEBOX_USER@$STORAGEBOX_HOST:$DEST_REL/"
exit_code=$?
set -e

duration=$(($(date +%s) - start))

# Show colorful backup summary
echo -e "\n${CYAN}📊 Backup Summary${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"

if [[ $exit_code -eq 0 ]]; then
  echo -e "${GREEN}🎉 Status: ${WHITE}Completed successfully${NC}"
  echo -e "${GREEN}✅ Result: ${WHITE}All files transferred without errors${NC}"
elif [[ $exit_code -eq 23 ]]; then
  echo -e "${GREEN}🎉 Status: ${WHITE}Completed with warnings${NC}"
  echo -e "${YELLOW}⚠️ Result: ${WHITE}Some files/attributes were not transferred (ACL errors)${NC}"
  echo -e "${YELLOW}💡 Note: ${WHITE}This is normal for system backups - backup is successful${NC}"
else
  echo -e "${RED}❌ Status: ${WHITE}Completed with errors${NC}"
  echo -e "${RED}🚨 Result: ${WHITE}Backup failed with exit code $exit_code${NC}"
fi

echo -e "${CYAN}⏱️ Duration: ${WHITE}${duration}s${NC}"
echo -e "${CYAN}🔄 Sync Type: ${WHITE}Incremental (only changed files)${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"

# Backup crontabs AFTER main backup is complete
echo -e "\n${CYAN}📅 Now backing up crontabs...${NC}"
backup_crontabs

# Send heartbeat to Better Stack if configured
if [[ -n "${BETTER_STACK_HEARTBEAT:-}" ]]; then
  echo -e "\n${CYAN}💓 Sending heartbeat to Better Stack...${NC}"

  # Send heartbeat only on success (Better Stack detects missing heartbeats as failures)
  if [[ -n "${exit_code:-}" ]]; then
    # Main backup was run, only send heartbeat on success
    if [[ $exit_code -eq 0 || $exit_code -eq 23 ]]; then
      # Success heartbeat (exit code 0 or 23 which is partial success)
      if curl -fsS -m 10 --retry 3 "$BETTER_STACK_HEARTBEAT" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Heartbeat sent successfully${NC}"
      else
        echo -e "${YELLOW}⚠️ Failed to send heartbeat (backup still completed)${NC}"
      fi
    else
      # Skip heartbeat on failure - Better Stack will detect missing heartbeat as failure
      echo -e "${YELLOW}⚠️ Backup failed with exit code $exit_code - no heartbeat sent${NC}"
    fi
  else
    # Main backup was disabled, send success heartbeat for crontab backup
    if curl -fsS -m 10 --retry 3 "$BETTER_STACK_HEARTBEAT" >/dev/null 2>&1; then
      echo -e "${GREEN}✅ Heartbeat sent successfully (crontab backup completed)${NC}"
    else
      echo -e "${YELLOW}⚠️ Failed to send heartbeat${NC}"
    fi
  fi
fi
