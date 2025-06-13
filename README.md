# 🚀 Backup to Storagebox

A simple, fast backup script for Hetzner Storageboxes.

## ⚡ Quick start

```bash
# 1. Copy and configure the environment file
cp env.example .env
# Edit .env with your Storagebox credentials

# 2. Run backups with simple command-line syntax
./backup-to-storagebox.sh / /backups/myserver/linux
./backup-to-storagebox.sh /home/user /backups/myserver/home
./backup-to-storagebox.sh /var/www /backups/myserver/www
```

## 📋 Usage

```bash
./backup-to-storagebox.sh <source_path> <dest_path>
```

### Configuration

1. **Copy the example configuration:**
   ```bash
   cp env.example .env
   ```

2. **Edit `.env` with your settings:**
   ```bash
   # Required
   STORAGEBOX_USER=u123456
   STORAGEBOX_HOST=u123456.your-storagebox.de
   
   # Optional
   RSYNC_MAX_SIZE=2G
   DRY_RUN=false
   ```

### Required environment variables

- `STORAGEBOX_USER` - Your Storagebox username (e.g., u123456)
- `STORAGEBOX_HOST` - Your Storagebox hostname (e.g., u123456.your-storagebox.de)

### Optional environment variables

- `SSH_KEY_PATH` - SSH key path (default: ~/.ssh/id_rsa)
- `SSH_PORT` - SSH port (default: 23)
- `RSYNC_MAX_SIZE` - Max file size (default: 2G)
- `RSYNC_TIMEOUT` - Connection timeout (default: 300)
- `RSYNC_BANDWIDTH_LIMIT` - Bandwidth limit (e.g., 1000 for 1MB/s)
- `DRY_RUN` - Set to 'true' for dry run

## 🔧 Features

- ✅ **Simple command-line interface** - No config files needed
- ✅ **Progress display** - See individual file transfers
- ✅ **File size limiting** - Skip large files automatically
- ✅ **Smart excludes** - Automatically excludes cache, temp files, etc.
- ✅ **Incremental backups** - Only transfers changed files
- ✅ **Dry run support** - Test before running
- ✅ **Hetzner Storagebox optimized** - Works perfectly with Storagebox SSH/SFTP

## 📝 Examples

### Initial setup
```bash
# Copy and configure
cp env.example .env
nano .env  # Edit with your credentials
```

### Backup entire system
```bash
./backup-to-storagebox.sh / /backups/infinity/linux
```

### Backup home directory with custom settings
```bash
# Edit .env to set RSYNC_MAX_SIZE=1G
./backup-to-storagebox.sh /home/user /backups/infinity/home
```

### Test backup (dry run)
```bash
# Edit .env to set DRY_RUN=true
./backup-to-storagebox.sh /var/www /backups/infinity/www
```

## 🔑 SSH key setup

1. Generate SSH key if you don't have one:
```bash
ssh-keygen -t rsa -b 4096
```

2. Install key on Storagebox:
```bash
cat ~/.ssh/id_rsa.pub | ssh -p 23 u123456@u123456.your-storagebox.de install-ssh-key
```

## 🚫 Default excludes

The script automatically excludes:
- Cache directories (`.cache/`, `cache/`)
- Development files (`.git/`, `node_modules/`)
- Temporary files (`*.tmp`, `*.swp`)
- System directories (`/dev/`, `/proc/`, `/sys/`, `/tmp/`, `/run/`, `/mnt/`, `/media/`)

## 📊 What you'll see

```
⚡ Backup to Storagebox v2.0.0
📁 Source: /home/user/
🎯 Dest: u123456@u123456.your-storagebox.de:backups/myserver/home
📏 Max size: 2G

🔌 Testing connection...
✅ Connected
📁 Creating destination...
✅ Destination ready

🚀 Starting backup...
sending incremental file list
./
Documents/
Documents/file1.txt
          1,234 100%    1.23MB/s    0:00:00 (xfr#1, to-chk=123/456)
...

🎉 Backup completed in 45s
```
