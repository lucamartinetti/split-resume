#!/bin/bash

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] SOURCE_FILE OUTPUT_DIR

Split a large file into smaller chunks with resume capability.

ARGUMENTS:
    SOURCE_FILE         Path to the source file to split
    OUTPUT_DIR          Directory where chunks will be created

OPTIONS:
    -p, --prefix PREFIX              Prefix for chunk filenames (default: split_)
    -s, --size SIZE_GB               Chunk size in GB (default: 8)
    -b, --buffer BUFFER_GB           Safety buffer in GB (default: 2)
    --upload-b2 BUCKET REMOTE_PATH   Upload chunks to B2 after creation/verification
    -x, --debug                      Enable debug mode (print all commands)
    -h, --help                       Show this help message

B2 UPLOAD:
    When --upload-b2 is used, chunks are uploaded to B2 cloud storage.
    Requires B2 CLI to be installed and authenticated.
    Before uploading, checks if chunk exists remotely with matching hash.
    Automatically deletes local chunks after successful upload verification.

EXAMPLES:
    $0 /path/to/large.file /path/to/output/
    $0 -p "backup_" -s 4 -b 1 /data/file.img /backup/chunks/
    $0 --prefix "media_" --size 10 /media.zfs /chunks/
    $0 --upload-b2 my-bucket "backups/" /file.img /chunks/

EOF
}

# Default configuration
PREFIX="split_"
CHUNK_SIZE_GB=8
SAFETY_BUFFER_GB=2
UPLOAD_B2=false
B2_BUCKET=""
B2_REMOTE_PATH=""
B2_CLI="backblaze-b2"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--prefix)
            PREFIX="$2"
            shift 2
            ;;
        -s|--size)
            CHUNK_SIZE_GB="$2"
            shift 2
            ;;
        -b|--buffer)
            SAFETY_BUFFER_GB="$2"
            shift 2
            ;;
        --upload-b2)
            UPLOAD_B2=true
            B2_BUCKET="$2"
            B2_REMOTE_PATH="$3"
            shift 3
            ;;
        -x|--debug)
            set -x
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            echo "Error: Unknown option $1"
            show_usage
            exit 1
            ;;
        *)
            if [ -z "$SOURCE_FILE" ]; then
                SOURCE_FILE="$1"
            elif [ -z "$OUTPUT_DIR" ]; then
                OUTPUT_DIR="$1"
            else
                echo "Error: Too many arguments"
                show_usage
                exit 1
            fi
            shift
            ;;
    esac
done

# Check required arguments
if [ -z "$SOURCE_FILE" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Error: SOURCE_FILE and OUTPUT_DIR are required"
    echo ""
    show_usage
    exit 1
fi

# Validate numeric parameters
if ! [[ "$CHUNK_SIZE_GB" =~ ^[0-9]+$ ]] || [ "$CHUNK_SIZE_GB" -le 0 ]; then
    echo "Error: Chunk size must be a positive integer"
    exit 1
fi

if ! [[ "$SAFETY_BUFFER_GB" =~ ^[0-9]+$ ]] || [ "$SAFETY_BUFFER_GB" -lt 0 ]; then
    echo "Error: Safety buffer must be a non-negative integer"
    exit 1
fi

# Validate B2 parameters if upload is enabled
if [ "$UPLOAD_B2" = true ]; then
    if [ -z "$B2_BUCKET" ]; then
        echo "Error: B2 bucket name is required when using --upload-b2"
        exit 1
    fi
    if [ -z "$B2_REMOTE_PATH" ]; then
        echo "Error: B2 remote path is required when using --upload-b2"
        exit 1
    fi
fi

# Convert GB to bytes
CHUNK_SIZE_BYTES=$((CHUNK_SIZE_GB * 1024 * 1024 * 1024))
SAFETY_BUFFER_BYTES=$((SAFETY_BUFFER_GB * 1024 * 1024 * 1024))

# Function to generate split-style suffix (aa, ab, ac, ..., az, ba, bb, etc.)
get_split_suffix() {
    local num=$1

    # Split uses: 0=aa, 1=ab, 2=ac, ..., 25=az, 26=ba, 27=bb, etc.
    local first_char=$((num / 26))
    local second_char=$((num % 26))

    echo "$(printf \\$(printf '%03o' $((97 + first_char))))$(printf \\$(printf '%03o' $((97 + second_char))))"
}

# Function to convert suffix back to number
suffix_to_number() {
    local suffix=$1

    # For 2-character suffixes: aa=0, ab=1, ..., az=25, ba=26, bb=27, etc.
    if [ ${#suffix} -eq 2 ]; then
        local first_char=$(printf "%d" "'${suffix:0:1}")
        local second_char=$(printf "%d" "'${suffix:1:1}")

        local first_val=$((first_char - 97))
        local second_val=$((second_char - 97))

        echo $((first_val * 26 + second_val))
    else
        # Handle longer suffixes if needed (aaa, aab, etc.)
        echo 0
    fi
}

# Function to find the last existing chunk
find_last_chunk() {
    local last_chunk=-1
    local last_suffix=""

    # Look for existing chunk files (exclude .sha1 files)
    for file in "$OUTPUT_DIR"/${PREFIX}*; do
        if [ -f "$file" ] && [[ "$file" != *.sha1 ]]; then
            # Extract suffix from filename
            local basename=$(basename "$file")
            local suffix=${basename#$PREFIX}

            # Convert suffix to number
            local chunk_num=$(suffix_to_number "$suffix")

            if [ $chunk_num -gt $last_chunk ]; then
                last_chunk=$chunk_num
                last_suffix=$suffix
            fi
        fi
    done

    echo "$last_chunk:$last_suffix"
}

# Function to get available disk space in bytes
get_available_space() {
    df --output=avail "$OUTPUT_DIR" | tail -1 | awk '{print $1 * 1024}'
}

# Function to check B2 CLI availability and authentication
check_b2_cli() {
    # Auto-detect B2 CLI command
    if command -v backblaze-b2 >/dev/null 2>&1; then
        B2_CLI="backblaze-b2"
    elif command -v b2 >/dev/null 2>&1; then
        B2_CLI="b2"
    elif command -v b2.exe >/dev/null 2>&1; then
        B2_CLI="b2.exe"
    else
        echo "ERROR: B2 CLI not found. Please install the Backblaze B2 CLI."
        echo "Expected commands: backblaze-b2, b2, or b2.exe"
        exit 1
    fi

    # Check if B2 CLI is authenticated
    if ! $B2_CLI account get >/dev/null 2>&1; then
        echo "ERROR: B2 CLI not authenticated. Please run '$B2_CLI account authorize' first."
        exit 1
    fi

    echo "B2 CLI is available and authenticated ($B2_CLI)."
}

# Function to get B2 file hash (SHA1) for a remote file
get_b2_file_hash() {
    local remote_file="$1"

    # Use B2 CLI to get file info and extract SHA1 hash
    local file_info=$($B2_CLI file info "b2://$B2_BUCKET/$remote_file" 2>/dev/null)
    if [ $? -eq 0 ]; then
        # First try to get contentSha1 (for regular files)
        local sha1=$(echo "$file_info" | grep -o '"contentSha1": *"[^"]*"' | cut -d'"' -f4)

        # If contentSha1 is "none", try large_file_sha1 (for large files)
        if [ "$sha1" = "none" ] || [ -z "$sha1" ]; then
            sha1=$(echo "$file_info" | grep -o '"large_file_sha1": *"[^"]*"' | cut -d'"' -f4)
        fi

        echo "$sha1"
    else
        echo ""
    fi
}

# Function to get or compute SHA1 hash for a local file
get_local_hash() {
    local chunk_file="$1"
    local hash_file="${chunk_file}.sha1"

    # Try to read from cached hash file first
    if [ -f "$hash_file" ]; then
        local cached_hash=$(cat "$hash_file" 2>/dev/null | cut -d' ' -f1)
        if [ -n "$cached_hash" ] && [ ${#cached_hash} -eq 40 ]; then
            echo "$cached_hash"
            return 0
        fi
    fi

    # Compute hash and save to cache file
    echo "Computing SHA1 hash for $(basename "$chunk_file")..." >&2
    local computed_hash=$(sha1sum "$chunk_file" | cut -d' ' -f1)

    # Save hash to cache file (never delete this)
    echo "$computed_hash  $(basename "$chunk_file")" > "$hash_file"

    echo "$computed_hash"
}

# Function to verify chunk against B2 by comparing SHA1 hashes
verify_chunk_with_b2() {
    local chunk_file="$1"
    local chunk_basename=$(basename "$chunk_file")
    local remote_file="${B2_REMOTE_PATH}${chunk_basename}"

    echo "Verifying chunk against B2: $chunk_basename"

    # Get remote file hash
    local remote_hash=$(get_b2_file_hash "$remote_file")
    if [ -z "$remote_hash" ]; then
        echo "Remote file not found: $remote_file"
        return 1
    fi

    # Get local file SHA1 hash (cached or computed)
    local local_hash=$(get_local_hash "$chunk_file")

    # Clean up hashes (remove any whitespace)
    local_hash=$(echo "$local_hash" | tr -d ' \t\n\r')
    remote_hash=$(echo "$remote_hash" | tr -d ' \t\n\r')

    # Compare hashes
    if [ "$local_hash" = "$remote_hash" ]; then
        echo "✓ Hash verification successful for $chunk_basename"
        return 0
    else
        echo "✗ Hash mismatch for $chunk_basename"
        echo "  Local:  $local_hash"
        echo "  Remote: $remote_hash"
        return 1
    fi
}

# Function to upload chunk to B2
upload_chunk_to_b2() {
    local chunk_file="$1"
    local chunk_basename=$(basename "$chunk_file")
    local remote_file="${B2_REMOTE_PATH}${chunk_basename}"

    echo "Uploading chunk to B2: $chunk_basename"

    # Upload the file to B2
    if $B2_CLI file upload "$B2_BUCKET" "$chunk_file" "$remote_file" >/dev/null 2>&1; then
        echo "✓ Upload successful for $chunk_basename"

        # Verify the upload by comparing hashes
        if verify_chunk_with_b2 "$chunk_file"; then
            echo "✓ Upload verification successful for $chunk_basename"

            # Delete local file after successful verification (but keep .sha1 file)
            echo "Deleting local chunk: $chunk_basename (keeping hash file)"
            rm -f "$chunk_file"
            return 0
        else
            echo "✗ Upload verification failed for $chunk_basename"
            return 1
        fi
    else
        echo "✗ Upload failed for $chunk_basename"
        return 1
    fi
}

# Function to validate chunk size
validate_chunk_size() {
    local chunk_file="$1"
    local chunk_number="$2"
    local expected_size

    # Calculate expected size for this chunk
    local remaining_bytes=$((FILE_SIZE - chunk_number * CHUNK_SIZE_BYTES))
    if [ $remaining_bytes -ge $CHUNK_SIZE_BYTES ]; then
        expected_size=$CHUNK_SIZE_BYTES
    else
        expected_size=$remaining_bytes
    fi

    # Get actual file size
    local actual_size=$(stat -c%s "$chunk_file" 2>/dev/null || stat -f%z "$chunk_file" 2>/dev/null)

    if [ "$actual_size" -ne "$expected_size" ]; then
        echo "ERROR: Partial chunk detected!"
        echo "File: $chunk_file"
        echo "Expected size: $expected_size bytes ($(($expected_size / 1024 / 1024)) MB)"
        echo "Actual size: $actual_size bytes ($(($actual_size / 1024 / 1024)) MB)"
        echo ""
        echo "This indicates an incomplete or corrupted chunk from a previous run."
        echo "Please remove the partial chunk file and run the script again."
        echo "To remove: rm \"$chunk_file\""
        exit 1
    fi
}

# Function to verify last chunk integrity by recreating it
verify_last_chunk_integrity() {
    local chunk_file="$1"
    local chunk_number="$2"
    local temp_file="${chunk_file}.tmp"

    echo "Verifying integrity of last chunk: $(basename "$chunk_file")"

    # Calculate parameters for recreating this chunk
    local remaining_bytes=$((FILE_SIZE - chunk_number * CHUNK_SIZE_BYTES))
    local count_blocks

    if [ $remaining_bytes -ge $CHUNK_SIZE_BYTES ]; then
        count_blocks=$CHUNK_SIZE_GB
    else
        # For the last partial chunk, calculate exact count
        count_blocks=$(( (remaining_bytes + 1024*1024*1024 - 1) / (1024*1024*1024) ))
    fi

    # Recreate the chunk to temporary file
    if ! dd if="$SOURCE_FILE" of="$temp_file" bs=1G skip=$((chunk_number * CHUNK_SIZE_GB)) count=$count_blocks 2>/dev/null; then
        echo "ERROR: Failed to recreate chunk for verification"
        rm -f "$temp_file"
        exit 1
    fi

    # Compare checksums
    local original_hash=$(get_local_hash "$chunk_file")
    local recreated_hash=$(sha1sum "$temp_file" | cut -d' ' -f1)

    # Clean up temporary file
    rm -f "$temp_file"

    if [ "$original_hash" != "$recreated_hash" ]; then
        echo "ERROR: Last chunk integrity verification failed!"
        echo "File: $chunk_file"
        echo "Original hash:   $original_hash"
        echo "Recreated hash:  $recreated_hash"
        echo ""
        echo "This indicates the last chunk is corrupted or incomplete."
        echo "Please remove the corrupted chunk file and run the script again."
        echo "To remove: rm \"$chunk_file\""
        exit 1
    fi

    echo "Last chunk integrity verified successfully."
}

# Check if source file exists
if [ ! -f "$SOURCE_FILE" ]; then
    echo "Error: Source file $SOURCE_FILE not found!"
    exit 1
fi

# Check if output directory exists
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "Error: Output directory $OUTPUT_DIR not found!"
    exit 1
fi

# Check B2 CLI if upload is enabled
if [ "$UPLOAD_B2" = true ]; then
    check_b2_cli
fi

# Get file size
FILE_SIZE=$(stat -c%s "$SOURCE_FILE" 2>/dev/null || stat -f%z "$SOURCE_FILE" 2>/dev/null)
if [ -z "$FILE_SIZE" ]; then
    echo "Error: Could not determine file size!"
    exit 1
fi

# Calculate total chunks needed
TOTAL_CHUNKS=$(( (FILE_SIZE + CHUNK_SIZE_BYTES - 1) / CHUNK_SIZE_BYTES ))

# Find the last existing chunk
last_info=$(find_last_chunk)
LAST_CHUNK_NUM=$(echo "$last_info" | cut -d: -f1)
LAST_CHUNK_SUFFIX=$(echo "$last_info" | cut -d: -f2)

if [ "$UPLOAD_B2" = true ]; then
    # For B2 upload mode, process all chunks that should exist based on file size
    echo "B2 upload mode: Processing all chunks for complete file"
    START_CHUNK=0
    # Total chunks is based on file size, not existing chunks
    TOTAL_CHUNKS=$(( (FILE_SIZE + CHUNK_SIZE_BYTES - 1) / CHUNK_SIZE_BYTES ))
    if [ $LAST_CHUNK_NUM -ne -1 ]; then
        echo "Found existing chunks up to: ${PREFIX}${LAST_CHUNK_SUFFIX} (chunk number $LAST_CHUNK_NUM)"
    else
        echo "No existing chunks found"
    fi
    echo "Will process all $TOTAL_CHUNKS chunks needed for complete file"
elif [ $LAST_CHUNK_NUM -eq -1 ]; then
    echo "No existing chunks found, starting from the beginning (chunk 0: aa)"
    START_CHUNK=0
else
    echo "Found last chunk: ${PREFIX}${LAST_CHUNK_SUFFIX} (chunk number $LAST_CHUNK_NUM)"

    # Validate existing chunks for correct size
    echo "Validating existing chunks..."
    last_existing_chunk_file=""
    last_existing_chunk_num=-1

    for chunk_num in $(seq 0 $LAST_CHUNK_NUM); do
        suffix=$(get_split_suffix $chunk_num)
        chunk_file="$OUTPUT_DIR/${PREFIX}$suffix"
        if [ -f "$chunk_file" ]; then
            validate_chunk_size "$chunk_file" "$chunk_num"
            last_existing_chunk_file="$chunk_file"
            last_existing_chunk_num="$chunk_num"
        else
            echo "WARNING: Missing chunk file: $chunk_file"
        fi
    done
    echo "Chunk validation completed."

    # Perform integrity verification on the last existing chunk
    if [ -n "$last_existing_chunk_file" ]; then
        verify_last_chunk_integrity "$last_existing_chunk_file" "$last_existing_chunk_num"
    fi

    START_CHUNK=$((LAST_CHUNK_NUM + 1))
fi

# Get initial available space
AVAILABLE_SPACE=$(get_available_space)

echo "Source file: $SOURCE_FILE"
echo "File size: $FILE_SIZE bytes ($(($FILE_SIZE / 1024 / 1024 / 1024)) GB)"
echo "Chunk size: $CHUNK_SIZE_GB GB ($CHUNK_SIZE_BYTES bytes)"
echo "Total chunks needed: $TOTAL_CHUNKS"
echo "Starting from chunk: $START_CHUNK ($(get_split_suffix $START_CHUNK))"
echo "Available disk space: $(($AVAILABLE_SPACE / 1024 / 1024 / 1024)) GB"
echo "Safety buffer: $SAFETY_BUFFER_GB GB"
echo "Output directory: $OUTPUT_DIR"
echo ""

# Check if we have enough space for at least one chunk plus buffer
if [ $AVAILABLE_SPACE -lt $((CHUNK_SIZE_BYTES + SAFETY_BUFFER_BYTES)) ]; then
    echo "Error: Not enough disk space for even one chunk plus safety buffer!"
    echo "Need: $(((CHUNK_SIZE_BYTES + SAFETY_BUFFER_BYTES) / 1024 / 1024 / 1024)) GB"
    echo "Available: $(($AVAILABLE_SPACE / 1024 / 1024 / 1024)) GB"
    exit 1
fi

# Resume extraction
current_chunk=$START_CHUNK
chunks_created=0

while [ $current_chunk -lt $TOTAL_CHUNKS ]; do
    # Check available space before creating each chunk (skip for B2 upload mode)
    if [ "$UPLOAD_B2" != true ]; then
        AVAILABLE_SPACE=$(get_available_space)

        if [ $AVAILABLE_SPACE -lt $((CHUNK_SIZE_BYTES + SAFETY_BUFFER_BYTES)) ]; then
            echo ""
            echo "Stopping: Not enough disk space for next chunk plus safety buffer"
            echo "Available: $(($AVAILABLE_SPACE / 1024 / 1024 / 1024)) GB"
            echo "Required: $(((CHUNK_SIZE_BYTES + SAFETY_BUFFER_BYTES) / 1024 / 1024 / 1024)) GB"
            break
        fi
    fi

    # Generate the suffix for this chunk
    suffix=$(get_split_suffix $current_chunk)
    output_file="$OUTPUT_DIR/${PREFIX}$suffix"

    # Handle B2 upload mode vs normal chunk creation
    if [ "$UPLOAD_B2" = true ]; then
        # B2 upload mode: process existing chunks or recreate if hash file exists
        if [ -f "$output_file" ]; then
            echo "Processing existing chunk $suffix ($(($current_chunk + 1))/$TOTAL_CHUNKS)..."

            # First check if chunk already exists remotely with matching hash
            if verify_chunk_with_b2 "$output_file"; then
                echo "Chunk already exists remotely with matching hash, deleting local copy (keeping hash file)"
                rm -f "$output_file"
            else
                # Upload the chunk to B2
                upload_chunk_to_b2 "$output_file"
            fi
            chunks_created=$((chunks_created + 1))
        else
            # Chunk file doesn't exist - check if we need to create it
            echo "Processing missing chunk $suffix ($(($current_chunk + 1))/$TOTAL_CHUNKS)..."

            # Calculate remaining bytes to avoid reading past end of file
            remaining_bytes=$((FILE_SIZE - current_chunk * CHUNK_SIZE_BYTES))
            if [ $remaining_bytes -le 0 ]; then
                echo "Chunk $suffix: beyond end of file, skipping"
            else
                # Check if we have a cached hash to compare with remote
                should_create=true
                if [ -f "${output_file}.sha1" ]; then
                    echo "Found hash file for missing chunk, checking against remote..."
                    cached_hash=$(cat "${output_file}.sha1" 2>/dev/null | cut -d' ' -f1)
                    remote_hash=$(get_b2_file_hash "${B2_REMOTE_PATH}${suffix}")

                    # Clean up hashes
                    cached_hash=$(echo "$cached_hash" | tr -d ' \t\n\r')
                    remote_hash=$(echo "$remote_hash" | tr -d ' \t\n\r')

                    if [ -n "$remote_hash" ] && [ "$cached_hash" = "$remote_hash" ]; then
                        echo "✓ Cached hash matches remote, chunk $suffix already uploaded correctly"
                        should_create=false
                        chunks_created=$((chunks_created + 1))
                    fi
                fi

                if [ "$should_create" = true ]; then
                    echo "Creating chunk $suffix for upload..."

                    # Determine how much to read (full chunk or remaining bytes)
                    if [ $remaining_bytes -ge $CHUNK_SIZE_BYTES ]; then
                        count_blocks=$CHUNK_SIZE_GB
                    else
                        # For the last partial chunk, calculate exact count
                        count_blocks=$(( (remaining_bytes + 1024*1024*1024 - 1) / (1024*1024*1024) ))
                    fi

                    # Create the chunk using dd
                    if dd if="$SOURCE_FILE" of="$output_file" bs=1G skip=$((current_chunk * CHUNK_SIZE_GB)) count=$count_blocks 2>/dev/null; then
                        echo "Successfully created: $output_file"

                        # Check if chunk already exists remotely with matching hash
                        if verify_chunk_with_b2 "$output_file"; then
                            echo "Created chunk matches remote hash, deleting local copy (keeping hash file)"
                            rm -f "$output_file"
                        else
                            # Upload the chunk to B2
                            upload_chunk_to_b2 "$output_file"
                        fi
                        chunks_created=$((chunks_created + 1))
                    else
                        echo "Error creating chunk $suffix"
                    fi
                fi
            fi
        fi
    else
        # Normal chunk creation mode
        # Check if this chunk already exists
        if [ -f "$output_file" ]; then
            echo "Chunk $suffix already exists, skipping..."
            current_chunk=$((current_chunk + 1))
            continue
        fi

        # Calculate remaining bytes to avoid reading past end of file
        remaining_bytes=$((FILE_SIZE - current_chunk * CHUNK_SIZE_BYTES))
        if [ $remaining_bytes -le 0 ]; then
            break
        fi

        # Determine how much to read (full chunk or remaining bytes)
        if [ $remaining_bytes -ge $CHUNK_SIZE_BYTES ]; then
            count_blocks=$CHUNK_SIZE_GB
        else
            # For the last partial chunk, calculate exact count
            count_blocks=$(( (remaining_bytes + 1024*1024*1024 - 1) / (1024*1024*1024) ))
        fi

        echo "Creating chunk $suffix ($(($current_chunk + 1))/$TOTAL_CHUNKS)..."

        # Extract the chunk using dd
        if dd if="$SOURCE_FILE" of="$output_file" bs=1G skip=$((current_chunk * CHUNK_SIZE_GB)) count=$count_blocks 2>/dev/null; then
            echo "Successfully created: $output_file"
            chunks_created=$((chunks_created + 1))

            # Show updated disk space
            AVAILABLE_SPACE=$(get_available_space)
            echo "Remaining space: $(($AVAILABLE_SPACE / 1024 / 1024 / 1024)) GB"
        else
            echo "Error creating chunk $suffix"
            df -h "$OUTPUT_DIR"
            break
        fi
    fi

    current_chunk=$((current_chunk + 1))
done

echo ""
echo "Operation completed!"
echo "Chunks created in this session: $chunks_created"
if [ $current_chunk -lt $TOTAL_CHUNKS ]; then
    remaining_chunks=$((TOTAL_CHUNKS - current_chunk))
    echo "Remaining chunks to create: $remaining_chunks"
    echo "Next chunk to create: $(get_split_suffix $current_chunk)"
    echo ""
    echo "To continue, free up disk space and run the script again."
else
    echo "All chunks have been created successfully!"
fi

# Final disk space report
echo ""
echo "Final disk space:"
df -h "$OUTPUT_DIR"