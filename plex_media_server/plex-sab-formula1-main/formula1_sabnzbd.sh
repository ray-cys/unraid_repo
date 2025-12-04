#!/bin/bash

# NZB RSS Feed Keywords: formula1
# sabnzbd RSS Filters:
# 0 : Requires : MWR
# 1 : Reject : re: proper|notebook|multi|round00
# 2 : Requires : re: F1TV|SKY
# 3 : Requires : re: FP1|FP2|FP3|Sprint|Qualifying|Race
# 4 : *

# set to SKY or F1LIVE
PREFERRED_FEED="F1LIVE"

# set destination dir where to place processed files.
# should be in your plex media libray path
# must be accessible from sabnzbd container if you are running sabnzbd in docker
DEST_DIR="/data/formula1"

# poster dir where templates for episode poster reside.
# must be accessible from sabnzbd container if you are running sabnzbd in docker
# POSTER_DIR="/config/scripts/formula_posters"

# set some basic variables we need from sabnzbd
SRC_DIR="$1"
JOB_NAME="$3"
SAB_FILE=$(find "$SRC_DIR" -type f | sort -n | tail -1)
EXTENSION="${SAB_FILE##*.}"
NEW_FILENAME="${JOB_NAME}.${EXTENSION}"

# array of episodes along with correct episode number to assign
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

# check to see if filename contains any of the episodes
FOUND=0
for KEY in "${!EPISODE_ARRAY[@]}"; do
  if echo "${NEW_FILENAME}" | grep -qEio "\.${KEY}"; then
    FOUND=1
    break
 fi
done

# if filename does not contain wanted episode name, then stop and delete files
if [[ $FOUND -eq 0 ]]; then
  echo "Filename does not contain wanted episode criteria ... aborting"
  rm -rf "${SRC_DIR}"
  exit 1
fi

# extract info we need to rename for plex
YEAR=$(echo "${NEW_FILENAME}" | cut -d. -f2)
SEASON=$(echo "${NEW_FILENAME}" | cut -d. -f3 | sed 's/Round//')
EPISODE="${EPISODE_ARRAY["${KEY}"]}"
LOCATION=$(echo "${NEW_FILENAME}" | cut -d. -f4)

# define new directory and filename for plex
PLEX_DIR="${DEST_DIR}/F1 ${YEAR}/${SEASON} - ${LOCATION} GP"
PLEX_NAME="${SEASON}x${EPISODE} - ${LOCATION} Grand Prix - ${KEY}"
PLEX_FILENAME="${PLEX_NAME}.${EXTENSION}"
# PLEX_POSTER="${PLEX_NAME}.png"

# create directories
mkdir -p "${PLEX_DIR}"

# check to see what network feed the file is.
# if feed is preferred feed, keep it, even if it's been downloaded before.
# if feed is NOT preferred feed, only keep it if there isn't any downloaded file
# the non preferred file will get overwritten if a preferred feed one becomes available
NETWORK=$(echo "${NEW_FILENAME}" | sed -n "s/.*${KEY}.//Ip" | sed 's/.WEB.*//')

if echo "${NETWORK}" | grep -qEio "${PREFERRED_FEED}"; then
  echo "File is Preferred Network (${PREFERRED_FEED})."
  mv "${SAB_FILE}" "${PLEX_DIR}/${PLEX_FILENAME}"
  echo "Copied"  
#   echo "Copying poster to ${PLEX_DIR}/${PLEX_POSTER}"
#   cp "${POSTER_DIR}/${EPISODE}.png" "${PLEX_DIR}/${PLEX_POSTER}"
else
  if [ ! -f "${PLEX_DIR}/${PLEX_FILENAME}" ]; then
    echo "File is not Preferred Feed (${PREFERRED_FEED}) and file does not exist."
    mv "${SAB_FILE}" "${PLEX_DIR}/${PLEX_FILENAME}"
    echo "Copied"
    # echo "Copying poster to ${PLEX_DIR}/${PLEX_POSTER}"
    # cp "${POSTER_DIR}/${EPISODE}.png" "${PLEX_DIR}/${PLEX_POSTER}"
  else
    echo "File is not Preferred Feed (${PREFERRED_FEED}) and file already exists."
    echo "Skipped"
    rm -rf "${SRC_DIR}"
    exit 0
  fi
fi

# remove sabnzbd files that are left over
echo "Cleaning up sabnzbd files"
rm -rf "${SRC_DIR}"

# set user friendly permissions
echo "Setting permissions for ${PLEX_DIR}/${PLEX_FILENAME}"
chmod 774 "${PLEX_DIR}/${PLEX_FILENAME}"

echo "Post-Processing Script Completed"
exit 0
