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

  # Extract Day (One|Two|Three|1|2|3|01|02|03) with optional delimiter
  DAY_MATCH=$(echo "${NEW_FILENAME}" | grep -oiE "Day[-._ ]?(One|Two|Three|0?1|0?2|0?3)" | head -1)
  if [[ -n "${DAY_MATCH}" ]]; then
    DAY_WORD=$(echo "${DAY_MATCH}" | sed -E 's/[Dd]ay[-._ ]?//')
    case "${DAY_WORD}" in
      One|01|1) TEST_DAY_NUM=1 ;;
      Two|02|2) TEST_DAY_NUM=2 ;;
      Three|03|3) TEST_DAY_NUM=3 ;;
    esac
  fi

  # If no explicit Day token, try extracting Test number as day surrogate
  # If no explicit Day token, try extracting Test number as day surrogate
  if [[ -z "${TEST_DAY_NUM}" ]]; then
    TEST_MATCH=$(echo "${NEW_FILENAME}" | grep -oiE "Test[-._ ]?(One|Two|Three|0?1|0?2|0?3)" | head -1)
    if [[ -n "${TEST_MATCH}" ]]; then
      TEST_WORD=$(echo "${TEST_MATCH}" | sed -E 's/[Tt]est[-._ ]?//')
      case "${TEST_WORD}" in
        One|01|1) TEST_DAY_NUM=1 ;;
        Two|02|2) TEST_DAY_NUM=2 ;;
        Three|03|3) TEST_DAY_NUM=3 ;;
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
  if [[ -z "${TEST_DAY_NUM}" ]]; then
    TEST_DAY_NUM=1
  fi

  MORNING_EP=$(( (TEST_DAY_NUM - 1) * 2 + 1 ))
  AFTERNOON_EP=$(( MORNING_EP + 1 ))

  if [[ ${TEST_ANALYSIS} -eq 1 ]]; then
    EPISODE=7
    DISPLAY_KEY="Post-Testing Analysis"
  elif [[ ${TEST_WRAPUP} -eq 1 ]]; then
    EPISODE=$(( 6 + TEST_DAY_NUM + 1 ))
    DISPLAY_KEY="Day ${TEST_DAY_NUM} Wrap-Up Show"
  elif [[ "${TEST_SESSION}" =~ ^[Mm]orning$ ]]; then
    EPISODE=${MORNING_EP}
    DISPLAY_KEY="Day ${TEST_DAY_NUM} Morning"
  elif [[ "${TEST_SESSION}" =~ ^[Aa]fternoon$ ]]; then
    EPISODE=${AFTERNOON_EP}
    DISPLAY_KEY="Day ${TEST_DAY_NUM} Afternoon"
  else
    PLEX_DIR_CHECK="${DEST_DIR}/F1 ${YEAR}/Specials"
    M_GLOB="${PLEX_DIR_CHECK}/S00E$(printf "%02d" ${MORNING_EP}) - Pre-Season Testing – Day ${TEST_DAY_NUM} Morning*"
    A_GLOB="${PLEX_DIR_CHECK}/S00E$(printf "%02d" ${AFTERNOON_EP}) - Pre-Season Testing – Day ${TEST_DAY_NUM} Afternoon*"
    shopt -s nullglob
    M_MATCHES=( $M_GLOB )
    A_MATCHES=( $A_GLOB )
    shopt -u nullglob
    M_EXISTS=$([[ ${#M_MATCHES[@]} -gt 0 ]] && echo 1 || echo 0)
    A_EXISTS=$([[ ${#A_MATCHES[@]} -gt 0 ]] && echo 1 || echo 0)

    if [[ ${M_EXISTS} -eq 0 && ${A_EXISTS} -eq 0 ]]; then
      EPISODE=${MORNING_EP}
      DISPLAY_KEY="Day ${TEST_DAY_NUM} Morning"
    elif [[ ${M_EXISTS} -eq 1 && ${A_EXISTS} -eq 0 ]]; then
      EPISODE=${AFTERNOON_EP}
      DISPLAY_KEY="Day ${TEST_DAY_NUM} Afternoon"
    elif [[ ${M_EXISTS} -eq 0 && ${A_EXISTS} -eq 1 ]]; then
      EPISODE=${MORNING_EP}
      DISPLAY_KEY="Day ${TEST_DAY_NUM} Morning"
    else
      EPISODE=${MORNING_EP}
      DISPLAY_KEY="Day ${TEST_DAY_NUM} Morning"
    fi
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
  if [[ $IS_TESTING -eq 1 ]]; then
    SESSION_LABEL=$(echo "${DISPLAY_KEY}" | grep -oiE 'Morning|Afternoon' | head -1)
    ALT_EP=""
    ALT_SESSION_LABEL=""
    if [[ "${SESSION_LABEL}" =~ ^[Mm]orning$ ]]; then
      ALT_EP=$(printf "%02d" $(( AFTERNOON_EP )))
      ALT_SESSION_LABEL="Afternoon"
    else
      ALT_EP=$(printf "%02d" $(( MORNING_EP )))
      ALT_SESSION_LABEL="Morning"
    fi
    ALT_NAME="S00E${ALT_EP} - Pre-Season Testing – Day ${TEST_DAY_NUM} ${ALT_SESSION_LABEL}"
    ALT_FILE="${PLEX_DIR}/${ALT_NAME}.${EXTENSION}"
    if [[ -f "${DEST_FILE}" && ! -f "${ALT_FILE}" ]]; then
      PLEX_NAME="${ALT_NAME}"
      PLEX_FILENAME="${PLEX_NAME}.${EXTENSION}"
      DEST_FILE="${PLEX_DIR}/${PLEX_FILENAME}"
    fi
  fi
  mv -n "${SAB_FILE}" "${DEST_FILE}"
else
  PLEX_NAME_NET="${PLEX_NAME} – ${NETWORK}"
  PLEX_FILENAME_NET="${PLEX_NAME_NET}.${EXTENSION}"
  DEST_FILE="${PLEX_DIR}/${PLEX_FILENAME_NET}"
  if [[ $IS_TESTING -eq 1 ]]; then
    SESSION_LABEL=$(echo "${DISPLAY_KEY}" | grep -oiE 'Morning|Afternoon' | head -1)
    ALT_EP=""
    ALT_SESSION_LABEL=""
    if [[ "${SESSION_LABEL}" =~ ^[Mm]orning$ ]]; then
      ALT_EP=$(printf "%02d" $(( AFTERNOON_EP )))
      ALT_SESSION_LABEL="Afternoon"
    else
      ALT_EP=$(printf "%02d" $(( MORNING_EP )))
      ALT_SESSION_LABEL="Morning"
    fi
    ALT_NAME_NET="S00E${ALT_EP} - Pre-Season Testing – Day ${TEST_DAY_NUM} ${ALT_SESSION_LABEL} – ${NETWORK}"
    ALT_FILE_NET="${PLEX_DIR}/${ALT_NAME_NET}.${EXTENSION}"
    if [[ -f "${DEST_FILE}" && ! -f "${ALT_FILE_NET}" ]]; then
      PLEX_NAME_NET="${ALT_NAME_NET}"
      PLEX_FILENAME_NET="${PLEX_NAME_NET}.${EXTENSION}"
      DEST_FILE="${PLEX_DIR}/${PLEX_FILENAME_NET}"
    fi
  fi
  if [ ! -f "${DEST_FILE}" ]; then
    mv -n "${SAB_FILE}" "${DEST_FILE}"
  else
    SUFFIXED="${DEST_FILE%.*} (2).${EXTENSION}"
    mv -n "${SAB_FILE}" "${SUFFIXED}"
    DEST_FILE="${SUFFIXED}"
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