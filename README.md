# dovi-converter

A Docker container that automatically strips Dolby Vision metadata from MKV files, converting them to clean HDR10 for universal playback — particularly on Apple devices running Plex.

## Why this exists

Dolby Vision is a proprietary HDR format that causes colour issues on Apple devices (iOS, macOS, tvOS) when played through Plex. The native Plex app cannot transcode DoVi due to licensing restrictions. This container solves the problem by stripping the DoVi layer from files, exposing the HDR10 base layer that was always embedded inside them.

**The conversion is lossless** — no video is re-encoded. The HDR10 base layer is bit-for-bit identical to what was always in the file. The only change is the removal of the Dolby Vision metadata layer.

## Features

- **Automatic library scan** on first run — converts all existing DoVi files
- **Radarr/Sonarr integration** — converts new imports automatically via a shared job queue
- **Scan checkpoint** — resumes from where it left off after a restart
- **Atomic file replacement** — originals are never at risk during conversion
- **Orphaned temp file cleanup** — cleans up after crashes or OOM kills on startup
- **Auto-blocklist** — files that fail conversion are skipped on future runs
- **Progress logging** — strip and remux progress with ETA displayed every 10%
- **Notifications** — optional support for ntfy, Gotify, Telegram, Discord, Email, and Apprise

## Requirements

### Host / Docker
- Docker and Docker Compose
- Radarr and/or Sonarr (optional — for automatic new import conversion)

### Tools (installed automatically in the container)
- `ffmpeg` and `ffprobe`
- `mkvmerge` (MKVToolNix)
- `bc`, `stdbuf`, `ionice`
- `curl` (only if notifications are configured)

### Manual download required
- **`dovi_tool`** — must be downloaded separately due to licensing. Get the latest Linux binary from [github.com/quietvoid/dovi_tool/releases](https://github.com/quietvoid/dovi_tool/releases) and place it at `/path/to/config/dovi-converter/scripts/dovi_tool`.

```bash
# Example for x86_64 Linux:
wget https://github.com/quietvoid/dovi_tool/releases/download/2.3.2/dovi_tool-2.3.2-x86_64-unknown-linux-musl.tar.gz
tar -xzf dovi_tool-2.3.2-x86_64-unknown-linux-musl.tar.gz
cp dovi_tool /path/to/config/dovi-converter/scripts/dovi_tool
chmod +x /path/to/config/dovi-converter/scripts/dovi_tool
```

## Installation

### 1. Create the directory structure

```bash
mkdir -p /path/to/config/dovi-converter/scripts
mkdir -p /path/to/config/dovi-converter/queue
```

### 2. Download dovi_tool

See [Requirements](#requirements) above.

### 3. Build the Docker image

```bash
docker build -t dovi-converter ./docker/
```

### 4. Configure and start

Copy `docker/docker-compose.yml`, adjust the paths and optional settings, then:

```bash
docker compose up -d dovi-converter
```

### 5. Set up Radarr and Sonarr integration (optional)

Copy `enqueue_dovi.sh` into both arr config directories and make it executable:

```bash
cp enqueue_dovi.sh /path/to/config/radarr/dovi_enqueue.sh
cp enqueue_dovi.sh /path/to/config/sonarr/dovi_enqueue.sh
chmod +x /path/to/config/radarr/dovi_enqueue.sh
chmod +x /path/to/config/sonarr/dovi_enqueue.sh
```

In both Radarr and Sonarr:
`Settings → Connect → + → Custom Script`
- **Path:** `/config/dovi_enqueue.sh`
- **Events:** ✅ On Import, ✅ On Upgrade — everything else off

Click **Test** to verify the connection.

## Volume mounts

| Container path | Purpose |
|---|---|
| `/scripts` | Scripts directory — place `dovi_tool` binary here |
| `/home/queue` | Shared job queue — Radarr/Sonarr write `.job` files here |
| `/home/imports/*` | Any subdirectory bound here is scanned automatically |

You can bind as many media directories as you like under `/home/imports`:

```yaml
volumes:
  - /path/to/media/Movies:/home/imports/movies
  - /path/to/media/Shows:/home/imports/shows
  - /path/to/media/4K:/home/imports/4k
  - /path/to/media/Anime:/home/imports/anime
```

All of them will be discovered and scanned without any additional configuration.

## Environment variables

### Required
| Variable | Description |
|---|---|
| `PUID` | User ID to run as |
| `PGID` | Group ID to run as |
| `TZ` | Timezone (e.g. `America/New_York`) |

### Tunable settings (optional)
| Variable | Default | Description |
|---|---|---|
| `POLL_INTERVAL` | `10` | Seconds between queue checks. Lower = faster response to new imports; higher = less idle load. |
| `RESCAN_INTERVAL` | `0` (disabled) | Hours between automatic full library rescans. Useful as a safety net to catch files that slipped past the queue hook. Set to `0` to disable. |
| `MEDIA_DIRS` | auto-discover | Space-separated list of directories to scan. By default, every subdirectory mounted under `/home/imports` is discovered automatically — just bind your directories there and they are picked up with no configuration. Only set this variable if you need to restrict scanning to specific paths. |

### Notifications (all optional)

Set `NOTIFY_SERVICE` to your provider name. Leave unset to disable notifications.

| Variable | Description |
|---|---|
| `NOTIFY_SERVICE` | Provider: `ntfy` \| `gotify` \| `telegram` \| `discord` \| `email` \| `apprise` |

#### ntfy
| Variable | Description |
|---|---|
| `NTFY_URL` | Full topic URL e.g. `https://ntfy.sh/your-topic` |
| `NTFY_AUTH` | Auth method: `bearer` (default) or `basic` |
| `NTFY_TOKEN` | Bearer token, or `username:password` for basic auth |

#### Gotify
| Variable | Description |
|---|---|
| `GOTIFY_URL` | Your Gotify server URL |
| `GOTIFY_TOKEN` | Gotify app token |

#### Telegram
| Variable | Description |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Bot token from @BotFather |
| `TELEGRAM_CHAT_ID` | Chat or channel ID |

#### Discord
| Variable | Description |
|---|---|
| `DISCORD_WEBHOOK` | Full Discord webhook URL |

#### Email (SMTP)
| Variable | Description | Default |
|---|---|---|
| `SMTP_HOST` | SMTP server hostname | |
| `SMTP_PORT` | SMTP port | `465` |
| `SMTP_USER` | SMTP username | |
| `SMTP_PASS` | SMTP password or app password | |
| `SMTP_FROM` | From address | Same as `SMTP_USER` |
| `SMTP_TO` | Recipient address | |

#### Apprise
| Variable | Description |
|---|---|
| `APPRISE_URL` | Apprise server URL |
| `APPRISE_TOKEN` | Auth token (optional) |

## Monitoring

All activity is logged to `/scripts/converter.log` inside the container, which maps to `/path/to/config/dovi-converter/scripts/converter.log` on the host.

```bash
tail -f /path/to/config/dovi-converter/scripts/converter.log
```

Sample log output during conversion:

```text
[2026-04-22 12:00:21]   DoVi detected: Ballerina.2025.2160p.UHD.Blu-ray.Remux.DV.HDR.mkv
[2026-04-22 12:00:21]   File duration: 02:04:39
[2026-04-22 12:00:21]   Stripping Dolby Vision layer...
[2026-04-22 12:01:04]   Progress: 30% | position 00:37:34/02:04:39 | elapsed 00:00:43 | ETA 00:01:40
[2026-04-22 12:09:15]   Strip complete in 00:09:15
[2026-04-22 12:09:15]   Remuxing 22 non-video track(s) from original...
[2026-04-22 12:09:20]   Remux: 10% | elapsed 00:00:05 | ETA 00:00:45
[2026-04-22 12:10:43]   Remux: 100% | Done in 00:01:28
[2026-04-22 12:10:43]   ✓ Done: Ballerina.2025.2160p.UHD.Blu-ray.Remux.DV.HDR.mkv
```

## Blocklist

Files that fail conversion are automatically added to `/scripts/blocklist.txt` and skipped on future runs. To retry a file, remove its line from the blocklist and restart the container with the scan marker deleted:

```bash
# Edit the blocklist to remove the entry
nano /path/to/config/dovi-converter/scripts/blocklist.txt

# Force a rescan (optional — only needed if you want to recheck the whole library)
rm /path/to/config/dovi-converter/scripts/.initial_scan_done
rm -f /path/to/config/dovi-converter/scripts/.scan_checkpoint
docker restart dovi-converter
```

## Standalone batch conversion

`strip_dovi.sh` is a standalone script for one-off batch conversion without Docker. It performs the same lossless strip operation on all MKV files in a directory.

```bash
# Install dependencies
sudo apt install ffmpeg mkvtoolnix
# Place dovi_tool in PATH

chmod +x strip_dovi.sh
./strip_dovi.sh /path/to/your/media
```

## How it works

For each DoVi MKV file:

1. `ffprobe` detects the Dolby Vision layer
2. `ffmpeg` extracts the HEVC video stream in Annex B format, piped directly to:
3. `dovi_tool remove` strips the DoVi RPU metadata, writing clean HDR10 HEVC
4. `mkvmerge` remuxes the clean video with all original audio, subtitle, and chapter tracks
5. The output is atomically renamed over the original

The HDR10 base layer was always present inside the DoVi file — this process simply removes the DoVi metadata that was causing playback issues.

## Compatibility

Tested with:
- Dolby Vision Profile 5 (streaming services)
- Dolby Vision Profile 7 (Blu-ray remuxes)
- Dolby Vision Profile 8 (hybrid WEB-DL)

Files with corrupted DoVi metadata (where `dovi_tool` cannot parse the RPU) are automatically added to the blocklist.

## Acknowledgements

- [dovi_tool](https://github.com/quietvoid/dovi_tool) by quietvoid — the core tool that makes DoVi stripping possible
- [MKVToolNix](https://mkvtoolnix.download/) — for reliable MKV remuxing
- [FFmpeg](https://ffmpeg.org/) — for HEVC stream extraction

## License

MIT
