#!/usr/bin/env bash
# =============================================================================
# converter.sh — DoVi → HDR10 converter for the dovi-converter container
#
# On first run: scans entire library and converts any DoVi files
# Ongoing:      polls /scripts/queue for trigger files written by Radarr/Sonarr
#
# Resilience:
#   - Orphaned tmp dir cleanup on startup
#   - Atomic final rename via .part → .new → original
#   - Scan checkpoint — resumes from last position on restart
#   - Auto-blocklist for files that persistently fail conversion
#
# Notifications (all optional — set via environment variables):
#   ntfy, Gotify, Telegram, Discord, Email (SMTP), Apprise
#
# Requirements: ffmpeg, ffprobe, mkvmerge, stdbuf, bc, ionice, dovi_tool
#               curl (only if notifications are configured)
# Log file: /scripts/converter.log
# =============================================================================

set -euo pipefail

# ── constants ─────────────────────────────────────────────────────────────────
readonly LOG_FILE="/scripts/converter.log"
readonly DOVI_TOOL="/scripts/dovi_tool"
readonly QUEUE_DIR="/scripts/queue"
readonly SCAN_MARKER="/scripts/.initial_scan_done"
readonly CHECKPOINT_FILE="/scripts/.scan_checkpoint"
readonly BLOCKLIST="/scripts/blocklist.txt"
readonly IMPORTS_ROOT="/home/imports"

# ── tunable settings (override via environment variables) ─────────────────────
#
# POLL_INTERVAL   — seconds between queue checks (default: 10)
#                   Lower values mean faster response to new imports;
#                   higher values reduce idle CPU/NAS load.
#                   Example: POLL_INTERVAL=30
#
# RESCAN_INTERVAL — how often to run a full library rescan (default: disabled)
#                   Catches any files that slipped past the queue hook.
#                   Accepts: a number of hours, e.g. RESCAN_INTERVAL=24
#                   Set to 0 or leave unset to disable periodic rescans.
#
# MEDIA_DIRS      — space-separated list of directories to scan and watch.
#                   Defaults to auto-discovering all subdirectories under
#                   /home/imports, so simply bind any directory there and
#                   it will be picked up automatically.
#                   Override example: MEDIA_DIRS="/home/imports/movies /home/imports/4k"
#
POLL_INTERVAL="${POLL_INTERVAL:-10}"
RESCAN_INTERVAL="${RESCAN_INTERVAL:-0}"  # hours; 0 = disabled

# DELETE_UNSUPPORTED_PROFILES — when true, files using DoVi profiles that
# cannot be safely converted (4, 5) will be DELETED rather than left in place.
# This causes Radarr/Sonarr to re-download the content, ideally picking up
# a Profile 7/8 release on the second attempt if you have custom formats
# configured to prefer compatible profiles.
#
# Accepts: true | false   (default: false)
#
# Use with caution — this permanently deletes media files.
# Set to true only if you have Radarr/Sonarr configured to prevent Profile 5
# from being re-downloaded (see README for custom format setup).
DELETE_UNSUPPORTED_PROFILES="${DELETE_UNSUPPORTED_PROFILES:-false}"

# ── notification configuration ────────────────────────────────────────────────
# Configure via environment variables in docker-compose.yml.
# Set NOTIFY_SERVICE to the provider you want, then fill in its variables.
# Leave NOTIFY_SERVICE unset or empty to disable notifications entirely.
#
# NOTIFY_SERVICE options: ntfy | gotify | telegram | discord | email | apprise
#
# ── ntfy ──────────────────────────────────────────────────────────────────────
#   NOTIFY_SERVICE=ntfy
#   NTFY_URL=https://ntfy.your-server.com/your-topic
#   NTFY_AUTH=bearer                     # or: basic
#   NTFY_TOKEN=your_token                # or: username:password for basic auth
#
# ── Gotify ────────────────────────────────────────────────────────────────────
#   NOTIFY_SERVICE=gotify
#   GOTIFY_URL=https://gotify.your-server.com
#   GOTIFY_TOKEN=your_app_token
#
# ── Telegram ──────────────────────────────────────────────────────────────────
#   NOTIFY_SERVICE=telegram
#   TELEGRAM_BOT_TOKEN=123456:ABCdef...
#   TELEGRAM_CHAT_ID=your_chat_id
#
# ── Discord ───────────────────────────────────────────────────────────────────
#   NOTIFY_SERVICE=discord
#   DISCORD_WEBHOOK=https://discord.com/api/webhooks/...
#
# ── Email (SMTP) ──────────────────────────────────────────────────────────────
#   NOTIFY_SERVICE=email
#   SMTP_HOST=smtp.gmail.com
#   SMTP_PORT=465                        # 465 for SSL, 587 for STARTTLS
#   SMTP_USER=you@gmail.com
#   SMTP_PASS=your_app_password
#   SMTP_FROM=you@gmail.com
#   SMTP_TO=you@example.com
#
# ── Apprise ───────────────────────────────────────────────────────────────────
#   NOTIFY_SERVICE=apprise
#   APPRISE_URL=http://apprise.your-server.com
#   APPRISE_TOKEN=your_token             # optional, if your Apprise needs auth

NOTIFY_SERVICE="${NOTIFY_SERVICE:-}"
NTFY_URL="${NTFY_URL:-}"
NTFY_AUTH="${NTFY_AUTH:-bearer}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
GOTIFY_URL="${GOTIFY_URL:-}"
GOTIFY_TOKEN="${GOTIFY_TOKEN:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-465}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
SMTP_FROM="${SMTP_FROM:-}"
SMTP_TO="${SMTP_TO:-}"
APPRISE_URL="${APPRISE_URL:-}"
APPRISE_TOKEN="${APPRISE_TOKEN:-}"

# ── logging ───────────────────────────────────────────────────────────────────
ts()      { date '+%Y-%m-%d %H:%M:%S'; }
log()     { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }
log_err() { echo "[$(ts)] ERROR: $*" | tee -a "$LOG_FILE" >&2; }

# ── notifications ─────────────────────────────────────────────────────────────
# $1 = title  $2 = message body  $3 = priority hint (low|default|high)
notify() {
    [[ -n "$NOTIFY_SERVICE" ]] || return 0
    local title="$1" message="$2" priority="${3:-default}"

    case "${NOTIFY_SERVICE,,}" in

        ntfy)
            [[ -n "$NTFY_URL" && -n "$NTFY_TOKEN" ]] || {
                log_err "ntfy: NTFY_URL and NTFY_TOKEN must be set."
                return 0
            }
            local auth_header
            case "${NTFY_AUTH,,}" in
                bearer) auth_header="Authorization: Bearer ${NTFY_TOKEN}" ;;
                basic)  auth_header="Authorization: Basic $(printf '%s' "$NTFY_TOKEN" | base64)" ;;
                *)      log_err "ntfy: NTFY_AUTH must be 'bearer' or 'basic'."; return 0 ;;
            esac
            curl -fsS -m 10 \
                -H "$auth_header" \
                -H "Title: ${title}" \
                -H "Priority: ${priority}" \
                -H "Tags: cd" \
                -d "$message" \
                "$NTFY_URL" > /dev/null 2>&1 \
                || log_err "ntfy notification failed (curl exit $?)."
            ;;

        gotify)
            [[ -n "$GOTIFY_URL" && -n "$GOTIFY_TOKEN" ]] || {
                log_err "Gotify: GOTIFY_URL and GOTIFY_TOKEN must be set."
                return 0
            }
            # Map priority hint to Gotify priority (1-10)
            local gotify_priority=5
            [[ "$priority" == "low" ]]  && gotify_priority=2
            [[ "$priority" == "high" ]] && gotify_priority=8
            curl -fsS -m 10 \
                -H "X-Gotify-Key: ${GOTIFY_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"title\":\"${title}\",\"message\":\"${message}\",\"priority\":${gotify_priority}}" \
                "${GOTIFY_URL%/}/message" > /dev/null 2>&1 \
                || log_err "Gotify notification failed (curl exit $?)."
            ;;

        telegram)
            [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || {
                log_err "Telegram: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set."
                return 0
            }
            curl -fsS -m 10 \
                -d "chat_id=${TELEGRAM_CHAT_ID}" \
                -d "text=*${title}*%0A${message}" \
                -d "parse_mode=Markdown" \
                "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" > /dev/null 2>&1 \
                || log_err "Telegram notification failed (curl exit $?)."
            ;;

        discord)
            [[ -n "$DISCORD_WEBHOOK" ]] || {
                log_err "Discord: DISCORD_WEBHOOK must be set."
                return 0
            }
            # Map priority to Discord embed colour (green/blue/red)
            local colour=3447003   # blue (default)
            [[ "$priority" == "low" ]]  && colour=5763719  # green
            [[ "$priority" == "high" ]] && colour=15548997 # red
            curl -fsS -m 10 \
                -H "Content-Type: application/json" \
                -d "{\"embeds\":[{\"title\":\"${title}\",\"description\":\"${message}\",\"color\":${colour}}]}" \
                "$DISCORD_WEBHOOK" > /dev/null 2>&1 \
                || log_err "Discord notification failed (curl exit $?)."
            ;;

        email)
            [[ -n "$SMTP_HOST" && -n "$SMTP_USER" && -n "$SMTP_PASS" && -n "$SMTP_TO" ]] || {
                log_err "Email: SMTP_HOST, SMTP_USER, SMTP_PASS, and SMTP_TO must be set."
                return 0
            }
            local from="${SMTP_FROM:-$SMTP_USER}"
            local protocol="smtps"
            (( SMTP_PORT == 587 )) && protocol="smtp"
            curl -fsS -m 30 \
                --url "${protocol}://${SMTP_HOST}:${SMTP_PORT}" \
                --ssl-reqd \
                --user "${SMTP_USER}:${SMTP_PASS}" \
                --mail-from "$from" \
                --mail-rcpt "$SMTP_TO" \
                --upload-file - <<EOF > /dev/null 2>&1 \
                || log_err "Email notification failed (curl exit $?)."
From: dovi-converter <${from}>
To: ${SMTP_TO}
Subject: [dovi-converter] ${title}
Content-Type: text/plain

${title}

${message}

--
Sent by dovi-converter
EOF
            ;;

        apprise)
            [[ -n "$APPRISE_URL" ]] || {
                log_err "Apprise: APPRISE_URL must be set."
                return 0
            }
            # Map priority to Apprise priority (min/low/normal/high/max)
            local apprise_priority="normal"
            [[ "$priority" == "low" ]]  && apprise_priority="low"
            [[ "$priority" == "high" ]] && apprise_priority="high"
            # Build curl args as an array so auth header quoting is handled correctly
            local curl_args=(-fsS -m 10)
            [[ -n "$APPRISE_TOKEN" ]] && curl_args+=(-H "Authorization: Bearer ${APPRISE_TOKEN}")
            curl_args+=(
                -H "Content-Type: application/json"
                -d "{\"title\":\"${title}\",\"body\":\"${message}\",\"type\":\"${apprise_priority}\"}"
                "${APPRISE_URL%/}/notify"
            )
            curl "${curl_args[@]}" > /dev/null 2>&1 \
                || log_err "Apprise notification failed (curl exit $?)."
            ;;

        *)
            log_err "Unknown NOTIFY_SERVICE '${NOTIFY_SERVICE}'. Valid options: ntfy gotify telegram discord email apprise"
            ;;
    esac
}

# ── dependency check ──────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    local cmd
    for cmd in ffmpeg ffprobe mkvmerge stdbuf bc ionice; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ -x "$DOVI_TOOL" ]] || missing+=("dovi_tool (expected at $DOVI_TOOL)")
    # curl only required when notifications are configured
    if [[ -n "$NOTIFY_SERVICE" ]]; then
        command -v curl &>/dev/null || missing+=("curl")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_err "Missing required tools: ${missing[*]}"
        log_err "Ensure dovi_tool binary is placed at /scripts/dovi_tool and is executable."
        exit 1
    fi
}

# ── detect DoVi ───────────────────────────────────────────────────────────────
# Returns 0 if file contains DoVi metadata, 1 otherwise.
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

# ── detect DoVi profile ──────────────────────────────────────────────────────
# Returns the DoVi profile number (4, 5, 7, 8) or empty string if unknown.
# Profile 5 is NOT HDR10-compatible and must be skipped — stripping it produces
# washed-out, green/purple-tinted video because the base layer uses IPT-PQ-C2
# color space which is meaningless without the DoVi metadata.
# Profiles 7 and 8 have a proper HDR10-compatible base layer and are safe to strip.
get_dovi_profile() {
    local file="$1"
    local profile

    # Try mkvmerge --identify first — its JSON output reliably contains
    # the DOVI configuration record with the profile number.
    profile=$(mkvmerge --identify --identification-format json "$file" 2>/dev/null \
        | grep -oE '"dv_profile"[[:space:]]*:[[:space:]]*[0-9]+' \
        | grep -oE '[0-9]+$' \
        | head -1)

    if [[ -n "$profile" ]]; then
        echo "$profile"
        return 0
    fi

    # Fallback: parse ffprobe text output for "DOVI configuration record: ... profile: N"
    profile=$(ffprobe -v quiet -show_streams -select_streams v:0 "$file" 2>&1 \
        | grep -oE 'profile:[[:space:]]*[0-9]+' \
        | grep -oE '[0-9]+$' \
        | head -1)

    echo "${profile:-}"
}

# ── helpers ───────────────────────────────────────────────────────────────────

# Convert seconds (integer or float) to HH:MM:SS
format_duration() {
    local secs="${1%.*}"
    secs="${secs:-0}"
    printf '%02d:%02d:%02d' $(( secs / 3600 )) $(( secs % 3600 / 60 )) $(( secs % 60 ))
}

# Return total duration of a media file in seconds, or empty string on failure
get_duration() {
    ffprobe -v quiet \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$1" 2>/dev/null \
        | grep -o '^[0-9.]*'
}

# ── media directory discovery ────────────────────────────────────────────────
# Returns the list of directories to scan, one per line.
# Uses MEDIA_DIRS env var if set (space-separated), otherwise auto-discovers
# all immediate subdirectories of IMPORTS_ROOT (/home/imports).
# This means any path bound under /home/imports is picked up automatically
# without needing to reconfigure the script.
get_media_dirs() {
    if [[ -n "${MEDIA_DIRS:-}" ]]; then
        # User explicitly set MEDIA_DIRS — split on whitespace
        local dir
        for dir in $MEDIA_DIRS; do
            echo "$dir"
        done
    else
        # Auto-discover: every immediate subdirectory of /home/imports
        if [[ ! -d "$IMPORTS_ROOT" ]]; then
            log_err "Imports root not found: $IMPORTS_ROOT — no directories to scan."
            return 1
        fi
        find "$IMPORTS_ROOT" -mindepth 1 -maxdepth 1 -type d | sort
    fi
}

# ── orphaned tmp dir cleanup ──────────────────────────────────────────────────
cleanup_orphaned_tmpdirs() {
    log "Checking for orphaned temp directories..."
    local count=0
    local media_dir tmpdir
    while IFS= read -r media_dir; do
        [[ -d "$media_dir" ]] || continue
        while IFS= read -r -d '' tmpdir; do
            log "  Removing orphaned tmp dir: $tmpdir"
            rm -rf "$tmpdir"
            (( count++ )) || true
        done < <(find "$media_dir" -mindepth 2 -maxdepth 2 \
            -type d -name ".dovi_tmp_*" -print0 2>/dev/null)
    done < <(get_media_dirs)
    if [[ $count -gt 0 ]]; then
        log "  Cleaned up $count orphaned tmp director(ies)."
    else
        log "  None found."
    fi
}

# ── scan checkpoint ───────────────────────────────────────────────────────────

write_checkpoint() {
    local tmp
    tmp=$(mktemp "${CHECKPOINT_FILE}.XXXXXX")
    printf '%s' "$1" > "$tmp"
    mv -f "$tmp" "$CHECKPOINT_FILE"
}

clear_checkpoint() { rm -f "$CHECKPOINT_FILE"; }

read_checkpoint() {
    [[ -f "$CHECKPOINT_FILE" ]] && cat "$CHECKPOINT_FILE" || echo ""
}

# ── progress monitor (background) ────────────────────────────────────────────
progress_monitor() {
    local progress_pipe="$1"
    local total_secs="$2"
    local start_time="$3"
    local last_pct=-1
    local total_int="${total_secs%.*}"
    total_int="${total_int:-0}"

    while IFS= read -r line; do
        if [[ "$line" =~ ^out_time_us=([0-9]+)$ ]]; then
            local elapsed_us="${BASH_REMATCH[1]}"
            local elapsed_secs pct=0

            elapsed_secs=$(echo "scale=2; $elapsed_us / 1000000" | bc 2>/dev/null)
            elapsed_secs="${elapsed_secs:-0}"

            if [[ $total_int -gt 0 ]]; then
                pct=$(echo "scale=0; ($elapsed_secs * 100) / $total_secs" | bc 2>/dev/null)
                pct="${pct:-0}"
                (( pct > 99 )) && pct=99
            fi

            local boundary=$(( (pct / 10) * 10 ))
            if (( boundary > last_pct && boundary > 0 )); then
                last_pct=$boundary

                local now wall_elapsed eta_fmt="--:--:--"
                now=$(date +%s)
                wall_elapsed=$(( now - start_time ))

                if (( wall_elapsed > 0 )); then
                    local eta_secs
                    eta_secs=$(echo "scale=0; ($wall_elapsed * (100 - $boundary)) / $boundary" \
                        | bc 2>/dev/null)
                    eta_fmt=$(format_duration "${eta_secs:-0}")
                fi

                log "  Progress: ${boundary}% | position $(format_duration "$elapsed_secs")/$(format_duration "$total_secs") | elapsed $(format_duration "$wall_elapsed") | ETA ${eta_fmt}"
            fi
        fi

        [[ "$line" == "progress=end" ]] && break
    done < "$progress_pipe"
}

# ── strip DoVi from a single file, replace in-place ──────────────────────────
strip_single() {
    local input="$1"
    local dir; dir="$(dirname "$input")"
    local tmpdir

    tmpdir="$(mktemp -d "${dir}/.dovi_tmp_XXXXXX")"
    local clean_hevc="${tmpdir}/video_hdr10.hevc"
    local output_part="${tmpdir}/output.part.mkv"

    trap 'rm -rf "${tmpdir:?}" 2>/dev/null || true' EXIT INT TERM

    local total_secs
    total_secs=$(get_duration "$input")
    total_secs="${total_secs:-}"
    local start_time; start_time=$(date +%s)

    if [[ -n "$total_secs" ]] && (( ${total_secs%.*} > 0 )); then
        log "  File duration: $(format_duration "$total_secs")"
    fi

    log "  Stripping Dolby Vision layer..."

    local progress_pipe="${tmpdir}/progress.pipe"
    mkfifo "$progress_pipe"
    progress_monitor "$progress_pipe" "$total_secs" "$start_time" &
    local monitor_pid=$!

    # Run ffmpeg + dovi_tool in a subshell with stdin closed (</dev/null).
    # This prevents dovi_tool's isatty() check from detecting a TTY and
    # entering interactive mode, which stalls the pipeline indefinitely.
    (
        ffmpeg -hide_banner -loglevel error \
            -progress "$progress_pipe" \
            -i "$input" \
            -map 0:v:0 \
            -c:v copy \
            -bsf:v hevc_mp4toannexb \
            -f hevc \
            - \
            | ionice -c 3 nice -n 19 "$DOVI_TOOL" remove \
                --input - \
                --output "$clean_hevc"
        echo "${PIPESTATUS[*]}" > "${tmpdir}/pipe_status"
    ) </dev/null

    wait "$monitor_pid" 2>/dev/null || true

    local pipe_codes ffmpeg_exit dovi_exit
    read -r pipe_codes < "${tmpdir}/pipe_status" 2>/dev/null || pipe_codes="1 1"
    ffmpeg_exit="${pipe_codes%% *}"
    dovi_exit="${pipe_codes##* }"
    ffmpeg_exit="${ffmpeg_exit:-1}"
    dovi_exit="${dovi_exit:-1}"

    if (( ffmpeg_exit != 0 || dovi_exit != 0 )); then
        log_err "  Pipeline failed (ffmpeg=$ffmpeg_exit dovi=$dovi_exit) on: $(basename "$input")"
        return 1
    fi

    if [[ ! -s "$clean_hevc" ]]; then
        log_err "  dovi_tool produced empty output — original untouched."
        return 1
    fi

    local end_time; end_time=$(date +%s)
    log "  Strip complete in $(format_duration $(( end_time - start_time )))"

    # Count non-video tracks for the summary log line.
    # Single identify call — parsed twice in memory to avoid a second NAS read.
    local identify_json other_tracks
    identify_json=$(mkvmerge --identify --identification-format json "$input" 2>/dev/null)
    local track_count video_count
    track_count=$(echo "$identify_json" | grep -o '"type"' | wc -l)
    video_count=$(echo "$identify_json" | grep -c '"video"' || true)
    other_tracks=$(( track_count > video_count ? track_count - video_count : 0 ))
    log "  Remuxing $other_tracks non-video track(s) from original..."

    # stdbuf -oL forces mkvmerge to flush its stdout after every line rather
    # than buffering in large chunks. Without this, all #GUI#progress lines
    # arrive at once at completion, making the progress display useless.
    local mux_start; mux_start=$(date +%s)
    local last_mux_pct=-1
    while IFS= read -r mux_line; do
        if [[ "$mux_line" =~ ^'#GUI#progress '([0-9]+)'%' ]]; then
            local mux_pct="${BASH_REMATCH[1]}"
            local mux_boundary=$(( (mux_pct / 10) * 10 ))
            if (( mux_boundary > last_mux_pct && mux_boundary > 0 )); then
                last_mux_pct=$mux_boundary
                local mux_now mux_elapsed mux_eta_fmt="--:--:--"
                mux_now=$(date +%s)
                mux_elapsed=$(( mux_now - mux_start ))
                if (( mux_elapsed > 0 )); then
                    local mux_eta
                    mux_eta=$(echo "scale=0; ($mux_elapsed * (100 - $mux_boundary)) / $mux_boundary" \
                        | bc 2>/dev/null)
                    mux_eta_fmt=$(format_duration "${mux_eta:-0}")
                fi
                log "  Remux: ${mux_boundary}% | elapsed $(format_duration "$mux_elapsed") | ETA ${mux_eta_fmt}"
            fi
        elif [[ "$mux_line" =~ ^'#GUI#error' ]]; then
            log_err "  mkvmerge reported: $mux_line"
        fi
    done < <(stdbuf -oL mkvmerge \
        --gui-mode \
        --quiet \
        --output "$output_part" \
        "$clean_hevc" \
        --no-video \
        "$input" 2>&1)

    local mux_exit=$?
    if (( mux_exit >= 2 )); then
        log_err "  mkvmerge failed (exit $mux_exit) on: $(basename "$input")"
        return 1
    fi

    local mux_end; mux_end=$(date +%s)
    log "  Remux: 100% | Done in $(format_duration $(( mux_end - mux_start )))"

    if [[ ! -s "$output_part" ]] || (( $(stat -c%s "$output_part") < 1048576 )); then
        log_err "  Output missing or suspiciously small — original untouched."
        return 1
    fi

    # Atomic replace: move finished file out of tmpdir then over the original.
    # If interrupted between the two mv calls, the original is still intact
    # and the .new file is cleaned up on next startup.
    local final_new="${input}.new"
    log "  Finalising (atomic replace)..."
    mv -f "$output_part" "$final_new"
    mv -f "$final_new" "$input"

    log "  ✓ Done: $(basename "$input")"
    # trap fires here, removing tmpdir
}

# ── process a single file ─────────────────────────────────────────────────────
process_file() {
    local input="$1"
    local base; base="$(basename "$input")"

    [[ "${input,,}" == *.mkv ]] || return 0

    if [[ "$base" == .dovi_tmp_* || "$base" == *.part.mkv || "$base" == *.new ]]; then
        return 0
    fi

    if [[ -f "$BLOCKLIST" ]] && grep -qF "$input" "$BLOCKLIST" 2>/dev/null; then
        log "Blocklisted, skipping: $base"
        return 0
    fi

    if ! has_dovi "$input"; then
        log "No DoVi detected, skipping: $base"
        return 0
    fi

    # Check DoVi profile — Profile 5 is NOT HDR10-compatible and must not be
    # stripped. Stripping Profile 5 produces washed-out, green/purple-tinted
    # video. Files without a detectable HDR10-compatible base layer are
    # blocklisted so they are not damaged on future runs.
    local dovi_profile
    dovi_profile=$(get_dovi_profile "$input")

    # Only profiles 7 and 8 have a valid HDR10 base layer.
    # Profile 4 and 5 use IPT-PQ-C2 colour encoding and cannot be safely stripped.
    # An unknown profile is treated as unsafe — better to leave the file untouched
    # than risk producing broken colours.
    case "$dovi_profile" in
        7|8)
            : # safe to strip, fall through to conversion below
            ;;
        4|5)
            log_err "Profile $dovi_profile DoVi detected — NOT HDR10-compatible, cannot strip: $base"
            log_err "  Profile $dovi_profile files use IPT-PQ-C2 colour encoding that requires"
            log_err "  the DoVi metadata to render correctly."

            if [[ "${DELETE_UNSUPPORTED_PROFILES,,}" == "true" ]]; then
                log_err "  DELETE_UNSUPPORTED_PROFILES=true — deleting file so Radarr/Sonarr re-downloads."
                if rm -f "$input"; then
                    log "Deleted: $input"
                    notify "DoVi Profile $dovi_profile deleted" "$base — file removed so Radarr/Sonarr will re-download" "high"
                else
                    log_err "Failed to delete file: $input"
                    echo "$input" >> "$BLOCKLIST"
                    notify "DoVi Profile $dovi_profile delete failed" "$base" "high"
                fi
            else
                log_err "  Re-download from a different source (BluRay rip, non-Netflix WEB-DL,"
                log_err "  or Profile 7/8 release), or set DELETE_UNSUPPORTED_PROFILES=true to"
                log_err "  auto-delete and trigger a re-download via Radarr/Sonarr."
                echo "$input" >> "$BLOCKLIST"
                log_err "Added to blocklist: $base"
                notify "DoVi Profile $dovi_profile skipped" "$base (not HDR10-compatible)" "high"
            fi
            return 0
            ;;
        *)
            log_err "Unknown or unsupported DoVi profile '${dovi_profile:-none detected}' on: $base"
            log_err "  Leaving file untouched as a precaution."
            echo "$input" >> "$BLOCKLIST"
            log_err "Added to blocklist: $base"
            notify "DoVi profile unknown" "$base — skipped as a precaution" "high"
            return 0
            ;;
    esac

    log "DoVi detected (profile ${dovi_profile:-unknown}): $base"
    notify "DoVi conversion started" "$base" "default"

    if strip_single "$input"; then
        notify "DoVi conversion complete" "$base" "low"
        return 0
    fi

    log_err "Conversion failed: $input"
    echo "$input" >> "$BLOCKLIST"
    log_err "Added to blocklist — will skip on future runs: $base"
    notify "DoVi conversion failed" "$base — added to blocklist" "high"
    return 0
}

# ── initial library scan ──────────────────────────────────────────────────────
initial_scan() {
    local checkpoint
    checkpoint=$(read_checkpoint)

    if [[ -n "$checkpoint" ]]; then
        log "════════════════════════════════════════════════════"
        log "RESUMING LIBRARY SCAN"
        log "  Continuing after: $checkpoint"
        log "════════════════════════════════════════════════════"
    else
        log "════════════════════════════════════════════════════"
        log "INITIAL LIBRARY SCAN STARTING"
        log "  Scanning directories:"
        local d
        while IFS= read -r d; do log "    $d"; done < <(get_media_dirs)
        log "════════════════════════════════════════════════════"
    fi

    local total=0
    local resuming=false
    [[ -n "$checkpoint" ]] && resuming=true

    local media_dir file
    while IFS= read -r media_dir; do
        if [[ ! -d "$media_dir" ]]; then
            log_err "Media directory not found: $media_dir — skipping."
            continue
        fi

        while IFS= read -r -d '' file; do
            if [[ "$resuming" == true ]]; then
                if [[ "$file" == "$checkpoint" ]]; then
                    resuming=false
                    log "Checkpoint reached — resuming."
                fi
                continue
            fi

            (( total++ )) || true
            log "────────────────────────────────────────────────────"
            log "[$total] $file"

            process_file "$file"
            write_checkpoint "$file"

        done < <(find "$media_dir" -type f -iname "*.mkv" \
            ! -name ".*" \
            ! -name "*.part.mkv" \
            ! -name "*.new" \
            -print0 | sort -z)
    done < <(get_media_dirs)

    log "════════════════════════════════════════════════════"
    log "LIBRARY SCAN COMPLETE — $total file(s) checked this run"
    log "════════════════════════════════════════════════════"

    touch "$SCAN_MARKER"
    clear_checkpoint
}

# ── queue polling loop ────────────────────────────────────────────────────────
poll_queue() {
    local rescan_secs=0
    if [[ "${RESCAN_INTERVAL:-0}" -gt 0 ]] 2>/dev/null; then
        rescan_secs=$(( RESCAN_INTERVAL * 3600 ))
        log "Periodic rescan enabled — every ${RESCAN_INTERVAL}h"
    fi

    log "════════════════════════════════════════════════════"
    log "POLLING QUEUE — checking every ${POLL_INTERVAL}s"
    [[ $rescan_secs -gt 0 ]] && log "  Full rescan every ${RESCAN_INTERVAL}h"
    log "  Queue: $QUEUE_DIR"
    log "════════════════════════════════════════════════════"

    mkdir -p "$QUEUE_DIR"

    local last_rescan; last_rescan=$(date +%s)
    local job_file file_path
    while true; do
        # Process any queued import jobs
        for job_file in "$QUEUE_DIR"/*.job; do
            [[ -f "$job_file" ]] || continue

            file_path=$(cat "$job_file" 2>/dev/null) || true
            rm -f "$job_file"

            file_path="${file_path%$'\n'}"
            file_path="${file_path%$'\r'}"

            if [[ -z "$file_path" ]]; then
                log_err "Empty job file — skipping: $(basename "$job_file")"
                continue
            fi

            if [[ ! -f "$file_path" ]]; then
                log_err "File not found: $file_path"
                continue
            fi

            log "════════════════════════════════════════════════════"
            log "NEW IMPORT: $file_path"
            process_file "$file_path"
        done

        # Check if a periodic full rescan is due
        if [[ $rescan_secs -gt 0 ]]; then
            local now elapsed
            now=$(date +%s)
            elapsed=$(( now - last_rescan ))
            if (( elapsed >= rescan_secs )); then
                log "════════════════════════════════════════════════════"
                log "PERIODIC RESCAN TRIGGERED (interval: ${RESCAN_INTERVAL}h)"
                log "════════════════════════════════════════════════════"
                rm -f "$SCAN_MARKER"
                clear_checkpoint
                initial_scan
                last_rescan=$(date +%s)
            fi
        fi

        sleep "$POLL_INTERVAL"
    done
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$QUEUE_DIR"

    log "════════════════════════════════════════════════════"
    log "dovi-converter starting up"
    log "  Poll interval   : ${POLL_INTERVAL}s"
    if [[ "${RESCAN_INTERVAL:-0}" -gt 0 ]] 2>/dev/null; then
        log "  Rescan interval : every ${RESCAN_INTERVAL}h"
    else
        log "  Rescan interval : disabled"
    fi
    if [[ "${DELETE_UNSUPPORTED_PROFILES,,}" == "true" ]]; then
        log "  Profile 4/5     : DELETE (will trigger Radarr/Sonarr re-download)"
    else
        log "  Profile 4/5     : skip & blocklist (safe default)"
    fi
    if [[ -n "${MEDIA_DIRS:-}" ]]; then
        log "  Media dirs      : ${MEDIA_DIRS} (from MEDIA_DIRS env var)"
    else
        log "  Media dirs      : auto-discover under ${IMPORTS_ROOT}"
    fi
    log "════════════════════════════════════════════════════"

    check_deps
    cleanup_orphaned_tmpdirs

    if [[ ! -f "$SCAN_MARKER" ]]; then
        initial_scan
    else
        log "Initial scan already completed — entering queue polling mode."
        local media_dir
        while IFS= read -r media_dir; do
            [[ -d "$media_dir" ]] || continue
            find "$media_dir" -name "*.new" -type f -delete 2>/dev/null || true
        done < <(get_media_dirs)
    fi

    poll_queue
}

main "$@"
