#!/usr/bin/env python3
import sys
import os
from datetime import datetime

"""
SABnzbd Pre-Queue Script (Hybrid RAM + NVMe)
"""

# Settings
RAM_THRESHOLD = 15 * 1024**3   # 15 GB max job size for RAM
SAFETY_MARGIN = 4 * 1024**3    # 4 GB headroom required
RAM_PATH = "/ram/incomplete"
DISK_PATH = "/data/net/incomplete"

# Log file path (inside sab scripts folder)
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_FILE = os.path.join(SCRIPT_DIR, "sab_prequeue_ramdisk.log")

def get_available_memory():
    """Read MemAvailable from /proc/meminfo (in bytes)."""
    with open("/proc/meminfo", "r") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                parts = line.split()
                return int(parts[1]) * 1024  # kB → bytes
    return 0

def log_decision(nzb_name, size_bytes, free_mem, dest_dir, reason):
    """Append a decision log entry."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_FILE, "a") as log:
        log.write(
            f"[{timestamp}] Job: {nzb_name}, Size: {size_bytes/1024**3:.2f} GB, "
            f"FreeMem: {free_mem/1024**3:.2f} GB, Dest: {dest_dir}, Reason: {reason}\n"
        )

# SAB passes 10 args minimum: https://sabnzbd.org/wiki/scripts/pre-queue-scripts
nzb_id, nzb_name, nzb_path, pp, script, cat, priority, nzb_size, url, user = sys.argv[1:11]

# Convert job size string to int (bytes)
try:
    size_bytes = int(nzb_size)
except ValueError:
    size_bytes = 0

free_mem = get_available_memory()

# Decide destination
if size_bytes and size_bytes < RAM_THRESHOLD and free_mem > (size_bytes + SAFETY_MARGIN):
    dest_dir = RAM_PATH
    reason = "Fits in RAM"
else:
    dest_dir = DISK_PATH
    if size_bytes >= RAM_THRESHOLD:
        reason = "Too large for RAM"
    elif free_mem <= (size_bytes + SAFETY_MARGIN):
        reason = "Not enough free memory"
    else:
        reason = "Unknown fallback"

# Log decision
log_decision(nzb_name, size_bytes, free_mem, dest_dir, reason)

# Output format: "cat priority pp script dest_dir"
print(f"{cat} {priority} {pp} {script} {dest_dir}")
sys.exit(0)