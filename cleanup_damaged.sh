#!/usr/bin/env bash
# =============================================================================
# cleanup_damaged.sh — Find and delete DoVi Profile 5 files damaged by
#                     earlier converter runs, so Radarr/Sonarr re-download them.
#
# HOW IT WORKS
# ────────────
# Early versions of the converter stripped DoVi from Profile 5 files without
# detecting the profile, producing washed-out / green-tinted video. This
# script identifies likely-damaged files by their filename patterns:
#
#   - Filename contains a DoVi indicator (DoVi, DV.HDR, DV., Dovi, etc.)
#   - But the file itself no longer contains any DoVi metadata (already stripped)
#   - AND the filename suggests a Profile 5 source (Netflix/NF, AppleTV+/ATVP,
#     Disney+/DSNP/DSNY — streaming services that use Profile 5)
#
# Files matching all three criteria are LIKELY DAMAGED and will be deleted
# unless you pass --dry-run.
#
# After deletion, Radarr/Sonarr will detect the missing file and re-queue it.
# Make sure you've set up custom formats to prefer Profile 7/8 releases first!
# See the README for Radarr/Sonarr custom format setup instructions.
#
# USAGE
# ─────
#   ./cleanup_damaged.sh --dry-run /path/to/media    # preview what would be deleted
#   ./cleanup_damaged.sh /path/to/media              # actually delete
#
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }

# ── parse args ────────────────────────────────────────────────────────────────
DRY_RUN=false
TARGET_DIR=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) TARGET_DIR="$arg" ;;
    esac
done

if [[ -z "$TARGET_DIR" ]]; then
    error "No target directory provided."
    echo "Usage: $0 [--dry-run] /path/to/media"
    exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
    error "Directory not found: $TARGET_DIR"
    exit 1
fi

# ── dependency check ──────────────────────────────────────────────────────────
for cmd in ffprobe find; do
    command -v "$cmd" &>/dev/null || { error "Missing required tool: $cmd"; exit 1; }
done

# ── detect whether a file currently has a DoVi layer ──────────────────────────
has_dovi() {
    local file="$1"
    ffprobe -v quiet -show_streams -select_streams v:0 "$file" 2>&1 \
        | grep -qi "DOVI configuration\|dv_profile" \
        && return 0
    ffprobe -v quiet -show_streams -select_streams v:0 \
        -print_format json "$file" 2>&1 \
        | grep -qi "dv_bl_signal_compatibility_id\|dolby.vision" \
        && return 0
    return 1
}

# ── filename pattern checks ──────────────────────────────────────────────────
# Filenames that originally had DoVi in the name
has_dovi_in_filename() {
    local name; name="$(basename "$1")"
    [[ "${name,,}" =~ (dovi|dv\.|\.dv-|hdr\.dv|dv-hdr) ]]
}

# Filenames that suggest a Profile 5 source (streaming services)
looks_like_profile_5_source() {
    local name; name="$(basename "$1")"
    # Streaming service release tags commonly associated with Profile 5:
    #   NF    = Netflix
    #   ATVP  = Apple TV+
    #   AMZN  = Amazon Prime Video
    #   DSNP  = Disney+
    #   HULU  = Hulu
    #   MAX   = HBO Max
    #   HMAX  = HBO Max (older tag)
    [[ "${name^^}" =~ (NF\.WEB|\.NF-|ATVP\.|AMZN\.|DSNP\.|DSNY\.|HULU\.|\.MAX\.|HMAX\.|PMTP\.) ]]
}

# ── main ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}DoVi damaged-file cleanup${RESET}"
echo -e "Target directory : ${CYAN}${TARGET_DIR}${RESET}"
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "Mode             : ${YELLOW}DRY RUN — no files will be deleted${RESET}"
else
    echo -e "Mode             : ${RED}DELETE${RESET}"
    echo ""
    warn "This will PERMANENTLY DELETE files matching the damaged-file criteria."
    warn "Ensure Radarr/Sonarr custom formats are set up to avoid re-downloading"
    warn "the same bad releases (see README)."
    echo ""
    read -rp "Type 'DELETE' to continue: " confirm
    if [[ "$confirm" != "DELETE" ]]; then
        info "Aborted."
        exit 0
    fi
fi
echo ""

candidates=()
checked=0

# Collect all MKV files
while IFS= read -r -d '' file; do
    ((checked++)) || true

    # Skip if the file doesn't have DoVi in the filename
    has_dovi_in_filename "$file" || continue

    # Skip if the file still has DoVi — it wasn't damaged
    has_dovi "$file" && continue

    # Skip if filename doesn't suggest a Profile 5 source
    looks_like_profile_5_source "$file" || continue

    candidates+=("$file")
done < <(find "$TARGET_DIR" -type f -iname "*.mkv" -print0)

info "Scanned $checked MKV file(s)."
echo ""

if [[ ${#candidates[@]} -eq 0 ]]; then
    success "No damaged files detected."
    exit 0
fi

echo -e "${BOLD}Damaged file candidates (${#candidates[@]}):${RESET}"
for f in "${candidates[@]}"; do
    echo "  $f"
done
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    warn "Dry run — no files deleted. Re-run without --dry-run to delete."
    exit 0
fi

deleted=0
failed=0
for f in "${candidates[@]}"; do
    if rm -f "$f"; then
        success "Deleted: $f"
        ((deleted++)) || true
    else
        error "Failed to delete: $f"
        ((failed++)) || true
    fi
done

echo ""
echo -e "${BOLD}Done.${RESET}"
echo -e "  Deleted : ${GREEN}${deleted}${RESET}"
echo -e "  Failed  : ${RED}${failed}${RESET}"
echo ""
info "Radarr and Sonarr should detect the missing files on their next scan"
info "and re-queue them for download."
