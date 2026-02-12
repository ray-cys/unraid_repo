#!/bin/bash

# NZB RSS Feed Keywords: formula1
# sabnzbd RSS Filters:
# 0 : Requires : MWR
# 1 : Reject : re: proper|notebook|multi
# 2 : Requires : re: F1TV|SKY
# 3 : Requires : re: FP1|FP2|FP3|Sprint|Qualifying|Race|Pre|Post|Warm-Up|Conference|Morning|Afternoon|Post-Testing|Round00
# 4 : *

# set to SKY or F1LIVE
PREFERRED_FEED="F1LIVE"
DEST_DIR="/data/formula1"
SRC_DIR="$1"
JOB_NAME="$3"
SAB_FILE=$(find "$SRC_DIR" -type f | sort -n | tail -1)
EXTENSION="${SAB_FILE##*.}"
NEW_FILENAME="${JOB_NAME}.${EXTENSION}"
DEST_FILE="" # final destination file path used for chmod

############################
# RACE WEEKEND EPISODES
############################
declare -A EPISODE_ARRAY
EPISODE_ARRAY["Warm-Up"]="01"
EPISODE_ARRAY["FP1"]="02"
EPISODE_ARRAY["Sprint.Qualifying"]="03"
EPISODE_ARRAY["Pre-Sprint.Show"]="04"
EPISODE_ARRAY["Sprint"]="05"
EPISODE_ARRAY["Post-Sprint.Show"]="06"
EPISODE_ARRAY["FP2"]="07"
EPISODE_ARRAY["FP3"]="08"
EPISODE_ARRAY["Pre-Qualifying.Show"]="09"
EPISODE_ARRAY["Qualifying"]="10"
EPISODE_ARRAY["Post-Qualifying.Show"]="11"
EPISODE_ARRAY["Pre-Race.Show"]="12"
EPISODE_ARRAY["Race"]="13"
EPISODE_ARRAY["Post-Race.Show"]="14"
EPISODE_ARRAY["Post-Race.Press.Conference"]="15"

# PRE-SEASON TESTING (SPECIALS)
# Day 1 Morning -> S00E01, Afternoon -> S00E02
# Day 2 Morning -> S00E03, Afternoon -> S00E04
# Day 3 Morning -> S00E05, Afternoon -> S00E06
# Post-Testing Analysis -> S00E07
# Day 1/2/3 Wrap-Up Show -> S00E08/09/10

##################################
# DETECT PRE-SEASON TESTING (SPECIALS)
##################################
IS_TESTING=0
TEST_DAY_NUM=""
TEST_SESSION="" # Morning | Afternoon | (empty => full day)
TEST_ANALYSIS=0
TEST_WRAPUP=0

if echo "${NEW_FILENAME}" | grep -qiE "(Pre-Season[._ ]Testing|[._ ]Round00[._ ]).*(Test|Day|Analysis|Wrap[-._ ]?Up)"; then
  # Detect analysis and wrap-up flags
  if echo "${NEW_FILENAME}" | grep -qiE "Post[-._ ]Testing[-._ ]Analysis"; then
    TEST_ANALYSIS=1
  fi
  if echo "${NEW_FILENAME}" | grep -qiE "Wrap[-._ ]?Up([-._ ]?Show)?"; then
    TEST_WRAPUP=1
  fi

  # Extract Day (One|Two|Three|1|2|3) if present
  DAY_TOKEN=$(echo "${NEW_FILENAME}" | grep -oiE "Day[-._ ](One|Two|Three|1|2|3)" | head -1 | sed -E 's/[-._ ]/./g')
  if [[ -n "${DAY_TOKEN}" ]]; then
    DAY_WORD=$(echo "${DAY_TOKEN}" | cut -d. -f2)
    case "${DAY_WORD}" in
      One|1) TEST_DAY_NUM=1 ;;
      Two|2) TEST_DAY_NUM=2 ;;
      Three|3) TEST_DAY_NUM=3 ;;
    esac
  fi

  # If no explicit Day token, try extracting Test number as day surrogate
  if [[ -z "${TEST_DAY_NUM}" ]]; then
    TEST_TOKEN=$(echo "${NEW_FILENAME}" | grep -oiE "Test[-._ ](One|Two|Three|1|2|3)" | head -1 | sed -E 's/[-._ ]/./g')
    if [[ -n "${TEST_TOKEN}" ]]; then
      TEST_WORD=$(echo "${TEST_TOKEN}" | cut -d. -f2)
      case "${TEST_WORD}" in
        One|1) TEST_DAY_NUM=1 ;;
        Two|2) TEST_DAY_NUM=2 ;;
        Three|3) TEST_DAY_NUM=3 ;;
      esac
    fi
  fi

  # Extract session if present
  TEST_SESSION=$(echo "${NEW_FILENAME}" | grep -oiE "Morning|Afternoon" | head -1)
  IS_TESTING=1
fi

##################################
# PRE-SEASON TESTING HANDLING
##################################
if [[ $IS_TESTING -eq 1 ]]; then
  YEAR=$(echo "${NEW_FILENAME}" | grep -oE '[12][0-9]{3}' | head -1)

  # Default day if not present
  if [[ -z "${TEST_DAY_NUM}" ]]; then
    TEST_DAY_NUM=1
  fi

  if [[ ${TEST_ANALYSIS} -eq 1 ]]; then
    EPISODE=7
    DISPLAY_KEY="Post-Testing Analysis"
  elif [[ ${TEST_WRAPUP} -eq 1 ]]; then
    EPISODE=$(( 6 + TEST_DAY_NUM + 1 ))
    DISPLAY_KEY="Day ${TEST_DAY_NUM} Wrap-Up Show"
  elif [[ "${TEST_SESSION}" =~ ^[Mm]orning$ ]]; then
    EPISODE=$(( (TEST_DAY_NUM - 1) * 2 + 1 ))
    DISPLAY_KEY="Day ${TEST_DAY_NUM} Morning"
  elif [[ "${TEST_SESSION}" =~ ^[Aa]fternoon$ ]]; then
    EPISODE=$(( (TEST_DAY_NUM - 1) * 2 + 2 ))
    DISPLAY_KEY="Day ${TEST_DAY_NUM} Afternoon"
  else
    EPISODE=$(( (TEST_DAY_NUM - 1) * 2 + 1 ))
    DISPLAY_KEY="Day ${TEST_DAY_NUM}"
  fi

  EPISODE=$(printf "%02d" "${EPISODE}")

  PLEX_DIR="${DEST_DIR}/F1 ${YEAR}/Specials"
  PLEX_NAME="S00E${EPISODE} - Pre-Season Testing – ${DISPLAY_KEY}"
  PLEX_FILENAME="${PLEX_NAME}.${EXTENSION}"

##################################
# RACE WEEKEND HANDLING
##################################
else
  FOUND=0
  for KEY in "${!EPISODE_ARRAY[@]}"; do
    if echo "${NEW_FILENAME}" | grep -qEio "\.${KEY}"; then
      FOUND=1
      break
    fi
  done

  if [[ $FOUND -eq 0 ]]; then
    echo "Filename does not contain wanted episode criteria ... aborting"
    rm -rf "${SRC_DIR}"
    exit 1
  fi

  YEAR=$(echo "${NEW_FILENAME}" | grep -oE '[12][0-9]{3}' | head -1)
  SEASON=$(echo "${NEW_FILENAME}" | cut -d. -f3 | sed 's/Round//')
  EPISODE="${EPISODE_ARRAY["${KEY}"]}"
  LOCATION=$(echo "${NEW_FILENAME}" | cut -d. -f4)

  PLEX_DIR="${DEST_DIR}/F1 ${YEAR}/${SEASON} - ${LOCATION} GP"
  PLEX_NAME="${SEASON}x${EPISODE} - ${LOCATION} Grand Prix - ${KEY}"
  PLEX_FILENAME="${PLEX_NAME}.${EXTENSION}"
fi

############################
# CREATE DESTINATION
############################
mkdir -p "${PLEX_DIR}"

############################
# FEED PRIORITY LOGIC
############################
NETWORK=$(echo "${NEW_FILENAME}" | sed -E 's/.*[._ ]([A-Za-z0-9]+)[._ ]WEB.*/\1/I')

if echo "${NETWORK}" | grep -qEio "${PREFERRED_FEED}"; then
  DEST_FILE="${PLEX_DIR}/${PLEX_FILENAME}"
  mv "${SAB_FILE}" "${DEST_FILE}"
else
  PLEX_NAME_NET="${PLEX_NAME} – ${NETWORK}"
  PLEX_FILENAME_NET="${PLEX_NAME_NET}.${EXTENSION}"
  DEST_FILE="${PLEX_DIR}/${PLEX_FILENAME_NET}"
  if [ ! -f "${DEST_FILE}" ]; then
    mv "${SAB_FILE}" "${DEST_FILE}"
  else
    rm -rf "${SRC_DIR}"
    exit 0
  fi
fi

############################
# CLEANUP
############################
rm -rf "${SRC_DIR}"
if [[ -n "${DEST_FILE}" && -f "${DEST_FILE}" ]]; then
  chmod 774 "${DEST_FILE}"
fi

echo "Post-Processing Script Completed"
exit 0