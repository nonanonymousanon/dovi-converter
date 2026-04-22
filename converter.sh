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
readonly MEDIA_DIRS=("/home/imports/movies" "/home/imports/shows")
readonly POLL_INTERVAL=10  # seconds between queue checks

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
            local apprise_auth=""
            [[ -n "$APPRISE_TOKEN" ]] && apprise_auth="-H \"Authorization: Bearer ${APPRISE_TOKEN}\""
            # Map priority to Apprise priority (min/low/normal/high/max)
            local apprise_priority="normal"
            [[ "$priority" == "low" ]]  && apprise_priority="low"
            [[ "$priority" == "high" ]] && apprise_priority="high"
            curl -fsS -m 10 \
                ${apprise_auth:+-H "$APPRISE_TOKEN"} \
                -H "Content-Type: application/json" \
                -d "{\"title\":\"${title}\",\"body\":\"${message}\",\"type\":\"${apprise_priority}\"}" \
                "${APPRISE_URL%/}/notify" > /dev/null 2>&1 \
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
has_dovi() {
    local file="$1"
    # Two complementary checks covering different ffprobe output formats:
    #   1. Text output: "DOVI configuration record" appears in the human-readable
    #      stream summary and is the most reliable indicator across ffprobe versions.
    #   2. JSON output: catches dv_bl_signal_compatibility_id and other structured
    #      DoVi codec tags that only appear in JSON format.
    # stderr is merged with stdout on both calls since ffprobe occasionally
    # prints codec side-data information there.
    ffprobe -v quiet -show_streams -select_streams v:0 \
        "$file" 2>&1 \
        | grep -qi "DOVI configuration\|dv_profile" \
        && return 0
    ffprobe -v quiet -show_streams -select_streams v:0 \
        -print_format json "$file" 2>&1 \
        | grep -qi "dv_bl_signal_compatibility_id\|dolby.vision" \
        && return 0
    return 1
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

# ── orphaned tmp dir cleanup ──────────────────────────────────────────────────
cleanup_orphaned_tmpdirs() {
    log "Checking for orphaned temp directories..."
    local count=0
    local media_dir tmpdir
    for media_dir in "${MEDIA_DIRS[@]}"; do
        [[ -d "$media_dir" ]] || continue
        while IFS= read -r -d '' tmpdir; do
            log "  Removing orphaned tmp dir: $tmpdir"
            rm -rf "$tmpdir"
            (( count++ )) || true
        done < <(find "$media_dir" -mindepth 2 -maxdepth 2 \
            -type d -name ".dovi_tmp_*" -print0 2>/dev/null)
    done
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

    log "DoVi detected: $base"
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
        for d in "${MEDIA_DIRS[@]}"; do log "    $d"; done
        log "════════════════════════════════════════════════════"
    fi

    local total=0
    local resuming=false
    [[ -n "$checkpoint" ]] && resuming=true

    local media_dir file
    for media_dir in "${MEDIA_DIRS[@]}"; do
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
    done

    log "════════════════════════════════════════════════════"
    log "LIBRARY SCAN COMPLETE — $total file(s) checked this run"
    log "════════════════════════════════════════════════════"

    touch "$SCAN_MARKER"
    clear_checkpoint
}

# ── queue polling loop ────────────────────────────────────────────────────────
poll_queue() {
    log "════════════════════════════════════════════════════"
    log "POLLING QUEUE — checking every ${POLL_INTERVAL}s"
    log "  Queue: $QUEUE_DIR"
    log "════════════════════════════════════════════════════"

    mkdir -p "$QUEUE_DIR"

    local job_file file_path
    while true; do
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

        sleep "$POLL_INTERVAL"
    done
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$QUEUE_DIR"

    log "════════════════════════════════════════════════════"
    log "dovi-converter starting up"
    log "════════════════════════════════════════════════════"

    check_deps
    cleanup_orphaned_tmpdirs

    if [[ ! -f "$SCAN_MARKER" ]]; then
        initial_scan
    else
        log "Initial scan already completed — entering queue polling mode."
        local media_dir
        for media_dir in "${MEDIA_DIRS[@]}"; do
            [[ -d "$media_dir" ]] || continue
            find "$media_dir" -name "*.new" -type f -delete 2>/dev/null || true
        done
    fi

    poll_queue
}

main "$@"
