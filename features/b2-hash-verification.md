# B2 Hash Verification Feature

## Overview

This feature enhances the split-resume script to verify chunk integrity by comparing local chunk hashes with remote B2 file hashes. This prevents duplicate uploads and enables automatic cleanup of already-uploaded chunks.

## Current Script Analysis

The script already has SHA256 integrity verification built-in (`split-resume.sh:212-231`) but only uses it for local chunk validation during resume operations.

## B2 Hash Verification Design

**Key Findings:**
- B2's `b2_get_file_info` API returns file metadata including SHA1 hash without downloading
- B2 CLI provides `b2 ls --json` and `b2 file get-info` commands for metadata access
- Current script uses SHA256 locally, but B2 primarily uses SHA1
- Need to bridge the gap between local SHA256 and B2's SHA1

## B2 CLI Integration Plan

**Key B2 CLI Commands:**
1. `b2 ls --json <bucket>/<prefix>` - List files with metadata including SHA1 hashes
2. `b2 file get-info <fileId>` - Get detailed file info including SHA1 hash
3. Standard B2 authentication via `b2 authorize-account`

## Implementation Strategy

### 1. B2 Configuration Options
- Add `--bucket BUCKET_NAME` parameter for B2 bucket
- Add `--b2-prefix PREFIX` parameter for remote file prefix mapping
- Add `--verify-b2` flag to enable verification mode
- Add `--delete-verified` flag to auto-delete verified chunks
- B2 CLI must be installed and authenticated

### 2. B2 CLI Integration Functions

```bash
# Check if B2 CLI is available and authenticated
check_b2_cli() {
    if ! command -v b2 &> /dev/null; then
        echo "Error: B2 CLI not found. Please install B2 CLI."
        exit 1
    fi

    if ! b2 account get &> /dev/null; then
        echo "Error: B2 CLI not authenticated. Run 'b2 authorize-account' first."
        exit 1
    fi
}

# Get remote file SHA1 hash using B2 CLI
get_b2_file_hash() {
    local bucket="$1"
    local remote_filename="$2"

    # Use b2 ls --json to get file metadata
    b2 ls --json "$bucket" --recursive | \
        jq -r ".[] | select(.fileName == \"$remote_filename\") | .contentSha1"
}

# List all chunks in bucket matching prefix
list_b2_chunks() {
    local bucket="$1"
    local prefix="$2"

    b2 ls --json "$bucket" --recursive | \
        jq -r ".[] | select(.fileName | startswith(\"$prefix\")) | .fileName"
}
```

### 3. Hash Verification Workflow

```bash
# For each local chunk:
verify_chunk_with_b2() {
    local chunk_file="$1"
    local bucket="$2"
    local remote_filename="$3"

    # Calculate local SHA1
    local local_sha1=$(sha1sum "$chunk_file" | cut -d' ' -f1)

    # Get remote SHA1
    local remote_sha1=$(get_b2_file_hash "$bucket" "$remote_filename")

    if [ "$local_sha1" = "$remote_sha1" ] && [ -n "$remote_sha1" ]; then
        echo "✓ Hash match: $chunk_file"
        if [ "$DELETE_VERIFIED" = "true" ]; then
            rm "$chunk_file"
            echo "  Deleted verified chunk: $chunk_file"
        fi
        return 0
    elif [ -n "$remote_sha1" ]; then
        echo "✗ Hash mismatch: $chunk_file (local: $local_sha1, remote: $remote_sha1)"
        return 1
    else
        echo "? Remote file not found: $remote_filename"
        return 2
    fi
}
```

### 4. Enhanced Script Flow

```bash
# Enhanced chunk creation workflow
create_chunk_with_verification() {
    local chunk_num="$1"
    local suffix="$2"
    local output_file="$3"

    # Create chunk normally
    echo "Creating chunk $suffix ($(($chunk_num + 1))/$TOTAL_CHUNKS)..."

    if dd if="$SOURCE_FILE" of="$output_file" bs=1G skip=$((chunk_num * CHUNK_SIZE_GB)) count=$count_blocks 2>/dev/null; then
        echo "Successfully created: $output_file"

        # If B2 verification is enabled
        if [ "$VERIFY_B2" = "true" ]; then
            local remote_filename="${B2_PREFIX}${suffix}"
            verify_chunk_with_b2 "$output_file" "$BUCKET" "$remote_filename"
        fi

        return 0
    else
        echo "Error creating chunk $suffix"
        return 1
    fi
}
```

### 5. New Command Line Options

```bash
# Additional parameters
--bucket BUCKET_NAME        B2 bucket name for verification
--b2-prefix PREFIX          Prefix for remote files in B2 (default: same as local prefix)
--verify-b2                 Enable B2 hash verification
--delete-verified           Automatically delete chunks that match B2 hashes
--b2-only                   Only perform verification, don't create new chunks
```

### 6. Example Usage

```bash
# Create chunks and verify against B2
./split-resume.sh --verify-b2 --bucket my-backup --b2-prefix "backup_" \
    --delete-verified /large/file.img /local/chunks/

# Only verify existing chunks without creating new ones
./split-resume.sh --b2-only --verify-b2 --bucket my-backup \
    --b2-prefix "backup_" --delete-verified /large/file.img /local/chunks/

# Create chunks with verification but keep verified chunks locally
./split-resume.sh --verify-b2 --bucket my-backup \
    /large/file.img /local/chunks/
```

## Implementation Benefits

1. **Prevents Duplicate Uploads**: Avoids re-uploading chunks that already exist with correct hashes
2. **Saves Bandwidth**: Only uploads chunks that are missing or have different hashes
3. **Storage Optimization**: Can automatically delete verified local chunks to free space
4. **Data Integrity**: Ensures uploaded chunks match local originals
5. **Resume Capability**: Can resume verification process on interrupted operations
6. **Backward Compatibility**: All new features are optional flags

## Technical Considerations

### Hash Algorithm Compatibility
- B2 uses SHA1 for file integrity
- Current script uses SHA256 for local verification
- Will add SHA1 calculation for B2 compatibility
- Both SHA1 and SHA256 will be available for different use cases

### Error Handling
- Handle B2 CLI authentication failures
- Handle network timeouts gracefully
- Provide clear error messages for common issues
- Continue operation when individual chunk verification fails

### Performance Optimization
- Batch B2 API calls when possible using `b2 ls --json`
- Cache remote file listings to reduce API calls
- Parallel verification of multiple chunks
- Optional verification (can be disabled for pure splitting)

## Future Enhancements

1. **Upload Integration**: Directly upload chunks that don't match or are missing
2. **Progress Tracking**: Show verification progress with progress bars
3. **Detailed Reporting**: Generate reports of verification results
4. **Configuration Files**: Support for B2 config files instead of command line params
5. **Multi-bucket Support**: Verify against multiple B2 buckets