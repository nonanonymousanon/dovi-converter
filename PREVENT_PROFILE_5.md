# Preventing DoVi Profile 5 downloads in Radarr/Sonarr

DoVi Profile 5 files (common in Netflix, Apple TV+, and other streaming-service WEB-DLs) use the IPT-PQ-C2 colour space which is **not backwards compatible with HDR10**. Stripping DoVi from a Profile 5 file produces washed-out, green/purple tinted video.

`dovi-converter` now refuses to convert Profile 5 files. To prevent Radarr/Sonarr from downloading them in the first place, you can set up **custom formats** that score releases based on their DoVi profile.

The easiest way to do this is to use the community-maintained [TRaSH Guides](https://trash-guides.info/) and their companion tool [Recyclarr](https://recyclarr.dev/), which syncs custom formats automatically. The manual approach below sets up only what's needed for profile filtering.

## Manual setup (Radarr)

### 1. Create the "DV HDR10" custom format (what you WANT)

`Settings → Custom Formats → +`

- **Name:** `DV HDR10`
- **Conditions → + → Release Title:**
  - **Name:** `DV HDR10`
  - **Implementation:** `Release Title`
  - **Regular Expression:** ✅ checked
  - **Value:** `(?=.*(dv|dovi|dolby[ .]?vision))(?=.*(hdr10|hdr)).*`

This matches releases that explicitly advertise both DoVi and HDR10 — typically Profile 7 or Profile 8, which are safe to strip.

### 2. Create the "DV Only (Profile 5)" custom format (what you DON'T want)

`Settings → Custom Formats → +`

- **Name:** `DV Only (Profile 5)`
- **Conditions → + → Release Title:**
  - **Name:** `DV without HDR10`
  - **Implementation:** `Release Title`
  - **Regular Expression:** ✅ checked
  - **Value:** `(?=.*(dv|dovi|dolby[ .]?vision))(?!.*hdr10).*`

This matches releases with DoVi but no HDR10 indicator — typically Profile 5.

### 3. Create the "Netflix Source" custom format (extra safety net)

Netflix releases are almost always Profile 5. This format tags them regardless of DoVi markers.

`Settings → Custom Formats → +`

- **Name:** `Streaming Profile 5 Source`
- **Conditions → + → Release Title:**
  - **Name:** `Netflix/ATVP/DSNP`
  - **Implementation:** `Release Title`
  - **Regular Expression:** ✅ checked
  - **Value:** `\b(NF|ATVP|DSNP|DSNY|HULU|HMAX|PMTP)\b[. ]WEB`

### 4. Apply scores in your quality profile

`Settings → Profiles → (your 4K profile) → Scores`

Set the following scores:

| Custom Format | Score |
|---|---|
| DV HDR10 | `+2000` |
| DV Only (Profile 5) | `-10000` |
| Streaming Profile 5 Source | `-10000` |

The hugely negative scores on the unwanted formats will cause Radarr to reject any release matching them, regardless of other quality factors. The positive score on DV HDR10 ensures Radarr prefers Profile 7/8 releases over plain HDR10-only releases.

### 5. Enable "Minimum Custom Format Score" (optional but recommended)

In the same profile, set **Minimum Custom Format Score** to `0`. This is a hard floor — any release that scores below 0 after all custom formats are applied will be rejected outright. Combined with the `-10000` penalty above, this guarantees Profile 5 releases are never downloaded.

## Same setup for Sonarr

The steps are identical. Go to Sonarr's `Settings → Custom Formats` and apply the same three formats to your 4K series profile.

## Verifying it works

After setup, trigger a manual search on a movie or episode that only has Profile 5 releases available (any Netflix-only 4K content). You should see Radarr/Sonarr either skip all available releases or only pick up non-Netflix fallback sources. The activity log will show custom format scores for each release.

## Using the cleanup script

Once the custom formats are in place and you're confident new downloads won't be Profile 5, you can delete the existing damaged files so Radarr/Sonarr re-downloads clean copies:

```bash
# Preview what would be deleted
./cleanup_damaged.sh --dry-run /path/to/media

# Actually delete
./cleanup_damaged.sh /path/to/media
```

The script looks for MKV files that:

1. Have `DoVi`, `DV.HDR`, or similar in the filename (originally had DoVi)
2. No longer contain any DoVi metadata (already stripped)
3. Have a streaming service tag like `NF.WEB`, `ATVP.`, `DSNP.`, etc.

Files matching all three criteria are likely damaged and will be deleted.

## Alternative: enable auto-delete in dovi-converter

If you're confident in your custom format setup, you can enable `DELETE_UNSUPPORTED_PROFILES=true` in the `dovi-converter` environment variables. When enabled, any Profile 5 file the converter encounters will be deleted immediately, triggering Radarr/Sonarr to re-download it.

```yaml
environment:
  - DELETE_UNSUPPORTED_PROFILES=true
```

**Do not enable this until your custom formats are set up correctly** — otherwise the same bad release will just get re-downloaded in an infinite loop.
