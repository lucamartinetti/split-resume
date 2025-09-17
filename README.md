# Split-Resume

A robust, resumable file splitting utility with integrity verification and flexible chunk management.

## Features

- **Resumable splitting**: Automatically detects existing chunks and continues from where it left off
- **Integrity verification**: SHA1 checksum verification of the last chunk before resuming
- **B2 cloud integration**: Upload chunks to Backblaze B2 with automatic hash verification and cleanup
- **Flexible chunk management**: Warns about missing chunks but continues (allows moving chunks to free disk space)
- **Split-compatible naming**: Uses standard split naming convention (aa, ab, ac, ...)
- **Safe error handling**: Detects and reports partial/corrupted chunks without data loss
- **Disk space monitoring**: Configurable safety buffer to prevent disk full errors
- **Command-line interface**: Fully parametric with comprehensive help

## Usage

```bash
./split-resume.sh [OPTIONS] SOURCE_FILE OUTPUT_DIR
```

### Arguments

- `SOURCE_FILE`: Path to the source file to split
- `OUTPUT_DIR`: Directory where chunks will be created

### Options

- `-p, --prefix PREFIX`: Prefix for chunk filenames (default: `split_`)
- `-s, --size SIZE_GB`: Chunk size in GB (default: `8`)
- `-b, --buffer BUFFER_GB`: Safety buffer in GB (default: `2`)
- `--upload-b2 BUCKET REMOTE_PATH`: Upload chunks to B2 after creation/verification
- `-h, --help`: Show help message

## Examples

### Basic Usage
```bash
# Split a large file with default settings (8GB chunks, 2GB buffer)
./split-resume.sh /path/to/large.file /path/to/output/
```

### Custom Settings
```bash
# Split with 4GB chunks and custom prefix
./split-resume.sh -p "backup_" -s 4 -b 1 /data/file.img /backup/chunks/

# Split with 10GB chunks and no safety buffer
./split-resume.sh --prefix "media_" --size 10 --buffer 0 /media.zfs /chunks/
```

### Resume Operations
```bash
# If splitting was interrupted, simply run the same command again
./split-resume.sh -p "backup_" -s 4 /data/file.img /backup/chunks/
# Script will automatically detect existing chunks and continue
```

### B2 Cloud Upload
```bash
# Split and upload to B2 cloud storage
./split-resume.sh --upload-b2 my-bucket "backups/vm-images/" /data/vm.img /tmp/chunks/

# With custom chunk size and prefix
./split-resume.sh -p "vm_" -s 2 --upload-b2 my-bucket "daily-backups/" /data/vm.img /tmp/chunks/
```

## Output

The script creates files with split-compatible naming:
- `prefix_aa` (chunk 0)
- `prefix_ab` (chunk 1)
- `prefix_ac` (chunk 2)
- etc.

## Safety Features

### Chunk Validation
- **Size validation**: Ensures chunks match expected sizes
- **Integrity verification**: SHA256 checksum verification of the last existing chunk
- **Corruption detection**: Identifies partial or corrupted chunks

### Error Handling
```bash
# Example error output for partial chunk
ERROR: Partial chunk detected!
File: /chunks/backup_ab
Expected size: 4294967296 bytes (4096 MB)
Actual size: 2147483648 bytes (2048 MB)

This indicates an incomplete or corrupted chunk from a previous run.
Please remove the partial chunk file and run the script again.
To remove: rm "/chunks/backup_ab"
```

### Missing Chunk Management
```bash
# Example warning for missing chunks (continues operation)
WARNING: Missing chunk file: /chunks/backup_aa
Chunk 0 (aa) not found - may have been moved to free disk space.
Note: 1 chunk(s) missing from sequence. This is acceptable if chunks were moved to free disk space.
```

## Disk Space Management

The script allows flexible disk space management:

1. **Monitor available space**: Checks disk space before creating each chunk
2. **Safety buffer**: Configurable buffer to prevent disk full errors
3. **Move completed chunks**: You can move completed chunks to external storage to free space
4. **Resume operation**: Script continues from the last available chunk

### Example Workflow
```bash
# Start splitting
./split-resume.sh -s 2 large-file.img /output/

# After some chunks are created, move them to external storage
mv /output/split_aa /output/split_ab /external/storage/

# Continue splitting (script warns about missing chunks but continues)
./split-resume.sh -s 2 large-file.img /output/
```

## Reassembling Files

To reassemble the split files:
```bash
# Standard concatenation
cat prefix_* > original-file

# Or using split's merge functionality
split -d -a 2 --numeric-suffixes=0 /dev/null prefix_
```

## B2 Cloud Storage Integration

### Features
- **Smart upload**: Checks if chunks already exist remotely with matching SHA1 hashes
- **Automatic verification**: Compares local and remote hashes after upload
- **Space saving**: Deletes local chunks after successful upload verification
- **Resume friendly**: Works with existing resume functionality

### Setup
1. Install B2 CLI: `pip install b2` or from AUR on Arch Linux
2. Authenticate: `backblaze-b2 account authorize`
3. Use `--upload-b2` option with bucket name and remote path

### Workflow
```bash
# The script will:
# 1. Create chunk locally
# 2. Check if chunk exists remotely with matching hash
# 3. If hash matches: delete local chunk (already uploaded)
# 4. If no match or missing: upload chunk to B2
# 5. Verify upload by comparing hashes
# 6. Delete local chunk after successful verification
./split-resume.sh --upload-b2 my-bucket "path/" /large-file.img /tmp/
```

## Requirements

- Bash shell
- Standard Unix utilities: `dd`, `stat`, `df`, `sha1sum`
- Sufficient disk space for at least one chunk plus safety buffer
- For B2 upload: B2 CLI installed and authenticated

## Technical Details

- **Chunk size calculation**: Uses 1GB blocks for dd operations
- **Hash algorithm**: SHA1 for both local integrity verification and B2 compatibility
- **Suffix generation**: Compatible with GNU split naming convention
- **B2 integration**: Uses B2 CLI for file operations and hash retrieval
- **Error codes**: Script exits with non-zero status on errors

## Troubleshooting

### Common Issues

1. **"Partial chunk detected"**: Remove the partial chunk file and restart
2. **"Not enough disk space"**: Increase available space or reduce chunk size
3. **"Source file not found"**: Check file path and permissions
4. **"Last chunk integrity verification failed"**: Remove corrupted chunk and restart
5. **"B2 CLI not found"**: Install B2 CLI with `pip install b2` or from AUR
6. **"B2 CLI not authenticated"**: Run `backblaze-b2 account authorize` first
7. **"Upload verification failed"**: Check network connection and B2 service status

### Debug Information

The script provides detailed progress information:
- Source file size and location
- Chunk size and total chunks needed
- Available disk space
- Validation results
- Creation progress for each chunk