#!/usr/bin/env bash
# =============================================================================
# enqueue_dovi.sh — Radarr / Sonarr Custom Script hook
#
# Place this file in BOTH:
#   /container-configs/radarr/dovi_enqueue.sh
#   /container-configs/sonarr/dovi_enqueue.sh
#
# In Radarr/Sonarr set Custom Script path to: /config/dovi_enqueue.sh
# Events: On Import, On Upgrade only
#
# This script does one thing: writes the imported file path into the
# shared queue directory so the dovi-converter container can pick it up.
# No docker exec, no network calls — just a file write.
# =============================================================================

QUEUE_DIR="/home/queue"

# Handle test event from Radarr/Sonarr UI
EVENT="${radarr_eventtype:-${sonarr_eventtype:-unknown}}"
if [[ "$EVENT" == "Test" ]]; then
    echo "DoVi enqueue hook: test OK"
    exit 0
fi

# Only act on imports and upgrades
if [[ "$EVENT" != "Download" ]]; then
    exit 0
fi

# Resolve file path from whichever arr is calling
FILE_PATH="${radarr_moviefile_path:-${sonarr_episodefile_path:-}}"

if [[ -z "$FILE_PATH" ]]; then
    echo "ERROR: Could not resolve file path from environment" >&2
    exit 1
fi

# Write a job file to the queue directory
# Job filename uses timestamp + random suffix to avoid collisions
JOB_FILE="${QUEUE_DIR}/$(date +%s%N)_$$.job"
echo "$FILE_PATH" > "$JOB_FILE"

echo "Queued for DoVi conversion: $FILE_PATH"
exit 0
