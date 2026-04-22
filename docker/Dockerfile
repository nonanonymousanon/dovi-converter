# =============================================================================
# Dockerfile — dovi-converter
#
# Builds on linuxserver/ffmpeg (which includes ffmpeg, ffprobe, mkvmerge)
# and adds the converter script as the container entrypoint.
#
# dovi_tool is NOT included here — you supply the binary by placing it at:
#   /container-configs/dovi-converter/scripts/dovi_tool
# It is mounted in via the volume bind in docker-compose.yml
# =============================================================================

FROM linuxserver/ffmpeg:latest

# mkvtoolnix provides mkvmerge
RUN apt-get update && \
    apt-get install -y --no-install-recommends mkvtoolnix bc curl coreutils && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy converter script into image
COPY converter.sh /converter.sh
RUN chmod +x /converter.sh

ENTRYPOINT ["/converter.sh"]
