#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 002

# Formula 1 SABnzbd post-processing script.
#
# SABnzbd arguments (3.0+):
#   $1 complete directory   $2 original NZB name   $3 clean job name
#   $4 indexer report ID   $5 category             $6 newsgroup
#   $7 post-processing status (0 = success)        $8 failure URL
#
#  NZB RSS Feed Keywords: formula1 "year"
#  Sabnzbd RSS Filters:
#  0 : Requires : MWR
#  1 : Reject : re: proper|notebook|multi
#  2 : Requires : re: F1TV|F1LIVE
#  3 : Requires : re: re: FP1|FP2|FP3|Sprint|Qualifying|Race|Pre|Post|Warm-Up|Conference|Morning|Afternoon|Post-Testing|Round00|Wrap-Up
#  4 : Reject : re: 720p|2160p|SKY
#  5 : Accept : *

# ---------------------------------------------------------------------------
# User configuration
# ---------------------------------------------------------------------------

PREFERRED_FEED="${F1_PREFERRED_FEED:-F1TV}"
DEST_DIR="${F1_DEST_DIR:-/data/formula1}"

# This must be the parent directory that contains SABnzbd's completed jobs.
# A job directory must be a child of this path before this script may remove it.
SAB_COMPLETED_ROOT="${F1_SAB_COMPLETED_ROOT:-/data/complete}"

# current:
#   F1 (2026)/Season 01/
#   S01E13 - Australia Grand Prix - Race.mkv
#
# kometa:
#   F1 (2026)/Season 01/
#   01x13 - Australia GP - Race Session.mkv
#
# Both profiles deliberately use the same stable 01-15 session slots so that
# changing the display convention does not silently remap Plex episodes.
NAMING_PROFILE="${F1_NAMING_PROFILE:-current}"

STATE_DIR="${F1_SCRIPT_STATE_DIR:-/config/scripts/state/formula1-sabnzbd}"

# The standard SABnzbd container does not include ffprobe. Validation therefore
# uses SABnzbd's successful post-processing status, minimum size, a container
# signature check, and quality/codec hints present in the release name.
MIN_FILE_BYTES="${F1_MIN_FILE_BYTES:-52428800}"
SIZE_UPGRADE_PERCENT="${F1_SIZE_UPGRADE_PERCENT:-10}"
LOCK_STALE_SECONDS="${F1_LOCK_STALE_SECONDS:-3600}"

# ---------------------------------------------------------------------------
# Session definitions
# ---------------------------------------------------------------------------

declare -A EPISODE_NUMBER
declare -A CURRENT_LABEL
declare -A KOMETA_LABEL

EPISODE_NUMBER["Weekend.Warm-Up"]="01"
EPISODE_NUMBER["FP1"]="02"
EPISODE_NUMBER["Sprint.Qualifying"]="03"
EPISODE_NUMBER["Pre-Sprint.Show"]="04"
EPISODE_NUMBER["Sprint"]="05"
EPISODE_NUMBER["Post-Sprint.Show"]="06"
EPISODE_NUMBER["FP2"]="07"
EPISODE_NUMBER["FP3"]="08"
EPISODE_NUMBER["Pre-Qualifying.Show"]="09"
EPISODE_NUMBER["Qualifying"]="10"
EPISODE_NUMBER["Post-Qualifying.Show"]="11"
EPISODE_NUMBER["Pre-Race.Show"]="12"
EPISODE_NUMBER["Race"]="13"
EPISODE_NUMBER["Post-Race.Show"]="14"
EPISODE_NUMBER["Post-Race.Press.Conference"]="15"

CURRENT_LABEL["Weekend.Warm-Up"]="Weekend.Warm-Up"
CURRENT_LABEL["FP1"]="FP1"
CURRENT_LABEL["Sprint.Qualifying"]="Sprint.Qualifying"
CURRENT_LABEL["Pre-Sprint.Show"]="Pre-Sprint.Show"
CURRENT_LABEL["Sprint"]="Sprint"
CURRENT_LABEL["Post-Sprint.Show"]="Post-Sprint.Show"
CURRENT_LABEL["FP2"]="FP2"
CURRENT_LABEL["FP3"]="FP3"
CURRENT_LABEL["Pre-Qualifying.Show"]="Pre-Qualifying.Show"
CURRENT_LABEL["Qualifying"]="Qualifying"
CURRENT_LABEL["Post-Qualifying.Show"]="Post-Qualifying.Show"
CURRENT_LABEL["Pre-Race.Show"]="Pre-Race.Show"
CURRENT_LABEL["Race"]="Race"
CURRENT_LABEL["Post-Race.Show"]="Post-Race.Show"
CURRENT_LABEL["Post-Race.Press.Conference"]="Post-Race.Press.Conference"

KOMETA_LABEL["Weekend.Warm-Up"]="Weekend Warm-Up"
KOMETA_LABEL["FP1"]="Free Practice 1"
KOMETA_LABEL["Sprint.Qualifying"]="Sprint Qualifying Session"
KOMETA_LABEL["Pre-Sprint.Show"]="Pre-Sprint Buildup"
KOMETA_LABEL["Sprint"]="Sprint Session"
KOMETA_LABEL["Post-Sprint.Show"]="Post-Sprint Analysis"
KOMETA_LABEL["FP2"]="Free Practice 2"
KOMETA_LABEL["FP3"]="Free Practice 3"
KOMETA_LABEL["Pre-Qualifying.Show"]="Pre-Qualifying Buildup"
KOMETA_LABEL["Qualifying"]="Qualifying Session"
KOMETA_LABEL["Post-Qualifying.Show"]="Post-Qualifying Analysis"
KOMETA_LABEL["Pre-Race.Show"]="Pre-Race Buildup"
KOMETA_LABEL["Race"]="Race Session"
KOMETA_LABEL["Post-Race.Show"]="Post-Race Analysis"
KOMETA_LABEL["Post-Race.Press.Conference"]="Post-Race Press Conference"

# ---------------------------------------------------------------------------
# Logging and safety helpers
# ---------------------------------------------------------------------------

JOB_NAME="${3:-unknown}"
FINAL_REPORTED=0
STAGED_FILE=""
ORIGINAL_FILE=""
LOCK_DIR=""

finish() {
  local outcome="$1"
  local detail="$2"
  FINAL_REPORTED=1
  printf '[Formula 1] Outcome: %s | Job: %s | %s\n' "$outcome" "$JOB_NAME" "$detail"
}

# Invoked by the EXIT trap.
# shellcheck disable=SC2329
on_exit() {
  local status=$?
  if [[ -n "$STAGED_FILE" && -e "$STAGED_FILE" ]]; then
    if [[ -n "$ORIGINAL_FILE" && -d "${ORIGINAL_FILE%/*}" && ! -e "$ORIGINAL_FILE" ]]; then
      mv -- "$STAGED_FILE" "$ORIGINAL_FILE" || true
    fi
  fi
  if [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
    rm -rf -- "$LOCK_DIR"
  fi
  if (( status != 0 && FINAL_REPORTED == 0 )); then
    printf '[Formula 1] Outcome: Failed | Job: %s | Unexpected script error (exit %d)\n' \
      "$JOB_NAME" "$status"
  fi
}
trap on_exit EXIT

canonical_path() {
  readlink -f -- "$1"
}

validate_removal_target() {
  local candidate="$1"
  local candidate_real root_real dest_real

  [[ -n "$candidate" && -d "$candidate" && ! -L "$candidate" ]] || return 1
  candidate_real=$(canonical_path "$candidate") || return 1
  root_real=$(canonical_path "$SAB_COMPLETED_ROOT") || return 1
  dest_real=$(canonical_path "$DEST_DIR") || return 1

  [[ "$candidate_real" != "/" ]] || return 1
  [[ "$root_real" != "/" ]] || return 1
  [[ "$candidate_real" != "$root_real" ]] || return 1
  [[ "$candidate_real" != "$dest_real" ]] || return 1
  [[ "$candidate_real" != "$STATE_DIR" ]] || return 1

  case "$candidate_real/" in
    "$root_real"/*) ;;
    *) return 1 ;;
  esac

  case "$dest_real/" in
    "$candidate_real"/*) return 1 ;;
  esac
  case "$candidate_real/" in
    "$dest_real"/*) return 1 ;;
  esac

  return 0
}

remove_job_directory() {
  local candidate="$1"
  if ! validate_removal_target "$candidate"; then
    finish "Failed" "Safety check refused removal of source directory: $candidate"
    return 1
  fi
  rm -rf -- "$candidate"
}

reject_and_remove() {
  local reason="$1"
  if remove_job_directory "$SRC_DIR"; then
    finish "Rejected" "$reason; validated SABnzbd job directory removed"
    exit 0
  fi
  exit 1
}

normalize_words() {
  local value="$1"
  value=${value//./ }
  value=${value//_/ }
  value=$(printf '%s' "$value" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  printf '%s' "$value"
}

session_pattern() {
  local value="$1"
  value=${value//./[._[:space:]-]+}
  printf '%s' "$value"
}

source_feed() {
  local value="$1"
  value="${value^^}"
  if [[ "$value" =~ (^|[._[:space:]-])(F1TV|F1LIVE|SKY)([._[:space:]-]|$) ]]; then
    printf '%s' "${BASH_REMATCH[2]^^}"
  else
    printf '%s' "UNKNOWN"
  fi
}

is_preferred_feed() {
  [[ "${1^^}" == "${PREFERRED_FEED^^}" ]]
}

state_key_for() {
  printf '%s' "$1" | cksum | awk '{print $1 "-" $2}'
}

state_value_for() {
  local state_file="$1" field="$2" fallback="$3" value
  [[ -f "$state_file" ]] || {
    printf '%s' "$fallback"
    return
  }
  value=$(awk -F= -v wanted="$field" '$1 == wanted {print $2; exit}' "$state_file")
  printf '%s' "${value:-$fallback}"
}

write_state() {
  local state_file="$1" target="$2" feed="$3" quality="$4"
  local quality_rank="$5" codec_hint="$6" size="$7"
  local temporary="${state_file}.$$.tmp"

  {
    printf 'target=%s\n' "$target"
    printf 'feed=%s\n' "$feed"
    printf 'quality=%s\n' "$quality"
    printf 'quality_rank=%s\n' "$quality_rank"
    printf 'codec_hint=%s\n' "$codec_hint"
    printf 'size=%s\n' "$size"
  } > "$temporary"
  chmod 0664 "$temporary"
  mv -f -- "$temporary" "$state_file"
}

media_size() {
  local size
  size=$(wc -c < "$1") || return 1
  size=${size//[[:space:]]/}
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$size"
}

container_header_valid() {
  local file="$1" extension="$2" signature
  [[ -r "$file" ]] || return 1
  signature=$(od -An -tx1 -N16 -- "$file" 2>/dev/null | tr -d '[:space:]') || return 1
  case "$extension" in
    mkv) [[ "$signature" == 1a45dfa3* ]] ;;
    mp4|m4v) [[ "${signature:8:8}" == "66747970" ]] ;;
    ts) [[ "${signature:0:2}" == "47" || "${signature:8:2}" == "47" ]] ;;
    *) return 1 ;;
  esac
}

quality_label_for() {
  local value="$1"
  value="${value,,}"
  if [[ "$value" =~ (^|[._[:space:]-])2160p([._[:space:]-]|$) ]]; then
    printf '2160p'
  elif [[ "$value" =~ (^|[._[:space:]-])1080p([._[:space:]-]|$) ]]; then
    printf '1080p'
  elif [[ "$value" =~ (^|[._[:space:]-])720p([._[:space:]-]|$) ]]; then
    printf '720p'
  else
    printf 'unknown'
  fi
}

quality_rank_for() {
  case "$1" in
    2160p) printf '3' ;;
    1080p) printf '2' ;;
    720p) printf '1' ;;
    *) printf '0' ;;
  esac
}

codec_hint_for() {
  local value="$1"
  value="${value^^}"
  if [[ "$value" =~ (^|[._[:space:]-])(HEVC|H[._-]?265|X265)([._[:space:]-]|$) ]]; then
    printf 'HEVC'
  elif [[ "$value" =~ (^|[._[:space:]-])(AVC|H[._-]?264|X264)([._[:space:]-]|$) ]]; then
    printf 'AVC'
  elif [[ "$value" =~ (^|[._[:space:]-])AV1([._[:space:]-]|$) ]]; then
    printf 'AV1'
  else
    printf 'unknown'
  fi
}

acquire_target_lock() {
  local requested="$1" owner_file now created_at age
  owner_file="${requested}/owner"
  now=$(date +%s)

  if mkdir -- "$requested" 2>/dev/null; then
    printf '%s\n' "$now" > "$owner_file"
    LOCK_DIR="$requested"
    return 0
  fi

  created_at=$(sed -n '1p' "$owner_file" 2>/dev/null || true)
  if [[ "$created_at" =~ ^[0-9]+$ ]]; then
    age=$((now - created_at))
    if (( age >= LOCK_STALE_SECONDS )); then
      rm -rf -- "$requested"
      if mkdir -- "$requested" 2>/dev/null; then
        printf '%s\n' "$now" > "$owner_file"
        LOCK_DIR="$requested"
        return 0
      fi
    fi
  fi
  return 1
}

# Returns 0 when the incoming release is a policy-approved upgrade. Resolution
# and codec values are release-name hints; SABnzbd status and container headers
# provide the dependency-free integrity boundary.
incoming_is_upgrade() {
  local incoming_feed="$1" existing_feed="$2"
  local incoming_rank="$3" incoming_size="$4"
  local existing_rank="$5" existing_size="$6" state_known="$7"

  if (( state_known == 1 )); then
    (( incoming_rank > existing_rank )) && return 0
    (( incoming_rank < existing_rank )) && return 1
  fi

  if is_preferred_feed "$incoming_feed" && \
    (( state_known == 1 )) && ! is_preferred_feed "$existing_feed"; then
    return 0
  fi
  if (( state_known == 1 )) && is_preferred_feed "$existing_feed" && \
    ! is_preferred_feed "$incoming_feed"; then
    return 1
  fi

  (( incoming_size >= existing_size * (100 + SIZE_UPGRADE_PERCENT) / 100 ))
}

# ---------------------------------------------------------------------------
# Validate SABnzbd invocation before examining or deleting anything
# ---------------------------------------------------------------------------

if (( $# < 7 )); then
  finish "Failed" "Expected at least 7 SABnzbd arguments; received $#"
  exit 1
fi

SRC_DIR="$1"
CATEGORY="$5"
POSTPROC_STATUS="$7"

case "${NAMING_PROFILE,,}" in
  current|kometa) NAMING_PROFILE="${NAMING_PROFILE,,}" ;;
  *)
    finish "Failed" "F1_NAMING_PROFILE must be current or kometa"
    exit 1
    ;;
esac

for numeric_setting in "$MIN_FILE_BYTES" "$SIZE_UPGRADE_PERCENT" "$LOCK_STALE_SECONDS"; do
  if [[ ! "$numeric_setting" =~ ^[0-9]+$ ]]; then
    finish "Failed" "File-size and lock settings must be non-negative integers"
    exit 1
  fi
done
if (( MIN_FILE_BYTES < 1 || LOCK_STALE_SECONDS < 1 )); then
  finish "Failed" "Minimum file size and stale-lock time must be greater than zero"
  exit 1
fi

if [[ "${CATEGORY,,}" != "f1" && "${CATEGORY,,}" != "formula1" ]]; then
  finish "Skipped" "SABnzbd category is $CATEGORY; expected f1 or formula1"
  exit 0
fi

if [[ "$POSTPROC_STATUS" != "0" ]]; then
  finish "Failed" "SABnzbd post-processing status is $POSTPROC_STATUS; source preserved"
  exit 1
fi

if [[ ! -d "$DEST_DIR" ]]; then
  mkdir -p -- "$DEST_DIR"
fi
if [[ ! -d "$SAB_COMPLETED_ROOT" ]]; then
  finish "Failed" "Configured SAB completed root does not exist: $SAB_COMPLETED_ROOT"
  exit 1
fi
if ! validate_removal_target "$SRC_DIR"; then
  finish "Failed" "Source directory failed the removal safety boundary: $SRC_DIR"
  exit 1
fi
SRC_DIR=$(canonical_path "$SRC_DIR")
DEST_DIR=$(canonical_path "$DEST_DIR")
mkdir -p -- "$STATE_DIR" "$STATE_DIR/locks" "$STATE_DIR/targets"
chmod 0775 "$STATE_DIR" "$STATE_DIR/locks" "$STATE_DIR/targets"

# Testing is intentionally outside this workflow. Round 00 jobs are rejected
# and safely removed after the SAB source boundary has been validated.
if [[ "$JOB_NAME" =~ (^|[._[:space:]-])Round0*0([._[:space:]-]|$) ]]; then
  reject_and_remove "Pre-season testing (Round 00) is disabled"
fi

# ---------------------------------------------------------------------------
# Locate exactly one primary video
# ---------------------------------------------------------------------------

declare -a VIDEO_FILES=()
while IFS= read -r -d '' candidate; do
  basename_lower="${candidate##*/}"
  basename_lower="${basename_lower,,}"
  [[ "$basename_lower" == *sample* ]] && continue
  VIDEO_FILES+=("$candidate")
done < <(
  find "$SRC_DIR" -xdev -type f \
    \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.ts' \) \
    -print0
)

if (( ${#VIDEO_FILES[@]} == 0 )); then
  reject_and_remove "No supported primary video was found"
fi
if (( ${#VIDEO_FILES[@]} > 1 )); then
  reject_and_remove "Multiple primary videos were found; multi-file jobs are unsupported"
fi

SAB_FILE="${VIDEO_FILES[0]}"
EXTENSION="${SAB_FILE##*.}"
EXTENSION="${EXTENSION,,}"

# ---------------------------------------------------------------------------
# Parse Formula1.YEAR.RoundNN.EVENT.PROGRAM... without assuming a one-word event
# ---------------------------------------------------------------------------

if [[ ! "$JOB_NAME" =~ ^Formula1[._[:space:]-]+((19|20)[0-9]{2})[._[:space:]-]+Round([0-9]{1,3})[._[:space:]-]+(.+)$ ]]; then
  reject_and_remove "Job name does not match Formula1.YEAR.RoundNN.EVENT.PROGRAM"
fi

YEAR="${BASH_REMATCH[1]}"
ROUND_NUMBER=$((10#${BASH_REMATCH[3]}))
REMAINDER="${BASH_REMATCH[4]}"

if (( ROUND_NUMBER == 0 )); then
  reject_and_remove "Pre-season testing (Round 00) is disabled"
fi
if (( ROUND_NUMBER < 1 || ROUND_NUMBER > 30 )); then
  reject_and_remove "Race round is outside the supported range 1-30"
fi

SESSION_KEY=""
EVENT_RAW=""
while IFS= read -r key; do
  pattern=$(session_pattern "$key")
  if [[ "$REMAINDER" =~ ^(.+)[._[:space:]-]+${pattern}([._[:space:]-]+.*)?$ ]]; then
    SESSION_KEY="$key"
    EVENT_RAW="${BASH_REMATCH[1]}"
    break
  fi
done < <(
  printf '%s\n' "${!EPISODE_NUMBER[@]}" |
    awk '{print length, $0}' |
    sort -rn |
    cut -d' ' -f2-
)

if [[ -z "$SESSION_KEY" || -z "$EVENT_RAW" ]]; then
  reject_and_remove "No supported Formula 1 programme could be identified"
fi

EVENT=$(normalize_words "$EVENT_RAW")
EVENT=$(printf '%s' "$EVENT" | sed -E 's/[[:space:]]+(Grand Prix|GP)$//I; s/[[:space:]]+$//')
if [[ -z "$EVENT" ]]; then
  reject_and_remove "Race event name is empty after normalization"
fi

ROUND=$(printf '%02d' "$ROUND_NUMBER")
EPISODE="${EPISODE_NUMBER[$SESSION_KEY]}"
FEED=$(source_feed "$JOB_NAME")

SHOW_DIR="${DEST_DIR}/F1 ${YEAR}"
SEASON_DIR="${SHOW_DIR}/Season ${ROUND}"
mkdir -p -- "$SEASON_DIR"
chmod 0775 "$SHOW_DIR" "$SEASON_DIR"

if [[ "$NAMING_PROFILE" == "current" ]]; then
  PROGRAM_LABEL="${CURRENT_LABEL[$SESSION_KEY]}"
  TARGET_STEM="S${ROUND}E${EPISODE} - ${EVENT} Grand Prix - ${PROGRAM_LABEL}"
else
  PROGRAM_LABEL="${KOMETA_LABEL[$SESSION_KEY]}"
  TARGET_STEM="${ROUND}x${EPISODE} - ${EVENT} GP - ${PROGRAM_LABEL}"
fi

TARGET_NAME="${TARGET_STEM}.${EXTENSION}"
TARGET="${SEASON_DIR}/${TARGET_NAME}"
TARGET_KEY=$(state_key_for "${SEASON_DIR}/${TARGET_STEM}")
TARGET_LOCK="${STATE_DIR}/locks/${TARGET_KEY}.lock"
STATE_FILE="${STATE_DIR}/targets/${TARGET_KEY}.state"

if ! acquire_target_lock "$TARGET_LOCK"; then
  finish "Failed" "Another job is already processing this Formula 1 episode; source preserved"
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate the incoming media and decide whether it may replace an existing file
# ---------------------------------------------------------------------------

if ! IN_SIZE=$(media_size "$SAB_FILE"); then
  reject_and_remove "Media size could not be read"
fi
if (( IN_SIZE < MIN_FILE_BYTES )); then
  reject_and_remove "Media is smaller than the configured minimum of ${MIN_FILE_BYTES} bytes"
fi
if ! container_header_valid "$SAB_FILE" "$EXTENSION"; then
  reject_and_remove "Media container header does not match the .$EXTENSION extension"
fi

IN_QUALITY=$(quality_label_for "$JOB_NAME")
IN_QUALITY_RANK=$(quality_rank_for "$IN_QUALITY")
IN_CODEC_HINT=$(codec_hint_for "$JOB_NAME")

ACTION="Imported"
declare -a EXISTING_TARGETS=()
for existing_extension in mkv mp4 m4v ts; do
  existing_candidate="${SEASON_DIR}/${TARGET_STEM}.${existing_extension}"
  [[ -e "$existing_candidate" ]] && EXISTING_TARGETS+=("$existing_candidate")
done
if (( ${#EXISTING_TARGETS[@]} > 1 )); then
  reject_and_remove "Multiple existing files claim the same Plex episode destination"
fi

EXISTING_TARGET=""
if (( ${#EXISTING_TARGETS[@]} == 1 )); then
  EXISTING_TARGET="${EXISTING_TARGETS[0]}"
  EXISTING_EXTENSION="${EXISTING_TARGET##*.}"
  EXISTING_EXTENSION="${EXISTING_EXTENSION,,}"
  if ! OLD_SIZE=$(media_size "$EXISTING_TARGET") || \
    (( OLD_SIZE < MIN_FILE_BYTES )) || \
    ! container_header_valid "$EXISTING_TARGET" "$EXISTING_EXTENSION"; then
    ACTION="Replaced invalid existing media"
  else
    OLD_FEED=$(state_value_for "$STATE_FILE" feed UNKNOWN)
    OLD_QUALITY_RANK=$(state_value_for "$STATE_FILE" quality_rank 0)
    if [[ -f "$STATE_FILE" ]]; then
      STATE_KNOWN=1
    else
      STATE_KNOWN=0
    fi

    if [[ "$IN_SIZE" == "$OLD_SIZE" ]] && cmp -s -- "$SAB_FILE" "$EXISTING_TARGET"; then
      reject_and_remove "Byte-identical duplicate already exists at $EXISTING_TARGET"
    fi

    if incoming_is_upgrade \
      "$FEED" "$OLD_FEED" \
      "$IN_QUALITY_RANK" "$IN_SIZE" \
      "$OLD_QUALITY_RANK" "$OLD_SIZE" "$STATE_KNOWN"; then
      ACTION="Upgraded"
    else
      reject_and_remove \
        "Existing destination was preserved because the incoming release is not a policy-approved upgrade"
    fi
  fi
fi

# Move/copy to a hidden staging name in the destination directory first. Plex
# cannot discover the incomplete name. The final rename is local and atomic.
STAGED_FILE="${SEASON_DIR}/.${TARGET_NAME}.$$.partial"
ORIGINAL_FILE="$SAB_FILE"
mv -- "$SAB_FILE" "$STAGED_FILE"
chmod 0664 "$STAGED_FILE"

if ! STAGED_SIZE=$(media_size "$STAGED_FILE"); then
  finish "Failed" "Staged media size could not be verified; source was not published"
  exit 1
fi
if [[ "$STAGED_SIZE" != "$IN_SIZE" ]] || \
  ! container_header_valid "$STAGED_FILE" "$EXTENSION"; then
  finish "Failed" "Staged media changed or failed its container check; source was not published"
  exit 1
fi

mv -f -- "$STAGED_FILE" "$TARGET"
STAGED_FILE=""
chmod 0664 "$TARGET"
if [[ -n "$EXISTING_TARGET" && "$EXISTING_TARGET" != "$TARGET" ]]; then
  rm -f -- "$EXISTING_TARGET"
fi
write_state "$STATE_FILE" "$TARGET" "$FEED" "$IN_QUALITY" \
  "$IN_QUALITY_RANK" "$IN_CODEC_HINT" "$IN_SIZE"

remove_job_directory "$SRC_DIR"
finish "$ACTION" \
  "Profile: $NAMING_PROFILE | Feed: $FEED | Quality hint: $IN_QUALITY | Codec hint: $IN_CODEC_HINT | Destination: $TARGET"
exit 0
