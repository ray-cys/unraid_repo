#!/bin/bash

# set to SKY or F1LIVE
PREFERRED_FEED="F1LIVE"

DEST_DIR="/data/formula1"

SRC_DIR="$1"
JOB_NAME="$3"
SAB_FILE=$(find "$SRC_DIR" -type f | sort -n | tail -1)
EXTENSION="${SAB_FILE##*.}"
NEW_FILENAME="${JOB_NAME}.${EXTENSION}"

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

############################
# PRE-SEASON TESTING (SPECIALS)
############################
declare -A TESTING_ARRAY
TESTING_ARRAY["Day.1.Morning"]="01"
TESTING_ARRAY["Day.1.Afternoon"]="02"
TESTING_ARRAY["Day.2.Morning"]="03"
TESTING_ARRAY["Day.2.Afternoon"]="04"
TESTING_ARRAY["Day.3.Morning"]="05"
TESTING_ARRAY["Day.3.Afternoon"]="06"
TESTING_ARRAY["Post-Testing.Analysis"]="07"

##################################
# DETECT PRE-SEASON TESTING
##################################
IS_TESTING=0
for KEY in "${!TESTING_ARRAY[@]}"; do
  if echo "${NEW_FILENAME}" | grep -qEio "Pre-Season.Testing.*${KEY}"; then
    IS_TESTING=1
    break
  fi
done

##################################
# PRE-SEASON TESTING HANDLING
##################################
if [[ $IS_TESTING -eq 1 ]]; then
  YEAR=$(echo "${NEW_FILENAME}" | cut -d. -f2)
  EPISODE="${TESTING_ARRAY["${KEY}"]}"

  PLEX_DIR="${DEST_DIR}/F1 ${YEAR}/Specials"
  PLEX_NAME="S00E${EPISODE} - Pre-Season Testing – ${KEY//./ }"
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

  YEAR=$(echo "${NEW_FILENAME}" | cut -d. -f2)
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
NETWORK=$(echo "${NEW_FILENAME}" | sed -n "s/.*${KEY}.//Ip" | sed 's/.WEB.*//')

if echo "${NETWORK}" | grep -qEio "${PREFERRED_FEED}"; then
  mv "${SAB_FILE}" "${PLEX_DIR}/${PLEX_FILENAME}"
else
  if [ ! -f "${PLEX_DIR}/${PLEX_FILENAME}" ]; then
    mv "${SAB_FILE}" "${PLEX_DIR}/${PLEX_FILENAME}"
  else
    rm -rf "${SRC_DIR}"
    exit 0
  fi
fi

############################
# CLEANUP
############################
rm -rf "${SRC_DIR}"
chmod 774 "${PLEX_DIR}/${PLEX_FILENAME}"

echo "Post-Processing Script Completed"
exit 0