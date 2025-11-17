#!/bin/bash
noParity=true
clearLog=false

# Stop if another instance is running
pidof -o %PPID -x "$0" >/dev/null && \
  logger -p err "Error: Script $0 already running, exiting!" && \
  exit 1

# --------------------------------------------------------------------------------
# SETTINGS

src_dir="/mnt/user/secure/torrent"
dest_dir="/mnt/user/secure"

# --------------------------------------------------------------------------------

# Function to rename patterns in files
rename_patterns() {
  local dir="$1"
  local patterns=("hhd800.com@" "gg5.co@")
  for pattern in "${patterns[@]}"; do
    find "$dir" -not \( -path "$dir/incomplete" -prune \) -type f \
      -exec rename -v "$pattern" '' {} \;
  done
}

# Function to remove unwanted file extensions
remove_unwanted_files() {
  local dir="$1"
  find "$dir" -not \( -path "$dir/incomplete" -prune \) -type f \
    \( -iname "*.url" -o -iname "*.html" -o -iname "*.txt" -o -iname "*.nfo" -o -iname "*.torrent" -o -iname "*.rejected" \) \
    -exec rm -v {} \;
}

# Function to move files from source to destination
move_files() {
  local src="$1"
  local dest="$2"
  mkdir -p "$dest"
  mv -f "$src"/* "$dest/"
}

# Function to move プライベート subdirectories
move_private_subdirs() {
  local src_base="$1"
  local dest_base="$2"
  local subdirs=(
    "Ai.Kano.叶爱"
    "Aika.Yumeno.夢乃あいか"
    "Akari.Niimura.新村あかり"
    "Ena.Satsuki.沙月恵奈"
    "Karen.Yuzuriha.楪カレン"
    "Sora.Amakawa.天川そら"
    "Sui.Twinkle.月野江すい"
    "Yui.Tenma.天馬ゆい"
  )
  for subdir in "${subdirs[@]}"; do
    move_files "$src_base/$subdir" "$dest_base/$subdir"
  done
}

# Record start time and check if source is empty
if [[ -z "$(find "$src_dir"/ -mindepth 1 -type f)" ]]; then
  echo "Source directory empty, script exit!"
  exit 1
else
  chmod -R 775 "$src_dir/"
  chown -R nobody "$src_dir/"
fi

# Rename files for metadata scans
rename_patterns "$src_dir"

# Remove unwanted files extensions
remove_unwanted_files "$src_dir"
find "$src_dir/complete/" -iname "18+游戏大全(996gg.cc)-七龍珠H版-三國志H版-三國群淫傳等.mp4" -type f -print -exec rm -v {} \;

# Atomic move for ポルノ
if [[ -n "$(find "$src_dir/complete/ポルノ/" -mindepth 1 -type f)" ]]; then
  move_files "$src_dir/complete/ポルノ" "$dest_dir/ポルノ"
else
  echo "Skip move, ポルノ directory empty!"
fi

# Atomic move for プライベート subdirectories
if [[ -n "$(find "$src_dir/complete" -not \( -path "$src_dir/complete/ポルノ" -prune \) -mindepth 1 -type f)" ]]; then
  move_private_subdirs "$src_dir/complete" "$dest_dir/プライベート"
else
  echo "Skip move, プライベート directory empty!"
  exit 1
fi

# Update VueTorrent webui
cd /mnt/user/appdata/qbittorrent/webui
rm -r VueTorrent
git clone --single-branch --branch latest-release https://github.com/VueTorrent/VueTorrent.git
cd ~

exit 0