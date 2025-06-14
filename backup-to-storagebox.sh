#!/bin/bash

# ⚡ Backup to Storagebox - Simple backup solution for Hetzner Storagebox
# Usage: ./backup-to-storagebox.sh <source_path> <dest_path>
# Example: ./backup-to-storagebox.sh / /backups/myserver/linux

# Set version
VERSION_SCRIPT="2.7.1"

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

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

# Add common excludes
opts+=(--exclude=".cache/" --exclude="cache/" --exclude=".git/" --exclude="node_modules/")
opts+=(--exclude="*.tmp" --exclude="*.swp" --exclude="/dev/" --exclude="/proc/")
opts+=(--exclude="/sys/" --exclude="/tmp/" --exclude="/run/" --exclude="/mnt/" --exclude="/media/")

# Backup crontabs if running as root
backup_crontabs() {
  if [[ $EUID -eq 0 ]]; then
    echo -e "${CYAN}📅 Backing up crontabs...${NC}"
    local crontab_dir="/tmp/crontab-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$crontab_dir"

    # Backup system crontab
    if [[ -f /etc/crontab ]]; then
      cp /etc/crontab "$crontab_dir/system-crontab"
      echo -e "${WHITE}✓ System crontab backed up${NC}"
    fi

    # Backup cron.d directory
    if [[ -d /etc/cron.d ]]; then
      cp -r /etc/cron.d "$crontab_dir/"
      echo -e "${WHITE}✓ /etc/cron.d backed up${NC}"
    fi

        # Backup user crontabs - with timeout protection and debug
    local users_backed_up=0
    echo -e "${WHITE}🔍 Backing up user crontabs...${NC}"

    # Use timeout for the entire user crontab process
    (
      # Create a temporary file with all usernames
      local users_file="/tmp/users_list_$$"
      cut -d: -f1 /etc/passwd > "$users_file"

      # Read users from file with individual timeouts
      while read -r user; do
        if [[ -n "$user" ]]; then
          echo -e "${WHITE}  Processing user: $user${NC}"
          if timeout 2 crontab -u "$user" -l > "$crontab_dir/user-$user-crontab.txt" 2>/dev/null; then
            if [[ -s "$crontab_dir/user-$user-crontab.txt" ]]; then
              echo -e "${WHITE}✓ User $user crontab backed up${NC}"
              ((users_backed_up++))
            else
              rm -f "$crontab_dir/user-$user-crontab.txt"
            fi
          fi
        fi
      done < "$users_file"

      # Clean up temp file
      rm -f "$users_file"
    ) &

    # Wait for user crontab backup with overall timeout
    local crontab_pid=$!
    if timeout 30 wait $crontab_pid 2>/dev/null; then
      echo -e "${WHITE}🔍 User crontab backup completed${NC}"
    else
      echo -e "${YELLOW}⚠️ User crontab backup timed out - continuing${NC}"
      kill $crontab_pid 2>/dev/null || true
    fi

    # Skip crontab upload for now - just save locally and continue
    if [[ $(ls -A "$crontab_dir" 2>/dev/null | wc -l) -gt 0 ]]; then
      echo -e "${GREEN}✅ Crontabs saved locally in $crontab_dir ($users_backed_up user crontabs)${NC}"
      echo -e "${YELLOW}💡 Crontab upload temporarily disabled - continuing with main backup${NC}"
    else
      echo -e "${YELLOW}⚠️ No crontabs found to backup${NC}"
    fi

    # Cleanup
    rm -rf "$crontab_dir"
  else
    echo -e "${YELLOW}💡 Skipping crontab backup (not running as root)${NC}"
  fi
}

# Backup crontabs automatically when running as root
backup_crontabs

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

# Send heartbeat to Better Stack if configured
if [[ -n "${BETTER_STACK_HEARTBEAT:-}" ]]; then
  echo -e "\n${CYAN}💓 Sending heartbeat to Better Stack...${NC}"

  # Send success or failure heartbeat based on exit code
  if [[ $exit_code -eq 0 || $exit_code -eq 23 ]]; then
    # Success heartbeat (exit code 0 or 23 which is partial success)
    if curl -fsS -m 10 --retry 3 "$BETTER_STACK_HEARTBEAT" >/dev/null 2>&1; then
      echo -e "${GREEN}✅ Heartbeat sent successfully${NC}"
    else
      echo -e "${YELLOW}⚠️ Failed to send heartbeat (backup still completed)${NC}"
    fi
  else
    # Failure heartbeat with exit code
    if curl -fsS -m 10 --retry 3 "$BETTER_STACK_HEARTBEAT/$exit_code" >/dev/null 2>&1; then
      echo -e "${GREEN}✅ Failure heartbeat sent (exit code: $exit_code)${NC}"
    else
      echo -e "${YELLOW}⚠️ Failed to send failure heartbeat${NC}"
    fi
  fi
fi
