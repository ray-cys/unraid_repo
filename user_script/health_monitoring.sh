#!/bin/bash
# shellcheck disable=SC2034
noParity=true
set -euo pipefail
LOCKFILE="/tmp/health_monitoring.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Another run health_monitoring.sh active, exiting (lock: $LOCKFILE)" >&2
    exit 1
fi
# Disk Health Monitor for Unraid
# Purpose: Run SMART tests, parse SMART/NVMe attributes, track endurance & risk, capture filesystem health,
# evaluate capacity growth, detect firmware/regression events, surface I/O error frequency, and emit concise
# notifications.
################################################################################
# ---------------- Configuration ----------------
# Disks health script settings. Tuned for performance and reliability.
################################################################################

# === SMART Test Scheduling ===
SHORT_TEST_POLL=1                               # Poll short test until it completes (0=fire-and-forget)
SHORT_TEST_MAX_WAIT=180                         # Max seconds to wait while polling short tests
SHORT_TEST_POLL_INTERVAL=10                     # Interval between polls (seconds)
LONG_TEST_ACCEL_FACTOR=2                        # Accelerate next long test interval (divide) after recent risk spike
LONG_TEST_MIN_INTERVAL_DAYS=30                  # Do not recommend long test sooner than this many days after last long
LONG_TEST_MAX_INTERVAL_DAYS=90                  # Maximum fallback days between long tests when no recent risk spike
LONG_TEST_RISK_LOOKBACK_DAYS=14                 # Consider risk spikes within this many days for acceleration
LONG_TEST_RISK_THRESHOLD=50                     # Risk score >= triggers long test consideration
LONG_TEST_CRITICAL_MIN_DAYS=7                   # Critical SMART & last long age >= days -> force long
LONG_TEST_RISK_MIN_DAYS=0                       # Min days since last long before risk-based scheduling applies
LONG_TEST_DECISION=""                           # Accumulator for long test scheduling decisions
LONG_TEST_NEAR_WINDOW_DAYS=7                    # Show health alert when long test is due within N days
LONG_TEST_INITIAL_FORCE=0                       # When no prior long test record, force an immediate long (1=enable, 0=skip)
REPLACEMENT_AUTO_RESET=1                        # Automatically detect drive replacement via POH drop and reset state
REPLACEMENT_POH_DROP_THRESHOLD_HOURS=24         # Default fallback drop threshold (hours) if type unknown
REPLACEMENT_POH_DROP_THRESHOLD_HOURS_HDD=24     # HDD: POH drop >= threshold => replacement
REPLACEMENT_POH_DROP_THRESHOLD_HOURS_SSD=12     # SATA SSD: smaller drop threshold
REPLACEMENT_POH_DROP_THRESHOLD_HOURS_NVME=6     # NVMe: smallest drop threshold

# === Capacity Thresholds ===
WARN_THRESHOLD_PERCENT=96                       # Per-disk usage percent -> warning
CRITICAL_THRESHOLD_PERCENT=98                   # Per-disk usage percent -> critical
THRESHOLD=90                                    # Array/pools overall usage percent considered full
NEAR_THRESHOLD_DELTA=5                          # "Near full" if within this percent of THRESHOLD
POOL_EXCLUDES=("ramtmp" "user0")                # Pool names excluded from pool totals

# === Storage Validation / Discrepancy Alerts ===
STORAGE_DISCREPANCY_ALERT_ENABLED=1             # Emit warning alert after sustained diff (0=disable)
STORAGE_DISCREPANCY_MIN_DIFF=5.0                # Minimum absolute percent diff to count toward streak
STORAGE_DISCREPANCY_SUSTAIN_RUNS=2              # Consecutive runs >= diff before alert recorded

# === Filesystem / Device Monitoring Toggles ===
ENABLE_BTRFS_SCRUB=0                            # Start btrfs scrub vs just parse last status
FIRST_RUN_FORCE=1                               # Force initial scrub on first run when disabled (0=disable)
BTRFS_SCRUB_STATE_TTL_DAYS=90                   # Days to retain scrub state files
ENABLE_BTRFS_DEVICE_STATS=1                     # Parse btrfs per-device stats and integrate (0=disable)
BTRFS_TREND_TOP_N=5                             # Top N devices by error delta
BTRFS_TREND_WINDOW_DAYS=7                       # Window for btrfs device trend aggregation
ENABLE_XFS_CHECK=0                              # Run xfs_repair -n metadata check (0=disable)
ENABLE_XFS_PROC_STATS=1                         # Parse /proc/fs/xfs/stat counters (0=disable)
XFS_PROC_PER_MOUNT_ALERTS=0                    # 1: emit per-mount warnings from proc spikes; 0: single global alert
XFS_PROC_REQUIRE_RATIO_FOR_ALERT=1             # 1: only alert on burst ratio triggers; 0: also alert on absolute deltas
XFS_PROC_KEYS=""                               # Space-separated keys to monitor; empty uses sane defaults
XFS_PROC_KEYS_EXCLUDE="extent_alloc dir_create dir_lookup delalloc flush" # Space-separated keys to exclude (e.g., "extent_alloc dir_create")
XFS_PROC_SMART_ANNOTATE_BURST=0                # 1: add SMART note to all XFS devices on burst; 0: do not annotate
XFS_PROC_SUPPRESS_DURING_PARITY=1              # 1: suppress XFS proc alerts while parity is running
IO_ERROR_LOG_FILE="/var/log/syslog"             # Syslog path fallback to dmesg
IO_ERROR_WINDOW_MINUTES=60                      # Time window (minutes) for de-dup/frequency
IO_ERROR_WARN_THRESHOLD=5                       # Unique error events >= warning
IO_ERROR_CRIT_THRESHOLD=20                      # Unique error events >= critical

# === Trends & Alerts: Toggles ===
AGE_AWARE_ENABLED=1                             # Annotate near-endurance devices (0=disable)
NVME_WEAR_REGRESSION_WARN=1                     # Flag any NVMe Percentage Used regression (0=disable)
SMART_ATTR_TREND_ENABLED=1                      # Enable SMART attribute growth trend (0=disable)
ERROR_RATE_TREND_ENABLED=1                      # Enable Btrfs/XFS error rate acceleration trend (0=disable)
SATA_LINK_INSTABILITY_ENABLED=1                 # Enable SATA link instability frequency tracking (0=disable)
BTRFS_DEV_TREND_ENABLED=1                       # Persist & render per-device btrfs error trends (0=disable)
SHARE_BREAKDOWN_ENABLED=0                       # Compute per-share usage (heavy) (0=disable)
RISK_SCORING_ENABLED=1                          # Show risk scores section (0=disable)
LIFECYCLE_ENABLED=1                             # Show lifecycle buckets (0=disable)
POH_TREND_ENABLED=1                             # Enable POH aging trend snapshot & section
TBW_TREND_ENABLED=1                             # Enable TBW days-left trend snapshot & section
TEMP_RATE_ALERT_ENABLED=1                       # Enable temperature change rate alerts (0=disable)
IO_ERROR_MONITOR_ENABLED=1                      # Enable syslog scanning for disk I/O frequency (0=disable)
IO_ERROR_DEDUP_ENABLED=1                        # De-duplicate identical message hashes inside window (0=disable)

# === SMART / Endurance / Trend Parameters ===
PARITY_SYNC_ERR_WARN=1                          # Parity sync errors threshold for warning alert
PARITY_SYNC_ERR_CRIT=10                         # Parity sync errors threshold for critical alert
POH_RESET_CRIT_THRESHOLD=500                    # POH drop > threshold -> critical reset event
SMART_ATTR_TREND_WINDOW_DAYS=7                  # Days window for SMART attribute growth trend
SMART_ATTR_TREND_TOP_N=5                        # Top N disks by summed attribute delta
SMART_ATTR_TREND_MIN_DELTA=1                    # Minimum per-attribute delta to include in output
ENDURANCE_DAYSLEFT_TOP_N=5                      # Top N devices by shrink rate
ENDURANCE_DAYSLEFT_ACCEL_FACTOR_PCT=50          # Last-day shrink exceeds avg by this percent -> acceleration flag
ENDURANCE_DAYSLEFT_ACCEL_MIN_DELTA=0.5          # Minimum single-day shrink (days) to consider acceleration
ERROR_RATE_TREND_WINDOW_DAYS=7                  # Days window for error acceleration analysis
ERROR_RATE_TREND_TOP_N=5                        # Top N accelerated devices/mounts
ERROR_RATE_ACCEL_FACTOR_PCT=100                 # Last interval delta > avg previous * (1+factor/100) => ACCEL
ERROR_RATE_ACCEL_MIN_DELTA=2                    # Minimum last-interval delta to consider acceleration
ERROR_RATE_ACCEL_FACTOR_CORRUPTION=50           # Override acceleration factor pct for corruption_errs key
ERROR_RATE_ACCEL_MIN_DELTA_CORRUPTION=1         # Override min delta for corruption_errs key
ERROR_RATE_ACCEL_FACTOR_GENERATION=75           # Override acceleration factor pct for generation_errs key
ERROR_RATE_ACCEL_MIN_DELTA_GENERATION=1         # Override min delta for generation_errs key
SATA_LINK_INSTABILITY_WINDOW_DAYS=14            # Days window for link instability analysis
SATA_LINK_INSTABILITY_STREAK_WARN=2             # Consecutive days with downshift events -> warning
SATA_LINK_INSTABILITY_STREAK_CRIT=5             # Consecutive days with downshift events -> critical

# === Export / History / Logging ===
HISTORY_WINDOW_DAYS=14                          # Days considered for usage growth trends
DYNAMIC_GROWTH=0                                # Use first vs last sample over actual elapsed days
SHARE_TOP_N=5                                   # Top N shares by size/growth
LOG_PRUNE_ENABLED=1                             # Prune old run logs in LOG_DIR
LOG_MAX_DAYS=0                                  # Age pruning days (0=disable)
LOG_MAX_COUNT=3                                 # Max retained logs per pattern (0=disable)
HISTORY_PRUNE_ENABLED=1                         # Enable auto-prune of history files (0=disable)
HISTORY_MAX_DAYS=180                            # Remove lines older than this many days (0=disable age pruning)
HISTORY_MAX_LINES=20000                         # Keep at most this many recent lines per history file (0=disable line pruning)
LOG_MIRROR_STDOUT=1                             # Echo log lines to stdout

# === Risk / Lifecycle Settings ===
LIFECYCLE_ALERT_TOP_N=3                         # Max devices listed in lifecycle health alerts
RISK_TOP_N=5                                    # Entries shown in Risk Scores (top list)
RISK_REPLACE=80                                 # Score >= goes to Replace Soon bucket
RISK_MONITOR=50                                 # Score >= goes to Monitor bucket
ENDURANCE_TREND_WINDOW_DAYS=7                   # Window (days) for endurance & aging trend
ENDURANCE_TREND_TOP_N=5                         # Top N devices to display per trend
ENDURANCE_TREND_MIN_POH_DELTA=24                # Min POH hour delta to include device

# === Display / Notification Preferences ===
FORECAST_PRECISION_DECIMALS=3                   # Decimals to show for daily percent growth
SHOW_SUBSYSTEMS_BLOCK="auto"                    # Subsystems block policy (auto|always|never)
SHOW_OK_SUBSYSTEMS=0                            # Hide OK subsystems if any WARN/CRIT exist (0=show)
SHOW_DISABLED_SUBSYSTEMS=0                      # Hide Disabled subsystems in description/body (0=show)
VERBOSE_OK=1                                    # Show OK lines (0=suppress)
SHOW_ZERO_COUNTS=0                              # Hide zero-count summary lines (1=show)

# === Temperature Trend / Rate Thresholds (Global) ===
TEMP_RATE_WARN_C_PER_DAY=2.5                    # Avg rise °C/day >= warning threshold (global)
TEMP_RATE_CRIT_C_PER_DAY=5.0                    # Avg rise °C/day >= critical threshold (global)
TEMP_RATE_MIN_SPAN_DAYS=1.0                     # Minimum span days required to evaluate rate (global)

# === SMART Thresholds (SATA) ===
RELOC_WARNING=1                                 # Reallocated sectors >= warning
RELOC_CRITICAL=10                               # Reallocated sectors >= critical
PEND_WARNING=1                                  # Pending sectors >= critical
SSD_TEMP_WARNING=65                             # SATA SSD temp C >= warning
SSD_TEMP_CRITICAL=70                            # SATA SSD temp C >= critical
HDD_TEMP_WARNING=55                             # HDD temp C >= warning
HDD_TEMP_CRITICAL=60                            # HDD temp C >= critical
LOAD_CYCLE_WARN=300000                          # HDD load cycle count >= warning
LOAD_CYCLE_CRIT=600000                          # HDD load cycle count >= critical
SSD_WEAR_WARN=20                                # SSD life remaining (%) <= warning
SSD_WEAR_CRIT=10                                # SSD life remaining (%) <= critical
REPORTED_UNC_CRIT=1                             # SATA attr 187 any >0 critical
CMD_TIMEOUT_WARN=5                              # SATA attr 188 >= warning
CMD_TIMEOUT_CRIT=50                             # SATA attr 188 >= critical
CMD_TIMEOUT_DELTA_WARN=5                        # Increase in attr 188 between runs >= triggers rate alert (0=disable)
CMD_TIMEOUT_COOLDOWN_DAYS=2                     # Suppress repeated delta alerts for N days (0=disable)
REALLOC_EVENT_WARN=1                            # SATA attr 196 >= warning
REALLOC_EVENT_CRIT=10                           # SATA attr 196 >= critical
END_TO_END_ERR_CRIT=1                           # SATA attr 184 any >0 critical
SOFT_READ_ERR_WARN=1000                         # SATA attr 201 >= warning (heuristic)

# === SMART Thresholds (NVMe) ===
NVME_TEMP_WARNING=70                             # NVMe temp C >= warning
NVME_TEMP_CRITICAL=80                            # NVMe temp C >= critical
NVME_PERCENT_USED_WARN=80                        # NVMe wear percent >= warning
NVME_PERCENT_USED_CRIT=90                        # NVMe wear percent >= critical
WEAR_TREND_ENABLED=1                             # Enable NVMe wear depletion projection
WEAR_TREND_WINDOW_DAYS=90                        # Window for percent_used slope (days)
WEAR_TREND_TOP_N=5                               # Top N soonest depletion estimates
WEAR_STABLE_MIN_RATE=0.005                       # Percent/day below which treat as stable (shows ∞)
WEAR_DAYS_LEFT_WARN=180                          # Projected days-left <= warning threshold (0=disable)
WEAR_DAYS_LEFT_CRIT=90                           # Projected days-left <= critical threshold (0=disable)
WRITER_WEEKLY_WARN_PCT=3                         # Weekly write volume as % of capacity >= warning
WRITER_WEEKLY_CRIT_PCT=5                         # Weekly write volume as % of capacity >= critical
WRITER_TIER_MODERATE_PCT=1                       # Weekly % >= this and < warn -> Moderate tier; below -> Light
UNSAFE_SDWN_DELTA_WARN=5                         # Unsafe shutdowns delta >= warning (M)
UNSAFE_SDWN_ABSOLUTE_MIN=100                     # Only warn if total unsafe shutdowns >= N (0=disable)
UNSAFE_SDWN_COOLDOWN_DAYS=3                      # Suppress repeat warnings for X days after one triggers (0=disable)
NVME_AVAIL_SPARE_WARN=5                          # Available Spare (%) below -> warning
NVME_ERR_LOG_DELTA_WARN=1                        # NVMe Error Information Log Entries delta >= warn
NVME_ERR_LOG_DELTA_CRIT=10                       # NVMe Error Information Log Entries delta >= critical
NVME_PCIE_CORR_DELTA_WARN=1                      # NVMe PCIe Correctable Error Count delta >= warn
NVME_PCIE_CORR_DELTA_CRIT=50                     # NVMe PCIe Correctable Error Count delta >= critical
NVME_PCIE_UNC_DELTA_WARN=1                       # NVMe PCIe Uncorrectable Error Count delta >= warn (usually critical on any)
NVME_PCIE_UNC_DELTA_CRIT=1                       # NVMe PCIe Uncorrectable Error Count delta >= critical (any increase)
NVME_THERM_T1_DELTA_WARN=1                       # NVMe Thermal Management T1 Transitions delta >= warn
NVME_THERM_T2_DELTA_WARN=1                       # NVMe Thermal Management T2 Transitions delta >= warn (treat as critical if >=1)
NVME_WARN_TEMP_TIME_DELTA_WARN=60                # NVMe Warning Comp. Temperature Time delta (seconds) >= warn
NVME_CRIT_TEMP_TIME_DELTA_WARN=10                # NVMe Critical Comp. Temperature Time delta (seconds) >= warn (usually critical if >0)

# === Btrfs / XFS Snapshot & Device Thresholds ===
SNAPSHOT_WARN=100                                # btrfs snapshot count >= warning
SNAPSHOT_CRIT=500                                # btrfs snapshot count >= critical
BTRFS_DEV_ERR_WARN_DELTA=1                       # Per-device read/write/flush err delta >= warning
BTRFS_DEV_ERR_CRIT_DELTA=10                      # Per-device read/write/flush err delta >= critical
BTRFS_DEV_CORR_WARN_DELTA=1                      # Per-device corruption/gen err delta >= warning
BTRFS_DEV_CORR_CRIT_DELTA=1                      # Per-device corruption/gen err delta >= critical
BTRFS_ERR_BURST_WARN_RATIO=5                     # Btrfs device error delta / previous delta >= warn ratio
BTRFS_ERR_BURST_CRIT_RATIO=10                    # Btrfs device error delta / previous delta >= critical ratio
XFS_PROC_WARN_DELTA=1000                         # xfs stat delta >= warning
XFS_PROC_CRIT_DELTA=4000                         # xfs stat delta >= critical
XFS_ERR_BURST_WARN_RATIO=8                       # xfs delta / previous-delta >= warn ratio
XFS_ERR_BURST_CRIT_RATIO=20                      # xfs delta / previous-delta >= critical ratio
BURST_WARN_BOOST=15                              # Composite SMART boost for warning burst events
BURST_CRIT_BOOST=30                              # Composite SMART boost for critical burst events

# === POH (Power-On Hours) Age Thresholds ===
HDD_POH_WARN_HOURS=17520                         # HDD warn
HDD_POH_CRIT_HOURS=43800                         # HDD critical
SSD_POH_WARN_HOURS=26280                         # SATA SSD warn
SSD_POH_CRIT_HOURS=43800                         # SATA SSD critical
NVME_POH_WARN_HOURS=26280                        # NVMe warn
NVME_POH_CRIT_HOURS=43800                        # NVMe critical

# === TBW / Endurance Forecast Thresholds ===
TBW_DAYS_WARN=14                                 # Remaining TBW forecast days < warning
TBW_DAYS_CRIT=3                                  # Remaining TBW forecast days < critical
TBW_WARN_TB=480                                  # Fallback TBW absolute threshold (TB)
DEFAULT_SSD_ENDURANCE_PER_TB=300                 # Fallback endurance (TB) for unknown SATA/NVMe SSD models
TBW_CONSUMED_WARN=80                             # Consumed percent of model TBW >= warning
TBW_CONSUMED_CRIT=95                             # Consumed percent of model TBW >= critical

# === Risk Scoring Weights ===
W_SEV_CRIT=70                                    # Base score for CRITICAL devices
W_SEV_WARN=30                                    # Base score for WARNING devices
W_PENDING=40                                     # Pending sectors weight
W_UNCORR=50                                      # Uncorrectables weight
W_REALLOC=15                                     # Reallocated sectors present
W_REALLOC_EVENTS=10                              # Reallocation events weight
W_CMD_TIMEOUT=10                                 # Command timeouts weight
W_CRC=5                                          # UDMA CRC errors weight
W_SSD_LIFE=20                                    # Low SSD life remaining weight
W_NVME_WEAR=20                                   # High NVMe wear weight
W_NVME_ERR_LOG=15                                # NVMe error log entries growth weight
W_NVME_PCIE_CORR=10                              # NVMe PCIe correctable errors growth weight
W_NVME_PCIE_UNC=50                               # NVMe PCIe uncorrectable errors growth weight
W_NVME_THERM_TRANS=10                            # NVMe thermal transition growth weight
W_NVME_TEMP_TIME=15                              # NVMe temperature time accumulation weight
W_TEMP=10                                        # High temperature weight
W_E2E=40                                         # End-to-End errors weight
W_SOFT_READ=10                                   # Soft read error rate weight
W_NVME_RO=80                                     # NVMe read-only mode weight
W_NVME_REL=60                                    # NVMe reliability degraded weight
W_AGE_NEAR=30                                    # Near endurance extra weight
W_POH_HDD=10                                     # High HDD POH age weight
W_POH_SSD=10                                     # High SATA SSD POH age weight
W_POH_NVME=10                                    # High NVMe POH age weight
W_BTRFS_DEV_ERR=3                                # Btrfs per-device I/O/corruption errors weight
W_XFS_META_ERR=3                                 # XFS metadata/stat anomalies weight
W_SATA_LINK_DOWN=10                              # SATA negotiated link downshift weight
W_SELFTEST_CRIT=40                               # SMART self-test critical result weight
W_SELFTEST_WARN=15                               # SMART self-test warning/ambiguous result weight
W_TBW_CONS_WARN=10                               # TBW consumed over warn threshold
W_TBW_CONS_CRIT=25                               # TBW consumed over critical threshold

# === Model-Specific Overrides ===
# Rule format uses ';'-separated key:value pairs per line. Supported keys:
#  - regex: POSIX ERE to match model string (case-insensitive)
#  - cap_min / cap_max: optional decimal TB capacity window (inclusive)
#  - per_tb: TBW endurance per TB of capacity (numeric)
#  - type: nvme | sata-ssd | sata-hdd (for POH overrides)
#  - warn / crit: POH hours thresholds (numeric)
#  - action: for quirks (e.g., invert_mwi_small)
# TBW endurance per TB overrides (model + optional capacity window)
TBW_MODEL_RULES='\
regex:MX500;per_tb:350
regex:WD[[:space:]]+Red.*SA500;cap_min:0.45;cap_max:0.55;per_tb:700
regex:WD[[:space:]]+Red.*SA500;cap_min:0.95;cap_max:1.05;per_tb:600
regex:Crucial[[:space:]]*T500;cap_min:0.95;cap_max:1.05;per_tb:600
regex:Crucial[[:space:]]*P5(\\+|[[:space:]]*Plus|P5P);cap_min:0.95;cap_max:1.05;per_tb:600
'
# POH threshold overrides by device type and model
POH_MODEL_RULES='\
type:nvme;regex:Crucial[[:space:]]*T500;warn:4000;crit:6000
type:nvme;regex:Crucial.*P5P|Crucial[[:space:]]*P5[[:space:]]*Plus|P5\\+;cap_min:0.95;cap_max:1.05;warn:4000;crit:6000
type:sata-hdd;regex:Ultrastar;warn:50000;crit:70000
type:sata-ssd;regex:SA500|WD[[:space:]]+Red[[:space:]]+SA500;warn:6000;crit:10000
'
# Parsing/compatibility quirks (e.g., vendor-reported life remaining anomalies)
QUIRK_MWI_RULES='\
action:invert_mwi_small;regex:WD[[:space:]]+Red.*SA500;cap_min:0.48;cap_max:0.52
'


# === Internals (do not modify unless needed) ===
ALERT_WARN=()                                     # Accumulator for warning messages
ALERT_CRIT=()                                     # Accumulator for critical messages
declare -A SMART_STATE                            # Map device -> OK/WARNING/CRITICAL
declare -A SMART_MSGS                             # Map device -> aggregated SMART message string
declare -A MOUNT_TO_DEV                           # Map /mnt/diskX -> /dev/sdX|nvme
declare -A POOL_MEMBER_MAP                        # Map base device (/dev/sdX|nvme0n1) -> pool name
declare -A MODEL_CACHE                            # Base device -> model string
declare -A CAPACITY_CACHE                         # Base device -> capacity TB (formatted numeric string)
declare -A SMART_RAW                              # Base device -> cached SATA smartctl -A output
declare -A NVME_RAW                               # Base device -> cached NVMe smartctl -a output
declare -A NVME_EXT_RAW                           # Base device -> cached NVMe smartctl -x output
declare -A SMART_INFO                             # Base device -> cached SATA smartctl -i output
declare -A BURST_BOOST                            # Base device -> accumulated burst boost this run (0-100)
declare -A TBW_STATUS_MAP                         # Map device -> TBW status (OK/WARNING/CRITICAL)
declare -A TBW_DAILY                              # Map device -> daily TBW bytes (over window)
declare -A TBW_DAYS_LEFT                          # Map device -> forecasted days left to endurance
declare -A IO_ERROR_RAW_MAP                       # Map device -> raw I/O error line count (duplicates included)
declare -A IO_ERROR_UNIQUE_MAP                    # Map device -> unique I/O error event count (dedup within window)
declare -A LAST_TEST                              # Map device -> last SMART test timestamp
declare -A NVME_LAST_UNSAFE                       # NVMe device -> last unsafe shutdown count
declare -A NVME_LAST_ERRLOG                       # NVMe device -> last error information log entries
declare -A NVME_LAST_PCIE_CORR                    # NVMe device -> last PCIe correctable error count
declare -A NVME_LAST_PCIE_UNC                     # NVMe device -> last PCIe uncorrectable error count
declare -A NVME_LAST_THERM_T1                     # NVMe device -> last thermal management T1 transitions
declare -A NVME_LAST_THERM_T2                     # NVMe device -> last thermal management T2 transitions
declare -A NVME_LAST_WARN_TEMP_TIME               # NVMe device -> last warning temperature time (seconds)
declare -A NVME_LAST_CRIT_TEMP_TIME               # NVMe device -> last critical temperature time (seconds)
declare -A PREV_ATTR                              # device|attr -> previous raw value
declare -A CUR_ATTR                               # device|attr -> current raw value
declare -A NEW_SEEN                               # Newly seen alerts/disks set
declare -A LONG_LAST_POH                          # Map device -> last long self-test lifetime hours
declare -A LONG_TEST_DUE_SOON                     # Map device -> days until next long test when near
declare -A CMD_TIMEOUT_LAST                       # Map device -> previous command timeout count
declare -A SELFTEST_WARN_SEEN                     # Map normalized self-test warning/critical messages (dedup within run)
declare -A LONG_TEST_RUNNING_LONG                 # Map device -> 1 if a long/extended self-test is currently in progress
declare -A RISK_SPIKE_TS                          # Map device -> epoch timestamp of last captured risk spike

# === Logs Paths ===
LOG_DIR="/mnt/user/cloud/logs/disk_health"        # Base directory for logs files
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')              # Timestamp used for rotating log filenames
mkdir -p "$LOG_DIR" 2>/dev/null || true
MASTER_LOG="$LOG_DIR/disk_health_$TIMESTAMP.log"  # Consolidated master log

# === Unified Subsystem Logging ===
_subsys_emit() {
    local tag="$1"; shift
    local raw="$*"
    if [[ "$raw" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        raw="$(echo "$raw" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} - //')"
    fi
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[$tag] $ts - $raw"
    if (( ${LOG_MIRROR_STDOUT:-0} == 1 )); then echo "$line"; fi
    echo "$line" >> "$MASTER_LOG"
}
log_smart() { _subsys_emit SMART "$*"; }
log_btrfs() { _subsys_emit BTRFS "$*"; }
log_xfs()   { _subsys_emit XFS   "$*"; }

# === Severity (INFO/WARN/CRIT) ===
log_emit() {
    local sev="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ "$msg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        msg="$(echo "$msg" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} - //')"
    fi
    local line="[${sev}] $ts - $msg"
    if (( ${LOG_MIRROR_STDOUT:-0} == 1 )); then echo "$line"; fi
    echo "$line" >> "$MASTER_LOG"
}
log_info()  { log_emit INFO "$*"; }
log_warn()  { log_emit WARN "$*"; }
log_crit()  { log_emit CRIT "$*"; }

# === State Files ===
STATE_DIR="/mnt/user/cloud/logs/disk_health/state"                  # Base directory for state files
mkdir -p "$STATE_DIR"
# --- Alerting & Runtime (immediate health evaluation, deltas, cooldowns, recent events) ---
SMART_LONG_STATE_FILE="$STATE_DIR/smart_long_processed.log"         # Long SMART test last run time per disk (scheduling)
SMART_LONG_LAST_POH_FILE="$STATE_DIR/smart_long_last.log"           # Long SMART test last POH snapshot per disk (delta vetting)
SMART_LAST="$STATE_DIR/smart_last_test.log"                         # Last SMART test type/time per disk (summary)
SMART_SELFTEST_DIR="$STATE_DIR/smart_selftest"                      # Per-disk SMART self-test logs (lifecycle events)
NVME_STATE_FILE="$STATE_DIR/counters_last.log"                      # NVMe counters last snapshot (delta alerts)
PREV_ATTR_FILE="$STATE_DIR/smart_prev_attrs.log"                    # Previous SMART/NVMe attribute raw values (delta calculations)
ALERT_NEW_SEEN_FILE="$STATE_DIR/new_alerts_seen.log"                # Newly seen alert/device tracking (de-dup noise)
RISK_PREV_FILE="$STATE_DIR/risk_prev.log"                           # Previous risk score per disk (change detection)
CMD_TIMEOUT_LAST_FILE="$STATE_DIR/cmd_timeout_last.log"             # Previous command timeout counts (delta alerting)
CMD_TIMEOUT_STATE_DIR="$STATE_DIR/cmd_timeout"                      # Per-disk command timeout cooldown files
UNSAFE_SDWN_STATE_DIR="$STATE_DIR/unsafe_shutdown"                  # Per-NVMe unsafe shutdown cooldown files
BTRFS_SCRUB_STATE_DIR="$STATE_DIR/btrfs_scrub_status"               # Per-pool scrub status (in-progress vs last)
XFS_PROC_PREV_FILE="$STATE_DIR/xfs_proc_stats_prev.log"             # Previous XFS /proc snapshot (delta anomaly detection)
STORAGE_DISCREPANCY_STATE_FILE="$STATE_DIR/storage_discrepancy_streak.log"  # Storage discrepancy streak counter
RISK_SPIKE_FILE="$STATE_DIR/risk_spikes.log"                        # Persisted risk spike timestamps (accelerated scheduling)
REPLACEMENT_EVENTS_FILE="$STATE_DIR/replacement_events.log"         # Drive replacement lifecycle events (alerts context)
SATA_LINK_HISTORY_FILE="$STATE_DIR/sata_link_downshift_history.log" # SATA link instability events (alert context)
# --- Trend / Historical Analytics (longer-term forecasting, prioritization, trajectory) ---
CAPACITY_HISTORY_FILE="$STATE_DIR/capacity_history.log"             # Array & pool capacity history (growth forecast)
DISK_CAP_HISTORY_FILE="$STATE_DIR/disk_cap_history.log"             # Per-disk capacity history (slot pressure)
SHARE_USAGE_HISTORY_FILE="$STATE_DIR/share_usage_history.log"       # Per-share usage history (top growth)
HEAVY_WRITER_HISTORY_FILE="$STATE_DIR/heavy_writer_history.log"     # Weekly write volume samples (tiering/prioritization)
RISK_TIER_HISTORY_FILE="$STATE_DIR/risk_tier_history.log"           # Aggregated risk tier counts (fleet drift)
IO_ERROR_HISTORY_FILE="$STATE_DIR/io_error_history.log"             # I/O error frequency timeline (acceleration)
BTRFS_DEV_HIST_FILE="$STATE_DIR/btrfs_device_stats_history.log"     # Btrfs per-device error deltas over time
XFS_PROC_HISTORY_FILE="$STATE_DIR/xfs_proc_stats_history.log"       # XFS stat counters history (metadata pressure trend)
POH_HISTORY_FILE="$STATE_DIR/poh_history.log"                       # POH timeline (lifecycle phase changes)
TBW_HISTORY_FILE="$STATE_DIR/tbw_history.log"                       # Total bytes written progression (wear modeling)
TBW_DAYSLEFT_HISTORY_FILE="$STATE_DIR/tbw_daysleft_history.log"     # TBW forecast days-left trajectory
SMART_ATTR_HISTORY_FILE="$STATE_DIR/smart_attr_history.log"         # Attribute growth time-series (trend alerts)
RISK_SCORES_HISTORY_FILE="$STATE_DIR/risk_scores_history.log"       # Historical composite / risk scores (optional analytics)
TEMP_HISTORY_FILE="$STATE_DIR/temp_history.log"                     # Temperature samples (rate & exposure)
SELFTEST_HISTORY_FILE="$STATE_DIR/selftest_events.log"              # SMART self-test lifecycle history (frequency/volatility)
# State files initialization
mkdir -p "$SMART_SELFTEST_DIR" "$UNSAFE_SDWN_STATE_DIR" "$BTRFS_SCRUB_STATE_DIR" "$CMD_TIMEOUT_STATE_DIR"
STATE_FILES_ALERT_RUNTIME=(
    "$SMART_LONG_STATE_FILE" "$SMART_LONG_LAST_POH_FILE" "$SMART_LAST" "$NVME_STATE_FILE" "$PREV_ATTR_FILE" "$ALERT_NEW_SEEN_FILE" "$RISK_PREV_FILE" "$CMD_TIMEOUT_LAST_FILE" "$XFS_PROC_PREV_FILE" "$STORAGE_DISCREPANCY_STATE_FILE" "$RISK_SPIKE_FILE" "$REPLACEMENT_EVENTS_FILE" "$SATA_LINK_HISTORY_FILE"
)
STATE_FILES_TREND_HISTORY=(
    "$CAPACITY_HISTORY_FILE" "$DISK_CAP_HISTORY_FILE" "$SHARE_USAGE_HISTORY_FILE" "$HEAVY_WRITER_HISTORY_FILE" "$RISK_TIER_HISTORY_FILE" "$IO_ERROR_HISTORY_FILE" "$BTRFS_DEV_HIST_FILE" "$XFS_PROC_HISTORY_FILE" "$POH_HISTORY_FILE" "$TBW_HISTORY_FILE" "$TBW_DAYSLEFT_HISTORY_FILE" "$SMART_ATTR_HISTORY_FILE" "$RISK_SCORES_HISTORY_FILE" "$TEMP_HISTORY_FILE" "$SELFTEST_HISTORY_FILE"
)
for f in "${STATE_FILES_ALERT_RUNTIME[@]}" "${STATE_FILES_TREND_HISTORY[@]}"; do
    if [[ ! -f "$f" ]]; then
        true > "$f" 2>/dev/null || true
    fi
done
if [[ ! -s "$STORAGE_DISCREPANCY_STATE_FILE" ]]; then
    printf '0 0\n' > "$STORAGE_DISCREPANCY_STATE_FILE" 2>/dev/null || true
fi

# === Notification Settings ===
NOTIFY_TITLE_SMART="SMART Test Alert"                       # SMART test notifications
NOTIFY_TITLE_BTRFS="Btrfs Scrub Alert"                      # Btrfs scrub notifications
NOTIFY_TITLE_XFS="XFS Alert"                                # XFS filesystem notifications
NOTIFY_TITLE_DISKIO="Disk I/O Alert"                        # Disk I/O notifications
ENABLE_MODEL_IN_ALERTS=0                                    # If 1, append disk model to per-disk health alert lines

################################################################################

# === Helper Function ===
# Trim old run logs under STATE_DIR to keep history bounded
prune_old_run_logs() {
    (( LOG_PRUNE_ENABLED == 1 )) || return 0
    local patterns=("disk_health_*.log")
    local removed=0
    local removed_age=0
    local removed_count=0
    local examined=0
    for pat in "${patterns[@]}"; do
        # Age-based pruning (mtime exceeding LOG_MAX_DAYS)
        if (( LOG_MAX_DAYS > 0 )); then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                ((examined++)) || true
                rm -f -- "$f" && ((removed++)) && ((removed_age++)) || true
            done < <(find "$LOG_DIR" -maxdepth 1 -type f -name "$pat" -mtime +$LOG_MAX_DAYS 2>/dev/null)
        fi
        # Count-based pruning (oldest first until within limit)
        if (( LOG_MAX_COUNT > 0 )); then
            mapfile -t files < <(find "$LOG_DIR" -maxdepth 1 -type f -name "$pat" -printf '%T@\t%p\n' 2>/dev/null | sort -n | awk -F'\t' '{print $2}')
            while (( ${#files[@]} > LOG_MAX_COUNT )); do
                local oldest="${files[0]}"
                rm -f -- "$oldest" && ((removed++)) && ((removed_count++)) || true
                files=("${files[@]:1}")
            done
            if (( LOG_MAX_COUNT > 0 )); then
                log_info "Run log pruning: pattern = $pat retained = ${#files[@]} (limit = $LOG_MAX_COUNT)"
            fi
        fi
    done
    # Emit summary if any deletions occurred
    log_info "Run log pruning: removed_total = $removed age = $removed_age count = $removed_count examined = $examined"
}

# === Helper Function ===
# Prune history/state growth files by age and line count (first column date YYYY-MM-DD)
prune_history_files() {
    (( HISTORY_PRUNE_ENABLED == 1 )) || return 0
    local max_days=${HISTORY_MAX_DAYS:-0} max_lines=${HISTORY_MAX_LINES:-0}
    local cutoff="" today
    today=$(date '+%Y-%m-%d')
    if (( max_days > 0 )); then cutoff=$(date -d "-${max_days} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d'); fi
    local files=(
        "$CAPACITY_HISTORY_FILE" "$DISK_CAP_HISTORY_FILE" "$SHARE_USAGE_HISTORY_FILE" "$HEAVY_WRITER_HISTORY_FILE" "$RISK_TIER_HISTORY_FILE" "$IO_ERROR_HISTORY_FILE" "$BTRFS_DEV_HIST_FILE" "$XFS_PROC_HISTORY_FILE" "$XFS_PROC_PREV_FILE" "$POH_HISTORY_FILE" "$TBW_DAYSLEFT_HISTORY_FILE" "$SMART_ATTR_HISTORY_FILE" "$RISK_SCORES_HISTORY_FILE" "$TEMP_HISTORY_FILE" "$TBW_HISTORY_FILE" "$SELFTEST_HISTORY_FILE" "$SATA_LINK_HISTORY_FILE"
    )
    local f
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        local tmp
        tmp=$(mktemp) || continue
        # Age prune: keep lines whose first field (date) >= cutoff if cutoff set else all
        if (( max_days > 0 )); then
            awk -v c="$cutoff" 'BEGIN{FS="[ \t]"} $1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ { if($1>=c) print; next } { print }' "$f" > "$tmp" 2>/dev/null || true
        else
            cat "$f" > "$tmp" 2>/dev/null || true
        fi
        mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" || true
        # Line count prune: retain last max_lines
        if (( max_lines > 0 )); then
            local lc
            lc=$(wc -l < "$f" 2>/dev/null || echo 0)
            if (( lc > max_lines )); then
                tmp=$(mktemp) || continue
                tail -n "$max_lines" "$f" > "$tmp" 2>/dev/null || true
                mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" || true
            fi
        fi
    done
}
prune_history_files

# === Helper Function ===
# Apply owner/permissions directly to all logs and persistent files.
enforce_state_tree_perms() {
    local f
    local count_files=0
    local count_dirs=0
    local count_logs=0
    for f in "${STATE_FILES_ALERT_RUNTIME[@]}" "${STATE_FILES_TREND_HISTORY[@]}" "$STORAGE_DISCREPANCY_STATE_FILE"; do
        [[ -e "$f" ]] || continue
        chmod 0664 "$f" 2>/dev/null || true
        chown nobody "$f" 2>/dev/null || true
        ((count_files++)) || true
    done
    # State subdirectories contents
    local d
    for d in "$SMART_SELFTEST_DIR" "$UNSAFE_SDWN_STATE_DIR" "$BTRFS_SCRUB_STATE_DIR" "$CMD_TIMEOUT_STATE_DIR"; do
        [[ -d "$d" ]] || continue
        ((count_dirs++)) || true
        while IFS= read -r sf; do
            chmod 0664 "$sf" 2>/dev/null || true
            chown nobody "$sf" 2>/dev/null || true
            ((count_files++)) || true
        done < <(find "$d" -type f 2>/dev/null)
    done
    # Logs: master log and any .log in LOG_DIR
    if [[ -n "$LOG_DIR" ]]; then        
        chmod 0775 "$LOG_DIR" 2>/dev/null || true
        chown nobody "$LOG_DIR" 2>/dev/null || true
        ((count_dirs++)) || true
    fi
    if [[ -n "$MASTER_LOG" ]]; then
        # Ensure master log exists and apply permissions
        touch "$MASTER_LOG" 2>/dev/null || true
        chmod 0664 "$MASTER_LOG" 2>/dev/null || true
        chown nobody "$MASTER_LOG" 2>/dev/null || true
        ((count_logs++)) || true
    fi
    if [[ -d "$LOG_DIR" ]]; then
        while IFS= read -r lf; do
            chmod 0664 "$lf" 2>/dev/null || true
            chown nobody "$lf" 2>/dev/null || true
            ((count_logs++)) || true
        done < <(find "$LOG_DIR" -type f -name '*.log' 2>/dev/null)
    fi
    log_info "Permissions sweep: files=$count_files dirs=$count_dirs logs=$count_logs"
}

# === Helper Functions ===
# Caching wrappers for external commands to minimize repeated calls
declare LSBLK_ALL_CACHE=""
declare -A BTRFS_DF_CACHE_DATA BTRFS_DF_CACHE_META SMART_SELFTEST_RAW SMART_CAP_RAW
cache_lsblk_all() {
    if [[ -z "$LSBLK_ALL_CACHE" ]]; then
        LSBLK_ALL_CACHE="$(lsblk -b -dn -o NAME,SIZE,ROTA 2>/dev/null || true)"
    fi
}
lsblk_size_cached() { cache_lsblk_all; local dev="$1"; awk -v d="${dev##*/}" '$1==d{print $2; exit}' <<<"$LSBLK_ALL_CACHE"; }
lsblk_rota_cached() { cache_lsblk_all; local dev="$1"; awk -v d="${dev##*/}" '$1==d{print $3; exit}' <<<"$LSBLK_ALL_CACHE"; }
smartctl_cached() {
    # Generic smartctl output caching keyed by full argument string
    local key
    key=$(printf "%s" "$*" | tr ' /' '__')
    local f="/tmp/health_smart_cache_$key.txt"
    if [[ ! -f "$f" ]]; then smartctl "$@" >"$f" 2>&1 || true; fi
    cat "$f"
}
get_selftest_cached() {
    local disk="$1"; local key="$disk"; if [[ -n "${SMART_SELFTEST_RAW[$key]:-}" ]]; then printf "%s" "${SMART_SELFTEST_RAW[$key]}"; return; fi
    if [[ ! "$disk" =~ ^/dev/[A-Za-z0-9]+([p0-9]+)?$ ]]; then printf ""; return; fi
    if [[ $disk == /dev/nvme* ]]; then SMART_SELFTEST_RAW[$key]="$(smartctl_cached -l selftest -d nvme "$disk")"; else SMART_SELFTEST_RAW[$key]="$(smartctl_cached -l selftest "$disk")"; fi
    printf "%s" "${SMART_SELFTEST_RAW[$key]}"
}
get_capabilities_cached() {
    local disk="$1"; local key="$disk"; if [[ -n "${SMART_CAP_RAW[$key]:-}" ]]; then printf "%s" "${SMART_CAP_RAW[$key]}"; return; fi
    if [[ ! "$disk" =~ ^/dev/[A-Za-z0-9]+([p0-9]+)?$ ]]; then printf ""; return; fi
    if [[ $disk == /dev/nvme* ]]; then SMART_CAP_RAW[$key]="$(smartctl_cached -c -d nvme "$disk")"; else SMART_CAP_RAW[$key]="$(smartctl_cached -c "$disk")"; fi
    printf "%s" "${SMART_CAP_RAW[$key]}"
}
btrfs_df_cached() {
    # Cache raw 'btrfs filesystem df' (pretty first, fallback) per mount
    local m="$1"; local key="$m"; if [[ -n "${BTRFS_DF_CACHE_DATA[$key]:-}" || -n "${BTRFS_DF_CACHE_META[$key]:-}" ]]; then return 0; fi
    local out_p out
    out_p=$(btrfs filesystem df -p "$m" 2>/dev/null || true)
    if [[ -n "$out_p" ]]; then out="$out_p"; else out=$(btrfs filesystem df "$m" 2>/dev/null || true); fi
    BTRFS_DF_CACHE_DATA[$key]=$(printf "%s" "$out" | awk -F',' '/Data/ {gsub(/ /,"",$2); print $2; exit}')
    BTRFS_DF_CACHE_META[$key]=$(printf "%s" "$out" | awk -F',' '/Metadata/ {gsub(/ /,"",$2); print $2; exit}')
    BTRFS_DF_CACHE_DATA[$key]="${BTRFS_DF_CACHE_DATA[$key]:-UNKNOWN}"; BTRFS_DF_CACHE_META[$key]="${BTRFS_DF_CACHE_META[$key]:-UNKNOWN}"
}

# === Helper Function ===
# Send a notification through Unraid's notify script with severity
notify_unraid() {
    local title="$1"; shift
    local body="$1"; shift
    local sev="${1:-warning}"
    # Map severity to icon
    local icon="normal"
    case "$sev" in
        critical|CRITICAL) icon="alert" ;;
        warning|WARNING) icon="warning" ;;
        *) icon="normal" ;;
    esac
    local crit_count=${#ALERT_CRIT[@]}
    local warn_count=${#ALERT_WARN[@]}
    local sev_word
    case "$sev" in
        critical|CRITICAL) sev_word="CRITICAL";;
        warning|WARNING) sev_word="WARNING";;
        *) sev_word="OK";;
    esac
    # Extract per-subsystem states from summary lines
    local sm_state bt_state xfs_state cap_state pm_state pr_state
    sm_state=$(echo "${SUBSYSTEM_LINES:-}" | awk -F': ' '/^SMART:/ {print $2; exit}')
    bt_state=$(echo "${SUBSYSTEM_LINES:-}" | awk -F': ' '/^Btrfs:/ {print $2; exit}')
    xfs_state=$(echo "${SUBSYSTEM_LINES:-}" | sed -n 's/^XFS:[ \t]*\(.*\)$/\1/p' | head -n1)
    cap_state=$(echo "${SUBSYSTEM_LINES:-}" | awk -F': ' '/^Capacity:/ {print $2; exit}')
    pr_state=$(echo "${SUBSYSTEM_LINES:-}" | awk -F': ' '/^Parity:/ {print $2; exit}')
    pm_state=$(echo "${SUBSYSTEM_LINES:-}" | awk -F': ' '/^Per-Mount:/ {print $2; exit}')
    # Build filtered summary string
    local parts=()
    add_if() { local k="$1" v="$2"; [[ -z "$v" ]] && return; if [[ "$v" == "Disabled" && ${SHOW_DISABLED_SUBSYSTEMS:-0} -eq 0 ]]; then return; fi; if [[ ${SHOW_OK_SUBSYSTEMS:-0} -eq 0 && "$v" == "OK" ]]; then return; fi; if [[ "$v" == "N/A" ]]; then return; fi; parts+=("$k $v"); }
    add_if SMART "$sm_state"; add_if Btrfs "$bt_state"; add_if XFS "$xfs_state"; add_if Capacity "$cap_state"; add_if Parity "$pr_state"; add_if Per-Mount "$pm_state"
    local summary_line=""
    if (( ${#parts[@]} > 0 )); then
        summary_line=$(IFS=' | '; echo "${parts[*]}")
    else
        summary_line="All subsystems nominal"
    fi
    # Normalize body for cleaner presentation (collapse multiple blank lines)
    local body_norm
    body_norm=$(printf "%s\n" "$body" | awk '{sub(/[ \t]+$/, "")} NF{print; blank=0; next} !blank{print ""; blank=1}')
    local BIN="/usr/local/emhttp/webGui/scripts/notify"
    local rc=0
    if [ -x "$BIN" ]; then
        log_info "Sending notification with $icon title '$title'"
        "$BIN" -s "${title:-Disks Health Monitoring}" -d "$summary_line" -m "$body_norm" -i "$icon" || rc=$?
        (( rc != 0 )) && log_warn "Sending notification FAILED - returned non-zero exit $rc; continuing"
    else
        # Syslog fallback when notify binary missing
        log_warn "Sending notification FAILED - notify binary missing, using syslog fallback"
        logger -t "Disks Health Monitoring" "${title:-Disks Health Monitoring}: $summary_line"
        logger -t "Disks Health Monitoring" "$body_norm"
    fi
    return 0
}

# === Helper Function ===
# Record structured alerts and accumulate for notification severity
record_alert() {
    local sev="$1"; shift
    local title="$1"; shift
    local body="$1"; shift
    if [[ "$sev" =~ ^(critical|CRITICAL)$ ]]; then
        ALERT_CRIT+=("$title: $body")
        log_crit "$title - $body"
    else
        ALERT_WARN+=("$title: $body")
        log_warn "$title - $body"
    fi
    # Risk spike capture (store epoch timestamp per device for dynamic long test recommendation)
    if [[ "$sev" =~ ^(critical|CRITICAL|warning)$ ]]; then
        # Attempt to extract a device path from body (formats: 'Disk /dev/sdX', 'Disk /dev/nvme0n1')
        local dev_match
        dev_match=$(printf '%s' "$body" | grep -Eo '/dev/[A-Za-z0-9]+' | head -n1 || true)
        if [[ -n "$dev_match" ]]; then
            RISK_SPIKE_TS["$dev_match"]="$(date +%s)"
        fi
    fi
}

# === Helper Function ===
# Convert bytes to human readable units
human_readable() {
    local bytes=${1:-0}
    local KB=1000; local MB=$((KB*KB)); local GB=$((MB*KB)); local TB=$((GB*KB))
    if (( bytes < KB )); then printf "%d B" "$bytes"; return; fi
    if (( bytes < MB )); then awk -v b="$bytes" -v k="$KB" 'BEGIN{printf "%.2f KB", b/k}'; return; fi
    if (( bytes < GB )); then awk -v b="$bytes" -v m="$MB" 'BEGIN{printf "%.2f MB", b/m}'; return; fi
    if (( bytes < TB )); then awk -v b="$bytes" -v g="$GB" 'BEGIN{printf "%.2f GB", b/g}'; return; fi
    awk -v b="$bytes" -v t="$TB" 'BEGIN{printf "%.2f TB", b/t}'
}

# === Helper Function ===
# Normalize partition path to its base device (e.g., /dev/sda1 -> /dev/sda)
base_device() {
    local d="$1"
    if [[ ! "$d" =~ ^/dev/[A-Za-z0-9]+([p0-9]+)?$ ]]; then
        echo ""; return 0
    fi
    if [[ "$d" == /dev/nvme* ]]; then
        echo "$d" | sed -E 's/p[0-9]+$//'
    else
        echo "$d" | sed -E 's/[0-9]+$//'
    fi
}

# === Helper Function ===
# Return device model string using smartctl (cached when possible)
get_device_model() {
    local d
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "" && return 0
    if [[ -n "${MODEL_CACHE[$d]:-}" ]]; then
        echo "${MODEL_CACHE[$d]}"; return 0
    fi
    if [[ "$d" == /dev/nvme* ]]; then
        MODEL_CACHE[$d]=$(smartctl_cached -i -d nvme "$d" 2>/dev/null | awk -F: '/Model Number/ {sub(/^ +/,"",$2); print $2; exit}')
    else
        MODEL_CACHE[$d]=$(smartctl_cached -i "$d" 2>/dev/null | awk -F: '/Device Model|Model Family/ {sub(/^ +/,"",$2); print $2; exit}')
    fi
    echo "${MODEL_CACHE[$d]}"
}

# === Helper Function ===
# Build optional model suffix for health alerts depending on toggle
model_suffix_for() {
    local dev="$1"
    local suffix=""
    if (( ${ENABLE_MODEL_IN_ALERTS:-0} == 1 )) && [[ -n "$dev" ]]; then
        local mdl
        mdl="$(get_device_model "$dev" 2>/dev/null)"
        if [[ -n "$mdl" ]]; then suffix=" (Model: $mdl)"; fi
    fi
    printf "%s" "$suffix"
}

# === Helper Function ===
# Return device capacity in TB (decimal TB)
get_device_capacity_tb() {
    local d
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "0" && return 0
    if [[ -n "${CAPACITY_CACHE[$d]:-}" ]]; then
        echo "${CAPACITY_CACHE[$d]}"; return 0
    fi
    local bytes
    bytes=$(lsblk_size_cached "$d")
    bytes=${bytes:-0}
    CAPACITY_CACHE[$d]=$(awk -v b="$bytes" 'BEGIN{printf "%.3f", b/1000000000000.0}')
    echo "${CAPACITY_CACHE[$d]}"
}

# === Helper Function ===
# Read a SATA SMART raw attribute value by ID
get_sata_raw() {
    local d
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "" && return 0
    if [[ -n "${SMART_RAW[$d]:-}" ]]; then
        echo "${SMART_RAW[$d]}"; return 0
    fi
    SMART_RAW[$d]=$(smartctl_cached -A "$d" 2>/dev/null || true)
    echo "${SMART_RAW[$d]}"
}

# === Helper Function ===
# Parse SATA device basic info from smartctl --info
get_sata_info() {
    local d
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "" && return 0
    if [[ -n "${SMART_INFO[$d]:-}" ]]; then
        echo "${SMART_INFO[$d]}"; return 0
    fi
    SMART_INFO[$d]=$(smartctl_cached -i "$d" 2>/dev/null || true)
    echo "${SMART_INFO[$d]}"
}

# === Helper Function ===
# Read an NVMe SMART/health value by key
get_nvme_raw() {
    local d
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "" && return 0
    if [[ -n "${NVME_RAW[$d]:-}" ]]; then
        echo "${NVME_RAW[$d]}"; return 0
    fi
    log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART attribute read (-a) on $d"
    NVME_RAW[$d]=$(smartctl_cached -a -d nvme "$d" 2>/dev/null || true)
    echo "${NVME_RAW[$d]}"
}

# === Helper Function ===
# Read extended NVMe statistics (device statistics & thermal/PCIe counters)
get_nvme_extended_raw() {
    local d
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "" && return 0
    if [[ -n "${NVME_EXT_RAW[$d]:-}" ]]; then
        echo "${NVME_EXT_RAW[$d]}"; return 0
    fi
    log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe extended statistics read (-x) on $d"
    NVME_EXT_RAW[$d]=$(smartctl_cached -x -d nvme "$d" 2>/dev/null || true)
    echo "${NVME_EXT_RAW[$d]}"
}

# === Helper Function ===
# Lookup or estimate TBW endurance threshold for a device
tbw_threshold_tb_for_device() {
    # Map model hints to endurance (TB written per TB capacity); return empty if unknown
    local model="$1"; shift
    local cap="$1"; shift
    local per_tb=""
    # Evaluate configured TBW rules first
    if [[ -n "${TBW_MODEL_RULES:-}" ]]; then
        while IFS= read -r __rline; do
            [[ -z "$__rline" || "$__rline" =~ ^# ]] && continue
            local _regex="" _per="" _min="" _max=""
            IFS=';' read -r -a __parts <<< "$__rline"
            for __p in "${__parts[@]}"; do
                case "$__p" in
                    regex:*) _regex="${__p#regex:}" ;;
                    per_tb:*) _per="${__p#per_tb:}" ;;
                    cap_min:*) _min="${__p#cap_min:}" ;;
                    cap_max:*) _max="${__p#cap_max:}" ;;
                esac
            done
            [[ -z "$_regex" || -z "$_per" ]] && continue
            if echo "$model" | grep -qiE "$_regex"; then
                local _cap_ok=1
                if [[ -n "$_min" || -n "$_max" ]]; then
                    _cap_ok=0
                    if awk -v c="$cap" -v a="${_min:-0}" -v b="${_max:-9999}" 'BEGIN{exit !(c+0>=a+0 && c+0<=b+0)}'; then _cap_ok=1; fi
                fi
                if (( _cap_ok == 1 )); then per_tb="$_per"; break; fi
            fi
        done <<< "${TBW_MODEL_RULES}"
    fi
    [[ -z "$per_tb" ]] && { echo ""; return 0; }
    awk -v c="$cap" -v p="$per_tb" 'BEGIN{printf "%.0f", c*p}'
}

# === Helper Function ===
# Evaluate TBW thresholds and return updated state and messages
eval_tbw_state() {
    local disk="$1"; shift
    local tbw_bytes="$1"; shift
    local in_state="${1:-}"; shift || true
    local out_state="$in_state"
    local model cap tbw_thresh consumed_pct
    model=$(get_device_model "$disk")
    cap=$(get_device_capacity_tb "$disk")
    tbw_thresh=$(tbw_threshold_tb_for_device "$model" "$cap")
    local TB=$((1000*1000*1000*1000))
    if [[ -n "$tbw_thresh" && "$tbw_thresh" =~ ^[0-9]+$ ]]; then
        if [[ "$cap" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            consumed_pct=$(awk -v w="$tbw_bytes" -v th="$tbw_thresh" 'BEGIN{printf "%.0f", (w/(th*1000*1000*1000*1000))*100}')
        fi
        if [[ -n "$consumed_pct" && "$consumed_pct" =~ ^[0-9]+$ ]]; then
            if (( consumed_pct >= TBW_CONSUMED_CRIT )); then
                out_state="CRITICAL"
                printf "%s\n" "$out_state"
                printf "%s\n" "TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_CRIT}%"
                record_alert critical "TBW Consumed" "Disk $disk TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_CRIT}%"
                return 0
            elif (( consumed_pct >= TBW_CONSUMED_WARN )) && [[ $out_state != CRITICAL ]]; then
                [[ $out_state == OK ]] && out_state="WARNING"
                printf "%s\n" "$out_state"
                printf "%s\n" "TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_WARN}%"
                record_alert warning "TBW Consumed" "Disk $disk TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_WARN}%"
                return 0
            fi
        fi
        printf "%s\n" "$out_state"
        return 0
    elif [[ $TBW_WARN_TB -gt 0 ]]; then
        if (( tbw_bytes >= TBW_WARN_TB * TB )) && [[ $out_state != CRITICAL ]]; then
            [[ $out_state == OK ]] && out_state="WARNING"
            printf "%s\n" "$out_state"
            printf "%s\n" "TBW exceeds ${TBW_WARN_TB} TB"
            record_alert warning "TBW Exceeds" "Disk $disk TBW exceeds ${TBW_WARN_TB} TB (bytes=$tbw_bytes)"
            return 0
        fi
        printf "%s\n" "$out_state"
        return 0
    fi
    printf "%s\n" "$out_state"
}

# === Helper Function ===
# Derive power-on-hours warning/critical thresholds adjusted for device class & model hints
poh_thresholds_for_device() {
    local dev="$1"; shift
    local dtype="$1"; shift # nvme|sata
    local rota="${1:-}"    # for sata: 1=HDD, 0=SSD
    local model
    model=$(get_device_model "$dev")
    local warn=0 crit=0
    if [[ "$dtype" == "nvme" ]]; then
        warn=$NVME_POH_WARN_HOURS; crit=$NVME_POH_CRIT_HOURS
    else
        if [[ "$rota" == "1" ]]; then
            warn=$HDD_POH_WARN_HOURS; crit=$HDD_POH_CRIT_HOURS
        else
            warn=$SSD_POH_WARN_HOURS; crit=$SSD_POH_CRIT_HOURS
        fi
    fi
    # Apply configuration-driven overrides
    if [[ -n "${POH_MODEL_RULES:-}" ]]; then
        local cap; cap=$(get_device_capacity_tb "$dev")
        while IFS= read -r __rline; do
            [[ -z "$__rline" || "$__rline" =~ ^# ]] && continue
            local _type="" _regex="" _warn="" _crit="" _min="" _max=""
            IFS=';' read -r -a __parts <<< "$__rline"
            for __p in "${__parts[@]}"; do
                case "$__p" in
                    type:*) _type="${__p#type:}" ;;
                    regex:*) _regex="${__p#regex:}" ;;
                    warn:*) _warn="${__p#warn:}" ;;
                    crit:*) _crit="${__p#crit:}" ;;
                    cap_min:*) _min="${__p#cap_min:}" ;;
                    cap_max:*) _max="${__p#cap_max:}" ;;
                esac
            done
            [[ -z "$_type" || -z "$_regex" ]] && continue
            # Match type to current device
            local _dtype=""
            case "${dtype}:${rota}" in
                nvme:*) _dtype="nvme" ;;
                *:1) _dtype="sata-hdd" ;;
                *) _dtype="sata-ssd" ;;
            esac
            [[ "$_dtype" != "$_type" ]] && continue
            if echo "$model" | grep -qiE "$_regex"; then
                local _cap_ok=1
                if [[ -n "$_min" || -n "$_max" ]]; then
                    _cap_ok=0
                    if awk -v c="$cap" -v a="${_min:-0}" -v b="${_max:-9999}" 'BEGIN{exit !(c+0>=a+0 && c+0<=b+0)}'; then _cap_ok=1; fi
                fi
                if (( _cap_ok == 1 )); then
                    [[ -n "$_warn" ]] && warn="$_warn"
                    [[ -n "$_crit" ]] && crit="$_crit"
                    break
                fi
            fi
        done <<< "${POH_MODEL_RULES}"
    fi
    echo "$warn $crit"
}

# === Helper Function ===
# Enumerate base SATA and NVMe devices excluding boot root device
get_all_disks() {
    local sata nvme out=()
    local sata_list=()
    for d in /dev/sd?; do
        [[ -b "$d" ]] && sata_list+=("$d")
    done
    sata="${sata_list[*]}"
    nvme=$(ls /dev/nvme?n? 2>/dev/null || true)
    local boot_src boot_root=""
    boot_src=$(findmnt -n -o SOURCE /boot 2>/dev/null || true)
    if [[ -n "$boot_src" ]]; then
        if [[ "$boot_src" == /dev/nvme* ]]; then
            boot_root=$(echo "$boot_src" | sed -E 's/p[0-9]+$//')
        else
            boot_root=$(echo "$boot_src" | sed -E 's/[0-9]+$//')
        fi
    fi
    for d in $sata $nvme; do
        [[ -n "$boot_root" && "$d" == "$boot_root" ]] && continue
        out+=("$d")
    done
    echo "${out[@]}"
}

# === Helper Function ===
# Construct mapping from /mnt/diskX mountpoints to block devices using disks.ini / disk.cfg definitions
build_mount_device_map() {
    MOUNT_TO_DEV=()
    local ini="/var/local/emhttp/disks.ini" cfg="/boot/config/disk.cfg" src=""
    if [[ -f "$ini" ]]; then src="$ini"; elif [[ -f "$cfg" ]]; then src="$cfg"; else return 0; fi
    # First pass: device fields
    while IFS=$'\t' read -r name dev; do
        [[ -z "$name" || -z "$dev" ]] && continue
        case "$name" in disk[0-9]*) MOUNT_TO_DEV["/mnt/$name"]="/dev/$dev";; esac
    done < <(awk -F= 'BEGIN{disk=""}
        /^\[disk[0-9]+\]/ {disk=$0; gsub(/^\[/, "", disk); gsub(/\]$/, "", disk); next}
        tolower($1)=="device" && disk!="" {val=$2; gsub(/"/, "", val); sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val); printf "%s\t%s\n", disk, val}' "$src" 2>/dev/null)
    # Second pass: id fields (by-id symlink resolution) filling missing entries
    while IFS=$'\t' read -r name idv; do
        [[ -z "$name" || -z "$idv" ]] && continue
        local mp="/mnt/$name"
        [[ -n "${MOUNT_TO_DEV[$mp]:-}" ]] && continue
        local resolved
        resolved=$(readlink -f "/dev/disk/by-id/$idv" 2>/dev/null || true)
        [[ -b "$resolved" ]] && MOUNT_TO_DEV["$mp"]="$resolved"
    done < <(awk -F= 'BEGIN{disk=""}
        /^\[disk[0-9]+\]/ {disk=$0; gsub(/^\[/, "", disk); gsub(/\]$/, "", disk); next}
        tolower($1)=="id" && disk!="" {val=$2; gsub(/"/, "", val); sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val); printf "%s\t%s\n", disk, val}' "$src" 2>/dev/null)
}

# === Helper Function ===
# Populate global parity progress/validity variables from var.ini or mdcmd status output
parity_state() {
    PARITY_VALID_FLAG=""
    PARITY_ACTION=""
    PARITY_CORR=""
    PARITY_POS=""
    PARITY_SIZE=""
    PARITY_ERRS=""
    PARITY_SPEED_K=""
    PARITY_REM=""
    # Prefer var.ini sbClean
    local ini="/var/local/emhttp/var.ini"
    if [[ -r "$ini" ]]; then
        local sb
        sb=$(awk -F= 'tolower($1)=="sbclean" {gsub(/"| |\r|\n/,"",$2); print tolower($2); exit}' "$ini" 2>/dev/null)
        case "$sb" in
            1|yes|true) PARITY_VALID_FLAG="1";;
            0|no|false) PARITY_VALID_FLAG="0";;
        esac
    fi
    # Fallback to mdcmd status
    local cmd="/usr/local/sbin/mdcmd" out
    [[ -x "$cmd" ]] || cmd="mdcmd"
    if command -v "$cmd" >/dev/null 2>&1; then
        out=$("$cmd" status 2>/dev/null | tr -d '\r') || out=""
        if [[ -n "$out" ]]; then
            local sb st act corr pos size errs spk rem
            sb=$(echo "$out" | awk -F= 'tolower($1)=="sbclean" {print tolower($2); exit}')
            st=$(echo "$out" | awk -F= 'tolower($1)=="mdstate" {print tolower($2); exit}')
            act=$(echo "$out" | awk -F= 'tolower($1)=="mdresyncaction" {print tolower($2); exit}')
            corr=$(echo "$out"| awk -F= 'tolower($1)=="mdresynccorr" {print $2; exit}')
            pos=$(echo "$out" | awk -F= 'tolower($1)=="mdresyncpos" {print $2; exit}')
            size=$(echo "$out"| awk -F= 'tolower($1)=="mdresyncsize" {print $2; exit}')
            errs=$(echo "$out"| awk -F= 'tolower($1)=="mdsyncerrs" {print $2; exit}')
            spk=$(echo "$out" | awk -F= 'tolower($1)=="mdresyncspeed" {print $2; exit}')
            rem=$(echo "$out" | awk -F= 'tolower($1)=="mdresyncrem" {print $2; exit}')
            if [[ -n "$sb" ]]; then
                case "$sb" in 1|yes|true) PARITY_VALID_FLAG="1";; 0|no|false) PARITY_VALID_FLAG="0";; esac
            else
                # Derive validity without sbclean: treat as active only if metrics indicate progress
                local _act_lc _is_active=0
                _act_lc=$(printf "%s" "$act" | awk '{print tolower($1)}')
                if [[ -n "$_act_lc" && "$_act_lc" != "idle" ]]; then
                    if [[ -n "$spk" && "$spk" =~ ^[0-9]+$ && $((10#$spk)) -gt 0 ]]; then _is_active=1
                    elif [[ -n "$rem" && "$rem" =~ ^[0-9]+$ && $((10#$rem)) -gt 0 ]]; then _is_active=1
                    elif [[ -n "$pos" && -n "$size" && "$pos" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ && $((10#$pos)) -gt 0 && $((10#$pos)) -lt $((10#$size)) ]]; then _is_active=1
                    fi
                fi
                if (( _is_active == 1 )); then
                    PARITY_VALID_FLAG="0"
                else
                    local _errs_ok=""
                    if [[ -n "$errs" && "$errs" =~ ^[0-9]+$ && $((10#$errs)) -eq 0 ]]; then _errs_ok=1; fi
                    local _completed=""
                    if [[ -n "$pos" && -n "$size" && "$pos" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ && $((10#$pos)) -eq $((10#$size)) ]]; then _completed=1; fi
                    if [[ "$st" == "started" || -n "$_errs_ok" || -n "$_completed" ]]; then
                        PARITY_VALID_FLAG="1"
                    else
                        PARITY_VALID_FLAG=""
                    fi
                fi
            fi
            PARITY_ACTION="$act"
            PARITY_CORR="$corr"
            PARITY_POS="$pos"
            PARITY_SIZE="$size"
            PARITY_ERRS="$errs"
            PARITY_SPEED_K="$spk"
            PARITY_REM="$rem"
            return 0
        fi
    fi
    return 1
}

# === Helper Function ===
# Return cached / resolved parity validity flag (1 clean, 0 invalid, empty unknown)
parity_clean_flag() {
    parity_state || true
    if [[ -n "${PARITY_VALID_FLAG:-}" ]]; then echo "${PARITY_VALID_FLAG}"; return 0; fi
    echo ""; return 1
}

# === Main Function ===
# Discover and summarize parity devices and current parity operation status.
discover_parity_and_status() {
    # Init output containers (status line, detail section)
    PARITY_STATUS_LINE=""
    PARITY_DETAILS_SECTION=""

    # Source metadata file used by Unraid for disk assignments
    local ini="/var/local/emhttp/disks.ini"
    local -a parity_labels=()
    local -a parity_devs=()

    # Parse disks.ini to identify parity entries and resolve device paths/by-id
    if [[ -f "$ini" ]]; then
        while IFS=$'\t' read -r sec dev idv; do
            [[ -z "$sec" ]] && continue 
            case "$sec" in
                parity|parity2|parity[0-9]*) # Match any parity slot
                    local resolved=""
                    if [[ -n "$dev" ]]; then        # Direct device assignment
                        resolved="/dev/$dev"
                    elif [[ -n "$idv" ]]; then      # Fallback by-id resolution
                        resolved=$(readlink -f "/dev/disk/by-id/$idv" 2>/dev/null || true)
                    fi
                    if [[ -n "$resolved" ]]; then   # Accumulate label + resolved device
                        parity_labels+=("$sec")
                        parity_devs+=("$resolved")
                    fi
                    ;;
            esac
        done < <(awk -F= '
            BEGIN{sec=""; dev=""; idv=""}
            /^\[(parity|parity2|parity[0-9]+)\]/ {
                if (sec!="") { printf "%s\t%s\t%s\n", sec, dev, idv }
                sec=$0; gsub(/^[\[]|[\]]$/, "", sec); dev=""; idv=""; next
            }
            tolower($1)=="device" && sec!="" {val=$2; gsub(/"/, "", val); sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val); dev=val; next}
            tolower($1)=="id" && sec!="" {val=$2; gsub(/"/, "", val); sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val); idv=val; next}
            END{ if (sec!="") { printf "%s\t%s\t%s\n", sec, dev, idv } }
        ' "$ini" 2>/dev/null)
    fi

    # Build labels string for parity devices (if any found)
    local labels_join=""
    if (( ${#parity_labels[@]} > 0 )); then
        labels_join=$(IFS=","; echo "${parity_labels[*]}")
        labels_join=${labels_join//,/, }
    fi

    # Populate parity operation state variables (validity, action, progress) via parity_state
    parity_state || true
    local clean_flag="${PARITY_VALID_FLAG:-}" 
    PARITY_CLEAN_FLAG="$clean_flag"

    # Derive high-level status line based on validity flag and active operation
    local is_active=0
    if [[ -n "$clean_flag" ]]; then
        local _act_lc="${PARITY_ACTION:-}"
        _act_lc=$(printf "%s" "$_act_lc" | awk '{print tolower($1)}')
        # Determine true activity: action non-idle AND (pos<size OR rem>0 OR speed>0)
        local _pos="${PARITY_POS:-}" _size="${PARITY_SIZE:-}" _rem="${PARITY_REM:-}" _spk="${PARITY_SPEED_K:-}"
        if [[ -n "$_act_lc" && "$_act_lc" != "idle" ]]; then
            if [[ "$_spk" =~ ^[0-9]+$ && $((10#$_spk)) -gt 0 ]]; then is_active=1
            elif [[ "$_rem" =~ ^[0-9]+$ && $((10#$_rem)) -gt 0 ]]; then is_active=1
            elif [[ "$_pos" =~ ^[0-9]+$ && "$_size" =~ ^[0-9]+$ && $((10#$_pos)) -gt 0 && $((10#$_pos)) -lt $((10#$_size)) ]]; then is_active=1
            fi
        fi
        if (( is_active == 1 )); then
            PARITY_STATUS_LINE=$([[ -n "$labels_join" ]] && echo "Parity ($labels_join):" || echo "Parity:")
        elif [[ "$clean_flag" == "1" ]]; then
            PARITY_STATUS_LINE=$([[ -n "$labels_join" ]] && echo "Parity ($labels_join): Valid" || echo "Parity: Valid")
        else
            PARITY_STATUS_LINE=$([[ -n "$labels_join" ]] && echo "Parity ($labels_join): Invalid (sync required)" || echo "Parity: Invalid (sync required)")
            record_alert warning "Parity Status" "Parity invalid (sync required)"
        fi
    else
        PARITY_STATUS_LINE="Parity: Unknown"
    fi

    # Append operation details if a parity operation is active (including paused)
    local action="${PARITY_ACTION:-}" corr="${PARITY_CORR:-}" pos="${PARITY_POS:-}" size="${PARITY_SIZE:-}" errs="${PARITY_ERRS:-}" speed_k="${PARITY_SPEED_K:-}" rem="${PARITY_REM:-}"
    local action_word="" corr_label="" pct="" eta_str="" paused=""
    [[ -n "$action" ]] && action_word=$(printf "%s" "$action" | awk '{print tolower($1)}')
    corr_label=$([[ "$corr" == "1" ]] && echo "correcting" || echo "non-correcting")
    # Compute in-progress percentage if position/size known
    if [[ -n "$pos" && -n "$size" ]]; then
        pct=$(awk -v p="$pos" -v s="$size" 'BEGIN{ if (s>0) printf "%.1f", (p/s)*100; }')
    fi
    # Consider paused if action is active but reported speed is 0 and pos<size
    if (( is_active == 1 )); then
        if [[ -n "$speed_k" && "$speed_k" =~ ^[0-9]+$ && "$speed_k" -eq 0 && -n "$pos" && -n "$size" && "$size" =~ ^[0-9]+$ && "$pos" =~ ^[0-9]+$ && $pos -lt $size ]]; then
            paused=" (paused)"
        fi
        PARITY_STATUS_LINE+=" ${action_word} in progress${paused} (${corr_label})"
        [[ -n "$pct" ]] && PARITY_STATUS_LINE+=", ~${pct}%"
        PARITY_DETAILS_SECTION="Parity Details:\n"
        PARITY_DETAILS_SECTION+=" - Action: ${action_word}${paused} (${corr_label})\n"
        # Progress line with optional percent
        if [[ -n "$pos" && -n "$size" ]]; then
            PARITY_DETAILS_SECTION+=" - Progress: ${pos} / ${size}"
            [[ -n "$pct" ]] && PARITY_DETAILS_SECTION+=" (~${pct}%)"
            PARITY_DETAILS_SECTION+="\n"
        fi
        # Load previous progress snapshot to compute delta speed/ETA
        local progress_file prev_pos prev_ts curr_ts
        progress_file="$STATE_DIR/parity_progress.state"
        prev_pos=""
        prev_ts=""
        curr_ts=$(date +%s)
        if [[ -f "$progress_file" ]]; then read -r prev_pos prev_ts < "$progress_file" || true; fi
        # If previous snapshot valid, compute instantaneous MB/s and ETA
        if [[ -n "$pos" && -n "$prev_pos" && -n "$prev_ts" && "$pos" =~ ^[0-9]+$ && "$prev_pos" =~ ^[0-9]+$ && "$prev_ts" =~ ^[0-9]+$ && $pos -ge $prev_pos ]]; then
            local dt=$(( curr_ts - prev_ts ))
            if (( dt > 0 )); then
                local delta=$(( pos - prev_pos ))
                local bytes=$(( delta * 512 ))
                local mbps
                mbps=$(awk -v b="$bytes" -v d="$dt" 'BEGIN{ if(d>0) printf "%.2f", (b/1048576)/d; }')
                if [[ -n "$mbps" && -n "$size" && "$size" =~ ^[0-9]+$ ]]; then
                    local remaining=$(( size - pos ))
                    if (( remaining > 0 )); then
                        local rem_bytes=$(( remaining * 512 ))
                        local eta_sec
                        eta_sec=$(awk -v rb="$rem_bytes" -v mbps="$mbps" 'BEGIN{ mb=mbps*1048576; if(mb>0) printf "%d", rb/mb; }')
                        if [[ -n "$eta_sec" && "$eta_sec" =~ ^[0-9]+$ ]]; then
                            local eta_h=$(( eta_sec/3600 )) eta_m=$(( (eta_sec%3600)/60 )) eta_s=$(( eta_sec%60 ))
                            if (( eta_h>0 )); then eta_str="${eta_h}h ${eta_m}m"; elif (( eta_m>0 )); then eta_str="${eta_m}m ${eta_s}s"; else eta_str="${eta_s}s"; fi
                            PARITY_DETAILS_SECTION+=" - ETA: ${eta_str} remaining\n"
                        fi
                    fi
                fi
                PARITY_DETAILS_SECTION+=" - Speed: ${mbps} MB/s (Δ ${delta} sectors / ${dt}s)\n"
            fi
        fi
        # Append reported speed / remaining sectors / errors when provided
        if [[ -n "$speed_k" && "$speed_k" =~ ^[0-9]+$ ]]; then
            local speed_mb
            speed_mb=$(awk -v sp="$speed_k" 'BEGIN{printf "%.2f", sp/1024.0}')
            PARITY_DETAILS_SECTION+=" - Reported Speed: ${speed_mb} MB/s\n"
        fi
        if [[ -n "$rem" && "$rem" =~ ^[0-9]+$ ]]; then PARITY_DETAILS_SECTION+=" - Remaining Sectors: ${rem}\n"; fi
        if [[ -n "$errs" ]]; then PARITY_DETAILS_SECTION+=" - Errors: ${errs}\n"; fi
        # Persist current position snapshot for next run speed/ETA calculation
        if [[ -n "$pos" ]]; then echo "$pos $curr_ts" > "$progress_file" 2>/dev/null || true; fi
        # Parity sync error alerts. Use thresholds if defined.
        if [[ -n "$errs" && "$errs" =~ ^[0-9]+$ ]] && (( is_active == 1 )); then
            local perr_warn=${PARITY_SYNC_ERR_WARN:-1} perr_crit=${PARITY_SYNC_ERR_CRIT:-10}
            if (( errs >= perr_crit )); then
                record_alert critical "Parity Sync Errors" "Parity operation has ${errs} sync errors; investigate disks (SMART long tests), cabling, and consider corrective check."
            elif (( errs >= perr_warn )); then
                record_alert warning "Parity Sync Errors" "Parity operation reported ${errs} sync errors; monitor; if increasing run a correcting parity check and inspect recent SMART logs."
            fi
        fi
    fi
}

# === Helper Function ===
# Persist risk spike timestamps (prune entries older than lookback before write)
save_risk_spikes() {
    local lookback_days=${LONG_TEST_RISK_LOOKBACK_DAYS:-14}
    local now_ts; now_ts=$(date +%s)
    # Prune in-memory map
    for dev in "${!RISK_SPIKE_TS[@]}"; do
        local ts=${RISK_SPIKE_TS[$dev]:-0}
        [[ $ts =~ ^[0-9]+$ ]] || { unset 'RISK_SPIKE_TS[$dev]'; continue; }
        local age_days=$(( (now_ts - ts) / 86400 ))
        if (( age_days > lookback_days )); then unset 'RISK_SPIKE_TS[$dev]'; fi
    done
    # Write file atomically
    local tmp
    tmp=$(mktemp) || { log_warn "mktemp failed; skipping risk spike save"; return 0; }
    for dev in "${!RISK_SPIKE_TS[@]}"; do
        printf '%s %s\n' "$dev" "${RISK_SPIKE_TS[$dev]}" >> "$tmp"
    done
    mv -f "$tmp" "$RISK_SPIKE_FILE" 2>/dev/null || rm -f "$tmp" || true
}

# === Helper Function ===
# Resolve SMART-capable device for a given /mnt path
smart_device_for_mount() {
    local mp="$1"
    local dev="${MOUNT_TO_DEV[$mp]:-}"
    if [[ -n "$dev" && -b "$dev" ]]; then echo "$dev"; return 0; fi
    local src
    src=$(findmnt -n -o SOURCE "$mp" 2>/dev/null || true)
    echo "$src"
}

if [ -f "$SMART_LAST" ]; then
    while read -r disk date; do
        LAST_TEST["$disk"]=$date
    done < "$SMART_LAST"
fi

if [ -f "$NVME_STATE_FILE" ]; then
    while read -r dev rest; do
        [[ -z "$dev" ]] && continue
        # Support legacy format: dev <unsafe_shutdowns>
        if [[ -z "$rest" ]]; then
            continue
        fi
        # Tokenize key=value pairs after the device name
        # Legacy single number (unsafe) support
        if [[ "$rest" =~ ^[0-9]+$ ]]; then
            NVME_LAST_UNSAFE["$dev"]="$rest"
            continue
        fi
        for token in $dev $rest; do
            # First token is device; skip
            [[ "$token" == "$dev" ]] && continue
            k=${token%%=*}
            v=${token#*=}
            [[ -z "$k" || -z "$v" ]] && continue
            case "$k" in
                unsafe) NVME_LAST_UNSAFE["$dev"]="$v";;
                errlog) NVME_LAST_ERRLOG["$dev"]="$v";;
                pc_corr) NVME_LAST_PCIE_CORR["$dev"]="$v";;
                pc_unc) NVME_LAST_PCIE_UNC["$dev"]="$v";;
                therm_t1) NVME_LAST_THERM_T1["$dev"]="$v";;
                therm_t2) NVME_LAST_THERM_T2["$dev"]="$v";;
                warn_temp_time) NVME_LAST_WARN_TEMP_TIME["$dev"]="$v";;
                crit_temp_time) NVME_LAST_CRIT_TEMP_TIME["$dev"]="$v";;
            esac
        done
    done < "$NVME_STATE_FILE"
fi

if [ -f "$PREV_ATTR_FILE" ]; then
    while read -r line; do
        [[ -z "$line" ]] && continue
        disk=""
        token=""
        disk=$(echo "$line" | awk '{print $1}')
        for token in $(echo "$line" | awk '{for(i=2;i<=NF;i++) print $i}'); do
            k=""; v=""
            k=${token%%=*}; v=${token#*=}
            [[ -n "$k" ]] && PREV_ATTR["$disk|$k"]="$v"
        done
    done < "$PREV_ATTR_FILE"
fi
if [ -f "$ALERT_NEW_SEEN_FILE" ]; then
    while IFS= read -r key; do
        [[ -n "$key" ]] && NEW_SEEN["$key"]=1
    done < "$ALERT_NEW_SEEN_FILE"
fi

# Load persisted last long self-test lifetime hours
if [ -f "$SMART_LONG_LAST_POH_FILE" ]; then
    while read -r disk poh; do
        [[ -z "$disk" || -z "$poh" ]] && continue
        [[ "$poh" =~ ^[0-9]+$ ]] || continue
        LONG_LAST_POH["$disk"]="$poh"
    done < "$SMART_LONG_LAST_POH_FILE"
fi

# Load previous Command_Timeout counts for delta alerts
if [ -f "$CMD_TIMEOUT_LAST_FILE" ]; then
    while read -r disk cnt; do
        [[ -z "$disk" || -z "$cnt" ]] && continue
        [[ "$cnt" =~ ^[0-9]+$ ]] || continue
        CMD_TIMEOUT_LAST["$disk"]="$cnt"
    done < "$CMD_TIMEOUT_LAST_FILE"
fi

# Load persisted risk spike timestamps (prune entries older than lookback)
if [ -f "$RISK_SPIKE_FILE" ]; then
    while read -r disk ts; do
        [[ -z "$disk" || -z "$ts" ]] && continue
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        # Apply lookback pruning at load time
        now_ts=$(date +%s)
        prune_days=${LONG_TEST_RISK_LOOKBACK_DAYS:-14}
        age_days=$(( (now_ts - ts) / 86400 ))
        if (( age_days <= prune_days )); then
            RISK_SPIKE_TS["$disk"]="$ts"
        fi
    done < "$RISK_SPIKE_FILE"
fi

# === Helper Function ===
# Persist last-run SMART test metadata for a device
save_last_test() {
    true > "$SMART_LAST"
    for disk in "${!LAST_TEST[@]}"; do
        echo "$disk ${LAST_TEST[$disk]}" >> "$SMART_LAST"
    done
}

# === Helper Function ===
# Persist last-run NVMe health snapshot for a device
save_nvme_state() {
    true > "$NVME_STATE_FILE"
    for dev in "${!NVME_LAST_UNSAFE[@]}"; do
        local line="$dev unsafe=${NVME_LAST_UNSAFE[$dev]:-0}"
        line+=" errlog=${NVME_LAST_ERRLOG[$dev]:-0}"
        line+=" pc_corr=${NVME_LAST_PCIE_CORR[$dev]:-0}"
        line+=" pc_unc=${NVME_LAST_PCIE_UNC[$dev]:-0}"
        line+=" therm_t1=${NVME_LAST_THERM_T1[$dev]:-0}"
        line+=" therm_t2=${NVME_LAST_THERM_T2[$dev]:-0}"
        line+=" warn_temp_time=${NVME_LAST_WARN_TEMP_TIME[$dev]:-0}"
        line+=" crit_temp_time=${NVME_LAST_CRIT_TEMP_TIME[$dev]:-0}"
        echo "$line" >> "$NVME_STATE_FILE"
    done
}

# === Helper Function ===
# Persist last observed long self-test lifetime hours per disk
save_long_last_poh() {
    true > "$SMART_LONG_LAST_POH_FILE"
    for disk in "${!LONG_LAST_POH[@]}"; do
        echo "$disk ${LONG_LAST_POH[$disk]}" >> "$SMART_LONG_LAST_POH_FILE"
    done
}

# === Helper Function ===
# Persist last observed Command_Timeout counts per disk
save_cmd_timeout_last() {
    true > "$CMD_TIMEOUT_LAST_FILE"
    for disk in "${!CMD_TIMEOUT_LAST[@]}"; do
        echo "$disk ${CMD_TIMEOUT_LAST[$disk]}" >> "$CMD_TIMEOUT_LAST_FILE"
    done
}

# === Main Function ===
# Collect SMART data, classify device health, and raise alerts
evaluate_smart() {
    local disk=$1
    local ctx=${2:-}
    local prev_state="${SMART_STATE[$disk]:-}"
    local prev_msgs="${SMART_MSGS[$disk]:-}"
    local is_nvme=0
    [[ $disk == /dev/nvme* ]] && is_nvme=1
    local state="OK"
    local messages=()
    if [[ $is_nvme -eq 1 ]]; then
        # Query raw NVMe SMART output once and parse key fields
        local nvme_output
        nvme_output=$(get_nvme_raw "$disk")
        local percent_used crit_warn nvme_temp media_errors err_logs unsafe_shutdowns avail_spare avail_spare_thr duw poh
        # Extended statistics (PCIe errors, thermal transitions, temperature time accumulation)
        local nvme_ext pcie_corr pcie_unc therm_t1 therm_t2 warn_temp_time crit_temp_time
        nvme_ext=$(get_nvme_extended_raw "$disk")
        # Parse endurance, age, warnings, error counters, and spares
        percent_used=$(echo "$nvme_output" | awk -F: '/Percentage Used/ {gsub(/%| /,"",$2); print $2; exit}')
        percent_used=${percent_used:-0}
        poh=$(echo "$nvme_output" | awk -F: '/Power On Hours/ {gsub(/ /,"",$2); print $2; exit}')
        poh=${poh:-0}
        crit_warn=$(echo "$nvme_output" | awk -F: '/Critical Warning/ {gsub(/ |\t/,"",$2); print $2; exit}')
        crit_warn=${crit_warn:-0}
        media_errors=$(echo "$nvme_output" | awk -F: '/Media and Data Integrity Errors/ {gsub(/ /,"",$2); print $2; exit}')
        media_errors=${media_errors:-0}
        err_logs=$(echo "$nvme_output" | awk -F: '/Error Information Log Entries/ {gsub(/ /,"",$2); print $2; exit}')
        err_logs=${err_logs:-0}
        unsafe_shutdowns=$(echo "$nvme_output" | awk -F: '/Unsafe Shutdowns/ {gsub(/ /,"",$2); print $2; exit}')
        unsafe_shutdowns=${unsafe_shutdowns:-0}
        avail_spare=$(echo "$nvme_output" | awk -F: '/Available Spare[^T]/ {gsub(/%| /,"",$2); print $2; exit}')
        avail_spare=${avail_spare:-}
        avail_spare_thr=$(echo "$nvme_output" | awk -F: '/Available Spare Threshold/ {gsub(/%| /,"",$2); print $2; exit}')
        avail_spare_thr=${avail_spare_thr:-}
        # Parse bytes written to estimate TBW, persist, and compare to thresholds
        duw=$(echo "$nvme_output" | awk -F: '/Data Units Written/ { if (match($2, /[0-9][0-9,]*/)) { v=substr($2,RSTART,RLENGTH); gsub(/,/, "", v); print v } else { print "" } exit }')
        # Parse extended NVMe statistics
        pcie_corr=$(echo "$nvme_ext" | awk -F: '/PCIe Correctable Error Count/ {gsub(/ /,"",$2); print $2; exit}')
        pcie_corr=${pcie_corr:-0}
        pcie_unc=$(echo "$nvme_ext" | awk -F: '/PCIe Uncorrectable Error Count/ {gsub(/ /,"",$2); print $2; exit}')
        pcie_unc=${pcie_unc:-0}
        therm_t1=$(echo "$nvme_ext" | awk -F: '/Thermal Management T1 Transitions/ {gsub(/ /,"",$2); print $2; exit}')
        therm_t1=${therm_t1:-0}
        therm_t2=$(echo "$nvme_ext" | awk -F: '/Thermal Management T2 Transitions/ {gsub(/ /,"",$2); print $2; exit}')
        therm_t2=${therm_t2:-0}
        warn_temp_time=$(echo "$nvme_ext" | awk -F: '/Warning  Comp. Temperature Time/ {gsub(/ /,"",$2); print $2; exit}')
        warn_temp_time=${warn_temp_time:-0}
        crit_temp_time=$(echo "$nvme_ext" | awk -F: '/Critical Comp. Temperature Time/ {gsub(/ /,"",$2); print $2; exit}')
        crit_temp_time=${crit_temp_time:-0}
        if [[ -n "$duw" ]]; then
            local tbw_bytes=$(( duw * 512000 ))
            local tbw_hr
            tbw_hr=$(human_readable "$tbw_bytes")
            messages+=("TBW ~ $tbw_hr")
            CUR_ATTR["$disk|tbw_bytes"]="$tbw_bytes"
            mapfile -t _tbw_eval < <(eval_tbw_state "$disk" "$tbw_bytes" "$state")
            state="${_tbw_eval[0]}"
            if (( ${#_tbw_eval[@]} > 1 )); then
                for ((i=1; i<${#_tbw_eval[@]}; i++)); do messages+=("${_tbw_eval[i]}"); done
            fi
        fi
        # Parse temperature and evaluate wear percent thresholds
        nvme_temp=$(echo "$nvme_output" | awk -F: '/Temperature/ {print $2; exit}' | grep -oE '[0-9]+' | head -n1 || true)
        if [[ -n "$nvme_temp" && "$nvme_temp" =~ ^[0-9]+$ ]]; then
            printf '%s %s temp=%s\n' "$(date '+%Y-%m-%d')" "$disk" "$nvme_temp" >> "$TEMP_HISTORY_FILE" 2>/dev/null || true
        fi
        if [[ $percent_used -ge $NVME_PERCENT_USED_CRIT ]]; then
            state="CRITICAL"; messages+=("NVMe wear ${percent_used}% >= ${NVME_PERCENT_USED_CRIT}%")
            record_alert critical "NVMe Wear" "Disk $disk NVMe wear ${percent_used}% >= ${NVME_PERCENT_USED_CRIT}%"
        elif [[ $percent_used -ge $NVME_PERCENT_USED_WARN ]]; then
            state="WARNING"; messages+=("NVMe wear ${percent_used}% >= ${NVME_PERCENT_USED_WARN}%")
            record_alert warning "NVMe Wear" "Disk $disk NVMe wear ${percent_used}% >= ${NVME_PERCENT_USED_WARN}%"
        fi
        # Decode Critical Warning bitfield and append detailed messages
        if [[ $crit_warn -ne 0 ]]; then
            state="CRITICAL"; messages+=("NVMe Critical Warning flags: $crit_warn")
            local cw_dec=""
            if [[ $crit_warn =~ ^0x[0-9A-Fa-f]+$ ]]; then
                cw_dec=$((16#${crit_warn#0x}))
            else
                cw_dec=$crit_warn
            fi
            if (( (cw_dec & 0x02) != 0 )); then
                messages+=("NVMe thermal threshold exceeded (Critical Warning bit1)")
            fi
            if (( (cw_dec & 0x01) != 0 )); then
                # Available spare below threshold (warn)
                local dup=0; for m in "${messages[@]}"; do [[ $m == *"Available Spare"* ]] && dup=1; done; (( dup==0 )) && messages+=("NVMe available spare below threshold (Critical Warning bit0)")
                [[ $state == OK ]] && state="WARNING"
            fi
            if (( (cw_dec & 0x04) != 0 )); then
                state="CRITICAL"; messages+=("NVMe reliability degraded (Critical Warning bit2)")
            fi
            if (( (cw_dec & 0x08) != 0 )); then
                state="CRITICAL"; messages+=("NVMe media in read-only mode (Critical Warning bit3)")
            fi
            if (( (cw_dec & 0x10) != 0 )); then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe volatile memory backup failed (Critical Warning bit4)")
            fi
        fi
        # Flag media/data integrity errors and low spare
        if [[ $media_errors -gt 0 ]]; then
            state="CRITICAL"; messages+=("NVMe media/data integrity errors = $media_errors")
            record_alert critical "NVMe Media Integrity" "Disk $disk NVMe media/data integrity errors = $media_errors"
        fi
        # Delta-based alerts for NVMe error log entries growth
        local prev_errlog=${NVME_LAST_ERRLOG[$disk]:-0}
        if [[ $err_logs -gt $prev_errlog ]]; then
            local delta_errlog=$((err_logs - prev_errlog))
            if (( delta_errlog >= NVME_ERR_LOG_DELTA_CRIT )); then
                state="CRITICAL"; messages+=("NVMe error log entries increased by ${delta_errlog} (${prev_errlog} -> ${err_logs})")
                record_alert critical "NVMe Error Log" "Disk $disk NVMe error log entries increased by ${delta_errlog} (${prev_errlog} -> ${err_logs})"
            elif (( delta_errlog >= NVME_ERR_LOG_DELTA_WARN )) && [[ $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe error log entries increased by ${delta_errlog} (${prev_errlog} -> ${err_logs})")
                record_alert warning "NVMe Error Log" "Disk $disk NVMe error log entries increased by ${delta_errlog} (${prev_errlog} -> ${err_logs})"
            fi
        fi
        # Delta-based alerts for PCIe correctable errors
        local prev_pcie_corr=${NVME_LAST_PCIE_CORR[$disk]:-0}
        if [[ $pcie_corr -gt $prev_pcie_corr ]]; then
            local delta_corr=$((pcie_corr - prev_pcie_corr))
            if (( delta_corr >= NVME_PCIE_CORR_DELTA_CRIT )); then
                state="CRITICAL"; messages+=("NVMe PCIe correctable errors increased by ${delta_corr} (${prev_pcie_corr} -> ${pcie_corr})")
                record_alert critical "NVMe PCIe Correctable" "Disk $disk NVMe PCIe correctable errors increased by ${delta_corr} (${prev_pcie_corr} -> ${pcie_corr})"
            elif (( delta_corr >= NVME_PCIE_CORR_DELTA_WARN )) && [[ $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe PCIe correctable errors increased by ${delta_corr} (${prev_pcie_corr} -> ${pcie_corr})")
                record_alert warning "NVMe PCIe Correctable" "Disk $disk NVMe PCIe correctable errors increased by ${delta_corr} (${prev_pcie_corr} -> ${pcie_corr})"
            fi
        fi
        # Delta-based alerts for PCIe uncorrectable errors (any increase critical)
        local prev_pcie_unc=${NVME_LAST_PCIE_UNC[$disk]:-0}
        if [[ $pcie_unc -gt $prev_pcie_unc ]]; then
            local delta_unc=$((pcie_unc - prev_pcie_unc))
            if (( delta_unc >= NVME_PCIE_UNC_DELTA_CRIT )); then
                state="CRITICAL"; messages+=("NVMe PCIe uncorrectable errors increased by ${delta_unc} (${prev_pcie_unc} -> ${pcie_unc})")
                record_alert critical "NVMe PCIe Uncorrectable" "Disk $disk NVMe PCIe uncorrectable errors increased by ${delta_unc} (${prev_pcie_unc} -> ${pcie_unc})"
            elif (( delta_unc >= NVME_PCIE_UNC_DELTA_WARN )) && [[ $state != CRITICAL ]]; then
                state="CRITICAL"; messages+=("NVMe PCIe uncorrectable errors increased by ${delta_unc} (${prev_pcie_unc} -> ${pcie_unc})")
                record_alert critical "NVMe PCIe Uncorrectable" "Disk $disk NVMe PCIe uncorrectable errors increased by ${delta_unc} (${prev_pcie_unc} -> ${pcie_unc})"
            fi
        fi
        # Delta-based alerts for thermal transitions
        local prev_t1=${NVME_LAST_THERM_T1[$disk]:-0}
        if [[ $therm_t1 -gt $prev_t1 ]]; then
            local delta_t1=$((therm_t1 - prev_t1))
            if (( delta_t1 >= NVME_THERM_T1_DELTA_WARN )) && [[ $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe thermal transitions T1 increased by ${delta_t1} (${prev_t1} -> ${therm_t1})")
                record_alert warning "NVMe Thermal T1" "Disk $disk NVMe thermal transitions T1 increased by ${delta_t1} (${prev_t1} -> ${therm_t1})"
            fi
        fi
        local prev_t2=${NVME_LAST_THERM_T2[$disk]:-0}
        if [[ $therm_t2 -gt $prev_t2 ]]; then
            local delta_t2=$((therm_t2 - prev_t2))
            if (( delta_t2 >= NVME_THERM_T2_DELTA_WARN )); then
                state="CRITICAL"; messages+=("NVMe thermal transitions T2 increased by ${delta_t2} (${prev_t2} -> ${therm_t2})")
                record_alert critical "NVMe Thermal T2" "Disk $disk NVMe thermal transitions T2 increased by ${delta_t2} (${prev_t2} -> ${therm_t2})"
            fi
        fi
        # Delta-based alerts for temperature time accumulation
        local prev_warn_tt=${NVME_LAST_WARN_TEMP_TIME[$disk]:-0}
        if [[ $warn_temp_time -gt $prev_warn_tt ]]; then
            local delta_wtt=$((warn_temp_time - prev_warn_tt))
            if (( delta_wtt >= NVME_WARN_TEMP_TIME_DELTA_WARN )) && [[ $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe warning temperature time +${delta_wtt}s (total ${warn_temp_time}s)")
                record_alert warning "NVMe Warn Temp Time" "Disk $disk NVMe warning temperature time +${delta_wtt}s (total ${warn_temp_time}s)"
            fi
        fi
        local prev_crit_tt=${NVME_LAST_CRIT_TEMP_TIME[$disk]:-0}
        if [[ $crit_temp_time -gt $prev_crit_tt ]]; then
            local delta_ctt=$((crit_temp_time - prev_crit_tt))
            if (( delta_ctt >= NVME_CRIT_TEMP_TIME_DELTA_WARN )); then
                state="CRITICAL"; messages+=("NVMe critical temperature time +${delta_ctt}s (total ${crit_temp_time}s)")
                record_alert critical "NVMe Critical Temp Time" "Disk $disk NVMe critical temperature time +${delta_ctt}s (total ${crit_temp_time}s)"
            fi
        fi
        if [[ -n "$avail_spare" && -n "$avail_spare_thr" && $avail_spare -lt $avail_spare_thr ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("NVMe Available Spare ${avail_spare}% < threshold ${avail_spare_thr}%")
            record_alert warning "NVMe Available Spare" "Disk $disk NVMe Available Spare ${avail_spare}% < threshold ${avail_spare_thr}%"
        elif [[ -n "$avail_spare" && $avail_spare -lt $NVME_AVAIL_SPARE_WARN ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("NVMe Available Spare low: ${avail_spare}%")
            record_alert warning "NVMe Available Spare" "Disk $disk NVMe Available Spare low: ${avail_spare}%"
        fi
        # Detect unsafe shutdown deltas since last run and warn
        local prev_uns=${NVME_LAST_UNSAFE[$disk]:-0}
        local delta=$((unsafe_shutdowns - prev_uns))
        local total_ok=1
        if [[ ${UNSAFE_SDWN_ABSOLUTE_MIN:-0} -gt 0 && $unsafe_shutdowns -lt $UNSAFE_SDWN_ABSOLUTE_MIN ]]; then
            total_ok=0
        fi
        local cooldown_ok=1
        if [[ ${UNSAFE_SDWN_COOLDOWN_DAYS:-0} -gt 0 ]]; then
            local warn_file="$UNSAFE_SDWN_STATE_DIR/${disk}.lastwarn"
            if [[ -f "$warn_file" ]]; then
                local last_ts now diff cooldown_sec
                last_ts=$(cat "$warn_file" 2>/dev/null || echo 0)
                now=$(date +%s)
                cooldown_sec=$((UNSAFE_SDWN_COOLDOWN_DAYS * 86400))
                diff=$((now - last_ts))
                if [[ $diff -lt $cooldown_sec ]]; then
                    cooldown_ok=0
                fi
            fi
        fi
        if [[ $unsafe_shutdowns -gt $prev_uns && $UNSAFE_SDWN_DELTA_WARN -gt 0 && $delta -ge $UNSAFE_SDWN_DELTA_WARN && $total_ok -eq 1 && $cooldown_ok -eq 1 ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("NVMe Unsafe Shutdowns increased: ${prev_uns} -> ${unsafe_shutdowns}")
            record_alert warning "NVMe Unsafe Shutdowns" "Disk $disk NVMe Unsafe Shutdowns increased: ${prev_uns} -> ${unsafe_shutdowns}"
            # Persist last warning timestamp for cooldown
            if [[ -n "$UNSAFE_SDWN_STATE_DIR" ]]; then
                printf '%s' "$(date +%s)" > "$UNSAFE_SDWN_STATE_DIR/${disk}.lastwarn" 2>/dev/null || true
            fi
        fi
        NVME_LAST_UNSAFE[$disk]=$unsafe_shutdowns
        # Evaluate temperature against warn/critical thresholds
        if [[ -n "$nvme_temp" ]]; then
            if [[ $nvme_temp -ge $NVME_TEMP_CRITICAL ]]; then
                state="CRITICAL"; messages+=("NVMe Temp ${nvme_temp}C >= ${NVME_TEMP_CRITICAL}C")
            elif [[ $nvme_temp -ge $NVME_TEMP_WARNING && $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe Temp ${nvme_temp}C >= ${NVME_TEMP_WARNING}C")
            fi
        fi
        # Persist parsed NVMe attributes for downstream consumers
        CUR_ATTR["$disk|nvme_percent_used"]="$percent_used"
        CUR_ATTR["$disk|poh"]="$poh"
        CUR_ATTR["$disk|unsafe_shutdowns"]="$unsafe_shutdowns"
        CUR_ATTR["$disk|media_errors"]="$media_errors"
        CUR_ATTR["$disk|err_logs"]="$err_logs"
        CUR_ATTR["$disk|avail_spare"]="$avail_spare"
        CUR_ATTR["$disk|pcie_corr"]="$pcie_corr"
        CUR_ATTR["$disk|pcie_unc"]="$pcie_unc"
        CUR_ATTR["$disk|therm_t1"]="$therm_t1"
        CUR_ATTR["$disk|therm_t2"]="$therm_t2"
        CUR_ATTR["$disk|warn_temp_time"]="$warn_temp_time"
        CUR_ATTR["$disk|crit_temp_time"]="$crit_temp_time"
        # Update last counters for next run
        NVME_LAST_ERRLOG[$disk]="$err_logs"
        NVME_LAST_PCIE_CORR[$disk]="$pcie_corr"
        NVME_LAST_PCIE_UNC[$disk]="$pcie_unc"
        NVME_LAST_THERM_T1[$disk]="$therm_t1"
        NVME_LAST_THERM_T2[$disk]="$therm_t2"
        NVME_LAST_WARN_TEMP_TIME[$disk]="$warn_temp_time"
        NVME_LAST_CRIT_TEMP_TIME[$disk]="$crit_temp_time"
        # Retrieve and classify latest self-test; persist status and message
        local st_info st_class st_sev st_msg
        st_info=$(get_latest_selftest_info "$disk")
        st_class=$(classify_selftest_status "$(echo "$st_info" | awk -F'|' '{print $3}')")
        st_sev=$(echo "$st_class" | awk -F'|' '{print $1}')
        st_msg=$(echo "$st_class" | awk -F'|' '{print $2}')
        CUR_ATTR["$disk|selftest_status"]="$st_sev"
        CUR_ATTR["$disk|selftest_msg"]="$st_msg"
        if [[ "$st_sev" == "CRITICAL" ]]; then
            state="CRITICAL"; messages+=("Self-test critical: $st_msg")
        elif [[ "$st_sev" == "WARNING" && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("Self-test warning: $st_msg")
        fi
        # Evaluate model-aware POH age thresholds for NVMe
        if [[ -n "$poh" && "$poh" =~ ^[0-9]+$ ]]; then
            local _poh_w _poh_c
            read -r _poh_w _poh_c < <(poh_thresholds_for_device "$disk" "nvme")
            if [[ -n "$_poh_w" && -n "$_poh_c" ]]; then
                if (( poh >= _poh_c )); then
                    state="CRITICAL"; messages+=("POH age NVMe ${poh}h >= ${_poh_c}h")
                elif (( poh >= _poh_w )) && [[ $state != CRITICAL ]]; then
                    [[ $state == OK ]] && state="WARNING"; messages+=("POH age NVMe ${poh}h >= ${_poh_w}h")
                fi
            fi
        fi
    else
        # Query raw SATA SMART attributes and parse key metrics
        local attr realloc pending offunc temp udma reported_uncorr cmd_timeout realloc_events end2end soft_read_err lcc poh
        attr=$(get_sata_raw "$disk")
        # Evaluate reallocated sectors thresholds (warn/crit)
        realloc=$(echo "$attr" | awk '/Reallocated_Sector_Ct/ {print $10; exit}')
        realloc=${realloc:-0}
        if [[ $realloc -ge $RELOC_CRITICAL ]]; then
            state="CRITICAL"; messages+=("Reallocated = $realloc (>= $RELOC_CRITICAL)")
            record_alert critical "Reallocated =" "Disk $disk reallocated sectors $realloc >= $RELOC_CRITICAL"
        elif [[ $realloc -ge $RELOC_WARNING ]]; then
            state="WARNING"; messages+=("Reallocated = $realloc (>= $RELOC_WARNING)")
            record_alert warning "Reallocated =" "Disk $disk reallocated sectors $realloc >= $RELOC_WARNING"
        fi
        # Evaluate pending/uncorrectable sectors
        pending=$(echo "$attr" | awk '/Current_Pending_Sector/ {print $10; exit}')
        pending=${pending:-0}
        if [[ $pending -ge $PEND_WARNING ]]; then
            state="CRITICAL"; messages+=("Pending sectors = $pending")
            record_alert critical "Pending sectors" "Disk $disk pending sectors $pending >= $PEND_WARNING"
        fi
        offunc=$(echo "$attr" | awk '/Offline_Uncorrectable/ {print $10; exit}')
        offunc=${offunc:-0}
        if [[ $offunc -gt 0 ]]; then
            state="CRITICAL"; messages+=("Offline Uncorrectable = $offunc")
            record_alert critical "Offline Uncorrectable" "Disk $disk offline uncorrectable $offunc > 0"
        fi
        # Evaluate reported uncorrectable and command timeout counters
        reported_uncorr=$(echo "$attr" | awk '/Reported_Uncorrectable|Reported_Uncorrect/ {print $10; exit}')
        reported_uncorr=${reported_uncorr:-0}
        if [[ $reported_uncorr -ge $REPORTED_UNC_CRIT ]]; then
            state="CRITICAL"; messages+=("Reported Uncorrectable = $reported_uncorr")
            record_alert critical "Reported Uncorrectable" "Disk $disk reported uncorrectable $reported_uncorr >= $REPORTED_UNC_CRIT"
        fi
        cmd_timeout=$(echo "$attr" | awk '/Command_Timeout/ {print $10; exit}')
        cmd_timeout=${cmd_timeout:-0}
        # Absolute threshold evaluation
        if [[ $cmd_timeout -ge $CMD_TIMEOUT_CRIT ]]; then
            state="CRITICAL"; messages+=("Command Timeout events = $cmd_timeout (>= $CMD_TIMEOUT_CRIT)")
            record_alert critical "Command Timeout events" "Disk $disk command timeout events $cmd_timeout >= $CMD_TIMEOUT_CRIT"
        elif [[ $cmd_timeout -ge $CMD_TIMEOUT_WARN && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("Command Timeout events = $cmd_timeout")
            record_alert warning "Command Timeout events" "Disk $disk command timeout events $cmd_timeout >= $CMD_TIMEOUT_WARN"
        fi
        # Rate (delta) alert with cooldown
        if [[ $CMD_TIMEOUT_DELTA_WARN -gt 0 && $CMD_TIMEOUT_COOLDOWN_DAYS -ge 0 ]]; then
            local prev_ct=${CMD_TIMEOUT_LAST[$disk]:-}
            if [[ -n "$prev_ct" && "$prev_ct" =~ ^[0-9]+$ ]]; then
                local delta=$(( cmd_timeout - prev_ct ))
                if (( delta >= CMD_TIMEOUT_DELTA_WARN )) && [[ $cmd_timeout -ge $CMD_TIMEOUT_WARN ]]; then
                    local cooldown_ok=1
                    if [[ $CMD_TIMEOUT_COOLDOWN_DAYS -gt 0 ]]; then
                        mkdir -p "$CMD_TIMEOUT_STATE_DIR" 2>/dev/null || true
                        local warn_file="$CMD_TIMEOUT_STATE_DIR/${disk}.lastwarn"
                        if [[ -f "$warn_file" ]]; then
                            local last_ts now diff cooldown_sec
                            last_ts=$(cat "$warn_file" 2>/dev/null || echo 0)
                            now=$(date +%s)
                            cooldown_sec=$((CMD_TIMEOUT_COOLDOWN_DAYS * 86400))
                            diff=$((now - last_ts))
                            if [[ $diff -lt $cooldown_sec ]]; then cooldown_ok=0; fi
                        fi
                    fi
                    if (( cooldown_ok == 1 )) && [[ $state != CRITICAL ]]; then
                        [[ $state == OK ]] && state="WARNING"
                        messages+=("Command Timeout increased: ${prev_ct} -> ${cmd_timeout} (+${delta})")
                        record_alert warning "Command Timeout events" "Disk $disk command timeout increased ${prev_ct}->${cmd_timeout} (+${delta})"
                        if [[ $CMD_TIMEOUT_COOLDOWN_DAYS -gt 0 ]]; then
                            printf '%s' "$(date +%s)" > "$CMD_TIMEOUT_STATE_DIR/${disk}.lastwarn" 2>/dev/null || true
                        fi
                    fi
                fi
            fi
            CMD_TIMEOUT_LAST[$disk]=$cmd_timeout
        fi
        # Evaluate reallocated event count, end-to-end and soft read error rate
        realloc_events=$(echo "$attr" | awk '/Reallocated_Event_Count/ {print $10; exit}')
        realloc_events=${realloc_events:-0}
        if [[ $realloc_events -ge $REALLOC_EVENT_CRIT ]]; then
            state="CRITICAL"; messages+=("Reallocated Event Count = $realloc_events (>= $REALLOC_EVENT_CRIT)")
            record_alert critical "Reallocated Event Count" "Disk $disk reallocated event count $realloc_events >= $REALLOC_EVENT_CRIT"
        elif [[ $realloc_events -ge $REALLOC_EVENT_WARN && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("Reallocated Event Count = $realloc_events")
            record_alert warning "Reallocated Event Count" "Disk $disk reallocated event count $realloc_events >= $REALLOC_EVENT_WARN"
        fi
        end2end=$(echo "$attr" | awk '/End_to_End_Error/ {print $10; exit}')
        end2end=${end2end:-0}
        if [[ $end2end -ge $END_TO_END_ERR_CRIT ]]; then
            state="CRITICAL"; messages+=("End-to-End Errors = $end2end")
            record_alert critical "End-to-End Errors" "Disk $disk end-to-end errors $end2end >= $END_TO_END_ERR_CRIT"
        fi
        soft_read_err=$(echo "$attr" | awk '/Soft_Read_Error_Rate/ {print $10; exit}')
        soft_read_err=${soft_read_err:-}
        if [[ -n "$soft_read_err" && $soft_read_err =~ ^[0-9]+$ && $soft_read_err -ge $SOFT_READ_ERR_WARN && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("Soft Read Error Rate = $soft_read_err (>= $SOFT_READ_ERR_WARN)")
            record_alert warning "Soft Read Error Rate" "Disk $disk soft read error rate $soft_read_err >= $SOFT_READ_ERR_WARN"
        fi
        # Determine device class (HDD/SSD) and evaluate temperature thresholds
        temp=$(echo "$attr" | awk '/Temperature_Celsius|Airflow_Temperature_Cel/ {print $10; exit}')
        temp=${temp:-0}
        if [[ -n "$temp" && "$temp" =~ ^[0-9]+$ && "$temp" != 0 ]]; then
            printf '%s %s temp=%s\n' "$(date '+%Y-%m-%d')" "$disk" "$temp" >> "$TEMP_HISTORY_FILE" 2>/dev/null || true
        fi
        local bdv
        bdv=$(base_device "$disk")
        local rota
            rota=$(lsblk_rota_cached "$bdv" 2>/dev/null || echo 1)
        local warn_t crit_t label
        if [[ "$rota" == "1" ]]; then
            warn_t=$HDD_TEMP_WARNING; crit_t=$HDD_TEMP_CRITICAL; label="HDD Temp"
        else
            warn_t=$SSD_TEMP_WARNING; crit_t=$SSD_TEMP_CRITICAL; label="SSD Temp"
        fi
        if [[ -n "$temp" && "$temp" != "0" ]]; then
            if [[ $temp -ge $crit_t ]]; then
                state="CRITICAL"; messages+=("${label} ${temp}C >= ${crit_t}C")
                record_alert critical "Temp" "Disk $disk ${label} ${temp}C >= ${crit_t}C"
            elif [[ $temp -ge $warn_t && $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("${label} ${temp}C >= ${warn_t}C")
                record_alert warning "Temp" "Disk $disk ${label} ${temp}C >= ${warn_t}C"
            fi
        fi
        # Check UDMA CRC errors and head parking (Load Cycle Count)
        udma=$(echo "$attr" | awk '/UDMA_CRC_Error_Count/ {print $10; exit}')
        udma=${udma:-0}
        if [[ $udma -gt 0 && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("UDMA CRC Errors = $udma")
            record_alert warning "UDMA CRC Errors" "Disk $disk UDMA CRC errors $udma (cabling/power check)"
        fi
        local lcc
        lcc=$(echo "$attr" | awk '/Load_Cycle_Count/ {print $10; exit}')
        lcc=${lcc:-}
        if [[ -n "$lcc" ]]; then
            if [[ $lcc -ge $LOAD_CYCLE_CRIT ]]; then
                state="CRITICAL"; messages+=("Load Cycle Count = $lcc (>= $LOAD_CYCLE_CRIT)")
                record_alert critical "Load Cycle Count" "Disk $disk load cycle count $lcc >= $LOAD_CYCLE_CRIT"
            elif [[ $lcc -ge $LOAD_CYCLE_WARN && $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("Load Cycle Count = $lcc (>= $LOAD_CYCLE_WARN)")
                record_alert warning "Load Cycle Count" "Disk $disk load cycle count $lcc >= $LOAD_CYCLE_WARN"
            fi
        fi
        # Evaluate SSD wear indicators (MWI/Wear Leveling) with heuristics and vendor overrides
        local wear_norm mwi_norm life_remain=""
        wear_norm=$(echo "$attr" | awk '/Wear_Leveling_Count/ {print $4; exit}')
        mwi_norm=$(echo "$attr" | awk '/Media_Wearout_Indicator/ {print $4; exit}')
        # Compute a local TBW estimate from available SMART fields for heuristic decisions
        # Prefer Total_LBAs_Written (or attribute 241 mapped as LBAs) else convert Host_Writes_GiB or NAND_GB_Written
        local _lbasw _lbaw_241 _hw32mib _host_gib _nand_tlc_gb _nand_slc_gb _tbw_bytes=""
        _lbasw=$(echo "$attr" | awk '/Total_LBAs_Written/ {print $10; exit}')
        _lbaw_241=$(echo "$attr" | awk '/^[ ]*241[ ]/ {print $10; exit}')
        if [[ -n "$_lbasw" ]]; then _tbw_bytes=$(( _lbasw * 512 ))
        elif [[ -n "$_lbaw_241" ]]; then _tbw_bytes=$(( _lbaw_241 * 512 ))
        fi
        if [[ -z "${_tbw_bytes:-}" ]]; then
            _host_gib=$(echo "$attr" | awk '/Host_Writes_GiB/ {print $10; exit}')
            if [[ -n "$_host_gib" && "$_host_gib" =~ ^[0-9]+$ ]]; then _tbw_bytes=$(( _host_gib * 1024 * 1024 * 1024 )); fi
        fi
        if [[ -z "${_tbw_bytes:-}" ]]; then
            _nand_tlc_gb=$(echo "$attr" | awk '/NAND_GB_Written_TLC/ {print $10; exit}')
            if [[ -n "$_nand_tlc_gb" && "$_nand_tlc_gb" =~ ^[0-9]+$ ]]; then _tbw_bytes=$(( _nand_tlc_gb * 1024 * 1024 * 1024 )); fi
        fi
        if [[ -z "${_tbw_bytes:-}" ]]; then
            _nand_slc_gb=$(echo "$attr" | awk '/NAND_GB_Written_SLC/ {print $10; exit}')
            if [[ -n "$_nand_slc_gb" && "$_nand_slc_gb" =~ ^[0-9]+$ ]]; then _tbw_bytes=$(( _nand_slc_gb * 1024 * 1024 * 1024 )); fi
        fi
        # Prefer MWI normalized when present, but apply heuristics for inverted/ambiguous reports
        if [[ -n "$mwi_norm" ]]; then
            local model
            model=$(get_device_model "$disk")
            # Vendor override: WD Red SA500 500GB sometimes reports small normalized values that should be inverted
            if echo "$model" | grep -qi 'WD Red' && echo "$model" | grep -qi 'SA500'; then
                local cap_tb
                cap_tb=$(get_device_capacity_tb "$disk")
                if awk -v c="$cap_tb" 'BEGIN{exit !(c>=0.48 && c<=0.52)}'; then
                    if [[ $mwi_norm -le 10 ]]; then
                        # Treat small normalized as percent used -> compute remaining
                        life_remain=$((100 - mwi_norm))
                    else
                        life_remain=$mwi_norm
                    fi
                else
                    life_remain=$mwi_norm
                fi
            else
                # Generic heuristic for new or quirky devices
                if [[ -n "$_tbw_bytes" && $_tbw_bytes -lt $((10*1024*1024*1024)) && $mwi_norm -le 10 ]]; then
                    # Tiny TBW (<10GB) and small normalized value (<=10) -> treat as new drive, assume full life
                    life_remain=100; messages+=("(info: inverted initial wear value $mwi_norm)")
                elif [[ $mwi_norm -le 100 ]]; then
                    # Treat low normalized as percent used when overall writes are still modest
                    if [[ -n "$_tbw_bytes" && $_tbw_bytes -lt $((50*1024*1024*1024)) && $mwi_norm -lt 20 ]]; then
                        life_remain=$((100 - mwi_norm))
                    else
                        life_remain=$mwi_norm
                    fi
                fi
            fi
        elif [[ -n "$wear_norm" ]]; then
            life_remain=$wear_norm
        fi

        if [[ -n "$life_remain" ]]; then
            if [[ $life_remain -le $SSD_WEAR_CRIT ]]; then
                state="CRITICAL"; messages+=("SSD life remaining ${life_remain}% <= ${SSD_WEAR_CRIT}%")
                record_alert critical "SSD life remaining" "Disk $disk SSD life remaining ${life_remain}% <= ${SSD_WEAR_CRIT}%"
            elif [[ $life_remain -le $SSD_WEAR_WARN && $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("SSD life remaining ${life_remain}% <= ${SSD_WEAR_WARN}%")
                record_alert warning "SSD life remaining" "Disk $disk SSD life remaining ${life_remain}% <= ${SSD_WEAR_WARN}%"
            fi
        fi
        # Persist POH and evaluate model-aware age thresholds for SATA (ROTA-aware) + record_alerts
        poh=$(echo "$attr" | awk '/Power_On_Hours/ {print $10; exit}')
        poh=${poh:-0}
        CUR_ATTR["$disk|poh"]="$poh"
        if [[ -n "$poh" && "$poh" =~ ^[0-9]+$ ]]; then
            local _poh_w _poh_c
            read -r _poh_w _poh_c < <(poh_thresholds_for_device "$disk" "sata" "$rota")
            if [[ -n "$_poh_w" && -n "$_poh_c" ]]; then
                local class_label
                if [[ "$rota" == "1" ]]; then class_label="HDD"; else class_label="SSD"; fi
                if (( poh >= _poh_c )); then
                    state="CRITICAL"; messages+=("POH age ${class_label} ${poh}h >= ${_poh_c}h")
                    record_alert critical "POH age ${class_label}" "Disk $disk POH age ${poh}h >= ${_poh_c}h"
                elif (( poh >= _poh_w )) && [[ $state != CRITICAL ]]; then
                    [[ $state == OK ]] && state="WARNING"; messages+=("POH age ${class_label} ${poh}h >= ${_poh_w}h")
                    record_alert warning "POH age ${class_label}" "Disk $disk POH age ${poh}h >= ${_poh_w}h"
                fi
            fi
        fi
        CUR_ATTR["$disk|realloc"]="${realloc:-0}"
        CUR_ATTR["$disk|pending"]="${pending:-0}"
        CUR_ATTR["$disk|offunc"]="${offunc:-0}"
        CUR_ATTR["$disk|reported_uncorr"]="${reported_uncorr:-0}"
        CUR_ATTR["$disk|cmd_timeout"]="${cmd_timeout:-0}"
        CUR_ATTR["$disk|realloc_events"]="${realloc_events:-0}"
        CUR_ATTR["$disk|end2end"]="${end2end:-0}"
        CUR_ATTR["$disk|soft_read_err"]="${soft_read_err:-0}"
        CUR_ATTR["$disk|udma"]="${udma:-0}"
        CUR_ATTR["$disk|lcc"]="${lcc:-0}"
        CUR_ATTR["$disk|temp"]="${temp:-0}"
        if [[ -n "${poh:-}" && "$poh" =~ ^[0-9]+$ ]]; then
            local _poh_w _poh_c
            read -r _poh_w _poh_c < <(poh_thresholds_for_device "$disk" "sata" "$rota")
            if [[ -n "$_poh_w" && -n "$_poh_c" ]]; then
                if (( poh >= _poh_c )); then
                    if [[ "$rota" == "1" ]]; then state="CRITICAL"; messages+=("POH age HDD ${poh}h >= ${_poh_c}h");
                    else state="CRITICAL"; messages+=("POH age SSD ${poh}h >= ${_poh_c}h"); fi
                elif (( poh >= _poh_w )) && [[ $state != CRITICAL ]]; then
                    [[ $state == OK ]] && state="WARNING"
                    if [[ "$rota" == "1" ]]; then messages+=("POH age HDD ${poh}h >= ${_poh_w}h"); else messages+=("POH age SSD ${poh}h >= ${_poh_w}h"); fi
                fi
            fi
        fi
        # Detect SATA negotiated link speed downshift (cabling/port issues)
        local info line max_speed current_speed
        info=$(get_sata_info "$disk")
        line=$(echo "$info" | grep -m1 'SATA Version is:' || true)
        if [[ -n "$line" ]]; then
            if [[ $line =~ ([0-9]+\.[0-9])[[:space:]]Gb/s ]]; then
                max_speed="${BASH_REMATCH[1]}"
            fi
            if [[ $line =~ \(current:[[:space:]]([0-9]+\.[0-9])[[:space:]]Gb/s\) ]]; then
                current_speed="${BASH_REMATCH[1]}"
            fi
            current_speed=${current_speed:-$max_speed}
            if [[ -n "$max_speed" && -n "$current_speed" ]]; then
                CUR_ATTR["$disk|sata_link_max"]="$max_speed"
                CUR_ATTR["$disk|sata_link_current"]="$current_speed"
                local max_i=${max_speed/./} curr_i=${current_speed/./}
                if [[ "$max_speed" != "$current_speed" ]]; then
                    local half=$(( max_i / 2 ))
                    if (( curr_i < half )); then
                        state="CRITICAL"; messages+=("SATA link downshift: max ${max_speed} current ${current_speed} Gb/s")
                    else
                        [[ $state == OK ]] && state="WARNING"; messages+=("SATA link downshift: max ${max_speed} current ${current_speed} Gb/s")
                    fi
                    # Persist daily link downshift event (dedup per-date per-device)
                    if (( SATA_LINK_INSTABILITY_ENABLED == 1 )); then
                        local today
                        today=$(date '+%Y-%m-%d')
                        if [[ -f "$SATA_LINK_HISTORY_FILE" ]]; then
                            local tmp
                            tmp=$(mktemp) || { log_warn "mktemp failed; skipping SATA link history dedup"; tmp=""; }
                            if [[ -n "$tmp" ]]; then
                                awk -v d="$today" -v dev="$disk" '!( $1==d && $2==dev )' "$SATA_LINK_HISTORY_FILE" > "$tmp" 2>/dev/null || true
                                mv -f "$tmp" "$SATA_LINK_HISTORY_FILE" 2>/dev/null || rm -f "$tmp" || true
                            fi
                        fi
                        echo "$today $disk max=$max_speed current=$current_speed" >> "$SATA_LINK_HISTORY_FILE"
                    fi
                fi
            fi
        fi
        # Persist commonly used parsed SMART attributes for downstream logic and JSON export
        [[ -n "$life_remain" ]] && CUR_ATTR["$disk|life_remain"]="$life_remain"
        local lbasw hw32mib lbasr tbw_bytes tbw_hr reads_bytes reads_hr
        lbasw=$(echo "$attr" | awk '/Total_LBAs_Written/ {print $10; exit}')
        if [[ -z "$lbasw" ]]; then lbasw=$(echo "$attr" | awk '/^[ ]*241[ ]/ {print $10; exit}'); fi
        if [[ -z "$lbasw" ]]; then
            hw32mib=$(echo "$attr" | awk '/Host_Writes_32MiB/ {print $10; exit}')
            if [[ -z "$hw32mib" ]]; then hw32mib=$(echo "$attr" | awk '/^[ ]*246[ ]/ {print $10; exit}'); fi
            if [[ -n "$hw32mib" ]]; then
                tbw_bytes=$(( hw32mib * 32 * 1024 * 1024 ))
            fi
        else
            tbw_bytes=$(( lbasw * 512 ))
        fi
        lbasr=$(echo "$attr" | awk '/Total_LBAs_Read/ {print $10; exit}')
        if [[ -z "$lbasr" ]]; then lbasr=$(echo "$attr" | awk '/^[ ]*242[ ]/ {print $10; exit}'); fi
        if [[ -n "$lbasr" ]]; then reads_bytes=$(( lbasr * 512 )); fi
        # Summarize TBW/Read totals and evaluate TBW thresholds (model-aware or global)
        if [[ -n "${tbw_bytes:-}" ]]; then
            tbw_hr=$(human_readable "$tbw_bytes")
            messages+=("TBW ~ $tbw_hr")
            CUR_ATTR["$disk|tbw_bytes"]="$tbw_bytes"
            mapfile -t _tbw_eval < <(eval_tbw_state "$disk" "$tbw_bytes" "$state")
            state="${_tbw_eval[0]}"
            if (( ${#_tbw_eval[@]} > 1 )); then
                for ((i=1; i<${#_tbw_eval[@]}; i++)); do messages+=("${_tbw_eval[i]}"); done
            fi
        fi
        # Add read total summary (human-readable)
        if [[ -n "${reads_bytes:-}" ]]; then
            reads_hr=$(human_readable "$reads_bytes")
            messages+=("Read ~ $reads_hr")
        fi
        # Persist per-attribute counters for later comparisons and reporting
        CUR_ATTR["$disk|realloc"]="$realloc"
        CUR_ATTR["$disk|pending"]="$pending"
        CUR_ATTR["$disk|offunc"]="$offunc"
        CUR_ATTR["$disk|reported_uncorr"]="$reported_uncorr"
        CUR_ATTR["$disk|cmd_timeout"]="$cmd_timeout"
        CUR_ATTR["$disk|realloc_events"]="$realloc_events"
        CUR_ATTR["$disk|udma"]="$udma"
        CUR_ATTR["$disk|lcc"]="${lcc:-0}"
        CUR_ATTR["$disk|end2end"]="$end2end"
        CUR_ATTR["$disk|soft_read_err"]="${soft_read_err:-0}"
        CUR_ATTR["$disk|temp"]="$temp"
        # Retrieve and classify latest SATA self-test; persist and update severity
        local st_info st_class st_sev st_msg
        st_info=$(get_latest_selftest_info "$disk")
        st_class=$(classify_selftest_status "$(echo "$st_info" | awk -F'|' '{print $3}')")
        st_sev=$(echo "$st_class" | awk -F'|' '{print $1}')
        st_msg=$(echo "$st_class" | awk -F'|' '{print $2}')
        CUR_ATTR["$disk|selftest_status"]="$st_sev"
        CUR_ATTR["$disk|selftest_msg"]="$st_msg"
        if [[ "$st_sev" == "CRITICAL" ]]; then
            state="CRITICAL"; messages+=("Self-test critical: $st_msg")
        elif [[ "$st_sev" == "WARNING" && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("Self-test warning: $st_msg")
        fi
    fi
    # Persist state & aggregated messages + emit per-line logs (minimal, no single-line aggregation)
    local _joined="" _m
    for _m in "${messages[@]}"; do
        if [[ -z "$_joined" ]]; then _joined="$_m"; else _joined+="; $_m"; fi
    done
    # Decide whether to log based on delta when in post-test context
    SMART_STATE["$disk"]="$state"
    SMART_MSGS["$disk"]="$_joined"
    if [[ "$ctx" == "post-test" && "$prev_state" == "$state" && "${prev_msgs}" == "$_joined" ]]; then
        # No change in state or messages; suppress duplicate post-test log
        :
    else
        # Log state then each message with disk prefix for clarity
        if [[ -n "$ctx" ]]; then
            log_smart "SMART state ($ctx) $disk: $state"
        else
            log_smart "SMART state $disk: $state"
        fi
        for _m in "${messages[@]}"; do
            log_smart "SMART detail $disk: $_m"
        done
    fi
    return 0
}

# === Helper Function ===
# Extract latest SMART self-test entry from smartctl output
get_latest_selftest_info() {
    local disk=$1
    local out
    if [[ $disk == /dev/nvme* ]]; then
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART self-test log read (-l selftest) on $disk"
        out=$(get_selftest_cached "$disk")
    else
        out=$(get_selftest_cached "$disk")
    fi
    local line
    # Most recent entry is first after header; support lines starting with '#' token then numeric ID
    line=$(echo "$out" | awk 'NR>5 && (($1=="#" && $2 ~ /^[0-9]+$/) || $1 ~ /^[0-9]+$/) {print; exit}')
    if [[ -z "$line" ]]; then
        # No entries in self-test log; fall back to execution status from capabilities page
        local exec_status
        if [[ $disk == /dev/nvme* ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART capability read (-c) on $disk"
            exec_status=$(get_capabilities_cached "$disk" | awk -F: '/Self-test execution status/ {sub(/^ +/,"",$2); print $2; exit}') || true
        else
            exec_status=$(get_capabilities_cached "$disk" | awk -F: '/Self-test execution status/ {sub(/^ +/,"",$2); print $2; exit}') || true
        fi
        exec_status=${exec_status:-"Self-test log not yet populated"}
        # Return with status in field 3 to allow downstream classification
        echo "0|unknown|${exec_status}| |"; return
    fi
    local num type status lifetime remaining
    num=$(echo "$line" | awk '{if($1=="#"){print $2}else{print $1}}')
    type=$(echo "$line" | awk '{if($1=="#"){print $3" "$4}else{print $2" "$3}}')
    remaining=$(echo "$line" | grep -o '[0-9]\+%\?' | head -n1 || true)
    lifetime=$(echo "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /hours/){print $(i-1); exit}}}')
    if [[ -z "$lifetime" ]]; then
        # Fallback for NVMe rows lacking the word 'hours': choose largest numeric excluding test id and percentage tokens
        lifetime=$(echo "$line" | awk -v tid="$num" '{maxv=0; for(i=1;i<=NF;i++){if($i ~ /^[0-9]+$/ && $i!=tid && $i!~/^[0-9]+%$/){if($i>maxv) maxv=$i}} if(maxv>0) print maxv}')
    fi
    status=$(echo "$line" | sed -E 's/^\s*#?\s*[0-9]+\s+[^ ]+\s+[^ ]+\s+//' | sed -E 's/\s+[0-9]+%.*//' )
    echo "${num}|${type}|${status}|${lifetime}|${remaining}"
}

# === Helper Function ===
# Map SMART self-test entries to severity
classify_selftest_status() {
    local raw="$1"
    local status norm code sev msg
    status="$raw"
    norm=$(echo "$status" | tr -s ' ' ' ' | sed 's/^ //; s/ $//')
    if [[ -z "${norm//[[:space:]]/}" ]] || echo "$norm" | grep -qiE "not yet populated|no self-tests|no entries|self[- ]?test log (is )?empty"; then
        echo "OK|Self-test log not yet populated"; return 0
    fi
    code=$(echo "$norm" | grep -Eo '0x[0-9a-fA-F]+' | head -n1 || true)
    [[ -z "$code" ]] && code=$(echo "$norm" | grep -Eo '\b[0-9]{1,3}\b' | head -n1 || true)
    sev="OK"; msg="$norm"
    if echo "$norm" | grep -qiE "in progress|progress"; then
        sev="INPROGRESS"; msg="Self-test in progress: $norm"
    elif echo "$norm" | grep -qiE "Completed without error|without error|completed successfully|no error|passed"; then
        sev="OK"; msg="Self-test passed${code:+ (code $code)}"
    elif echo "$norm" | grep -qiE "(read|write|uncorrectable|unrecoverable|fatal|electrical|servo|seek|verify) (error|failure)|failed"; then
        sev="CRITICAL"; msg="Self-test critical${code:+ (code $code)}: $norm"
    elif echo "$norm" | grep -qiE "aborted|interrupted|cancelled"; then
        sev="WARNING"; msg="Self-test did not complete: $norm"
    elif echo "$norm" | grep -qi "Completed"; then
        sev="OK"; msg="Self-test completed${code:+ (code $code)}"
    else
        sev="WARNING"; msg="Self-test ambiguous status: $norm"
    fi
    if [[ $sev == WARNING || $sev == CRITICAL ]]; then
        local key
        key=$(echo "$msg" | tr '[:upper:]' '[:lower:]')
        if [[ -n "${SELFTEST_WARN_SEEN[$key]:-}" ]]; then
            echo "SUPPRESS|Duplicate self-test $sev suppressed"; return 0
        fi
        SELFTEST_WARN_SEEN[$key]=1
    fi
    echo "$sev|$msg"
}

# === Helper Function ===
# Persist a compact snapshot of the latest SMART self-test (or capabilities fallback)
save_selftest_snapshot() {
    local disk="$1"
    local info num type status lifetime remaining sev msg
    info=$(get_latest_selftest_info "$disk")
    IFS='|' read -r num type status lifetime remaining <<< "$info"
    # Classify status for quick glance
    local cls
    cls=$(classify_selftest_status "$status")
    sev=$(echo "$cls" | awk -F'|' '{print $1}')
    msg=$(echo "$cls" | awk -F'|' '{print $2}')
    local base
    base=$(basename "$disk")
    {
        printf "Captured: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf "Disk: %s\n" "$disk"
        printf "Entry: %s\n" "${num:-0}"
        printf "Type: %s\n" "${type:-unknown}"
        printf "Status: %s\n" "${status:-unknown}"
        [[ -n "${lifetime:-}" ]] && printf "LifetimeHours: %s\n" "$lifetime"
        [[ -n "${remaining:-}" ]] && printf "Remaining: %s\n" "$remaining"
        printf "Class: %s\n" "${sev:-OK}"
        [[ -n "${msg:-}" ]] && printf "ClassDetail: %s\n" "$msg"
    } > "$SMART_SELFTEST_DIR/${base}.snapshot" 2>/dev/null || true
}

# === Helper Function ===
# Poll a short self-test until completion or timeout
poll_short_test_completion() {
    local disk=$1
    local waited=0
    while (( waited < SHORT_TEST_MAX_WAIT )); do
        # Poll execution status directly to detect running short test
        local exec_status
        if [[ $disk == /dev/nvme* ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART capability read (-c) on $disk"
            exec_status=$(smartctl -c -d nvme "$disk" 2>/dev/null | awk -F: '/Self-test execution status/ {print $2}') || true
        else
            exec_status=$(smartctl -c "$disk" 2>/dev/null | awk -F: '/Self-test execution status/ {print $2}') || true
        fi
        if echo "$exec_status" | grep -qi 'in progress'; then
            sleep $SHORT_TEST_POLL_INTERVAL
            waited=$(( waited + SHORT_TEST_POLL_INTERVAL ))
            continue
        fi
        # Not in progress: try to read latest self-test log entry for classification
        local info
        info=$(get_latest_selftest_info "$disk")
        local num type status remaining
        IFS='|' read -r num type status remaining <<< "$info"
        # If self-test log is not populated yet, reflect that explicitly
        if [[ "$type" == "unknown" ]]; then
            echo "OK|Self-test log not yet populated"
            return 0
        fi
        local class sev msg
        class=$(classify_selftest_status "$status")
        sev=$(echo "$class" | awk -F'|' '{print $1}')
        msg=$(echo "$class" | awk -F'|' '{print $2}')
        echo "$sev|$msg"
        return 0
    done
    echo "INPROGRESS|Short test still running after ${SHORT_TEST_MAX_WAIT}s"
    return 0
}

# === Helper Function ===
# Fast approximate risk score from state+message
risk_score_quick() {
    local st="$1"; shift
    local msg="$1"; shift
    local score=0
    case "$st" in
        CRITICAL) ((score += W_SEV_CRIT));;
        WARNING)  ((score += W_SEV_WARN));;
    esac
    [[ $msg == *"Pending sectors"* ]] && ((score += W_PENDING))
    [[ $msg == *"Offline Uncorrectable"* || $msg == *"Reported Uncorrectable"* ]] && ((score += W_UNCORR))
    [[ $msg == *"Reallocated ="* ]] && ((score += W_REALLOC))
    [[ $msg == *"Reallocated Event Count"* ]] && ((score += W_REALLOC_EVENTS))
    [[ $msg == *"Command Timeout"* ]] && ((score += W_CMD_TIMEOUT))
    [[ $msg == *"UDMA CRC Errors"* ]] && ((score += W_CRC))
    [[ $msg == *"SSD life remaining"* ]] && ((score += W_SSD_LIFE))
    [[ $msg == *"NVMe wear"* ]] && ((score += W_NVME_WEAR))
    [[ $msg == *"NVMe error log entries increased"* ]] && ((score += W_NVME_ERR_LOG))
    [[ $msg == *"NVMe PCIe correctable errors increased"* ]] && ((score += W_NVME_PCIE_CORR))
    [[ $msg == *"NVMe PCIe uncorrectable errors increased"* ]] && ((score += W_NVME_PCIE_UNC))
    [[ $msg == *"NVMe thermal transitions T1 increased"* ]] && ((score += W_NVME_THERM_TRANS))
    [[ $msg == *"NVMe thermal transitions T2 increased"* ]] && ((score += W_NVME_THERM_TRANS))
    [[ $msg == *"NVMe warning temperature time"* ]] && ((score += W_NVME_TEMP_TIME))
    [[ $msg == *"NVMe critical temperature time"* ]] && ((score += W_NVME_TEMP_TIME))
    [[ $msg == *"POH age HDD"* ]] && ((score += W_POH_HDD))
    [[ $msg == *"POH age SSD"* ]] && ((score += W_POH_SSD))
    [[ $msg == *"POH age NVMe"* ]] && ((score += W_POH_NVME))
    [[ $msg == *"Btrfs device errors"* ]] && ((score += W_BTRFS_DEV_ERR))
    [[ $msg == *"XFS metadata anomalies"* ]] && ((score += W_XFS_META_ERR))
    [[ $msg == *"Temp"* ]] && ((score += W_TEMP))
    [[ $msg == *"End-to-End Errors"* ]] && ((score += W_E2E))
    [[ $msg == *"Soft Read Error Rate"* ]] && ((score += W_SOFT_READ))
    [[ $msg == *"read-only mode"* ]] && ((score += W_NVME_RO))
    [[ $msg == *"reliability degraded"* ]] && ((score += W_NVME_REL))
    echo "$score"
}

# === Helper Function ===
# Launch SMART tests (short/long) as configured
run_smart_test() {
    local disk=$1
    if [[ $disk == /dev/sd* ]]; then
        local pstate
        pstate=$(hdparm -C "$disk" 2>/dev/null | awk -F: '/state is/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print tolower($2)}')
        if echo "$pstate" | grep -qi "standby"; then
            log_info "Spinning up disk $disk (standby -> active) via hdparm -I"
        fi
        hdparm -I "$disk" >/dev/null 2>&1 || true
    fi
    local test_kind="short"
    local selftest poh_attr current_poh last_long_hours_diff="" last_long_poh="" threshold_hours=$(( LONG_TEST_MAX_INTERVAL_DAYS * 24 ))
    # Baseline SMART evaluation and log (pre-test)
    evaluate_smart "$disk" "pre-test"
    if [[ $disk == /dev/nvme* ]]; then
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART self-test log read (-l selftest) on $disk"
        selftest=$(smartctl -l selftest -d nvme "$disk" 2>/dev/null || true)
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART attribute read (-a) on $disk"
        poh_attr=$(smartctl -a -d nvme "$disk" 2>/dev/null | awk -F: '/Power On Hours/ {gsub(/ /,"",$2); print $2; exit}')
    else
        selftest=$(smartctl -l selftest "$disk" 2>/dev/null || true)
        poh_attr=$(smartctl -A "$disk" 2>/dev/null | awk '/Power_On_Hours/ {print $10; exit}')
    fi
    current_poh=${poh_attr:-0}
    # Automatic replacement detection/reset: if current POH is much lower than persisted last-long POH
    if (( REPLACEMENT_AUTO_RESET == 1 )); then
        local persisted_ll=${LONG_LAST_POH["$disk"]:-}
        # Determine device-type-aware threshold
        local drop_threshold=$REPLACEMENT_POH_DROP_THRESHOLD_HOURS
        if [[ $disk == /dev/nvme* ]]; then
            drop_threshold=$REPLACEMENT_POH_DROP_THRESHOLD_HOURS_NVME
        else
            # Distinguish SATA SSD vs HDD via ROTA
            local bdv rota
            bdv=$(base_device "$disk")
            rota=$(lsblk_rota_cached "$bdv" 2>/dev/null || echo 1)
            if [[ "$rota" == "0" ]]; then
                drop_threshold=$REPLACEMENT_POH_DROP_THRESHOLD_HOURS_SSD
            else
                drop_threshold=$REPLACEMENT_POH_DROP_THRESHOLD_HOURS_HDD
            fi
        fi
        if [[ -n "$persisted_ll" && "$persisted_ll" =~ ^[0-9]+$ && "$current_poh" =~ ^[0-9]+$ ]]; then
            if (( persisted_ll - current_poh >= drop_threshold )); then
                log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Possible replacement detected on $disk: current POH ${current_poh}h << last-long POH ${persisted_ll}h (≥${drop_threshold}h drop). Resetting state and forcing initial long test."
                record_alert warning "Drive Replacement" "Detected possible drive replacement on $disk (POH drop ${persisted_ll}->${current_poh} ≥ ${drop_threshold}h). Baseline reset and long test forced."
                printf '%s %s prev_poh=%s new_poh=%s drop=%s threshold=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$disk" "$persisted_ll" "$current_poh" "$(( persisted_ll - current_poh ))" "$drop_threshold" >> "$REPLACEMENT_EVENTS_FILE" 2>/dev/null || true
                unset 'LONG_LAST_POH["$disk"]'
                # Prune processed long-test id for this disk to avoid stale suppression
                if [[ -f "$SMART_LONG_STATE_FILE" ]]; then
                    grep -v "^$disk " "$SMART_LONG_STATE_FILE" > "$SMART_LONG_STATE_FILE.tmp" 2>/dev/null || true
                    mv -f "$SMART_LONG_STATE_FILE.tmp" "$SMART_LONG_STATE_FILE" 2>/dev/null || true
                fi
                # Mark a hint variable for later scheduling block
                local __replacement_forced=1
            fi
        fi
    fi
    # Determine model/vendor and apply hardcoded pattern expansion
    local model_raw=""
    if [[ $disk == /dev/nvme* ]]; then
        model_raw=$(smartctl -i -d nvme "$disk" 2>/dev/null | awk -F: '/^Model Number/ {sub(/^[ \t]+/,"",$2); print $2; exit}')
    else
        model_raw=$(smartctl -i "$disk" 2>/dev/null | awk -F: '/Device Model/ {sub(/^[ \t]+/,"",$2); print $2; exit}')
        [[ -z "$model_raw" ]] && model_raw=$(smartctl -i "$disk" 2>/dev/null | awk -F: '/Model Family/ {sub(/^[ \t]+/,"",$2); print $2; exit}')
    fi
    # Include generic "Extended" to cover NVMe long tests as well as SATA variants
    local patterns=("Extended" "Extended offline" "Extended self-test" "Long")
    if echo "$model_raw" | grep -qi 'ultrastar' && echo "$model_raw" | grep -qi 'wd\|western'; then
        patterns+=("Extended offline" "Extended" "Long offline" "Offline" "Extended-Offline" "Long_test")
    fi
    declare -A _seen_pat
    local p uniq_patterns=()
    for p in "${patterns[@]}"; do
        [[ -z "$p" ]] && continue
        if [[ -z "${_seen_pat[$p]:-}" ]]; then _seen_pat[$p]=1; uniq_patterns+=("$p"); fi
    done
    local combined_regex=""
    for p in "${uniq_patterns[@]}"; do
        [[ -n "$p" ]] && combined_regex+="${p}|"
    done
    combined_regex=${combined_regex%|}
    # Support smartctl rows that begin with '#' then numeric ID; robust lifetime extraction
    last_long_poh=$(echo "$selftest" | awk -v rgx="$combined_regex" '
        NR>5 && $0 ~ rgx && (($1=="#" && $2 ~ /^[0-9]+$/) || $1 ~ /^[0-9]+$/) {
            id_field = ($1=="#" ? $2 : $1)
            lifetime=""
            # Preferred: numeric immediately preceding a dash (LBA error placeholder)
            for(i=1;i<=NF;i++){
                if($i ~ /^[0-9]+$/ && $(i+1) ~ /^-$/){lifetime=$i; break}
            }
            if(lifetime==""){
                maxv=0
                for(i=1;i<=NF;i++){
                    if($i ~ /^[0-9]+$/ && $i!=id_field && $i!~/^[0-9]+%$/){ if($i>maxv) maxv=$i }
                }
                if(maxv>0) lifetime=maxv
            }
            if(lifetime!=""){print lifetime; exit}
        }
    ' | head -n1)
    if [[ -z "$last_long_poh" ]]; then
        last_long_poh=$(echo "$selftest" | awk '
            NR>5 && /Extended offline|Long/ && (($1=="#" && $2 ~ /^[0-9]+$/) || $1 ~ /^[0-9]+$/) {
                id_field = ($1=="#" ? $2 : $1); maxv=0
                for(i=1;i<=NF;i++){
                    if($i ~ /^[0-9]+$/ && $i!=id_field && $i!~/^[0-9]+%$/){ if($i>maxv) maxv=$i }
                }
                if(maxv>0){print maxv; exit}
            }
        ' | head -n1)
    fi
    if [[ -n "$last_long_poh" && $current_poh -gt 0 ]]; then
        # Monotonic guard: ignore regressed lifetime unless drive replacement (current_poh also regressed)
        local prev_ll=${LONG_LAST_POH["$disk"]:-}
        if [[ -n "$prev_ll" && "$prev_ll" =~ ^[0-9]+$ && "$last_long_poh" =~ ^[0-9]+$ ]]; then
            if (( last_long_poh < prev_ll )) && (( current_poh >= prev_ll )) && (( prev_ll - last_long_poh > 1 )); then
                log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Ignoring regressed last long-test lifetime $last_long_poh < $prev_ll on $disk (monotonic guard)"
            else
                LONG_LAST_POH["$disk"]="$last_long_poh"
            fi
        else
            LONG_LAST_POH["$disk"]="$last_long_poh"
        fi
        local eff_ll=${LONG_LAST_POH["$disk"]:-$last_long_poh}
        last_long_hours_diff=$(( current_poh - eff_ll ))
    elif [[ -z "$last_long_poh" && -n "${LONG_LAST_POH[$disk]:-}" && $current_poh -gt 0 ]]; then
        # Fallback to persisted last long POH when self-test log has no entries
        local persisted=${LONG_LAST_POH[$disk]}
        if [[ "$persisted" =~ ^[0-9]+$ && $current_poh -ge $persisted ]]; then
            last_long_hours_diff=$(( current_poh - persisted ))
        fi
    fi
    # SMART scheduling: evaluate SMART state & risk once, then decide if long test needed.
    local state_pre msgs_pre risk_pre schedule_long=0 reasons=()
    evaluate_smart "$disk"
    state_pre="${SMART_STATE[$disk]:-OK}"
    msgs_pre="${SMART_MSGS[$disk]:-}"
    risk_pre=$(risk_score_quick "$state_pre" "$msgs_pre")
    local crit_age_hours=$(( LONG_TEST_CRITICAL_MIN_DAYS * 24 ))
    local risk_age_hours=$(( LONG_TEST_RISK_MIN_DAYS * 24 ))
    # No previous long test record: optionally force initial long only if LONG_TEST_INITIAL_FORCE=1
    # If disabled, we simply skip auto-scheduling and rely on interval/risk/critical triggers later.
    if [[ -z "${last_long_hours_diff:-}" ]]; then
        if (( LONG_TEST_INITIAL_FORCE == 1 )); then
            schedule_long=1; reasons+=("no record")
        else
            # Re-attempt extraction with combined vendor patterns already performed; if still empty we just skip forcing
            if [[ -n "$last_long_poh" && $current_poh -gt 0 ]]; then
                last_long_hours_diff=$(( current_poh - last_long_poh ))
            fi
        fi
    fi
    # Interval elapsed
    if [[ -n "${last_long_hours_diff:-}" && ${last_long_hours_diff} -ge $threshold_hours ]]; then schedule_long=1; reasons+=("interval ${last_long_hours_diff}h >= ${threshold_hours}h"); fi
    # Force long test on detected replacement regardless of LONG_TEST_INITIAL_FORCE
    if [[ -n "${__replacement_forced:-}" ]]; then schedule_long=1; reasons+=("replacement detected"); fi
    # Critical SMART state with sufficient age
    if [[ "$state_pre" == CRITICAL && ( -z "${last_long_hours_diff:-}" || ${last_long_hours_diff} -ge $crit_age_hours ) ]]; then schedule_long=1; reasons+=("critical state"); fi
    # Risk threshold (ignore rising requirement for simplicity)
    if (( risk_pre >= LONG_TEST_RISK_THRESHOLD )) && [[ -z "${last_long_hours_diff:-}" || ${last_long_hours_diff} -ge $risk_age_hours ]]; then schedule_long=1; reasons+=("risk ${risk_pre} >= ${LONG_TEST_RISK_THRESHOLD}"); fi    # Removed explicit SMART_TEST_TYPE override; long tests are scheduled only via risk/critical/interval logic
    if (( schedule_long == 1 )); then
        test_kind="long"
        local last_note="no record"
        [[ -n "${last_long_hours_diff:-}" ]] && last_note="${last_long_hours_diff}h"
        local IFS=','
        local reason_join="${reasons[*]}"
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - LONG test scheduled on $disk (last_long=${last_note}; reasons=${reason_join})"
        LONG_TEST_DECISION+="$disk: long scheduled (last=${last_note}; reasons=${reason_join}; risk=${risk_pre}; state=${state_pre})\n"
        # Alerts only for critical state or risk threshold
        if [[ "$state_pre" == CRITICAL ]]; then
            record_alert critical "SMART Scheduling" "Disk $disk long test scheduled (critical state; risk=${risk_pre})"
        elif (( risk_pre >= LONG_TEST_RISK_THRESHOLD )); then
            record_alert warning "SMART Scheduling" "Disk $disk long test scheduled (risk ${risk_pre} >= ${LONG_TEST_RISK_THRESHOLD})"
        fi
    else
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - SHORT test retained on $disk (risk=${risk_pre} state=${state_pre})"
    fi
    # If not scheduled yet but near interval, add to due-soon health alerts list
    if (( schedule_long == 0 )) && [[ -n "${last_long_hours_diff:-}" ]]; then
        local remaining=$(( threshold_hours - last_long_hours_diff ))
        if (( remaining > 0 )); then
            local days_left=$(( (remaining + 23) / 24 ))
            if (( days_left <= LONG_TEST_NEAR_WINDOW_DAYS )); then
                LONG_TEST_DUE_SOON["$disk"]=$days_left
            fi
        fi
    fi
    # Check for existing in-progress test
    local exec_status existing_in_progress=0
    if [[ $disk == /dev/nvme* ]]; then
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART capability read (-c) on $disk"
        exec_status=$(smartctl -c -d nvme "$disk" 2>/dev/null | awk -F: '/Self-test execution status/ {print $2}') || true
    else
        exec_status=$(smartctl -c "$disk" 2>/dev/null | awk -F: '/Self-test execution status/ {print $2}') || true
    fi
    if echo "$exec_status" | grep -qi 'in progress'; then
        existing_in_progress=1
        # Attempt to classify running test type via latest self-test log entry
        local latest
        latest=$(get_latest_selftest_info "$disk")
        local latest_type latest_status
        latest_type=$(echo "$latest" | awk -F'|' '{print $2}' )
        latest_status=$(echo "$latest" | awk -F'|' '{print $3}' )
        if echo "$latest_status" | grep -qi 'in progress' && echo "$latest_type" | grep -qiE 'extended|long'; then
            LONG_TEST_RUNNING_LONG["$disk"]=1
        fi
    fi
    if [[ $existing_in_progress -eq 1 ]]; then
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Self-test already in progress on $disk; skipping new start (status: ${exec_status})"
        printf '%s %s in_progress status=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$disk" "$exec_status" >> "$SELFTEST_HISTORY_FILE" 2>/dev/null || true
    else
        if [[ $disk == /dev/nvme* ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Starting NVMe SMART test (-t ${test_kind}) on $disk"
            smartctl -t "$test_kind" -d nvme "$disk" >/dev/null 2>&1 || true
            printf '%s %s start type=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$disk" "${test_kind}" >> "$SELFTEST_HISTORY_FILE" 2>/dev/null || true
        else
            smartctl -t "$test_kind" "$disk" >/dev/null 2>&1 || true
            printf '%s %s start type=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$disk" "${test_kind}" >> "$SELFTEST_HISTORY_FILE" 2>/dev/null || true
        fi
        local test_kind_started="${test_kind}"
        if [[ $test_kind_started == long || $test_kind_started == extended ]]; then
            LONG_TEST_RUNNING_LONG["$disk"]=1
        fi
    fi
    if [[ $test_kind == short && $SHORT_TEST_POLL -eq 1 && $existing_in_progress -eq 0 ]]; then
        local result
        result=$(poll_short_test_completion "$disk")
        local s sev msg
        sev=$(echo "$result" | awk -F'|' '{print $1}')
        msg=$(echo "$result" | awk -F'|' '{print $2}')
        if [[ $sev != INPROGRESS ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - $disk short self-test status: $msg"
            printf '%s %s complete type=short sev=%s msg="%s"\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$disk" "$sev" "$msg" >> "$SELFTEST_HISTORY_FILE" 2>/dev/null || true
            if [[ $sev == WARNING ]]; then
                record_alert warning "$NOTIFY_TITLE_SMART" "Disk $disk short self-test warning: $msg"
            fi
        else
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - $disk short self-test still in progress after wait window"
            printf '%s %s incomplete type=short status=in_progress\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$disk" >> "$SELFTEST_HISTORY_FILE" 2>/dev/null || true
        fi
    else
        if [[ $existing_in_progress -eq 1 ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Skipping poll (different test still running)"
        else
            sleep 5
        fi
    fi
    # Re-evaluate post test (may reveal new info); keep pre-eval already used for scheduling
    evaluate_smart "$disk" "post-test"
    local state="${SMART_STATE[$disk]:-OK}" msgs="${SMART_MSGS[$disk]:-}"
    if [[ $state == WARNING || $state == CRITICAL ]]; then
        record_alert "$state" "$NOTIFY_TITLE_SMART" "Disk $disk SMART $state: $msgs"
    fi
    LAST_TEST[$disk]=$(date '+%Y-%m-%d')
    # Persist a compact latest self-test snapshot (even when device self-test log is empty)
    save_selftest_snapshot "$disk"
}

# === Helper Function ===
# Append trend deltas (e.g., pending, realloc) to SMART messages
augment_messages_with_deltas() {
    for disk in "${!SMART_STATE[@]}"; do
        local raw="${SMART_MSGS[$disk]}"
        [[ -z "$raw" ]] && continue
        IFS='; ' read -r -a parts <<< "$raw"
        local augmented=()
        for p in "${parts[@]}"; do
            local attr="" value="" prev="" cur="" delta=""
            if [[ $p =~ Reallocated\ =\ ([0-9]+) ]]; then attr=realloc; value=${BASH_REMATCH[1]}; fi
            if [[ $p =~ Pending\ sectors\ =\ ([0-9]+) ]]; then attr=pending; value=${BASH_REMATCH[1]}; fi
            if [[ $p =~ UDMA\ CRC\ Errors\ =\ ([0-9]+) ]]; then attr=udma; value=${BASH_REMATCH[1]}; fi
            if [[ $p =~ Soft\ Read\ Error\ Rate\ =\ ([0-9]+) ]]; then attr=soft_read_err; value=${BASH_REMATCH[1]}; fi
            if [[ -n "$attr" ]]; then
                prev=${PREV_ATTR["$disk|$attr"]:-}
                cur=${CUR_ATTR["$disk|$attr"]:-$value}
                if [[ -n "$prev" && "$cur" =~ ^[0-9]+$ && "$prev" =~ ^[0-9]+$ ]]; then
                    delta=$((cur - prev))
                    if (( delta > 0 )); then
                        p+=" (+${delta})"
                    fi
                fi
            fi
            local kind=""
            if [[ $p == Reallocated\ *=* ]]; then kind="realloc"; fi
            if [[ $p == Pending\ sectors* ]]; then kind="pending"; fi
            if [[ $p == UDMA\ CRC\ Errors* ]]; then kind="udma"; fi
            if [[ $p == Soft\ Read\ Error\ Rate* ]]; then kind="soft_read"; fi
            if [[ $p == Offline\ Uncorrectable* || $p == Reported\ Uncorrectable* ]]; then kind="uncorrect"; fi
            if [[ $p == NVMe\ thermal* ]]; then kind="nvme_thermal"; fi
            if [[ $p == NVMe\ reliability* ]]; then kind="nvme_rel"; fi
            if [[ $p == NVMe\ media\ in\ read-only* ]]; then kind="nvme_ro"; fi
            if [[ $p == NVMe\ Available\ Spare* ]]; then kind="nvme_spare"; fi
            if [[ $p == NVMe\ media/data\ integrity\ errors* ]]; then kind="nvme_media"; fi
            local prev_state_tag=${PREV_ATTR["$disk|state"]:-OK}
            local new_key="$disk|${kind:-generic}"
            if [[ "${SMART_STATE[$disk]}" != OK && "$prev_state_tag" == OK && -z "${NEW_SEEN[$new_key]:-}" ]]; then
                p="NEW: $p"; NEW_SEEN[$new_key]=1
            fi
            augmented+=("$p")
            attr=""; value=""; prev=""; cur=""; delta=""
        done
        SMART_MSGS[$disk]="$(printf "%s; " "${augmented[@]}")"
    done
}

# === Helper Function ===
# Detect newly completed long tests and summarize result
check_completed_long_tests() {
    declare -A PROCESSED
    if [[ -f "$SMART_LONG_STATE_FILE" ]]; then
        while read -r d id; do PROCESSED[$d]="$id"; done < "$SMART_LONG_STATE_FILE"
    fi
    local disks; disks=$(get_all_disks)
    for disk in $disks; do
        # Sanitize disk before smartctl invocations
        if [[ ! "$disk" =~ ^/dev/[A-Za-z0-9]+([p0-9]+)?$ ]]; then continue; fi
        local out model_raw
        if [[ $disk == /dev/nvme* ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART self-test log read (-l selftest) on $disk"
            out=$(smartctl -l selftest -d nvme "$disk" 2>/dev/null || true)
            model_raw=$(smartctl -i -d nvme "$disk" 2>/dev/null | awk -F: '/^Model Number/ {sub(/^[ \t]+/,"",$2); print $2; exit}')
        else
            out=$(smartctl -l selftest "$disk" 2>/dev/null || true)
            model_raw=$(smartctl -i "$disk" 2>/dev/null | awk -F: '/Device Model/ {sub(/^[ \t]+/,"",$2); print $2; exit}')
            [[ -z "$model_raw" ]] && model_raw=$(smartctl -i "$disk" 2>/dev/null | awk -F: '/Model Family/ {sub(/^[ \t]+/,"",$2); print $2; exit}')
        fi
        # Build unified long-test pattern list (include generic "Extended" for NVMe devices)
        local patterns=("Extended" "Extended offline" "Extended self-test" "Long" "Extended-Offline" "Long offline" "Offline")
        if echo "$model_raw" | grep -qi 'ultrastar' && echo "$model_raw" | grep -qi 'wd\|western'; then
            patterns+=("Extended" "Long_test")
        fi
        declare -A _seen_lp; local p uniq_lp=()
        for p in "${patterns[@]}"; do
            [[ -z "$p" ]] && continue
            if [[ -z "${_seen_lp[$p]:-}" ]]; then _seen_lp[$p]=1; uniq_lp+=("$p"); fi
        done
        local rgx=""
        for p in "${uniq_lp[@]}"; do
            [[ -n "$p" ]] && rgx+="${p}|"
        done
        rgx=${rgx%|}
        local line
        line=$(echo "$out" | awk -v rgx="$rgx" 'NR>5 && $0 ~ rgx && (($1=="#" && $2 ~ /^[0-9]+$/) || $1 ~ /^[0-9]+$/) {print; exit}')
        [[ -z "$line" ]] && continue
        local id type status
        id=$(echo "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /^[0-9]+$/){print $i; break}}}')
        type=$(echo "$line" | awk -v rgx="$rgx" '{for(i=2;i<=NF;i++){if($i ~ /Extended|Long/){print $i; break}}}')
        status=$(echo "$line" | sed -E 's/^\s*#?\s*[0-9]+\s+[^ ]+\s+[^ ]+\s+//' | sed -E 's/\s+[0-9]+%.*//' )
        if [[ ${PROCESSED[$disk]:-} == "$id" ]]; then continue; fi
        if echo "$status" | grep -qi 'in progress'; then continue; fi
        local class msg sev
        class=$(classify_selftest_status "$status")
        sev=$(echo "$class" | awk -F'|' '{print $1}')
        msg=$(echo "$class" | awk -F'|' '{print $2}')
        if [[ $sev == WARNING ]]; then
            record_alert warning "$NOTIFY_TITLE_SMART" "Disk $disk long self-test warning: $msg"
        elif [[ $sev == CRITICAL ]]; then
            record_alert critical "$NOTIFY_TITLE_SMART" "Disk $disk long self-test CRITICAL: $msg"
        fi
        printf '%s %s complete type=long id=%s sev=%s msg="%s"\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$disk" "$id" "$sev" "$msg" >> "$SELFTEST_HISTORY_FILE" 2>/dev/null || true
        local lifetime poh current_poh
        # Broaden lifetime extraction: first try token before 'hours'; else choose largest numeric token after id
        lifetime=$(echo "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /hours/){print $(i-1); exit}}}')
        if [[ -z "$lifetime" ]]; then
            # Collect numeric tokens excluding the first column (self-test entry index) and percentages
            local largest=0 tok 
            while read -r tok; do
                [[ "$tok" =~ ^[0-9]+$ ]] || continue
                # Skip numeric test id token
                [[ "$tok" == "$id" ]] && continue
                if (( tok > largest )); then largest=$tok; fi
            done < <(echo "$line" | grep -Eo '[0-9]+' )
            [[ $largest -gt 0 ]] && lifetime=$largest
        fi
        if [[ -n "${lifetime:-}" && "$lifetime" =~ ^[0-9]+$ ]]; then
            local prev_ll=${LONG_LAST_POH["$disk"]:-}
            if [[ -n "$prev_ll" && "$prev_ll" =~ ^[0-9]+$ && $lifetime -lt $prev_ll ]]; then
                # Need current POH to decide replacement vs regression
                local cur_poh
                if [[ $disk == /dev/nvme* ]]; then
                    cur_poh=$(smartctl -a -d nvme "$disk" 2>/dev/null | awk -F: '/Power On Hours/ {gsub(/ /,"",$2); print $2; exit}')
                else
                    cur_poh=$(smartctl -A "$disk" 2>/dev/null | awk '/Power_On_Hours/ {print $10; exit}')
                fi
                if [[ "$cur_poh" =~ ^[0-9]+$ && $cur_poh -ge $prev_ll && $(( prev_ll - lifetime )) -gt 1 ]]; then
                    log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Ignoring regressed long-test POH $lifetime < $prev_ll on $disk (monotonic guard)"
                else
                    LONG_LAST_POH["$disk"]="$lifetime"
                    log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Recorded last long-test POH for $disk from self-test log: ${lifetime}h"
                fi
            else
                LONG_LAST_POH["$disk"]="$lifetime"
                log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Recorded last long-test POH for $disk from self-test log: ${lifetime}h"
            fi
        else
            if [[ $disk == /dev/nvme* ]]; then
                log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART attribute read (-a) for POH fallback on $disk"
                poh=$(smartctl -a -d nvme "$disk" 2>/dev/null | awk -F: '/Power On Hours/ {gsub(/ /,"",$2); print $2; exit}')
            else
                poh=$(smartctl -A "$disk" 2>/dev/null | awk '/Power_On_Hours/ {print $10; exit}')
            fi
            if [[ -n "${poh:-}" && "$poh" =~ ^[0-9]+$ ]]; then
                LONG_LAST_POH["$disk"]="$poh"
                log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Recorded last long-test POH for $disk from POH fallback: ${poh}h"
            fi
        fi
        echo "$disk $id" >> "$SMART_LONG_STATE_FILE.tmp"
    done
    if [[ -f "$SMART_LONG_STATE_FILE.tmp" ]]; then
        awk '{a[$1]=$2} END {for(k in a) print k, a[k]}' "$SMART_LONG_STATE_FILE.tmp" > "$SMART_LONG_STATE_FILE"
        rm -f "$SMART_LONG_STATE_FILE.tmp"
    fi
}

# === Main Function ===
# Monitor Btrfs filesystems for scrub status
monitor_btrfs() {
    # Prune aged persisted status files to avoid indefinite growth
    if [[ -d "$BTRFS_SCRUB_STATE_DIR" && ${BTRFS_SCRUB_STATE_TTL_DAYS:-0} -gt 0 ]]; then
        find "$BTRFS_SCRUB_STATE_DIR" -type f -name '*.status' -mtime +"${BTRFS_SCRUB_STATE_TTL_DAYS}" -delete 2>/dev/null || true
    fi
    local all_mounts filtered=()
    mapfile -t all_mounts < <(mount | awk '$5=="btrfs" {print $3}' | sort -u)
    local m
    for m in "${all_mounts[@]}"; do
        local skip=0 base
        for base in "${filtered[@]}"; do
            if [[ "$m" == "$base" ]]; then skip=1; break; fi
            if [[ "$m" == "$base"/* ]]; then skip=1; break; fi
        done
        (( skip==0 )) && filtered+=("$m")
    done
    if [[ ${ENABLE_BTRFS_SCRUB:-0} -eq 1 ]]; then
        log_btrfs "BTRFS scrubbing starting (${#filtered[@]} mount(s))"
    else
        log_btrfs "BTRFS scrubbing disabled; summarizing last recorded status for ${#filtered[@]} mount(s)"
    fi
    for m in "${filtered[@]}"; do
        # Per-mount persisted file key
        local key file
        key="${m//\//_}"
        key="${key// /_}"
        file="$BTRFS_SCRUB_STATE_DIR/${key}.status"
        local data_raid meta_raid
        # Try pretty (-p) output; fallback to default if unsupported by btrfs-progs
        btrfs_df_cached "$m"
        data_raid="${BTRFS_DF_CACHE_DATA[$m]:-UNKNOWN}"
        meta_raid="${BTRFS_DF_CACHE_META[$m]:-UNKNOWN}"
        data_raid=${data_raid:-UNKNOWN}
        meta_raid=${meta_raid:-UNKNOWN}
        local initial_status
        initial_status=$(btrfs scrub status "$m" 2>/dev/null || true)
        if [[ ${ENABLE_BTRFS_SCRUB:-0} -eq 1 ]]; then
            if echo "$initial_status" | grep -qi 'running'; then
                log_btrfs "Scrub already running on $m (Data: $data_raid Meta: $meta_raid)"
            else
                log_btrfs "Starting async scrub on $m (Data: $data_raid Meta: $meta_raid)"
                local _scrub_out
                _scrub_out=$(btrfs scrub start "$m" 2>&1 || true)
                while IFS= read -r _ln; do [[ -n "$_ln" ]] && log_btrfs "$m scrub start: $_ln"; done <<< "$_scrub_out"
            fi
        else
            # If disabled but no persisted status exists and configured to force baseline, kick off one-time scrub
            if [[ ${FIRST_RUN_FORCE:-0} -eq 1 && ! -s "$file" ]]; then
                if echo "$initial_status" | grep -qi 'no stats available'; then
                    log_btrfs "Force baseline scrub (first-run) on $m (Data: $data_raid Meta: $meta_raid)"
                    local _scrub_force
                    _scrub_force=$(btrfs scrub start "$m" 2>&1 || true)
                    while IFS= read -r _ln; do [[ -n "$_ln" ]] && log_btrfs "$m scrub start (forced baseline): $_ln"; done <<< "_scrub_force"
                fi
            fi
        fi
        local status corrected uncorrectable msg
        status=$(btrfs scrub status "$m" 2>/dev/null || true)
        # If kernel has no recorded stats (e.g., post-reboot), load our persisted last status for this mount
        if echo "$status" | grep -qi "no stats available"; then
            if [[ -s "$file" ]]; then
                status=$(cat "$file" 2>/dev/null || true)
            else
                # No kernel stats and no persisted file: emit a clear synthetic summary line
                log_btrfs "$m: Last scrub: none recorded"
            fi
        fi
        log_btrfs "Scrub status $m (Data: $data_raid Meta: $meta_raid)"
        while IFS= read -r ln; do
            [[ -z "$ln" ]] && continue
            log_btrfs "$m: $ln"
        done < <(printf "%s" "$status")
        # Persist status (including "no stats available" sentinel) with a timestamp header
        if [[ -n "$status" ]]; then
            {
                printf "Saved: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
                printf "%s" "$status"
            } > "$file" 2>/dev/null || true
        fi
        # If status indicates no stats available, add explicit synthetic summary for clarity
        if echo "$status" | grep -qi "no stats available"; then
            log_btrfs "$m: Last scrub: none recorded"
        fi
        corrected=$(echo "$status" | awk -F'[: ]+' '/corrected errors/ {print $NF; exit}'); corrected=${corrected:-0}
        uncorrectable=$(echo "$status" | awk -F'[: ]+' '/unrecoverable errors/ {print $NF; exit}'); uncorrectable=${uncorrectable:-0}
        if [[ $uncorrectable -gt 0 ]]; then
            if [[ "$data_raid" =~ RAID0 || "$meta_raid" =~ RAID0 ]]; then
                msg="CRITICAL: $m RAID0 segment unrecoverable errors=$uncorrectable"
            else
                msg="CRITICAL: $m unrecoverable errors=$uncorrectable"
            fi
            log_btrfs "$msg"
            record_alert critical "$NOTIFY_TITLE_BTRFS" "$msg"
        elif [[ $corrected -gt 0 ]]; then
            msg="WARNING: $m scrub corrected=$corrected"
            log_btrfs "$msg"
            record_alert warning "$NOTIFY_TITLE_BTRFS" "$msg"
        fi
    done
    log_btrfs "Btrfs scrubbing completed"
}

# === Main Function ===
# Monitor XFS filesystems for metadata issues
monitor_xfs() {
    if [[ ${ENABLE_XFS_CHECK:-0} -eq 1 ]]; then
        log_xfs "$(date '+%Y-%m-%d %H:%M:%S') - XFS checks starting"
    else
        log_xfs "$(date '+%Y-%m-%d %H:%M:%S') - XFS checks disabled"
    fi
    # Enumerate current XFS mounts
    local mountpoints
    mountpoints=$(mount | awk '$5=="xfs" {print $3}')
    for mp in $mountpoints; do
        log_xfs "$(date '+%Y-%m-%d %H:%M:%S') - XFS check $mp"
        # Optional offline repair (-n) metadata inspection for corruption indicators
        if [[ ${ENABLE_XFS_CHECK:-0} -eq 1 ]]; then
            local dev xfs_out msg
            dev=$(findmnt -n -o SOURCE --target "$mp" 2>/dev/null || true)
            if [[ -n "$dev" ]]; then
                xfs_out=$(xfs_repair -n "$dev" 2>&1 || true)
                log_xfs "$xfs_out"
                # Flag critical if tool output signals error/corruption/fatal conditions
                if echo "$xfs_out" | grep -qiE "error|corrupt|fatal"; then
                    msg="CRITICAL: XFS metadata issue on $mp ($dev)"
                    log_xfs "$(date '+%Y-%m-%d %H:%M:%S') - $msg"
                    record_alert critical "$NOTIFY_TITLE_XFS" "$msg"
                fi
            fi
        fi
        # Scan recent kernel ring buffer for XFS / I/O error patterns referencing mount; raise warning
        if dmesg | tail -n 3000 | grep -qiE "$(basename "$mp").*(XFS|I/O error)|XFS ERROR|xfs_repair"; then
            msg="WARNING: Kernel/XFS I/O messages for $mp"
            log_xfs "$(date '+%Y-%m-%d %H:%M:%S') - $msg"
            record_alert warning "$NOTIFY_TITLE_XFS" "$msg"
        fi
    done
    # Completion log
    log_xfs "$(date '+%Y-%m-%d %H:%M:%S') - XFS checks completed"
}

# === Main Function ===
# Evaluate array and pool capacity against thresholds
evaluate_capacity_alerts() {
    if [[ -n "${ARRAY_PERCENT:-}" ]]; then
        # Critical if usage exceeds configured threshold
        if awk -v p="${ARRAY_PERCENT:-0}" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then
            record_alert critical "Array Capacity" "Array usage ${ARRAY_PERCENT:-0}% > ${THRESHOLD}%"
        # Warning if approaching threshold within NEAR_THRESHOLD_DELTA
        elif awk -v p="${ARRAY_PERCENT:-0}" -v t="$THRESHOLD" -v d="$NEAR_THRESHOLD_DELTA" 'BEGIN{exit (p + d >= t)?0:1}'; then
            record_alert warning "Array Capacity" "Array usage ${ARRAY_PERCENT:-0}% near ${THRESHOLD}%"
        fi
    fi
    if [[ -n "${POOLS_PERCENT:-}" ]]; then
        # Critical / warning evaluation mirrors array logic for pooled storage
        if awk -v p="${POOLS_PERCENT:-0}" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then
            record_alert critical "Pools Capacity" "Pools usage ${POOLS_PERCENT:-0}% > ${THRESHOLD}%"
        elif awk -v p="${POOLS_PERCENT:-0}" -v t="$THRESHOLD" -v d="$NEAR_THRESHOLD_DELTA" 'BEGIN{exit (p + d >= t)?0:1}'; then
            record_alert warning "Pools Capacity" "Pools usage ${POOLS_PERCENT:-0}% near ${THRESHOLD}%"
        fi
    fi
}

# === Helper Function ===
# Evaluate mountpoint usage against defined thresholds
evaluate_per_mount_thresholds() {
    local candidates=(/mnt/disk* /mnt/cache /mnt/*)
    declare -A seen
    local uniq=()
    local mp
    for mp in "${candidates[@]}"; do
        [[ -e "$mp" ]] || continue
        [[ -n "${seen[$mp]:-}" ]] && continue
        seen[$mp]=1
        uniq+=("$mp")
    done
    for mp in "${uniq[@]}"; do
        mountpoint -q "$mp" || continue
        local sz used pct mount
        read -r sz used pct mount < <(df -h --output=size,used,pcent,target "$mp" 2>/dev/null | tail -n1) || continue
        local usep=${pct%%%}
        [[ -n "$usep" ]] || continue
        if [[ $usep -ge $CRITICAL_THRESHOLD_PERCENT ]]; then
            record_alert critical "Storage Critical" "$mp usage ${usep}% >= ${CRITICAL_THRESHOLD_PERCENT}%"
        elif [[ $usep -ge $WARN_THRESHOLD_PERCENT ]]; then
            record_alert warning "Storage Warning" "$mp usage ${usep}% >= ${WARN_THRESHOLD_PERCENT}%"
        fi
    done
}

# === Main Execution ===
# SMART tests, filesystem checks, mapping, I/O error scan
log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Starting SMART tests (short by default; long scheduled per risk)"
check_completed_long_tests
for disk in $(get_all_disks); do
    run_smart_test "$disk"
done
log_smart "$(date '+%Y-%m-%d %H:%M:%S') - SMART tests completed"
augment_messages_with_deltas
save_nvme_state
save_long_last_poh
save_cmd_timeout_last
save_risk_spikes
save_last_test
# Persist daily POH snapshot for aging trend (once per day)
if (( POH_TREND_ENABLED == 1 )); then
    today=$(date '+%Y-%m-%d')
    if [[ -f "$POH_HISTORY_FILE" ]]; then
        tmp=$(mktemp) || { log_warn "mktemp failed; skipping POH history dedup"; tmp=""; }
        if [[ -n "$tmp" ]]; then
            awk -v d="$today" '$1!=d' "$POH_HISTORY_FILE" > "$tmp" 2>/dev/null || true
            mv -f "$tmp" "$POH_HISTORY_FILE" 2>/dev/null || rm -f "$tmp" || true
        fi
    fi
    for disk in "${!SMART_STATE[@]}"; do
        poh=${CUR_ATTR["$disk|poh"]:-}
        if [[ -n "$poh" && "$poh" =~ ^[0-9]+$ ]]; then
            echo "$today $disk poh=$poh" >> "$POH_HISTORY_FILE"
        fi
    done
fi
 # Persist daily SMART attribute snapshot (once per day)
 if (( SMART_ATTR_TREND_ENABLED == 1 )); then
    today=$(date '+%Y-%m-%d')
    if [[ -f "$SMART_ATTR_HISTORY_FILE" ]]; then
        tmp=$(mktemp) || { log_warn "mktemp failed; skipping SMART attribute history dedup"; tmp=""; }
        if [[ -n "$tmp" ]]; then
            awk -v d="$today" '$1!=d' "$SMART_ATTR_HISTORY_FILE" > "$tmp" 2>/dev/null || true
            mv -f "$tmp" "$SMART_ATTR_HISTORY_FILE" 2>/dev/null || rm -f "$tmp" || true
        fi
    fi
    for disk in "${!SMART_STATE[@]}"; do
        # Build compact attribute line: date device attr=value ... (subset of noisy attrs)
        line="$today $disk"
        for key in realloc pending offunc reported_uncorr cmd_timeout realloc_events udma soft_read_err nvme_percent_used unsafe_shutdowns media_errors err_logs pcie_corr pcie_unc therm_t1 therm_t2 warn_temp_time crit_temp_time tbw_bytes poh; do
            val=${CUR_ATTR["$disk|$key"]:-}
            [[ -n "$val" ]] && line+=" $key=$val"
        done
        echo "$line" >> "$SMART_ATTR_HISTORY_FILE"
    done
 fi
     # NVMe wear projection (percent_used -> depletion ETA)
     if (( WEAR_TREND_ENABLED == 1 )); then
        win_wear=${WEAR_TREND_WINDOW_DAYS:-90}
        cutoff_wear=$(date -d "-${win_wear} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
        if [[ -f "$SMART_ATTR_HISTORY_FILE" ]]; then
            declare -A _WEAR_FDT _WEAR_FVAL _WEAR_LDT _WEAR_LVAL
            while read -r dt dev rest; do
                [[ -z "$dt" || -z "$dev" || "$dt" < "$cutoff_wear" ]] && continue
                [[ "$dev" != /dev/nvme* ]] && continue
                pu=$(printf "%s" "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^nvme_percent_used=/){sub(/nvme_percent_used=/,"",$i); print $i; break}}}')
                [[ -z "$pu" ]] && continue
                if [[ -z "${_WEAR_FDT[$dev]:-}" || "$dt" < "${_WEAR_FDT[$dev]}" ]]; then _WEAR_FDT[$dev]="$dt"; _WEAR_FVAL[$dev]="$pu"; fi
                if [[ -z "${_WEAR_LDT[$dev]:-}" || "$dt" > "${_WEAR_LDT[$dev]}" ]]; then _WEAR_LDT[$dev]="$dt"; _WEAR_LVAL[$dev]="$pu"; fi
            done < <(tail -n 50000 "$SMART_ATTR_HISTORY_FILE" 2>/dev/null || cat "$SMART_ATTR_HISTORY_FILE")
            declare -A NVME_WEAR_DAYS_LEFT NVME_WEAR_RATE
            for dev in "${!_WEAR_LVAL[@]}"; do
                fv=${_WEAR_FVAL[$dev]:-0}; lv=${_WEAR_LVAL[$dev]:-0}
                [[ "$fv" =~ ^[0-9]+$ ]] || continue
                [[ "$lv" =~ ^[0-9]+$ ]] || continue
                span_days=$(( ( $(date -d "${_WEAR_LDT[$dev]}" +%s 2>/dev/null || date +%s) - $(date -d "${_WEAR_FDT[$dev]}" +%s 2>/dev/null || date +%s) ) / 86400 ))
                (( span_days<=0 )) && span_days=1
                growth=$(( lv - fv ))
                if (( growth > 0 )); then
                    rate=$(awk -v g="$growth" -v s="$span_days" 'BEGIN{printf "%.4f", g/s}')
                    NVME_WEAR_RATE[$dev]="$rate"
                    remaining=$(( 100 - lv ))
                    if (( remaining <= 0 )); then
                        NVME_WEAR_DAYS_LEFT[$dev]=0
                    else
                        if awk -v r="$rate" -v min="${WEAR_STABLE_MIN_RATE}" 'BEGIN{exit (r>min)?0:1}'; then
                            # days_left = remaining / rate
                            dl=$(awk -v rem="$remaining" -v r="$rate" 'BEGIN{printf "%d", (rem/r)}')
                            NVME_WEAR_DAYS_LEFT[$dev]="$dl"
                        else
                            NVME_WEAR_DAYS_LEFT[$dev]="INF"
                        fi
                    fi
                else
                    NVME_WEAR_RATE[$dev]="0"
                    NVME_WEAR_DAYS_LEFT[$dev]="INF"
                fi
            done
            # Emit projection-based alerts only (guidance integrated in health alerts builder)
            if declare -p NVME_WEAR_DAYS_LEFT &>/dev/null; then
                dev=""; dl=""; rate=""; warn_thr=${WEAR_DAYS_LEFT_WARN:-0}; crit_thr=${WEAR_DAYS_LEFT_CRIT:-0}
                for dev in "${!NVME_WEAR_DAYS_LEFT[@]}"; do
                    dl=${NVME_WEAR_DAYS_LEFT[$dev]}
                    rate=${NVME_WEAR_RATE[$dev]:-0}
                    if [[ "$dl" =~ ^[0-9]+$ ]]; then
                        if (( crit_thr>0 && dl <= crit_thr )); then
                            record_alert critical "NVMe Wear Projection" "Disk $dev projected depletion ${dl}d <= ${crit_thr}d (rate ${rate}%/d)"
                        elif (( warn_thr>0 && dl <= warn_thr )); then
                            record_alert warning "NVMe Wear Projection" "Disk $dev projected depletion ${dl}d <= ${warn_thr}d (rate ${rate}%/d)"
                        fi
                    fi
                done
            fi
        fi
     fi
monitor_btrfs
log_info "Btrfs: scrub status assessed"

# === Helper Function ===
# Check btrfs snapshot counts against thresholds.
check_btrfs_snapshots() {
    local mountpoints
    mountpoints=$(mount | awk '$5=="btrfs" {print $3}')
    for mp in $mountpoints; do
        local list cnt
        list=$(btrfs subvolume list "$mp" 2>/dev/null || true)
        [[ -z "$list" ]] && continue
        cnt=$(printf "%s\n" "$list" | grep -Eio '(^|/)[@.]?snapshots?(/|$)|(^|/)snapshot[^/]*' | wc -l || true)
        if (( cnt >= SNAPSHOT_CRIT )); then
            record_alert critical "$NOTIFY_TITLE_BTRFS" "Critical: $mp snapshot count $cnt >= $SNAPSHOT_CRIT"
        elif (( cnt >= SNAPSHOT_WARN )); then
            record_alert warning "$NOTIFY_TITLE_BTRFS" "Warning: $mp snapshot count $cnt >= $SNAPSHOT_WARN"
        fi
    done
}
check_btrfs_snapshots
log_info "Btrfs: snapshot counts evaluated"
monitor_xfs  # XFS metadata check (if enabled earlier)
log_info "XFS: metadata check completed"
build_mount_device_map  # Populate array mountpoint -> device map
log_info "Mount mapping: devices resolved"

# === Helper Function ===
# Scan syslog/dmesg for disk I/O errors, count unique occurrences per device over time window.
scan_syslog_disk_errors() {
    (( IO_ERROR_MONITOR_ENABLED == 1 )) || { IO_ERROR_FREQ_SECTION=""; return 0; }
    local had_e=0
    case $- in *e*) had_e=1; set +e;; esac
    local window_sec=$(( IO_ERROR_WINDOW_MINUTES * 60 ))
    local now_epoch
    now_epoch=$(date +%s)
    local cutoff=$(( now_epoch - window_sec ))
    local log_src
    if [[ -f "$IO_ERROR_LOG_FILE" ]]; then
        log_src=$(tail -n 20000 "$IO_ERROR_LOG_FILE" 2>/dev/null || true)
    else
        log_src=$(dmesg 2>/dev/null | tail -n 20000 || true)
    fi
    declare -A HASH_SEEN
    if [[ -f "$IO_ERROR_HISTORY_FILE" ]]; then
        while read -r ts dev hash; do
            [[ -z "$ts" || -z "$dev" || -z "$hash" ]] && continue
            if (( ts >= cutoff )); then
                HASH_SEEN["$dev|$hash"]=$ts
            fi
        done < "$IO_ERROR_HISTORY_FILE"
    fi
    local new_hist
    new_hist="$(mktemp)" || { log_warn "mktemp failed; skipping I/O error history update"; new_hist=""; }
    for key in "${!HASH_SEEN[@]}"; do
        if [[ -n "$new_hist" ]]; then
            local ts="${HASH_SEEN[$key]}" dv="${key%%|*}" h="${key#*|}"; printf "%s %s %s\n" "$ts" "$dv" "$h" >> "$new_hist"
        fi
    done
    while read -r line; do
        [[ "$line" == *"Script aborted"* ]] && continue
        [[ "$line" == *"Disk I/O Alert"* ]] && continue
        if ! grep -qiE 'I/O error|blk_update_request|end_request|failed command: (READ|WRITE)|hard resetting link|link is slow to respond|exception Emask' <<< "$line"; then
            continue
        fi
        local devices=()
        local dev_tokens
        dev_tokens=$(echo "$line" | grep -oE 'sd[a-z]|nvme[0-9]+n[0-9]+' 2>/dev/null || true)
        for tok in $dev_tokens; do
            [[ -n "$tok" ]] && devices+=("/dev/$tok")
        done
        (( ${#devices[@]} == 0 )) && continue
        local ts_part epoch
        ts_part=$(echo "$line" | awk '{print $1" "$2" "$3}')
        if [[ "$ts_part" =~ ^[A-Z][a-z]{2}\ [0-9]{1,2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
            epoch=$(date -d "$ts_part $(date '+%Y')" +%s 2>/dev/null || echo "$now_epoch")
        else
            epoch=$now_epoch
        fi
        local hash
        hash=$(echo "$line" | sha1sum | awk '{print $1}')
        for dev in "${devices[@]}"; do
            IO_ERROR_RAW_MAP["$dev"]=$(( ${IO_ERROR_RAW_MAP["$dev"]:-0} + 1 ))
            if (( IO_ERROR_DEDUP_ENABLED == 1 )) && [[ -n "${HASH_SEEN["$dev|$hash"]:-}" ]]; then
                continue
            fi
            HASH_SEEN["$dev|$hash"]=$epoch
            [[ -n "$new_hist" ]] && printf "%s %s %s\n" "$epoch" "$dev" "$hash" >> "$new_hist"
            IO_ERROR_UNIQUE_MAP["$dev"]=$(( ${IO_ERROR_UNIQUE_MAP["$dev"]:-0} + 1 ))
        done
    done < <(printf "%s\n" "$log_src")
    if [[ -n "$new_hist" ]]; then mv "$new_hist" "$IO_ERROR_HISTORY_FILE" 2>/dev/null || true; fi
    local dev _io_rank=() lines=""
    for dev in "${!IO_ERROR_RAW_MAP[@]}"; do
        local raw_count uniq_count mark
        raw_count=${IO_ERROR_RAW_MAP[$dev]:-0}
        uniq_count=${IO_ERROR_UNIQUE_MAP[$dev]:-0}
        mark=""
        if (( uniq_count >= IO_ERROR_CRIT_THRESHOLD )); then
            record_alert critical "$NOTIFY_TITLE_DISKIO" "Disk $dev I/O errors unique $uniq_count >= $IO_ERROR_CRIT_THRESHOLD (last ${IO_ERROR_WINDOW_MINUTES}m)"
            mark="CRIT"
        elif (( uniq_count >= IO_ERROR_WARN_THRESHOLD )); then
            record_alert warning "$NOTIFY_TITLE_DISKIO" "Disk $dev I/O errors unique $uniq_count >= $IO_ERROR_WARN_THRESHOLD (last ${IO_ERROR_WINDOW_MINUTES}m)"
            mark="WARN"
        fi
        # Composite score per device to prioritize frequency list
        local st sm_raw sm_norm uniq err_norm cap_norm=0 arr_slot="" k base_dev
        st="${SMART_STATE[$dev]:-OK}"
        sm_raw="$(risk_score_quick "$st" "${SMART_MSGS[$dev]:-}")"; [[ "$sm_raw" =~ ^[0-9]+$ ]] || sm_raw=0
        sm_norm=$(( sm_raw > 100 ? 100 : sm_raw ))
                # Apply burst boost if present for this device/base
                local _burst_boost=${BURST_BOOST[$dev]:-${BURST_BOOST[$base_dev]:-0}}
                if [[ "$_burst_boost" =~ ^[0-9]+$ && $_burst_boost -gt 0 ]]; then
                    sm_norm=$(( sm_norm + _burst_boost ))
                    (( sm_norm > 100 )) && sm_norm=100
                fi
        base_dev="$(base_device "$dev")"
        uniq="${IO_ERROR_UNIQUE_MAP[$dev]:-${IO_ERROR_UNIQUE_MAP[$base_dev]:-0}}"; [[ "$uniq" =~ ^[0-9]+$ ]] || uniq=0
        if (( uniq >= ${IO_ERROR_CRIT_THRESHOLD:-20} )); then err_norm=100
        elif (( uniq >= ${IO_ERROR_WARN_THRESHOLD:-5} )); then err_norm=65
        else err_norm=$(awk -v u="$uniq" -v w="${IO_ERROR_WARN_THRESHOLD:-5}" 'BEGIN{ if(w>0) printf "%d", (u*50)/w; else print 0 }'); fi
        for k in "${!MOUNT_TO_DEV[@]}"; do
            if [[ "$k" == /mnt/disk* ]]; then
                local mdev bmdev
                mdev="${MOUNT_TO_DEV[$k]}"; bmdev="$(base_device "$mdev")"
                if [[ "$bmdev" == "$base_dev" ]]; then arr_slot="$k"; break; fi
            fi
        done
        if [[ -n "$arr_slot" ]]; then
            local pct usep warn_t crit_t
            warn_t="${WARN_THRESHOLD_PERCENT:-96}"; crit_t="${CRITICAL_THRESHOLD_PERCENT:-98}"
            read -r _sz _u pct _mount < <(df -h --output=size,used,pcent,target "$arr_slot" 2>/dev/null | tail -n1)
            usep=${pct%%%}
            if [[ "$usep" =~ ^[0-9]+$ && $crit_t -gt $warn_t ]]; then
                cap_norm=$(awk -v u="$usep" -v w="$warn_t" -v c="$crit_t" 'BEGIN{ x=u-w; d=c-w; if(d<=0){print 0}else{ if(x<0) x=0; if(x>d) x=d; printf "%d", int((x*100)/d) } }')
            fi
        fi
        local w_cap=20; local w_smart=60; local w_err=20; local total=$(( w_cap + w_smart + w_err )); local comp
        comp=$(awk -v c="$cap_norm" -v s="$sm_norm" -v e="$err_norm" -v wc="$w_cap" -v ws="$w_smart" -v we="$w_err" -v t="$total" 'BEGIN{ printf "%d", int((wc*c + ws*s + we*e)/t) }')
        _io_rank+=("$comp\t$(basename "$dev")\t$raw_count\t$uniq_count\t${mark}")
    done
    if (( ${#_io_rank[@]} > 0 )); then
        local sorted_io
        sorted_io=$(printf "%s\n" "${_io_rank[@]}" | sort -nr -k1,1)
        while IFS=$'\t' read -r comp_score name raw uniq mark; do
            lines+=" - ${name} raw=${raw} unique=${uniq}${mark:+ (${mark})} (priority ${comp_score})\n"
        done <<< "$sorted_io"
        IO_ERROR_FREQ_SECTION="I/O Error Frequency (last ${IO_ERROR_WINDOW_MINUTES}m):\n$lines"
        IO_ERROR_FREQ_SECTION="$(printf "%s\n" "$IO_ERROR_FREQ_SECTION" | trim_outer_blank_lines)"
    else
        IO_ERROR_FREQ_SECTION=""
    fi
    (( had_e == 1 )) && set -e
}
scan_syslog_disk_errors
evaluate_per_mount_thresholds

# === Notification Builder ===
severity_rank() { case "$1" in CRITICAL) echo 2;; WARNING) echo 1;; *) echo 0;; esac; }
status_word()   { case "$1" in 2) echo "CRITICAL";; 1) echo "WARNING";; *) echo "OK";; esac; }
map_emoji()     { case "$1" in 2) printf "🔴";; 1) printf "🟡";; *) printf "🟢";; esac; }

# === Helper Function ===
# Return btrfs Data profile for a mounted path (e.g., RAID1, single, RAID10).
btrfs_data_profile_for_mount() {
    local mp="$1"
    local prof
    btrfs_df_cached "$mp"; prof="${BTRFS_DF_CACHE_DATA[$mp]:-UNKNOWN}"; prof=$(printf "%s" "$prof" | awk -F':' '{print $1}')
    echo "$prof"
}

# === Helper Function ===
# Return btrfs Metadata profile for a mounted path
btrfs_metadata_profile_for_mount() {
    local mp="$1"
    local prof
    btrfs_df_cached "$mp"; prof="${BTRFS_DF_CACHE_META[$mp]:-UNKNOWN}"; prof=$(printf "%s" "$prof" | awk -F':' '{print $1}')
    echo "$prof"
}

# === Helper Function ===
# Condense and sanitize SMART message lists for inline display.
sanitize_smart_for_inline() {
    local raw="${1:-}"; local strip_wear=${2:-0}
    local s
    s=$(printf "%s" "$raw" | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//')
    if (( strip_wear == 1 )); then
        s=$(printf "%s" "$s" | sed -E 's/NVMe wear [0-9]+%//g; s/SSD life remaining [0-9]+%//g')
    fi
    s=$(printf "%s" "$s" | sed -E 's/TBW ~ [^;]+//g; s/Read ~ [^;]+//g')
    s=$(printf "%s" "$s" | sed -E 's/(^|[, ] )TBW, ~, [0-9]+(\.[0-9]+)?( [A-Za-z]+)?(, |$)/\1/g')
    s=$(printf "%s" "$s" | sed -E 's/(^|, )~(, |$)/\1/g')
    local IFS=';'
    read -r -a parts <<< "$s"
    local out_parts=()
    local part
    for part in "${parts[@]}"; do
        part=$(printf "%s" "$part" | sed -E 's/^ +//; s/ +$//')
        [[ -n "$part" ]] && out_parts+=("$part")
        (( ${#out_parts[@]} >= 3 )) && break
    done
    if (( ${#out_parts[@]} == 0 )); then
        echo ""
        return 0
    fi
    local out
    out=$(printf "%s, " "${out_parts[@]}")
    out=${out%%, }
    out=$(printf "%s" "$out" | sed -E 's/, +, /, /g; s/, ,/, /g; s/ +,/,/g; s/, +/, /g; s/^, +//; s/, +$//')
    echo "$out"
}

# === Helper Function ===
# Trim only leading and trailing blank-only lines, preserving internal blank lines
trim_outer_blank_lines() {
    awk 'BEGIN{seen=0;pending=""} {
        if ($0 ~ /^[[:space:]]*$/) { if (seen) pending = pending $0 ORS; next }
        if (pending) { printf "%s", pending; pending="" }
        print; seen=1
    } END{}'
}

# === Main Function ===
# Build array disk list, compute usage per disk, merge SMART severity, and assemble lines
build_storage_and_disk_lines() {
    ARRAY_MAX_SEV=0; POOLS_MAX_SEV=0
    ARRAY_DISK_LINES=""; POOL_LINES=""
    local arr=()
    for d in /mnt/disk*; do [[ -d "$d" ]] || continue; mountpoint -q "$d" || continue; arr+=("$d"); done
    ARRAY_COUNT=${#arr[@]}
    local arr_used=0 arr_size=0
    declare -a ARR_INFO POOL_INFO
    local name
    # For each array disk: parse df usage, compute percent and capacity, combine with SMART severity, and collect reasons
    for d in "${arr[@]}"; do
        local sz u pct mount
        read -r sz u pct mount < <(df -B1 --output=size,used,pcent,target "$d" 2>/dev/null | tail -n1) || continue
        sz=${sz:-0}; u=${u:-0}
        arr_size=$((arr_size + sz)); arr_used=$((arr_used + u))
        local pct_local
        pct_local=$(awk "BEGIN{ if($sz>0) printf \"%.1f\",($u/$sz)*100; else print 0 }")
        local usage_sev=0
        local pct_int="${pct_local%.*}"
        if (( pct_int >= CRITICAL_THRESHOLD_PERCENT )); then usage_sev=2
        elif (( pct_int >= WARN_THRESHOLD_PERCENT )); then usage_sev=1
        fi
        local dev
        dev=$(smart_device_for_mount "$d")
        local sm_state=${SMART_STATE["$dev"]:-OK}
        local sm_msg=${SMART_MSGS["$dev"]:-}
        local sm_rank
        sm_rank=$(severity_rank "$sm_state")
        local final_sev=$usage_sev; (( sm_rank > final_sev )) && final_sev=$sm_rank
        (( final_sev > ARRAY_MAX_SEV )) && ARRAY_MAX_SEV=$final_sev
        local sev_word
        sev_word=$(status_word "$final_sev")
        local reasons=()
        if [[ -n "$sm_msg" && "$sm_state" != OK ]]; then
            local sm_inline
            sm_inline=$(sanitize_smart_for_inline "$sm_msg" 0)
            [[ -n "$sm_inline" ]] && reasons+=("SMART: $sm_inline")
        fi
        local reason_join=""; if (( ${#reasons[@]} > 0 )); then reason_join=$(printf "%s; " "${reasons[@]}"); reason_join=${reason_join%%; }; fi
        local cap_str
        cap_str="$(human_readable "$u") / $(human_readable "$sz")"
        local drv_part=""
        if (( final_sev > 0 && sm_rank > 0 )); then
            local has_smart=0 has_tbw=0 has_wear=0
            has_smart=1
            if [[ "$sm_msg" == *"TBW"* ]]; then has_tbw=1; fi
            if [[ "$sm_msg" == *"NVMe wear"* || "$sm_msg" == *"SSD life remaining"* ]]; then has_wear=1; fi
            local parts=()
            (( has_smart==1 )) && parts+=("SMART")
            (( has_tbw==1 )) && parts+=("TBW")
            (( has_wear==1 )) && parts+=("Wear")
            if (( ${#parts[@]} > 0 )); then
                local joined
                joined="$(IFS=,; echo "${parts[*]}")"
                drv_part="{driver: ${joined}}"
            fi
        fi
        if (( VERBOSE_OK == 1 || final_sev > 0 )); then
            ARR_INFO+=("$(basename "$d")|$cap_str|$pct_local|$sev_word|$drv_part|$reason_join")
        fi
    done
    # Compute aggregated array stats and human-readable forms
    if (( arr_size > 0 )); then
        ARRAY_PERCENT=$(awk "BEGIN{printf \"%.3f\", ($arr_used/$arr_size)*100}")
        ARRAY_USED_HR=$(human_readable "$arr_used")
        ARRAY_TOTAL_HR=$(human_readable "$arr_size")
        # Export raw bytes for higher-precision capacity history
        ARRAY_USED_BYTES=$arr_used
        ARRAY_TOTAL_BYTES=$arr_size
    fi
    # Optionally include parity devices when parity is valid (for visibility)
    local pflag
    pflag="$(parity_clean_flag || true)"
    if [[ "$pflag" == "1" ]]; then
        local ini="/var/local/emhttp/disks.ini"
        if [[ -f "$ini" ]]; then
            # First try direct device mapping
            while IFS=$'\t' read -r sec dev; do
                [[ -z "$sec" || -z "$dev" ]] && continue
                case "$sec" in
                    parity|parity2)
                        local bdev="/dev/$dev"
                        local cap_tb
                        cap_tb="$(get_device_capacity_tb "$bdev")"
                        local cap_str="0B / ${cap_tb}TB"
                        ARR_INFO+=("${sec}|$cap_str|n/a|OK||")
                        ;;
                esac
            done < <(awk -F= '
                BEGIN{sec=""}
                /^\[(parity|parity2)\]/ {sec=$0; gsub(/^[[]|[]]$/, "", sec); next}
                tolower($1)=="device" && sec!="" {val=$2; gsub(/"/, "", val); sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val); printf "%s\t%s\n", sec, val}
            ' "$ini" 2>/dev/null)
            # Fallback: resolve by-id if needed
            while IFS=$'\t' read -r sec idv; do
                [[ -z "$sec" || -z "$idv" ]] && continue
                case "$sec" in
                    parity|parity2)
                        local resolved
                        resolved=$(readlink -f "/dev/disk/by-id/$idv" 2>/dev/null || true)
                        if [[ -b "$resolved" ]]; then
                            local cap_tb
                            cap_tb="$(get_device_capacity_tb "$resolved")"
                            local cap_str="0B / ${cap_tb}TB"
                            ARR_INFO+=("${sec}|$cap_str|n/a|OK||")
                        fi
                        ;;
                esac
            done < <(awk -F= '
                BEGIN{sec=""}
                /^\[(parity|parity2)\]/ {sec=$0; gsub(/^[[]|[]]$/, "", sec); next}
                tolower($1)=="id" && sec!="" {val=$2; gsub(/"/, "", val); sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val); printf "%s\t%s\n", sec, val}
            ' "$ini" 2>/dev/null)
        fi
    fi
    # Discover pools (exclude array disks and /mnt/user), honoring pool excludes
    local pools=()
    for p in /mnt/*; do
        [[ -d "$p" ]] || continue; mountpoint -q "$p" || continue
        local name
        name=$(basename "$p")
        case "$name" in disk*|user) continue;; esac
        local skip=0; for ex in "${POOL_EXCLUDES[@]}"; do [[ "$name" == "$ex" || "$p" == "$ex" ]] && { skip=1; break; }; done
        (( skip==1 )) && continue
        pools+=("$p")
    done
    POOLS_COUNT=${#pools[@]}
    local pools_used=0 pools_size=0
    # For each pool: parse usage, determine filesystem and RAID profile, collect member devices, and evaluate SMART-driven tags
    for p in "${pools[@]}"; do
        local name fstype raid_str="" devlist=""
        name=$(basename "$p")
        local sz u pct mount
        read -r sz u pct mount < <(df -B1 --output=size,used,pcent,target "$p" 2>/dev/null | tail -n1) || continue
        sz=${sz:-0}; u=${u:-0}
        pools_size=$((pools_size + sz)); pools_used=$((pools_used + u))
        local pct
        pct=$(awk "BEGIN{ if($sz>0) printf \"%.1f\",($u/$sz)*100; else print 0 }")
        local usage_sev=0
        if (( $(awk "BEGIN{print ($pct >= $CRITICAL_THRESHOLD_PERCENT)}") )); then usage_sev=2
        elif (( $(awk "BEGIN{print ($pct >= $WARN_THRESHOLD_PERCENT)}") )); then usage_sev=1
        fi
        fstype=$(findmnt -n -o FSTYPE "$p" 2>/dev/null || true)
        if [[ "$fstype" == "btrfs" ]]; then
            local prof_data prof_meta raid_parts=()
            prof_data=$(btrfs_data_profile_for_mount "$p")
            prof_meta=$(btrfs_metadata_profile_for_mount "$p")
            [[ -n "$prof_data" ]] && raid_parts+=("DATA:$(echo "$prof_data" | tr '[:lower:]' '[:upper:]')")
            [[ -n "$prof_meta" ]] && raid_parts+=("META:$(echo "$prof_meta" | tr '[:lower:]' '[:upper:]')")
            if (( ${#raid_parts[@]} > 0 )); then
                local pd_up
                pd_up=$(echo "$prof_data" | tr '[:lower:]' '[:upper:]')
                local pm_up
                pm_up=$(echo "$prof_meta" | tr '[:lower:]' '[:upper:]')
                if [[ -n "$pd_up" && -n "$pm_up" && "$pd_up" == "$pm_up" ]]; then
                    raid_str="(${pd_up})"
                else
                    raid_str="(${raid_parts[*]})"
                fi
            fi
            devlist=$(btrfs filesystem show "$p" 2>/dev/null | awk '/devid/ && /path/ {for(i=1;i<=NF;i++){if($i=="path"){print $(i+1)}}}');
            [[ -z "$devlist" ]] && devlist=$(btrfs filesystem show "$p" 2>/dev/null | awk '/devid/ {print $NF}')
                    # Btrfs profile mismatch / unbalanced detection
                    if [[ -n "$prof_data" && -n "$prof_meta" ]]; then
                        local pd_norm pm_norm
                        pd_norm=$(echo "$prof_data" | tr '[:lower:]' '[:upper:]')
                        pm_norm=$(echo "$prof_meta" | tr '[:lower:]' '[:upper:]')
                        local devcnt
                        devcnt=$(echo "$devlist" | awk 'NF' | wc -l | awk '{print $1}')
                        # Mismatch: one redundant, other single
                        if [[ "$pd_norm" =~ RAID[0-9]+ && "$pm_norm" == SINGLE ]]; then
                            record_alert warning "Btrfs Profile" "Pool $(basename "$p") metadata SINGLE but data $pd_norm; consider 'btrfs balance start -mconvert=$pd_norm'"
                        elif [[ "$pm_norm" =~ RAID[0-9]+ && "$pd_norm" == SINGLE ]]; then
                            record_alert warning "Btrfs Profile" "Pool $(basename "$p") data SINGLE but metadata $pm_norm; consider 'btrfs balance start -dconvert=$pm_norm'"
                        fi
                        # Unbalanced: multiple devices but single profile (no redundancy)
                        if [[ "$devcnt" =~ ^[0-9]+$ && $devcnt -ge 2 && "$pd_norm" == SINGLE ]]; then
                            record_alert warning "Btrfs Unbalanced" "Pool $(basename "$p") has $devcnt devices with data profile SINGLE; add redundancy via 'btrfs balance start -dconvert=raid1 -mconvert=raid1'"
                        fi
                        # RAID1 profile with only one device present
                        if [[ "$devcnt" =~ ^[0-9]+$ && $devcnt -lt 2 && "$pd_norm" == RAID1 ]]; then
                            record_alert warning "Btrfs Unbalanced" "Pool $(basename "$p") data profile RAID1 but only $devcnt device; convert to SINGLE or add a second device."
                        fi
                    fi
        else
            devlist=$(findmnt -n -o SOURCE "$p" 2>/dev/null || true)
            raid_str="(SINGLE)"
        fi
        # Evaluate member device SMART statuses for pool
        local pool_dev_max=0 pool_has_wear=0 pool_has_tbw=0 pool_has_smart=0
        for dv in $devlist; do
            local rootdv="$dv"
            if [[ "$rootdv" == /dev/nvme* ]]; then
                rootdv=$(echo "$rootdv" | sed -E 's/p[0-9]+$//')
            else
                rootdv=$(echo "$rootdv" | sed -E 's/[0-9]+$//')
            fi
            local st="${SMART_STATE[$rootdv]:-OK}" msg="${SMART_MSGS[$rootdv]:-}"
            local r
            r=$(severity_rank "$st")
            (( r > pool_dev_max )) && pool_dev_max=$r
            [[ $r -gt 0 ]] && pool_has_smart=1
            if [[ "$msg" == *"NVMe wear"* || "$msg" == *"SSD life remaining"* ]]; then pool_has_wear=1; fi
            if [[ "$msg" == *"TBW exceeds"* || "$msg" == *"TBW ~"* ]]; then pool_has_tbw=1; fi
        done
        local pool_final=$usage_sev
        (( pool_dev_max > pool_final )) && pool_final=$pool_dev_max
        (( pool_final > POOLS_MAX_SEV )) && POOLS_MAX_SEV=$pool_final
        # Build driver tags (SMART/TBW/Wear) for Pool Disks (only if severity > 0)
        local meta_part=""
        if (( pool_final > 0 )); then
            local parts=()
            (( pool_has_smart == 1 )) && parts+=("SMART")
            (( pool_has_tbw   == 1 )) && parts+=("TBW")
            (( pool_has_wear  == 1 )) && parts+=("Wear")
            if (( ${#parts[@]} > 0 )); then
                local joined
                joined="$(IFS=,; echo "${parts[*]}")"
                meta_part="{driver: ${joined}}"
            fi
        fi
        # Append pool line if verbose or severity > OK
        if (( VERBOSE_OK == 1 || pool_final > 0 )); then
            local cap_str
            cap_str="$(human_readable "$u") / $(human_readable "$sz")"
            local usage_display="$cap_str"; [[ -n "$raid_str" ]] && usage_display="$cap_str $raid_str"
            POOL_INFO+=("$name|$usage_display|$pct|$(status_word "$pool_final")|$meta_part")
        fi
        # Pool membership mapping for annotations
        # Map each member device back to its pool for later annotations
        for dv in $devlist; do
            local rootdv="$dv"
            if [[ "$rootdv" == /dev/nvme* ]]; then
                rootdv=$(echo "$rootdv" | sed -E 's/p[0-9]+$//')
            else
                rootdv=$(echo "$rootdv" | sed -E 's/[0-9]+$//')
            fi
            POOL_MEMBER_MAP["$rootdv"]="$name"
        done
    done
    # Compute aggregated pool stats and human-readable forms
    if (( pools_size > 0 )); then
        POOLS_PERCENT=$(awk "BEGIN{printf \"%.3f\", ($pools_used/$pools_size)*100}")
        POOLS_USED_HR=$(human_readable "$pools_used")
        POOLS_TOTAL_HR=$(human_readable "$pools_size")
        # Export raw bytes for higher-precision capacity history
        POOLS_USED_BYTES=$pools_used
        POOLS_TOTAL_BYTES=$pools_size
    fi
    # Persist per-disk usage snapshot to support disk growth analysis
    local today
    today=$(date '+%Y-%m-%d')
    for d in "${arr[@]}"; do
        local sz u pct mount
        read -r sz u pct mount < <(df -B1 --output=size,used,pcent,target "$d" 2>/dev/null | tail -n1) || continue
        echo "$today $(basename \""$d"\") used=$u size=$sz" >> "$DISK_CAP_HISTORY_FILE"
    done
    # Bump group severities based on capacity thresholds (array/pools)
    if awk -v p="${ARRAY_PERCENT:-0}" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then ARRAY_MAX_SEV=2
    elif awk -v p="${ARRAY_PERCENT:-0}" -v t="$THRESHOLD" -v d="$NEAR_THRESHOLD_DELTA" 'BEGIN{exit (p + d >= t)?0:1}' && [[ $ARRAY_MAX_SEV -lt 1 ]]; then ARRAY_MAX_SEV=1; fi
    if awk -v p="${POOLS_PERCENT:-0}" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then POOLS_MAX_SEV=2
    elif awk -v p="${POOLS_PERCENT:-0}" -v t="$THRESHOLD" -v d="$NEAR_THRESHOLD_DELTA" 'BEGIN{exit (p + d >= t)?0:1}' && [[ $POOLS_MAX_SEV -lt 1 ]]; then POOLS_MAX_SEV=1; fi
    local a_emoji
    a_emoji=$(map_emoji "$ARRAY_MAX_SEV")
    local p_emoji
    p_emoji=$(map_emoji "$POOLS_MAX_SEV")
    local a_word
    a_word=$(status_word "$ARRAY_MAX_SEV")
    local p_word
    p_word=$(status_word "$POOLS_MAX_SEV")
    # Build the top summary line for array and pools
    STORAGE_TOP_LINES=$(printf "%s Array %s (%d Disk): %s%% — %s used of %s\n%s Pools %s (%d Disk): %s%% — %s used of %s" \
        "$a_emoji" "$a_word" "$ARRAY_COUNT" "${ARRAY_PERCENT:-0.0}" "${ARRAY_USED_HR:-0 B}" "${ARRAY_TOTAL_HR:-0 B}" \
        "$p_emoji" "$p_word" "$POOLS_COUNT" "${POOLS_PERCENT:-0.0}" "${POOLS_USED_HR:-0 B}" "${POOLS_TOTAL_HR:-0 B}")
    # Dynamic alignment for [Array Disks] and [Pool Disks]
    local NAME_COL_WIDTH=6 USAGE_COL_WIDTH=22 PCT_COL_WIDTH=4 STATUS_COL_WIDTH=7 DRIVER_COL_WIDTH=0 REASON_COL_WIDTH=0
    local tmp_entry
    for tmp_entry in "${ARR_INFO[@]}" "${POOL_INFO[@]}"; do
        [[ -z "$tmp_entry" ]] && continue
        local n u pct sev drv rsn
        n=$(echo "$tmp_entry" | awk -F'|' '{print $1}')
        u=$(echo "$tmp_entry" | awk -F'|' '{print $2}')
        pct=$(echo "$tmp_entry" | awk -F'|' '{print $3}')
        sev=$(echo "$tmp_entry" | awk -F'|' '{print $4}')
        drv=$(echo "$tmp_entry" | awk -F'|' '{print $5}')
        rsn=$(echo "$tmp_entry" | awk -F'|' '{print $6}')
        (( ${#n}   > NAME_COL_WIDTH )) && NAME_COL_WIDTH=${#n}
        (( ${#u}   > USAGE_COL_WIDTH )) && USAGE_COL_WIDTH=${#u}
        (( ${#pct} > PCT_COL_WIDTH )) && PCT_COL_WIDTH=${#pct}
        (( ${#sev} > STATUS_COL_WIDTH )) && STATUS_COL_WIDTH=${#sev}
        drv=${drv# }
        (( ${#drv} > DRIVER_COL_WIDTH )) && DRIVER_COL_WIDTH=${#drv}
        (( ${#rsn} > REASON_COL_WIDTH )) && REASON_COL_WIDTH=${#rsn}
    done
    (( USAGE_COL_WIDTH > 40 )) && USAGE_COL_WIDTH=40
    (( DRIVER_COL_WIDTH > 40 )) && DRIVER_COL_WIDTH=40
    (( REASON_COL_WIDTH > 80 )) && REASON_COL_WIDTH=80
    local fmt_array fmt_pool
    fmt_array="%-${NAME_COL_WIDTH}s %s (%s%%) [%s]%s%s\n"
    fmt_pool="%-${NAME_COL_WIDTH}s %s (%s%%) [%s]%s%s\n"
    ARRAY_DISK_LINES=""
    # Format [Array Disks] with aligned columns and optional driver/reason fields
    for tmp_entry in "${ARR_INFO[@]}"; do
        local n u pctv sevw drv rsn
        n=$(echo "$tmp_entry" | awk -F'|' '{print $1}')
        u=$(echo "$tmp_entry" | awk -F'|' '{print $2}')
        pctv=$(echo "$tmp_entry" | awk -F'|' '{print $3}')
        sevw=$(echo "$tmp_entry" | awk -F'|' '{print $4}')
        drv=$(echo "$tmp_entry" | awk -F'|' '{print $5}')
        rsn=$(echo "$tmp_entry" | awk -F'|' '{print $6}')
        drv=${drv# }
        local drv_out="" rsn_out=""
        [[ -n "$drv" ]] && drv_out=" $drv"
        [[ -n "$rsn" ]] && rsn_out=" $rsn"
        printf -v ARRAY_DISK_LINES "%s${fmt_array}" "$ARRAY_DISK_LINES" "$n" "$u" "$pctv" "$sevw" "$drv_out" "$rsn_out"
    done
    POOL_LINES=""
    # Format [Pool Disks] similarly with alignment and metadata
    for tmp_entry in "${POOL_INFO[@]}"; do
        local n u pctv sevw meta rsn
        n=$(echo "$tmp_entry" | awk -F'|' '{print $1}')
        u=$(echo "$tmp_entry" | awk -F'|' '{print $2}')
        pctv=$(echo "$tmp_entry" | awk -F'|' '{print $3}')
        sevw=$(echo "$tmp_entry" | awk -F'|' '{print $4}')
        meta=$(echo "$tmp_entry" | awk -F'|' '{print $5}')
        rsn=$(echo "$tmp_entry" | awk -F'|' '{print $6}')
        meta=${meta# }
        local meta_out="" rsn_out=""
        [[ -n "$meta" ]] && meta_out=" $meta"
        [[ -n "$rsn" ]] && rsn_out=" $rsn"
        printf -v POOL_LINES "%s${fmt_pool}" "$POOL_LINES" "$n" "$u" "$pctv" "$sevw" "$meta_out" "$rsn_out"
    done
}

# === Helper Function ===
# Check for discrepancies between array usage and /mnt/user usage
validate_storage_metrics() {
    local user_line discrepancy_section=""
    if mountpoint -q /mnt/user; then
        user_line=$(df -B1 /mnt/user 2>/dev/null | awk 'NR==2')
        local user_sz
        user_sz=$(echo "$user_line" | awk '{print $2}')
        local user_used
        user_used=$(echo "$user_line" | awk '{print $3}')
        if [[ -n "$user_sz" && -n "$user_used" ]]; then
            local user_pct_calc
            user_pct_calc=$(awk "BEGIN{ if($user_sz>0) printf \"%.1f\", ($user_used/$user_sz)*100; else print 0 }")
            if [[ -n "${ARRAY_PERCENT:-}" ]]; then
                local diff
                diff=$(awk -v a="${ARRAY_PERCENT:-0}" -v u="$user_pct_calc" 'BEGIN{d=a-u; if(d<0)d=-d; printf "%.2f", d}')
                local threshold="${STORAGE_DISCREPANCY_MIN_DIFF:-5.0}"
                local diff_int="${diff%.*}" thr_int="${threshold%.*}"
                if (( diff_int >= thr_int )); then
                    discrepancy_section+="Storage Discrepancy: Aggregated array ${ARRAY_PERCENT:-0}% vs /mnt/user ${user_pct_calc}% (diff ${diff}%). Possible share caching, pending deletions, mover activity, or share include/exclude settings.\n"
                    if (( ${STORAGE_DISCREPANCY_ALERT_ENABLED:-1} == 1 )); then
                        local streak=0
                        if [[ -f "$STORAGE_DISCREPANCY_STATE_FILE" ]]; then
                            read -r streak _ < "$STORAGE_DISCREPANCY_STATE_FILE" || true
                            [[ ! "$streak" =~ ^[0-9]+$ ]] && streak=0
                        fi
                        streak=$(( streak + 1 ))
                        printf '%s %s\n' "$streak" "$diff" > "$STORAGE_DISCREPANCY_STATE_FILE" 2>/dev/null || true
                        if (( streak >= ${STORAGE_DISCREPANCY_SUSTAIN_RUNS:-2} )); then
                            record_alert warning "Storage Validation" "Storage discrepancy diff=${diff}% (array ${ARRAY_PERCENT:-0}% vs /mnt/user ${user_pct_calc}%) — investigate share settings (Cache, Include/Exclude), mover status, recent deletions."
                        fi
                    fi
                else
                    # Reset streak when below threshold
                    printf '0 0\n' > "$STORAGE_DISCREPANCY_STATE_FILE" 2>/dev/null || true
                fi
            fi
        fi
    fi
    STORAGE_VALIDATION_SECTION="$discrepancy_section"
    if [[ -n "${STORAGE_VALIDATION_SECTION:-}" ]]; then
        STORAGE_VALIDATION_SECTION="$(printf "%s\n" "$STORAGE_VALIDATION_SECTION" | trim_outer_blank_lines)"
    fi
}

# === Main Function ===
# Summarize subsystem statuses based on collected alerts
build_subsystem_lines() {
    local sm=OK bt=OK xfs=OK cap=OK pm=OK end=OK ad=OK pr=OK
    for a in "${ALERT_CRIT[@]}"; do
        [[ $a == "$NOTIFY_TITLE_SMART"* ]] && sm=CRITICAL
        [[ $a == "$NOTIFY_TITLE_BTRFS"* ]] && bt=CRITICAL
        [[ $a == "$NOTIFY_TITLE_XFS"* ]] && xfs=CRITICAL
        [[ $a == *Capacity* ]] && cap=CRITICAL
        [[ $a == Storage\ Critical* ]] && pm=CRITICAL
        [[ $a == TBW\ Endurance* ]] && end=CRITICAL
        [[ $a == SMART\ Scheduling* ]] && ad=CRITICAL
        [[ $a == Parity\ Status:* ]] && pr=CRITICAL
    done
    for a in "${ALERT_WARN[@]}"; do
        [[ $sm != CRITICAL && $a == "$NOTIFY_TITLE_SMART"* ]] && sm=WARNING
        [[ $bt != CRITICAL && $a == "$NOTIFY_TITLE_BTRFS"* ]] && bt=WARNING
        [[ $xfs != CRITICAL && $a == "$NOTIFY_TITLE_XFS"* ]] && xfs=WARNING
        [[ $cap != CRITICAL && $a == *Capacity* ]] && cap=WARNING
        [[ $pm != CRITICAL && $a == Storage\ Warning* ]] && pm=WARNING
        [[ $end != CRITICAL && $a == TBW\ Endurance* ]] && end=WARNING
        [[ $ad != CRITICAL && $a == SMART\ Scheduling* ]] && ad=WARNING
        [[ $pr != CRITICAL && $a == Parity\ Status:* ]] && pr=WARNING
    done
    # Determine Btrfs anomaly counts even if scrub disabled (device errors, unrecoverable, corrected)
    local btrfs_anom_count=0 btrfs_crit_flag=0 btrfs_warn_flag=0
    # Scan SMART_MSGS for device-level patterns
    for msg in "${SMART_MSGS[@]}"; do
        if [[ $msg == *"Btrfs device errors"* ]]; then btrfs_anom_count=$((btrfs_anom_count+1)); btrfs_warn_flag=1; fi
    done
    # Scan recommendation / alert arrays for additional Btrfs patterns
    for a in "${ALERT_CRIT[@]}"; do
        if [[ $a == *"scrub corrected="* || $a == *"unrecoverable errors="* || $a == *"Btrfs device errors"* ]]; then
            btrfs_anom_count=$((btrfs_anom_count+1)); btrfs_crit_flag=1
        fi
    done
    for a in "${ALERT_WARN[@]}"; do
        if [[ $a == *"scrub corrected="* || $a == *"unrecoverable errors="* || $a == *"Btrfs device errors"* ]]; then
            btrfs_anom_count=$((btrfs_anom_count+1)); btrfs_warn_flag=1
        fi
    done
    # Elevate bt severity if anomalies present even when scrub disabled
    if (( btrfs_crit_flag == 1 )) && [[ $bt != CRITICAL ]]; then bt=CRITICAL; fi
    if (( btrfs_warn_flag == 1 )) && [[ $bt == OK ]]; then bt=WARNING; fi

    # Determine XFS display state: enabled if either metadata check OR proc stats enabled
    local xfs_display
    if [[ ${ENABLE_XFS_CHECK:-0} -eq 1 || ${ENABLE_XFS_PROC_STATS:-0} -eq 1 ]]; then
        xfs_display="$xfs"
    else
        xfs_display="Disabled"
    fi
    # Count XFS anomalies/messages for optional inline detail
    local xfs_anom_count=0
    for a in "${ALERT_CRIT[@]}" "${ALERT_WARN[@]}"; do
        if [[ $a == *"XFS metadata anomalies"* ]]; then xfs_anom_count=$((xfs_anom_count+1)); fi
        if [[ $a == *"XFS metadata issue"* ]]; then xfs_anom_count=$((xfs_anom_count+1)); fi
        if [[ $a == *"XFS Alert"* ]] && [[ $a == *"Counter "* ]]; then xfs_anom_count=$((xfs_anom_count+1)); fi
    done
    if (( xfs_anom_count > 0 )) && [[ $xfs_display != Disabled ]]; then
        xfs_display+=" (${xfs_anom_count})"
    fi
    # Determine Btrfs display: enabled if scrub OR anomalies present
    local btrfs_display
    if [[ ${ENABLE_BTRFS_SCRUB:-0} -eq 1 || $btrfs_anom_count -gt 0 ]]; then
        btrfs_display="$bt"
    else
        btrfs_display="Disabled"
    fi
    if (( btrfs_anom_count > 0 )) && [[ $btrfs_display != Disabled ]]; then
        btrfs_display+=" (${btrfs_anom_count})"
    fi
    SUBSYSTEM_LINES="SMART: $sm
Btrfs: $btrfs_display
XFS:   $xfs_display
Capacity: $cap
Per-Mount: $pm
Endurance: $end
Scheduling: $ad
Parity: $pr"
}

# === Main Function ===
# Build health alerts based on alert messages
build_health_alerts() {
    local rec=""
    if (( ${#ALERT_WARN[@]} + ${#ALERT_CRIT[@]} > 0 )); then
        rec+="Health Alerts:\n"
        declare -A SEEN_REC_DEVICES=()
        # Track count of distinct critical SMART/NVMe conditions per base device for compound escalation
        declare -A CRIT_SMART_COUNT=()
        # Aggregate firmware reset events per device (POH / wear regressions)
        declare -A FR_EVENTS FR_COUNT FR_FRIENDLY FR_MODEL_SUFFIX FR_CRIT
        # Iterate over alerts (critical first) and map to per-device or per-mount actions
        for x in "${ALERT_CRIT[@]}" "${ALERT_WARN[@]}"; do
            local disk_ref mnt_ref
            disk_ref=$(echo "$x" | grep -o '/dev/[a-zA-Z0-9]*' | head -n1 || true)
            mnt_ref=$(echo "$x" | grep -o '/mnt/[a-zA-Z0-9_-]*' | head -n1 || true)
            local friendly="$disk_ref"
            local bdev=""
            if [[ -n "$disk_ref" ]]; then
                bdev="$(base_device "$disk_ref")"
                local arr_slot="" pool_name=""
                local k
                for k in "${!MOUNT_TO_DEV[@]}"; do
                    if [[ "$k" == /mnt/disk* ]]; then
                        local mdev
                        mdev="${MOUNT_TO_DEV[$k]}"
                        local bmdev
                        bmdev="$(base_device "$mdev")"
                        if [[ "$bmdev" == "$bdev" ]]; then arr_slot="$(basename "$k")"; break; fi
                    fi
                done
                if [[ -n "${POOL_MEMBER_MAP[$bdev]:-}" ]]; then pool_name="${POOL_MEMBER_MAP[$bdev]}"; fi
                if [[ -n "$arr_slot" ]]; then
                    friendly="$arr_slot:$(basename "$bdev")"
                elif [[ -n "$pool_name" ]]; then
                    friendly="${pool_name}:$(basename "$bdev")"
                else
                    friendly="$(basename "$bdev")"
                fi
            fi
            local display_friendly="$friendly"
            if [[ "$friendly" == *:* ]]; then
                local left="${friendly%%:*}" right="${friendly##*:}"
                display_friendly="${left} [${right}]"
            fi
            # Optional model suffix for health alerts
            local model_suffix
            model_suffix="$(model_suffix_for "$bdev")"
            # Match alert text to specific health alert patterns
            case "$x" in
                # Explicit title-based resiliency matches (SATA / Firmware)
                *"SATA Link Instability:"*)
                    if [[ -n "$friendly" ]]; then
                        # Parse streak from body
                        local streak_val
                        streak_val=$(echo "$x" | awk -F'streak ' '{print $2}' | awk '{print $1}' | tr -d 'd' 2>/dev/null || true)
                        [[ "$streak_val" =~ ^[0-9]+$ ]] || streak_val=0
                        local warn_thr=${SATA_LINK_INSTABILITY_STREAK_WARN:-2}
                        local crit_thr=${SATA_LINK_INSTABILITY_STREAK_CRIT:-5}
                        local guidance="Negotiated SATA link speed reduced; reseat/replace cable, test different controller port, verify backplane integrity."
                        if (( streak_val >= crit_thr )); then
                            guidance="Persistent critical SATA link downshift streak (${streak_val}d); treat as physical layer degradation: replace cable/backplane, migrate data off if repeats, verify restoration before next parity check."
                        elif (( streak_val >= warn_thr )); then
                            guidance="SATA link downshift streak (${streak_val}d); investigate cable/backplane, monitor for escalation to critical threshold."
                        fi
                        rec+="- $display_friendly$model_suffix: $guidance\n"
                        [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    fi ;;
                *"Firmware Reset:"*)
                    # Defer aggregation; capture event types per device
                    if [[ -n "$friendly" && -n "$bdev" ]]; then
                        local type=""
                        if [[ $x == *"Power-On Hours dropped"* ]]; then
                            type="POH regression"
                            # Determine critical magnitude from drop amount
                            local drop_val
                            drop_val=$(echo "$x" | grep -o 'drop [0-9]*h' | awk '{print $2}' | tr -d 'h' 2>/dev/null || true)
                            [[ "$drop_val" =~ ^[0-9]+$ ]] || drop_val=0
                            if (( drop_val > ${POH_RESET_CRIT_THRESHOLD:-100} )); then FR_CRIT["$bdev"]=1; fi
                        elif [[ $x == *"NVMe Percentage Used decreased"* || $x == *"NVMe percent_used regression"* ]]; then
                            type="wear regression"
                        else
                            type="counter regression"
                        fi
                        # Append unique type token
                        if [[ -n "$type" ]]; then
                            if [[ ! -v "FR_EVENTS[$bdev]" ]]; then FR_EVENTS["$bdev"]=""; fi
                            if [[ " ${FR_EVENTS[$bdev]} " != *" $type "* ]]; then
                                FR_EVENTS["$bdev"]+=" $type"
                            fi
                            FR_COUNT["$bdev"]=$(( ${FR_COUNT["$bdev"]:-0} + 1 ))
                            FR_FRIENDLY["$bdev"]="$display_friendly"
                            FR_MODEL_SUFFIX["$bdev"]="$model_suffix"
                        fi
                    fi ;;
                *"Drive Replacement"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Drive replacement detected; verify serial/model match expectation, run long SMART test to establish baseline, and perform parity/scrub verification next cycle.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"Btrfs device errors"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Btrfs device error counters increased; run scrub, inspect cables, consider replacing device if trend continues.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"Btrfs Device"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Btrfs per-device errors rising; run scrub, check SMART for underlying issues, inspect cabling/backplane, and plan replacement if escalation persists.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"XFS metadata anomalies"*)
                    if [[ -n "$friendly" ]]; then
                        rec+="- $display_friendly$model_suffix: XFS metadata/stat anomaly, stop array/unmount volume, run 'xfs_repair -n $bdev' (read-only). If output says 'would be modified', back up then run 'xfs_repair $bdev' during maintenance. Also check dmesg and SMART for underlying faults.\n"
                        [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    fi ;;
                *"POH age HDD"*)
                    if echo "$x" | grep -qi 'SMART CRITICAL'; then
                        [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Critical HDD power-on hours; schedule replacement window and ensure backups are current.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    else
                        [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Elevated HDD power-on hours; monitor closely and plan refresh.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    fi ;;
                *"POH age SSD"*)
                    if echo "$x" | grep -qi 'SMART CRITICAL'; then
                        [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Critical SSD power-on hours; migrate workloads and replace soon.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    else
                        [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Elevated SSD power-on hours; plan maintenance window and review TBW/endurance.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    fi ;;
                *"POH age NVMe"*)
                    if echo "$x" | grep -qi 'SMART CRITICAL'; then
                        [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Critical NVMe power-on hours; schedule replacement and validate firmware health.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    else
                        [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Elevated NVMe power-on hours; plan refresh and monitor performance/SMART.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    fi ;;
                *"Reallocated Event Count"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Reallocation events logged; monitor trend; consider replacement if increasing.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"Reallocated ="*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Reallocated sectors rising; monitor; replace if trend increases.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"Pending sectors"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Pending sectors; backup; run long test; plan replacement.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"Offline Uncorrectable"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Offline uncorrectable; clone and replace soon.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 && CRIT_SMART_COUNT["$bdev"]=$(( ${CRIT_SMART_COUNT["$bdev"]:-0} + 1 )) ;;
                *"UDMA CRC Errors"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: CRC errors; reseat/replace SATA cable.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"Temp "*C*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: High temperature; improve cooling / airflow.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"NVMe wear"*)
                    rec+="- ${display_friendly:-NVMe}$model_suffix: High NVMe wear level; schedule replacement.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"long self-test CRITICAL"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Failed long test; migrate data; replace drive.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 && CRIT_SMART_COUNT["$bdev"]=$(( ${CRIT_SMART_COUNT["$bdev"]:-0} + 1 )) ;;
                *"short self-test warning"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Short test warning; run a long test.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"unrecoverable errors="*)
                    [[ -n "$mnt_ref" ]] && rec+="- $mnt_ref (Btrfs): Unrecoverable errors; backup; inspect device(s); rerun scrub.\n" ;;
                *"scrub corrected="*)
                    [[ -n "$mnt_ref" ]] && rec+="- $mnt_ref (Btrfs): Corrected errors; monitor; consider more frequent scrubs.\n" ;;
                *"Parity Sync Errors"*)
                    if [[ -n "$friendly" ]]; then
                        rec+="- $display_friendly$model_suffix: Parity sync reported errors; run SMART long tests, inspect cabling/backplane, consider a correcting parity check.\n"
                        [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    fi ;;
                *"Btrfs Profile"*)
                    if [[ -n "$friendly" ]]; then
                        rec+="- $display_friendly$model_suffix: Btrfs data/metadata profile mismatch; align via 'btrfs balance start -dconvert=raid1 -mconvert=raid1' (use appropriate target).\n"
                        [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    fi ;;
                *"Btrfs Unbalanced"*)
                    if [[ -n "$friendly" ]]; then
                        rec+="- $display_friendly$model_suffix: Btrfs pool redundancy not configured or insufficient devices; add a second device or convert profiles (e.g., raid1).\n"
                        [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    fi ;;
                *"XFS metadata issue"*)
                    [[ -n "$mnt_ref" ]] && rec+="- $mnt_ref (XFS): Metadata issue; schedule offline xfs_repair; backup first.\n" ;;
                *"Array usage "*|*"Pools usage "*)
                    rec+="- Capacity: Cleanup data or plan expansion (usage threshold crossed).\n" ;;
                *"Storage Warning "*)
                    [[ -n "$mnt_ref" ]] && rec+="- $mnt_ref: High usage; cleanup or plan expansion.\n" ;;
                *"Storage Critical "*)
                    [[ -n "$mnt_ref" ]] && rec+="- $mnt_ref: Critical usage; expand immediately or purge data.\n" ;;
                *"Reported Uncorrectable"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Uncorrectable errors; backup immediately; plan replacement.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"Command Timeout events"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Command timeouts; inspect cabling/power; monitor closely.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"End-to-End Errors"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Data path integrity errors; replace drive/controller.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"Soft Read Error Rate"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Elevated soft read errors; run long test; monitor trend.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"NVMe reliability degraded"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: NVMe reliability degraded; schedule replacement soon.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 && CRIT_SMART_COUNT["$bdev"]=$(( ${CRIT_SMART_COUNT["$bdev"]:-0} + 1 )) ;;
                *"NVMe media in read-only mode"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: NVMe is read-only; clone data; replace immediately.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 && CRIT_SMART_COUNT["$bdev"]=$(( ${CRIT_SMART_COUNT["$bdev"]:-0} + 1 )) ;;
                *"NVMe volatile memory backup failed"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: NVMe volatile memory backup failed; ensure power protection; plan replacement.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"SSD life remaining "*)
                    if echo "$x" | grep -q "SSD life remaining .*<= ${SSD_WEAR_CRIT}%"; then
                        [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: SSD life critically low; migrate workloads and replace soon.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    else
                        [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: SSD life low; reduce writes, monitor, and plan refresh.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    fi ;;
                *"TBW exceeds model baseline "*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Terabytes written (TBW) exceeds model baseline; reduce write amplification, review heavy writers, and plan replacement if trend continues.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"TBW exceeds "*" TB"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: High total bytes written (TBW); reduce writes and monitor endurance progression.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"NVMe Unsafe Shutdowns increased:"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Unsafe shutdowns increased; check PSU/UPS, power stability, firmware, and cabling/backplane; run long SMART and filesystem checks.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"NVMe Available Spare "*"< threshold"*|*"NVMe Available Spare low:"*|*"NVMe available spare below threshold"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: NVMe available spare below threshold; plan replacement, reduce write load, and improve cooling.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"NVMe thermal threshold exceeded"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: NVMe thermal threshold exceeded; improve airflow/cooling and review workloads.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"NVMe media/data integrity errors"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: NVMe media/data integrity errors; backup immediately and replace.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 && CRIT_SMART_COUNT["$bdev"]=$(( ${CRIT_SMART_COUNT["$bdev"]:-0} + 1 )) ;;
                *"NVMe error log entries increased"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: NVMe error log growth; review SMART history, update firmware, monitor for escalation, plan replacement if persistent.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"NVMe PCIe uncorrectable errors increased"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: NVMe PCIe UNCORRECTABLE errors; immediate backup; inspect slot/backplane; replace device/controller.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 && CRIT_SMART_COUNT["$bdev"]=$(( ${CRIT_SMART_COUNT["$bdev"]:-0} + 1 )) ;;
                *"NVMe PCIe correctable errors increased"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Rising NVMe PCIe correctable errors; reseat, improve cooling, monitor for uncorrectables.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"NVMe thermal transitions T2 increased"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: NVMe critical thermal transitions; improve airflow/heatsink and reduce sustained heavy writes.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 && CRIT_SMART_COUNT["$bdev"]=$(( ${CRIT_SMART_COUNT["$bdev"]:-0} + 1 )) ;;
                *"NVMe thermal transitions T1 increased"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: NVMe warning thermal transitions; optimize cooling before escalation.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"NVMe warning temperature time +"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: NVMe warning temperature exposure rising; enhance airflow and distribute I/O load.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"NVMe critical temperature time +"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: NVMe critical temperature exposure; throttle workloads and schedule replacement if persistent.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 && CRIT_SMART_COUNT["$bdev"]=$(( ${CRIT_SMART_COUNT["$bdev"]:-0} + 1 )) ;;
                *" snapshot count "*)
                    [[ -n "$mnt_ref" ]] && rec+="- $mnt_ref: Snapshot count high; prune old snapshots and adjust retention.\n" ;;
                *"NVMe Critical Warning flags:"*)
                    if [[ -n "$friendly" ]]; then
                        local flags_val
                        flags_val=$(echo "$x" | awk -F'flags:' '{sub(/^ +/,"",$2); print $2}' 2>/dev/null | tr -d ' ')
                        local bitcount=0 value=0
                        if [[ -n "$flags_val" ]]; then
                            if [[ "$flags_val" =~ ^0x[0-9a-fA-F]+$ ]]; then
                                local hex=${flags_val#0x}
                                value=$((16#${hex}))
                            elif [[ "$flags_val" =~ ^[0-9]+$ ]]; then
                                value=$((flags_val))
                            fi
                            local i
                            for (( i=0; i<8; i++ )); do
                                if (( (value >> i) & 1 )); then ((bitcount++)); fi
                            done
                        fi
                        if (( bitcount >= 2 )); then
                            rec+="- $display_friendly$model_suffix: Multiple NVMe critical warning bits set ($flags_val); immediate backup & replacement planning.\n"
                            [[ -n "$bdev" ]] && CRIT_SMART_COUNT["$bdev"]=$(( ${CRIT_SMART_COUNT["$bdev"]:-0} + 1 ))
                        else
                            rec+="- $display_friendly$model_suffix: NVMe critical warning bitfield ($flags_val) set; review specific flagged conditions and plan mitigation.\n"
                        fi
                        [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    fi ;;
                *"SMART Trend:"*)
                    # One-to-one mapping for SMART Trend record_alert entries
                    if [[ -n "$friendly" ]]; then
                        local trend_body
                        trend_body=$(echo "$x" | sed -E 's/^SMART Trend: //')
                        rec+="- $display_friendly$model_suffix: SMART trend — ${trend_body}; act per attribute guidance (parity check/long test/backup).\n"
                        [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    fi ;;
                *"Kernel/XFS I/O messages"*)
                    [[ -n "$mnt_ref" ]] && rec+="- $mnt_ref: Kernel/XFS I/O errors; inspect cabling/controller logs and consider offline check if persistent.\n" ;;
                *"Load Cycle Count = "*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Excessive load cycle count; adjust APM/firmware settings, monitor trend, plan replacement if rising.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
                *"TBW consumed "*)
                    if echo "$x" | grep -q "TBW consumed .*>= ${TBW_CONSUMED_CRIT}%"; then
                        [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: SSD endurance nearly exhausted; migrate workloads and replace soon.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    else
                        [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: High SSD endurance consumption; reduce writes and plan refresh.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    fi ;;
                *"TBW Endurance"*)
                    if echo "$x" | grep -qi 'CRITICAL'; then
                        [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Terabytes written (TBW) near exhaustion; schedule replacement and migrate workloads.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    else
                        [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Terabytes written (TBW) forecast low; reduce write amplification and plan refresh.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    fi ;;
                *"SMART Scheduling"*)
                    if echo "$x" | grep -qi 'critical'; then
                        [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Long test scheduled (critical SMART state). Back up data, review SMART attributes, consider accelerated replacement.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    else
                        [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: Long test scheduled (elevated risk). Monitor next runs, inspect SMART deltas, plan proactive diagnostics.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    fi ;;
                *"I/O errors unique"*)
                    [[ -n "$friendly" ]] && rec+="- $display_friendly$model_suffix: High I/O error frequency; check SATA/NVMe cabling, power stability, controller logs; consider moving data & replacing if persistent.\n" && [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1 ;;
            esac
        done
        # Emit aggregated firmware reset guidance lines (after collecting all events)
        local fr_dev
        for fr_dev in "${!FR_COUNT[@]}"; do
            local friendly_tag="${FR_FRIENDLY[$fr_dev]:-}" model_suffix="${FR_MODEL_SUFFIX[$fr_dev]:-}" types="${FR_EVENTS[$fr_dev]:-}" cnt="${FR_COUNT[$fr_dev]:-0}"
            types=${types# }
            local plural=""; (( cnt > 1 )) && plural="s"
            local agg_line="Firmware/controller counter regressions detected (${cnt} event${plural}: ${types// /, })"
            if [[ -n "${FR_CRIT[$fr_dev]:-}" ]]; then
                agg_line="Multiple / critical firmware or controller counter regressions (${cnt} events: ${types// /, }); immediate firmware check, controller/backplane inspection, and backup before next parity/scrub."
            fi
            rec+="- ${friendly_tag}${model_suffix}: ${agg_line}.\n"
            SEEN_REC_DEVICES["$fr_dev"]=1
        done
        # Compound SMART failure escalation: if multiple critical conditions detected on same device
        for dev_key in "${!CRIT_SMART_COUNT[@]}"; do
            local cnt=${CRIT_SMART_COUNT[$dev_key]:-0}
            if (( cnt >= 2 )) && [[ -z "${COMPOUND_EMITTED[$dev_key]:-}" ]]; then
                rec+="- $(basename "$dev_key") : Multiple critical SMART/NVMe conditions (${cnt}); prioritize immediate backup & replacement planning.\n"
                COMPOUND_EMITTED[dev_key]=1
            fi
        done
        # Inject NVMe-specific SMART message driven guidance (messages not recorded via record_alert)
        for dev in "${!SMART_STATE[@]}"; do
            local st="${SMART_STATE[$dev]:-OK}"
            [[ $st == OK ]] && continue
            local raw_msg="${SMART_MSGS[$dev]:-}"
            [[ -z "$raw_msg" ]] && continue
            local base
            base="$(base_device "$dev")"
            local arr_slot="" pool_name="" k
            for k in "${!MOUNT_TO_DEV[@]}"; do
                if [[ "$k" == /mnt/disk* ]]; then
                    local mdev
                    mdev="${MOUNT_TO_DEV[$k]}"
                    local bmdev
                    bmdev="$(base_device "$mdev")"
                    if [[ "$bmdev" == "$base" ]]; then arr_slot="$(basename "$k")"; break; fi
                fi
            done
            if [[ -n "${POOL_MEMBER_MAP[$base]:-}" ]]; then pool_name="${POOL_MEMBER_MAP[$base]}"; fi
            local tag
            if [[ -n "$arr_slot" ]]; then tag="$arr_slot [$(basename "$base")]"; elif [[ -n "$pool_name" ]]; then tag="$pool_name [$(basename "$base")]"; else tag="$(basename "$base")"; fi
            local model_suffix
            model_suffix="$(model_suffix_for "$base")"
            [[ -n "${SEEN_REC_DEVICES[$base]:-}" ]] && continue
            if [[ $raw_msg == *"NVMe error log entries increased"* ]]; then
                rec+=" - $tag$model_suffix: NVMe error log growth; monitor escalation; update firmware; backup & plan replacement if growth persists.\n"; SEEN_REC_DEVICES[$base]=1; continue
            fi
            if [[ $raw_msg == *"NVMe PCIe correctable errors increased"* ]]; then
                rec+=" - $tag$model_suffix: Rising NVMe PCIe correctable errors; inspect slot/backplane, reseat, verify cooling, monitor for uncorrectable events.\n"; SEEN_REC_DEVICES[$base]=1; continue
            fi
            if [[ $raw_msg == *"NVMe PCIe uncorrectable errors increased"* ]]; then
                rec+=" - $tag$model_suffix: NVMe PCIe uncorrectable errors; immediate backup and migrate workload; replace device / inspect controller.\n"; SEEN_REC_DEVICES[$base]=1; continue
            fi
            if [[ $raw_msg == *"NVMe thermal transitions T2 increased"* ]]; then
                rec+=" - $tag$model_suffix: NVMe critical thermal transitions; improve airflow, consider heatsink, reduce sustained heavy writes.\n"; SEEN_REC_DEVICES[$base]=1; continue
            fi
            if [[ $raw_msg == *"NVMe thermal transitions T1 increased"* ]]; then
                rec+=" - $tag$model_suffix: NVMe warning thermal transitions; optimize cooling before escalation.\n"; SEEN_REC_DEVICES[$base]=1; continue
            fi
            if [[ $raw_msg == *"NVMe warning temperature time"* ]]; then
                rec+=" - $tag$model_suffix: Accumulating NVMe time at warning temperature; improve cooling or distribute I/O load.\n"; SEEN_REC_DEVICES[$base]=1; continue
            fi
            if [[ $raw_msg == *"NVMe critical temperature time"* ]]; then
                rec+=" - $tag$model_suffix: NVMe time at critical temperature; throttle workloads and replace if persistent.\n"; SEEN_REC_DEVICES[$base]=1; continue
            fi
        done
        # Compute composite health score per device and prioritize alert ordering
        local rank_lines=()
        local dev
        for dev in "${!SMART_STATE[@]}"; do
            local st; st="${SMART_STATE[$dev]:-OK}"
            [[ "$st" == WARNING || "$st" == CRITICAL ]] || continue
            local base; base="$(base_device "$dev")"
            # SMART component (normalize to 0–100)
            local sm_raw sm_norm
            sm_raw="$(risk_score_quick "$st" "${SMART_MSGS[$dev]:-}")"
            [[ "$sm_raw" =~ ^[0-9]+$ ]] || sm_raw=0
            if (( sm_raw > 100 )); then sm_norm=100; else sm_norm=$sm_raw; fi
            # Apply burst boost (base device scope)
            local _burst_boost=${BURST_BOOST[$dev]:-${BURST_BOOST[$base]:-0}}
            if [[ "$_burst_boost" =~ ^[0-9]+$ && $_burst_boost -gt 0 ]]; then
                sm_norm=$(( sm_norm + _burst_boost ))
                (( sm_norm > 100 )) && sm_norm=100
            fi
            # Error component from I/O unique events (scaled against thresholds)
            local uniq; uniq="${IO_ERROR_UNIQUE_MAP[$dev]:-${IO_ERROR_UNIQUE_MAP[$base]:-0}}"
            [[ "$uniq" =~ ^[0-9]+$ ]] || uniq=0
            local err_norm
            if (( uniq >= ${IO_ERROR_CRIT_THRESHOLD:-20} )); then err_norm=100
            elif (( uniq >= ${IO_ERROR_WARN_THRESHOLD:-5} )); then err_norm=65
            else err_norm=$(awk -v u="$uniq" -v w="${IO_ERROR_WARN_THRESHOLD:-5}" 'BEGIN{ if(w>0) printf "%d", (u*50)/w; else print 0 }'); fi
            # Capacity pressure per disk mount (percent toward thresholds)
            local cap_norm=0
            local arr_slot=""
            local k
            for k in "${!MOUNT_TO_DEV[@]}"; do
                if [[ "$k" == /mnt/disk* ]]; then
                    local mdev bmdev
                    mdev="${MOUNT_TO_DEV[$k]}"; bmdev="$(base_device "$mdev")"
                    if [[ "$bmdev" == "$base" ]]; then arr_slot="$k"; break; fi
                fi
            done
            if [[ -n "$arr_slot" ]]; then
                local pct usep warn_t crit_t
                warn_t="${WARN_THRESHOLD_PERCENT:-75}"; crit_t="${CRITICAL_THRESHOLD_PERCENT:-90}"
                read -r _sz _u pct _mount < <(df -h --output=size,used,pcent,target "$arr_slot" 2>/dev/null | tail -n1)
                usep=${pct%%%}
                if [[ "$usep" =~ ^[0-9]+$ && $crit_t -gt $warn_t ]]; then
                    cap_norm=$(awk -v u="$usep" -v w="$warn_t" -v c="$crit_t" 'BEGIN{ x=u-w; d=c-w; if(d<=0){print 0}else{ if(x<0) x=0; if(x>d) x=d; printf "%d", int((x*100)/d) } }')
                fi
            fi
            # Weighted composite (0–100)
            local w_cap=20; local w_smart=60; local w_err=20; local total=$(( w_cap + w_smart + w_err )); local comp
            comp=$(awk -v c="$cap_norm" -v s="$sm_norm" -v e="$err_norm" -v wc="$w_cap" -v ws="$w_smart" -v we="$w_err" -v t="$total" 'BEGIN{ printf "%d", int((wc*c + ws*s + we*e)/t) }')
            rank_lines+=("$comp\t$dev\t$base")
        done
        # Sort by composite score descending and emit prioritized SMART alerts
        if (( ${#rank_lines[@]} > 0 )); then
            local sorted line comp_score s_dev s_base
            sorted=$(printf "%s\n" "${rank_lines[@]}" | sort -nr -k1,1)
            while IFS=$'\t' read -r comp_score s_dev s_base; do
                [[ -n "${SEEN_REC_DEVICES[$s_base]:-}" ]] && continue
                local st; st="${SMART_STATE[$s_dev]:-OK}"
                local arr_slot=""; local pool_name=""; local k
                for k in "${!MOUNT_TO_DEV[@]}"; do
                    if [[ "$k" == /mnt/disk* ]]; then
                        local mdev bmdev
                        mdev="${MOUNT_TO_DEV[$k]}"; bmdev="$(base_device "$mdev")"
                        if [[ "$bmdev" == "$s_base" ]]; then arr_slot="$(basename "$k")"; break; fi
                    fi
                done
                if [[ -n "${POOL_MEMBER_MAP[$s_base]:-}" ]]; then pool_name="${POOL_MEMBER_MAP[$s_base]}"; fi
                local tag model_suffix raw_msg inline_msg
                if [[ -n "$arr_slot" ]]; then tag="$arr_slot [$(basename "$s_base")]"; elif [[ -n "$pool_name" ]]; then tag="$pool_name [$(basename "$s_base")]"; else tag="$(basename "$s_base")"; fi
                model_suffix="$(model_suffix_for "$s_base")"
                raw_msg="${SMART_MSGS[$s_dev]:-}"; inline_msg="$(sanitize_smart_for_inline "$raw_msg" 1)"
                if [[ "$st" == CRITICAL ]]; then
                    rec+=" - $tag$model_suffix: SMART CRITICAL — ${inline_msg:-review SMART details}; backup immediately and replace. (priority ${comp_score})\n"
                else
                    if [[ -n "${LONG_TEST_RUNNING_LONG[$s_dev]:-}" ]]; then
                        rec+=" - $tag$model_suffix: SMART WARNING — ${inline_msg:-review SMART details}; long SMART test currently in progress; monitor results before planning replacement. (priority ${comp_score})\n"
                    else
                        rec+=" - $tag$model_suffix: SMART WARNING — ${inline_msg:-review SMART details}; run a long SMART test, monitor, and plan replacement if it worsens. (priority ${comp_score})\n"
                    fi
                fi
                SEEN_REC_DEVICES["$s_base"]=1
            done <<< "$sorted"
        fi
    fi
    # If parity operation is active (non-idle), prefer in-progress guidance and suppress invalid
    local _act_lc="" _pos_cf="${PARITY_POS:-}" _size_cf="${PARITY_SIZE:-}" _rem_cf="${PARITY_REM:-}" _spk_cf="${PARITY_SPEED_K:-}"
    if [[ -n "${PARITY_ACTION:-}" ]]; then _act_lc=$(printf "%s" "${PARITY_ACTION}" | awk '{print tolower($1)}'); fi
    if [[ -n "${_act_lc}" && "${_act_lc}" != "idle" ]]; then
        local _active_cf=0
        if [[ "$_spk_cf" =~ ^[0-9]+$ && $((10#$_spk_cf)) -gt 0 ]]; then _active_cf=1
        elif [[ "$_rem_cf" =~ ^[0-9]+$ && $((10#$_rem_cf)) -gt 0 ]]; then _active_cf=1
        elif [[ "$_pos_cf" =~ ^[0-9]+$ && "$_size_cf" =~ ^[0-9]+$ && $((10#$_pos_cf)) -gt 0 && $((10#$_pos_cf)) -lt $((10#$_size_cf)) ]]; then _active_cf=1
        fi
        if (( _active_cf == 1 )); then
            local _corr_lbl; _corr_lbl=$([[ "${PARITY_CORR:-}" == "1" ]] && echo "correcting" || echo "non-correcting")
            rec+=" - Parity: in progress (${_corr_lbl}); capacity forecast and write metrics may be skewed; defer interpretation and re-check after completion.\n"
        fi
    else
        if [[ "${PARITY_CLEAN_FLAG:-1}" == "0" ]]; then
            rec+=" - Parity: invalid; run non-correcting parity check first (investigate recent SMART pending/reallocated/uncorrectable deltas), then correcting if errors found.\n"
        fi
    fi
    HEALTH_ALERTS_SECTION="$rec"
    if [[ -n "${HEALTH_ALERTS_SECTION:-}" ]]; then
        HEALTH_ALERTS_SECTION="$(printf "%s\n" "$HEALTH_ALERTS_SECTION" | trim_outer_blank_lines)"
    else
        # Provide a default informational message when no health alerts were generated
        HEALTH_ALERTS_SECTION="Health Alerts:\n - None detected; all monitored disks and filesystems nominal."
    fi
    # Integrate NVMe wear projection guidance (warn/critical only) if arrays populated
    if declare -p NVME_WEAR_DAYS_LEFT &>/dev/null && declare -p NVME_WEAR_RATE &>/dev/null; then
        local guid_added=0
        local dev dl rate
        local _wear_rank=()
        local warn_thr="${WEAR_DAYS_LEFT_WARN:-0}"
        local crit_thr="${WEAR_DAYS_LEFT_CRIT:-0}"
        for dev in "${!NVME_WEAR_DAYS_LEFT[@]}"; do
            dl=${NVME_WEAR_DAYS_LEFT[$dev]}
            rate=${NVME_WEAR_RATE[$dev]:-0}
            [[ "$dl" =~ ^[0-9]+$ ]] || continue  # skip INF stable devices (exclude from alerts section)
            local base model_suffix
            base="$(basename "$dev")"
            model_suffix="$(model_suffix_for "$(base_device "$dev")")"
            local base_dev
            base_dev="$(base_device "$dev")"
            # Composite score (SMART + I/O error + capacity)
            local st sm_raw sm_norm uniq err_norm cap_norm=0 arr_slot="" k
            st="${SMART_STATE[$dev]:-OK}"
            sm_raw="$(risk_score_quick "$st" "${SMART_MSGS[$dev]:-}")"; [[ "$sm_raw" =~ ^[0-9]+$ ]] || sm_raw=0
            sm_norm=$(( sm_raw > 100 ? 100 : sm_raw ))
                        # Burst boost (NVMe wear guidance)
                        local _burst_boost=${BURST_BOOST[$dev]:-${BURST_BOOST[$base_dev]:-0}}
                        if [[ "$_burst_boost" =~ ^[0-9]+$ && $_burst_boost -gt 0 ]]; then
                            sm_norm=$(( sm_norm + _burst_boost ))
                            (( sm_norm > 100 )) && sm_norm=100
                        fi
            uniq="${IO_ERROR_UNIQUE_MAP[$dev]:-${IO_ERROR_UNIQUE_MAP[$base_dev]:-0}}"; [[ "$uniq" =~ ^[0-9]+$ ]] || uniq=0
            if (( uniq >= ${IO_ERROR_CRIT_THRESHOLD:-20} )); then err_norm=100
            elif (( uniq >= ${IO_ERROR_WARN_THRESHOLD:-5} )); then err_norm=65
            else err_norm=$(awk -v u="$uniq" -v w="${IO_ERROR_WARN_THRESHOLD:-5}" 'BEGIN{ if(w>0) printf "%d", (u*50)/w; else print 0 }'); fi
            for k in "${!MOUNT_TO_DEV[@]}"; do
                if [[ "$k" == /mnt/disk* ]]; then
                    local mdev bmdev
                    mdev="${MOUNT_TO_DEV[$k]}"; bmdev="$(base_device "$mdev")"
                    if [[ "$bmdev" == "$base_dev" ]]; then arr_slot="$k"; break; fi
                fi
            done
            if [[ -n "$arr_slot" ]]; then
                local pct usep warn_t crit_t
                warn_t="${WARN_THRESHOLD_PERCENT:-96}"; crit_t="${CRITICAL_THRESHOLD_PERCENT:-98}"
                read -r _sz _u pct _mount < <(df -h --output=size,used,pcent,target "$arr_slot" 2>/dev/null | tail -n1)
                usep=${pct%%%}
                if [[ "$usep" =~ ^[0-9]+$ && $crit_t -gt $warn_t ]]; then
                    cap_norm=$(awk -v u="$usep" -v w="$warn_t" -v c="$crit_thr" 'BEGIN{ x=u-w; d=c-w; if(d<=0){print 0}else{ if(x<0) x=0; if(x>d) x=d; printf "%d", int((x*100)/d) } }')
                fi
            fi
            local w_cap=20; local w_smart=60; local w_err=20; local total=$(( w_cap + w_smart + w_err )); local comp
            comp=$(awk -v c="$cap_norm" -v s="$sm_norm" -v e="$err_norm" -v wc="$w_cap" -v ws="$w_smart" -v we="$w_err" -v t="$total" 'BEGIN{ printf "%d", int((wc*c + ws*s + we*e)/t) }')
            if (( crit_thr>0 && dl <= crit_thr )); then
                _wear_rank+=("$comp\t${base}${model_suffix}\tCRIT\t${dl}\t${crit_thr}\t${rate}")
                guid_added=1
            elif (( warn_thr>0 && dl <= warn_thr )); then
                _wear_rank+=("$comp\t${base}${model_suffix}\tWARN\t${dl}\t${warn_thr}\t${rate}")
                guid_added=1
            fi
        done
        if (( ${#_wear_rank[@]} > 0 )); then
            local sorted_w
            sorted_w=$(printf "%s\n" "${_wear_rank[@]}" | sort -nr -k1,1)
            while IFS=$'\t' read -r comp_score tag sev dl thr rate; do
                if [[ "$sev" == "CRIT" ]]; then
                    HEALTH_ALERTS_SECTION+="\n - ${tag}: NVMe wear projected depletion ${dl}d <= ${thr}d; backup & replace scheduling now (rate ${rate}%/d). (priority ${comp_score})"
                else
                    HEALTH_ALERTS_SECTION+="\n - ${tag}: NVMe wear projected depletion ${dl}d <= ${thr}d; plan replacement window (rate ${rate}%/d). (priority ${comp_score})"
                fi
            done <<< "$sorted_w"
        fi
        # Optionally show soonest depletion if no individual entries added but projections exist
        if (( guid_added==0 )) && (( warn_thr>0 || crit_thr>0 )); then
            # Compute soonest numeric dl among devices for contextual monitoring
            local min_dl=999999
            local min_dev=""
            local min_rate=""
            for dev in "${!NVME_WEAR_DAYS_LEFT[@]}"; do
                dl=${NVME_WEAR_DAYS_LEFT[$dev]} ; [[ "$dl" =~ ^[0-9]+$ ]] || continue
                if (( dl < min_dl )); then min_dl=$dl; min_dev="$dev"; min_rate=${NVME_WEAR_RATE[$dev]:-0}; fi
            done
            if (( min_dl < 999999 )); then
                local base model_suffix
                base="$(basename "$min_dev")"
                model_suffix="$(model_suffix_for "$(base_device "$min_dev")")"
                HEALTH_ALERTS_SECTION+="\n - ${base}${model_suffix}: NVMe wear projection earliest depletion ~${min_dl}d (rate ${min_rate}%/d); monitor trend."
            fi
        fi
    fi
    # Add heavy writer guidance (tiers) based on weekly percent arrays, ranked by composite priority
    if declare -p WRITER_WEEKLY_PCT &>/dev/null && declare -p WRITER_TIER &>/dev/null; then
        local dev w tier
        local _hw_rank=()
        for dev in "${!WRITER_WEEKLY_PCT[@]}"; do
            w=${WRITER_WEEKLY_PCT[$dev]:-0}
            tier=${WRITER_TIER[$dev]:-}
            # Only consider Heavy tier (warning/critical)
            if [[ "$tier" == "H" ]]; then
                # Normalize writer intensity (0-100)
                local writer_norm
                if awk -v ww="$w" -v c="$WRITER_WEEKLY_CRIT_PCT" 'BEGIN{exit (ww>=c)?0:1}'; then
                    writer_norm=100
                elif awk -v ww="$w" -v wthr="$WRITER_WEEKLY_WARN_PCT" 'BEGIN{exit (ww>=wthr)?0:1}'; then
                    writer_norm=65
                else
                    writer_norm=$(awk -v ww="$w" -v wthr="$WRITER_WEEKLY_WARN_PCT" 'BEGIN{ if(wthr>0) printf "%d", int((ww*50)/wthr); else print 0 }')
                fi
                # SMART-based quick risk component + burst boost
                local st sm_raw sm_norm base_dev
                st="${SMART_STATE[$dev]:-OK}"
                sm_raw="$(risk_score_quick "$st" "${SMART_MSGS[$dev]:-}")"; [[ "$sm_raw" =~ ^[0-9]+$ ]] || sm_raw=0
                sm_norm=$(( sm_raw > 100 ? 100 : sm_raw ))
                base_dev="$(base_device "$dev")"
                local _burst_boost=${BURST_BOOST[$dev]:-${BURST_BOOST[$base_dev]:-0}}
                if [[ "$_burst_boost" =~ ^[0-9]+$ && $_burst_boost -gt 0 ]]; then
                    sm_norm=$(( sm_norm + _burst_boost ))
                    (( sm_norm > 100 )) && sm_norm=100
                fi
                # I/O error unique event component
                local uniq err_norm
                uniq="${IO_ERROR_UNIQUE_MAP[$dev]:-${IO_ERROR_UNIQUE_MAP[$base_dev]:-0}}"; [[ "$uniq" =~ ^[0-9]+$ ]] || uniq=0
                if (( uniq >= ${IO_ERROR_CRIT_THRESHOLD:-20} )); then err_norm=100
                elif (( uniq >= ${IO_ERROR_WARN_THRESHOLD:-5} )); then err_norm=65
                else err_norm=$(awk -v u="$uniq" -v w="${IO_ERROR_WARN_THRESHOLD:-5}" 'BEGIN{ if(w>0) printf "%d", int((u*50)/w); else print 0 }'); fi
                # Composite score (writer weighted)
                local comp
                comp=$(awk -v wn="$writer_norm" -v s="$sm_norm" -v e="$err_norm" 'BEGIN{ printf "%d", int((2*wn + s + e)/4) }')
                local tag model_suffix
                tag="$(basename "$dev")"; model_suffix="$(model_suffix_for "$base_dev")"
                _hw_rank+=("$comp\t${tag}${model_suffix}\t$w")
            fi
        done
        if (( ${#_hw_rank[@]} > 0 )); then
            local sorted_hw
            sorted_hw=$(printf "%s\n" "${_hw_rank[@]}" | sort -nr -k1,1)
            while IFS=$'\t' read -r comp_score tag ww; do
                if awk -v ww="$ww" -v c="$WRITER_WEEKLY_CRIT_PCT" 'BEGIN{exit (ww>=c)?0:1}'; then
                    HEALTH_ALERTS_SECTION+="\n - ${tag}: Extremely heavy write rate ~$(awk -v w=\""$ww"\" 'BEGIN{printf \"%.2f\", w}')% cap/week; redistribute workloads, review logging, expect accelerated wear. (priority ${comp_score})"
                else
                    HEALTH_ALERTS_SECTION+="\n - ${tag}: Heavy write rate ~$(awk -v w=\""$ww"\" 'BEGIN{printf \"%.2f\", w}')% cap/week; monitor and consider moving high-churn data to lower-tier media. (priority ${comp_score})"
                fi
            done <<< "$sorted_hw"
        else
            # Optional single monitoring line for top writer if no heavy thresholds crossed
            local top_dev="" top_w=0
            for dev in "${!WRITER_WEEKLY_PCT[@]}"; do
                w=${WRITER_WEEKLY_PCT[$dev]:-0}
                if awk -v w="$w" -v tw="$top_w" 'BEGIN{exit (w>tw)?0:1}'; then top_w=$w; top_dev=$dev; fi
            done
            if [[ -n "$top_dev" ]]; then
                local base model_suffix
                base="$(basename "$top_dev")"; model_suffix="$(model_suffix_for "$(base_device "$top_dev")")"
                HEALTH_ALERTS_SECTION+="\n - ${base}${model_suffix}: Top writer ~$(awk -v w="$top_w" 'BEGIN{printf "%.2f", w}')% cap/week; currently below heavy thresholds."
            fi
        fi
    fi
    # Dynamic long SMART test scheduling guidance (accelerated after recent risk spike)
    if declare -p RISK_SPIKE_TS &>/dev/null; then
        local accel_factor base_days lookback min_days now_ts
        accel_factor=${LONG_TEST_ACCEL_FACTOR:-2}
        base_days=${LONG_TEST_MAX_INTERVAL_DAYS:-90}
        lookback=${LONG_TEST_RISK_LOOKBACK_DAYS:-14}
        min_days=${LONG_TEST_MIN_INTERVAL_DAYS:-30}
        now_ts=$(date +%s)
        local _lt_rank=()
        local dev
        for dev in "${!RISK_SPIKE_TS[@]}"; do
            local spike_ts age_days
            spike_ts=${RISK_SPIKE_TS[$dev]:-0}
            [[ $spike_ts =~ ^[0-9]+$ ]] || continue
            age_days=$(( (now_ts - spike_ts) / 86400 ))
            (( age_days < 0 )) && continue
            (( age_days <= lookback )) || continue
            # Composite score per device
            local st sm_raw sm_norm uniq err_norm cap_norm=0 arr_slot="" k base_dev
            st="${SMART_STATE[$dev]:-OK}"
            sm_raw="$(risk_score_quick "$st" "${SMART_MSGS[$dev]:-}")"; [[ "$sm_raw" =~ ^[0-9]+$ ]] || sm_raw=0
            sm_norm=$(( sm_raw > 100 ? 100 : sm_raw ))
            base_dev="$(base_device "$dev")"
            # Burst boost (long test guidance)
            local _burst_boost=${BURST_BOOST[$dev]:-${BURST_BOOST[$base_dev]:-0}}
                        if [[ "$_burst_boost" =~ ^[0-9]+$ && $_burst_boost -gt 0 ]]; then
                            sm_norm=$(( sm_norm + _burst_boost ))
                            (( sm_norm > 100 )) && sm_norm=100
                        fi
            # base_dev already set above
            uniq="${IO_ERROR_UNIQUE_MAP[$dev]:-${IO_ERROR_UNIQUE_MAP[$base_dev]:-0}}"; [[ "$uniq" =~ ^[0-9]+$ ]] || uniq=0
            if (( uniq >= ${IO_ERROR_CRIT_THRESHOLD:-20} )); then err_norm=100
            elif (( uniq >= ${IO_ERROR_WARN_THRESHOLD:-5} )); then err_norm=65
            else err_norm=$(awk -v u="$uniq" -v w="${IO_ERROR_WARN_THRESHOLD:-5}" 'BEGIN{ if(w>0) printf "%d", (u*50)/w; else print 0 }'); fi
            for k in "${!MOUNT_TO_DEV[@]}"; do
                if [[ "$k" == /mnt/disk* ]]; then
                    local mdev bmdev
                    mdev="${MOUNT_TO_DEV[$k]}"; bmdev="$(base_device "$mdev")"
                    if [[ "$bmdev" == "$base_dev" ]]; then arr_slot="$k"; break; fi
                fi
            done
            if [[ -n "$arr_slot" ]]; then
                local pct usep warn_t crit_t
                warn_t="${WARN_THRESHOLD_PERCENT:-96}"; crit_t="${CRITICAL_THRESHOLD_PERCENT:-98}"
                read -r _sz _u pct _mount < <(df -h --output=size,used,pcent,target "$arr_slot" 2>/dev/null | tail -n1)
                usep=${pct%%%}
                if [[ "$usep" =~ ^[0-9]+$ && $crit_t -gt $warn_t ]]; then
                    cap_norm=$(awk -v u="$usep" -v w="$warn_t" -v c="$crit_t" 'BEGIN{ x=u-w; d=c-w; if(d<=0){print 0}else{ if(x<0) x=0; if(x>d) x=d; printf "%d", int((x*100)/d) } }')
                fi
            fi
            local w_cap=20; local w_smart=60; local w_err=20; local total=$(( w_cap + w_smart + w_err )); local comp
            comp=$(awk -v c="$cap_norm" -v s="$sm_norm" -v e="$err_norm" -v wc="$w_cap" -v ws="$w_smart" -v we="$w_err" -v t="$total" 'BEGIN{ printf "%d", int((wc*c + ws*s + we*e)/t) }')
            local accel_days recommend_date base_short model_suffix
            accel_days=$(( base_days / accel_factor )); (( accel_days < min_days )) && accel_days=$min_days
            recommend_date=$(date -d "+${accel_days} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
            base_short="$(basename "$dev")"; model_suffix="$(model_suffix_for "$(base_device "$dev")")"
            _lt_rank+=("$comp\t${base_short}${model_suffix}\t${recommend_date}\t${age_days}\t${accel_days}")
        done
        if (( ${#_lt_rank[@]} > 0 )); then
            local sorted_lt
            sorted_lt=$(printf "%s\n" "${_lt_rank[@]}" | sort -nr -k1,1)
            while IFS=$'\t' read -r comp_score tag rec_date age_days accel_days; do
                HEALTH_ALERTS_SECTION+="\n - ${tag}: Accelerate next long SMART test to ${rec_date} (risk spike ${age_days}d ago; interval ~${accel_days}d vs base ${base_days}d). (priority ${comp_score})"
            done <<< "$sorted_lt"
        fi
    fi
}

# === Main Function ===
# Build non-critical trend / advisory analytics section
build_trend_section() {
    # Temperature Evolution subsection
    if [[ -f "${TEMP_HISTORY_FILE}" ]]; then
        local temp_win=${TEMP_TREND_WINDOW_DAYS:-14}
        local now_ts
        now_ts=$(date +%s)
        local cut_ts=$(( now_ts - temp_win*86400 ))
        declare -A TT_MIN TT_MAX TT_SUM TT_CNT TT_FIRST TT_LAST TT_FIRST_TS TT_LAST_TS
        while read -r line; do
            [[ -z "$line" ]] && continue
            local dt dev tmp crit ts
            dt=$(awk '{print $1}' <<<"$line")
            dev=$(awk '{print $2}' <<<"$line")
            tmp=$(awk '{print $3}' <<<"$line")
            crit=$(awk '{print $4}' <<<"$line")
            [[ -z "$dt" || -z "$dev" || -z "$tmp" ]] && continue
            ts=$(date -d "$dt" +%s 2>/dev/null || echo 0)
            (( ts >= cut_ts )) || continue
            [[ "$tmp" =~ ^[0-9]+$ ]] || continue
            if [[ -z "${TT_MIN[$dev]}" || "${TT_MIN[$dev]}" -gt "$tmp" ]]; then TT_MIN[$dev]="$tmp"; fi
            if [[ -z "${TT_MAX[$dev]}" || "${TT_MAX[$dev]}" -lt "$tmp" ]]; then TT_MAX[$dev]="$tmp"; fi
            TT_SUM[$dev]=$(( ${TT_SUM[$dev]:-0} + tmp ))
            TT_CNT[$dev]=$(( ${TT_CNT[$dev]:-0} + 1 ))
            if [[ -z "${TT_FIRST[$dev]}" ]]; then TT_FIRST[$dev]="$tmp"; TT_FIRST_TS[$dev]="$ts"; fi
            TT_LAST[$dev]="$tmp"; TT_LAST_TS[$dev]="$ts"
        done < "${TEMP_HISTORY_FILE}"
        local tdev
        for tdev in "${!TT_CNT[@]}"; do
            local rise rate days
            if [[ -n "${TT_FIRST[$tdev]}" && -n "${TT_LAST[$tdev]}" ]]; then
                rise=$(( ${TT_LAST[$tdev]} - ${TT_FIRST[$tdev]} ))
            else
                rise=0
            fi
            rate="0.0"; days=0
            if [[ -n "${TT_FIRST_TS[$tdev]}" && -n "${TT_LAST_TS[$tdev]}" ]]; then
                local span
                span=$(( ${TT_LAST_TS[$tdev]} - ${TT_FIRST_TS[$tdev]} ))
                if (( span > 0 )); then
                    days=$(awk -v s="$span" 'BEGIN{printf "%.2f", s/86400.0}')
                    rate=$(awk -v r="$rise" -v d="$days" 'BEGIN{ if(d>0) printf "%.2f", r/d; else print "0.0" }')
                fi
            fi
            if (( TEMP_RATE_ALERT_ENABLED == 1 )) && [[ -n "$rate" && "$days" != "0.00" ]]; then
                if (( 10#${days%.*} >= TEMP_RATE_MIN_SPAN_DAYS )); then
                    local rate_int
                    rate_int="${rate%.*}"
                    if (( rate_int >= TEMP_RATE_CRIT_C_PER_DAY )); then
                        record_alert critical "Temperature Rate" "$(basename "$tdev") rising +${rise}C over ${days}d (~${rate}C/day)"
                    elif (( rate_int >= TEMP_RATE_WARN_C_PER_DAY )); then
                        record_alert warning "Temperature Rate" "$(basename "$tdev") rising +${rise}C over ${days}d (~${rate}C/day)"
                    fi
                fi
            fi
        done
        # Build ranked temperature rate guidance lines (composite priority)
        if (( TEMP_RATE_ALERT_ENABLED == 1 )); then
            local _tr_rank=()
            for tdev in "${!TT_CNT[@]}"; do
                # Recompute rise/rate/days for ranking using cached TT_* maps
                local rise rate days
                rise=$(( ${TT_LAST[$tdev]:-0} - ${TT_FIRST[$tdev]:-0} ))
                days=0
                if [[ -n "${TT_FIRST_TS[$tdev]}" && -n "${TT_LAST_TS[$tdev]}" ]]; then
                    local span
                    span=$(( ${TT_LAST_TS[$tdev]} - ${TT_FIRST_TS[$tdev]} ))
                    if (( span > 0 )); then
                        days=$(awk -v s="$span" 'BEGIN{printf "%.2f", s/86400.0}')
                        rate=$(awk -v r="$rise" -v d="$days" 'BEGIN{ if(d>0) printf "%.2f", r/d; else print "0.0" }')
                    else
                        rate="0.0"
                    fi
                else
                    rate="0.0"
                fi
                [[ "$days" == "0.00" ]] && continue
                local rate_int
                rate_int="${rate%.*}"
                # Only include warn/crit
                if (( rate_int >= TEMP_RATE_WARN_C_PER_DAY )); then
                    # Normalize rate severity (0-100)
                    local rate_norm
                    if (( rate_int >= TEMP_RATE_CRIT_C_PER_DAY )); then rate_norm=100
                    else rate_norm=$(awk -v r="$rate_int" -v w="$TEMP_RATE_WARN_C_PER_DAY" 'BEGIN{ if(w>0) printf "%d", int((r*65)/w); else print 0 }'); fi
                    # SMART + I/O error components
                    local st sm_raw sm_norm base_dev uniq err_norm
                    base_dev="$(base_device "$tdev")"
                    st="${SMART_STATE[$tdev]:-${SMART_STATE[$base_dev]:-OK}}"
                    sm_raw="$(risk_score_quick "$st" "${SMART_MSGS[$tdev]:-${SMART_MSGS[$base_dev]:-}}")"; [[ "$sm_raw" =~ ^[0-9]+$ ]] || sm_raw=0
                    sm_norm=$(( sm_raw > 100 ? 100 : sm_raw ))
                                        # Burst boost (temperature rate guidance)
                                        local _burst_boost=${BURST_BOOST[$tdev]:-${BURST_BOOST[$base_dev]:-0}}
                                        if [[ "$_burst_boost" =~ ^[0-9]+$ && $_burst_boost -gt 0 ]]; then
                                            sm_norm=$(( sm_norm + _burst_boost ))
                                            (( sm_norm > 100 )) && sm_norm=100
                                        fi
                    uniq="${IO_ERROR_UNIQUE_MAP[$tdev]:-${IO_ERROR_UNIQUE_MAP[$base_dev]:-0}}"; [[ "$uniq" =~ ^[0-9]+$ ]] || uniq=0
                    if (( uniq >= ${IO_ERROR_CRIT_THRESHOLD:-20} )); then err_norm=100
                    elif (( uniq >= ${IO_ERROR_WARN_THRESHOLD:-5} )); then err_norm=65
                    else err_norm=$(awk -v u="$uniq" -v w="${IO_ERROR_WARN_THRESHOLD:-5}" 'BEGIN{ if(w>0) printf "%d", int((u*50)/w); else print 0 }'); fi
                    # Composite score (rate weighted)
                    local comp tag model_suffix
                    comp=$(awk -v rn="$rate_norm" -v s="$sm_norm" -v e="$err_norm" 'BEGIN{ printf "%d", int((2*rn + s + e)/4) }')
                    tag="$(basename "$tdev")"; model_suffix="$(model_suffix_for "$base_dev")"
                    _tr_rank+=("$comp\t${tag}${model_suffix}\t${rise}\t${days}\t${rate}")
                fi
            done
            if (( ${#_tr_rank[@]} > 0 )); then
                local sorted_tr
                sorted_tr=$(printf "%s\n" "${_tr_rank[@]}" | sort -nr -k1,1)
                while IFS=$'\t' read -r comp_score tag rise days rate; do
                    HEALTH_ALERTS_SECTION+=$"\n - ${tag}: Temperature rising +${rise}C over ${days}d (~${rate}C/day). (priority ${comp_score})"
                done <<< "$sorted_tr"
            fi
        fi
    fi
    # Trend-derived early warnings (growth acceleration, thermal exposure, heavy writers, endurance)
    declare -g DL_SHRINK_LINE EARLY_ERR_LINE BTRFS_SUM_LINE SMART_GROWTH_LINE POH_GROWTH_LINE
    DL_SHRINK_LINE=""; EARLY_ERR_LINE=""; BTRFS_SUM_LINE=""; SMART_GROWTH_LINE=""; POH_GROWTH_LINE=""
    # SMART attribute growth trend computation
    if (( SMART_ATTR_TREND_ENABLED == 1 )); then
        declare -A SMARTG_CODES=() SMARTG_SCORE=()
        local win_attr=${SMART_ATTR_TREND_WINDOW_DAYS:-7}
        local cutoff_attr
        cutoff_attr=$(date -d "-${win_attr} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
        declare -A first_line_attr last_line_attr first_dt_attr last_dt_attr
        if [[ -f "$SMART_ATTR_HISTORY_FILE" ]]; then
            local lines_attr
            lines_attr=$(tail -n 50000 "$SMART_ATTR_HISTORY_FILE" 2>/dev/null || true)
            if [[ -n "$lines_attr" ]]; then
                local tmp_attr
                tmp_attr=$(mktemp) || { log_warn "mktemp failed; skipping SMART attribute trend block"; tmp_attr=""; }
                if [[ -n "$tmp_attr" ]]; then
                    printf "%s\n" "$lines_attr" | awk -v c="$cutoff_attr" '$1>=c' > "$tmp_attr"
                while read -r dt dev rest; do
                    [[ -z "$dt" || -z "$dev" ]] && continue
                    if [[ -z "${first_dt_attr[$dev]:-}" || "$dt" < "${first_dt_attr[$dev]}" ]]; then first_dt_attr[$dev]="$dt"; first_line_attr[$dev]="$rest"; fi
                    if [[ -z "${last_dt_attr[$dev]:-}" || "$dt" > "${last_dt_attr[$dev]}" ]]; then last_dt_attr[$dev]="$dt"; last_line_attr[$dev]="$rest"; fi
                done < "$tmp_attr"
                rm -f "$tmp_attr"
                else
                    # Without tmp, skip SMART attribute trend computation
                    :
                fi
                local min_delta_attr=${SMART_ATTR_TREND_MIN_DELTA:-1}
                local attrs_attr=(realloc pending reported_uncorr offunc cmd_timeout realloc_events udma soft_read_err nvme_percent_used unsafe_shutdowns media_errors err_logs pcie_corr pcie_unc therm_t1 therm_t2 warn_temp_time crit_temp_time tbw_bytes)
                for dev in "${!last_line_attr[@]}"; do
                    local f="${first_line_attr[$dev]}" l="${last_line_attr[$dev]}"
                    declare -A fv_attr lv_attr
                    for token in $f; do k=${token%%=*}; v=${token#*=}; fv_attr[$k]="$v"; done
                    for token in $l; do k=${token%%=*}; v=${token#*=}; lv_attr[$k]="$v"; done
                    local show_attr=0 hv_writer_flag=0 pcie_corr_low_flag=0 wear_delta=0 tbw_delta=0 media_growth_flag=0 warn_temp_delta=0 crit_temp_delta=0 therm_warn=0 therm_crit=0 unsafe_low=0
                    for a in "${attrs_attr[@]}"; do
                        local sv=${fv_attr[$a]:-} ev=${lv_attr[$a]:-}
                        [[ -z "$sv" || -z "$ev" ]] && continue
                        if [[ "$sv" =~ ^[0-9]+(\.[0-9]+)?$ && "$ev" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                            local delta
                            delta=$(awk -v s="$sv" -v e="$ev" 'BEGIN{printf "%.2f", e-s}')
                            if awk -v d="$delta" -v m="$min_delta_attr" 'BEGIN{exit (d>=m)?0:1}'; then
                                show_attr=1
                                case "$a" in
                                    nvme_percent_used) wear_delta="$delta" ;;
                                    unsafe_shutdowns) if [[ $delta =~ ^[0-9]+$ ]] && (( 10#${delta%.*} > 0 && 10#${delta%.*} < ${UNSAFE_SDWN_DELTA_WARN:-999999} )); then unsafe_low=1; fi ;;
                                    pcie_corr) if [[ $delta =~ ^[0-9]+$ ]] && (( 10#${delta%.*} > 0 && 10#${delta%.*} < ${NVME_PCIE_CORR_DELTA_WARN:-999999} )); then pcie_corr_low_flag=1; fi ;;
                                    media_errors) if [[ $delta =~ ^[0-9]+(\.[0-9]+)?$ && ! $delta =~ ^0+(\.0+)?$ ]]; then media_growth_flag=1; fi ;;
                                    therm_t1) if [[ $delta =~ ^[0-9]+(\.[0-9]+)?$ && ! $delta =~ ^0+(\.0+)?$ ]]; then therm_warn=1; fi ;;
                                    therm_t2) if [[ $delta =~ ^[0-9]+(\.[0-9]+)?$ && ! $delta =~ ^0+(\.0+)?$ ]]; then therm_crit=1; fi ;;
                                    warn_temp_time) warn_temp_delta="$delta" ;;
                                    crit_temp_time) crit_temp_delta="$delta" ;;
                                    tbw_bytes) tbw_delta="$delta" ;;
                                esac
                            fi
                        fi
                    done
                    (( show_attr == 0 )) && continue
                    if [[ -n "$tbw_delta" ]] && [[ $tbw_delta =~ ^[0-9]+$ ]] && (( tbw_delta >= 500000000000 )); then hv_writer_flag=1; fi
                    local base tag model_suffix disk codes="" score=0
                    disk="$dev"; base="$(base_device "$disk")"; tag="$(basename "$base")"; model_suffix="$(model_suffix_for "$base")"
                    (( hv_writer_flag )) && { codes+="HVW "; ((score++)); }
                    if [[ -n "$wear_delta" ]] && (( 10#${wear_delta%.*} >= 1 )); then
                        local current_wear="${CUR_ATTR["$disk|nvme_percent_used"]:-0}"
                        if [[ $current_wear =~ ^[0-9]+$ ]] && (( current_wear < NVME_PERCENT_USED_WARN )); then
                            codes+="W+${wear_delta}% "; ((score++))
                        fi
                    fi
                    (( unsafe_low )) && { codes+="US "; ((score++)); }
                    (( pcie_corr_low_flag )) && { codes+="PCIE "; ((score++)); }
                    (( media_growth_flag )) && { codes+="MEDIA "; ((score++)); }
                    (( therm_warn )) && { codes+="T1 "; ((score++)); }
                    (( therm_crit )) && { codes+="T2 "; ((score++)); }
                    if [[ -n "$warn_temp_delta" ]] && (( 10#${warn_temp_delta%.*} > 0 )); then codes+="WT+${warn_temp_delta}s "; ((score++)); fi
                    if [[ -n "$crit_temp_delta" ]] && (( 10#${crit_temp_delta%.*} > 0 )); then codes+="CT+${crit_temp_delta}s "; ((score++)); fi
                    if [[ -n "${AGE_CLASS[$disk]:-}" && "${AGE_CLASS[$disk]}" == "Near endurance" ]]; then codes+="NR "; ((score++)); fi
                    if (( score > 0 )); then
                        SMARTG_CODES["$disk"]="${codes% }"
                        SMARTG_SCORE["$disk"]="$score"
                    fi
                done
                if (( ${#SMARTG_SCORE[@]} > 0 )); then
                    local sr=()
                    for d in "${!SMARTG_SCORE[@]}"; do
                        sr+=("${SMARTG_SCORE[$d]} $d ${SMARTG_CODES[$d]}")
                    done
                    local sorted cnt=0 line=""
                    sorted=$(printf "%s\n" "${sr[@]}" | sort -nr -k1,1 | head -n ${SMART_ATTR_TREND_TOP_N:-5})
                    while read -r sc dv codes; do
                        local base tag model_suffix
                        base="$(base_device "$dv")"; tag="$(basename "$base")"; model_suffix="$(model_suffix_for "$base")"
                        line+="$tag$model_suffix ${codes}; "
                        (( ++cnt >= ${SMART_ATTR_TREND_TOP_N:-5} )) && break
                    done < <(printf "%s\n" "$sorted")
                    SMART_GROWTH_LINE="${line%'; '}"
                fi
            fi
        fi
    fi
    # Endurance aging + TBW days-left shrink & acceleration (ranking)
    if (( ${POH_TREND_ENABLED:-0} == 1 || ${TBW_TREND_ENABLED:-0} == 1 )); then
        local win_end=${ENDURANCE_TREND_WINDOW_DAYS:-7}
        local cutoff_end
        cutoff_end=$(date -d "-${win_end} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
        # --- POH Aging Ranking ---
        if (( POH_TREND_ENABLED == 1 )) && [[ -f "$POH_HISTORY_FILE" ]]; then
            local poh_lines tmp_poh
            poh_lines=$(tail -n 50000 "$POH_HISTORY_FILE" 2>/dev/null || true | awk -v c="$cutoff_end" '$1>=c')
            if [[ -n "$poh_lines" ]]; then
                tmp_poh=$(mktemp) || { log_warn "mktemp failed; skipping POH trend block"; tmp_poh=""; }
                if [[ -n "$tmp_poh" ]]; then
                    printf "%s\n" "$poh_lines" | awk '{d=$2; for(i=3;i<=NF;i++){split($i,a,"="); if(a[1]=="poh") v=a[2]} if(d!="" && v!=""){print $1,d,v}}' > "$tmp_poh"
                declare -A poh_first_dt poh_first_v poh_last_dt poh_last_v
                while read -r dt dev v; do
                    [[ -z "$dev" || -z "$v" ]] && continue
                    if [[ -z "${poh_first_dt[$dev]:-}" || "$dt" < "${poh_first_dt[$dev]}" ]]; then poh_first_dt[$dev]="$dt"; poh_first_v[$dev]="$v"; fi
                    if [[ -z "${poh_last_dt[$dev]:-}" || "$dt" > "${poh_last_dt[$dev]}" ]]; then poh_last_dt[$dev]="$dt"; poh_last_v[$dev]="$v"; fi
                done < "$tmp_poh"
                rm -f "$tmp_poh"
                fi
                local poh_rank=()
                for dev in "${!poh_last_v[@]}"; do
                    local start=${poh_first_v[$dev]:-0} end=${poh_last_v[$dev]:-0}
                    if [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && $end -gt $start ]]; then
                        local delta=$(( end - start ))
                        if (( delta >= ENDURANCE_TREND_MIN_POH_DELTA )); then
                            poh_rank+=("$delta $dev $start $end")
                        fi
                    fi
                done
                if (( ${#poh_rank[@]} > 0 )); then
                    local sorted
                    sorted=$(printf "%s\n" "${poh_rank[@]}" | sort -nr -k1,1 | head -n ${ENDURANCE_TREND_TOP_N:-5})
                    # Build compact POH growth line with rate per day
                    {
                        local _s="" _cnt=0
                        while read -r delta dev start end; do
                            [[ -z "$dev" ]] && continue
                            local days_interval=$(( ( $(date -d "${poh_last_dt[$dev]}" +%s 2>/dev/null || date +%s) - $(date -d "${poh_first_dt[$dev]}" +%s 2>/dev/null || date +%s) ) / 86400 ))
                            (( days_interval<=0 )) && days_interval=1
                            local rate
                            rate=$(awk -v dlt="$delta" -v dd="$days_interval" 'BEGIN{printf "%.2f", dlt/dd}')
                            local base tag model_suffix
                            base="$(base_device "$dev")"; tag="$(basename "$base")"; model_suffix="$(model_suffix_for "$base")"
                            _s+="${tag}${model_suffix} +${delta}h r=${rate}h/d; "
                            (( ++_cnt >= ${ENDURANCE_TREND_TOP_N:-5} )) && break
                        done < <(printf "%s\n" "$sorted")
                        POH_GROWTH_LINE="${_s%'; '}"
                    }
                fi
            fi
        fi
        # --- TBW Days-Left Shrink & Acceleration ---
        if (( ${TBW_TREND_ENABLED:-0} == 1 )) && [[ -f "$TBW_DAYSLEFT_HISTORY_FILE" ]]; then
            local dl_lines tmp_dl accel_factor=${ENDURANCE_DAYSLEFT_ACCEL_FACTOR_PCT:-50} accel_min=${ENDURANCE_DAYSLEFT_ACCEL_MIN_DELTA:-0.5}
            dl_lines=$(tail -n 50000 "$TBW_DAYSLEFT_HISTORY_FILE" 2>/dev/null || true | awk -v c="$cutoff_end" '$1>=c')
            if [[ -n "$dl_lines" ]]; then
                tmp_dl=$(mktemp) || { log_warn "mktemp failed; skipping TBW days-left trend block"; tmp_dl=""; }
                if [[ -n "$tmp_dl" ]]; then
                    printf "%s\n" "$dl_lines" | awk '{d=$2; for(i=3;i<=NF;i++){split($i,a,"="); if(a[1]=="days_left") v=a[2]} if(d!="" && v!=""){print $1,d,v}}' > "$tmp_dl"
                declare -A dl_first_dt dl_first_v dl_last_dt dl_last_v dl_seq
                while read -r dt dev v; do
                    [[ -z "$dev" || -z "$v" ]] && continue
                    if [[ -z "${dl_first_dt[$dev]:-}" || "$dt" < "${dl_first_dt[$dev]}" ]]; then dl_first_dt[$dev]="$dt"; dl_first_v[$dev]="$v"; fi
                    if [[ -z "${dl_last_dt[$dev]:-}" || "$dt" > "${dl_last_dt[$dev]}" ]]; then dl_last_dt[$dev]="$dt"; dl_last_v[$dev]="$v"; fi
                    dl_seq[$dev]+="${dt}:${v} "
                done < "$tmp_dl"
                rm -f "$tmp_dl"
                fi
                local dl_rank=()
                for dev in "${!dl_last_v[@]}"; do
                    # Restrict to SSD/NVMe (ROTA=0 or nvme path)
                    if [[ "$dev" != /dev/nvme* ]]; then
                        local rota
                        rota=$(lsblk_rota_cached "$dev" 2>/dev/null || echo 1)
                        [[ "$rota" != "0" ]] && continue
                    fi
                    local start=${dl_first_v[$dev]:-0} end=${dl_last_v[$dev]:-0}
                    if [[ "$start" =~ ^[0-9]+(\.[0-9]+)?$ && "$end" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                        local shrink
                        shrink=$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.3f", e-s}')
                        awk -v sh="$shrink" 'BEGIN{exit (sh<0)?0:1}' || continue
                        # Build daily deltas for acceleration check
                        local entries=() seq_sorted last_dt="" last_v="" prev_v="" prev_dt=""
                        read -r -a entries <<< "${dl_seq[$dev]}"
                        seq_sorted=$(printf "%s\n" "${entries[@]}" | awk -F: '{print $1,$2}' | sort -k1,1)
                        local daily_deltas=() dt_cur v_cur
                        while read -r dt_cur v_cur; do
                            if [[ -n "$prev_dt" && "$prev_v" =~ ^[0-9]+(\.[0-9]+)?$ && "$v_cur" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                                local dlt
                                dlt=$(awk -v p="$prev_v" -v c="$v_cur" 'BEGIN{printf "%.3f", c-p}')
                                daily_deltas+=("$dlt")
                            fi
                            prev_dt="$dt_cur"; prev_v="$v_cur"; last_dt="$dt_cur"; last_v="$v_cur"
                        done < <(printf "%s\n" "$seq_sorted")
                        local accel_flag=""
                        if (( ${#daily_deltas[@]} > 1 )); then
                            local last_delta=${daily_deltas[-1]} sum=0 cnt=0 d
                            for d in "${daily_deltas[@]:0:${#daily_deltas[@]}-1}"; do
                                if awk -v x="$d" 'BEGIN{exit (x<0)?0:1}'; then
                                    sum=$(awk -v s="$sum" -v x="$d" 'BEGIN{printf "%.3f", s + x}')
                                    ((cnt++))
                                fi
                            done
                            if (( cnt > 0 )) && awk -v ld="$last_delta" -v mn="$accel_min" 'BEGIN{exit (ld<=-mn)?0:1}'; then
                                local avg
                                avg=$(awk -v s="$sum" -v c="$cnt" 'BEGIN{printf "%.3f", s/c}')
                                if awk -v ld="$last_delta" -v avg="$avg" -v pct="$accel_factor" 'BEGIN{exit (avg!=0 && ( (ld/avg) <= ( -1 - pct/100 ) ))?0:1}'; then
                                    accel_flag="ACCEL"
                                fi
                            fi
                        fi
                        # Rate per day
                        local days_interval=$(( ( $(date -d "$last_dt" +%s 2>/dev/null || date +%s) - $(date -d "${dl_first_dt[$dev]}" +%s 2>/dev/null || date +%s) ) / 86400 ))
                        (( days_interval<=0 )) && days_interval=1
                        local rate
                        rate=$(awk -v sh="$shrink" -v d="$days_interval" 'BEGIN{printf "%.3f", sh/d}')
                        local abs_rate
                        abs_rate=$(awk -v r="$rate" 'BEGIN{printf "%.3f", (r<0)? -r : r}')
                        dl_rank+=("$abs_rate $dev $start $end $shrink $rate $accel_flag")
                    fi
                done
                if (( ${#dl_rank[@]} > 0 )); then
                    local sorted
                    sorted=$(printf "%s\n" "${dl_rank[@]}" | sort -nr -k1,1 | head -n ${ENDURANCE_DAYSLEFT_TOP_N:-5})
                    {
                        local _s="" _cnt=0
                        while read -r abs_rate dev start end shrink rate accel; do
                            _s+="$(basename "$dev") ${shrink}d r=${rate}d/d${accel:+,$accel}; "
                            (( ++_cnt >= 5 )) && break
                        done < <(printf "%s\n" "$sorted")
                        DL_SHRINK_LINE="${_s%'; '}"
                    }
                fi
            fi
        fi
    fi
    # Btrfs/XFS error rate acceleration summary (top-N)
    if (( ERROR_RATE_TREND_ENABLED == 1 )); then
        local win_err=${ERROR_RATE_TREND_WINDOW_DAYS:-7} cutoff_err accel_factor_err=${ERROR_RATE_ACCEL_FACTOR_PCT:-100} accel_min_err=${ERROR_RATE_ACCEL_MIN_DELTA:-2} top_err=${ERROR_RATE_TREND_TOP_N:-5}
        local decay_days=7  # Error aging decay constant for acceleration weighting (e^{-age/decay_days})
        local now_epoch_err; now_epoch_err=$(date +%s)
        cutoff_err=$(date -d "-${win_err} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
        # Btrfs device/mount sequences
        local btrfs_lines
        [[ -f "$BTRFS_DEV_HIST_FILE" ]] && btrfs_lines=$(tail -n 50000 "$BTRFS_DEV_HIST_FILE" 2>/dev/null || true) || btrfs_lines=""
        declare -A BSEQ MSEQ
        if [[ -n "$btrfs_lines" ]]; then
            while read -r dt rest; do
                [[ -z "$dt" || "$dt" < "$cutoff_err" ]] && continue
                local key mount delta dev
                key=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^key=/){sub(/key=/,"",$i); print $i; break}}}')
                mount=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^mount=/){sub(/mount=/,"",$i); print $i; break}}}')
                delta=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^delta=/){sub(/delta=/,"",$i); print $i; break}}}')
                dev=$(echo "$rest" | awk '{print $NF}')
                [[ -z "$dev" || -z "$delta" || -z "$key" ]] && continue
                [[ "$delta" =~ ^[0-9]+$ ]] || continue
                BSEQ["$dev|$key"]+="${dt}:${delta} "
                [[ -n "$mount" ]] && MSEQ["$mount|$key"]+="${dt}:${delta} "
            done < <(printf "%s\n" "$btrfs_lines")
        fi
        local b_rank=() m_rank=()
        for dk in "${!BSEQ[@]}"; do
            local seq=() ; read -r -a seq <<< "${BSEQ[$dk]}"; (( ${#seq[@]} < 2 )) && continue
            local sorted_seq prev_dt="" last_delta="" deltas=() deltas_dates=()
            sorted_seq=$(printf "%s\n" "${seq[@]}" | awk -F: '{print $1,$2}' | sort -k1,1)
            while read -r dt d; do
                [[ -z "$dt" || -z "$d" ]] && continue
                if [[ -n "$prev_dt" ]]; then deltas+=("$d"); deltas_dates+=("$dt"); fi
                prev_dt="$dt"; last_delta="$d"
            done < <(printf "%s\n" "$sorted_seq")
            (( ${#deltas[@]} < 2 )) && continue
            # Weighted aging average excluding latest delta (use exp(-age/decay_days))
            local w_sum=0 w_tot=0 idx
            for idx in $(seq 0 $(( ${#deltas[@]} - 2 ))); do
                local dd=${deltas[$idx]} d_dt=${deltas_dates[$idx]}
                [[ "$dd" =~ ^[0-9]+$ ]] || continue
                local d_epoch; d_epoch=$(date -d "$d_dt" +%s 2>/dev/null || echo "$now_epoch_err")
                local age_days; age_days=$(( (now_epoch_err - d_epoch)/86400 ))
                (( age_days < 0 )) && age_days=0
                local weight; weight=$(awk -v a="$age_days" -v dec="$decay_days" 'BEGIN{ if(dec<=0) dec=7; printf "%.6f", exp(-a/dec) }')
                w_sum=$(awk -v ws="$w_sum" -v dd="$dd" -v w="$weight" 'BEGIN{ printf "%.6f", ws + dd*w }')
                w_tot=$(awk -v wt="$w_tot" -v w="$weight" 'BEGIN{ printf "%.6f", wt + w }')
            done
            local avg; avg=$(awk -v s="$w_sum" -v t="$w_tot" 'BEGIN{ if(t>0) printf "%.3f", s/t; else print 0 }')
            local dev=${dk%%|*} key=${dk##*|} f_key="$accel_factor_err" m_key="$accel_min_err"
            case "$key" in
                corruption_errs)
                    f_key=${ERROR_RATE_ACCEL_FACTOR_CORRUPTION:-$accel_factor_err}; m_key=${ERROR_RATE_ACCEL_MIN_DELTA_CORRUPTION:-$accel_min_err} ;;
                generation_errs)
                    f_key=${ERROR_RATE_ACCEL_FACTOR_GENERATION:-$accel_factor_err}; m_key=${ERROR_RATE_ACCEL_MIN_DELTA_GENERATION:-$accel_min_err} ;;
            esac
            if awk -v l="$last_delta" -v a="$avg" -v f="$f_key" -v m="$m_key" 'BEGIN{exit (l>=m && a>0 && l>=a*(1+f/100))?0:1}'; then
                local ratio
                ratio=$(awk -v l="$last_delta" -v a="$avg" 'BEGIN{if(a>0)printf "%.2f", l/a; else print 0}')
                b_rank+=("$last_delta $dev $key $last_delta $avg $ratio")
            fi
        done
        for mk in "${!MSEQ[@]}"; do
            local seq=() ; read -r -a seq <<< "${MSEQ[$mk]}"; (( ${#seq[@]} < 2 )) && continue
            local sorted_seq prev_dt="" last_delta="" deltas=() deltas_dates=()
            sorted_seq=$(printf "%s\n" "${seq[@]}" | awk -F: '{print $1,$2}' | sort -k1,1)
            while read -r dt d; do
                [[ -z "$dt" || -z "$d" ]] && continue
                if [[ -n "$prev_dt" ]]; then deltas+=("$d"); deltas_dates+=("$dt"); fi
                prev_dt="$dt"; last_delta="$d"
            done < <(printf "%s\n" "$sorted_seq")
            (( ${#deltas[@]} < 2 )) && continue
            local w_sum=0 w_tot=0 idx
            for idx in $(seq 0 $(( ${#deltas[@]} - 2 ))); do
                local dd=${deltas[$idx]} d_dt=${deltas_dates[$idx]}
                [[ "$dd" =~ ^[0-9]+$ ]] || continue
                local d_epoch; d_epoch=$(date -d "$d_dt" +%s 2>/dev/null || echo "$now_epoch_err")
                local age_days; age_days=$(( (now_epoch_err - d_epoch)/86400 ))
                (( age_days < 0 )) && age_days=0
                local weight; weight=$(awk -v a="$age_days" -v dec="$decay_days" 'BEGIN{ if(dec<=0) dec=7; printf "%.6f", exp(-a/dec) }')
                w_sum=$(awk -v ws="$w_sum" -v dd="$dd" -v w="$weight" 'BEGIN{ printf "%.6f", ws + dd*w }')
                w_tot=$(awk -v wt="$w_tot" -v w="$weight" 'BEGIN{ printf "%.6f", wt + w }')
            done
            local avg; avg=$(awk -v s="$w_sum" -v t="$w_tot" 'BEGIN{ if(t>0) printf "%.3f", s/t; else print 0 }')
            local mount=${mk%%|*} key=${mk##*|} f_key="$accel_factor_err" m_key="$accel_min_err"
            case "$key" in
                corruption_errs)
                    f_key=${ERROR_RATE_ACCEL_FACTOR_CORRUPTION:-$accel_factor_err}; m_key=${ERROR_RATE_ACCEL_MIN_DELTA_CORRUPTION:-$accel_min_err} ;;
                generation_errs)
                    f_key=${ERROR_RATE_ACCEL_FACTOR_GENERATION:-$accel_factor_err}; m_key=${ERROR_RATE_ACCEL_MIN_DELTA_GENERATION:-$accel_min_err} ;;
            esac
            if awk -v l="$last_delta" -v a="$avg" -v f="$f_key" -v m="$m_key" 'BEGIN{exit (l>=m && a>0 && l>=a*(1+f/100))?0:1}'; then
                local ratio
                ratio=$(awk -v l="$last_delta" -v a="$avg" 'BEGIN{if(a>0)printf "%.2f", l/a; else print 0}')
                m_rank+=("$last_delta $mount $key $last_delta $avg $ratio")
            fi
        done
        local xfs_lines
        [[ -f "$XFS_PROC_HISTORY_FILE" ]] && xfs_lines=$(tail -n 20000 "$XFS_PROC_HISTORY_FILE" 2>/dev/null || true) || xfs_lines=""
        declare -A XSEQ
        if [[ -n "$xfs_lines" ]]; then
            while read -r dt rest; do
                [[ -z "$dt" || "$dt" < "$cutoff_err" ]] && continue
                local key delta
                key=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^key=/){sub(/key=/,"",$i); print $i; break}}}')
                delta=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^delta=/){sub(/delta=/,"",$i); print $i; break}}}')
                [[ -z "$key" || -z "$delta" ]] && continue
                [[ "$delta" =~ ^[0-9]+$ ]] || continue
                XSEQ["$key"]+="${dt}:${delta} "
            done < <(printf "%s\n" "$xfs_lines")
        fi
        local x_rank=()
        for key in "${!XSEQ[@]}"; do
            local seq=() ; read -r -a seq <<< "${XSEQ[$key]}"; (( ${#seq[@]} < 2 )) && continue
            local sorted_seq prev_dt="" last_delta="" deltas=() deltas_dates=()
            sorted_seq=$(printf "%s\n" "${seq[@]}" | awk -F: '{print $1,$2}' | sort -k1,1)
            while read -r dt d; do
                [[ -z "$dt" || -z "$d" ]] && continue
                if [[ -n "$prev_dt" ]]; then deltas+=("$d"); deltas_dates+=("$dt"); fi
                prev_dt="$dt"; last_delta="$d"
            done < <(printf "%s\n" "$sorted_seq")
            (( ${#deltas[@]} < 2 )) && continue
            local w_sum=0 w_tot=0 idx
            for idx in $(seq 0 $(( ${#deltas[@]} - 2 ))); do
                local dd=${deltas[$idx]} d_dt=${deltas_dates[$idx]}
                [[ "$dd" =~ ^[0-9]+$ ]] || continue
                local d_epoch; d_epoch=$(date -d "$d_dt" +%s 2>/dev/null || echo "$now_epoch_err")
                local age_days; age_days=$(( (now_epoch_err - d_epoch)/86400 ))
                (( age_days < 0 )) && age_days=0
                local weight; weight=$(awk -v a="$age_days" -v dec="$decay_days" 'BEGIN{ if(dec<=0) dec=7; printf "%.6f", exp(-a/dec) }')
                w_sum=$(awk -v ws="$w_sum" -v dd="$dd" -v w="$weight" 'BEGIN{ printf "%.6f", ws + dd*w }')
                w_tot=$(awk -v wt="$w_tot" -v w="$weight" 'BEGIN{ printf "%.6f", wt + w }')
            done
            local avg; avg=$(awk -v s="$w_sum" -v t="$w_tot" 'BEGIN{ if(t>0) printf "%.3f", s/t; else print 0 }')
            if awk -v l="$last_delta" -v a="$avg" -v f="$accel_factor_err" -v m="$accel_min_err" 'BEGIN{exit (l>=m && a>0 && l>=a*(1+f/100))?0:1}'; then
                local ratio
                ratio=$(awk -v l="$last_delta" -v a="$avg" 'BEGIN{if(a>0)printf "%.2f", l/a; else print 0}')
                x_rank+=("$last_delta $key $last_delta $avg $ratio")
            fi
        done
        if (( ${#b_rank[@]} + ${#m_rank[@]} + ${#x_rank[@]} > 0 )); then
            local part_b="" part_m="" part_x=""
            if (( ${#b_rank[@]} > 0 )); then
                local sorted_b; sorted_b=$(printf "%s\n" "${b_rank[@]}" | sort -nr -k1,1 | head -n "$top_err")
                while read -r _ dev key _ _ ratio; do
                    part_b+="$(basename "$dev"):$key x$ratio, "
                done < <(printf "%s\n" "$sorted_b")
                part_b=${part_b%%, }
            fi
            if (( ${#m_rank[@]} > 0 )); then
                local sorted_m; sorted_m=$(printf "%s\n" "${m_rank[@]}" | sort -nr -k1,1 | head -n "$top_err")
                while read -r _ mount key _ _ ratio; do
                    part_m+="${mount}:$key x$ratio, "
                done < <(printf "%s\n" "$sorted_m")
                part_m=${part_m%%, }
            fi
            if (( ${#x_rank[@]} > 0 )); then
                local sorted_x; sorted_x=$(printf "%s\n" "${x_rank[@]}" | sort -nr -k1,1 | head -n "$top_err")
                while read -r _ key _ _ ratio; do
                    part_x+="${key} x$ratio, "
                done < <(printf "%s\n" "$sorted_x")
                part_x=${part_x%%, }
            fi
            EARLY_ERR_LINE="${part_b:+BtrfsDev: ${part_b}; }${part_m:+BtrfsMnt: ${part_m}; }${part_x:+XFS: ${part_x}}"
            EARLY_ERR_LINE="${EARLY_ERR_LINE%%; }"
        fi
    fi
    # Btrfs cumulative device/mount/key totals
    if (( BTRFS_DEV_TREND_ENABLED == 1 )); then
        local win_bt=${BTRFS_TREND_WINDOW_DAYS:-7} cutoff_bt
        cutoff_bt=$(date -d "-${win_bt} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
        if [[ -f "$BTRFS_DEV_HIST_FILE" ]]; then
            local lines_bt
            lines_bt=$(tail -n 50000 "$BTRFS_DEV_HIST_FILE" 2>/dev/null || true)
            if [[ -n "$lines_bt" ]]; then
                declare -A SUM_KEY DEV_SUM SUM_MOUNT_KEY MOUNT_SUM KEY_SUM
                while read -r dt rest; do
                    [[ -z "$dt" || "$dt" < "$cutoff_bt" ]] && continue
                    local dev mount key delta
                    dev=$(echo "$rest" | awk '{print $1}')
                    key=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^key=/){sub(/key=/,"",$i); print $i; break}}}')
                    mount=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^mount=/){sub(/mount=/,"",$i); print $i; break}}}')
                    delta=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^delta=/){sub(/delta=/,"",$i); print $i; break}}}')
                    [[ -z "$dev" || -z "$key" || -z "$delta" ]] && continue
                    [[ "$delta" =~ ^[0-9]+$ ]] || continue
                    (( delta == 0 )) && continue
                    SUM_KEY["$dev|$key"]=$(( ${SUM_KEY["$dev|$key"]:-0} + delta ))
                    DEV_SUM["$dev"]=$(( ${DEV_SUM["$dev"]:-0} + delta ))
                    [[ -n "$mount" ]] && {
                        SUM_MOUNT_KEY["$mount|$key"]=$(( ${SUM_MOUNT_KEY["$mount|$key"]:-0} + delta ))
                        MOUNT_SUM["$mount"]=$(( ${MOUNT_SUM["$mount"]:-0} + delta ))
                    }
                    KEY_SUM["$key"]=$(( ${KEY_SUM["$key"]:-0} + delta ))
                done < <(printf "%s\n" "$lines_bt")
                if (( ${#DEV_SUM[@]} > 0 )); then
                    if (( ${#DEV_SUM[@]} > 0 )); then
                        local ranked_bt line=""; ranked_bt=$(for d in "${!DEV_SUM[@]}"; do echo "${DEV_SUM[$d]} $d"; done | sort -nr -k1,1 | head -n ${BTRFS_TREND_TOP_N:-5})
                        while read -r total dev; do
                            [[ -z "$dev" ]] && continue
                            line+="$(basename "$dev"):+$total; "
                        done < <(printf "%s\n" "$ranked_bt")
                        BTRFS_SUM_LINE="${line%'; '}"
                    fi
                fi
            fi
        fi
    fi
    # Build compact one-liner Trend output with key metrics
    {
        declare -a _TL=()
        _add_line() { local tag="$1" text="$2"; [[ -n "$text" ]] && _TL+=("${tag}: ${text}"); }
        # Capacity forecast
        if [[ -n "${ARR_GROWTH_STR:-}" || -n "${POOL_GROWTH_STR:-}" || -n "${ARR_DAYS_TO_THRESHOLD:-}" || -n "${POOL_DAYS_TO_THRESHOLD:-}" ]]; then
            local _cf_a _cf_p _cf_suffix=""
            if (( ${ARR_HISTORY_COUNT:-0} < 2 )); then
                _cf_a="array history<2 samples"
            else
                _cf_a="array ${ARR_DAYS_TO_THRESHOLD:-N/A}d→${THRESHOLD}% (${ARR_GROWTH_STR:-N/A}/d)"
            fi
            if (( ${POOL_HISTORY_COUNT:-0} < 2 )); then
                _cf_p="pools history<2 samples"
            else
                _cf_p="pools ${POOL_DAYS_TO_THRESHOLD:-N/A}d→${THRESHOLD}% (${POOL_GROWTH_STR:-N/A}/d)"
            fi
            # Annotate CF only when parity is truly in progress to indicate potential skew
            if [[ -n "${PARITY_ACTION:-}" ]]; then
                local _act _pos _size _rem _spk
                _act=$(printf "%s" "${PARITY_ACTION}" | awk '{print tolower($1)}')
                _pos="${PARITY_POS:-}"; _size="${PARITY_SIZE:-}"; _rem="${PARITY_REM:-}"; _spk="${PARITY_SPEED_K:-}"
                if [[ -n "$_act" && "$_act" != "idle" ]]; then
                    if [[ "$_spk" =~ ^[0-9]+$ && $((10#$_spk)) -gt 0 ]]; then _cf_suffix=" (parity in progress; forecast may be skewed)"
                    elif [[ "$_rem" =~ ^[0-9]+$ && $((10#$_rem)) -gt 0 ]]; then _cf_suffix=" (parity in progress; forecast may be skewed)"
                    elif [[ "$_pos" =~ ^[0-9]+$ && "$_size" =~ ^[0-9]+$ && $((10#$_pos)) -gt 0 && $((10#$_pos)) -lt $((10#$_size)) ]]; then _cf_suffix=" (parity in progress; forecast may be skewed)"
                    fi
                fi
            fi
            _add_line "CF" "${_cf_a}; ${_cf_p}${_cf_suffix}"
        fi
        # Disk growth (top 5)
        if (( ${DISK_GROWTH_ENABLED:-1} == 1 )) && [[ -f "${DISK_CAP_HISTORY_FILE}" ]]; then
            local _win_dg _lines_dg _cutoff_dg _tmp_dg
            _win_dg=$HISTORY_WINDOW_DAYS
            _lines_dg=$(tail -n 20000 "$DISK_CAP_HISTORY_FILE" 2>/dev/null || true)
            if [[ -n "$_lines_dg" ]]; then
                _cutoff_dg=$(date -d "-${_win_dg} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
                _tmp_dg=$(mktemp) || { log_warn "mktemp failed; skipping disk growth block"; _tmp_dg=""; }
                if [[ -n "$_tmp_dg" ]]; then
                    printf "%s\n" "$_lines_dg" | awk -v c="$_cutoff_dg" '$1>=c{print}' | awk '{d=$2; for(i=3;i<=NF;i++){split($i,a,"="); if(a[1]=="used") used=a[2]; if(a[1]=="size") sz=a[2]} if(used!="" && sz!=""){print $1,d,used,sz}}' > "$_tmp_dg"
                    declare -A _DG_FDT _DG_FU _DG_LDT _DG_LU _DG_SZ
                    while read -r dt disk used sz; do
                        _DG_SZ[$disk]="$sz"
                        if [[ -z "${_DG_FDT[$disk]:-}" || "$dt" < "${_DG_FDT[$disk]}" ]]; then _DG_FDT[$disk]="$dt"; _DG_FU[$disk]="$used"; fi
                        if [[ -z "${_DG_LDT[$disk]:-}" || "$dt" > "${_DG_LDT[$disk]}" ]]; then _DG_LDT[$disk]="$dt"; _DG_LU[$disk]="$used"; fi
                    done < "$_tmp_dg"
                    rm -f "$_tmp_dg"
                fi
                local _rank=()
                for disk in "${!_DG_LU[@]}"; do
                    local fu=${_DG_FU[$disk]:-0} lu=${_DG_LU[$disk]:-0} sz=${_DG_SZ[$disk]:-0}
                    if (( lu>0 && fu>=0 && lu>fu )); then
                        local days=$(( ( $(date -d "${_DG_LDT[$disk]}" +%s 2>/dev/null || date +%s) - $(date -d "${_DG_FDT[$disk]}" +%s 2>/dev/null || date +%s) ) / 86400 ))
                        (( days<=0 )) && days=1
                        local per_day=$(( (lu - fu) / days ))
                        _rank+=("$per_day $disk $sz")
                    fi
                done
                # Build growth and shrink lists independently then merge into single line
                format_rate_dg() { local b="$1"; if (( b >= 1000000000 )); then awk -v v="$b" 'BEGIN{printf "%.1fG", v/1000000000}'; elif (( b >= 1000000 )); then awk -v v="$b" 'BEGIN{printf "%dM", int(v/1000000)}'; else awk -v v="$b" 'BEGIN{printf "%dK", int(v/1000)}'; fi; }
                local _items_growth=() _items_shrink=() sep=" | "
                if (( ${#_rank[@]} > 0 )); then
                    local _sorted_g
                    _sorted_g=$(printf "%s\n" "${_rank[@]}" | sort -nr -k1,1 | head -n 5)
                    while read -r pd disk sz; do
                        [[ -z "$pd" || -z "$disk" ]] && continue
                        disk=${disk//\"/}
                        local rate pct
                        rate=$(format_rate_dg "$pd")
                        if (( sz>0 )); then pct=$(awk -v pd="$pd" -v sz="$sz" 'BEGIN{printf "%.2f", (pd/sz)*100}'); _items_growth+=("🔺${disk} +${rate} (${pct}%)"); else _items_growth+=("🔺${disk} +${rate}"); fi
                    done < <(printf "%s\n" "$_sorted_g")
                fi
                local _shrink_rank=()
                for disk in "${!_DG_LU[@]}"; do
                    local fu=${_DG_FU[$disk]:-0} lu=${_DG_LU[$disk]:-0} sz=${_DG_SZ[$disk]:-0}
                    if (( fu>0 && lu>=0 && fu>lu )); then
                        local days=$(( ( $(date -d "${_DG_LDT[$disk]}" +%s 2>/dev/null || date +%s) - $(date -d "${_DG_FDT[$disk]}" +%s 2>/dev/null || date +%s) ) / 86400 ))
                        (( days<=0 )) && days=1
                        local per_day=$(( (fu - lu) / days ))
                        _shrink_rank+=("$per_day $disk $sz")
                    fi
                done
                if (( ${#_shrink_rank[@]} > 0 )); then
                    local _sorted_s
                    _sorted_s=$(printf "%s\n" "${_shrink_rank[@]}" | sort -nr -k1,1 | head -n 5)
                    while read -r pd disk sz; do
                        [[ -z "$pd" || -z "$disk" ]] && continue
                        disk=${disk//\"/}
                        local rate pct
                        rate=$(format_rate_dg "$pd")
                        if (( sz>0 )); then pct=$(awk -v pd="$pd" -v sz="$sz" 'BEGIN{printf "%.2f", (pd/sz)*100}'); _items_shrink+=("🔻${disk} -${rate} (${pct}%)"); else _items_shrink+=("🔻${disk} -${rate}"); fi
                    done < <(printf "%s\n" "$_sorted_s")
                fi
                if (( ${#_items_growth[@]} + ${#_items_shrink[@]} > 0 )); then
                    local _combined=("${_items_growth[@]}" "${_items_shrink[@]}")
                    _add_line "DISK↑" "$(IFS="$sep"; echo "${_combined[*]}")"
                fi
            fi
        fi
        # Share growth (top N)
        if (( ${SHARE_BREAKDOWN_ENABLED:-0} == 1 )) && [[ -f "${SHARE_USAGE_HISTORY_FILE}" ]]; then
            local _win_s _cut_s _lines_s _tmp_s
            _win_s=$HISTORY_WINDOW_DAYS
            _cut_s=$(date -d "-${_win_s} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
            _lines_s=$(tail -n 50000 "${SHARE_USAGE_HISTORY_FILE}" 2>/dev/null || true)
            if [[ -n "$_lines_s" ]]; then
                _tmp_s=$(mktemp) || { log_warn "mktemp failed; skipping share growth block"; _tmp_s=""; }
                if [[ -n "$_tmp_s" ]]; then
                    printf "%s\n" "$_lines_s" | awk -v c="$_cut_s" '$1>=c{print}' | awk '{s=$2; for(i=3;i<=NF;i++){split($i,a,"="); if(a[1]=="bytes") b=a[2]} if(s!="" && b!=""){print $1,s,b}}' > "$_tmp_s"
                # Predeclare arrays to avoid nounset when data is sparse
                declare -A _SFDT _SFB _SLDT _SLB
                while read -r dt s b; do
                    if [[ -z "${_SFDT[$s]:-}" || "$dt" < "${_SFDT[$s]}" ]]; then _SFDT[$s]="$dt"; _SFB[$s]="$b"; fi
                    if [[ -z "${_SLDT[$s]:-}" || "$dt" > "${_SLDT[$s]}" ]]; then _SLDT[$s]="$dt"; _SLB[$s]="$b"; fi
                done < "$_tmp_s"
                rm -f "$_tmp_s"
                fi
                local _gr=()
                for s in "${!_SLB[@]}"; do
                    local fu=${_SFB[$s]:-0} lu=${_SLB[$s]:-0}
                    if (( lu>0 && fu>=0 && lu>fu )); then
                        local days=$(( ( $(date -d "${_SLDT[$s]}" +%s 2>/dev/null || date +%s) - $(date -d "${_SFDT[$s]}" +%s 2>/dev/null || date +%s) ) / 86400 ))
                        (( days<=0 )) && days=1
                        local per_day=$(( (lu - fu) / days ))
                        _gr+=("$per_day $s")
                    fi
                done
                # Share growth and shrink
                _share_rate_fmt() { local b="$1"; if (( b >= 1000000000 )); then awk -v v="$b" 'BEGIN{printf "%.1fG", v/1000000000}'; elif (( b >= 1000000 )); then awk -v v="$b" 'BEGIN{printf "%dM", int(v/1000000)}'; else awk -v v="$b" 'BEGIN{printf "%dK", int(v/1000)}'; fi; }
                local _share_growth_items=() _share_shrink_items=()
                if (( ${#_gr[@]} > 0 )); then
                    local _sorted_gs
                    _sorted_gs=$(printf "%s\n" "${_gr[@]}" | sort -nr -k1,1 | head -n "${SHARE_TOP_N}")
                    while read -r pd s; do
                        [[ -z "$s" ]] && continue
                        local rate; rate=$(_share_rate_fmt "$pd")
                        _share_growth_items+=("🔺${s} +${rate}")
                    done < <(printf "%s\n" "$_sorted_gs")
                fi
                local _shrink_share=()
                for s in "${!_SLB[@]}"; do
                    local fu=${_SFB[$s]:-0} lu=${_SLB[$s]:-0}
                    if (( fu>0 && lu>=0 && fu>lu )); then
                        local days=$(( ( $(date -d "${_SLDT[$s]}" +%s 2>/dev/null || date +%s) - $(date -d "${_SFDT[$s]}" +%s 2>/dev/null || date +%s) ) / 86400 ))
                        (( days<=0 )) && days=1
                        local per_day=$(( (fu - lu) / days ))
                        _shrink_share+=("$per_day $s")
                    fi
                done
                if (( ${#_shrink_share[@]} > 0 )); then
                    local _sorted_ss
                    _sorted_ss=$(printf "%s\n" "${_shrink_share[@]}" | sort -nr -k1,1 | head -n "${SHARE_TOP_N}")
                    while read -r pd s; do
                        [[ -z "$s" ]] && continue
                        local rate; rate=$(_share_rate_fmt "$pd")
                        _share_shrink_items+=("🔻${s} -${rate}")
                    done < <(printf "%s\n" "$_sorted_ss")
                fi
                if (( ${#_share_growth_items[@]} + ${#_share_shrink_items[@]} > 0 )); then
                    local _combined_share=("${_share_growth_items[@]}" "${_share_shrink_items[@]}")
                    _add_line "SHARE↑" "$(IFS=' | '; echo "${_combined_share[*]}")"
                fi
            fi
        fi
        # NVMe/SATA SSD wear rate (TBW-derived percent/day)
        if declare -p TBW_DAILY >/dev/null 2>&1; then
            local wear_items=() sep_w=" | "
            for dev in "${!TBW_DAILY[@]}"; do
                local is_ssd=0
                if [[ "$dev" == /dev/nvme* ]]; then is_ssd=1; else
                    local rota; rota=$(lsblk_rota_cached "$dev" 2>/dev/null || echo 1)
                    [[ "$rota" == "0" ]] && is_ssd=1
                fi
                (( is_ssd == 0 )) && continue
                local model cap_tb tbw_thresh_tb
                model=$(get_device_model "$dev")
                cap_tb=$(get_device_capacity_tb "$dev")
                tbw_thresh_tb=$(tbw_threshold_tb_for_device "$model" "$cap_tb")
                [[ -z "$tbw_thresh_tb" ]] && continue
                if ! [[ "$tbw_thresh_tb" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then continue; fi
                local daily_bytes total_bytes rate_pct_day_raw rate_pct_day_disp
                daily_bytes=${TBW_DAILY[$dev]:-0}
                total_bytes=$(awk -v t="$tbw_thresh_tb" 'BEGIN{printf "%d", int(t * 1000*1000*1000*1000)}')
                if (( daily_bytes > 0 && total_bytes > 0 )); then
                    rate_pct_day_raw=$(awk -v d="$daily_bytes" -v t="$total_bytes" 'BEGIN{printf "%.8f", (d/t)*100.0}')
                    rate_pct_day_disp=$(awk -v r="$rate_pct_day_raw" 'BEGIN{printf "%.4f", r}')
                    if awk -v r="$rate_pct_day_raw" -v d="$rate_pct_day_disp" 'BEGIN{exit (r>0 && d==0)?0:1}'; then
                        rate_pct_day_disp="~0.0001"
                    fi
                    local used_pct days_left label_dev
                    used_pct=${CUR_ATTR["$dev|nvme_percent_used"]:-}
                    label_dev=$(basename "$dev")
                    if [[ -n "$used_pct" && "$used_pct" =~ ^[0-9]+$ ]] && awk -v r="$rate_pct_day_raw" 'BEGIN{exit (r>0)?0:1}'; then
                        local remaining
                        remaining=$(awk -v u="$used_pct" -v r="$rate_pct_day_raw" 'BEGIN{printf "%.1f", (100.0 - u)/r}')
                        wear_items+=("${label_dev} ${remaining/.*}d r=${rate_pct_day_disp}%/d")
                    else
                        wear_items+=("${label_dev} ∞ r=${rate_pct_day_disp}%/d")
                    fi
                fi
            done
            if (( ${#wear_items[@]} > 0 )); then
                _add_line "WEAR" "$(IFS="$sep_w"; echo "${wear_items[*]}")"
            fi
        fi
        # Maintenance: long SMART tests due soon
        if declare -p LONG_TEST_DUE_SOON &>/dev/null; then
            local _near=() _k _d
            for _k in "${!LONG_TEST_DUE_SOON[@]}"; do _d=${LONG_TEST_DUE_SOON[$_k]}; _near+=("$(basename "$_k")(${_d}d)"); done
            if (( ${#_near[@]} > 0 )); then _add_line "MTN" "${_near[*]}"; fi
        fi
        # TBW trend (forecast days-left) and heavy writers compact
        if (( ${TBW_TREND_ENABLED:-0} == 1 )) && declare -p TBW_DAYS_LEFT &>/dev/null; then
            local _tbw="" _writers=""
            for dev in "${!TBW_DAYS_LEFT[@]}"; do
                local dl=${TBW_DAYS_LEFT[$dev]} daily=${TBW_DAILY[$dev]:-0}
                format_rate() {
                    local b="$1"
                    if [[ "$b" =~ ^[0-9]+$ ]]; then
                        awk -v v="$b" 'BEGIN{ if(v>=1000000000) printf "%.1fG", v/1000000000; else if(v>=1000000) printf "%dM", int(v/1000000); else printf "%dK", int(v/1000) }'
                    else
                        printf "0K"
                    fi
                }
                local rate; rate=$(format_rate "$daily")
                _tbw+="🔺$(basename "$dev") ${rate} → ${dl}d | "
            done
            _tbw=${_tbw%" | "}; [[ -n "$_tbw" ]] && _add_line "TBW" "$_tbw"
            if declare -p TBW_DAILY &>/dev/null && declare -p CAPACITY_CACHE &>/dev/null; then
                local _hr=() ; for dev in "${!TBW_DAILY[@]}"; do
                    local daily=${TBW_DAILY[$dev]:-0} cap_tb=${CAPACITY_CACHE[$dev]:-}
                    [[ -z "$cap_tb" || -z "$daily" ]] && continue
                    if [[ "$cap_tb" =~ ^[0-9]+(\.[0-9]+)?$ && "$daily" =~ ^[0-9]+$ ]]; then
                        local np; np=$(awk -v daily="$daily" -v cap_tb="$cap_tb" 'BEGIN{printf "%.6f", (daily/(cap_tb*1000000000000.0))*100}')
                        _hr+=("$np $dev $daily $cap_tb")
                    fi
                done
                if (( ${#_hr[@]} > 0 )); then
                    local _sorted _s=""
                    _sorted=$(printf "%s\n" "${_hr[@]}" | sort -nr -k1,1 | head -n 5)
                    # Global writer classification arrays for guidance and alerts
                    declare -A WRITER_WEEKLY_PCT WRITER_TIER
                    while read -r pct dev daily cap_tb; do
                        format_rate() {
                            local b="$1"
                            if [[ "$b" =~ ^[0-9]+$ ]]; then
                                awk -v v="$b" 'BEGIN{ if(v>=1000000000) printf "%.1fG", v/1000000000; else if(v>=1000000) printf "%dM", int(v/1000000); else printf "%dK", int(v/1000) }'
                            else
                                printf "0K"
                            fi
                        }
                        local rate; rate=$(format_rate "$daily")
                        # pct is daily % of capacity; derive weekly percent
                        local weekly_pct; weekly_pct=$(awk -v d="$pct" 'BEGIN{printf "%.6f", d*7}')
                        WRITER_WEEKLY_PCT[$dev]="$weekly_pct"
                        # Determine tier
                        local tier="" w="$weekly_pct"
                        if awk -v w="$w" -v c="$WRITER_WEEKLY_CRIT_PCT" 'BEGIN{exit (w>=c)?0:1}'; then
                            tier="H"; record_alert critical "Heavy Writer" "Disk $dev weekly write ~$(awk -v w="$w" 'BEGIN{printf "%.2f", w}')% cap/week >= ${WRITER_WEEKLY_CRIT_PCT}%"
                        elif awk -v w="$w" -v wthr="$WRITER_WEEKLY_WARN_PCT" 'BEGIN{exit (w>=wthr)?0:1}'; then
                            tier="H"; record_alert warning "Heavy Writer" "Disk $dev weekly write ~$(awk -v w="$w" 'BEGIN{printf "%.2f", w}')% cap/week >= ${WRITER_WEEKLY_WARN_PCT}%"
                        elif awk -v w="$w" -v m="$WRITER_TIER_MODERATE_PCT" 'BEGIN{exit (w>=m)?0:1}'; then
                            tier="M"
                        else
                            tier="L"
                        fi
                        WRITER_TIER[$dev]="$tier"
                        _s+="🔺$(basename "$dev") $(printf '%.3f' "$pct")% cap (${rate}) | "
                    done < <(printf "%s\n" "$_sorted")
                    _s=${_s%" | "}; _add_line "WRITERS" "$_s"
                fi
            fi
        fi
        # NVMe wear depletion projection line (percent_used slope)
        if (( ${WEAR_TREND_ENABLED:-0} == 1 )) && declare -p NVME_WEAR_DAYS_LEFT &>/dev/null; then
            local _wear_items=() dev
            for dev in "${!NVME_WEAR_DAYS_LEFT[@]}"; do
                local dl=${NVME_WEAR_DAYS_LEFT[$dev]} rate=${NVME_WEAR_RATE[$dev]:-0}
                local dl_fmt
                if [[ "$dl" == INF ]]; then dl_fmt="∞"; else dl_fmt="${dl}d"; fi
                _wear_items+=("$(basename "$dev") ${dl_fmt} r=$(printf '%.4f' "$rate")%/d")
            done
            if (( ${#_wear_items[@]} > 0 )); then
                # Order by shortest days-left (INF last)
                local _rank=() item
                for item in "${_wear_items[@]}"; do
                    local dlv
                    dlv=$(echo "$item" | awk '{print $2}' | sed 's/d$//; s/∞/999999/')
                    _rank+=("$dlv $item")
                done
                local _sorted
                _sorted=$(printf "%s\n" "${_rank[@]}" | sort -n -k1,1 | awk '{ $1=""; sub(/^ /,""); print }' | head -n ${WEAR_TREND_TOP_N})
                local _line=""
                while read -r ln; do [[ -n "$ln" ]] && _line+="$ln | "; done < <(printf "%s\n" "$_sorted")
                _line="${_line% | }"
                [[ -n "$_line" ]] && _add_line "WEAR" "$_line"
            fi
        fi
        # Lifecycle
        {
            local rcnt=0 mcnt=0 rshow="" mshow="" life_line="" top=${LIFECYCLE_ALERT_TOP_N}
            if declare -p REPLACE_LIST &>/dev/null || declare -p MONITOR_LIST &>/dev/null; then
                [[ -n "${REPLACE_LIST[*]:-}" ]] && rcnt=${#REPLACE_LIST[@]} ; [[ -n "${MONITOR_LIST[*]:-}" ]] && mcnt=${#MONITOR_LIST[@]}
                if (( rcnt > 0 )); then rshow="Replace(${rcnt})=$(printf '%s' "${REPLACE_LIST[*]:0:top}")"; fi
                if (( mcnt > 0 )); then mshow="Monitor(${mcnt})=$(printf '%s' "${MONITOR_LIST[*]:0:top}")"; fi
            fi
            if [[ -z "$rshow$mshow" ]] && [[ -f "$RISK_TIER_HISTORY_FILE" ]]; then
                # Fallback to most recent history line containing device lists
                local last
                last=$(tail -n 200 "$RISK_TIER_HISTORY_FILE" | awk 'NF' | tail -n 1)
                if [[ -n "$last" ]]; then
                    local repl mon
                    repl=$(printf "%s\n" "$last" | awk '{for(i=1;i<=NF;i++){if($i ~ /^REPLACE_DEVICES=/){sub(/REPLACE_DEVICES=/,"",$i); print $i; break}}}')
                    mon=$(printf "%s\n" "$last" | awk '{for(i=1;i<=NF;i++){if($i ~ /^MONITOR_DEVICES=/){sub(/MONITOR_DEVICES=/,"",$i); print $i; break}}}')
                    if [[ -n "$repl" ]]; then
                        # split by comma, keep top N
                        IFS=',' read -r -a _ra <<< "$repl"
                        rcnt=${#_ra[@]}
                        local _slice_r; _slice_r=$(printf '%s ' "${_ra[@]:0:top}" | awk 'NF')
                        rshow="Replace(${rcnt})=${_slice_r% }"
                    fi
                    if [[ -n "$mon" ]]; then
                        IFS=',' read -r -a _ma <<< "$mon"
                        mcnt=${#_ma[@]}
                        local _slice_m; _slice_m=$(printf '%s ' "${_ma[@]:0:top}" | awk 'NF')
                        mshow="Monitor(${mcnt})=${_slice_m% }"
                    fi
                fi
            fi
            life_line="${rshow}${rshow:+; }${mshow}"
            [[ -n "$life_line" ]] && _add_line "LIFE" "$life_line"
        }
        # POH growth (aging rate)
        if [[ -n "${POH_GROWTH_LINE:-}" ]]; then
            local _poh_items=() _ppart
            IFS=';' read -r -a _poh_parts <<< "${POH_GROWTH_LINE}" || true
            for _ppart in "${_poh_parts[@]}"; do
                _ppart=$(echo "$_ppart" | awk 'NF')
                [[ -z "$_ppart" ]] && continue
                if [[ "$_ppart" =~ -[0-9] ]]; then _poh_items+=("$_ppart"); else _poh_items+=("🔺$_ppart"); fi
            done
            [[ ${#_poh_items[@]} -gt 0 ]] && _add_line "POH↑" "$(IFS=' | '; echo "${_poh_items[*]}")"
        fi
        # POH Age : show top-N highest POH with class
        if (( AGE_AWARE_ENABLED==1 )) && [[ -n "${AGE_AWARE_LINES:-}" ]]; then
            local _rank=()
            while IFS= read -r l; do
                [[ -z "$l" ]] && continue
                # Expect format: dev (class) POH=XXXXh
                local dev cls poh
                dev=$(printf "%s" "$l" | awk '{print $1}')
                cls=$(printf "%s" "$l" | awk -F'[()]' '{print $2}')
                poh=$(printf "%s" "$l" | awk -F'POH=' '{print $2}' | tr -d 'h')
                [[ -z "$dev" || -z "$poh" ]] && continue
                [[ "$poh" =~ ^[0-9]+$ ]] || continue
                _rank+=("$poh $dev $cls")
            done < <(printf "%s\n" "${AGE_AWARE_LINES}")
            if (( ${#_rank[@]} > 0 )); then
                local _sorted _line="" _top=${AGE_AWARE_TOP_N:-5}
                _sorted=$(printf "%s\n" "${_rank[@]}" | sort -nr -k1,1 | head -n "$_top")
                while read -r poh dev cls; do
                    local suffix="${poh}h"
                    if [[ -n "$cls" && "$cls" != "age" ]]; then
                        _line+="$(basename "$dev") ${suffix} (${cls}); "
                    else
                        _line+="$(basename "$dev") ${suffix}; "
                    fi
                done < <(printf "%s\n" "$_sorted")
                _line="${_line%'; '}"
                [[ -n "$_line" ]] && _add_line "AGE↑" "$_line"
            fi
        fi
        # Smart growth and early warnings compact summaries
        if [[ -n "${SMART_GROWTH_LINE:-}" ]]; then
            local _items=() _part
            IFS=';' read -r -a _parts <<< "${SMART_GROWTH_LINE}" || true
            for _part in "${_parts[@]}"; do
                _part=$(echo "$_part" | awk 'NF')
                [[ -z "$_part" ]] && continue
                if [[ "$_part" =~ -[0-9] ]]; then _items+=("$_part"); else _items+=("🔺$_part"); fi
            done
            [[ ${#_items[@]} -gt 0 ]] && _add_line "SMART↑" "$(IFS=' | '; echo "${_items[*]}")"
        fi
        if [[ -n "${DL_SHRINK_LINE:-}" ]]; then
            local _dl_items=() _dpart
            IFS=';' read -r -a _dl_parts <<< "${DL_SHRINK_LINE}" || true
            for _dpart in "${_dl_parts[@]}"; do
                _dpart=$(echo "$_dpart" | awk 'NF')
                [[ -z "$_dpart" ]] && continue
                if [[ "$_dpart" =~ -[0-9] ]]; then _dl_items+=("$_dpart"); else _dl_items+=("🔺$_dpart"); fi
            done
            [[ ${#_dl_items[@]} -gt 0 ]] && _add_line "DL🔻" "$(IFS=' | '; echo "${_dl_items[*]}")"
        fi
        if [[ -n "${EARLY_ERR_LINE:-}" ]]; then
            local _err_items=() _epart
            IFS=';' read -r -a _err_parts <<< "${EARLY_ERR_LINE}" || true
            for _epart in "${_err_parts[@]}"; do
                _epart=$(echo "$_epart" | awk 'NF')
                [[ -z "$_epart" ]] && continue
                if [[ "$_epart" =~ -[0-9] ]]; then _err_items+=("$_epart"); else _err_items+=("🔺$_epart"); fi
            done
            [[ ${#_err_items[@]} -gt 0 ]] && _add_line "ERR↑" "$(IFS=' | '; echo "${_err_items[*]}")"
        fi
        if [[ -n "${BTRFS_SUM_LINE:-}" ]]; then
            local _b_items=() _bpart
            IFS=';' read -r -a _b_parts <<< "${BTRFS_SUM_LINE}" || true
            for _bpart in "${_b_parts[@]}"; do
                _bpart=$(echo "$_bpart" | awk 'NF')
                [[ -z "$_bpart" ]] && continue
                _b_items+=("🔺$_bpart")
            done
            [[ ${#_b_items[@]} -gt 0 ]] && _add_line "BTRFSΣ" "$(IFS=' | '; echo "${_b_items[*]}")"
        fi
        # SATA link instability (events + streak), also raises alerts here
        if (( ${SATA_LINK_INSTABILITY_ENABLED:-0} == 1 )) && [[ -f "${SATA_LINK_HISTORY_FILE}" ]]; then
            local _win_sat=${SATA_LINK_INSTABILITY_WINDOW_DAYS:-14}
            local _cut_sat
            _cut_sat=$(date -d "-${_win_sat} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
            local _lines_sat
            _lines_sat=$(tail -n 20000 "${SATA_LINK_HISTORY_FILE}" 2>/dev/null || true)
            if [[ -n "$_lines_sat" ]]; then
                declare -A _DEV_DATES _DEV_LAST_MAX _DEV_LAST_CURR
                while read -r dt dev rest; do
                    [[ -z "$dt" || -z "$dev" || "$dt" < "$_cut_sat" ]] && continue
                    _DEV_DATES["$dev"]+="$dt "
                    local mx cur
                    mx=$(echo "$rest" | awk -F'[ =]' '{for(i=1;i<=NF;i++){if($i ~ /^max=/){print $(i+1); break}}}')
                    cur=$(echo "$rest" | awk -F'[ =]' '{for(i=1;i<=NF;i++){if($i ~ /^current=/){print $(i+1); break}}}')
                    [[ -n "$mx" ]] && _DEV_LAST_MAX["$dev"]="$mx"
                    [[ -n "$cur" ]] && _DEV_LAST_CURR["$dev"]="$cur"
                done < <(printf "%s\n" "$_lines_sat")
                local _items=()
                for dev in "${!_DEV_DATES[@]}"; do
                    local -a dates=()
                    mapfile -t dates < <(printf "%s" "${_DEV_DATES[$dev]}" | tr ' ' '\n' | awk 'NF' | sort -u)
                    local count=${#dates[@]}
                    (( count==0 )) && continue
                    local streak=1
                    if (( count > 1 )); then
                        local i
                        for ((i=count-1;i>0;i--)); do
                            local curr=${dates[$i]} prev=${dates[$((i-1))]}
                            local prev_plus
                            prev_plus=$(date -d "$prev +1 day" '+%Y-%m-%d' 2>/dev/null || echo "$prev")
                            if [[ "$curr" == "$prev_plus" ]]; then ((streak++)); else break; fi
                        done
                    fi
                    local mx cur; mx=${_DEV_LAST_MAX[$dev]:-?}; cur=${_DEV_LAST_CURR[$dev]:-?}
                    local sev="" warn_thr=${SATA_LINK_INSTABILITY_STREAK_WARN:-2} crit_thr=${SATA_LINK_INSTABILITY_STREAK_CRIT:-5}
                    if (( streak >= crit_thr )); then sev="CRITICAL"; elif (( streak >= warn_thr )); then sev="WARNING"; fi
                    _items+=("$streak $count $dev $mx $cur $sev")
                    if [[ -n "$sev" ]]; then
                        local sev_lc; sev_lc=$(echo "$sev" | tr '[:upper:]' '[:lower:]')
                        record_alert "$sev_lc" "SATA Link Instability" "Disk $dev link downshift streak ${streak}d (events ${count}) ${mx}->${cur}Gb/s"
                    fi
                done
                if (( ${#_items[@]} > 0 )); then
                    local _sorted _s="" _limit=5 _cnt=0
                    _sorted=$(printf "%s\n" "${_items[@]}" | sort -nr -k1,1 -k2,2)
                    while read -r streak count dev mx cur sev; do
                        _s+="$(basename "$dev") ev=${count} st=${streak} ${mx}->${cur}${sev:+ ($sev)}; "
                        (( ++_cnt >= _limit )) && break
                    done < <(printf "%s\n" "$_sorted")
                    _s="${_s%'; '}"; _s="${_s//; / | }"; _add_line "SATA" "$_s"
                fi
            fi
        fi
        if (( ${#_TL[@]} > 0 )); then
            TREND_SECTION="Trend Analysis:\n$(printf "%s\n" "${_TL[@]}")"
            TREND_SECTION="$(printf "%s\n" "$TREND_SECTION" | trim_outer_blank_lines)"
        else
            TREND_SECTION=""
        fi
    }
}

# === Helper Function ===
# Build notification subject line
build_subject() {
    SUBJECT="Disks Health"
}

# === Main Function ===
# Summarize disk health states
build_disk_health_summary() {
    # Aggregate SMART-derived condition flags and counters for summary and downstream notification formatting
    local crit_count=0 warn_count=0 pending_count=0 uncorrect_count=0 high_temp=0 nvme_wear_warn=0 read_only=0 reliability=0 timeout_warn=0 realloc_events_warn=0 end2end_count=0 soft_read_warn=0
    local nvme_errlog_incr=0 nvme_pcie_corr_incr=0 nvme_pcie_unc_incr=0 nvme_therm_t1_incr=0 nvme_therm_t2_incr=0 nvme_warn_tt_incr=0 nvme_crit_tt_incr=0
    local selftest_crit=0 selftest_warn=0
    local poh_hdd=0 poh_ssd=0 poh_nvme=0
    local btrfs_dev_errs=0 xfs_meta_anoms=0 sata_link_down=0 tbw_consumed_warn=0 tbw_consumed_crit=0
    for dev in "${!SMART_STATE[@]}"; do
        local st="${SMART_STATE[$dev]:-OK}" msg="${SMART_MSGS[$dev]:-}"
        # Severity tallies
        if [[ $st == CRITICAL ]]; then ((++crit_count)); fi
        if [[ $st == WARNING ]]; then ((++warn_count)); fi
        # Attribute / message pattern tallies
        if [[ $msg == *"Pending sectors"* ]]; then ((++pending_count)); fi
        if [[ $msg == *"Offline Uncorrectable"* || $msg == *"Reported Uncorrectable"* ]]; then ((++uncorrect_count)); fi
        if [[ $msg == *"Temp"* ]]; then ((++high_temp)); fi
        if [[ $msg == *"NVMe wear"* ]]; then ((++nvme_wear_warn)); fi
        if [[ $msg == *"read-only mode"* ]]; then ((++read_only)); fi
        if [[ $msg == *"reliability degraded"* ]]; then ((++reliability)); fi
        if [[ $msg == *"Command Timeout"* ]]; then ((++timeout_warn)); fi
        if [[ $msg == *"Reallocated Event Count"* ]]; then ((++realloc_events_warn)); fi
        if [[ $msg == *"NVMe error log entries increased"* ]]; then ((++nvme_errlog_incr)); fi
        if [[ $msg == *"NVMe PCIe correctable errors increased"* ]]; then ((++nvme_pcie_corr_incr)); fi
        if [[ $msg == *"NVMe PCIe uncorrectable errors increased"* ]]; then ((++nvme_pcie_unc_incr)); fi
        if [[ $msg == *"NVMe thermal transitions T1 increased"* ]]; then ((++nvme_therm_t1_incr)); fi
        if [[ $msg == *"NVMe thermal transitions T2 increased"* ]]; then ((++nvme_therm_t2_incr)); fi
        if [[ $msg == *"NVMe warning temperature time"* ]]; then ((++nvme_warn_tt_incr)); fi
        if [[ $msg == *"NVMe critical temperature time"* ]]; then ((++nvme_crit_tt_incr)); fi
        if [[ $msg == *"End-to-End Errors"* ]]; then ((++end2end_count)); fi
        if [[ $msg == *"Soft Read Error Rate"* ]]; then ((++soft_read_warn)); fi
        if [[ $msg == *"POH age HDD"* ]]; then ((++poh_hdd)); fi
        if [[ $msg == *"POH age SSD"* ]]; then ((++poh_ssd)); fi
        if [[ $msg == *"POH age NVMe"* ]]; then ((++poh_nvme)); fi
        if [[ $msg == *"Btrfs device errors"* ]]; then ((++btrfs_dev_errs)); fi
        if [[ $msg == *"XFS metadata anomalies"* ]]; then ((++xfs_meta_anoms)); fi
        if [[ $msg == *"SATA link downshift"* ]]; then ((++sata_link_down)); fi
        if [[ $msg == *"TBW consumed"* ]]; then
            if echo "$msg" | grep -q "TBW consumed .*>= ${TBW_CONSUMED_CRIT}%"; then ((++tbw_consumed_crit)); else ((++tbw_consumed_warn)); fi
        fi
        if [[ $msg == *"Self-test critical"* ]]; then ((++selftest_crit)); fi
        if [[ $msg == *"Self-test warning"* ]]; then ((++selftest_warn)); fi
    done
    CRIT_DISK_COUNT=$crit_count
    WARN_DISK_COUNT=$warn_count
    local lines=("Disk Health Summary:")
    add_line() { local k="$1"; local v="$2"; if (( ${SHOW_ZERO_COUNTS:-0}==1 )) || (( v>0 )); then lines+=(" - $k: $v"); fi; }
    add_line "Critical" "$crit_count"
    add_line "Warning" "$warn_count"
    local parity_invalid=0
    # Only mark invalid when array is idle; suppress during active parity operations
    if [[ "${PARITY_CLEAN_FLAG:-}" == "0" ]]; then
        if [[ -z "${PARITY_ACTION:-}" || "${PARITY_ACTION,,}" == "idle" ]]; then
            parity_invalid=1
        fi
    fi
    add_line "Parity invalid" "$parity_invalid"
    add_line "Pending sectors" "$pending_count"
    add_line "Uncorrectable errors" "$uncorrect_count"
    add_line "High temp" "$high_temp"
    add_line "NVMe wear" "$nvme_wear_warn"
    add_line "NVMe read-only" "$read_only"
    add_line "NVMe reliability" "$reliability"
    add_line "NVMe error log growth" "$nvme_errlog_incr"
    add_line "NVMe PCIe corr errors" "$nvme_pcie_corr_incr"
    add_line "NVMe PCIe unc errors" "$nvme_pcie_unc_incr"
    add_line "NVMe thermal T1" "$nvme_therm_t1_incr"
    add_line "NVMe thermal T2" "$nvme_therm_t2_incr"
    add_line "NVMe warn temp time" "$nvme_warn_tt_incr"
    add_line "NVMe crit temp time" "$nvme_crit_tt_incr"
    add_line "Command timeouts" "$timeout_warn"
    add_line "Reallocation events" "$realloc_events_warn"
    add_line "End-to-end errors" "$end2end_count"
    add_line "Soft read errors" "$soft_read_warn"
    add_line "POH age HDD" "$poh_hdd"
    add_line "POH age SSD" "$poh_ssd"
    add_line "POH age NVMe" "$poh_nvme"
    add_line "Btrfs device errors" "$btrfs_dev_errs"
    add_line "XFS metadata anomalies" "$xfs_meta_anoms"
    add_line "SATA link downshift" "$sata_link_down"
    add_line "TBW consumed critical" "$tbw_consumed_crit"
    add_line "TBW consumed warning" "$tbw_consumed_warn"
    add_line "Self-test critical" "$selftest_crit"
    add_line "Self-test warning" "$selftest_warn"
    if (( ${#lines[@]} == 1 )); then
        lines+=(" - No issues detected")
    fi
    DISK_HEALTH_SUMMARY="$(printf "%s\n" "${lines[@]}")"
    DISK_HEALTH_SUMMARY="$(printf "%s\n" "$DISK_HEALTH_SUMMARY" | trim_outer_blank_lines)"
}

# === Main Function ===
# Compute risk scores for disks based on SMART attributes and categorize into lifecycle buckets
compute_risk_and_lifecycle() {
    (( RISK_SCORING_ENABLED == 1 )) || return 0
    # Derive per-disk risk scores from SMART-derived messages and attributes
    local age_lines=""
    declare -g -A RISK_MAP AGE_CLASS
    declare -g AGE_AWARE_LINES
    AGE_AWARE_LINES=""
    declare -A RISK
    # Compute per-device risk scores
    for dev in "${!SMART_STATE[@]}"; do
        local st="${SMART_STATE[$dev]:-OK}"
        local msg="${SMART_MSGS[$dev]:-}"
        local score=0
        case "$st" in
            CRITICAL) ((score += W_SEV_CRIT));;
            WARNING)  ((score += W_SEV_WARN));;
        esac
        [[ $msg == *"Pending sectors"* ]] && ((score += W_PENDING))
        [[ $msg == *"Offline Uncorrectable"* || $msg == *"Reported Uncorrectable"* ]] && ((score += W_UNCORR))
        [[ $msg == *"Reallocated ="* ]] && ((score += W_REALLOC))
        [[ $msg == *"Reallocated Event Count"* ]] && ((score += W_REALLOC_EVENTS))
        [[ $msg == *"Command Timeout"* ]] && ((score += W_CMD_TIMEOUT))
        [[ $msg == *"UDMA CRC Errors"* ]] && ((score += W_CRC))
        [[ $msg == *"SSD life remaining"* ]] && ((score += W_SSD_LIFE))
        [[ $msg == *"NVMe wear"* ]] && ((score += W_NVME_WEAR))
        [[ $msg == *"NVMe error log entries increased"* ]] && ((score += W_NVME_ERR_LOG))
        [[ $msg == *"NVMe PCIe correctable errors increased"* ]] && ((score += W_NVME_PCIE_CORR))
        [[ $msg == *"NVMe PCIe uncorrectable errors increased"* ]] && ((score += W_NVME_PCIE_UNC))
        [[ $msg == *"NVMe thermal transitions T1 increased"* ]] && ((score += W_NVME_THERM_TRANS))
        [[ $msg == *"NVMe thermal transitions T2 increased"* ]] && ((score += W_NVME_THERM_TRANS))
        [[ $msg == *"NVMe warning temperature time"* ]] && ((score += W_NVME_TEMP_TIME))
        [[ $msg == *"NVMe critical temperature time"* ]] && ((score += W_NVME_TEMP_TIME))
        [[ $msg == *"POH age HDD"* ]] && ((score += W_POH_HDD))
        [[ $msg == *"POH age SSD"* ]] && ((score += W_POH_SSD))
        [[ $msg == *"POH age NVMe"* ]] && ((score += W_POH_NVME))
        [[ $msg == *"Btrfs device errors"* ]] && ((score += W_BTRFS_DEV_ERR))
        [[ $msg == *"XFS metadata anomalies"* ]] && ((score += W_XFS_META_ERR))
        [[ $msg == *"SATA link downshift"* ]] && ((score += W_SATA_LINK_DOWN))
        [[ $msg == *"Self-test critical"* || $msg == *"long self-test CRITICAL"* ]] && ((score += W_SELFTEST_CRIT))
        [[ $msg == *"Self-test warning"* || $msg == *"short self-test warning"* ]] && ((score += W_SELFTEST_WARN))
        [[ $msg == *"Temp"* ]] && ((score += W_TEMP))
        [[ $msg == *"End-to-End Errors"* ]] && ((score += W_E2E))
        [[ $msg == *"Soft Read Error Rate"* ]] && ((score += W_SOFT_READ))
        [[ $msg == *"read-only mode"* ]] && ((score += W_NVME_RO))
        [[ $msg == *"reliability degraded"* ]] && ((score += W_NVME_REL))
        local poh=0 percent_used=0 life_remain=0
        if [[ $dev == /dev/nvme* ]]; then
            percent_used=${CUR_ATTR["$dev|nvme_percent_used"]:-0}
            poh=${CUR_ATTR["$dev|poh"]:-0}
            if (( percent_used >= 90 )); then ((score += W_AGE_NEAR)); AGE_CLASS[$dev]="Near endurance"; fi
        else
            poh=${CUR_ATTR["$dev|poh"]:-0}
            life_remain=${CUR_ATTR["$dev|life_remain"]:-0}
            if [[ $life_remain -gt 0 && $life_remain -le 10 ]]; then ((score += W_AGE_NEAR)); AGE_CLASS[$dev]="Near endurance"; fi
        fi
        if [[ -n "${CUR_ATTR["$dev|tbw_consumed_pct"]:-}" ]]; then
            local _tc=${CUR_ATTR["$dev|tbw_consumed_pct"]}
            if (( _tc >= TBW_CONSUMED_CRIT )); then ((score += W_TBW_CONS_CRIT))
            elif (( _tc >= TBW_CONSUMED_WARN )); then ((score += W_TBW_CONS_WARN)); fi
        fi
        RISK[$dev]=$score
        RISK_MAP[$dev]=$score
        if (( AGE_AWARE_ENABLED==1 )); then
            local cls="${AGE_CLASS[$dev]:-}"
            local poh_num="${poh//,/}"
            if [[ -n "$cls" ]] || (( 10#${poh_num:-0} > 0 )); then
                age_lines+="$(basename "$dev") (${cls:-age}) POH=${poh}h\n"
            fi
        fi
    done

    # Build top-N list of highest non-zero risk scores for display
    local scored_list filtered idx
    idx=0
    scored_list=$(for d in "${!RISK[@]}"; do echo "${RISK[$d]} $d"; done | sort -nr -k1,1)
    filtered=$(printf "%s\n" "$scored_list" | awk '$1+0>0')
    local replace_inline=() monitor_inline=() healthy_inline=()
    while read -r sc dv; do
        [[ -z "$dv" ]] && continue
        local base_dev
        base_dev="$(basename "$dv")"
        # Exclude md* pseudo devices from display
        if [[ "$base_dev" == md* ]]; then continue; fi
        local tag="${base_dev}(${sc})"
        if (( sc >= RISK_REPLACE )); then
            replace_inline+=("$tag")
        elif (( sc >= RISK_MONITOR )); then
            monitor_inline+=("$tag")
        else
            healthy_inline+=("$tag")
        fi
        (( ++idx >= RISK_TOP_N )) && break
    done < <(printf "%s\n" "$filtered")
    # Bucket disks into replace/monitor/healthy based on score thresholds
    if (( LIFECYCLE_ENABLED == 1 )); then
        local replace=() monitor=() healthy=()
        for d in "${!RISK[@]}"; do
            local s=${RISK[$d]}
            local bname
            bname="$(basename "$d")"
            # Exclude md* pseudo devices from display
            if (( s >= RISK_REPLACE )); then [[ $bname == md* ]] || replace+=("$bname")
            elif (( s >= RISK_MONITOR )); then [[ $bname == md* ]] || monitor+=("$bname")
            else [[ $bname == md* ]] || healthy+=("$bname")
            fi
        done
        REPLACE_COUNT=${#replace[@]}
        MONITOR_COUNT=${#monitor[@]}
        HEALTHY_COUNT=${#healthy[@]}
        declare -g REPLACE_LIST MONITOR_LIST
        REPLACE_LIST=("${replace[@]}")
        MONITOR_LIST=("${monitor[@]}")
    fi
    # Export POH age lines for Trend section
    if (( AGE_AWARE_ENABLED==1 )) && [[ -n "$age_lines" ]]; then
        AGE_AWARE_LINES="$(printf "%s\n" "$age_lines" | trim_outer_blank_lines)"
    fi
}

# === Helper Function ===
# Append today's risk tier counts to history file
persist_risk_tier_history() {
    (( RISK_SCORING_ENABLED == 1 )) || return 0
    local today
    today=$(date '+%Y-%m-%d')
    local crit
    crit=${CRIT_DISK_COUNT:-0}
    local warn
    warn=${WARN_DISK_COUNT:-0}
    local replace_cnt
    replace_cnt=${REPLACE_COUNT:-0}
    local monitor_cnt
    monitor_cnt=${MONITOR_COUNT:-0}
    local healthy_cnt
    healthy_cnt=${HEALTHY_COUNT:-0}
    local tmp
    tmp=$(mktemp) || { log_warn "mktemp failed; skipping risk tier snapshot"; return 0; }
    if [[ -f "$RISK_TIER_HISTORY_FILE" ]]; then
        awk -v d="$today" '$1!=d{print}' "$RISK_TIER_HISTORY_FILE" > "$tmp" || true
    fi
    local repl_csv mon_csv
    if declare -p REPLACE_LIST &>/dev/null && (( ${#REPLACE_LIST[@]} > 0 )); then
        local _r=() d; for d in "${REPLACE_LIST[@]}"; do _r+=("$(basename "$d")"); done; repl_csv=$(IFS=, ; echo "${_r[*]}")
    else
        repl_csv=""
    fi
    if declare -p MONITOR_LIST &>/dev/null && (( ${#MONITOR_LIST[@]} > 0 )); then
        local _m=() d; for d in "${MONITOR_LIST[@]}"; do _m+=("$(basename "$d")"); done; mon_csv=$(IFS=, ; echo "${_m[*]}")
    else
        mon_csv=""
    fi
    echo "$today critical=$crit warning=$warn replace=$replace_cnt monitor=$monitor_cnt healthy=$healthy_cnt REPLACE_DEVICES=${repl_csv} MONITOR_DEVICES=${mon_csv}" >> "$tmp"
    mv -f "$tmp" "$RISK_TIER_HISTORY_FILE" 2>/dev/null || rm -f "$tmp" || true
    # Persist per-disk risk scores history (overwrite today's entries for each disk)
    if declare -p RISK_MAP &>/dev/null; then
        local today_r
        today_r=$(date '+%Y-%m-%d')
        local tmp_scores
        tmp_scores=$(mktemp) || { log_warn "mktemp failed; skipping risk scores history update"; tmp_scores=""; }
        if [[ -n "$tmp_scores" ]]; then
            if [[ -f "$RISK_SCORES_HISTORY_FILE" ]]; then
                awk -v d="$today_r" '$1!=d{print}' "$RISK_SCORES_HISTORY_FILE" > "$tmp_scores" || true
            fi
            for d in "${!RISK_MAP[@]}"; do
                printf '%s %s risk=%s\n' "$today_r" "$d" "${RISK_MAP[$d]}" >> "$tmp_scores"
            done
            mv -f "$tmp_scores" "$RISK_SCORES_HISTORY_FILE" 2>/dev/null || true
        fi
    fi
}

# === Main Function ===
# Compute share usage breakdown and growth trends
compute_share_breakdown() {
    # Gate on feature toggle and presence of /mnt/user
    (( SHARE_BREAKDOWN_ENABLED == 1 )) || { return 0; }
    local root="/mnt/user"
    [[ -d "$root" ]] || { return 0; }
    local today
    today=$(date '+%Y-%m-%d')
    local shares=()
    # Enumerate first-level shares under /mnt/user
    while IFS= read -r d; do shares+=("$d"); done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    [[ ${#shares[@]} -eq 0 ]] && { return 0; }
    local name path bytes
    # Measure current share sizes and append to history for growth analysis
    for path in "${shares[@]}"; do
        name=$(basename "$path")
        bytes=$(du -sb "$path" 2>/dev/null | awk '{print $1}')
        bytes=${bytes:-0}
        echo "$today $name bytes=$bytes" >> "$SHARE_USAGE_HISTORY_FILE"
    done
    return 0
}

# === Main Function ===
# Track capacity usage history, compute growth trends, estimate days to threshold, export JSON
capacity_forecast_and_export() {
    # Consolidated math using scaled integers (milli-percent) to reduce multiple awk processes.
    convert_pct_to_milli() { 
        local p="$1"
        if [[ $p =~ ^[0-9]+$ ]]; then
            echo $(( 10#$p * 1000 ))
        elif [[ $p =~ ^([0-9]+)\.([0-9]+)$ ]]; then
            local whole=${BASH_REMATCH[1]}
            local frac=${BASH_REMATCH[2]}
            frac=${frac:0:3}
            while (( ${#frac} < 3 )); do frac+="0"; done
            echo $(( 10#$whole * 1000 + 10#$frac ))
        else
            echo 0
        fi
    }
    local now_date
    now_date=$(date '+%Y-%m-%d')
    # Prefer computing percent from bytes for maximum precision
    local arr_bu arr_bs pool_bu pool_bs
    arr_bu=${ARRAY_USED_BYTES:-0}
    arr_bs=${ARRAY_TOTAL_BYTES:-0}
    pool_bu=${POOLS_USED_BYTES:-0}
    pool_bs=${POOLS_TOTAL_BYTES:-0}
    local array_pct pools_pct
    if [[ "$arr_bs" =~ ^[0-9]+$ && $arr_bs -gt 0 ]]; then
        array_pct=$(awk -v bu="$arr_bu" -v bs="$arr_bs" 'BEGIN{printf "%.6f", (bu/bs)*100}')
    else
        array_pct="${ARRAY_PERCENT:-0}"
    fi
    if [[ "$pool_bs" =~ ^[0-9]+$ && $pool_bs -gt 0 ]]; then
        pools_pct=$(awk -v bu="$pool_bu" -v bs="$pool_bs" 'BEGIN{printf "%.6f", (bu/bs)*100}')
    else
        pools_pct="${POOLS_PERCENT:-0}"
    fi
    # Persist both percent and raw bytes for back-compat and better precision
    echo "$now_date array=$array_pct pools=$pools_pct arr_bu=$arr_bu arr_bs=$arr_bs pool_bu=$pool_bu pool_bs=$pool_bs" >> "$CAPACITY_HISTORY_FILE"
    local arr_prev=() pool_prev=() dates=()
    local lines
    lines=$(tail -n $HISTORY_WINDOW_DAYS "$CAPACITY_HISTORY_FILE" 2>/dev/null || true)
    while read -r l; do
        [[ -z "$l" ]] && continue
        dates+=("$l")
        # Prefer computing percent from persisted bytes; fallback to stored percent fields
        local _abu _abs _pbu _pbs _apct _ppct
        _abu=$(awk 'match($0, /arr_bu=([0-9]+)/, m){print m[1]}' <<< "$l")
        _abs=$(awk 'match($0, /arr_bs=([0-9]+)/, m){print m[1]}' <<< "$l")
        _pbu=$(awk 'match($0, /pool_bu=([0-9]+)/, m){print m[1]}' <<< "$l")
        _pbs=$(awk 'match($0, /pool_bs=([0-9]+)/, m){print m[1]}' <<< "$l")
        if [[ -n "$_abu" && -n "$_abs" && $_abs -gt 0 ]]; then
            _apct=$(awk -v bu="$_abu" -v bs="$_abs" 'BEGIN{printf "%.6f", (bu/bs)*100}')
        else
            _apct=$(awk 'match($0, /array=([0-9.]+)/, m){print m[1]}' <<< "$l")
        fi
        if [[ -n "$_pbu" && -n "$_pbs" && $_pbs -gt 0 ]]; then
            _ppct=$(awk -v bu="$_pbu" -v bs="$_pbs" 'BEGIN{printf "%.6f", (bu/bs)*100}')
        else
            _ppct=$(awk 'match($0, /pools=([0-9.]+)/, m){print m[1]}' <<< "$l")
        fi
        arr_prev+=("${_apct:-0}")
        pool_prev+=("${_ppct:-0}")
    done < <(printf "%s\n" "$lines")
    local arr_growth_m=0 pool_growth_m=0 count=${#arr_prev[@]}
    if (( count > 1 )); then
        if (( DYNAMIC_GROWTH == 1 )); then
            local first_line last_line first_date last_date first_arr last_arr first_pool last_pool days_elapsed days_elapsed_p
            first_line="${dates[0]}"; last_line="${dates[$((count-1))]}"
            first_date="${first_line%% *}"; last_date="${last_line%% *}"
            first_arr="${arr_prev[0]}"; last_arr="${arr_prev[$((count-1))]}"
            first_pool="${pool_prev[0]}"; last_pool="${pool_prev[$((count-1))]}"
            days_elapsed=$(( ( $(date -d "$last_date" +%s 2>/dev/null || date +%s) - $(date -d "$first_date" +%s 2>/dev/null || date +%s) ) / 86400 ))
            (( days_elapsed <= 0 )) && days_elapsed=1
            days_elapsed_p=$days_elapsed
            if [[ $first_arr =~ ^[0-9.]+$ && $last_arr =~ ^[0-9.]+$ ]]; then
                local fa_m la_m
                fa_m=$(convert_pct_to_milli "$first_arr")
                la_m=$(convert_pct_to_milli "$last_arr")
                if (( la_m > fa_m )); then
                    arr_growth_m=$(( (la_m - fa_m) / days_elapsed ))
                    # Preserve tiny positive growth by clamping to minimum 1 milli-%%/day
                    (( arr_growth_m == 0 )) && arr_growth_m=1
                fi
            fi
            if [[ $first_pool =~ ^[0-9.]+$ && $last_pool =~ ^[0-9.]+$ ]]; then
                local fp_m lp_m
                fp_m=$(convert_pct_to_milli "$first_pool")
                lp_m=$(convert_pct_to_milli "$last_pool")
                if (( lp_m > fp_m )); then
                    pool_growth_m=$(( (lp_m - fp_m) / days_elapsed_p ))
                    (( pool_growth_m == 0 )) && pool_growth_m=1
                fi
            fi
        else
            local i prev_m cur_m accum_arr=0 accum_pool=0 delta_count=0
            for ((i=1;i<count;i++)); do
                if [[ ${arr_prev[$i]} =~ ^[0-9.]+$ && ${arr_prev[$((i-1))]} =~ ^[0-9.]+$ ]]; then
                    cur_m=$(convert_pct_to_milli "${arr_prev[$i]}")
                    prev_m=$(convert_pct_to_milli "${arr_prev[$((i-1))]}")
                    (( cur_m > prev_m )) && accum_arr=$(( accum_arr + (cur_m - prev_m) ))
                fi
                if [[ ${pool_prev[$i]} =~ ^[0-9.]+$ && ${pool_prev[$((i-1))]} =~ ^[0-9.]+$ ]]; then
                    cur_m=$(convert_pct_to_milli "${pool_prev[$i]}")
                    prev_m=$(convert_pct_to_milli "${pool_prev[$((i-1))]}")
                    (( cur_m > prev_m )) && accum_pool=$(( accum_pool + (cur_m - prev_m) ))
                fi
            done
            delta_count=$(( count - 1 ))
            if (( delta_count > 0 )); then
                arr_growth_m=$(( accum_arr / delta_count ))
                pool_growth_m=$(( accum_pool / delta_count ))
                # Clamp to minimum 1 milli-%%/day when there is net positive growth
                (( arr_growth_m == 0 && accum_arr > 0 )) && arr_growth_m=1
                (( pool_growth_m == 0 && accum_pool > 0 )) && pool_growth_m=1
            fi
        fi
    fi
    local days_to_arr_thresh="N/A" days_to_pool_thresh="N/A"
    local arr_pct_m pools_pct_m thresh_m
    arr_pct_m=$(convert_pct_to_milli "$array_pct")
    pools_pct_m=$(convert_pct_to_milli "$pools_pct")
    thresh_m=$(convert_pct_to_milli "$THRESHOLD")
    if (( arr_growth_m > 0 )); then
        local left_m=$(( thresh_m - arr_pct_m ))
        if (( left_m <= 0 )); then days_to_arr_thresh="0"; else days_to_arr_thresh=$(printf '%.1f' "$(( left_m * 10 / arr_growth_m ))" | awk '{printf "%s", $1/10}') ; fi
    elif (( arr_pct_m < thresh_m )); then
        # Non-positive growth but below threshold -> effectively infinite days
        days_to_arr_thresh="INF"
    fi
    if (( pool_growth_m > 0 )); then
        local left_pm=$(( thresh_m - pools_pct_m ))
        if (( left_pm <= 0 )); then days_to_pool_thresh="0"; else days_to_pool_thresh=$(printf '%.1f' "$(( left_pm * 10 / pool_growth_m ))" | awk '{printf "%s", $1/10}') ; fi
    elif (( pools_pct_m < thresh_m )); then
        days_to_pool_thresh="INF"
    fi
    fmt_growth() {
        # Format daily growth with higher precision
        local gm="$1"
        if (( gm <= 0 )); then printf "0%%"; return; fi
        # Convert milli-percent to percent float with configured decimals
        local decs=${FORECAST_PRECISION_DECIMALS:-3}
        awk -v m="$gm" -v d="$decs" 'BEGIN{p=m/1000.0; fmt="%0."d"f%%"; printf(fmt,p)}'
    }
    local arr_g_str pool_g_str
    arr_g_str=$(fmt_growth "$arr_growth_m")
    pool_g_str=$(fmt_growth "$pool_growth_m")
    fmt_days() {
        local v="$1"
        case "$v" in
            INF) echo "∞" ;;
            ""|N/A) echo "N/A" ;;
            *) awk -v x="$v" 'BEGIN{printf "%d", (x==0)?0:int(x+0.999)}' ;;
        esac
    }
    local arr_days_str pool_days_str
    arr_days_str=$(fmt_days "$days_to_arr_thresh")
    pool_days_str=$(fmt_days "$days_to_pool_thresh")
    ARR_DAYS_TO_THRESHOLD="$arr_days_str"
    POOL_DAYS_TO_THRESHOLD="$pool_days_str"
    ARR_GROWTH_STR="$arr_g_str"
    POOL_GROWTH_STR="$pool_g_str"
    ARR_HISTORY_COUNT="$count"  # sample count for capacity forecast
    POOL_HISTORY_COUNT="$count"
}

# === Main Function ===
# Analyze TBW history to estimate daily write rates and days to threshold
tbw_forecast_and_heavy_writers() {
    # Forecast days-to-endurance threshold and list heavy writers (normalized by capacity)
    (( ${TBW_TREND_ENABLED:-1} == 1 )) || { return 0; }
    TBW_DAILY=()
    TBW_DAYS_LEFT=()
    TBW_STATUS_MAP=()
    local today
    today=$(date '+%Y-%m-%d')
    for dev in "${!SMART_STATE[@]}"; do
        local tbw=${CUR_ATTR["$dev|tbw_bytes"]:-}
        [[ -n "$tbw" ]] && echo "$today $dev tbw=$tbw" >> "$TBW_HISTORY_FILE"
    done
    local win=$HISTORY_WINDOW_DAYS
    # Compute per-device daily TBW deltas over window and estimate days to threshold
    local cutoff
    cutoff=$(date -d "-$win days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
    local lines
    lines=$(tail -n 50000 "$TBW_HISTORY_FILE" 2>/dev/null || true)
    [[ -z "$lines" ]] && { return 0; }
    local tmp
    tmp=$(mktemp) || { log_warn "mktemp failed; skipping TBW window aggregation"; return 0; }
    printf "%s\n" "$lines" | awk -v c="$cutoff" '$1>=c{print}' | awk '{d=$2; for(i=3;i<=NF;i++){split($i,a,"="); if(a[1]=="tbw") v=a[2]} if(d!="" && v!="" && v ~ /^[0-9]+$/){print $1,d,v}}' > "$tmp"
    declare -A first_dt first_v last_dt last_v
    while read -r dt dev v; do
        if [[ -z "${first_dt[$dev]:-}" || "$dt" < "${first_dt[$dev]}" ]]; then first_dt[$dev]="$dt"; first_v[$dev]="$v"; fi
        if [[ -z "${last_dt[$dev]:-}" || "$dt" > "${last_dt[$dev]}" ]]; then last_dt[$dev]="$dt"; last_v[$dev]="$v"; fi
    done < "$tmp"
    rm -f "$tmp"
    declare -a heavy_rank=()
    for dev in "${!last_v[@]}"; do
        local start=${first_v[$dev]:-0} end=${last_v[$dev]:-0}
        [[ ! "$start" =~ ^[0-9]+$ || ! "$end" =~ ^[0-9]+$ ]] && continue
        local days
        days=$(awk -v lts="$(date -d "${last_dt[$dev]}" +%s 2>/dev/null || date +%s)" -v fts="$(date -d "${first_dt[$dev]}" +%s 2>/dev/null || date +%s)" 'BEGIN{d=int((lts-fts)/86400); if(d<=0)d=1; print d}')
        # Debug: log values if anything is non-numeric before proceeding
        if ! awk -v e="$end" -v s="$start" -v d="$days" 'BEGIN{exit (e ~ /^[0-9]+$/ && s ~ /^[0-9]+$/ && d ~ /^[0-9]+$/)?0:1}'; then
            log_warn "TBW debug: skipping dev=$(basename "$dev") start='$start' end='$end' days='$days' (non-numeric)"
            continue
        fi
        if awk -v e="$end" -v s="$start" 'BEGIN{exit !(e+0>s+0)}'; then
            local daily
            daily=$(awk -v e="$end" -v s="$start" -v d="$days" 'BEGIN{printf "%d", int(((e+0)-(s+0))/(d+0))}')
            TBW_DAILY[$dev]=$daily
            local model cap tbw_thresh
            model=$(get_device_model "$dev")
            cap=$(get_device_capacity_tb "$dev")
            tbw_thresh=$(tbw_threshold_tb_for_device "$model" "$cap")
            local total_bytes="" remaining_bytes="" days_left=""
            if [[ -n "$tbw_thresh" ]]; then
                # Compute total_bytes using awk to avoid arithmetic errors on non-numeric inputs
                if [[ "$tbw_thresh" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    total_bytes=$(awk -v th="$tbw_thresh" 'BEGIN{printf "%d", int(th * 1000*1000*1000*1000)}')
                else
                    log_warn "TBW debug: non-numeric tbw_thresh for dev=$(basename "$dev") model='$model' cap='$cap' tbw_thresh='$tbw_thresh'"
                    total_bytes=""
                fi
            else
                local used_pct=${CUR_ATTR["$dev|nvme_percent_used"]:-}
                if [[ -n "$used_pct" && "$used_pct" =~ ^[0-9]+$ ]] && awk -v u="$used_pct" 'BEGIN{exit !(u+0>0)}'; then
                    total_bytes=$(awk -v e="$end" -v u="$used_pct" 'BEGIN{printf "%d", int((e+0)*100/(u+0))}')
                else
                    # Fallback for SATA/NVMe SSDs with unknown model endurance: use DEFAULT_SSD_ENDURANCE_PER_TB
                    local bd rota
                    bd=$(base_device "$dev")
                    rota=$(lsblk_rota_cached "$bd" 2>/dev/null || echo 1)
                    if [[ "$rota" == "0" ]]; then
                        # SSD: use capacity * DEFAULT_SSD_ENDURANCE_PER_TB
                        if [[ -n "$cap" && "$cap" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                            total_bytes=$(awk -v c="$cap" -v p="$DEFAULT_SSD_ENDURANCE_PER_TB" 'BEGIN{printf "%d", int(c*p*1000*1000*1000*1000)}')
                        fi
                    fi
                fi
            fi
            [[ ! "$total_bytes" =~ ^[0-9]+$ ]] && total_bytes=""
            if [[ -n "$total_bytes" ]] && awk -v t="$total_bytes" -v e="$end" -v d="$daily" 'BEGIN{exit !(t+0>e+0 && d+0>0)}'; then
                remaining_bytes=$(awk -v t="$total_bytes" -v e="$end" 'BEGIN{printf "%d", (t+0) - (e+0)}')
                days_left=$(awk -v r="$remaining_bytes" -v d="$daily" 'BEGIN{printf "%.1f", (r+0)/(d+0)}')
                TBW_DAYS_LEFT[$dev]=$days_left
                local status="OK"
                if [[ -n "$days_left" ]]; then
                    if awk -v dl="$days_left" -v c="$TBW_DAYS_CRIT" 'BEGIN{exit !(dl+0<c+0)}'; then
                        status="CRITICAL"
                    elif awk -v dl="$days_left" -v w="$TBW_DAYS_WARN" 'BEGIN{exit !(dl+0<w+0)}'; then
                        status="WARNING"
                    fi
                fi
                TBW_STATUS_MAP[$dev]="$status"
            else
                log_warn "TBW debug: insufficient data for dev=$(basename "$dev") total_bytes='$total_bytes' end='$end' daily='$daily'"
            fi
            local cap_tb
            cap_tb=$(printf "%s" "$cap" | awk '/^[0-9]+(\.[0-9]+)?$/{print ($0+0)}')
            if awk -v c="$cap_tb" 'BEGIN{exit !(c+0>0)}'; then
                local norm_pct
                norm_pct=$(awk -v daily="$daily" -v cap_tb="$cap_tb" 'BEGIN{printf "%.6f", ((daily+0)/ (cap_tb*1000000000000.0))*100}')
                heavy_rank+=("$norm_pct $dev $daily $cap_tb")
            fi
        fi
    done
    if (( ${#heavy_rank[@]} > 0 )); then
        # Persist top heavy writers normalized rate to history
        local sorted
        sorted=$(printf "%s\n" "${heavy_rank[@]}" | sort -nr -k1,1 | head -n 5)
        while read -r pct dev daily cap_tb; do
            [[ -z "$dev" ]] && continue
            echo "$today $dev norm=$pct daily=$daily" >> "$HEAVY_WRITER_HISTORY_FILE"
        done < <(printf "%s\n" "$sorted")
    fi
    # Generate TBW endurance alerts
    if declare -p TBW_DAYS_LEFT >/dev/null 2>&1; then
        for dev in "${!TBW_DAYS_LEFT[@]}"; do
        local days_left=${TBW_DAYS_LEFT[$dev]}
        local status=${TBW_STATUS_MAP[$dev]:-OK}
        if [[ "$status" == "CRITICAL" ]]; then
            record_alert critical "TBW Endurance" "Disk $dev TBW forecast CRITICAL: ${days_left}d remaining (<${TBW_DAYS_CRIT}d)"
        elif [[ "$status" == "WARNING" ]]; then
            record_alert warning "TBW Endurance" "Disk $dev TBW forecast WARNING: ${days_left}d remaining (<${TBW_DAYS_WARN}d)"
        fi
        done
    fi
    # Persist TBW days-left snapshot (once daily) for trend analysis
    if (( ${TBW_TREND_ENABLED:-0} == 1 )); then
        if declare -p TBW_DAYS_LEFT >/dev/null 2>&1; then
            local __have_keys=0
            for __k in "${!TBW_DAYS_LEFT[@]}"; do __have_keys=1; break; done
            if (( __have_keys == 1 )); then
        local today tmp
        today=$(date '+%Y-%m-%d')
        if [[ -f "$TBW_DAYSLEFT_HISTORY_FILE" ]]; then
            tmp=$(mktemp) || { log_warn "mktemp failed; skipping TBW days-left history dedup"; tmp=""; }
            if [[ -n "$tmp" ]]; then
                awk -v d="$today" '$1!=d' "$TBW_DAYSLEFT_HISTORY_FILE" > "$tmp" 2>/dev/null || true
                mv -f "$tmp" "$TBW_DAYSLEFT_HISTORY_FILE" 2>/dev/null || rm -f "$tmp" || true
            fi
        fi
                for dev in "${!TBW_DAYS_LEFT[@]}"; do
            local dl
            dl="${TBW_DAYS_LEFT[$dev]}"
            [[ -n "$dl" ]] && echo "$today $dev days_left=${dl}" >> "$TBW_DAYSLEFT_HISTORY_FILE"
        done
            fi
        fi
    fi
}

# === Helper Function ===
# Detect firmware/controller resets by checking for Power-On Hours (POH) drops and NVMe Percentage Used regression
detect_counter_resets() {
    local events=""
    for dev in "${!SMART_STATE[@]}"; do
        local prev_poh=${PREV_ATTR["$dev|poh"]:-}
        local curr_poh=${CUR_ATTR["$dev|poh"]:-}
        if [[ -n "$prev_poh" && -n "$curr_poh" && "$prev_poh" =~ ^[0-9]+$ && "$curr_poh" =~ ^[0-9]+$ && $curr_poh -lt $prev_poh ]]; then
            local drop=$(( prev_poh - curr_poh ))
            local sev="warning"
            if (( drop > POH_RESET_CRIT_THRESHOLD )); then sev="critical"; fi
            events+=" - $(basename "$dev") POH regression: ${prev_poh}h -> ${curr_poh}h (drop ${drop}h)\n"
            record_alert "$sev" "Firmware Reset" "Disk $dev Power-On Hours dropped (${prev_poh} -> ${curr_poh}) possible controller/firmware reset"
        fi
        if [[ "$dev" == /dev/nvme* ]]; then
            local prev_used=${PREV_ATTR["$dev|nvme_percent_used"]:-}
            local curr_used=${CUR_ATTR["$dev|nvme_percent_used"]:-}
            if [[ -n "$prev_used" && -n "$curr_used" && "$prev_used" =~ ^[0-9]+$ && "$curr_used" =~ ^[0-9]+$ && $curr_used -lt $prev_used ]]; then
                local delta=$(( prev_used - curr_used ))
                if (( delta >= NVME_WEAR_REGRESSION_WARN )); then
                    events+=" - $(basename "$dev") NVMe percent_used regression: ${prev_used}% -> ${curr_used}% (drop ${delta}%)\n"
                    record_alert warning "Firmware Reset" "Disk $dev NVMe Percentage Used decreased (${prev_used}% -> ${curr_used}%); check firmware or controller resets"
                fi
            fi
        fi
    done
    return 0
}

detect_counter_resets

# === Main Function ===
# Collect and integrate btrfs per-device stats
collect_btrfs_device_stats() {
    # Snapshot per-device btrfs error counters; compute deltas vs previous run; raise alerts and record history
    (( ${ENABLE_BTRFS_DEVICE_STATS:-0} == 1 )) || return 0
    local prev_file="$STATE_DIR/btrfs_device_stats.prev"
    declare -A PREV_STAT
    # Load previous counters for delta computation
    if [[ -f "$prev_file" ]]; then
        while read -r dev key val; do
            [[ -z "$dev" || -z "$key" || -z "$val" ]] && continue
            PREV_STAT["$dev|$key"]="$val"
        done < "$prev_file"
    fi
    # Enumerate btrfs mountpoints
    local mts
    mts=$(mount | awk '/ btrfs /{print $3}')
    [[ -z "$mts" ]] && return 0
    local out_has=0
    true > "$prev_file.tmp"
    for m in $mts; do
        local stats
        stats=$(btrfs device stats -z "$m" 2>/dev/null || true)
        [[ -z "$stats" ]] && continue
        while read -r line; do
            [[ -z "$line" ]] && continue
            if [[ "$line" =~ ^[/]dev/ ]]; then
                local dev
                local key
                local val
                dev=$(echo "$line" | awk '{print $1}' | sed 's/://')
                key=$(echo "$line" | awk '{print $2}')
                val=$(echo "$line" | awk '{print $3}')
                [[ -z "$dev" || -z "$key" || -z "$val" ]] && continue
                # Write current snapshot line
                echo "$dev $key $val" >> "$prev_file.tmp"
                out_has=1
                if [[ "$val" =~ ^[0-9]+$ ]]; then
                        local prev
                        local delta
                        prev=${PREV_STAT["$dev|$key"]:-0}
                        delta=$(( val - prev ))
                    if (( delta > 0 )); then
                        local sev
                        sev="warning"
                        # Severity mapping: escalate for corruption/generation and large I/O deltas
                        case "$key" in
                            corruption_errs|generation_errs)
                                if (( delta >= BTRFS_DEV_CORR_CRIT_DELTA )); then
                                    sev="critical"
                                elif (( delta >= BTRFS_DEV_CORR_WARN_DELTA )); then
                                    sev="warning"
                                else
                                    # Below warn threshold -> skip alert for these keys
                                    continue
                                fi;;
                            read_io_errs|write_io_errs|flush_io_errs)
                                if (( delta >= BTRFS_DEV_ERR_CRIT_DELTA )); then sev="critical"; elif (( delta >= BTRFS_DEV_ERR_WARN_DELTA )); then sev="warning"; fi;;
                        esac
                        # Burst detection: compare current delta with previous recorded delta for same key
                        local last_delta ratio
                        last_delta=0
                        if [[ -f "$BTRFS_DEV_HIST_FILE" ]]; then
                            last_delta=$(grep -E " key=$key " "$BTRFS_DEV_HIST_FILE" 2>/dev/null | tail -n1 | awk '{for(i=1;i<=NF;i++){ if($i ~ /^delta=/){sub(/delta=/,"",$i); print $i; break } }}' || true)
                            [[ -n "$last_delta" && "$last_delta" =~ ^[0-9]+$ ]] || last_delta=0
                        fi
                        if (( last_delta > 0 )); then
                            ratio=$(awk -v d="$delta" -v l="$last_delta" 'BEGIN{ if(l>0) printf "%d", int(d/l); else print 0 }')
                            if (( ratio >= BTRFS_ERR_BURST_CRIT_RATIO )); then
                                record_alert critical "Btrfs Burst" "Device $dev $key burst delta $delta (x${ratio} vs last $last_delta) on mount $m"
                                local bdev_burst; bdev_burst=$(base_device "$dev")
                                [[ -z "${SMART_STATE[$bdev_burst]:-}" ]] && SMART_STATE[$bdev_burst]="OK"
                                SMART_MSGS[$bdev_burst]="${SMART_MSGS[$bdev_burst]:-} Btrfs burst: $key x${ratio}"
                                local cur_boost=${BURST_BOOST[$bdev_burst]:-0}; cur_boost=$(( cur_boost + BURST_CRIT_BOOST )); (( cur_boost > 100 )) && cur_boost=100; BURST_BOOST[$bdev_burst]=$cur_boost
                            elif (( ratio >= BTRFS_ERR_BURST_WARN_RATIO )); then
                                record_alert warning "Btrfs Burst" "Device $dev $key elevated delta $delta (x${ratio} vs last $last_delta) on mount $m"
                                local bdev_burst; bdev_burst=$(base_device "$dev")
                                [[ -z "${SMART_STATE[$bdev_burst]:-}" ]] && SMART_STATE[$bdev_burst]="OK"
                                SMART_MSGS[$bdev_burst]="${SMART_MSGS[$bdev_burst]:-} Btrfs burst: $key x${ratio}"
                                local cur_boost=${BURST_BOOST[$bdev_burst]:-0}; cur_boost=$(( cur_boost + BURST_WARN_BOOST )); (( cur_boost > 100 )) && cur_boost=100; BURST_BOOST[$bdev_burst]=$cur_boost
                            else
                                record_alert "$sev" "Btrfs Device" "Device $dev $key +$delta (now $val) on mount $m"
                            fi
                        else
                            record_alert "$sev" "Btrfs Device" "Device $dev $key +$delta (now $val) on mount $m"
                        fi
                        # Persist delta to time-series history
                        local today
                        today=$(date '+%Y-%m-%d')
                        echo "$today $dev mount=$m key=$key delta=$delta value=$val" >> "$BTRFS_DEV_HIST_FILE"
                        # Attach message to base block device SMART messages for summary sections
                        local bdev
                        bdev=$(base_device "$dev")
                        [[ -z "${SMART_STATE[$bdev]:-}" ]] && SMART_STATE[$bdev]="OK"
                        SMART_MSGS[$bdev]="${SMART_MSGS[$bdev]:-} Btrfs device errors: $key +$delta" 
                    fi
                fi
            fi
        done < <(echo "$stats" | awk 'NF>=3')
    done
    # Commit snapshot if we captured data; otherwise discard temp
    if (( out_has == 1 )); then
        mv "$prev_file.tmp" "$prev_file" 2>/dev/null || rm -f "$prev_file.tmp"
    else
        rm -f "$prev_file.tmp" 2>/dev/null || true
    fi
}

# === Main Function ===
# Collect and integrate xfs /proc stats (global deltas)
collect_xfs_proc_stats() {
    # Capture select global XFS counters; compute deltas to detect anomalous spikes signalling metadata pressure
    (( ${ENABLE_XFS_PROC_STATS:-0} == 1 )) || return 0
    local stat_file="/proc/fs/xfs/stat"
    [[ -r "$stat_file" ]] || return 0
    local prev_file="$XFS_PROC_PREV_FILE"
    # Optionally suppress alerting during parity operations (still capture history/snapshot)
    local suppress=0
    if (( XFS_PROC_SUPPRESS_DURING_PARITY == 1 )); then
        # Ensure parity state is refreshed (non-fatal if unavailable)
        parity_state || true
        if [[ -n "${PARITY_ACTION:-}" && "${PARITY_ACTION,,}" != "idle" ]]; then
            suppress=1
            log_xfs "$(date '+%Y-%m-%d %H:%M:%S') - Suppressing XFS proc alerts (parity action: ${PARITY_ACTION})"
        fi
    fi
    declare -A PREV_XFS
    # Load previous snapshot for delta computation
    if [[ -f "$prev_file" ]]; then
        while read -r key val; do
            [[ -z "$key" || -z "$val" ]] && continue
            PREV_XFS["$key"]="$val"
        done < "$prev_file"
    fi
    true > "$prev_file.tmp"
    local had_any=0 had_crit=0
    local summary_lines=""
    # Resolve keys to inspect: use configured list or defaults, then apply excludes
    local keys=()
    if [[ -n "$XFS_PROC_KEYS" ]]; then
        read -r -a keys <<< "$XFS_PROC_KEYS"
    else
        keys=(extent_alloc dir_lookup dir_create xs_xstrat delalloc flush)
    fi
    if [[ -n "$XFS_PROC_KEYS_EXCLUDE" ]]; then
        local filtered=() k ex
        for k in "${keys[@]}"; do
            local skip=0
            for ex in $XFS_PROC_KEYS_EXCLUDE; do [[ "$k" == "$ex" ]] && { skip=1; break; }; done
            (( skip==0 )) && filtered+=("$k")
        done
        keys=("${filtered[@]}")
    fi
    # Snapshot XFS mountpoints once for reuse
    local -a xfs_mounts_arr=()
    mapfile -t xfs_mounts_arr < <(mount | awk '/ xfs /{print $3}')
    for k in "${keys[@]}"; do
        local val
        val=$(awk -v key="$k" '$1==key{print $2; exit}' "$stat_file" 2>/dev/null || true)
        [[ -z "$val" || ! "$val" =~ ^[0-9]+$ ]] && continue
        echo "$k $val" >> "$prev_file.tmp"
        local prev
        local delta
        prev=${PREV_XFS["$k"]:-0}
        delta=$(( val - prev ))
        if (( delta > 0 )); then
            local sev last_delta ratio
            sev="warning"
            # Retrieve previous delta for burst ratio (parse last history line with key)
            last_delta=0
            if [[ -f "$XFS_PROC_HISTORY_FILE" ]]; then
                local hist_line
                hist_line=$(grep -E " key=$k " "$XFS_PROC_HISTORY_FILE" 2>/dev/null || true)
                last_delta=$(echo "$hist_line" | tail -n1 | awk '{for(i=1;i<=NF;i++){ if($i ~ /^delta=/){sub(/delta=/,"",$i); print $i; break } }}' 2>/dev/null || true)
                [[ -n "$last_delta" && "$last_delta" =~ ^[0-9]+$ ]] || last_delta=0
            fi
            # Apply standard delta thresholds first
            if (( delta >= XFS_PROC_CRIT_DELTA )); then sev="critical"; elif (( delta >= XFS_PROC_WARN_DELTA )); then sev="warning"; else sev="skip"; fi
            # Compute burst ratio if prior delta present
            if (( last_delta > 0 )); then
                ratio=$(awk -v d="$delta" -v l="$last_delta" 'BEGIN{ if(l>0) printf "%d", int(d/l); else print 0 }')
                if (( ratio >= XFS_ERR_BURST_CRIT_RATIO )); then
                    sev="critical"; had_crit=1; had_any=1
                    summary_lines+="$k burst +$delta (x${ratio} vs $last_delta); "
                    if (( XFS_PROC_SMART_ANNOTATE_BURST == 1 && suppress == 0 )); then
                        local bdev_burst
                        for m in "${xfs_mounts_arr[@]}"; do
                            local src; src=$(findmnt -n -o SOURCE "$m" 2>/dev/null || true); [[ -z "$src" ]] && continue
                            bdev_burst=$(base_device "$src")
                            [[ -z "${SMART_STATE[$bdev_burst]:-}" ]] && SMART_STATE[$bdev_burst]="OK"
                            SMART_MSGS[$bdev_burst]="${SMART_MSGS[$bdev_burst]:-} XFS burst: $k x${ratio}"
                            local cur_boost=${BURST_BOOST[$bdev_burst]:-0}; cur_boost=$(( cur_boost + BURST_CRIT_BOOST )); (( cur_boost > 100 )) && cur_boost=100; BURST_BOOST[$bdev_burst]=$cur_boost
                        done
                    fi
                elif (( ratio >= XFS_ERR_BURST_WARN_RATIO )); then
                    [[ "$sev" == "skip" ]] && sev="warning"
                    had_any=1
                    summary_lines+="$k elevated +$delta (x${ratio} vs $last_delta); "
                    if (( XFS_PROC_SMART_ANNOTATE_BURST == 1 && suppress == 0 )); then
                        local bdev_burst
                        for m in "${xfs_mounts_arr[@]}"; do
                            local src; src=$(findmnt -n -o SOURCE "$m" 2>/dev/null || true); [[ -z "$src" ]] && continue
                            bdev_burst=$(base_device "$src")
                            [[ -z "${SMART_STATE[$bdev_burst]:-}" ]] && SMART_STATE[$bdev_burst]="OK"
                            SMART_MSGS[$bdev_burst]="${SMART_MSGS[$bdev_burst]:-} XFS burst: $k x${ratio}"
                            local cur_boost=${BURST_BOOST[$bdev_burst]:-0}; cur_boost=$(( cur_boost + BURST_WARN_BOOST )); (( cur_boost > 100 )) && cur_boost=100; BURST_BOOST[$bdev_burst]=$cur_boost
                        done
                    fi
                elif [[ "$sev" != "skip" ]]; then
                    if (( XFS_PROC_REQUIRE_RATIO_FOR_ALERT == 0 )); then
                        had_any=1; [[ "$sev" == "critical" ]] && had_crit=1
                        summary_lines+="$k +$delta; "
                    fi
                fi
            else
                if [[ "$sev" != "skip" ]]; then
                    if (( XFS_PROC_REQUIRE_RATIO_FOR_ALERT == 0 )); then
                        had_any=1; [[ "$sev" == "critical" ]] && had_crit=1
                        summary_lines+="$k +$delta; "
                    fi
                fi
            fi
            # Persist delta to history with delta field for future burst comparisons
            local today; today=$(date '+%Y-%m-%d')
            echo "$today key=$k delta=$delta value=$val" >> "$XFS_PROC_HISTORY_FILE"
        fi
    done
    # Emit alert(s): prefer single global alert unless explicitly configured for per-mount
    if (( had_any == 1 && suppress == 0 )); then
        local msg="XFS metadata activity spike: ${summary_lines%%; }"
        if (( XFS_PROC_PER_MOUNT_ALERTS == 1 )); then
            for m in "${xfs_mounts_arr[@]}"; do
                local src; src=$(findmnt -n -o SOURCE "$m" 2>/dev/null || true); [[ -z "$src" ]] && continue
                local bdev; bdev=$(base_device "$src")
                [[ -z "${SMART_STATE[$bdev]:-}" ]] && SMART_STATE[$bdev]="OK"
                record_alert "$([[ $had_crit -eq 1 ]] && echo critical || echo warning)" "$NOTIFY_TITLE_XFS" "$msg ($bdev, mount: $m)"
            done
        else
            record_alert "$([[ $had_crit -eq 1 ]] && echo critical || echo warning)" "$NOTIFY_TITLE_XFS" "$msg"
        fi
    fi
    # Persist new snapshot for next run delta computation
    mv "$prev_file.tmp" "$prev_file" 2>/dev/null || rm -f "$prev_file.tmp" 2>/dev/null || true
}

# === Main Function ===
# Build and send notification
log_info "Building sections..."
log_info "Summarizing disks and pools usage..."; build_storage_and_disk_lines; log_info "Usage summary completed"
log_info "Checking capacity thresholds..."; evaluate_capacity_alerts; log_info "Capacity threshold check completed"
log_info "Preparing parity summary..."; discover_parity_and_status; log_info "Parity summary completed"
log_info "Collecting btrfs per-device stats..."; collect_btrfs_device_stats; log_info "Btrfs device stats collection completed"
log_info "Collecting XFS /proc stats..."; collect_xfs_proc_stats; log_info "XFS /proc stats collection completed"
log_info "Estimating capacity growth..."; capacity_forecast_and_export; log_info "Capacity forecast completed"
log_info "Compiling health alerts..."; build_health_alerts; log_info "Health alerts compiled"
build_subject
log_info "Building disk health summary..."; build_disk_health_summary; log_info "Disk health summary completed"
log_info "Analyzing write rates and TBW forecasts..."; tbw_forecast_and_heavy_writers; log_info "TBW analysis completed"
log_info "Summarizing subsystem statuses..."; build_subsystem_lines; log_info "Subsystem summary completed"
log_info "Scoring disk risk and lifecycle buckets..."; compute_risk_and_lifecycle; log_info "Risk and lifecycle scoring completed"
log_info "Validating storage metrics..."; validate_storage_metrics; log_info "Storage metrics validation completed"
log_info "Recording share sizes to history..."; compute_share_breakdown; log_info "Share size history updated"
log_info "Scanning syslog for disk I/O errors..."; scan_syslog_disk_errors; log_info "Syslog scan completed"
log_info "Recording today's risk tier counts..."; persist_risk_tier_history; log_info "Risk tier counts recorded"
log_info "Compiling trend analytics..."; build_trend_section; log_info "Trend analytics compiled"
log_info "Section build completed"
# Build subsystem subject suffix per policy (auto|always|never); no body content rendered
if [[ -n "${SUBSYSTEM_LINES:-}" ]]; then
    case "${SHOW_SUBSYSTEMS_BLOCK:-auto}" in
        never)
            : ;;
        always)
            # Show degraded list if any; else show nominal status
            if echo "${SUBSYSTEM_LINES}" | grep -Eq ': (WARNING|CRITICAL)$'; then
                degraded_list=""
                while read -r name; do
                    [[ -z "$name" ]] && continue
                    if [[ -z "$degraded_list" ]]; then degraded_list="$name"; else degraded_list+=", $name"; fi
                done < <(printf "%s\n" "${SUBSYSTEM_LINES}" | awk -F: '/: (WARNING|CRITICAL)$/ {print $1}')
                if [[ -n "$degraded_list" ]]; then
                    SUBJECT="${SUBJECT:-Disks Health} — Subsystems degraded: ${degraded_list}"
                fi
            else
                SUBJECT="${SUBJECT:-Disks Health} — All subsystems nominal"
            fi
            ;;
        auto|*)
            # Only show when degraded
            if echo "${SUBSYSTEM_LINES}" | grep -Eq ': (WARNING|CRITICAL)$'; then
                degraded_list=""
                while read -r name; do
                    [[ -z "$name" ]] && continue
                    if [[ -z "$degraded_list" ]]; then degraded_list="$name"; else degraded_list+=", $name"; fi
                done < <(printf "%s\n" "${SUBSYSTEM_LINES}" | awk -F: '/: (WARNING|CRITICAL)$/ {print $1}')
                if [[ -n "$degraded_list" ]]; then
                    SUBJECT="${SUBJECT:-Disks Health} — Subsystems degraded: ${degraded_list}"
                fi
            fi
            ;;
    esac
fi
# Compose Array section to control spacing precisely
ARRAY_SECTION="[Array Disks]:\n${PARITY_STATUS_LINE:-}\n"
if [[ -n "${PARITY_DETAILS_SECTION:-}" ]]; then
    ARRAY_SECTION+="${PARITY_DETAILS_SECTION}"
fi
ARRAY_SECTION+="${ARRAY_DISK_LINES:-}"
# Compose Pool section only if there is content
POOL_SECTION=""
if printf "%s" "${POOL_LINES:-}" | grep -q '[^[:space:]]'; then
    POOL_SECTION="[Pool Disks]:\n${POOL_LINES}"
fi
# Append a section in notification if non-empty
_append_section() {
    local s="$1"
    # Fast skip if empty or whitespace-only
    if ! printf "%s" "$s" | grep -q '[^[:space:]]'; then return 0; fi
    # Convert literal \n sequences to real newlines before further cleanup
    s="$(printf '%s' "$s" | sed -E 's/\\n/\n/g')"
    # Remove leading blank lines, collapse internal runs of >1 blank lines to a single
    local cleaned
    cleaned=$(printf "%s\n" "$s" | awk 'BEGIN{out=0;blank=0} {
        if ($0 ~ /^[[:space:]]*$/) { blank++ ; next }
        if (blank>0 && out>0) { print "" ; blank=0 }
        print ; out++
    } END{}')
    # Strip any trailing blank lines (may remain if original ended with blanks)
    cleaned=$(printf "%s\n" "$cleaned" | awk '{lines[NR]=$0} END{max=0; for(i=NR;i>=1;i--){if(lines[i] ~ /^[[:space:]]*$/) continue; max=i; break} for(i=1;i<=max;i++){print lines[i]}}')
    # Final skip if cleaning removed all content
    if ! printf "%s" "$cleaned" | grep -q '[^[:space:]]'; then return 0; fi
    NOTIFY_SECTIONS+=("$cleaned")
}
# Build variable sections, skipping hidden ones cleanly
NOTIFY_SECTIONS=()
_append_section "${ARRAY_SECTION:-}"
_append_section "${POOL_SECTION:-}"
_append_section "${DISK_HEALTH_SUMMARY:-}"
_append_section "${STORAGE_VALIDATION_SECTION:-}"
_append_section "${HEALTH_ALERTS_SECTION:-}"
_append_section "${TREND_SECTION:-}"
# Join non-empty sections with exactly one blank line between
TAIL_SECTIONS=""
if (( ${#NOTIFY_SECTIONS[@]} > 0 )); then
    for idx in "${!NOTIFY_SECTIONS[@]}"; do
        if (( idx > 0 )); then TAIL_SECTIONS+=$'\n\n'; fi
        TAIL_SECTIONS+="${NOTIFY_SECTIONS[$idx]}"
    done
fi
# Assemble final notification body with symmetric spacing
NOTIFY_BODY="${STORAGE_TOP_LINES:-}

${TAIL_SECTIONS}"

# Log severity used for the outgoing notification
if (( ${#ALERT_CRIT[@]} > 0 )); then
    _final_sev=critical
elif (( ${#ALERT_WARN[@]} > 0 )); then
    if [[ -z "${HEALTH_ALERTS_SECTION:-}" ]]; then
        _final_sev=normal
    else
        _final_sev=warning
    fi
else
    _final_sev=normal
fi
log_info "Preparing notification severity level = ${_final_sev}, critical count = ${#ALERT_CRIT[@]}, warning count = ${#ALERT_WARN[@]}"
notify_unraid "${SUBJECT:-Disk Health Summary}" "$NOTIFY_BODY" "${_final_sev}"

# === Helper Function ===
# Persist current SMART attributes and states
persist_current_attrs() {
    true > "$PREV_ATTR_FILE"
    for disk in "${!SMART_STATE[@]}"; do
        local line="$disk state=${SMART_STATE[$disk]}"
        for key in realloc pending offunc reported_uncorr cmd_timeout realloc_events udma lcc end2end soft_read_err temp; do
            local v=${CUR_ATTR["$disk|$key"]:-}
            [[ -n "$v" ]] && line+=" $key=$v"
        done
        local poh=${CUR_ATTR["$disk|poh"]:-}
        [[ -n "$poh" ]] && line+=" poh=$poh"
        local nvme_used=${CUR_ATTR["$disk|nvme_percent_used"]:-}
        [[ -n "$nvme_used" ]] && line+=" nvme_percent_used=$nvme_used"
        echo "$line" >> "$PREV_ATTR_FILE"
    done
}
persist_current_attrs

# === Helper Function ===
# Persist newly seen disks for alert suppression
persist_new_seen() {
    true > "$ALERT_NEW_SEEN_FILE"
    for key in "${!NEW_SEEN[@]}"; do
        echo "$key" >> "$ALERT_NEW_SEEN_FILE"
    done
}
persist_new_seen

# === Helper Function ===
# Persist current risk scores for trend analysis
persist_risk_scores() {
    # Load previous risk scores locally for delta computation
    declare -A PREV_RISK
    if [ -f "$RISK_PREV_FILE" ]; then
        while read -r dev score; do
            [[ -z "$dev" || -z "$score" ]] && continue
            PREV_RISK["$dev"]="$score"
        done < "$RISK_PREV_FILE"
    fi
     true > "$RISK_PREV_FILE"
    for dev in "${!SMART_STATE[@]}"; do
        local msg="${SMART_MSGS[$dev]}"
        local score prev delta
        score=$(risk_score_quick "${SMART_STATE[$dev]}" "$msg")
        prev=${PREV_RISK["$dev"]:-}
        if [[ -n "$prev" && "$prev" =~ ^[0-9]+$ && "$score" =~ ^[0-9]+$ ]]; then
            delta=$((score - prev))
            if (( delta != 0 )); then
                log_info "Risk score change for $dev: ${prev} -> ${score} (Δ=${delta})"
            fi
        fi
        echo "$dev $score" >> "$RISK_PREV_FILE"
    done
}
persist_risk_scores
prune_old_run_logs
enforce_state_tree_perms
exit 0
