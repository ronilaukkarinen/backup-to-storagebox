#!/bin/bash

# ⚡ Backup to Storagebox - Simple backup solution for Hetzner Storagebox
# Version: 2.3.0
# Usage: ./backup-to-storagebox.sh <source_path> <dest_path>
# Example: ./backup-to-storagebox.sh / /backups/infinity/linux

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
  echo -e "${WHITE}Example: $0 / /backups/infinity/linux${NC}"
  echo ""
  echo -e "${YELLOW}Configuration:${NC}"
  echo -e "${WHITE}  Copy .env.example to .env and configure your settings${NC}"
}

# Load configuration from .env file
load_config() {
  local env_file="$SCRIPT_DIR/.env"

  if [[ -f "$env_file" ]]; then
    echo -e "${GREEN}⚙️  Loading configuration from $env_file${NC}"
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
  DRY_RUN="${DRY_RUN:-false}"

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

echo -e "\n${CYAN}⚡ Backup to Storagebox v2.3.0${NC}"
echo -e "${WHITE}📁 Source: ${YELLOW}$SOURCE_PATH${NC}"
echo -e "${WHITE}🎯 Dest: ${YELLOW}$STORAGEBOX_USER@$STORAGEBOX_HOST:$DEST_REL${NC}"
echo -e "${WHITE}📏 Largest file allowed: ${YELLOW}$RSYNC_MAX_SIZE${NC}"
echo -e "${WHITE}🧪 Dry run: ${YELLOW}$DRY_RUN${NC}"

# Test connection
echo -e "\n${CYAN}🔌 Testing connection...${NC}"
sftp_opts="-o BatchMode=yes -o StrictHostKeyChecking=no -i $SSH_KEY_PATH -P $SSH_PORT"

if ! echo "pwd" | sftp $sftp_opts "$STORAGEBOX_USER@$STORAGEBOX_HOST" >/dev/null 2>&1; then
  echo -e "${RED}❌ Connection failed${NC}"
  echo -e "${YELLOW}💡 Check your .env configuration and SSH key${NC}"
  exit 1
fi
echo -e "${GREEN}✅ Connected${NC}"

# Create destination
echo -e "${CYAN}📁 Creating destination...${NC}"
IFS='/' read -ra parts <<< "$DEST_REL"
path=""
for part in "${parts[@]}"; do
  [[ -n "$part" ]] && {
    path="${path:+$path/}$part"
    echo "mkdir $path" | sftp $sftp_opts "$STORAGEBOX_USER@$STORAGEBOX_HOST" 2>/dev/null || true
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

[[ "$DRY_RUN" == "true" ]] && opts+=(--dry-run) && echo -e "${YELLOW}🔍 DRY RUN MODE${NC}"

# Start backup
echo -e "\n${CYAN}🚀 Starting backup...${NC}"
start=$(date +%s)

rsync "${opts[@]}" "$SOURCE_PATH" "$STORAGEBOX_USER@$STORAGEBOX_HOST:$DEST_REL/"
exit_code=$?
duration=$(($(date +%s) - start))

if [[ $exit_code -eq 0 ]]; then
  echo -e "\n${GREEN}🎉 Backup completed successfully in ${duration}s${NC}"
else
  echo -e "\n${GREEN}🎉 Backup completed in ${duration}s${NC}"
  echo -e "${YELLOW}💡 Some files may have been skipped due to permissions or changes during transfer${NC}"
fi
