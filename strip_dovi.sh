#!/usr/bin/env bash
# =============================================================================
# strip_dovi.sh — Batch Dolby Vision → HDR10 (lossless, no re-encode)
#
# What it does:
#   For each .mkv file found under the target directory:
#     1. Extracts the raw HEVC stream via ffmpeg
#     2. Strips the DoVi RPU layer via dovi_tool (keeps HDR10 base layer)
#     3. Remuxes clean video + original audio/subtitles/chapters via mkvmerge
#     4. Verifies the output, then deletes the original
#
# Dependencies (must be in PATH):
#   ffmpeg, dovi_tool, mkvmerge  (from MKVToolNix)
#
# Install on Debian/Ubuntu:
#   sudo apt install ffmpeg mkvtoolnix
#   # dovi_tool — grab latest binary from:
#   # https://github.com/quietvoid/dovi_tool/releases
#   # e.g. sudo cp dovi_tool /usr/local/bin/ && sudo chmod +x /usr/local/bin/dovi_tool
#
# Usage:
#   chmod +x strip_dovi.sh
#   ./strip_dovi.sh /path/to/your/media
#
#   If no path is given the current directory is used.
#
# Output files are written next to the originals with a .hdr10.mkv suffix,
# then the original is deleted only after a successful remux.
# =============================================================================

set -euo pipefail

# ── colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── dependency check ──────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in ffmpeg dovi_tool mkvmerge; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
        echo ""
        echo "Install instructions:"
        echo "  ffmpeg + mkvmerge : sudo apt install ffmpeg mkvtoolnix"
        echo "  dovi_tool         : https://github.com/quietvoid/dovi_tool/releases"
        echo "                      (download Linux binary, place in /usr/local/bin/)"
        exit 1
    fi
}

# ── detect whether a file actually has a DoVi layer ──────────────────────────
has_dovi() {
    local file="$1"
    ffprobe -v quiet -show_streams -select_streams v:0 \
        -print_format json "$file" 2>/dev/null \
        | grep -qi "dovi\|dolby.vision\|DOVI" && return 0

    # fallback: check side_data_list for DOVI configuration record
    ffprobe -v quiet -show_streams -select_streams v:0 "$file" 2>&1 \
        | grep -qi "DOVI configuration\|dv_profile" && return 0

    return 1
}

# ── process a single MKV ─────────────────────────────────────────────────────
process_file() {
    local input="$1"
    local dir; dir="$(dirname "$input")"
    local base; base="$(basename "$input" .mkv)"
    local tmpdir; tmpdir="$(mktemp -d "${dir}/.strip_dovi_tmp_XXXXXX")"
    local output="${dir}/${base}.hdr10.mkv"

    # Clean up temp dir on any exit from this function
    trap 'rm -rf "$tmpdir"' RETURN

    echo ""
    echo -e "${BOLD}────────────────────────────────────────────────────${RESET}"
    info "Processing: $(basename "$input")"

    # Skip if output already exists
    if [[ -f "$output" ]]; then
        warn "Output already exists, skipping: $(basename "$output")"
        return 0
    fi

    # Skip if no DoVi detected
    if ! has_dovi "$input"; then
        warn "No Dolby Vision detected, skipping: $(basename "$input")"
        return 0
    fi

    local raw_hevc="${tmpdir}/video.hevc"
    local clean_hevc="${tmpdir}/video_hdr10.hevc"

    # Step 1: Extract raw HEVC bitstream
    info "Extracting HEVC stream..."
    ffmpeg -hide_banner -loglevel error \
        -i "$input" \
        -map 0:v:0 \
        -c:v copy \
        -bsf:v hevc_mp4toannexb \
        -f hevc \
        "$raw_hevc"

    # Step 2: Strip DoVi RPU, keep HDR10 base layer
    info "Stripping Dolby Vision layer (keeping HDR10)..."
    dovi_tool remove \
        --input "$raw_hevc" \
        --output "$clean_hevc"

    # Verify the clean HEVC was produced and has non-zero size
    if [[ ! -s "$clean_hevc" ]]; then
        error "dovi_tool produced an empty output — skipping: $(basename "$input")"
        return 1
    fi

    # Step 3: Remux clean video + all other tracks from original
    info "Remuxing with original audio, subtitles and chapters..."
    mkvmerge \
        --output "$output" \
        --no-video \
        "$input" \
        + \
        --no-audio --no-subtitles --no-chapters --no-attachments \
        "$clean_hevc"

    # Verify output exists and is reasonably sized (>1 MB sanity check)
    if [[ ! -s "$output" ]] || [[ $(stat -c%s "$output") -lt 1048576 ]]; then
        error "Output file is missing or suspiciously small — NOT deleting original."
        rm -f "$output"
        return 1
    fi

    success "Created: $(basename "$output")"

    # Step 4: Delete original
    info "Deleting original..."
    rm -f "$input"
    success "Deleted: $(basename "$input")"
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
    local target_dir="${1:-.}"

    if [[ ! -d "$target_dir" ]]; then
        error "Directory not found: $target_dir"
        exit 1
    fi

    check_deps

    echo ""
    echo -e "${BOLD}DoVi → HDR10 batch stripper${RESET}"
    echo -e "Target directory : ${CYAN}${target_dir}${RESET}"
    echo -e "Mode             : lossless strip (no re-encode)"
    echo -e "After success    : delete original"
    echo ""

    # Collect all .mkv files recursively
    mapfile -d '' files < <(find "$target_dir" -type f -iname "*.mkv" -print0 | sort -z)

    if [[ ${#files[@]} -eq 0 ]]; then
        warn "No .mkv files found in: $target_dir"
        exit 0
    fi

    info "Found ${#files[@]} MKV file(s) to evaluate."

    local processed=0
    local failed=0

    for f in "${files[@]}"; do
        # Skip files we already output (avoid re-processing .hdr10.mkv files)
        if [[ "$f" == *.hdr10.mkv ]]; then
            continue
        fi

        if process_file "$f"; then
            ((processed++)) || true
        else
            ((failed++)) || true
        fi
    done

    echo ""
    echo -e "${BOLD}────────────────────────────────────────────────────${RESET}"
    echo -e "${BOLD}Done.${RESET}"
    echo -e "  Processed : ${GREEN}${processed}${RESET}"
    echo -e "  Failed    : ${RED}${failed}${RESET}"
    echo ""

    [[ $failed -gt 0 ]] && exit 1
    exit 0
}

main "$@"
