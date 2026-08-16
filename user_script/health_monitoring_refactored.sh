#!/bin/bash
# shellcheck disable=SC2034,SC2155
noParity=true
set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    printf 'health_monitoring.sh requires Bash 4 or newer (found %s).\n' \
        "${BASH_VERSION:-unknown}" >&2
    exit 2
fi

# Disk Health Monitor for Unraid v2.8
# Purpose: Run SMART tests, parse SMART/NVMe attributes, track endurance & risk, capture filesystem health,
# evaluate capacity growth, detect firmware/regression events, surface I/O error frequency, and emit concise
# notifications.
################################################################################
# ---------------- Configuration ----------------
# Disks health script settings. Tuned for performance and reliability.
################################################################################

# === SMART Test Scheduling ===
SHORT_TEST_INTERVAL_DAYS=7                      # Run automatic short tests no more often than this (0=disable)
SMART_ALLOW_SPINUP=0                            # Allow SMART collection/tests to wake standby SATA HDDs (0=defer)
SHORT_TEST_POLL=1                               # Poll short test until it completes (0=fire-and-forget)
SHORT_TEST_MAX_WAIT=180                         # Max seconds to wait while polling short tests
SHORT_TEST_POLL_INTERVAL=10                     # Interval between polls (seconds)
LONG_TEST_ACCEL_FACTOR=2                        # Accelerate next long test interval (divide) after recent risk spike
LONG_TEST_MIN_INTERVAL_DAYS=45                  # Do not recommend long test sooner than this many days after last long
LONG_TEST_MAX_INTERVAL_DAYS=120                 # Maximum fallback days between long tests when no recent risk spike
LONG_TEST_RISK_LOOKBACK_DAYS=7                  # Consider risk spikes within this many days for acceleration
LONG_TEST_RISK_THRESHOLD=60                     # Risk score >= triggers long test consideration
LONG_TEST_CRITICAL_MIN_DAYS=7                   # Critical SMART & last long age >= days -> force long
LONG_TEST_RISK_MIN_DAYS=0                       # Min days since last long before risk-based scheduling applies
LONG_TEST_DECISION=""                           # Accumulator for long test scheduling decisions
LONG_TEST_NEAR_WINDOW_DAYS=5                    # Show health alert when long test is due within N days
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
FIRST_RUN_FORCE=0                               # Keep disabled scrubs fully disabled; set 1 only for an intentional baseline
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
SYSLOG_CURSOR_STARTUP_LOOKBACK_LINES=100         # First cursor run: inspect only the most recent N lines
SYSLOG_CURSOR_ROTATION_LOOKBACK_LINES=2000       # Recovery scan when the previous rotated file cannot be found

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
SHARE_TOP_N=5                                   # Top N shares by size/growth
HISTORY_SCHEMA_VERSION=3                       # Normalized history row schema written by this version
FORECAST_MIN_SAMPLES=3                         # Minimum distinct daily samples for an actionable forecast
FORECAST_MIN_SPAN_DAYS=2                       # Minimum elapsed days for an actionable forecast
FORECAST_HIGH_SAMPLES=7                        # Samples required for HIGH confidence
FORECAST_HIGH_SPAN_DAYS=7                      # Elapsed days required for HIGH confidence
FORECAST_STALE_AFTER_DAYS=3                    # Latest sample older than this is marked STALE
FORECAST_MAX_GAP_DAYS=14                       # Histories with a larger internal gap are LOW confidence
LOG_PRUNE_ENABLED=1                             # Prune old run logs in LOG_DIR
LOG_MAX_DAYS=0                                  # Age pruning days (0=disable)
LOG_MAX_COUNT=3                                 # Max retained logs per pattern (0=disable)
HISTORY_PRUNE_ENABLED=1                         # Enable auto-prune of history files (0=disable)
HISTORY_MAX_DAYS=180                            # Remove lines older than this many days (0=disable age pruning)
HISTORY_MAX_LINES=20000                         # Keep at most this many recent lines per history file (0=disable line pruning)
LOG_MIRROR_STDOUT=1                             # Mirror log lines to the User Scripts console

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

# === Paths / Integration ===
LOG_DIR="/mnt/user/cloud/logs/disk_health"       # Run logs and persistent state
LOCK_FILE="/tmp/health_monitoring.lock"          # Non-blocking single-instance lock
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"

# === Temperature Trend / Rate Thresholds (Global) ===
TEMP_RATE_WARN_C_PER_DAY=4.0                    # Avg rise °C/day >= warning threshold (global)
TEMP_RATE_CRIT_C_PER_DAY=8.0                    # Avg rise °C/day >= critical threshold (global)
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
WEAR_TREND_WINDOW_DAYS=120                       # Window for percent_used slope (days)
WEAR_TREND_TOP_N=5                               # Top N soonest depletion estimates
WEAR_STABLE_MIN_RATE=0.001                       # Percent/day below which treat as stable (shows ∞)
WEAR_DAYS_LEFT_WARN=120                          # Projected days-left <= warning threshold (0=disable)
WEAR_DAYS_LEFT_CRIT=60                           # Projected days-left <= critical threshold (0=disable)
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
NVME_WARN_TEMP_TIME_DELTA_WARN=300               # NVMe Warning Comp. Temperature Time delta (seconds) >= warn
NVME_CRIT_TEMP_TIME_DELTA_WARN=60                # NVMe Critical Comp. Temperature Time delta (seconds) >= warn (usually critical if >0)

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
W_TEMP=5                                         # High temperature weight
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


# === Runtime State (do not modify) ===
ALERT_WARN=()                                     # Accumulator for warning messages
ALERT_CRIT=()                                     # Accumulator for critical messages
declare -A SMART_STATE                            # Map device -> OK/WARNING/CRITICAL
declare -A SMART_MSGS                             # Map device -> aggregated SMART message string
declare -A MOUNT_TO_DEV                           # Map /mnt/diskX -> /dev/sdX|nvme
declare -A POOL_MEMBER_MAP                        # Map base device (/dev/sdX|nvme0n1) -> pool name
declare -A BURST_BOOST                            # Base device -> accumulated burst boost this run (0-100)
declare -A TBW_STATUS_MAP                         # Map device -> TBW status (OK/WARNING/CRITICAL)
declare -A TBW_DAILY                              # Map device -> daily TBW bytes (over window)
declare -A TBW_DAYS_LEFT                          # Map device -> forecasted days left to endurance
declare -A NVME_WEAR_DAYS_LEFT NVME_WEAR_RATE     # NVMe depletion projection
declare -A TBW_FORECAST_CONFIDENCE                # Per-device TBW forecast confidence
declare -A NVME_WEAR_CONFIDENCE                   # Per-device NVMe wear forecast confidence
declare -A TEMP_RATE_CONFIDENCE                   # Per-device temperature-rate confidence
declare -A IO_ERROR_RAW_MAP                       # Map device -> raw I/O error line count (duplicates included)
declare -A IO_ERROR_UNIQUE_MAP                    # Map device -> unique I/O error event count (dedup within window)
declare -A LAST_TEST                              # Map device -> last SMART test timestamp
declare -A LAST_TEST_EPOCH LAST_TEST_KIND         # Actual test-start epoch/type (legacy date state remains supported)
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
declare -A LONG_TEST_RUNNING_LONG                 # Map device -> 1 if a long/extended self-test is currently in progress
declare -A RISK_SPIKE_TS                          # Map device -> epoch timestamp of last captured risk spike
declare -A ALERT_SEEN                             # Exact alert de-duplication within a run
declare -a FINDING_IDS                            # Ordered canonical finding identifiers
declare -A FINDING_SEEN                           # Canonical finding de-duplication within a run
declare -A FINDING_SEVERITY FINDING_CATEGORY      # Finding classification
declare -A FINDING_SIGNAL FINDING_DEVICE          # Risk signal and normalized base device
declare -A FINDING_TITLE FINDING_EVIDENCE         # User-facing finding content
declare -A FINDING_ACTION FINDING_ALERT_TEXT       # Recommended action and rendered alert text
declare -A SATA_POWER_STATE SMART_DEFERRED         # Cached SATA power state and deferred SMART checks
declare -A PREVIOUS_RISK                           # Previous persisted risk, retained when a disk stays asleep
declare -A DEVICE_ID_BY_PATH DEVICE_PATH_BY_ID     # Runtime path <-> stable persistent identity
declare -A DEVICE_ID_SOURCE                        # Identity source: WWN, by-id, serial, or path fallback
declare -a DISCOVERED_DISKS                        # Ordered SMART-capable base-device candidates
declare -A RISK_MAP AGE_CLASS                     # Canonical risk results and lifecycle annotations
declare -a NOTIFY_SECTIONS                        # Final notification sections
declare -a TBW_EVAL_MESSAGES                      # Output from direct TBW evaluation
TBW_EVAL_STATE="OK"

RUN_STAMP=""
RUN_EPOCH=0
MASTER_LOG=""
RUN_DIR=""
SMART_CACHE_DIR=""
CLEANUP_DONE=0
PARITY_STATE_LOADED=0
PARITY_ACTIVE=0
DEVICE_INVENTORY_READY=0
SYSLOG_CURSOR_READY=0
SYSLOG_CURSOR_PENDING_PATH=""
SYSLOG_CURSOR_PENDING_DEVICE=""
SYSLOG_CURSOR_PENDING_INODE=""
SYSLOG_CURSOR_PENDING_LINES=0
SYSLOG_CURSOR_PENDING_SIZE=0
SYSLOG_CURSOR_PENDING_ANCHOR="-"
SYSLOG_CHUNK_FILE=""
RUN_MODE="monitor"
CONFIG_ERROR_COUNT=0
CONFIG_WARNING_COUNT=0
DEPENDENCY_ERROR_COUNT=0
DEPENDENCY_WARNING_COUNT=0

# === Logs Paths ===
STATE_DIR="${LOG_DIR:-}/state"

# === Categorized Timestamp Logging ===
log() {
    local category="$1"
    local level="$2"
    shift 2

    local message="$*"
    local line

    message="$(printf '%s' "$message" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} - //')"
    printf -v line '%s [%s][%s] %s' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$category" \
        "$level" \
        "$message"

    if (( LOG_MIRROR_STDOUT == 1 )); then
        # Use stderr so logging never contaminates data returned by command substitution.
        printf '%s\n' "$line" >&2
    fi

    if [[ -n "$MASTER_LOG" ]]; then
        printf '%s\n' "$line" >> "$MASTER_LOG" 2>/dev/null || true
    fi
}

log_info()  { log "HEALTH" "INFO" "$*"; }
log_warn()  { log "HEALTH" "WARN" "$*"; }
log_crit()  { log "HEALTH" "CRIT" "$*"; }
log_smart() { log "SMART"  "INFO" "$*"; }
log_btrfs() { log "BTRFS"  "INFO" "$*"; }
log_xfs()   { log "XFS"    "INFO" "$*"; }

# === State Files ===
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
BTRFS_DEV_PREV_FILE="$STATE_DIR/btrfs_device_stats.prev"            # Previous Btrfs per-device counters and capture metadata
SYSLOG_CURSOR_STATE_FILE="$STATE_DIR/syslog_cursor.state"            # Persistent inode/line cursor for incremental syslog reads
STORAGE_DISCREPANCY_STATE_FILE="$STATE_DIR/storage_discrepancy_streak.log"  # Storage discrepancy streak counter
RISK_SPIKE_FILE="$STATE_DIR/risk_spikes.log"                        # Persisted risk spike timestamps (accelerated scheduling)
DEVICE_ID_MAP_FILE="$STATE_DIR/device_identity_map.log"             # Stable ID to current /dev path inventory
DEVICE_ID_SCHEMA_FILE="$STATE_DIR/device_identity_schema.version"   # One-time /dev history migration marker
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
STATE_FILES_ALERT_RUNTIME=(
    "$SMART_LONG_STATE_FILE" "$SMART_LONG_LAST_POH_FILE" "$SMART_LAST" "$NVME_STATE_FILE" "$PREV_ATTR_FILE" "$ALERT_NEW_SEEN_FILE" "$RISK_PREV_FILE" "$CMD_TIMEOUT_LAST_FILE" "$XFS_PROC_PREV_FILE" "$BTRFS_DEV_PREV_FILE" "$SYSLOG_CURSOR_STATE_FILE" "$STORAGE_DISCREPANCY_STATE_FILE" "$RISK_SPIKE_FILE" "$REPLACEMENT_EVENTS_FILE" "$SATA_LINK_HISTORY_FILE"
)
STATE_FILES_TREND_HISTORY=(
    "$CAPACITY_HISTORY_FILE" "$DISK_CAP_HISTORY_FILE" "$SHARE_USAGE_HISTORY_FILE" "$HEAVY_WRITER_HISTORY_FILE" "$RISK_TIER_HISTORY_FILE" "$IO_ERROR_HISTORY_FILE" "$BTRFS_DEV_HIST_FILE" "$XFS_PROC_HISTORY_FILE" "$POH_HISTORY_FILE" "$TBW_HISTORY_FILE" "$TBW_DAYSLEFT_HISTORY_FILE" "$SMART_ATTR_HISTORY_FILE" "$RISK_SCORES_HISTORY_FILE" "$TEMP_HISTORY_FILE" "$SELFTEST_HISTORY_FILE"
)
# === Notification Settings ===
NOTIFY_TITLE_SMART="SMART Test Alert"                       # SMART test notifications
NOTIFY_TITLE_BTRFS="Btrfs Scrub Alert"                      # Btrfs scrub notifications
NOTIFY_TITLE_XFS="XFS Alert"                                # XFS filesystem notifications
NOTIFY_TITLE_DISKIO="Disk I/O Alert"                        # Disk I/O notifications
ENABLE_MODEL_IN_ALERTS=0                                    # If 1, append disk model to per-disk health alert lines

################################################################################

# ---------------------------------------------------------------------------
# Runtime, locking, cleanup, and atomic state helpers
# ---------------------------------------------------------------------------

ensure_dir() {
    local path="$1"

    [[ -d "$path" ]] || mkdir -p -- "$path"
}

safe_state_name() {
    local value="${1:-unknown}"

    value="${value#/dev/}"
    value=$(printf '%s' "$value" | sed -E 's#[^A-Za-z0-9._-]+#_#g; s#^_+##; s#_+$##')
    [[ -n "$value" ]] || value="unknown"
    printf '%s' "$value"
}

join_by() {
    local delimiter="$1"
    shift
    local output=""
    local value

    for value in "$@"; do
        if [[ -z "$output" ]]; then
            output="$value"
        else
            output+="$delimiter$value"
        fi
    done

    printf '%s' "$output"
}


format_bytes_short() {
    local bytes="${1:-0}"

    if [[ "$bytes" =~ ^[0-9]+$ ]]; then
        awk -v value="$bytes" 'BEGIN {
            if (value >= 1000000000) {
                printf "%.1fG", value / 1000000000
            } else if (value >= 1000000) {
                printf "%dM", int(value / 1000000)
            } else {
                printf "%dK", int(value / 1000)
            }
        }'
    else
        printf '0K'
    fi
}

state_temp_file() {
    local target="$1"

    mktemp "${target}.tmp.XXXXXX"
}

atomic_commit() {
    local temp_file="$1"
    local target="$2"

    if ! mv -f -- "$temp_file" "$target"; then
        rm -f -- "$temp_file" 2>/dev/null || true
        log "STATE" "WARN" "Unable to replace state file atomically: $target"
        return 1
    fi

    return 0
}

atomic_write_text() {
    local target="$1"
    local value="$2"
    local temp_file

    temp_file="$(state_temp_file "$target")" || {
        log "STATE" "WARN" "Unable to create temporary state file for $target"
        return 1
    }

    if ! printf '%s' "$value" > "$temp_file"; then
        rm -f -- "$temp_file" 2>/dev/null || true
        log "STATE" "WARN" "Unable to write temporary state file for $target"
        return 1
    fi

    atomic_commit "$temp_file" "$target"
}

# Return a record timestamp. Schema-v3 rows carry captured_epoch; legacy rows
# fall back to midnight for their leading YYYY-MM-DD date.
history_record_epoch() {
    local date_field="$1"
    local record="${2:-}"
    local token epoch=""

    for token in $record; do
        if [[ "$token" == captured_epoch=* ]]; then
            epoch="${token#*=}"
            break
        fi
    done
    if [[ "$epoch" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$epoch"
    else
        date -d "$date_field 00:00:00" +%s 2>/dev/null || return 1
    fi
}

history_field_value() {
    local record="$1"
    local wanted="$2"
    local token

    for token in $record; do
        if [[ "$token" == "$wanted="* ]]; then
            printf '%s\n' "${token#*=}"
            return 0
        fi
    done
    return 1
}

# Replace every row for one date in one atomic commit. Callers pass complete
# normalized rows as separate arguments. Malformed legacy rows are discarded.
atomic_replace_daily_history() {
    local target="$1"
    local replace_date="$2"
    shift 2
    local temp_file record

    temp_file="$(state_temp_file "$target")" || return 1
    if [[ -f "$target" ]]; then
        if ! awk -v d="$replace_date" '
            /^#/ { print; next }
            $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
                if ($1 != d) print
            }
        ' "$target" > "$temp_file" 2>/dev/null
        then
            rm -f -- "$temp_file" 2>/dev/null || true
            log "HISTORY" "WARN" "Unable to stage daily history update: $target"
            return 1
        fi
    fi
    for record in "$@"; do
        [[ "$record" == "$replace_date "* ]] || continue
        printf '%s\n' "$record" >> "$temp_file" || {
            rm -f -- "$temp_file" 2>/dev/null || true
            return 1
        }
    done
    atomic_commit "$temp_file" "$target"
}

# Atomically replace one date/entity row while retaining other entities from
# that date. This is used by collectors that discover samples one device at a
# time, such as SMART temperature parsing.
atomic_upsert_daily_history() {
    local target="$1"
    local replace_date="$2"
    local entity="$3"
    local record="$4"
    local temp_file

    [[ "$record" == "$replace_date $entity "* ]] || return 1
    temp_file="$(state_temp_file "$target")" || return 1
    if [[ -f "$target" ]]; then
        if ! awk -v d="$replace_date" -v e="$entity" '
            /^#/ { print; next }
            $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
                if (!($1 == d && $2 == e)) print
            }
        ' "$target" > "$temp_file" 2>/dev/null
        then
            rm -f -- "$temp_file" 2>/dev/null || true
            log "HISTORY" "WARN" "Unable to stage entity history update: $target"
            return 1
        fi
    fi
    printf '%s\n' "$record" >> "$temp_file" || {
        rm -f -- "$temp_file" 2>/dev/null || true
        return 1
    }
    atomic_commit "$temp_file" "$target"
}

# Classify forecast evidence. RESET is supplied by callers when a monotonic
# endurance counter regresses and STALE when the newest sample is too old.
forecast_confidence() {
    local samples="${1:-0}"
    local span_days="${2:-0}"
    local latest_age_days="${3:-999999}"
    local maximum_gap_days="${4:-999999}"

    if (( samples < FORECAST_MIN_SAMPLES )) ||
       awk -v span="$span_days" -v minimum="$FORECAST_MIN_SPAN_DAYS" \
           'BEGIN { exit !(span < minimum) }'
    then
        printf 'INSUFFICIENT\n'
    elif awk -v age="$latest_age_days" -v stale="$FORECAST_STALE_AFTER_DAYS" \
             'BEGIN { exit !(age > stale) }'
    then
        printf 'STALE\n'
    elif awk -v gap="$maximum_gap_days" -v maximum="$FORECAST_MAX_GAP_DAYS" \
             'BEGIN { exit !(gap > maximum) }'
    then
        printf 'LOW\n'
    elif (( samples >= FORECAST_HIGH_SAMPLES )) &&
         awk -v span="$span_days" -v high="$FORECAST_HIGH_SPAN_DAYS" \
             'BEGIN { exit !(span >= high) }'
    then
        printf 'HIGH\n'
    else
        printf 'MEDIUM\n'
    fi
}

forecast_confidence_is_actionable() {
    [[ "$1" == "MEDIUM" || "$1" == "HIGH" ]]
}

acquire_lock() {
    if ! command -v flock >/dev/null 2>&1; then
        printf '%s [LOCK][ERROR] flock is unavailable\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" >&2
        return 1
    fi

    exec 9>"$LOCK_FILE"

    if ! flock -n 9; then
        printf '%s [LOCK][INFO] Another health_monitoring.sh run is active; exiting (lock: %s)\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$LOCK_FILE" >&2
        return 1
    fi

    return 0
}

initialize_runtime() {
    local state_file

    umask 077
    ensure_dir "$LOG_DIR" || return 1
    ensure_dir "$STATE_DIR" || return 1
    ensure_dir "$SMART_SELFTEST_DIR" || return 1
    ensure_dir "$UNSAFE_SDWN_STATE_DIR" || return 1
    ensure_dir "$BTRFS_SCRUB_STATE_DIR" || return 1
    ensure_dir "$CMD_TIMEOUT_STATE_DIR" || return 1

    RUN_EPOCH="$(date +%s)"
    RUN_STAMP="$(date '+%Y-%m-%d_%H%M%S')"
    MASTER_LOG="$LOG_DIR/disk_health_$RUN_STAMP.log"
    : > "$MASTER_LOG" || return 1

    RUN_DIR="$(mktemp -d /tmp/health_monitoring.XXXXXX)" || {
        log "INIT" "ERROR" "Unable to create run workspace"
        return 1
    }
    SMART_CACHE_DIR="$RUN_DIR/smartctl"
    ensure_dir "$SMART_CACHE_DIR" || return 1

    # Remove cache files produced by older versions; this version never reuses
    # SMART output across runs.
    find /tmp -maxdepth 1 -type f -name 'health_smart_cache_*.txt' \
        -delete 2>/dev/null || true

    for state_file in \
        "${STATE_FILES_ALERT_RUNTIME[@]}" \
        "${STATE_FILES_TREND_HISTORY[@]}"
    do
        [[ -e "$state_file" ]] || : > "$state_file" || {
            log "STATE" "WARN" "Unable to initialize state file: $state_file"
        }
    done

    if [[ ! -s "$STORAGE_DISCREPANCY_STATE_FILE" ]]; then
        atomic_write_text "$STORAGE_DISCREPANCY_STATE_FILE" $'0 0\n' || true
    fi

    log "INIT" "INFO" "Runtime initialized (state: $STATE_DIR)"
}

cleanup() {
    local exit_code="$1"

    if (( CLEANUP_DONE == 1 )); then
        return 0
    fi
    CLEANUP_DONE=1

    if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
        rm -rf -- "$RUN_DIR" 2>/dev/null || true
    fi

    if (( exit_code == 0 )); then
        log "RUN" "INFO" "Health monitoring completed"
    else
        log "RUN" "ERROR" "Health monitoring exited with status $exit_code"
    fi
}

handle_signal() {
    local signal_name="$1"
    local exit_code=143

    [[ "$signal_name" == "INT" ]] && exit_code=130
    log "RUN" "WARN" "Received $signal_name; stopping"
    exit "$exit_code"
}


# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------

# Trim old run logs under LOG_DIR to keep history bounded
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
    local cutoff="" cutoff_epoch=0 today
    today=$(date '+%Y-%m-%d')
    if (( max_days > 0 )); then
        cutoff=$(date -d "-${max_days} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
        cutoff_epoch=$(date -d "$cutoff 00:00:00" +%s 2>/dev/null || echo 0)
    fi
    local files=(
        "$CAPACITY_HISTORY_FILE" "$DISK_CAP_HISTORY_FILE" "$SHARE_USAGE_HISTORY_FILE" "$HEAVY_WRITER_HISTORY_FILE" "$RISK_TIER_HISTORY_FILE" "$IO_ERROR_HISTORY_FILE" "$BTRFS_DEV_HIST_FILE" "$XFS_PROC_HISTORY_FILE" "$POH_HISTORY_FILE" "$TBW_DAYSLEFT_HISTORY_FILE" "$SMART_ATTR_HISTORY_FILE" "$RISK_SCORES_HISTORY_FILE" "$TEMP_HISTORY_FILE" "$TBW_HISTORY_FILE" "$SELFTEST_HISTORY_FILE" "$SATA_LINK_HISTORY_FILE" "$REPLACEMENT_EVENTS_FILE"
    )
    local f
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        local filtered final_file line_count
        filtered="$(state_temp_file "$f")" || continue
        final_file="$(state_temp_file "$f")" || {
            rm -f -- "$filtered" 2>/dev/null || true
            continue
        }

        # Date-led analytics rows and epoch-led I/O-event rows are both valid.
        # Anything else is malformed history and is removed during staging.
        if ! awk -v c="$cutoff" -v ce="$cutoff_epoch" -v prune_age="$max_days" '
            /^#/ { print; next }
            $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
                if (!prune_age || $1 >= c) print
                next
            }
            $1 ~ /^[0-9]+$/ {
                if (!prune_age || $1 >= ce) print
                next
            }
        ' "$f" > "$filtered" 2>/dev/null
        then
            rm -f -- "$filtered" "$final_file" 2>/dev/null || true
            log "HISTORY" "WARN" "Unable to stage history pruning: $f"
            continue
        fi

        line_count=$(wc -l < "$filtered" 2>/dev/null || echo 0)
        if (( max_lines > 0 && line_count > max_lines )); then
            if ! tail -n "$max_lines" "$filtered" > "$final_file" 2>/dev/null; then
                rm -f -- "$filtered" "$final_file" 2>/dev/null || true
                log "HISTORY" "WARN" "Unable to apply history line limit: $f"
                continue
            fi
        else
            if ! cp -p -- "$filtered" "$final_file" 2>/dev/null; then
                rm -f -- "$filtered" "$final_file" 2>/dev/null || true
                log "HISTORY" "WARN" "Unable to stage retained history: $f"
                continue
            fi
        fi
        rm -f -- "$filtered" 2>/dev/null || true
        atomic_commit "$final_file" "$f" || true
    done
}

# === Helper Functions ===
# Caching wrappers for external commands to minimize repeated calls
declare LSBLK_ALL_CACHE=""
declare -A BTRFS_DF_CACHE_DATA BTRFS_DF_CACHE_META
cache_lsblk_all() {
    if [[ -z "$LSBLK_ALL_CACHE" ]]; then
        LSBLK_ALL_CACHE="$(lsblk -b -dn -o NAME,SIZE,ROTA,TYPE 2>/dev/null || true)"
    fi
}
lsblk_size_cached() {
    local dev="$1" source="$LSBLK_ALL_CACHE"
    [[ -n "$source" ]] || source="$(lsblk -b -dn -o NAME,SIZE,ROTA,TYPE 2>/dev/null || true)"
    awk -v d="${dev##*/}" '$1==d{print $2; exit}' <<<"$source"
}
lsblk_rota_cached() {
    local dev="$1" source="$LSBLK_ALL_CACHE"
    [[ -n "$source" ]] || source="$(lsblk -b -dn -o NAME,SIZE,ROTA,TYPE 2>/dev/null || true)"
    awk -v d="${dev##*/}" '$1==d{print $3; exit}' <<<"$source"
}

# Read a SATA device's power state without intentionally waking it. The result
# is cached for the run so every SMART-related phase makes the same decision.
refresh_sata_power_state() {
    local disk="$1"
    local state="" probe="" rota=""

    [[ "$disk" == /dev/sd* ]] || return 0
    [[ -n "${SATA_POWER_STATE[$disk]:-}" ]] && return 0

    if command -v hdparm >/dev/null 2>&1; then
        state=$(hdparm -C "$disk" 2>/dev/null |
            awk -F: '/state is/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print tolower($2); exit}')
    fi

    case "$state" in
        standby|sleeping|sleep) SATA_POWER_STATE[$disk]="standby"; return 0 ;;
        active/idle|active|idle) SATA_POWER_STATE[$disk]="active"; return 0 ;;
    esac

    # smartctl -n exits before normal SMART access when a rotational device is
    # sleeping. This is a fallback for controllers not supported by hdparm.
    probe=$(smartctl -n standby -i "$disk" 2>&1 || true)
    if printf '%s' "$probe" | grep -qiE 'device is in (standby|sleep)|standby mode|sleep mode'; then
        SATA_POWER_STATE[$disk]="standby"
        return 0
    fi
    if printf '%s' "$probe" | grep -qiE 'device model|model family|smart support|serial number'; then
        SATA_POWER_STATE[$disk]="active"
        return 0
    fi

    rota=$(lsblk_rota_cached "$disk" 2>/dev/null || true)
    if [[ "$rota" == "0" ]]; then
        SATA_POWER_STATE[$disk]="solid-state"
    else
        SATA_POWER_STATE[$disk]="unknown"
    fi
}

# Prepare a device for full SMART access. Return 1 when a rotational SATA disk
# is asleep (or its power state cannot be proven safe) and wake-up is disabled.
prepare_smart_access() {
    local disk="$1"
    local state

    [[ "$disk" == /dev/sd* ]] || return 0
    refresh_sata_power_state "$disk"
    state="${SATA_POWER_STATE[$disk]:-unknown}"

    case "$state" in
        active|solid-state) return 0 ;;
        standby|unknown)
            if (( SMART_ALLOW_SPINUP == 0 )); then
                return 1
            fi
            log "SMART" "INFO" "Wake-up permitted for $disk (power state: $state)"
            if command -v hdparm >/dev/null 2>&1; then
                hdparm -I "$disk" >/dev/null 2>&1 || true
            fi
            SATA_POWER_STATE[$disk]="active"
            return 0
            ;;
    esac

    return 0
}

retain_previous_smart_snapshot() {
    local disk="$1"
    local power_state="${2:-standby}"
    local previous_state="${PREV_ATTR["$disk|state"]:-OK}"
    local composite attr value message

    case "$previous_state" in
        OK|WARNING|CRITICAL) ;;
        *) previous_state="OK" ;;
    esac

    SMART_DEFERRED[$disk]="$power_state"
    SMART_STATE[$disk]="$previous_state"
    SMART_MSGS[$disk]="SMART collection and self-test deferred (${power_state}; automatic spin-up disabled)"

    # Preserve the previous attribute baseline so persistence and trend delta
    # calculations do not erase or reset a sleeping disk's last known values.
    for composite in "${!PREV_ATTR[@]}"; do
        [[ "$composite" == "$disk|"* ]] || continue
        attr="${composite#"$disk|"}"
        [[ "$attr" == "state" ]] && continue
        value="${PREV_ATTR[$composite]}"
        CUR_ATTR["$disk|$attr"]="$value"
    done

    message="Disk $disk remains ${power_state}; previous SMART state $previous_state retained"
    if [[ "$previous_state" == "CRITICAL" || "$previous_state" == "WARNING" ]]; then
        record_alert "$previous_state" "$NOTIFY_TITLE_SMART" "$message"
    fi

    log "SMART" "INFO" "Deferred live SMART collection and self-test for $disk (power state: $power_state)"
}

short_test_is_due() {
    local disk="$1"
    local interval_days="${SHORT_TEST_INTERVAL_DAYS:-0}"
    local last_epoch="${LAST_TEST_EPOCH[$disk]:-}"
    local last_date="${LAST_TEST[$disk]:-}"
    local now_epoch

    [[ "$interval_days" =~ ^[0-9]+$ ]] || return 1
    (( 10#$interval_days > 0 )) || return 1

    if [[ ! "$last_epoch" =~ ^[0-9]+$ && -n "$last_date" ]]; then
        last_epoch=$(date -d "$last_date" +%s 2>/dev/null || true)
    fi
    [[ "$last_epoch" =~ ^[0-9]+$ ]] || return 0

    now_epoch=$(date +%s)
    (( now_epoch - last_epoch >= 10#$interval_days * 86400 ))
}

short_test_next_date() {
    local disk="$1"
    local last_epoch="${LAST_TEST_EPOCH[$disk]:-}"
    local last_date="${LAST_TEST[$disk]:-}"
    local interval_days="${SHORT_TEST_INTERVAL_DAYS:-0}"

    if [[ ! "$last_epoch" =~ ^[0-9]+$ && -n "$last_date" ]]; then
        last_epoch=$(date -d "$last_date" +%s 2>/dev/null || true)
    fi
    if [[ "$last_epoch" =~ ^[0-9]+$ && "$interval_days" =~ ^[0-9]+$ ]]; then
        date -d "@$(( last_epoch + 10#$interval_days * 86400 ))" '+%Y-%m-%d %H:%M' 2>/dev/null || true
    fi
}

mark_test_started() {
    local disk="$1"
    local test_kind="$2"
    local now_epoch

    now_epoch=$(date +%s)
    LAST_TEST[$disk]=$(date '+%Y-%m-%d')
    LAST_TEST_EPOCH[$disk]="$now_epoch"
    LAST_TEST_KIND[$disk]="$test_kind"
}

smartctl_cached() {
    local key cache_file temp_file device_arg device_key

    key="$(printf '%s\0' "$@" | cksum | awk '{print $1 "_" $2}')"
    device_arg="${!#}"
    device_key="$(safe_state_name "$device_arg")"
    cache_file="$SMART_CACHE_DIR/${device_key}_${key}.txt"

    if [[ ! -f "$cache_file" ]]; then
        temp_file="$(mktemp "$SMART_CACHE_DIR/.smartctl.XXXXXX")" || return 1
        smartctl "$@" > "$temp_file" 2>&1 || true
        mv -f -- "$temp_file" "$cache_file" || {
            rm -f -- "$temp_file" 2>/dev/null || true
            return 1
        }
    fi

    cat -- "$cache_file"
}

invalidate_smart_cache() {
    local disk="${1:-}"
    local disk_key=""

    if [[ -n "$SMART_CACHE_DIR" && -d "$SMART_CACHE_DIR" ]]; then
        if [[ -n "$disk" ]]; then
            disk_key="$(safe_state_name "$disk")"
            find "$SMART_CACHE_DIR" -maxdepth 1 -type f \
                -name "${disk_key}_*.txt" -delete 2>/dev/null || true
        else
            find "$SMART_CACHE_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true
        fi
    fi
}
get_selftest_live() {
    local disk="$1"
    if [[ ! "$disk" =~ ^/dev/[A-Za-z0-9]+([p0-9]+)?$ ]]; then printf ""; return; fi
    if [[ $disk == /dev/nvme* ]]; then
        smartctl -l selftest -d nvme "$disk" 2>/dev/null || true
    else
        smartctl -l selftest "$disk" 2>/dev/null || true
    fi
}
get_capabilities_live() {
    local disk="$1"
    if [[ ! "$disk" =~ ^/dev/[A-Za-z0-9]+([p0-9]+)?$ ]]; then printf ""; return; fi
    if [[ $disk == /dev/nvme* ]]; then
        smartctl -c -d nvme "$disk" 2>/dev/null || true
    else
        smartctl -c "$disk" 2>/dev/null || true
    fi
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
        summary_line="$(join_by ' | ' "${parts[@]}")"
    else
        summary_line="All subsystems nominal"
    fi
    # Normalize body for cleaner presentation (collapse multiple blank lines)
    local body_norm
    body_norm=$(printf "%s\n" "$body" | awk '{sub(/[ \t]+$/, "")} NF{print; blank=0; next} !blank{print ""; blank=1}')
    local rc=0
    if [ -x "$NOTIFY_BIN" ]; then
        log_info "Sending notification with $icon title '$title'"
        "$NOTIFY_BIN" -s "${title:-Disks Health Monitoring}" -d "$summary_line" -m "$body_norm" -i "$icon" || rc=$?
        (( rc != 0 )) && log_warn "Sending notification FAILED - returned non-zero exit $rc; continuing"
    else
        # Syslog fallback when notify binary missing
        log_warn "Sending notification FAILED - notify binary missing, using syslog fallback"
        logger -t "Disks Health Monitoring" "${title:-Disks Health Monitoring}: $summary_line"
        logger -t "Disks Health Monitoring" "$body_norm"
    fi
    return 0
}

# === Helper Functions ===
# Classify one finding once. These globals are consumed immediately by
# record_alert(), avoiding a side-effecting helper inside command substitution.
classify_finding_metadata() {
    local title="$1"
    local body="$2"
    local lower_title="${title,,}"
    local lower_body="${body,,}"

    FINDING_CLASS_CATEGORY="general"
    FINDING_CLASS_SIGNAL="advisory"
    FINDING_CLASS_ACTION="Review the evidence and the related subsystem logs."

    case "$lower_title|$lower_body" in
        *"pending sectors"*|*"offline uncorrectable"*|*"reported uncorrectable"*|*"media integrity"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.media"
            FINDING_CLASS_ACTION="Back up immediately, run a long SMART test, and plan replacement if the condition remains."
            ;;
        *"reallocated"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.reallocation"
            FINDING_CLASS_ACTION="Monitor the counter trend and replace the drive if it continues to increase."
            ;;
        *"self-test"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.selftest"
            FINDING_CLASS_ACTION="Review the self-test log; back up and replace the drive after a failed long test."
            ;;
        *"end-to-end errors"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.end_to_end"
            FINDING_CLASS_ACTION="Back up the device and inspect both the drive and controller data path."
            ;;
        *"soft read error"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.soft_read"
            FINDING_CLASS_ACTION="Run a long SMART test and monitor whether the counter continues to rise."
            ;;
        *"read-only mode"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.read_only"
            FINDING_CLASS_ACTION="Clone or back up the data immediately and replace the NVMe device."
            ;;
        *"reliability degraded"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.reliability"
            FINDING_CLASS_ACTION="Back up the device and schedule replacement."
            ;;
        *"nvme error log"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.nvme_error_log"
            FINDING_CLASS_ACTION="Review NVMe logs and firmware, then monitor for continued growth."
            ;;
        *"command timeout"*)
            FINDING_CLASS_CATEGORY="io"
            FINDING_CLASS_SIGNAL="io.command_timeout"
            FINDING_CLASS_ACTION="Inspect power, cabling, backplane, and controller logs."
            ;;
        *"udma crc"*|*"sata link instability"*)
            FINDING_CLASS_CATEGORY="io"
            FINDING_CLASS_SIGNAL="io.sata_link"
            FINDING_CLASS_ACTION="Reseat or replace the SATA cable and verify the controller/backplane link."
            ;;
        *"pcie correctable"*|*"pcie uncorrectable"*)
            FINDING_CLASS_CATEGORY="io"
            FINDING_CLASS_SIGNAL="io.pcie_link"
            FINDING_CLASS_ACTION="Inspect the PCIe slot or backplane, reseat the device, and verify cooling."
            ;;
        *"i/o errors unique"*)
            FINDING_CLASS_CATEGORY="io"
            FINDING_CLASS_SIGNAL="io.kernel"
            FINDING_CLASS_ACTION="Inspect cabling, power, controller logs, and the affected device before errors escalate."
            ;;
        *"unsafe shutdown"*|*"volatile memory backup"*)
            FINDING_CLASS_CATEGORY="io"
            FINDING_CLASS_SIGNAL="io.power"
            FINDING_CLASS_ACTION="Check UPS, PSU, firmware, and power stability before the counter grows further."
            ;;
        temp*|*"temperature"*|*" temp"*|*"thermal"*)
            FINDING_CLASS_CATEGORY="temperature"
            FINDING_CLASS_SIGNAL="thermal.exposure"
            FINDING_CLASS_ACTION="Improve airflow or cooling and reduce sustained I/O until temperature stabilizes."
            ;;
        *"tbw"*|*"heavy writer"*)
            FINDING_CLASS_CATEGORY="endurance"
            FINDING_CLASS_SIGNAL="endurance.tbw"
            FINDING_CLASS_ACTION="Reduce write amplification, confirm backups, and plan the device refresh window."
            ;;
        *"nvme wear"*|*"available spare"*|*"ssd life remaining"*)
            FINDING_CLASS_CATEGORY="endurance"
            FINDING_CLASS_SIGNAL="endurance.wear"
            FINDING_CLASS_ACTION="Reduce write load and plan replacement before the remaining endurance is exhausted."
            ;;
        *"poh age"*|*"load cycle count"*)
            FINDING_CLASS_CATEGORY="lifecycle"
            FINDING_CLASS_SIGNAL="lifecycle.age"
            FINDING_CLASS_ACTION="Keep backups current and plan a proactive refresh based on trend and workload."
            ;;
        *"firmware reset"*|*"drive replacement"*)
            FINDING_CLASS_CATEGORY="lifecycle"
            FINDING_CLASS_SIGNAL="lifecycle.regression"
            FINDING_CLASS_ACTION="Verify device identity and firmware, then establish fresh SMART and filesystem baselines."
            ;;
        *"btrfs"*)
            FINDING_CLASS_CATEGORY="filesystem"
            FINDING_CLASS_SIGNAL="filesystem.btrfs"
            FINDING_CLASS_ACTION="Run or review a scrub, inspect device health and cabling, and back up before repair."
            ;;
        *"xfs"*)
            FINDING_CLASS_CATEGORY="filesystem"
            FINDING_CLASS_SIGNAL="filesystem.xfs"
            FINDING_CLASS_ACTION="Back up first, unmount during maintenance, and run an offline read-only XFS check."
            ;;
        *"capacity"*|*"storage warning"*|*"storage critical"*|*"storage validation"*)
            FINDING_CLASS_CATEGORY="capacity"
            FINDING_CLASS_SIGNAL="capacity.space"
            FINDING_CLASS_ACTION="Free space or expand capacity and verify share, cache, and mover settings."
            ;;
        *"parity"*)
            FINDING_CLASS_CATEGORY="parity"
            FINDING_CLASS_SIGNAL="parity.integrity"
            FINDING_CLASS_ACTION="Review the parity operation, SMART health, and cabling before a corrective check."
            ;;
        *"smart scheduling"*)
            FINDING_CLASS_CATEGORY="maintenance"
            FINDING_CLASS_SIGNAL="maintenance.smart_test"
            FINDING_CLASS_ACTION="Review the scheduled test result on the next run."
            ;;
        *"smart"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.aggregate"
            FINDING_CLASS_ACTION="Review the device SMART evidence and keep a current backup."
            ;;
    esac
}

finding_code_for_alert() {
    local title="$1"
    local body="$2"
    local code="${title,,}"
    local discriminator=""

    code="${code//[!a-z0-9]/_}"
    while [[ "$code" == *__* ]]; do code="${code//__/_}"; done
    code="${code#_}"
    code="${code%_}"

    if [[ "$title" == "$NOTIFY_TITLE_SMART" ]]; then
        if [[ "${body,,}" == *"self-test"* ]]; then
            discriminator="selftest"
        elif [[ "${body,,}" == *"deferred"* || "${body,,}" == *"remains standby"* ]]; then
            discriminator="deferred"
        else
            discriminator="aggregate"
        fi
    fi

    case "$title" in
        "Btrfs Device"|"Btrfs Burst")
            if [[ "$body" =~ (read_io_errs|write_io_errs|flush_io_errs|corruption_errs|generation_errs) ]]; then
                discriminator="${BASH_REMATCH[1]}"
            fi
            ;;
        "Firmware Reset")
            if [[ "$body" == *"Power-On Hours"* ]]; then discriminator="poh"
            elif [[ "$body" == *"Percentage Used"* || "$body" == *"percent_used"* ]]; then discriminator="wear"
            fi
            ;;
        "XFS Alert")
            if [[ "$body" =~ Counter[[:space:]]+([A-Za-z0-9_]+) ]]; then
                discriminator="${BASH_REMATCH[1]}"
            fi
            ;;
        "SMART Trend")
            discriminator="$(printf '%s' "$body" | cksum | awk '{print $1}')"
            ;;
    esac

    FINDING_CODE_RESULT="${code:-finding}${discriminator:+_$discriminator}"
}

record_finding() {
    local severity="${1,,}"
    local category="$2"
    local signal="$3"
    local device="$4"
    local title="$5"
    local evidence="$6"
    local action="$7"
    local code="$8"
    local scope="global"
    local mount_ref=""
    local pool_ref=""
    local id old_severity requested_severity should_log=0

    [[ "$severity" == "critical" ]] || severity="warning"
    requested_severity="$severity"
    if [[ -n "$device" ]]; then
        device="$(base_device "$device")"
        scope="device:${device:-unknown}"
    else
        mount_ref=$(printf '%s' "$evidence" | grep -Eo '/mnt/[A-Za-z0-9_.-]+' | head -n1 || true)
        if [[ -n "$mount_ref" ]]; then
            scope="mount:$mount_ref"
        elif [[ "$evidence" =~ Pool[[:space:]]+([A-Za-z0-9_.-]+) ]]; then
            pool_ref="${BASH_REMATCH[1]}"
            scope="pool:$pool_ref"
        fi
    fi

    id="$scope|$code"
    if [[ -z "${FINDING_SEEN[$id]:-}" ]]; then
        FINDING_SEEN[$id]=1
        FINDING_IDS+=("$id")
        should_log=1
    fi

    old_severity="${FINDING_SEVERITY[$id]:-}"
    if [[ "$old_severity" == "critical" && "$requested_severity" != "critical" ]]; then
        return 0
    elif [[ "$old_severity" == "warning" && "$severity" == "critical" ]]; then
        should_log=1
    fi

    FINDING_SEVERITY[$id]="$severity"
    FINDING_CATEGORY[$id]="$category"
    FINDING_SIGNAL[$id]="$signal"
    FINDING_DEVICE[$id]="$device"
    FINDING_TITLE[$id]="$title"
    FINDING_EVIDENCE[$id]="$evidence"
    FINDING_ACTION[$id]="$action"
    FINDING_ALERT_TEXT[$id]="$title: $evidence"

    if (( should_log == 1 )); then
        if [[ "$severity" == "critical" ]]; then
            log_crit "$title - $evidence"
        else
            log_warn "$title - $evidence"
        fi
    fi

    if [[ -n "$device" ]]; then
        RISK_SPIKE_TS[$device]="$(date +%s)"
    fi

    return 0
}

# Record one canonical finding. Repeated wording changes for the same device and
# condition update the evidence instead of adding another risk contribution.
record_alert() {
    local severity="$1"
    local title="$2"
    local body="$3"
    local device=""

    device=$(printf '%s' "$body" | grep -Eo '/dev/[A-Za-z0-9]+' | head -n1 || true)
    classify_finding_metadata "$title" "$body"
    finding_code_for_alert "$title" "$body"
    record_finding \
        "$severity" \
        "$FINDING_CLASS_CATEGORY" \
        "$FINDING_CLASS_SIGNAL" \
        "$device" \
        "$title" \
        "$body" \
        "$FINDING_CLASS_ACTION" \
        "$FINDING_CODE_RESULT"
}

# Rebuild the legacy alert arrays from the canonical registry only after every
# collector has finished. Existing subsystem summaries therefore consume the
# same de-duplicated severity/evidence set as notification rendering.
materialize_alerts_from_findings() {
    local severity id text

    ALERT_WARN=()
    ALERT_CRIT=()
    ALERT_SEEN=()

    for severity in critical warning; do
        for id in "${FINDING_IDS[@]}"; do
            [[ "${FINDING_SEVERITY[$id]:-}" == "$severity" ]] || continue
            text="${FINDING_ALERT_TEXT[$id]:-}"
            [[ -n "$text" ]] || continue
            ALERT_SEEN[$id]=1
            if [[ "$severity" == "critical" ]]; then
                ALERT_CRIT+=("$text")
            else
                ALERT_WARN+=("$text")
            fi
        done
    done
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
    # Model lookup uses smartctl and can wake a SATA HDD. Defer it along with
    # the rest of SMART collection when this run intentionally kept it asleep.
    [[ -n "${SMART_DEFERRED[$d]:-}" ]] && echo "" && return 0
    if [[ "$d" == /dev/nvme* ]]; then
        smartctl_cached -i -d nvme "$d" 2>/dev/null |
            awk -F: '/Model Number/ {sub(/^ +/,"",$2); print $2; exit}'
    else
        smartctl_cached -i "$d" 2>/dev/null |
            awk -F: '/Device Model|Model Family/ {sub(/^ +/,"",$2); print $2; exit}'
    fi
}

# === Helper Function ===
# Build optional model suffix for health alerts depending on toggle
model_suffix_for() {
    local dev="$1"
    local suffix=""
    if [[ -n "$dev" && -n "${SMART_DEFERRED[$dev]:-}" ]]; then
        printf '%s' "$suffix"
        return 0
    fi
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
    local bytes
    bytes=$(lsblk_size_cached "$d")
    bytes=${bytes:-0}
    awk -v b="$bytes" 'BEGIN{printf "%.3f", b/1000000000000.0}'
}

# === Helper Function ===
# Read a SATA SMART raw attribute value by ID
get_sata_raw() {
    local d
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "" && return 0
    smartctl_cached -A "$d" 2>/dev/null || true
}

# === Helper Function ===
# Parse SATA device basic info from smartctl --info
get_sata_info() {
    local d
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "" && return 0
    smartctl_cached -i "$d" 2>/dev/null || true
}

# === Helper Function ===
# Read an NVMe SMART/health value by key
get_nvme_raw() {
    local d
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "" && return 0
    log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART attribute read (-a) on $d"
    smartctl_cached -a -d nvme "$d" 2>/dev/null || true
}

# === Helper Function ===
# Read extended NVMe statistics (device statistics & thermal/PCIe counters)
get_nvme_extended_raw() {
    local d
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "" && return 0
    log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe extended statistics read (-x) on $d"
    smartctl_cached -x -d nvme "$d" 2>/dev/null || true
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
# Evaluate TBW thresholds through explicit globals so alert side effects remain
# in the current shell. Do not call this function through command substitution.
eval_tbw_state() {
    local disk="$1"
    local tbw_bytes="$2"
    local in_state="${3:-OK}"
    local model cap tbw_thresh consumed_pct

    TBW_EVAL_STATE="$in_state"
    TBW_EVAL_MESSAGES=()

    model=$(get_device_model "$disk")
    cap=$(get_device_capacity_tb "$disk")
    tbw_thresh=$(tbw_threshold_tb_for_device "$model" "$cap")
    local TB=$((1000*1000*1000*1000))

    if [[ -n "$tbw_thresh" && "$tbw_thresh" =~ ^[0-9]+$ ]]; then
        if [[ "$cap" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            consumed_pct=$(awk -v w="$tbw_bytes" -v th="$tbw_thresh" 'BEGIN{printf "%.0f", (w/(th*1000*1000*1000*1000))*100}')
        fi
        if [[ -n "$consumed_pct" && "$consumed_pct" =~ ^[0-9]+$ ]]; then
            CUR_ATTR["$disk|tbw_consumed_pct"]="$consumed_pct"
            if (( consumed_pct >= TBW_CONSUMED_CRIT )); then
                TBW_EVAL_STATE="CRITICAL"
                TBW_EVAL_MESSAGES+=("TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_CRIT}%")
                record_alert critical "TBW Consumed" "Disk $disk TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_CRIT}%"
                return 0
            elif (( consumed_pct >= TBW_CONSUMED_WARN )) && [[ $TBW_EVAL_STATE != CRITICAL ]]; then
                [[ $TBW_EVAL_STATE == OK ]] && TBW_EVAL_STATE="WARNING"
                TBW_EVAL_MESSAGES+=("TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_WARN}%")
                record_alert warning "TBW Consumed" "Disk $disk TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_WARN}%"
                return 0
            fi
        fi
        return 0
    elif [[ $TBW_WARN_TB -gt 0 ]]; then
        if (( tbw_bytes >= TBW_WARN_TB * TB )) && [[ $TBW_EVAL_STATE != CRITICAL ]]; then
            [[ $TBW_EVAL_STATE == OK ]] && TBW_EVAL_STATE="WARNING"
            TBW_EVAL_MESSAGES+=("TBW exceeds ${TBW_WARN_TB} TB")
            record_alert warning "TBW Exceeds" "Disk $disk TBW exceeds ${TBW_WARN_TB} TB (bytes=$tbw_bytes)"
        fi
        return 0
    fi
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

# === Device discovery and stable identity ===
# Choose the best /dev/disk/by-id name without accessing drive media.
best_by_id_for_device() {
    local disk="$1"
    local link resolved name rank best="" best_rank=99

    for link in /dev/disk/by-id/*; do
        [[ -L "$link" ]] || continue
        name="${link##*/}"
        [[ "$name" == *-part[0-9]* ]] && continue
        resolved=$(readlink -f -- "$link" 2>/dev/null || true)
        [[ "$resolved" == "$disk" ]] || continue

        case "$name" in
            wwn-*|nvme-eui.*|nvme-uuid.*) rank=1 ;;
            ata-*|nvme-*) rank=2 ;;
            scsi-*) rank=3 ;;
            usb-*) rank=4 ;;
            *) rank=5 ;;
        esac

        if (( rank < best_rank )) ||
           { (( rank == best_rank )) && [[ -z "$best" || "$name" < "$best" ]]; }
        then
            best="$name"
            best_rank=$rank
        fi
    done

    printf '%s' "$best"
}

register_device_identity() {
    local disk="$1"
    local wwn serial by_id component identity source fingerprint existing

    [[ -b "$disk" ]] || return 1
    [[ -n "${DEVICE_ID_BY_PATH[$disk]:-}" ]] && return 0

    wwn=$(lsblk -dn -o WWN "$disk" 2>/dev/null | awk '{$1=$1; print; exit}')
    serial=$(lsblk -dn -o SERIAL "$disk" 2>/dev/null | awk '{$1=$1; print; exit}')
    by_id=$(best_by_id_for_device "$disk")

    component=$(safe_state_name "$wwn")
    if [[ -n "$wwn" && "$component" =~ [1-9A-Fa-f] ]]; then
        identity="wwn_${component}"
        source="wwn"
    elif [[ -n "$by_id" ]]; then
        identity="byid_$(safe_state_name "$by_id")"
        source="by-id"
    elif [[ -n "$serial" ]]; then
        identity="serial_$(safe_state_name "$serial")"
        source="serial"
    else
        identity="path_$(safe_state_name "$disk")"
        source="path-fallback"
    fi

    existing="${DEVICE_PATH_BY_ID[$identity]:-}"
    if [[ -n "$existing" && "$existing" != "$disk" ]]; then
        fingerprint=$(printf '%s' "$disk|$wwn|$serial|$by_id" | cksum | awk '{print $1}')
        identity="${identity}_${fingerprint}"
        log "INVENTORY" "WARN" \
            "Duplicate device identity detected for $disk and $existing; using disambiguated key $identity"
    fi

    DEVICE_ID_BY_PATH[$disk]="$identity"
    DEVICE_PATH_BY_ID[$identity]="$disk"
    DEVICE_ID_SOURCE[$identity]="$source"

    if [[ "$source" == "path-fallback" ]]; then
        log "INVENTORY" "WARN" \
            "No WWN, by-id, or serial available for $disk; persistent identity falls back to its path"
    fi
}

discover_device_inventory() {
    local boot_src boot_root="" name type disk device_name temp_file identity source
    local -a candidates=()
    local -A seen=()

    DEVICE_ID_BY_PATH=()
    DEVICE_PATH_BY_ID=()
    DEVICE_ID_SOURCE=()
    DISCOVERED_DISKS=()
    DEVICE_INVENTORY_READY=0

    cache_lsblk_all
    while read -r name _size _rota type; do
        [[ "$type" == "disk" ]] || continue
        [[ "$name" =~ ^sd[a-z]+$ || "$name" =~ ^nvme[0-9]+n[0-9]+$ ]] || continue
        disk="/dev/$name"
        [[ -b "$disk" && -z "${seen[$disk]:-}" ]] || continue
        seen[$disk]=1
        candidates+=("$disk")
    done <<< "$LSBLK_ALL_CACHE"

    # Include devices explicitly assigned by Unraid even if a controller omits
    # useful TYPE metadata from lsblk.
    if [[ -r /var/local/emhttp/disks.ini ]]; then
        while IFS= read -r device_name; do
            device_name="${device_name#/dev/}"
            [[ "$device_name" =~ ^(sd[a-z]+|nvme[0-9]+n[0-9]+)$ ]] || continue
            disk="/dev/$device_name"
            [[ -b "$disk" && -z "${seen[$disk]:-}" ]] || continue
            seen[$disk]=1
            candidates+=("$disk")
        done < <(
            awk -F= 'tolower($1)=="device" {
                value=$2
                gsub(/"/, "", value)
                gsub(/^[ \t]+|[ \t]+$/, "", value)
                if (value != "") print value
            }' /var/local/emhttp/disks.ini 2>/dev/null
        )
    fi

    # Last-resort discovery for unusual lsblk/controller output.
    for disk in /dev/sd* /dev/nvme*n*; do
        [[ -b "$disk" ]] || continue
        name="${disk##*/}"
        [[ "$name" =~ ^sd[a-z]+$ || "$name" =~ ^nvme[0-9]+n[0-9]+$ ]] || continue
        [[ -z "${seen[$disk]:-}" ]] || continue
        seen[$disk]=1
        candidates+=("$disk")
    done

    boot_src=$(findmnt -n -o SOURCE /boot 2>/dev/null || true)
    if [[ -n "$boot_src" ]]; then
        boot_src=$(readlink -f -- "$boot_src" 2>/dev/null || printf '%s' "$boot_src")
    fi
    [[ -n "$boot_src" ]] && boot_root=$(base_device "$boot_src")

    mapfile -t DISCOVERED_DISKS < <(
        printf '%s\n' "${candidates[@]}" |
            awk 'NF' |
            sort -Vu
    )

    candidates=()
    for disk in "${DISCOVERED_DISKS[@]}"; do
        [[ -n "$boot_root" && "$disk" == "$boot_root" ]] && continue
        register_device_identity "$disk" || continue
        candidates+=("$disk")
    done
    DISCOVERED_DISKS=("${candidates[@]}")

    temp_file="$(state_temp_file "$DEVICE_ID_MAP_FILE")" || return 1
    for disk in "${DISCOVERED_DISKS[@]}"; do
        identity="${DEVICE_ID_BY_PATH[$disk]}"
        source="${DEVICE_ID_SOURCE[$identity]}"
        printf '%s %s source=%s\n' "$identity" "$disk" "$source" >> "$temp_file"
    done
    atomic_commit "$temp_file" "$DEVICE_ID_MAP_FILE" || return 1
    DEVICE_INVENTORY_READY=1

    if (( ${#DISCOVERED_DISKS[@]} == 0 )); then
        log "INVENTORY" "WARN" "No non-boot SATA/SAS/NVMe disks were discovered"
    else
        log "INVENTORY" "INFO" \
            "Discovered ${#DISCOVERED_DISKS[@]} disk(s) with stable identity mapping"
    fi
}

persistent_device_key() {
    local device="$1"
    local base suffix identity

    [[ "$device" == /dev/* ]] || { printf '%s' "$device"; return 0; }
    base=$(base_device "$device")
    [[ -n "$base" ]] || { printf 'path_%s' "$(safe_state_name "$device")"; return 0; }
    suffix="${device#$base}"
    identity="${DEVICE_ID_BY_PATH[$base]:-}"
    [[ -n "$identity" ]] || identity="path_$(safe_state_name "$base")"
    printf '%s%s' "$identity" "${suffix:+@$suffix}"
}

runtime_device_path() {
    local key="$1"
    local identity suffix="" base

    if [[ "$key" == /dev/* ]]; then
        printf '%s' "$key"
        return 0
    fi

    identity="${key%%@*}"
    [[ "$key" == *@* ]] && suffix="${key#*@}"
    base="${DEVICE_PATH_BY_ID[$identity]:-}"
    [[ -n "$base" ]] || return 1
    printf '%s%s' "$base" "$suffix"
}

persistent_seen_key() {
    local key="$1" device remainder
    if [[ "$key" == /dev/*'|'* ]]; then
        device="${key%%|*}"
        remainder="${key#*|}"
        printf '%s|%s' "$(persistent_device_key "$device")" "$remainder"
    else
        printf '%s' "$key"
    fi
}

runtime_seen_key() {
    local key="$1" identity remainder device
    [[ "$key" == *'|'* ]] || { printf '%s' "$key"; return 0; }
    identity="${key%%|*}"
    remainder="${key#*|}"
    if device=$(runtime_device_path "$identity"); then
        printf '%s|%s' "$device" "$remainder"
    else
        printf '%s' "$key"
    fi
}

migrate_device_identity_histories() {
    local current_version="" file temp_file disk identity legacy_name stable_name directory
    local migration_failed=0
    local -a files=(
        "$TEMP_HISTORY_FILE"
        "$SATA_LINK_HISTORY_FILE"
        "$REPLACEMENT_EVENTS_FILE"
        "$SELFTEST_HISTORY_FILE"
        "$POH_HISTORY_FILE"
        "$SMART_ATTR_HISTORY_FILE"
        "$RISK_SCORES_HISTORY_FILE"
        "$TBW_HISTORY_FILE"
        "$HEAVY_WRITER_HISTORY_FILE"
        "$TBW_DAYSLEFT_HISTORY_FILE"
        "$BTRFS_DEV_HIST_FILE"
        "$BTRFS_DEV_PREV_FILE"
        "$IO_ERROR_HISTORY_FILE"
    )

    [[ -r "$DEVICE_ID_SCHEMA_FILE" ]] && read -r current_version < "$DEVICE_ID_SCHEMA_FILE" || true
    [[ "$current_version" == "2" ]] && return 0

    if (( ${#DISCOVERED_DISKS[@]} == 0 )); then
        log "STATE" "WARN" \
            "Deferring stable identity migration because no data disks were discovered"
        return 1
    fi

    log "STATE" "INFO" "Migrating persisted device references to stable identity schema v2"

    for file in "${files[@]}"; do
        [[ -s "$file" ]] || continue
        temp_file="$(state_temp_file "$file")" || {
            migration_failed=1
            continue
        }
        cp -p -- "$file" "$temp_file" 2>/dev/null || {
            rm -f -- "$temp_file" 2>/dev/null || true
            migration_failed=1
            continue
        }

        for disk in "${DISCOVERED_DISKS[@]}"; do
            identity="${DEVICE_ID_BY_PATH[$disk]:-}"
            [[ -n "$identity" ]] || continue
            sed -E \
                -e "s#${disk}(p?[0-9]+)#${identity}@\\1#g" \
                -e "s#${disk}([^A-Za-z0-9]|$)#${identity}\\1#g" \
                "$temp_file" > "${temp_file}.next" 2>/dev/null || {
                    migration_failed=1
                    rm -f -- "${temp_file}.next" 2>/dev/null || true
                    break
                }
            mv -f -- "${temp_file}.next" "$temp_file" || {
                migration_failed=1
                break
            }
        done

        if (( migration_failed == 0 )); then
            atomic_commit "$temp_file" "$file" || migration_failed=1
        else
            rm -f -- "$temp_file" "${temp_file}.next" 2>/dev/null || true
            break
        fi
    done

    # Migrate per-device cooldown and self-test filenames where a legacy file
    # exists. The file contents themselves remain unchanged.
    if (( migration_failed == 0 )); then
        for disk in "${DISCOVERED_DISKS[@]}"; do
            identity="${DEVICE_ID_BY_PATH[$disk]:-}"
            [[ -n "$identity" ]] || continue
            legacy_name=$(safe_state_name "$disk")
            stable_name=$(safe_state_name "$identity")

            for directory in "$UNSAFE_SDWN_STATE_DIR" "$CMD_TIMEOUT_STATE_DIR"; do
                if [[ -e "$directory/${legacy_name}.lastwarn" && ! -e "$directory/${stable_name}.lastwarn" ]]; then
                    mv -f -- "$directory/${legacy_name}.lastwarn" "$directory/${stable_name}.lastwarn" 2>/dev/null || true
                fi
            done

            if [[ -e "$SMART_SELFTEST_DIR/${disk##*/}.snapshot" && ! -e "$SMART_SELFTEST_DIR/${stable_name}.snapshot" ]]; then
                mv -f -- \
                    "$SMART_SELFTEST_DIR/${disk##*/}.snapshot" \
                    "$SMART_SELFTEST_DIR/${stable_name}.snapshot" 2>/dev/null || true
            fi
        done
    fi

    if (( migration_failed == 1 )); then
        log "STATE" "WARN" "Stable identity history migration was incomplete; it will retry next run"
        return 1
    fi

    atomic_write_text "$DEVICE_ID_SCHEMA_FILE" $'2\n' || return 1
    log "STATE" "INFO" "Stable identity history migration completed"
}

# Enumerate the inventory captured once by main().
get_all_disks() {
    if (( DEVICE_INVENTORY_READY == 0 )); then
        discover_device_inventory || true
    fi
    printf '%s\n' "${DISCOVERED_DISKS[@]}"
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
# Derive the active flag once from the cached parity snapshot.
derive_parity_activity() {
    local action_lc="${PARITY_ACTION:-}"
    local pos="${PARITY_POS:-}"
    local size="${PARITY_SIZE:-}"
    local remaining="${PARITY_REM:-}"
    local speed="${PARITY_SPEED_K:-}"

    PARITY_ACTIVE=0
    action_lc="${action_lc,,}"

    [[ -n "$action_lc" && "$action_lc" != "idle" ]] || return 0

    if [[ "$speed" =~ ^[0-9]+$ ]] && (( 10#$speed > 0 )); then
        PARITY_ACTIVE=1
    elif [[ "$remaining" =~ ^[0-9]+$ ]] && (( 10#$remaining > 0 )); then
        PARITY_ACTIVE=1
    elif [[ "$pos" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ ]] &&
         (( 10#$pos > 0 && 10#$pos < 10#$size ))
    then
        PARITY_ACTIVE=1
    fi
}

# Populate global parity progress/validity variables once per run.
parity_state() {
    if (( PARITY_STATE_LOADED == 1 )); then
        [[ -n "${PARITY_VALID_FLAG:-}${PARITY_ACTION:-}" ]]
        return
    fi
    PARITY_STATE_LOADED=1

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
            derive_parity_activity
            return 0
        fi
    fi
    derive_parity_activity
    return 1
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

    # main() captured parity state once before any subsystem collectors run.
    local clean_flag="${PARITY_VALID_FLAG:-}" 
    PARITY_CLEAN_FLAG="$clean_flag"

    # Derive high-level status line based on validity flag and active operation
    local is_active=$PARITY_ACTIVE
    if [[ -n "$clean_flag" ]]; then
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
        if [[ -n "$pos" ]]; then
            atomic_write_text "$progress_file" "$pos $curr_ts" || true
        fi
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
    local tmp state_key
    tmp="$(state_temp_file "$RISK_SPIKE_FILE")" || {
        log_warn "Unable to create risk-spike state temporary file"
        return 0
    }
    for dev in "${!RISK_SPIKE_TS[@]}"; do
        state_key=$(persistent_device_key "$dev")
        printf '%s %s\n' "$state_key" "${RISK_SPIKE_TS[$dev]}" >> "$tmp"
    done
    atomic_commit "$tmp" "$RISK_SPIKE_FILE" || true
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

load_persistent_state() {
    local disk date dev rest token k v line key poh cnt ts score stored_key
    local now_ts prune_days age_days

    now_ts="$(date +%s)"
    prune_days=${LONG_TEST_RISK_LOOKBACK_DAYS:-14}

if [ -f "$SMART_LAST" ]; then
    while read -r stored_key date rest; do
        disk=$(runtime_device_path "$stored_key" 2>/dev/null || true)
        [[ -n "$disk" && -n "$date" ]] || continue
        LAST_TEST["$disk"]=$date
        for token in $rest; do
            k=${token%%=*}
            v=${token#*=}
            case "$k" in
                epoch) [[ "$v" =~ ^[0-9]+$ ]] && LAST_TEST_EPOCH["$disk"]="$v" ;;
                type) [[ -n "$v" ]] && LAST_TEST_KIND["$disk"]="$v" ;;
            esac
        done
        if [[ ! "${LAST_TEST_EPOCH[$disk]:-}" =~ ^[0-9]+$ ]]; then
            LAST_TEST_EPOCH["$disk"]=$(date -d "$date" +%s 2>/dev/null || true)
        fi
    done < "$SMART_LAST"
fi

if [ -f "$NVME_STATE_FILE" ]; then
    while read -r stored_key rest; do
        dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
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
        stored_key=$(echo "$line" | awk '{print $1}')
        disk=$(runtime_device_path "$stored_key" 2>/dev/null || true)
        [[ -n "$disk" ]] || continue
        for token in $(echo "$line" | awk '{for(i=2;i<=NF;i++) print $i}'); do
            k=""; v=""
            k=${token%%=*}; v=${token#*=}
            [[ -n "$k" ]] && PREV_ATTR["$disk|$k"]="$v"
        done
    done < "$PREV_ATTR_FILE"
fi

if [ -f "$RISK_PREV_FILE" ]; then
    while read -r stored_key score; do
        disk=$(runtime_device_path "$stored_key" 2>/dev/null || true)
        [[ -n "$disk" && "$score" =~ ^[0-9]+$ ]] || continue
        PREVIOUS_RISK["$disk"]="$score"
    done < "$RISK_PREV_FILE"
fi
if [ -f "$ALERT_NEW_SEEN_FILE" ]; then
    while IFS= read -r key; do
        key=$(runtime_seen_key "$key")
        [[ -n "$key" ]] && NEW_SEEN["$key"]=1
    done < "$ALERT_NEW_SEEN_FILE"
fi

# Load persisted last long self-test lifetime hours
if [ -f "$SMART_LONG_LAST_POH_FILE" ]; then
    while read -r stored_key poh; do
        disk=$(runtime_device_path "$stored_key" 2>/dev/null || true)
        [[ -z "$disk" || -z "$poh" ]] && continue
        [[ "$poh" =~ ^[0-9]+$ ]] || continue
        LONG_LAST_POH["$disk"]="$poh"
    done < "$SMART_LONG_LAST_POH_FILE"
fi

# Load previous Command_Timeout counts for delta alerts
if [ -f "$CMD_TIMEOUT_LAST_FILE" ]; then
    while read -r stored_key cnt; do
        disk=$(runtime_device_path "$stored_key" 2>/dev/null || true)
        [[ -z "$disk" || -z "$cnt" ]] && continue
        [[ "$cnt" =~ ^[0-9]+$ ]] || continue
        CMD_TIMEOUT_LAST["$disk"]="$cnt"
    done < "$CMD_TIMEOUT_LAST_FILE"
fi

# Load persisted risk spike timestamps (prune entries older than lookback)
if [ -f "$RISK_SPIKE_FILE" ]; then
    while read -r stored_key ts; do
        disk=$(runtime_device_path "$stored_key" 2>/dev/null || true)
        [[ -z "$disk" || -z "$ts" ]] && continue
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        # Apply lookback pruning at load time
        age_days=$(( (now_ts - ts) / 86400 ))
        if (( age_days <= prune_days )); then
            RISK_SPIKE_TS["$disk"]="$ts"
        fi
    done < "$RISK_SPIKE_FILE"
fi
}

# === Helper Function ===
# Persist actual SMART test-start metadata for a device
save_last_test() {
    local temp_file disk state_key
    temp_file="$(state_temp_file "$SMART_LAST")" || return 1
    for disk in "${!LAST_TEST[@]}"; do
        state_key=$(persistent_device_key "$disk")
        printf '%s %s epoch=%s type=%s\n' \
            "$state_key" \
            "${LAST_TEST[$disk]}" \
            "${LAST_TEST_EPOCH[$disk]:-0}" \
            "${LAST_TEST_KIND[$disk]:-unknown}" >> "$temp_file"
    done
    atomic_commit "$temp_file" "$SMART_LAST"
}

# === Helper Function ===
# Persist last-run NVMe health snapshot for a device
save_nvme_state() {
    local temp_file dev line state_key
    temp_file="$(state_temp_file "$NVME_STATE_FILE")" || return 1
    for dev in "${!NVME_LAST_UNSAFE[@]}"; do
        state_key=$(persistent_device_key "$dev")
        line="$state_key unsafe=${NVME_LAST_UNSAFE[$dev]:-0}"
        line+=" errlog=${NVME_LAST_ERRLOG[$dev]:-0}"
        line+=" pc_corr=${NVME_LAST_PCIE_CORR[$dev]:-0}"
        line+=" pc_unc=${NVME_LAST_PCIE_UNC[$dev]:-0}"
        line+=" therm_t1=${NVME_LAST_THERM_T1[$dev]:-0}"
        line+=" therm_t2=${NVME_LAST_THERM_T2[$dev]:-0}"
        line+=" warn_temp_time=${NVME_LAST_WARN_TEMP_TIME[$dev]:-0}"
        line+=" crit_temp_time=${NVME_LAST_CRIT_TEMP_TIME[$dev]:-0}"
        printf '%s\n' "$line" >> "$temp_file"
    done
    atomic_commit "$temp_file" "$NVME_STATE_FILE"
}

# === Helper Function ===
# Persist last observed long self-test lifetime hours per disk
save_long_last_poh() {
    local temp_file disk state_key
    temp_file="$(state_temp_file "$SMART_LONG_LAST_POH_FILE")" || return 1
    for disk in "${!LONG_LAST_POH[@]}"; do
        state_key=$(persistent_device_key "$disk")
        printf '%s %s\n' "$state_key" "${LONG_LAST_POH[$disk]}" >> "$temp_file"
    done
    atomic_commit "$temp_file" "$SMART_LONG_LAST_POH_FILE"
}

# === Helper Function ===
# Persist last observed Command_Timeout counts per disk
save_cmd_timeout_last() {
    local temp_file disk state_key
    temp_file="$(state_temp_file "$CMD_TIMEOUT_LAST_FILE")" || return 1
    for disk in "${!CMD_TIMEOUT_LAST[@]}"; do
        state_key=$(persistent_device_key "$disk")
        printf '%s %s\n' "$state_key" "${CMD_TIMEOUT_LAST[$disk]}" >> "$temp_file"
    done
    atomic_commit "$temp_file" "$CMD_TIMEOUT_LAST_FILE"
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
            eval_tbw_state "$disk" "$tbw_bytes" "$state"
            state="$TBW_EVAL_STATE"
            if (( ${#TBW_EVAL_MESSAGES[@]} > 0 )); then
                messages+=("${TBW_EVAL_MESSAGES[@]}")
            fi
        fi
        # Parse temperature and evaluate wear percent thresholds
        nvme_temp=$(echo "$nvme_output" | awk -F: '/Temperature/ {print $2; exit}' | grep -oE '[0-9]+' | head -n1 || true)
        if [[ -n "$nvme_temp" && "$nvme_temp" =~ ^[0-9]+$ ]]; then
            local nvme_temp_date nvme_temp_key nvme_temp_record
            nvme_temp_date=$(date '+%Y-%m-%d')
            nvme_temp_key=$(persistent_device_key "$disk")
            nvme_temp_record="$nvme_temp_date $nvme_temp_key temp=$nvme_temp captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION"
            atomic_upsert_daily_history \
                "$TEMP_HISTORY_FILE" "$nvme_temp_date" "$nvme_temp_key" "$nvme_temp_record" || true
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
            record_alert critical "NVMe Critical Warning" "Disk $disk NVMe Critical Warning flags: $crit_warn"
            local cw_dec=""
            if [[ $crit_warn =~ ^0x[0-9A-Fa-f]+$ ]]; then
                cw_dec=$((16#${crit_warn#0x}))
            else
                cw_dec=$crit_warn
            fi
            if (( (cw_dec & 0x02) != 0 )); then
                messages+=("NVMe thermal threshold exceeded (Critical Warning bit1)")
                record_alert critical "NVMe Thermal Warning" "Disk $disk NVMe thermal threshold exceeded (Critical Warning bit1)"
            fi
            if (( (cw_dec & 0x01) != 0 )); then
                # Available spare below threshold (warn)
                local dup=0; for m in "${messages[@]}"; do [[ $m == *"Available Spare"* ]] && dup=1; done; (( dup==0 )) && messages+=("NVMe available spare below threshold (Critical Warning bit0)")
                [[ $state == OK ]] && state="WARNING"
                record_alert warning "NVMe Available Spare" "Disk $disk NVMe available spare below threshold (Critical Warning bit0)"
            fi
            if (( (cw_dec & 0x04) != 0 )); then
                state="CRITICAL"; messages+=("NVMe reliability degraded (Critical Warning bit2)")
                record_alert critical "NVMe Reliability" "Disk $disk NVMe reliability degraded (Critical Warning bit2)"
            fi
            if (( (cw_dec & 0x08) != 0 )); then
                state="CRITICAL"; messages+=("NVMe media in read-only mode (Critical Warning bit3)")
                record_alert critical "NVMe Read-Only" "Disk $disk NVMe media in read-only mode (Critical Warning bit3)"
            fi
            if (( (cw_dec & 0x10) != 0 )); then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe volatile memory backup failed (Critical Warning bit4)")
                record_alert warning "NVMe Volatile Memory" "Disk $disk NVMe volatile memory backup failed (Critical Warning bit4)"
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
        local cooldown_key legacy_warn_file
        cooldown_key=$(persistent_device_key "$disk")
        local warn_file="$UNSAFE_SDWN_STATE_DIR/$(safe_state_name "$cooldown_key").lastwarn"
        legacy_warn_file="$UNSAFE_SDWN_STATE_DIR/$(safe_state_name "$disk").lastwarn"
        if [[ ! -e "$warn_file" && -e "$legacy_warn_file" ]]; then
            mv -f -- "$legacy_warn_file" "$warn_file" 2>/dev/null || true
        fi
        if [[ ${UNSAFE_SDWN_COOLDOWN_DAYS:-0} -gt 0 ]]; then
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
            if (( UNSAFE_SDWN_COOLDOWN_DAYS > 0 )); then
                atomic_write_text "$warn_file" "$(date +%s)" || true
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
                        local cooldown_key legacy_warn_file
                        cooldown_key=$(persistent_device_key "$disk")
                        local warn_file="$CMD_TIMEOUT_STATE_DIR/$(safe_state_name "$cooldown_key").lastwarn"
                        legacy_warn_file="$CMD_TIMEOUT_STATE_DIR/$(safe_state_name "$disk").lastwarn"
                        if [[ ! -e "$warn_file" && -e "$legacy_warn_file" ]]; then
                            mv -f -- "$legacy_warn_file" "$warn_file" 2>/dev/null || true
                        fi
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
                            atomic_write_text "$warn_file" "$(date +%s)" || true
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
            local sata_temp_date sata_temp_key sata_temp_record
            sata_temp_date=$(date '+%Y-%m-%d')
            sata_temp_key=$(persistent_device_key "$disk")
            sata_temp_record="$sata_temp_date $sata_temp_key temp=$temp captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION"
            atomic_upsert_daily_history \
                "$TEMP_HISTORY_FILE" "$sata_temp_date" "$sata_temp_key" "$sata_temp_record" || true
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
                        local today sata_link_key sata_link_record
                        today=$(date '+%Y-%m-%d')
                        sata_link_key=$(persistent_device_key "$disk")
                        sata_link_record="$today $sata_link_key max=$max_speed current=$current_speed captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION"
                        atomic_upsert_daily_history \
                            "$SATA_LINK_HISTORY_FILE" "$today" "$sata_link_key" "$sata_link_record" || true
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
            eval_tbw_state "$disk" "$tbw_bytes" "$state"
            state="$TBW_EVAL_STATE"
            if (( ${#TBW_EVAL_MESSAGES[@]} > 0 )); then
                messages+=("${TBW_EVAL_MESSAGES[@]}")
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
        out=$(get_selftest_live "$disk")
    else
        out=$(get_selftest_live "$disk")
    fi
    local line
    # Most recent entry is first after header; support lines starting with '#' token then numeric ID
    line=$(echo "$out" | awk 'NR>5 && (($1=="#" && $2 ~ /^[0-9]+$/) || $1 ~ /^[0-9]+$/) {print; exit}')
    if [[ -z "$line" ]]; then
        # No entries in self-test log; fall back to execution status from capabilities page
        local exec_status
        if [[ $disk == /dev/nvme* ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART capability read (-c) on $disk"
            exec_status=$(get_capabilities_live "$disk" | awk -F: '/Self-test execution status/ {sub(/^ +/,"",$2); print $2; exit}') || true
        else
            exec_status=$(get_capabilities_live "$disk" | awk -F: '/Self-test execution status/ {sub(/^ +/,"",$2); print $2; exit}') || true
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
    echo "$sev|$msg"
}

# === Helper Function ===
# Persist a compact snapshot of the latest SMART self-test (or capabilities fallback)
save_selftest_snapshot() {
    local disk="$1"
    local info num type status lifetime remaining sev msg target temp_file state_key
    info=$(get_latest_selftest_info "$disk")
    IFS='|' read -r num type status lifetime remaining <<< "$info"
    # Classify status for quick glance
    local cls
    cls=$(classify_selftest_status "$status")
    sev=$(echo "$cls" | awk -F'|' '{print $1}')
    msg=$(echo "$cls" | awk -F'|' '{print $2}')
    state_key=$(persistent_device_key "$disk")
    target="$SMART_SELFTEST_DIR/$(safe_state_name "$state_key").snapshot"
    temp_file="$(state_temp_file "$target")" || return 1
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
    } > "$temp_file" 2>/dev/null || {
        rm -f -- "$temp_file" 2>/dev/null || true
        return 1
    }
    atomic_commit "$temp_file" "$target"
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

# === Helper Functions ===
# Map a canonical signal to one risk contribution. Severity is used only where
# the configured weights distinguish warning from critical evidence.
risk_points_for_signal() {
    local signal="$1"
    local severity="$2"
    local points=0

    case "$signal" in
        smart.media)             points=$W_UNCORR ;;
        smart.reallocation)      points=$W_REALLOC ;;
        smart.selftest)
            if [[ "$severity" == "critical" ]]; then
                points=$W_SELFTEST_CRIT
            else
                points=$W_SELFTEST_WARN
            fi
            ;;
        smart.end_to_end)        points=$W_E2E ;;
        smart.soft_read)         points=$W_SOFT_READ ;;
        smart.read_only)         points=$W_NVME_RO ;;
        smart.reliability)       points=$W_NVME_REL ;;
        smart.nvme_error_log)    points=$W_NVME_ERR_LOG ;;
        io.command_timeout)      points=$W_CMD_TIMEOUT ;;
        io.sata_link)            points=$W_SATA_LINK_DOWN ;;
        io.pcie_link)
            if [[ "$severity" == "critical" ]]; then
                points=$W_NVME_PCIE_UNC
            else
                points=$W_NVME_PCIE_CORR
            fi
            ;;
        io.kernel)
            if [[ "$severity" == "critical" ]]; then
                points=$W_UNCORR
            else
                points=$W_CMD_TIMEOUT
            fi
            ;;
        io.power)                points=$W_CMD_TIMEOUT ;;
        thermal.exposure)        points=$W_NVME_TEMP_TIME ;;
        endurance.tbw)
            if [[ "$severity" == "critical" ]]; then
                points=$W_TBW_CONS_CRIT
            else
                points=$W_TBW_CONS_WARN
            fi
            ;;
        endurance.wear)          points=$W_NVME_WEAR ;;
        lifecycle.age)           points=$W_POH_HDD ;;
        lifecycle.regression)    points=$W_AGE_NEAR ;;
        filesystem.btrfs)        points=$W_BTRFS_DEV_ERR ;;
        filesystem.xfs)          points=$W_XFS_META_ERR ;;
    esac

    printf '%s\n' "$points"
}

# Canonical scorer used by SMART scheduling, ranking, persistence, and lifecycle
# classification. Each underlying signal contributes at most once per device,
# even when several collectors report different evidence for that signal.
risk_score_for_device() {
    local dev="$1"
    local state="$2"
    local _legacy_message="${3:-}"
    local base_dev=""
    local score=0 id signal severity points existing
    local percent_used life_remaining tbw_consumed
    declare -A SIGNAL_POINTS=()

    if [[ -n "$dev" ]]; then
        base_dev="$(base_device "$dev")"
    fi

    case "$state" in
        CRITICAL) ((score += W_SEV_CRIT)) ;;
        WARNING)  ((score += W_SEV_WARN)) ;;
    esac

    if [[ -n "$base_dev" ]]; then
        for id in "${FINDING_IDS[@]}"; do
            [[ "${FINDING_DEVICE[$id]:-}" == "$base_dev" ]] || continue
            signal="${FINDING_SIGNAL[$id]:-advisory}"
            severity="${FINDING_SEVERITY[$id]:-warning}"
            points="$(risk_points_for_signal "$signal" "$severity")"
            [[ "$points" =~ ^[0-9]+$ ]] || points=0
            existing="${SIGNAL_POINTS[$signal]:-0}"
            if (( points > existing )); then
                SIGNAL_POINTS[$signal]=$points
            fi
        done

        # Direct attribute fallbacks cover retained/migrated state even when a
        # device was not awake long enough to emit a fresh finding this run.
        percent_used=${CUR_ATTR["$base_dev|nvme_percent_used"]:-0}
        life_remaining=${CUR_ATTR["$base_dev|life_remain"]:-0}
        tbw_consumed=${CUR_ATTR["$base_dev|tbw_consumed_pct"]:-0}

        if [[ "$percent_used" =~ ^[0-9]+$ ]] && (( percent_used >= 90 )); then
            existing="${SIGNAL_POINTS["endurance.wear"]:-0}"
            (( W_AGE_NEAR > existing )) && SIGNAL_POINTS["endurance.wear"]=$W_AGE_NEAR
        elif [[ "$life_remaining" =~ ^[0-9]+$ ]] &&
             (( life_remaining > 0 && life_remaining <= 10 ))
        then
            existing="${SIGNAL_POINTS["endurance.wear"]:-0}"
            (( W_AGE_NEAR > existing )) && SIGNAL_POINTS["endurance.wear"]=$W_AGE_NEAR
        fi

        if [[ "$tbw_consumed" =~ ^[0-9]+$ ]]; then
            existing="${SIGNAL_POINTS["endurance.tbw"]:-0}"
            if (( tbw_consumed >= TBW_CONSUMED_CRIT && W_TBW_CONS_CRIT > existing )); then
                SIGNAL_POINTS["endurance.tbw"]=$W_TBW_CONS_CRIT
            elif (( tbw_consumed >= TBW_CONSUMED_WARN && W_TBW_CONS_WARN > existing )); then
                SIGNAL_POINTS["endurance.tbw"]=$W_TBW_CONS_WARN
            fi
        fi
    fi

    for signal in "${!SIGNAL_POINTS[@]}"; do
        points="${SIGNAL_POINTS[$signal]:-0}"
        ((score += points))
    done
    (( score > 100 )) && score=100

    printf '%s\n' "$score"
}

# === Helper Function ===
# Launch SMART tests (short/long) as configured
run_smart_test() {
    local disk=$1
    if ! prepare_smart_access "$disk"; then
        retain_previous_smart_snapshot "$disk" "${SATA_POWER_STATE[$disk]:-standby}"
        return 0
    fi
    local test_kind="short"
    local selftest poh_attr current_poh last_long_hours_diff="" last_long_poh="" threshold_hours=$(( LONG_TEST_MAX_INTERVAL_DAYS * 24 ))
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
                printf '%s %s prev_poh=%s new_poh=%s drop=%s threshold=%s captured_epoch=%s schema=%s\n' \
                    "$(date '+%Y-%m-%d %H:%M:%S')" "$(persistent_device_key "$disk")" \
                    "$persisted_ll" "$current_poh" "$(( persisted_ll - current_poh ))" \
                    "$drop_threshold" "$RUN_EPOCH" "$HISTORY_SCHEMA_VERSION" \
                    >> "$REPLACEMENT_EVENTS_FILE" 2>/dev/null || true
                unset 'LONG_LAST_POH["$disk"]'
                # Prune processed long-test id for this disk to avoid stale suppression
                if [[ -f "$SMART_LONG_STATE_FILE" ]]; then
                    local processed_temp processed_state_key
                    processed_temp="$(state_temp_file "$SMART_LONG_STATE_FILE")" || processed_temp=""
                    if [[ -n "$processed_temp" ]]; then
                        processed_state_key=$(persistent_device_key "$disk")
                        awk -v dev="$disk" -v stable="$processed_state_key" \
                            '$1 != dev && $1 != stable' \
                            "$SMART_LONG_STATE_FILE" > "$processed_temp" 2>/dev/null || true
                        atomic_commit "$processed_temp" "$SMART_LONG_STATE_FILE" || true
                    fi
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
    local state_pre msgs_pre risk_pre previous_risk_pre schedule_long=0 test_due=0 test_started=0 reasons=()
    evaluate_smart "$disk" "pre-test"
    state_pre="${SMART_STATE[$disk]:-OK}"
    msgs_pre="${SMART_MSGS[$disk]:-}"
    risk_pre=$(risk_score_for_device "$disk" "$state_pre" "$msgs_pre")
    # The previous value is the last fully finalized canonical score (including
    # filesystem, I/O, endurance, and trend findings). Keep the higher value so
    # test scheduling does not ignore a recent non-SMART risk signal merely
    # because those collectors run later in the current cycle.
    previous_risk_pre="${PREVIOUS_RISK[$disk]:-}"
    if [[ "$previous_risk_pre" =~ ^[0-9]+$ ]] &&
       (( previous_risk_pre > risk_pre ))
    then
        risk_pre=$previous_risk_pre
    fi
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
        test_due=1
        local last_note="no record"
        [[ -n "${last_long_hours_diff:-}" ]] && last_note="${last_long_hours_diff}h"
        local reason_join
        reason_join=$(join_by ', ' "${reasons[@]}")
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - LONG test scheduled on $disk (last_long=${last_note}; reasons=${reason_join})"
        LONG_TEST_DECISION+="$disk: long scheduled (last=${last_note}; reasons=${reason_join}; risk=${risk_pre}; state=${state_pre})\n"
        # Alerts only for critical state or risk threshold
        if [[ "$state_pre" == CRITICAL ]]; then
            record_alert critical "SMART Scheduling" "Disk $disk long test scheduled (critical state; risk=${risk_pre})"
        elif (( risk_pre >= LONG_TEST_RISK_THRESHOLD )); then
            record_alert warning "SMART Scheduling" "Disk $disk long test scheduled (risk ${risk_pre} >= ${LONG_TEST_RISK_THRESHOLD})"
        fi
    else
        if short_test_is_due "$disk"; then
            test_due=1
            log_smart "SHORT test due on $disk (interval=${SHORT_TEST_INTERVAL_DAYS}d, risk=${risk_pre}, state=${state_pre})"
        elif [[ "${SHORT_TEST_INTERVAL_DAYS:-0}" =~ ^0+$ ]]; then
            log_smart "Automatic SHORT tests disabled for $disk (SHORT_TEST_INTERVAL_DAYS=0)"
        else
            local next_short_date
            next_short_date=$(short_test_next_date "$disk")
            log_smart "SHORT test not due on $disk${next_short_date:+; next eligible $next_short_date}"
        fi
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
        printf '%s %s in_progress status=%s captured_epoch=%s schema=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(persistent_device_key "$disk")" "$exec_status" "$RUN_EPOCH" "$HISTORY_SCHEMA_VERSION" >> "$SELFTEST_HISTORY_FILE" 2>/dev/null || true
    elif (( test_due == 1 )); then
        local test_start_output="" test_start_rc=0
        if [[ $disk == /dev/nvme* ]]; then
            log_smart "Starting NVMe SMART test (-t ${test_kind}) on $disk"
            test_start_output=$(smartctl -t "$test_kind" -d nvme "$disk" 2>&1)
            test_start_rc=$?
        else
            log_smart "Starting SATA SMART test (-t ${test_kind}) on $disk"
            test_start_output=$(smartctl -t "$test_kind" "$disk" 2>&1)
            test_start_rc=$?
        fi

        if (( test_start_rc == 0 )) ||
           printf '%s' "$test_start_output" |
               grep -qiE 'self-test.*(begun|started)|testing has begun|please wait'
        then
            test_started=1
            mark_test_started "$disk" "$test_kind"
            printf '%s %s start type=%s captured_epoch=%s schema=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(persistent_device_key "$disk")" "${test_kind}" "$RUN_EPOCH" "$HISTORY_SCHEMA_VERSION" >> "$SELFTEST_HISTORY_FILE" 2>/dev/null || true
            if [[ $test_kind == long || $test_kind == extended ]]; then
                LONG_TEST_RUNNING_LONG["$disk"]=1
            fi
        else
            local start_error
            start_error=$(printf '%s' "$test_start_output" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-240)
            log_warn "SMART test start failed on $disk (type=$test_kind, rc=$test_start_rc): ${start_error:-no output}"
            record_alert warning "SMART Scheduling" "Disk $disk failed to start $test_kind SMART test"
        fi
    fi
    if [[ $test_kind == short && $SHORT_TEST_POLL -eq 1 && $test_started -eq 1 ]]; then
        local result
        result=$(poll_short_test_completion "$disk")
        local s sev msg
        sev=$(echo "$result" | awk -F'|' '{print $1}')
        msg=$(echo "$result" | awk -F'|' '{print $2}')
        if [[ $sev != INPROGRESS ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - $disk short self-test status: $msg"
            printf '%s %s complete type=short sev=%s msg="%s" captured_epoch=%s schema=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(persistent_device_key "$disk")" "$sev" "$msg" "$RUN_EPOCH" "$HISTORY_SCHEMA_VERSION" >> "$SELFTEST_HISTORY_FILE" 2>/dev/null || true
            if [[ $sev == WARNING ]]; then
                record_alert warning "$NOTIFY_TITLE_SMART" "Disk $disk short self-test warning: $msg"
            fi
        else
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - $disk short self-test still in progress after wait window"
            printf '%s %s incomplete type=short status=in_progress captured_epoch=%s schema=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(persistent_device_key "$disk")" "$RUN_EPOCH" "$HISTORY_SCHEMA_VERSION" >> "$SELFTEST_HISTORY_FILE" 2>/dev/null || true
        fi
    else
        if [[ $existing_in_progress -eq 1 ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Skipping poll (different test still running)"
        elif (( test_started == 1 )); then
            sleep 5
        fi
    fi
    # A test can change self-test/capability output. Drop only this run's cache before
    # the post-test read so no pre-test snapshot is accidentally reused.
    if (( test_started == 1 )); then
        invalidate_smart_cache "$disk"
    fi

    # Attribute health was evaluated once before scheduling. Short-test completion
    # is classified above, so a second full attribute pass would only duplicate
    # threshold alerts in the same run.
    local state="${SMART_STATE[$disk]:-OK}" msgs="${SMART_MSGS[$disk]:-}"
    if [[ $state == WARNING || $state == CRITICAL ]]; then
        record_alert "$state" "$NOTIFY_TITLE_SMART" "Disk $disk SMART $state: $msgs"
    fi
    # Persist a compact latest self-test snapshot (even when device self-test log is empty)
    save_selftest_snapshot "$disk"
}

# === Helper Function ===
# Append trend deltas (e.g., pending, realloc) to SMART messages
augment_messages_with_deltas() {
    for disk in "${!SMART_STATE[@]}"; do
        local raw="${SMART_MSGS[$disk]}"
        [[ -z "$raw" ]] && continue
        IFS=';' read -r -a parts <<< "$raw"
        local augmented=()
        for p in "${parts[@]}"; do
            p="${p#"${p%%[![:space:]]*}"}"
            p="${p%"${p##*[![:space:]]}"}"
            [[ -z "$p" ]] && continue
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
    local -a disks=()
    local disk temp_file d id stored_key state_key

    if [[ -f "$SMART_LONG_STATE_FILE" ]]; then
        while read -r stored_key id; do
            d=$(runtime_device_path "$stored_key" 2>/dev/null || true)
            [[ -n "$d" && -n "$id" ]] && PROCESSED[$d]="$id"
        done < "$SMART_LONG_STATE_FILE"
    fi
    mapfile -t disks < <(get_all_disks)
    for disk in "${disks[@]}"; do
        [[ -n "$disk" ]] || continue
        # Sanitize disk before smartctl invocations
        if [[ ! "$disk" =~ ^/dev/[A-Za-z0-9]+([p0-9]+)?$ ]]; then continue; fi
        # Do not wake sleeping rotational devices merely to inspect an old
        # self-test log. run_smart_test() will retain their previous snapshot.
        if ! prepare_smart_access "$disk"; then
            continue
        fi
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
        printf '%s %s complete type=long id=%s sev=%s msg="%s" captured_epoch=%s schema=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(persistent_device_key "$disk")" "$id" "$sev" "$msg" "$RUN_EPOCH" "$HISTORY_SCHEMA_VERSION" >> "$SELFTEST_HISTORY_FILE" 2>/dev/null || true
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
        PROCESSED["$disk"]="$id"
    done

    temp_file="$(state_temp_file "$SMART_LONG_STATE_FILE")" || return 0
    for disk in "${!PROCESSED[@]}"; do
        state_key=$(persistent_device_key "$disk")
        printf '%s %s\n' "$state_key" "${PROCESSED[$disk]}" >> "$temp_file"
    done
    atomic_commit "$temp_file" "$SMART_LONG_STATE_FILE" || true
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
        key="$(safe_state_name "$m")"
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
                    while IFS= read -r _ln; do [[ -n "$_ln" ]] && log_btrfs "$m scrub start (forced baseline): $_ln"; done <<< "$_scrub_force"
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
            local status_temp
            status_temp="$(state_temp_file "$file")" || status_temp=""
            if [[ -n "$status_temp" ]]; then
                {
                    printf "Saved: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
                    printf "%s" "$status"
                } > "$status_temp" 2>/dev/null || true
                atomic_commit "$status_temp" "$file" || true
            fi
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
    local -a mountpoints=()
    local mp
    mapfile -t mountpoints < <(mount | awk '$5=="xfs" {print $3}')
    for mp in "${mountpoints[@]}"; do
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

# === Main Collection Phase ===
# Run SMART tests, record daily SMART history, and calculate NVMe wear projection.
collect_smart_health() {
    local -a disks=()
    local disk today tmp poh line key val stored_key
    local win_wear cutoff_wear dt dev rest pu fv lv span_days growth rate remaining dl warn_thr crit_thr

    log_smart "Starting SMART tests (short by default; long scheduled per risk)"
    check_completed_long_tests
    mapfile -t disks < <(get_all_disks)
    for disk in "${disks[@]}"; do
        [[ -n "$disk" ]] || continue
        run_smart_test "$disk"
    done
    log_smart "SMART tests completed"
    augment_messages_with_deltas

# Persist daily POH snapshot for aging trend (once per day)
if (( POH_TREND_ENABLED == 1 )); then
    today=$(date '+%Y-%m-%d')
    local -a poh_records=()
    for disk in "${!SMART_STATE[@]}"; do
        [[ -n "${SMART_DEFERRED[$disk]:-}" ]] && continue
        poh=${CUR_ATTR["$disk|poh"]:-}
        if [[ -n "$poh" && "$poh" =~ ^[0-9]+$ ]]; then
            poh_records+=("$today $(persistent_device_key "$disk") poh=$poh captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION")
        fi
    done
    atomic_replace_daily_history "$POH_HISTORY_FILE" "$today" "${poh_records[@]}" ||
        log_warn "Unable to atomically update POH history"
fi
 # Persist daily SMART attribute snapshot (once per day)
 if (( SMART_ATTR_TREND_ENABLED == 1 )); then
    today=$(date '+%Y-%m-%d')
    local -a smart_attr_records=()
    for disk in "${!SMART_STATE[@]}"; do
        [[ -n "${SMART_DEFERRED[$disk]:-}" ]] && continue
        # Build compact attribute line: date device attr=value ... (subset of noisy attrs)
        line="$today $(persistent_device_key "$disk")"
        for key in realloc pending offunc reported_uncorr cmd_timeout realloc_events udma soft_read_err nvme_percent_used unsafe_shutdowns media_errors err_logs pcie_corr pcie_unc therm_t1 therm_t2 warn_temp_time crit_temp_time tbw_bytes poh; do
            val=${CUR_ATTR["$disk|$key"]:-}
            [[ -n "$val" ]] && line+=" $key=$val"
        done
        line+=" captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION"
        smart_attr_records+=("$line")
    done
    atomic_replace_daily_history "$SMART_ATTR_HISTORY_FILE" "$today" "${smart_attr_records[@]}" ||
        log_warn "Unable to atomically update SMART attribute history"
 fi
     # NVMe wear projection (percent_used -> depletion ETA)
     if (( WEAR_TREND_ENABLED == 1 )); then
        win_wear=${WEAR_TREND_WINDOW_DAYS:-90}
        cutoff_wear=$(date -d "-${win_wear} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
        if [[ -f "$SMART_ATTR_HISTORY_FILE" ]]; then
            declare -A _WEAR_SAMPLE_VALUE _WEAR_SAMPLE_EPOCH _WEAR_DEVICE_SEEN _WEAR_SEQUENCE
            declare -g -A NVME_WEAR_DAYS_LEFT NVME_WEAR_RATE NVME_WEAR_CONFIDENCE
            NVME_WEAR_DAYS_LEFT=()
            NVME_WEAR_RATE=()
            NVME_WEAR_CONFIDENCE=()
            while read -r dt stored_key rest; do
                dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
                [[ "$dt" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
                [[ -z "$dev" || "$dt" < "$cutoff_wear" ]] && continue
                [[ "$dev" != /dev/nvme* ]] && continue
                pu=$(history_field_value "$rest" nvme_percent_used 2>/dev/null || true)
                [[ "$pu" =~ ^[0-9]+$ ]] || continue
                local wear_sample_key="$dev|$dt" wear_epoch
                wear_epoch=$(history_record_epoch "$dt" "$rest" 2>/dev/null || true)
                [[ "$wear_epoch" =~ ^[0-9]+$ ]] || continue
                _WEAR_SAMPLE_VALUE[$wear_sample_key]="$pu"
                _WEAR_SAMPLE_EPOCH[$wear_sample_key]="$wear_epoch"
                _WEAR_DEVICE_SEEN[$dev]=1
            done < <(tail -n 50000 "$SMART_ATTR_HISTORY_FILE" 2>/dev/null || cat "$SMART_ATTR_HISTORY_FILE")

            local wear_sample
            for wear_sample in "${!_WEAR_SAMPLE_VALUE[@]}"; do
                dev="${wear_sample%|*}"
                _WEAR_SEQUENCE[$dev]="${_WEAR_SEQUENCE[$dev]:-}${_WEAR_SAMPLE_EPOCH[$wear_sample]} ${_WEAR_SAMPLE_VALUE[$wear_sample]}"$'\n'
            done

            for dev in "${!_WEAR_DEVICE_SEEN[@]}"; do
                local wear_first_epoch=0 wear_last_epoch=0 wear_previous_epoch=0
                local wear_first_value="" wear_last_value="" wear_previous_value=""
                local wear_samples=0 wear_max_gap_seconds=0 wear_reset=0 wear_gap
                while read -r wear_epoch pu; do
                    [[ "$wear_epoch" =~ ^[0-9]+$ && "$pu" =~ ^[0-9]+$ ]] || continue
                    if (( wear_samples == 0 )); then
                        wear_first_epoch=$wear_epoch
                        wear_first_value=$pu
                    else
                        wear_gap=$(( wear_epoch - wear_previous_epoch ))
                        (( wear_gap > wear_max_gap_seconds )) && wear_max_gap_seconds=$wear_gap
                        (( pu < wear_previous_value )) && wear_reset=1
                    fi
                    wear_last_epoch=$wear_epoch
                    wear_last_value=$pu
                    wear_previous_epoch=$wear_epoch
                    wear_previous_value=$pu
                    ((wear_samples++)) || true
                done < <(printf '%s' "${_WEAR_SEQUENCE[$dev]:-}" | sort -n -k1,1)

                (( wear_samples > 0 )) || continue
                fv=$wear_first_value
                lv=$wear_last_value
                span_days=$(awk -v first="$wear_first_epoch" -v last="$wear_last_epoch" \
                    'BEGIN { printf "%.3f", (last-first)/86400.0 }')
                local wear_latest_age wear_max_gap_days wear_confidence
                wear_latest_age=$(awk -v now="$RUN_EPOCH" -v last="$wear_last_epoch" \
                    'BEGIN { age=(now-last)/86400.0; if(age<0) age=0; printf "%.3f", age }')
                wear_max_gap_days=$(awk -v gap="$wear_max_gap_seconds" \
                    'BEGIN { printf "%.3f", gap/86400.0 }')
                wear_confidence=$(forecast_confidence \
                    "$wear_samples" "$span_days" "$wear_latest_age" "$wear_max_gap_days")
                if (( wear_reset == 1 )); then
                    wear_confidence="RESET"
                fi
                NVME_WEAR_CONFIDENCE[$dev]="$wear_confidence"

                if (( wear_reset == 1 )); then
                    NVME_WEAR_RATE[$dev]="0"
                    NVME_WEAR_DAYS_LEFT[$dev]="INF"
                    continue
                fi
                growth=$(( lv - fv ))
                if (( growth > 0 )) &&
                   awk -v span="$span_days" 'BEGIN { exit !(span > 0) }'
                then
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
                    local wear_confidence="${NVME_WEAR_CONFIDENCE[$dev]:-INSUFFICIENT}"
                    if [[ "$dl" =~ ^[0-9]+$ ]] && forecast_confidence_is_actionable "$wear_confidence"; then
                        if (( crit_thr>0 && dl <= crit_thr )); then
                            record_alert critical "NVMe Wear Projection" "Disk $dev projected depletion ${dl}d <= ${crit_thr}d (rate ${rate}%/d; confidence=$wear_confidence)"
                        elif (( warn_thr>0 && dl <= warn_thr )); then
                            record_alert warning "NVMe Wear Projection" "Disk $dev projected depletion ${dl}d <= ${warn_thr}d (rate ${rate}%/d; confidence=$wear_confidence)"
                        fi
                    fi
                done
            fi
        fi
     fi
}

# === Helper Function ===
# Check btrfs snapshot counts against thresholds.
check_btrfs_snapshots() {
    local -a mountpoints=()
    local mp
    mapfile -t mountpoints < <(mount | awk '$5=="btrfs" {print $3}')
    for mp in "${mountpoints[@]}"; do
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

# Append a fixed, inclusive line range without reading lines appended after the
# metadata snapshot. Called directly so write failures propagate to the cursor
# builder instead of being hidden by command substitution.
append_syslog_line_range() {
    local source="$1" start_line="$2" end_line="$3" target="$4"

    (( start_line <= end_line )) || return 0
    sed -n "${start_line},${end_line}p" "$source" >> "$target"
}

# Build the exact syslog chunk for this run and stage the cursor metadata that
# may be committed only after the I/O history update succeeds.
build_new_syslog_chunk() {
    local source="$IO_ERROR_LOG_FILE"
    local metadata current_device current_inode current_size current_lines current_anchor="-"
    local schema="" previous_path="" previous_device="" previous_inode=""
    local previous_lines=0 previous_size=0 previous_anchor="-" start_line reason
    local rotated rotated_metadata rotated_device rotated_inode rotated_size rotated_lines
    local recovered=0 anchor_matches=0 observed_anchor=""
    local verify_metadata verify_device verify_inode verify_size chunk_lines

    SYSLOG_CURSOR_READY=0
    SYSLOG_CHUNK_FILE="$RUN_DIR/syslog.incremental.log"
    : > "$SYSLOG_CHUNK_FILE" || return 1

    if [[ ! -r "$source" ]]; then
        dmesg 2>/dev/null | tail -n "$SYSLOG_CURSOR_ROTATION_LOOKBACK_LINES" > "$SYSLOG_CHUNK_FILE" || true
        log "SYSLOG" "WARN" \
            "$source is unavailable; using a non-cursor dmesg fallback"
        return 0
    fi

    metadata=$(stat -c '%d %i %s' -- "$source" 2>/dev/null) || return 1
    read -r current_device current_inode current_size <<< "$metadata"
    current_lines=$(wc -l < "$source" 2>/dev/null || echo 0)
    current_lines=${current_lines//[[:space:]]/}
    [[ "$current_device" =~ ^[0-9]+$ && "$current_inode" =~ ^[0-9]+$ ]] || return 1
    [[ "$current_size" =~ ^[0-9]+$ && "$current_lines" =~ ^[0-9]+$ ]] || return 1
    if (( current_lines > 0 )); then
        current_anchor=$(sed -n "${current_lines}p" "$source" 2>/dev/null | sha1sum | awk '{print $1}')
        [[ -n "$current_anchor" ]] || current_anchor="-"
    fi

    if [[ -s "$SYSLOG_CURSOR_STATE_FILE" ]]; then
        read -r schema previous_path previous_device previous_inode previous_lines previous_size previous_anchor \
            < "$SYSLOG_CURSOR_STATE_FILE" || true
    fi
    if [[ "$schema" != "v2" || ! "$previous_device" =~ ^[0-9]+$ ||
          ! "$previous_inode" =~ ^[0-9]+$ || ! "$previous_lines" =~ ^[0-9]+$ ||
          ! "$previous_size" =~ ^[0-9]+$ || -z "$previous_anchor" ]]; then
        schema=""
        previous_lines=0
        previous_size=0
        previous_anchor="-"
    fi

    if [[ -n "$schema" && "$previous_path" == "$source" &&
          "$previous_device" == "$current_device" && "$previous_inode" == "$current_inode" &&
          "$current_lines" -ge "$previous_lines" && "$current_size" -ge "$previous_size" ]]; then
        if (( previous_lines == 0 )) || [[ "$previous_anchor" == "-" ]]; then
            anchor_matches=1
        else
            observed_anchor=$(sed -n "${previous_lines}p" "$source" 2>/dev/null | sha1sum | awk '{print $1}')
            [[ "$observed_anchor" == "$previous_anchor" ]] && anchor_matches=1
        fi
    fi

    if [[ -z "$schema" ]]; then
        if (( current_lines > SYSLOG_CURSOR_STARTUP_LOOKBACK_LINES )); then
            start_line=$(( current_lines - SYSLOG_CURSOR_STARTUP_LOOKBACK_LINES + 1 ))
        else
            start_line=1
        fi
        append_syslog_line_range "$source" "$start_line" "$current_lines" "$SYSLOG_CHUNK_FILE" || return 1
        reason="initial lookback"
    elif (( anchor_matches == 1 )); then
        start_line=$(( previous_lines + 1 ))
        append_syslog_line_range "$source" "$start_line" "$current_lines" "$SYSLOG_CHUNK_FILE" || return 1
        reason="cursor continuation"
    else
        for rotated in "${source}.1" "${source}.0"; do
            [[ -r "$rotated" ]] || continue
            rotated_metadata=$(stat -c '%d %i %s' -- "$rotated" 2>/dev/null) || continue
            read -r rotated_device rotated_inode rotated_size <<< "$rotated_metadata"
            [[ "$rotated_device" == "$previous_device" && "$rotated_inode" == "$previous_inode" ]] || continue
            rotated_lines=$(wc -l < "$rotated" 2>/dev/null || echo 0)
            rotated_lines=${rotated_lines//[[:space:]]/}
            [[ "$rotated_lines" =~ ^[0-9]+$ ]] || continue
            if (( previous_lines > 0 )) && [[ "$previous_anchor" != "-" ]]; then
                observed_anchor=$(sed -n "${previous_lines}p" "$rotated" 2>/dev/null | sha1sum | awk '{print $1}')
                [[ "$observed_anchor" == "$previous_anchor" ]] || continue
            fi
            append_syslog_line_range "$rotated" "$(( previous_lines + 1 ))" "$rotated_lines" "$SYSLOG_CHUNK_FILE" || return 1
            append_syslog_line_range "$source" 1 "$current_lines" "$SYSLOG_CHUNK_FILE" || return 1
            recovered=1
            reason="rotation recovery via ${rotated}"
            break
        done

        if (( recovered == 0 )); then
            if (( current_lines > SYSLOG_CURSOR_ROTATION_LOOKBACK_LINES )); then
                start_line=$(( current_lines - SYSLOG_CURSOR_ROTATION_LOOKBACK_LINES + 1 ))
            else
                start_line=1
            fi
            append_syslog_line_range "$source" "$start_line" "$current_lines" "$SYSLOG_CHUNK_FILE" || return 1
            reason="rotation/truncation fallback"
            log "SYSLOG" "WARN" \
                "Previous syslog inode was unavailable; scanning the last ${SYSLOG_CURSOR_ROTATION_LOOKBACK_LINES} line(s)"
        fi
    fi

    # Do not advance a cursor captured across a concurrent rotation. The chunk
    # remains safe to process because event hashes are de-duplicated; the next
    # run will retry from the last committed cursor.
    verify_metadata=$(stat -c '%d %i %s' -- "$source" 2>/dev/null || true)
    read -r verify_device verify_inode verify_size <<< "$verify_metadata"
    if [[ "$verify_device" != "$current_device" || "$verify_inode" != "$current_inode" ]]; then
        log "SYSLOG" "WARN" "Syslog rotated while its incremental chunk was being built; cursor advancement deferred"
        return 0
    fi

    SYSLOG_CURSOR_PENDING_PATH="$source"
    SYSLOG_CURSOR_PENDING_DEVICE="$current_device"
    SYSLOG_CURSOR_PENDING_INODE="$current_inode"
    SYSLOG_CURSOR_PENDING_LINES="$current_lines"
    SYSLOG_CURSOR_PENDING_SIZE="$current_size"
    SYSLOG_CURSOR_PENDING_ANCHOR="$current_anchor"
    SYSLOG_CURSOR_READY=1

    chunk_lines=$(wc -l < "$SYSLOG_CHUNK_FILE" 2>/dev/null || echo 0)
    chunk_lines=${chunk_lines//[[:space:]]/}
    log "SYSLOG" "INFO" \
        "Prepared ${chunk_lines:-0} new line(s) using ${reason}"
}

commit_syslog_cursor() {
    (( SYSLOG_CURSOR_READY == 1 )) || return 0
    atomic_write_text "$SYSLOG_CURSOR_STATE_FILE" \
        "v2 $SYSLOG_CURSOR_PENDING_PATH $SYSLOG_CURSOR_PENDING_DEVICE $SYSLOG_CURSOR_PENDING_INODE $SYSLOG_CURSOR_PENDING_LINES $SYSLOG_CURSOR_PENDING_SIZE $SYSLOG_CURSOR_PENDING_ANCHOR"$'\n'
}

syslog_timestamp_epoch() {
    local line="$1" now_epoch="$2"
    local timestamp year epoch

    timestamp=$(printf '%s\n' "$line" | awk '{print $1" "$2" "$3}')
    if [[ "$timestamp" =~ ^[A-Z][a-z]{2}\ [0-9]{1,2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        year=$(date '+%Y')
        epoch=$(date -d "$timestamp $year" +%s 2>/dev/null || echo "$now_epoch")
        if (( epoch > now_epoch + 86400 )); then
            epoch=$(date -d "$timestamp $(( year - 1 ))" +%s 2>/dev/null || echo "$now_epoch")
        fi
        printf '%s' "$epoch"
    else
        printf '%s' "$now_epoch"
    fi
}

# Scan only the new syslog chunk, count unique disk I/O events in the configured
# time window, then atomically advance history and cursor together.
scan_syslog_disk_errors() {
    (( IO_ERROR_MONITOR_ENABLED == 1 )) || { IO_ERROR_FREQ_SECTION=""; return 0; }
    local had_e=0
    case $- in *e*) had_e=1; set +e;; esac
    local window_sec=$(( IO_ERROR_WINDOW_MINUTES * 60 ))
    local now_epoch cutoff stored_key dev key new_hist history_committed=0
    local line tok dev_tokens ts epoch hash event_hash normalized_line
    now_epoch=$(date +%s)
    cutoff=$(( now_epoch - window_sec ))

    IO_ERROR_RAW_MAP=()
    IO_ERROR_UNIQUE_MAP=()
    declare -A HASH_SEEN NEW_IO_EVENT_MAP

    if ! build_new_syslog_chunk; then
        log "SYSLOG" "WARN" "Unable to build the incremental syslog chunk; cursor was not advanced"
        SYSLOG_CHUNK_FILE=""
    fi

    if [[ -f "$IO_ERROR_HISTORY_FILE" ]]; then
        while read -r ts stored_key hash; do
            dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
            [[ -z "$ts" || -z "$dev" || -z "$hash" || ! "$ts" =~ ^[0-9]+$ ]] && continue
            if (( ts >= cutoff )); then
                if [[ -z "${HASH_SEEN["$dev|$hash"]:-}" ]]; then
                    IO_ERROR_UNIQUE_MAP["$dev"]=$(( ${IO_ERROR_UNIQUE_MAP["$dev"]:-0} + 1 ))
                fi
                HASH_SEEN["$dev|$hash"]=$ts
            fi
        done < "$IO_ERROR_HISTORY_FILE"
    fi

    new_hist="$(state_temp_file "$IO_ERROR_HISTORY_FILE")" || new_hist=""
    if [[ -z "$new_hist" ]]; then
        log "SYSLOG" "WARN" "Unable to create I/O history staging file; cursor was not advanced"
    else
        for key in "${!HASH_SEEN[@]}"; do
            ts="${HASH_SEEN[$key]}"
            dev="${key%%|*}"
            hash="${key#*|}"
            printf '%s %s %s\n' "$ts" "$(persistent_device_key "$dev")" "$hash" >> "$new_hist"
        done

        if [[ -n "$SYSLOG_CHUNK_FILE" && -r "$SYSLOG_CHUNK_FILE" ]]; then
            while IFS= read -r line; do
                [[ "$line" == *"Script aborted"* || "$line" == *"Disk I/O Alert"* ]] && continue
                if ! grep -qiE 'I/O error|blk_update_request|end_request|failed command: (READ|WRITE)|hard resetting link|link is slow to respond|exception Emask' <<< "$line"; then
                    continue
                fi

                dev_tokens=$(printf '%s\n' "$line" | grep -oE 'sd[a-z]+|nvme[0-9]+n[0-9]+' 2>/dev/null | sort -u || true)
                [[ -n "$dev_tokens" ]] || continue
                epoch=$(syslog_timestamp_epoch "$line" "$now_epoch")
                [[ "$epoch" =~ ^[0-9]+$ ]] || epoch=$now_epoch
                (( epoch >= cutoff )) || continue

                normalized_line=$(
                    printf '%s' "$line" |
                        sed -E 's/^[A-Z][a-z]{2}[[:space:]]+[0-9]{1,2}[[:space:]]+[0-9:]{8}[[:space:]]+//'
                )
                hash=$(printf '%s' "$normalized_line" | sha1sum | awk '{print $1}')

                while IFS= read -r tok; do
                    [[ -n "$tok" ]] || continue
                    dev="/dev/$tok"
                    IO_ERROR_RAW_MAP["$dev"]=$(( ${IO_ERROR_RAW_MAP["$dev"]:-0} + 1 ))
                    event_hash="$hash"
                    if (( IO_ERROR_DEDUP_ENABLED == 0 )); then
                        event_hash="${hash}_${epoch}_${IO_ERROR_RAW_MAP[$dev]}"
                    fi
                    if (( IO_ERROR_DEDUP_ENABLED == 1 )) && [[ -n "${HASH_SEEN["$dev|$event_hash"]:-}" ]]; then
                        continue
                    fi
                    if [[ -z "${HASH_SEEN["$dev|$event_hash"]:-}" ]]; then
                        IO_ERROR_UNIQUE_MAP["$dev"]=$(( ${IO_ERROR_UNIQUE_MAP["$dev"]:-0} + 1 ))
                    fi
                    HASH_SEEN["$dev|$event_hash"]=$epoch
                    NEW_IO_EVENT_MAP["$dev"]=1
                    printf '%s %s %s\n' "$epoch" "$(persistent_device_key "$dev")" "$event_hash" >> "$new_hist"
                done <<< "$dev_tokens"
            done < "$SYSLOG_CHUNK_FILE"
        fi

        if atomic_commit "$new_hist" "$IO_ERROR_HISTORY_FILE"; then
            history_committed=1
        fi
    fi

    if (( history_committed == 1 )); then
        commit_syslog_cursor || log "SYSLOG" "WARN" "I/O history was saved but the syslog cursor could not be committed"
    fi

    local dev _io_rank=() lines=""
    for dev in "${!NEW_IO_EVENT_MAP[@]}"; do
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
        base_dev="$(base_device "$dev")"
        st="${SMART_STATE[$dev]:-${SMART_STATE[$base_dev]:-OK}}"
        sm_raw="$(risk_score_for_device "$base_dev" "$st" "${SMART_MSGS[$dev]:-${SMART_MSGS[$base_dev]:-}}")"; [[ "$sm_raw" =~ ^[0-9]+$ ]] || sm_raw=0
        sm_norm=$(( sm_raw > 100 ? 100 : sm_raw ))
                # Apply burst boost if present for this device/base
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
                cap_norm=$(awk -v u="$usep" -v w="$warn_t" -v c="$crit_t" 'BEGIN{ x=u-w; d=c-w; if(d<=0){print 0}else{ if(x<0) x=0; if(x>d) x=d; printf "%d", int((x*100)/d) } }')
            fi
        fi
        local w_cap=20; local w_smart=60; local w_err=20; local total=$(( w_cap + w_smart + w_err )); local comp
        comp=$(awk -v c="$cap_norm" -v s="$sm_norm" -v e="$err_norm" -v wc="$w_cap" -v ws="$w_smart" -v we="$w_err" -v t="$total" 'BEGIN{ printf "%d", int((wc*c + ws*s + we*e)/t) }')
        _io_rank+=("$comp"$'\t'"$(basename "$dev")"$'\t'"$raw_count"$'\t'"$uniq_count"$'\t'"${mark}")
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

# === Notification Builder ===
severity_rank() { case "$1" in CRITICAL) echo 2;; WARNING) echo 1;; *) echo 0;; esac; }
status_word()   { case "$1" in 2) echo "CRITICAL";; 1) echo "WARNING";; *) echo "OK";; esac; }
map_emoji()     { case "$1" in 2) printf "🔴";; 1) printf "🟡";; *) printf "🟢";; esac; }

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
    local pflag="${PARITY_VALID_FLAG:-}"
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
            btrfs_df_cached "$p"
            prof_data="${BTRFS_DF_CACHE_DATA[$p]:-UNKNOWN}"
            prof_meta="${BTRFS_DF_CACHE_META[$p]:-UNKNOWN}"
            prof_data=$(printf '%s' "$prof_data" | awk -F':' '{print $1}')
            prof_meta=$(printf '%s' "$prof_meta" | awk -F':' '{print $1}')
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
    local -a disk_capacity_records=()
    for d in "${arr[@]}"; do
        local sz u pct mount disk_name
        read -r sz u pct mount < <(df -B1 --output=size,used,pcent,target "$d" 2>/dev/null | tail -n1) || continue
        disk_name=$(basename "$d")
        [[ "$sz" =~ ^[0-9]+$ && "$u" =~ ^[0-9]+$ ]] || continue
        disk_capacity_records+=("$today $disk_name used=$u size=$sz captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION")
    done
    atomic_replace_daily_history \
        "$DISK_CAP_HISTORY_FILE" "$today" "${disk_capacity_records[@]}" ||
        log_warn "Unable to atomically update per-disk capacity history"
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
                        atomic_write_text "$STORAGE_DISCREPANCY_STATE_FILE" \
                            "${streak} ${diff}"$'\n' || true
                        if (( streak >= ${STORAGE_DISCREPANCY_SUSTAIN_RUNS:-2} )); then
                            record_alert warning "Storage Validation" "Storage discrepancy diff=${diff}% (array ${ARRAY_PERCENT:-0}% vs /mnt/user ${user_pct_calc}%) — investigate share settings (Cache, Include/Exclude), mover status, recent deletions."
                        fi
                    fi
                else
                    # Reset streak when below threshold
                    atomic_write_text "$STORAGE_DISCREPANCY_STATE_FILE" $'0 0\n' || true
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
            local disk_ref mnt_ref canonical_action="" canonical_title="" finding_id
            disk_ref=$(echo "$x" | grep -o '/dev/[a-zA-Z0-9]*' | head -n1 || true)
            mnt_ref=$(echo "$x" | grep -o '/mnt/[a-zA-Z0-9_-]*' | head -n1 || true)
            for finding_id in "${FINDING_IDS[@]}"; do
                if [[ "${FINDING_ALERT_TEXT[$finding_id]:-}" == "$x" ]]; then
                    canonical_action="${FINDING_ACTION[$finding_id]:-}"
                    canonical_title="${FINDING_TITLE[$finding_id]:-Finding}"
                    break
                fi
            done
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
                            if [[ -z "${FR_EVENTS[$bdev]+set}" ]]; then FR_EVENTS["$bdev"]=""; fi
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
                *)
                    if [[ -n "$canonical_action" ]]; then
                        local fallback_target="${display_friendly:-${mnt_ref:-$canonical_title}}"
                        rec+="- ${fallback_target}${model_suffix}: ${canonical_action}\n"
                        [[ -n "$bdev" ]] && SEEN_REC_DEVICES["$bdev"]=1
                    fi
                    ;;
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
            sm_raw="$(risk_score_for_device "$dev" "$st" "${SMART_MSGS[$dev]:-}")"
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
            rank_lines+=("$comp"$'\t'"$dev"$'\t'"$base")
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
            forecast_confidence_is_actionable \
                "${NVME_WEAR_CONFIDENCE[$dev]:-INSUFFICIENT}" || continue
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
            sm_raw="$(risk_score_for_device "$dev" "$st" "${SMART_MSGS[$dev]:-}")"; [[ "$sm_raw" =~ ^[0-9]+$ ]] || sm_raw=0
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
                _wear_rank+=("$comp"$'\t'"${base}${model_suffix}"$'\t'"CRIT"$'\t'"${dl}"$'\t'"${crit_thr}"$'\t'"${rate}")
                guid_added=1
            elif (( warn_thr>0 && dl <= warn_thr )); then
                _wear_rank+=("$comp"$'\t'"${base}${model_suffix}"$'\t'"WARN"$'\t'"${dl}"$'\t'"${warn_thr}"$'\t'"${rate}")
                guid_added=1
            fi
        done
        if (( ${#_wear_rank[@]} > 0 )); then
            local sorted_w
            sorted_w=$(printf "%s\n" "${_wear_rank[@]}" | sort -nr -k1,1)
            while read -r _ln; do
                local _ltab
                _ltab=$(printf "%s" "$_ln" | sed -E 's/\\t/\t/g')
                IFS=$'\t' read -r comp_score tag sev dl thr rate <<< "$_ltab"
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
                forecast_confidence_is_actionable \
                    "${NVME_WEAR_CONFIDENCE[$dev]:-INSUFFICIENT}" || continue
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
                sm_raw="$(risk_score_for_device "$dev" "$st" "${SMART_MSGS[$dev]:-}")"; [[ "$sm_raw" =~ ^[0-9]+$ ]] || sm_raw=0
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
                _hw_rank+=("$comp"$'\t'"${tag}${model_suffix}"$'\t'"$w")
            fi
        done
        if (( ${#_hw_rank[@]} > 0 )); then
            local sorted_hw
            sorted_hw=$(printf "%s\n" "${_hw_rank[@]}" | sort -nr -k1,1)
            while read -r _ln; do
                local _ltab
                _ltab=$(printf "%s" "$_ln" | sed -E 's/\\t/\t/g')
                IFS=$'\t' read -r comp_score tag ww <<< "$_ltab"
                if awk -v ww="$ww" -v c="$WRITER_WEEKLY_CRIT_PCT" 'BEGIN{exit (ww>=c)?0:1}'; then
                    HEALTH_ALERTS_SECTION+="\n - ${tag}: Extremely heavy write rate ~$(awk -v w=\""$ww"\" 'BEGIN{printf "%.2f", w}')% cap/week; redistribute workloads, review logging, expect accelerated wear. (priority ${comp_score})"
                else
                    HEALTH_ALERTS_SECTION+="\n - ${tag}: Heavy write rate ~$(awk -v w=\""$ww"\" 'BEGIN{printf "%.2f", w}')% cap/week; monitor and consider moving high-churn data to lower-tier media. (priority ${comp_score})"
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
            sm_raw="$(risk_score_for_device "$dev" "$st" "${SMART_MSGS[$dev]:-}")"; [[ "$sm_raw" =~ ^[0-9]+$ ]] || sm_raw=0
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
            _lt_rank+=("$comp"$'\t'"${base_short}${model_suffix}"$'\t'"${recommend_date}"$'\t'"${age_days}"$'\t'"${accel_days}")
        done
        if (( ${#_lt_rank[@]} > 0 )); then
            local sorted_lt
            sorted_lt=$(printf "%s\n" "${_lt_rank[@]}" | sort -nr -k1,1)
            while read -r _ln; do
                local _ltab
                _ltab=$(printf "%s" "$_ln" | sed -E 's/\\t/\t/g')
                IFS=$'\t' read -r comp_score tag rec_date age_days accel_days <<< "$_ltab"
                HEALTH_ALERTS_SECTION+="\n - ${tag}: Accelerate next long SMART test to ${rec_date} (risk spike ${age_days}d ago; interval ~${accel_days}d vs base ${base_days}d). (priority ${comp_score})"
            done <<< "$sorted_lt"
        fi
    fi
}

# === Main Function ===
# Build non-critical trend / advisory analytics section
build_trend_section() {
    # Minimal ERR trap to log which sub-block failed while compiling trends
    trap 'log_crit "Trend sub-block failed [${CURRENT_TREND_BLOCK:-unknown}] at line ${LINENO}: ${BASH_COMMAND}"' ERR
    CURRENT_TREND_BLOCK="init"
    declare -g TEMP_FORECAST_CONFIDENCE_LINE
    TEMP_FORECAST_CONFIDENCE_LINE=""
    # Temperature Evolution subsection
    CURRENT_TREND_BLOCK="temperature"
    if [[ -f "${TEMP_HISTORY_FILE}" ]]; then
        local temp_win=${TEMP_TREND_WINDOW_DAYS:-14} stored_key rest dt
        local now_ts
        now_ts=$(date +%s)
        local cut_ts=$(( now_ts - temp_win*86400 ))
        declare -A TT_MIN TT_MAX TT_SUM TT_CNT TT_FIRST TT_LAST TT_FIRST_TS TT_LAST_TS TT_MAX_GAP_SECONDS
        declare -A TEMP_SAMPLE_VALUE TEMP_SAMPLE_EPOCH TEMP_DEVICE_SEEN TEMP_SEQUENCE
        TEMP_RATE_CONFIDENCE=()
        while read -r dt stored_key rest; do
            [[ "$dt" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
            local dev tmp ts temp_sample_key
            dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
            [[ -n "$dev" ]] || continue
            tmp=$(history_field_value "$rest" temp 2>/dev/null || true)
            if [[ -z "$tmp" ]]; then
                tmp="${rest%% *}"
                tmp="${tmp#temp=}"
            fi
            [[ "$tmp" =~ ^[0-9]+$ ]] || continue
            ts=$(history_record_epoch "$dt" "$rest" 2>/dev/null || true)
            [[ "$ts" =~ ^[0-9]+$ ]] || continue
            (( ts >= cut_ts )) || continue
            temp_sample_key="$dev|$dt"
            TEMP_SAMPLE_VALUE[$temp_sample_key]="$tmp"
            TEMP_SAMPLE_EPOCH[$temp_sample_key]="$ts"
            TEMP_DEVICE_SEEN[$dev]=1
        done < "${TEMP_HISTORY_FILE}"

        local temp_sample
        for temp_sample in "${!TEMP_SAMPLE_VALUE[@]}"; do
            local temp_dev="${temp_sample%|*}"
            TEMP_SEQUENCE[$temp_dev]="${TEMP_SEQUENCE[$temp_dev]:-}${TEMP_SAMPLE_EPOCH[$temp_sample]} ${TEMP_SAMPLE_VALUE[$temp_sample]}"$'\n'
        done

        local temp_dev
        for temp_dev in "${!TEMP_DEVICE_SEEN[@]}"; do
            local previous_ts=0 max_gap_seconds=0 gap_seconds=0 sample_temp sample_ts
            while read -r sample_ts sample_temp; do
                [[ "$sample_ts" =~ ^[0-9]+$ && "$sample_temp" =~ ^[0-9]+$ ]] || continue
                if [[ -z "${TT_FIRST[$temp_dev]:-}" ]]; then
                    TT_FIRST[$temp_dev]="$sample_temp"
                    TT_FIRST_TS[$temp_dev]="$sample_ts"
                elif (( previous_ts > 0 )); then
                    gap_seconds=$(( sample_ts - previous_ts ))
                    (( gap_seconds > max_gap_seconds )) && max_gap_seconds=$gap_seconds
                fi
                if [[ -z "${TT_MIN[$temp_dev]:-}" || ${TT_MIN[$temp_dev]} -gt $sample_temp ]]; then TT_MIN[$temp_dev]="$sample_temp"; fi
                if [[ -z "${TT_MAX[$temp_dev]:-}" || ${TT_MAX[$temp_dev]} -lt $sample_temp ]]; then TT_MAX[$temp_dev]="$sample_temp"; fi
                TT_SUM[$temp_dev]=$(( ${TT_SUM[$temp_dev]:-0} + sample_temp ))
                TT_CNT[$temp_dev]=$(( ${TT_CNT[$temp_dev]:-0} + 1 ))
                TT_LAST[$temp_dev]="$sample_temp"
                TT_LAST_TS[$temp_dev]="$sample_ts"
                previous_ts=$sample_ts
            done < <(printf '%s' "${TEMP_SEQUENCE[$temp_dev]:-}" | sort -n -k1,1)
            TT_MAX_GAP_SECONDS[$temp_dev]="$max_gap_seconds"
        done
        local tdev
        for tdev in "${!TT_CNT[@]}"; do
            local rise rate days
            if [[ -n "${TT_FIRST[$tdev]:-}" && -n "${TT_LAST[$tdev]:-}" ]]; then
                rise=$(( ${TT_LAST[$tdev]:-0} - ${TT_FIRST[$tdev]:-0} ))
            else
                rise=0
            fi
            rate="0.0"; days=0
            if [[ -n "${TT_FIRST_TS[$tdev]:-}" && -n "${TT_LAST_TS[$tdev]:-}" ]]; then
                local span
                span=$(( ${TT_LAST_TS[$tdev]:-0} - ${TT_FIRST_TS[$tdev]:-0} ))
                if (( span > 0 )); then
                    days=$(awk -v s="$span" 'BEGIN{printf "%.2f", s/86400.0}')
                    rate=$(awk -v r="$rise" -v d="$days" 'BEGIN{ if(d>0) printf "%.2f", r/d; else print "0.0" }')
                fi
            fi
            local temp_latest_age temp_max_gap_days temp_confidence
            temp_latest_age=$(awk -v now="$RUN_EPOCH" -v last="${TT_LAST_TS[$tdev]:-0}" \
                'BEGIN { if(last<=0) print 999999; else { age=(now-last)/86400.0; if(age<0) age=0; printf "%.3f", age } }')
            temp_max_gap_days=$(awk -v gap="${TT_MAX_GAP_SECONDS[$tdev]:-0}" \
                'BEGIN { printf "%.3f", gap/86400.0 }')
            temp_confidence=$(forecast_confidence \
                "${TT_CNT[$tdev]:-0}" "$days" "$temp_latest_age" "$temp_max_gap_days")
            TEMP_RATE_CONFIDENCE[$tdev]="$temp_confidence"
            if (( TEMP_RATE_ALERT_ENABLED == 1 )) && [[ -n "$rate" && "$days" != "0.00" ]] &&
               forecast_confidence_is_actionable "$temp_confidence"
            then
                if awk -v d="$days" -v min="$TEMP_RATE_MIN_SPAN_DAYS" \
                    'BEGIN { exit !(d >= min) }'
                then
                    if awk -v r="$rate" -v c="$TEMP_RATE_CRIT_C_PER_DAY" \
                        'BEGIN { exit !(r >= c) }'
                    then
                        record_alert critical "Temperature Rate" "Disk $tdev rising +${rise}C over ${days}d (~${rate}C/day; confidence=$temp_confidence)"
                    elif awk -v r="$rate" -v w="$TEMP_RATE_WARN_C_PER_DAY" \
                        'BEGIN { exit !(r >= w) }'
                    then
                        record_alert warning "Temperature Rate" "Disk $tdev rising +${rise}C over ${days}d (~${rate}C/day; confidence=$temp_confidence)"
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
                forecast_confidence_is_actionable \
                    "${TEMP_RATE_CONFIDENCE[$tdev]:-INSUFFICIENT}" || continue
                # Only include warn/crit
                if awk -v r="$rate" -v w="$TEMP_RATE_WARN_C_PER_DAY" \
                    'BEGIN { exit !(r >= w) }'
                then
                    # Normalize rate severity (0-100)
                    local rate_norm
                    if awk -v r="$rate" -v c="$TEMP_RATE_CRIT_C_PER_DAY" \
                        'BEGIN { exit !(r >= c) }'
                    then
                        rate_norm=100
                    else
                        rate_norm=$(awk -v r="$rate" -v w="$TEMP_RATE_WARN_C_PER_DAY" 'BEGIN{ if(w>0) printf "%d", int((r*65)/w); else print 0 }')
                    fi
                    # SMART + I/O error components
                    local st sm_raw sm_norm base_dev uniq err_norm
                    base_dev="$(base_device "$tdev")"
                    st="${SMART_STATE[$tdev]:-${SMART_STATE[$base_dev]:-OK}}"
                    sm_raw="$(risk_score_for_device "$base_dev" "$st" "${SMART_MSGS[$tdev]:-${SMART_MSGS[$base_dev]:-}}")"; [[ "$sm_raw" =~ ^[0-9]+$ ]] || sm_raw=0
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
                    _tr_rank+=("$comp"$'\t'"${tag}${model_suffix}"$'\t'"${rise}"$'\t'"${days}"$'\t'"${rate}")
                fi
            done
            if (( ${#_tr_rank[@]} > 0 )); then
                local sorted_tr
                sorted_tr=$(printf "%s\n" "${_tr_rank[@]}" | sort -nr -k1,1)
                while IFS=$'\t' read -r comp_score tag rise days rate; do
                    : # Structured Temperature Rate alert is rendered by build_health_alerts().
                done <<< "$sorted_tr"
            fi
        fi
        local -a temp_confidence_items=()
        for tdev in "${!TEMP_RATE_CONFIDENCE[@]}"; do
            case "${TEMP_RATE_CONFIDENCE[$tdev]:-INSUFFICIENT}" in
                HIGH|MEDIUM) ;;
                *) temp_confidence_items+=("$(basename "$tdev")=${TEMP_RATE_CONFIDENCE[$tdev]:-INSUFFICIENT}") ;;
            esac
        done
        if (( ${#temp_confidence_items[@]} > 0 )); then
            TEMP_FORECAST_CONFIDENCE_LINE="$(join_by ' | ' "${temp_confidence_items[@]}")"
        fi
    fi
    # Trend-derived early warnings (growth acceleration, thermal exposure, heavy writers, endurance)
    declare -g DL_SHRINK_LINE EARLY_ERR_LINE BTRFS_SUM_LINE SMART_GROWTH_LINE POH_GROWTH_LINE
    DL_SHRINK_LINE=""; EARLY_ERR_LINE=""; BTRFS_SUM_LINE=""; SMART_GROWTH_LINE=""; POH_GROWTH_LINE=""
    # SMART attribute growth trend computation
    CURRENT_TREND_BLOCK="smart-attr-trend"
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
                local stored_key
                while read -r dt stored_key rest; do
                    dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
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
                    (( hv_writer_flag )) && { codes+="HVW "; ((++score)); }
                    if [[ -n "$wear_delta" ]] && (( 10#${wear_delta%.*} >= 1 )); then
                        local current_wear="${CUR_ATTR["$disk|nvme_percent_used"]:-0}"
                        if [[ $current_wear =~ ^[0-9]+$ ]] && (( current_wear < NVME_PERCENT_USED_WARN )); then
                            codes+="W+${wear_delta}% "; ((++score))
                        fi
                    fi
                    (( unsafe_low )) && { codes+="US "; ((++score)); }
                    (( pcie_corr_low_flag )) && { codes+="PCIE "; ((++score)); }
                    (( media_growth_flag )) && { codes+="MEDIA "; ((++score)); }
                    (( therm_warn )) && { codes+="T1 "; ((++score)); }
                    (( therm_crit )) && { codes+="T2 "; ((++score)); }
                    if [[ -n "$warn_temp_delta" ]] && (( 10#${warn_temp_delta%.*} > 0 )); then codes+="WT+${warn_temp_delta}s "; ((++score)); fi
                    if [[ -n "$crit_temp_delta" ]] && (( 10#${crit_temp_delta%.*} > 0 )); then codes+="CT+${crit_temp_delta}s "; ((++score)); fi
                    # Avoid double expansion of possibly-unset AGE_CLASS under nounset
                    local ac="${AGE_CLASS[$disk]:-}"
                    if [[ -n "$ac" && "$ac" == "Near endurance" ]]; then codes+="NR "; ((++score)); fi
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
    CURRENT_TREND_BLOCK="endurance-trend"
    if (( ${POH_TREND_ENABLED:-0} == 1 || ${TBW_TREND_ENABLED:-0} == 1 )); then
        local win_end=${ENDURANCE_TREND_WINDOW_DAYS:-7}
        local cutoff_end
        cutoff_end=$(date -d "-${win_end} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
        # --- POH Aging Ranking ---
        if (( POH_TREND_ENABLED == 1 )) && [[ -f "$POH_HISTORY_FILE" ]]; then
            local poh_lines tmp_poh
            poh_lines=$(
                (tail -n 50000 "$POH_HISTORY_FILE" 2>/dev/null || true) |
                    awk -v c="$cutoff_end" '$1>=c'
            )
            if [[ -n "$poh_lines" ]]; then
                tmp_poh=$(mktemp) || { log_warn "mktemp failed; skipping POH trend block"; tmp_poh=""; }
                if [[ -n "$tmp_poh" ]]; then
                    printf "%s\n" "$poh_lines" | awk '{d=$2; for(i=3;i<=NF;i++){split($i,a,"="); if(a[1]=="poh") v=a[2]} if(d!="" && v!=""){print $1,d,v}}' > "$tmp_poh"
                declare -A poh_first_dt poh_first_v poh_last_dt poh_last_v
                local stored_key
                while read -r dt stored_key v; do
                    dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
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
            dl_lines=$(
                (tail -n 50000 "$TBW_DAYSLEFT_HISTORY_FILE" 2>/dev/null || true) |
                    awk -v c="$cutoff_end" '$1>=c'
            )
            if [[ -n "$dl_lines" ]]; then
                tmp_dl=$(mktemp) || { log_warn "mktemp failed; skipping TBW days-left trend block"; tmp_dl=""; }
                if [[ -n "$tmp_dl" ]]; then
                    printf "%s\n" "$dl_lines" | awk '{d=$2; for(i=3;i<=NF;i++){split($i,a,"="); if(a[1]=="days_left") v=a[2]} if(d!="" && v!=""){print $1,d,v}}' > "$tmp_dl"
                declare -A dl_first_dt dl_first_v dl_last_dt dl_last_v dl_seq
                local stored_key
                while read -r dt stored_key v; do
                    dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
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
                                    ((++cnt))
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
    CURRENT_TREND_BLOCK="fs-error-accel"
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
                local key mount delta rate_metric event dev stored_key
                key=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^key=/){sub(/key=/,"",$i); print $i; break}}}')
                mount=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^mount=/){sub(/mount=/,"",$i); print $i; break}}}')
                delta=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^delta=/){sub(/delta=/,"",$i); print $i; break}}}')
                rate_metric=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^rate_day=/){sub(/rate_day=/,"",$i); print $i; break}}}')
                event=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^event=/){sub(/event=/,"",$i); print $i; break}}}')
                stored_key=$(echo "$rest" | awk '{print $1}')
                dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
                [[ -z "$dev" || -z "$key" ]] && continue
                if [[ "$event" == "reset" ]]; then
                    unset "BSEQ[$dev|$key]"
                    [[ -n "$mount" ]] && unset "MSEQ[$mount|$key]"
                    continue
                fi
                [[ -z "$dev" || -z "$delta" || -z "$key" || -z "$rate_metric" ]] && continue
                [[ "$delta" =~ ^[0-9]+$ && "$rate_metric" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
                BSEQ["$dev|$key"]+="${dt}:${rate_metric} "
                [[ -n "$mount" ]] && MSEQ["$mount|$key"]+="${dt}:${rate_metric} "
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
                [[ "$dd" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
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
                [[ "$dd" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
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
                local key delta rate_metric event
                key=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^key=/){sub(/key=/,"",$i); print $i; break}}}')
                delta=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^delta=/){sub(/delta=/,"",$i); print $i; break}}}')
                rate_metric=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^rate_day=/){sub(/rate_day=/,"",$i); print $i; break}}}')
                event=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^event=/){sub(/event=/,"",$i); print $i; break}}}')
                if [[ "$event" == "reset" ]]; then
                    [[ -n "$key" ]] && unset "XSEQ[$key]"
                    continue
                fi
                [[ -z "$key" || -z "$delta" || -z "$rate_metric" ]] && continue
                [[ "$delta" =~ ^[0-9]+$ && "$rate_metric" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
                XSEQ["$key"]+="${dt}:${rate_metric} "
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
                [[ "$dd" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
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
    CURRENT_TREND_BLOCK="btrfs-cumulative"
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
                    local dev stored_key mount key delta
                    stored_key=$(echo "$rest" | awk '{print $1}')
                    dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
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
    CURRENT_TREND_BLOCK="trend-one-liners"
    {
        declare -a _TL=()
        _add_line() { local tag="$1" text="$2"; [[ -n "$text" ]] && _TL+=("${tag}: ${text}"); }
        # Capacity forecast
        CURRENT_TREND_BLOCK="TL: capacity-forecast"
        if [[ -n "${ARR_GROWTH_STR:-}" || -n "${POOL_GROWTH_STR:-}" || -n "${ARR_DAYS_TO_THRESHOLD:-}" || -n "${POOL_DAYS_TO_THRESHOLD:-}" ]]; then
            local _cf_a _cf_p _cf_suffix=""
            if (( ${ARR_HISTORY_COUNT:-0} < 2 )); then
                _cf_a="array history<2 samples"
            else
                _cf_a="array ${ARR_DAYS_TO_THRESHOLD:-N/A}d→${THRESHOLD}% (${ARR_GROWTH_STR:-N/A}/d; confidence=${ARR_FORECAST_CONFIDENCE:-INSUFFICIENT})"
            fi
            if (( ${POOL_HISTORY_COUNT:-0} < 2 )); then
                _cf_p="pools history<2 samples"
            else
                _cf_p="pools ${POOL_DAYS_TO_THRESHOLD:-N/A}d→${THRESHOLD}% (${POOL_GROWTH_STR:-N/A}/d; confidence=${POOL_FORECAST_CONFIDENCE:-INSUFFICIENT})"
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
        _add_line "TEMP-Q" "${TEMP_FORECAST_CONFIDENCE_LINE:-}"
        # Disk growth (top 5)
        CURRENT_TREND_BLOCK="TL: disk-growth"
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
                local _items_growth=() _items_shrink=()
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
                    _add_line "DISK↑" "$(join_by ' | ' "${_combined[@]}")"
                fi
            fi
        fi
        # Share growth (top N)
        CURRENT_TREND_BLOCK="TL: share-growth"
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
                    _add_line "SHARE↑" "$(join_by ' | ' "${_combined_share[@]}")"
                fi
            fi
        fi
        # NVMe/SATA SSD wear rate (TBW-derived percent/day)
        CURRENT_TREND_BLOCK="TL: wear-rate"
        if declare -p TBW_DAILY >/dev/null 2>&1; then
            local wear_items=()
            for dev in "${!TBW_DAILY[@]}"; do
                forecast_confidence_is_actionable \
                    "${TBW_FORECAST_CONFIDENCE[$dev]:-INSUFFICIENT}" || continue
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
                _add_line "WEAR" "$(join_by ' | ' "${wear_items[@]}")"
            fi
        fi
        # Maintenance: long SMART tests due soon
        CURRENT_TREND_BLOCK="TL: maintenance"
        if declare -p LONG_TEST_DUE_SOON &>/dev/null; then
            local _near=() _k _d
            for _k in "${!LONG_TEST_DUE_SOON[@]}"; do _d=${LONG_TEST_DUE_SOON[$_k]}; _near+=("$(basename "$_k")(${_d}d)"); done
            if (( ${#_near[@]} > 0 )); then _add_line "MTN" "${_near[*]}"; fi
        fi
        # TBW trend (forecast days-left) and heavy writers compact
        CURRENT_TREND_BLOCK="TL: tbw-trend"
        if (( ${TBW_TREND_ENABLED:-0} == 1 )) && declare -p TBW_DAYS_LEFT &>/dev/null; then
            local _tbw="" _writers=""
            for dev in "${!TBW_DAYS_LEFT[@]}"; do
                local dl=${TBW_DAYS_LEFT[$dev]} daily=${TBW_DAILY[$dev]:-0}
                local rate; rate=$(format_bytes_short "$daily")
                _tbw+="🔺$(basename "$dev") ${rate} → ${dl}d [${TBW_FORECAST_CONFIDENCE[$dev]:-INSUFFICIENT}] | "
            done
            _tbw=${_tbw%" | "}; [[ -n "$_tbw" ]] && _add_line "TBW" "$_tbw"
            if declare -p TBW_DAILY &>/dev/null; then
                local _hr=() ; for dev in "${!TBW_DAILY[@]}"; do
                    forecast_confidence_is_actionable \
                        "${TBW_FORECAST_CONFIDENCE[$dev]:-INSUFFICIENT}" || continue
                    local daily=${TBW_DAILY[$dev]:-0} cap_tb
                    cap_tb=$(get_device_capacity_tb "$dev")
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
                        local rate; rate=$(format_bytes_short "$daily")
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
        CURRENT_TREND_BLOCK="TL: wear-depletion"
        if (( ${WEAR_TREND_ENABLED:-0} == 1 )) && declare -p NVME_WEAR_DAYS_LEFT &>/dev/null; then
            local _wear_items=() dev
            for dev in "${!NVME_WEAR_DAYS_LEFT[@]}"; do
                local dl=${NVME_WEAR_DAYS_LEFT[$dev]} rate=${NVME_WEAR_RATE[$dev]:-0}
                local dl_fmt
                if [[ "$dl" == INF ]]; then dl_fmt="∞"; else dl_fmt="${dl}d"; fi
                _wear_items+=("$(basename "$dev") ${dl_fmt} r=$(printf '%.4f' "$rate")%/d [${NVME_WEAR_CONFIDENCE[$dev]:-INSUFFICIENT}]")
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
        CURRENT_TREND_BLOCK="TL: lifecycle"
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
        CURRENT_TREND_BLOCK="TL: POH-growth"
        if [[ -n "${POH_GROWTH_LINE:-}" ]]; then
            local _poh_items=() _ppart
            IFS=';' read -r -a _poh_parts <<< "${POH_GROWTH_LINE}" || true
            for _ppart in "${_poh_parts[@]}"; do
                _ppart=$(echo "$_ppart" | awk 'NF')
                [[ -z "$_ppart" ]] && continue
                if [[ "$_ppart" =~ -[0-9] ]]; then _poh_items+=("$_ppart"); else _poh_items+=("🔺$_ppart"); fi
            done
            [[ ${#_poh_items[@]} -gt 0 ]] && _add_line "POH↑" "$(join_by ' | ' "${_poh_items[@]}")"
        fi
        # POH Age : show top-N highest POH with class
        CURRENT_TREND_BLOCK="TL: POH-age"
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
        CURRENT_TREND_BLOCK="TL: SMART-growth"
        if [[ -n "${SMART_GROWTH_LINE:-}" ]]; then
            local _items=() _part
            IFS=';' read -r -a _parts <<< "${SMART_GROWTH_LINE}" || true
            for _part in "${_parts[@]}"; do
                _part=$(echo "$_part" | awk 'NF')
                [[ -z "$_part" ]] && continue
                if [[ "$_part" =~ -[0-9] ]]; then _items+=("$_part"); else _items+=("🔺$_part"); fi
            done
            [[ ${#_items[@]} -gt 0 ]] && _add_line "SMART↑" "$(join_by ' | ' "${_items[@]}")"
        fi
        CURRENT_TREND_BLOCK="TL: DL-shrink"
        if [[ -n "${DL_SHRINK_LINE:-}" ]]; then
            local _dl_items=() _dpart
            IFS=';' read -r -a _dl_parts <<< "${DL_SHRINK_LINE}" || true
            for _dpart in "${_dl_parts[@]}"; do
                _dpart=$(echo "$_dpart" | awk 'NF')
                [[ -z "$_dpart" ]] && continue
                if [[ "$_dpart" =~ -[0-9] ]]; then _dl_items+=("$_dpart"); else _dl_items+=("🔺$_dpart"); fi
            done
            [[ ${#_dl_items[@]} -gt 0 ]] && _add_line "DL🔻" "$(join_by ' | ' "${_dl_items[@]}")"
        fi
        CURRENT_TREND_BLOCK="TL: early-err"
        if [[ -n "${EARLY_ERR_LINE:-}" ]]; then
            local _err_items=() _epart
            IFS=';' read -r -a _err_parts <<< "${EARLY_ERR_LINE}" || true
            for _epart in "${_err_parts[@]}"; do
                _epart=$(echo "$_epart" | awk 'NF')
                [[ -z "$_epart" ]] && continue
                if [[ "$_epart" =~ -[0-9] ]]; then _err_items+=("$_epart"); else _err_items+=("🔺$_epart"); fi
            done
            [[ ${#_err_items[@]} -gt 0 ]] && _add_line "ERR↑" "$(join_by ' | ' "${_err_items[@]}")"
        fi
        CURRENT_TREND_BLOCK="TL: btrfs-sum"
        if [[ -n "${BTRFS_SUM_LINE:-}" ]]; then
            local _b_items=() _bpart
            IFS=';' read -r -a _b_parts <<< "${BTRFS_SUM_LINE}" || true
            for _bpart in "${_b_parts[@]}"; do
                _bpart=$(echo "$_bpart" | awk 'NF')
                [[ -z "$_bpart" ]] && continue
                _b_items+=("🔺$_bpart")
            done
            [[ ${#_b_items[@]} -gt 0 ]] && _add_line "BTRFSΣ" "$(join_by ' | ' "${_b_items[@]}")"
        fi
        # SATA link instability (events + streak), also raises alerts here
        CURRENT_TREND_BLOCK="TL: sata-link"
        if (( ${SATA_LINK_INSTABILITY_ENABLED:-0} == 1 )) && [[ -f "${SATA_LINK_HISTORY_FILE}" ]]; then
            local _win_sat=${SATA_LINK_INSTABILITY_WINDOW_DAYS:-14}
            local _cut_sat
            _cut_sat=$(date -d "-${_win_sat} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
            local _lines_sat
            _lines_sat=$(tail -n 20000 "${SATA_LINK_HISTORY_FILE}" 2>/dev/null || true)
            if [[ -n "$_lines_sat" ]]; then
                declare -A _DEV_DATES _DEV_LAST_MAX _DEV_LAST_CURR
                local stored_key
                while read -r dt stored_key rest; do
                    dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
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
    # Clear local trap before returning
    trap - ERR
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
    local deferred_smart_count=${#SMART_DEFERRED[@]}
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
    add_line "SMART deferred (standby)" "$deferred_smart_count"
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
        local score computed_score
        computed_score="$(risk_score_for_device "$dev" "$st" "$msg")"
        if [[ -n "${SMART_DEFERRED[$dev]:-}" && "${PREVIOUS_RISK[$dev]:-}" =~ ^[0-9]+$ ]]; then
            score="${PREVIOUS_RISK[$dev]}"
            (( computed_score > score )) && score="$computed_score"
        else
            score="$computed_score"
        fi

        local poh=0 percent_used=0 life_remain=0
        if [[ $dev == /dev/nvme* ]]; then
            percent_used=${CUR_ATTR["$dev|nvme_percent_used"]:-0}
            poh=${CUR_ATTR["$dev|poh"]:-0}
            if [[ "$percent_used" =~ ^[0-9]+$ ]] && (( percent_used >= 90 )); then
                AGE_CLASS[$dev]="Near endurance"
            fi
        else
            poh=${CUR_ATTR["$dev|poh"]:-0}
            life_remain=${CUR_ATTR["$dev|life_remain"]:-0}
            if [[ "$life_remain" =~ ^[0-9]+$ ]] &&
               (( life_remain > 0 && life_remain <= 10 ))
            then
                AGE_CLASS[$dev]="Near endurance"
            fi
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
    tmp="$(state_temp_file "$RISK_TIER_HISTORY_FILE")" || {
        log_warn "Unable to create risk-tier history temporary file"
        return 0
    }
    if [[ -f "$RISK_TIER_HISTORY_FILE" ]]; then
        awk -v d="$today" '$1!=d{print}' "$RISK_TIER_HISTORY_FILE" > "$tmp" || true
    fi
    local repl_csv mon_csv
    if declare -p REPLACE_LIST &>/dev/null && (( ${#REPLACE_LIST[@]} > 0 )); then
        local _r=() d; for d in "${REPLACE_LIST[@]}"; do _r+=("$(basename "$d")"); done; repl_csv="$(join_by ',' "${_r[@]}")"
    else
        repl_csv=""
    fi
    if declare -p MONITOR_LIST &>/dev/null && (( ${#MONITOR_LIST[@]} > 0 )); then
        local _m=() d; for d in "${MONITOR_LIST[@]}"; do _m+=("$(basename "$d")"); done; mon_csv="$(join_by ',' "${_m[@]}")"
    else
        mon_csv=""
    fi
    echo "$today critical=$crit warning=$warn replace=$replace_cnt monitor=$monitor_cnt healthy=$healthy_cnt REPLACE_DEVICES=${repl_csv} MONITOR_DEVICES=${mon_csv} captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION" >> "$tmp"
    atomic_commit "$tmp" "$RISK_TIER_HISTORY_FILE" || true
    # Persist per-disk risk scores history (overwrite today's entries for each disk)
    if declare -p RISK_MAP &>/dev/null; then
        local today_r
        today_r=$(date '+%Y-%m-%d')
        local tmp_scores
        tmp_scores="$(state_temp_file "$RISK_SCORES_HISTORY_FILE")" || {
            log_warn "Unable to create risk-score history temporary file"
            tmp_scores=""
        }
        if [[ -n "$tmp_scores" ]]; then
            if [[ -f "$RISK_SCORES_HISTORY_FILE" ]]; then
                awk -v d="$today_r" '$1!=d{print}' "$RISK_SCORES_HISTORY_FILE" > "$tmp_scores" || true
            fi
            for d in "${!RISK_MAP[@]}"; do
                printf '%s %s risk=%s captured_epoch=%s schema=%s\n' \
                    "$today_r" "$(persistent_device_key "$d")" "${RISK_MAP[$d]}" \
                    "$RUN_EPOCH" "$HISTORY_SCHEMA_VERSION" >> "$tmp_scores"
            done
            atomic_commit "$tmp_scores" "$RISK_SCORES_HISTORY_FILE" || true
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
    local -a share_records=()
    # Measure current share sizes and replace today's history snapshot.
    for path in "${shares[@]}"; do
        name=$(basename "$path")
        bytes=$(du -sb "$path" 2>/dev/null | awk '{print $1}')
        bytes=${bytes:-0}
        [[ "$bytes" =~ ^[0-9]+$ ]] || continue
        share_records+=("$today $name bytes=$bytes captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION")
    done
    atomic_replace_daily_history \
        "$SHARE_USAGE_HISTORY_FILE" "$today" "${share_records[@]}" ||
        log_warn "Unable to atomically update share-usage history"
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
    # Persist one normalized sample per day. Re-running the script replaces the
    # same-day sample instead of weighting that day multiple times.
    local capacity_record
    capacity_record="$now_date scope=capacity array=$array_pct pools=$pools_pct arr_bu=$arr_bu arr_bs=$arr_bs pool_bu=$pool_bu pool_bs=$pool_bs captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION"
    atomic_replace_daily_history "$CAPACITY_HISTORY_FILE" "$now_date" "$capacity_record" ||
        log_warn "Unable to atomically update capacity history"
    local arr_prev=() pool_prev=() dates=()
    local lines
    local capacity_cutoff
    capacity_cutoff=$(date -d "-${HISTORY_WINDOW_DAYS} days" '+%Y-%m-%d' 2>/dev/null || printf '%s' "$now_date")
    lines=$(awk -v c="$capacity_cutoff" '
        $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $1 >= c { latest[$1]=$0 }
        END { for (d in latest) print latest[d] }
    ' "$CAPACITY_HISTORY_FILE" 2>/dev/null | sort -k1,1)
    while IFS= read -r l; do
        [[ -z "$l" ]] && continue
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
        # Do not turn a partially written legacy row into a false zero-percent
        # sample; that would distort the calculated growth rate.
        [[ "$_apct" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
        [[ "$_ppct" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
        dates+=("$l")
        arr_prev+=("$_apct")
        pool_prev+=("$_ppct")
    done < <(printf "%s\n" "$lines")
    local arr_growth_m=0 pool_growth_m=0 count=${#arr_prev[@]} capacity_span_days=0
    if (( count > 1 )); then
        local first_line last_line first_date last_date first_arr last_arr first_pool last_pool days_elapsed days_elapsed_p
        local first_epoch last_epoch first_rest last_rest
        first_line="${dates[0]}"; last_line="${dates[$((count-1))]}"
        first_date="${first_line%% *}"; last_date="${last_line%% *}"
        first_arr="${arr_prev[0]}"; last_arr="${arr_prev[$((count-1))]}"
        first_pool="${pool_prev[0]}"; last_pool="${pool_prev[$((count-1))]}"
        first_rest="${first_line#* }"
        last_rest="${last_line#* }"
        first_epoch=$(history_record_epoch "$first_date" "$first_rest" 2>/dev/null || true)
        last_epoch=$(history_record_epoch "$last_date" "$last_rest" 2>/dev/null || true)
        days_elapsed=$(awk -v first="$first_epoch" -v last="$last_epoch" \
            'BEGIN { if (first ~ /^[0-9]+$/ && last > first) printf "%.3f", (last-first)/86400.0; else print "0" }')
        days_elapsed_p=$days_elapsed
        capacity_span_days=$days_elapsed
        if [[ $first_arr =~ ^[0-9.]+$ && $last_arr =~ ^[0-9.]+$ ]]; then
            local fa_m la_m
            fa_m=$(convert_pct_to_milli "$first_arr")
            la_m=$(convert_pct_to_milli "$last_arr")
            if (( la_m > fa_m )) && awk -v d="$days_elapsed" 'BEGIN { exit !(d > 0) }'; then
                arr_growth_m=$(awk -v delta="$((la_m - fa_m))" -v days="$days_elapsed" \
                    'BEGIN { printf "%d", delta/days }')
                # Preserve tiny positive growth by clamping to minimum 1 milli-%%/day
                (( arr_growth_m == 0 )) && arr_growth_m=1
            fi
        fi
        if [[ $first_pool =~ ^[0-9.]+$ && $last_pool =~ ^[0-9.]+$ ]]; then
            local fp_m lp_m
            fp_m=$(convert_pct_to_milli "$first_pool")
            lp_m=$(convert_pct_to_milli "$last_pool")
            if (( lp_m > fp_m )) && awk -v d="$days_elapsed_p" 'BEGIN { exit !(d > 0) }'; then
                pool_growth_m=$(awk -v delta="$((lp_m - fp_m))" -v days="$days_elapsed_p" \
                    'BEGIN { printf "%d", delta/days }')
                (( pool_growth_m == 0 )) && pool_growth_m=1
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
    local capacity_previous_epoch=0 capacity_latest_epoch=0 capacity_max_gap_seconds=0
    local capacity_line capacity_date capacity_rest capacity_epoch capacity_gap
    for capacity_line in "${dates[@]}"; do
        capacity_date="${capacity_line%% *}"
        capacity_rest="${capacity_line#* }"
        capacity_epoch=$(history_record_epoch "$capacity_date" "$capacity_rest" 2>/dev/null || true)
        [[ "$capacity_epoch" =~ ^[0-9]+$ ]] || continue
        if (( capacity_previous_epoch > 0 )); then
            capacity_gap=$(( capacity_epoch - capacity_previous_epoch ))
            (( capacity_gap > capacity_max_gap_seconds )) && capacity_max_gap_seconds=$capacity_gap
        fi
        capacity_previous_epoch=$capacity_epoch
        capacity_latest_epoch=$capacity_epoch
    done
    local capacity_latest_age capacity_max_gap_days
    capacity_latest_age=$(awk -v now="$RUN_EPOCH" -v last="$capacity_latest_epoch" \
        'BEGIN { if(last<=0) print 999999; else { age=(now-last)/86400.0; if(age<0) age=0; printf "%.3f", age } }')
    capacity_max_gap_days=$(awk -v gap="$capacity_max_gap_seconds" \
        'BEGIN { printf "%.3f", gap/86400.0 }')
    ARR_FORECAST_CONFIDENCE=$(forecast_confidence \
        "$count" "$capacity_span_days" "$capacity_latest_age" "$capacity_max_gap_days")
    POOL_FORECAST_CONFIDENCE="$ARR_FORECAST_CONFIDENCE"
    ARR_FORECAST_SPAN_DAYS="$capacity_span_days"
    POOL_FORECAST_SPAN_DAYS="$capacity_span_days"
}

# === Main Function ===
# Analyze TBW history to estimate daily write rates and days to threshold
tbw_forecast_and_heavy_writers() {
    # Forecast days-to-endurance threshold and list heavy writers (normalized by capacity)
    (( ${TBW_TREND_ENABLED:-1} == 1 )) || { return 0; }
    TBW_DAILY=()
    TBW_DAYS_LEFT=()
    TBW_STATUS_MAP=()
    TBW_FORECAST_CONFIDENCE=()
    local today
    today=$(date '+%Y-%m-%d')
    local -a tbw_records=()
    for dev in "${!SMART_STATE[@]}"; do
        [[ -n "${SMART_DEFERRED[$dev]:-}" ]] && continue
        local tbw=${CUR_ATTR["$dev|tbw_bytes"]:-}
        if [[ "$tbw" =~ ^[0-9]+$ ]]; then
            tbw_records+=("$today $(persistent_device_key "$dev") tbw=$tbw captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION")
        fi
    done
    atomic_replace_daily_history "$TBW_HISTORY_FILE" "$today" "${tbw_records[@]}" ||
        log_warn "Unable to atomically update TBW history"
    local win=$HISTORY_WINDOW_DAYS
    # Compute per-device daily TBW deltas over window and estimate days to threshold
    local cutoff
    cutoff=$(date -d "-$win days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
    local lines
    lines=$(tail -n 50000 "$TBW_HISTORY_FILE" 2>/dev/null || true)
    if [[ -z "$lines" ]]; then
        # Clear today's derived snapshots as well; otherwise a manually
        # cleared or unavailable TBW history could leave stale same-day data.
        atomic_replace_daily_history "$HEAVY_WRITER_HISTORY_FILE" "$today" ||
            log_warn "Unable to clear today's heavy-writer history"
        atomic_replace_daily_history "$TBW_DAYSLEFT_HISTORY_FILE" "$today" ||
            log_warn "Unable to clear today's TBW days-left history"
        return 0
    fi
    declare -A _TBW_SAMPLE_VALUE _TBW_SAMPLE_EPOCH _TBW_DEVICE_SEEN _TBW_SEQUENCE
    declare -A first_v last_v TBW_SPAN_DAYS
    local stored_key dt rest v sample_key sample_epoch
    while read -r dt stored_key rest; do
        [[ "$dt" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
        [[ "$dt" < "$cutoff" ]] && continue
        dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
        [[ -n "$dev" ]] || continue
        v=$(history_field_value "$rest" tbw 2>/dev/null || true)
        [[ "$v" =~ ^[0-9]+$ ]] || continue
        sample_epoch=$(history_record_epoch "$dt" "$rest" 2>/dev/null || true)
        [[ "$sample_epoch" =~ ^[0-9]+$ ]] || continue
        sample_key="$dev|$dt"
        _TBW_SAMPLE_VALUE[$sample_key]="$v"
        _TBW_SAMPLE_EPOCH[$sample_key]="$sample_epoch"
        _TBW_DEVICE_SEEN[$dev]=1
    done < <(printf '%s\n' "$lines")

    for sample_key in "${!_TBW_SAMPLE_VALUE[@]}"; do
        dev="${sample_key%|*}"
        _TBW_SEQUENCE[$dev]="${_TBW_SEQUENCE[$dev]:-}${_TBW_SAMPLE_EPOCH[$sample_key]} ${_TBW_SAMPLE_VALUE[$sample_key]}"$'\n'
    done

    for dev in "${!_TBW_DEVICE_SEEN[@]}"; do
        local first_epoch=0 last_epoch=0 previous_epoch=0 previous_value=""
        local samples=0 max_gap_seconds=0 gap_seconds reset_seen=0
        while read -r sample_epoch v; do
            [[ "$sample_epoch" =~ ^[0-9]+$ && "$v" =~ ^[0-9]+$ ]] || continue
            if (( samples == 0 )); then
                first_epoch=$sample_epoch
                first_v[$dev]="$v"
            else
                gap_seconds=$(( sample_epoch - previous_epoch ))
                (( gap_seconds > max_gap_seconds )) && max_gap_seconds=$gap_seconds
                (( v < previous_value )) && reset_seen=1
            fi
            last_epoch=$sample_epoch
            last_v[$dev]="$v"
            previous_epoch=$sample_epoch
            previous_value=$v
            ((samples++)) || true
        done < <(printf '%s' "${_TBW_SEQUENCE[$dev]:-}" | sort -n -k1,1)

        local span_days latest_age_days max_gap_days confidence
        span_days=$(awk -v first="$first_epoch" -v last="$last_epoch" \
            'BEGIN { if(last>first) printf "%.3f", (last-first)/86400.0; else print "0" }')
        latest_age_days=$(awk -v now="$RUN_EPOCH" -v last="$last_epoch" \
            'BEGIN { age=(now-last)/86400.0; if(age<0) age=0; printf "%.3f", age }')
        max_gap_days=$(awk -v gap="$max_gap_seconds" 'BEGIN { printf "%.3f", gap/86400.0 }')
        confidence=$(forecast_confidence "$samples" "$span_days" "$latest_age_days" "$max_gap_days")
        if (( reset_seen == 1 )); then
            confidence="RESET"
        fi
        TBW_FORECAST_CONFIDENCE[$dev]="$confidence"
        TBW_SPAN_DAYS[$dev]="$span_days"
    done

    declare -a heavy_rank=()
    for dev in "${!last_v[@]}"; do
        local start=${first_v[$dev]:-0} end=${last_v[$dev]:-0}
        [[ ! "$start" =~ ^[0-9]+$ || ! "$end" =~ ^[0-9]+$ ]] && continue
        local days="${TBW_SPAN_DAYS[$dev]:-0}"
        # Debug: log values if anything is non-numeric before proceeding
        if ! awk -v e="$end" -v s="$start" -v d="$days" 'BEGIN{exit (e ~ /^[0-9]+$/ && s ~ /^[0-9]+$/ && d+0>0)?0:1}'; then
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
            if awk -v c="$cap_tb" 'BEGIN{exit !(c+0>0)}' &&
               forecast_confidence_is_actionable "${TBW_FORECAST_CONFIDENCE[$dev]:-INSUFFICIENT}"
            then
                local norm_pct
                norm_pct=$(awk -v daily="$daily" -v cap_tb="$cap_tb" 'BEGIN{printf "%.6f", ((daily+0)/ (cap_tb*1000000000000.0))*100}')
                heavy_rank+=("$norm_pct $dev $daily $cap_tb")
            fi
        fi
    done
    local -a heavy_writer_records=()
    if (( ${#heavy_rank[@]} > 0 )); then
        # Persist top heavy writers normalized rate to history
        local sorted
        sorted=$(printf "%s\n" "${heavy_rank[@]}" | sort -nr -k1,1 | head -n 5)
        while read -r pct dev daily cap_tb; do
            [[ -z "$dev" ]] && continue
            heavy_writer_records+=("$today $(persistent_device_key "$dev") norm=$pct daily=$daily confidence=${TBW_FORECAST_CONFIDENCE[$dev]:-INSUFFICIENT} captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION")
        done < <(printf "%s\n" "$sorted")
    fi
    atomic_replace_daily_history \
        "$HEAVY_WRITER_HISTORY_FILE" "$today" "${heavy_writer_records[@]}" ||
        log_warn "Unable to atomically update heavy-writer history"
    # Generate TBW endurance alerts
    if declare -p TBW_DAYS_LEFT >/dev/null 2>&1; then
        for dev in "${!TBW_DAYS_LEFT[@]}"; do
        local days_left=${TBW_DAYS_LEFT[$dev]}
        local status=${TBW_STATUS_MAP[$dev]:-OK}
        local confidence=${TBW_FORECAST_CONFIDENCE[$dev]:-INSUFFICIENT}
        if [[ "$status" == "CRITICAL" ]] && forecast_confidence_is_actionable "$confidence"; then
            record_alert critical "TBW Endurance" "Disk $dev TBW forecast CRITICAL: ${days_left}d remaining (<${TBW_DAYS_CRIT}d; confidence=$confidence)"
        elif [[ "$status" == "WARNING" ]] && forecast_confidence_is_actionable "$confidence"; then
            record_alert warning "TBW Endurance" "Disk $dev TBW forecast WARNING: ${days_left}d remaining (<${TBW_DAYS_WARN}d; confidence=$confidence)"
        fi
        done
    fi
    # Persist one normalized TBW days-left snapshot per day.
    if (( ${TBW_TREND_ENABLED:-0} == 1 )); then
        local -a tbw_daysleft_records=()
        for dev in "${!TBW_DAYS_LEFT[@]}"; do
            local dl="${TBW_DAYS_LEFT[$dev]}"
            [[ -n "$dl" ]] || continue
            tbw_daysleft_records+=("$today $(persistent_device_key "$dev") days_left=$dl confidence=${TBW_FORECAST_CONFIDENCE[$dev]:-INSUFFICIENT} captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION")
        done
        atomic_replace_daily_history \
            "$TBW_DAYSLEFT_HISTORY_FILE" "$today" "${tbw_daysleft_records[@]}" ||
            log_warn "Unable to atomically update TBW days-left history"
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
                if (( NVME_WEAR_REGRESSION_WARN > 0 &&
                      delta >= NVME_WEAR_REGRESSION_WARN )); then
                    events+=" - $(basename "$dev") NVMe percent_used regression: ${prev_used}% -> ${curr_used}% (drop ${delta}%)\n"
                    record_alert warning "Firmware Reset" "Disk $dev NVMe Percentage Used decreased (${prev_used}% -> ${curr_used}%); check firmware or controller resets"
                fi
            fi
        fi
    done
    return 0
}

# Normalize a counter delta to a per-day rate when capture timing is known.
counter_rate_per_day() {
    local delta="$1" elapsed_seconds="$2"
    (( elapsed_seconds > 0 )) || return 1
    awk -v delta="$delta" -v elapsed="$elapsed_seconds" \
        'BEGIN { printf "%.6f", (delta * 86400.0) / elapsed }'
}

last_btrfs_history_metric() {
    local stable_key="$1" legacy_path="$2" wanted_key="$3"
    [[ -f "$BTRFS_DEV_HIST_FILE" ]] || return 0
    awk -v stable="$stable_key" -v legacy="$legacy_path" -v wanted="$wanted_key" '
        $2 != stable && $2 != legacy { next }
        {
            matched = 0
            reset = 0
            delta = ""
            rate = ""
            for (i = 3; i <= NF; i++) {
                if ($i == "key=" wanted) matched = 1
                if ($i == "event=reset") reset = 1
                if ($i ~ /^delta=/) { delta=$i; sub(/^delta=/, "", delta) }
                if ($i ~ /^rate_day=/) { rate=$i; sub(/^rate_day=/, "", rate) }
            }
            if (!matched) next
            if (reset) { print "reset", 0; next }
            if (delta !~ /^[0-9]+$/) next
            if (rate ~ /^[0-9]+([.][0-9]+)?$/ && rate > 0) print "rate", rate
            else print "delta", delta
        }
    ' "$BTRFS_DEV_HIST_FILE" 2>/dev/null | tail -n 1
}

last_xfs_history_metric() {
    local wanted_key="$1"
    [[ -f "$XFS_PROC_HISTORY_FILE" ]] || return 0
    awk -v wanted="$wanted_key" '
        {
            matched = 0
            reset = 0
            delta = ""
            rate = ""
            for (i = 2; i <= NF; i++) {
                if ($i == "key=" wanted) matched = 1
                if ($i == "event=reset") reset = 1
                if ($i ~ /^delta=/) { delta=$i; sub(/^delta=/, "", delta) }
                if ($i ~ /^rate_day=/) { rate=$i; sub(/^rate_day=/, "", rate) }
            }
            if (!matched) next
            if (reset) { print "reset", 0; next }
            if (delta !~ /^[0-9]+$/) next
            if (rate ~ /^[0-9]+([.][0-9]+)?$/ && rate > 0) print "rate", rate
            else print "delta", delta
        }
    ' "$XFS_PROC_HISTORY_FILE" 2>/dev/null | tail -n 1
}

# Collect Btrfs counters without resetting them. Missing baselines and counter
# regressions establish a new baseline and never become synthetic error deltas.
collect_btrfs_device_stats() {
    (( ${ENABLE_BTRFS_DEVICE_STATS:-0} == 1 )) || return 0
    local prev_file="$BTRFS_DEV_PREV_FILE"
    local snapshot_temp now_epoch previous_epoch=0 current_boot_id="unknown"
    local stored_key state_key dev key val line token m stats prev delta elapsed_seconds
    local rate_day current_kind current_metric last_kind last_metric ratio=0
    local absolute_severity alert_severity alert_title alert_message boost bdev
    local out_has=0 baseline_count=0 reset_count=0 delta_count=0
    local today
    local -a mounts=()
    declare -A PREV_STAT PREV_PRESENT

    now_epoch=$(date +%s)
    [[ -r /proc/sys/kernel/random/boot_id ]] && read -r current_boot_id < /proc/sys/kernel/random/boot_id || true

    if [[ -f "$prev_file" ]]; then
        while read -r stored_key key val line; do
            if [[ "$stored_key" == "meta" ]]; then
                for token in "$key" "$val" $line; do
                    [[ "$token" == captured_epoch=* ]] && previous_epoch="${token#*=}"
                done
                continue
            fi
            dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
            [[ -n "$dev" && -n "$key" && "$val" =~ ^[0-9]+$ ]] || continue
            PREV_STAT["$dev|$key"]="$val"
            PREV_PRESENT["$dev|$key"]=1
        done < "$prev_file"
    fi
    [[ "$previous_epoch" =~ ^[0-9]+$ ]] || previous_epoch=0
    elapsed_seconds=$(( now_epoch - previous_epoch ))
    (( elapsed_seconds > 0 )) || elapsed_seconds=0

    mapfile -t mounts < <(mount | awk '/ btrfs /{print $3}')
    (( ${#mounts[@]} > 0 )) || return 0

    snapshot_temp="$(state_temp_file "$prev_file")" || return 0
    printf 'meta schema=2 captured_epoch=%s boot_id=%s\n' "$now_epoch" "$current_boot_id" > "$snapshot_temp"
    today=$(date '+%Y-%m-%d')

    for m in "${mounts[@]}"; do
        # Never pass -z: the monitor must preserve filesystem diagnostic evidence.
        stats=$(btrfs device stats "$m" 2>/dev/null || true)
        [[ -n "$stats" ]] || continue

        while IFS= read -r line; do
            dev=""; key=""; val=""
            if [[ "$line" =~ ^\[([^]]+)\]\.([^[:space:]]+)[[:space:]]+([0-9]+) ]]; then
                dev="${BASH_REMATCH[1]}"
                key="${BASH_REMATCH[2]}"
                val="${BASH_REMATCH[3]}"
            elif [[ "$line" =~ ^(/dev/[^:[:space:]]+):?[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9]+) ]]; then
                dev="${BASH_REMATCH[1]}"
                key="${BASH_REMATCH[2]}"
                val="${BASH_REMATCH[3]}"
            fi
            [[ -n "$dev" && -n "$key" && "$val" =~ ^[0-9]+$ ]] || continue

            state_key=$(persistent_device_key "$dev")
            printf '%s %s %s\n' "$state_key" "$key" "$val" >> "$snapshot_temp"
            out_has=1

            if [[ -z "${PREV_PRESENT["$dev|$key"]:-}" ]]; then
                ((baseline_count++)) || true
                continue
            fi

            prev=${PREV_STAT["$dev|$key"]}
            if (( val < prev )); then
                ((reset_count++)) || true
                printf '%s %s mount=%s key=%s event=reset previous=%s value=%s captured_epoch=%s schema=%s\n' \
                    "$today" "$state_key" "$m" "$key" "$prev" "$val" \
                    "$RUN_EPOCH" "$HISTORY_SCHEMA_VERSION" >> "$BTRFS_DEV_HIST_FILE"
                continue
            fi

            delta=$(( val - prev ))
            (( delta > 0 )) || continue
            ((delta_count++)) || true
            rate_day=$(counter_rate_per_day "$delta" "$elapsed_seconds" 2>/dev/null || true)
            if [[ -n "$rate_day" ]]; then
                current_kind="rate"
                current_metric="$rate_day"
            else
                current_kind="delta"
                current_metric="$delta"
            fi

            last_kind=""; last_metric=""; ratio=0
            read -r last_kind last_metric < <(last_btrfs_history_metric "$state_key" "$dev" "$key") || true
            if [[ "$last_kind" == "$current_kind" && "$last_metric" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                ratio=$(awk -v current="$current_metric" -v previous="$last_metric" \
                    'BEGIN { if (previous > 0) printf "%d", int(current / previous); else print 0 }')
            fi

            printf '%s %s mount=%s key=%s delta=%s value=%s elapsed_sec=%s%s captured_epoch=%s schema=%s\n' \
                "$today" "$state_key" "$m" "$key" "$delta" "$val" "$elapsed_seconds" \
                "${rate_day:+ rate_day=$rate_day}" "$RUN_EPOCH" "$HISTORY_SCHEMA_VERSION" >> "$BTRFS_DEV_HIST_FILE"

            absolute_severity=""
            case "$key" in
                corruption_errs|generation_errs)
                    if (( delta >= BTRFS_DEV_CORR_CRIT_DELTA )); then absolute_severity="critical"
                    elif (( delta >= BTRFS_DEV_CORR_WARN_DELTA )); then absolute_severity="warning"
                    fi
                    ;;
                read_io_errs|write_io_errs|flush_io_errs)
                    if (( delta >= BTRFS_DEV_ERR_CRIT_DELTA )); then absolute_severity="critical"
                    elif (( delta >= BTRFS_DEV_ERR_WARN_DELTA )); then absolute_severity="warning"
                    fi
                    ;;
            esac

            alert_severity="$absolute_severity"
            alert_title="Btrfs Device"
            alert_message="Device $dev $key +$delta (now $val) on mount $m"
            boost=0
            if (( ratio >= BTRFS_ERR_BURST_CRIT_RATIO )); then
                alert_severity="critical"
                alert_title="Btrfs Burst"
                alert_message="Device $dev $key rate burst x${ratio} (+$delta) on mount $m"
                boost=$BURST_CRIT_BOOST
            elif (( ratio >= BTRFS_ERR_BURST_WARN_RATIO )); then
                [[ "$alert_severity" == "critical" ]] || alert_severity="warning"
                alert_title="Btrfs Burst"
                alert_message="Device $dev $key rate elevated x${ratio} (+$delta) on mount $m"
                boost=$BURST_WARN_BOOST
            fi

            [[ -n "$alert_severity" ]] || continue
            record_alert "$alert_severity" "$alert_title" "$alert_message"
            bdev=$(base_device "$dev")
            [[ -n "$bdev" ]] || continue
            [[ -n "${SMART_STATE[$bdev]:-}" ]] || SMART_STATE[$bdev]="OK"
            SMART_MSGS[$bdev]="${SMART_MSGS[$bdev]:-} Btrfs device errors: $key +$delta"
            if (( boost > 0 )); then
                boost=$(( ${BURST_BOOST[$bdev]:-0} + boost ))
                (( boost > 100 )) && boost=100
                BURST_BOOST[$bdev]=$boost
            fi
        done <<< "$stats"
    done

    if (( out_has == 1 )); then
        atomic_commit "$snapshot_temp" "$prev_file" || true
    else
        rm -f -- "$snapshot_temp" 2>/dev/null || true
    fi
    (( baseline_count > 0 )) && log "BTRFS" "INFO" \
        "Established $baseline_count new counter baseline(s) without alerting"
    (( reset_count > 0 )) && log "BTRFS" "WARN" \
        "Detected $reset_count counter reset(s); affected counters were re-baselined"
    log "BTRFS" "INFO" "Recorded $delta_count positive counter delta(s)"
}

# === Main Function ===
# Collect and integrate xfs /proc stats (global deltas)
collect_xfs_proc_stats() {
    (( ${ENABLE_XFS_PROC_STATS:-0} == 1 )) || return 0
    local stat_file="/proc/fs/xfs/stat" prev_file="$XFS_PROC_PREV_FILE"
    [[ -r "$stat_file" ]] || return 0

    local snapshot_temp now_epoch previous_epoch=0 current_boot_id="unknown" previous_boot_id=""
    local first second rest token k ex skip val prev delta elapsed_seconds rate_day
    local current_kind current_metric last_kind last_metric ratio absolute_severity
    local alert_due alert_severity burst_boost summary_lines="" final_severity
    local m src bdev boost message today
    local suppress=0 baseline_all=0 snapshot_count=0 baseline_count=0 reset_count=0 delta_count=0
    local had_any=0 had_crit=0
    local -a keys=() filtered=() xfs_mounts_arr=()
    declare -A PREV_XFS PREV_XFS_PRESENT

    now_epoch=$(date +%s)
    today=$(date '+%Y-%m-%d')
    [[ -r /proc/sys/kernel/random/boot_id ]] && read -r current_boot_id < /proc/sys/kernel/random/boot_id || true

    if (( XFS_PROC_SUPPRESS_DURING_PARITY == 1 && PARITY_ACTIVE == 1 )); then
        suppress=1
        log "XFS" "INFO" "Suppressing XFS proc alerts during parity action ${PARITY_ACTION:-unknown}"
    fi

    if [[ -f "$prev_file" ]]; then
        while read -r first second rest; do
            if [[ "$first" == "meta" ]]; then
                for token in "$second" $rest; do
                    [[ "$token" == captured_epoch=* ]] && previous_epoch="${token#*=}"
                    [[ "$token" == boot_id=* ]] && previous_boot_id="${token#*=}"
                done
                continue
            fi
            [[ -n "$first" && "$second" =~ ^[0-9]+$ ]] || continue
            PREV_XFS["$first"]="$second"
            PREV_XFS_PRESENT["$first"]=1
        done < "$prev_file"
    fi
    [[ "$previous_epoch" =~ ^[0-9]+$ ]] || previous_epoch=0
    elapsed_seconds=$(( now_epoch - previous_epoch ))
    (( elapsed_seconds > 0 )) || elapsed_seconds=0

    if [[ -z "$previous_boot_id" || "$previous_boot_id" != "$current_boot_id" ]]; then
        baseline_all=1
    fi

    if [[ -n "$XFS_PROC_KEYS" ]]; then
        read -r -a keys <<< "$XFS_PROC_KEYS"
    else
        keys=(extent_alloc dir_lookup dir_create xs_xstrat delalloc flush)
    fi
    if [[ -n "$XFS_PROC_KEYS_EXCLUDE" ]]; then
        for k in "${keys[@]}"; do
            skip=0
            for ex in $XFS_PROC_KEYS_EXCLUDE; do
                [[ "$k" == "$ex" ]] && { skip=1; break; }
            done
            (( skip == 0 )) && filtered+=("$k")
        done
        keys=("${filtered[@]}")
    fi

    mapfile -t xfs_mounts_arr < <(mount | awk '/ xfs /{print $3}')
    snapshot_temp="$(state_temp_file "$prev_file")" || return 0
    printf 'meta schema=2 captured_epoch=%s boot_id=%s\n' "$now_epoch" "$current_boot_id" > "$snapshot_temp"

    for k in "${keys[@]}"; do
        val=$(awk -v key="$k" '$1==key{print $2; exit}' "$stat_file" 2>/dev/null || true)
        [[ "$val" =~ ^[0-9]+$ ]] || continue
        printf '%s %s\n' "$k" "$val" >> "$snapshot_temp"
        ((snapshot_count++)) || true

        if (( baseline_all == 1 )) || [[ -z "${PREV_XFS_PRESENT[$k]:-}" ]]; then
            ((baseline_count++)) || true
            continue
        fi

        prev=${PREV_XFS[$k]}
        if (( val < prev )); then
            ((reset_count++)) || true
            printf '%s key=%s event=reset previous=%s value=%s boot_id=%s captured_epoch=%s schema=%s\n' \
                "$today" "$k" "$prev" "$val" "$current_boot_id" \
                "$RUN_EPOCH" "$HISTORY_SCHEMA_VERSION" >> "$XFS_PROC_HISTORY_FILE"
            continue
        fi

        delta=$(( val - prev ))
        (( delta > 0 )) || continue
        ((delta_count++)) || true
        rate_day=$(counter_rate_per_day "$delta" "$elapsed_seconds" 2>/dev/null || true)
        if [[ -n "$rate_day" ]]; then
            current_kind="rate"
            current_metric="$rate_day"
        else
            current_kind="delta"
            current_metric="$delta"
        fi

        last_kind=""; last_metric=""; ratio=0
        read -r last_kind last_metric < <(last_xfs_history_metric "$k") || true
        if [[ "$last_kind" == "$current_kind" && "$last_metric" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            ratio=$(awk -v current="$current_metric" -v previous="$last_metric" \
                'BEGIN { if (previous > 0) printf "%d", int(current / previous); else print 0 }')
        fi

        printf '%s key=%s delta=%s value=%s elapsed_sec=%s%s captured_epoch=%s schema=%s\n' \
            "$today" "$k" "$delta" "$val" "$elapsed_seconds" \
            "${rate_day:+ rate_day=$rate_day}" "$RUN_EPOCH" "$HISTORY_SCHEMA_VERSION" >> "$XFS_PROC_HISTORY_FILE"

        absolute_severity=""
        if (( delta >= XFS_PROC_CRIT_DELTA )); then absolute_severity="critical"
        elif (( delta >= XFS_PROC_WARN_DELTA )); then absolute_severity="warning"
        fi

        alert_due=0
        alert_severity="$absolute_severity"
        burst_boost=0
        message="$k +$delta"
        if (( ratio >= XFS_ERR_BURST_CRIT_RATIO )); then
            alert_due=1
            alert_severity="critical"
            burst_boost=$BURST_CRIT_BOOST
            message="$k rate burst +$delta (x${ratio})"
        elif (( ratio >= XFS_ERR_BURST_WARN_RATIO )); then
            alert_due=1
            [[ "$alert_severity" == "critical" ]] || alert_severity="warning"
            burst_boost=$BURST_WARN_BOOST
            message="$k rate elevated +$delta (x${ratio})"
        elif [[ -n "$absolute_severity" ]] && (( XFS_PROC_REQUIRE_RATIO_FOR_ALERT == 0 )); then
            alert_due=1
        fi

        (( alert_due == 1 )) || continue
        had_any=1
        [[ "$alert_severity" == "critical" ]] && had_crit=1
        summary_lines+="$message; "

        if (( burst_boost > 0 && XFS_PROC_SMART_ANNOTATE_BURST == 1 && suppress == 0 )); then
            for m in "${xfs_mounts_arr[@]}"; do
                src=$(findmnt -n -o SOURCE "$m" 2>/dev/null || true)
                [[ -n "$src" ]] || continue
                bdev=$(base_device "$src")
                [[ -n "$bdev" ]] || continue
                [[ -n "${SMART_STATE[$bdev]:-}" ]] || SMART_STATE[$bdev]="OK"
                SMART_MSGS[$bdev]="${SMART_MSGS[$bdev]:-} XFS burst: $k x${ratio}"
                boost=$(( ${BURST_BOOST[$bdev]:-0} + burst_boost ))
                (( boost > 100 )) && boost=100
                BURST_BOOST[$bdev]=$boost
            done
        fi
    done

    if (( snapshot_count > 0 )); then
        atomic_commit "$snapshot_temp" "$prev_file" || true
    else
        rm -f -- "$snapshot_temp" 2>/dev/null || true
    fi

    if (( baseline_all == 1 && baseline_count > 0 )); then
        log "XFS" "INFO" \
            "Established a boot-aware XFS baseline for $baseline_count counter(s) without alerting"
    elif (( baseline_count > 0 )); then
        log "XFS" "INFO" "Established $baseline_count new XFS counter baseline(s) without alerting"
    fi
    (( reset_count > 0 )) && log "XFS" "WARN" \
        "Detected $reset_count XFS counter reset(s); affected counters were re-baselined"
    log "XFS" "INFO" "Recorded $delta_count positive XFS counter delta(s)"

    if (( had_any == 1 && suppress == 0 )); then
        message="XFS metadata activity spike: ${summary_lines%%; }"
        [[ $had_crit -eq 1 ]] && final_severity="critical" || final_severity="warning"
        if (( XFS_PROC_PER_MOUNT_ALERTS == 1 )); then
            for m in "${xfs_mounts_arr[@]}"; do
                src=$(findmnt -n -o SOURCE "$m" 2>/dev/null || true)
                [[ -n "$src" ]] || continue
                bdev=$(base_device "$src")
                record_alert "$final_severity" "$NOTIFY_TITLE_XFS" "$message (${bdev:-unknown}, mount: $m)"
            done
        else
            record_alert "$final_severity" "$NOTIFY_TITLE_XFS" "$message"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Notification assembly
# ---------------------------------------------------------------------------

add_notification_section() {
    local section="${1:-}"
    local cleaned

    if ! printf '%s' "$section" | grep -q '[^[:space:]]'; then
        return 0
    fi

    section="${section//\\n/$'\n'}"
    cleaned="$(
        printf '%s\n' "$section" |
            awk '
                BEGIN { emitted=0; blanks=0 }
                /^[[:space:]]*$/ { blanks++; next }
                {
                    if (blanks > 0 && emitted > 0)
                        print ""
                    blanks=0
                    print
                    emitted++
                }
            '
    )"

    [[ -n "$cleaned" ]] && NOTIFY_SECTIONS+=("$cleaned")
}


append_subsystem_subject_suffix() {
    local degraded_list=""

    case "${SHOW_SUBSYSTEMS_BLOCK:-auto}" in
        never)
            return 0
            ;;
        always|auto)
            while IFS= read -r name; do
                [[ -n "$name" ]] || continue
                if [[ -z "$degraded_list" ]]; then
                    degraded_list="$name"
                else
                    degraded_list+=", $name"
                fi
            done < <(
                printf '%s\n' "${SUBSYSTEM_LINES:-}" |
                    awk -F: '/: (WARNING|CRITICAL)$/ {print $1}'
            )

            if [[ -n "$degraded_list" ]]; then
                SUBJECT="${SUBJECT:-Disks Health} — Subsystems degraded: $degraded_list"
            elif [[ "$SHOW_SUBSYSTEMS_BLOCK" == "always" ]]; then
                SUBJECT="${SUBJECT:-Disks Health} — All subsystems nominal"
            fi
            ;;
    esac
}


compose_notification() {
    local array_section pool_section tail_sections=""
    local index

    append_subsystem_subject_suffix

    array_section="[Array Disks]:\n${PARITY_STATUS_LINE:-}\n${PARITY_DETAILS_SECTION:-}${ARRAY_DISK_LINES:-}"
    pool_section=""
    if printf '%s' "${POOL_LINES:-}" | grep -q '[^[:space:]]'; then
        pool_section="[Pool Disks]:\n${POOL_LINES}"
    fi

    NOTIFY_SECTIONS=()
    add_notification_section "$array_section"
    add_notification_section "$pool_section"
    add_notification_section "${DISK_HEALTH_SUMMARY:-}"
    add_notification_section "${STORAGE_VALIDATION_SECTION:-}"
    add_notification_section "${HEALTH_ALERTS_SECTION:-}"
    add_notification_section "${TREND_SECTION:-}"

    for index in "${!NOTIFY_SECTIONS[@]}"; do
        if (( index > 0 )); then
            tail_sections+=$'\n\n'
        fi
        tail_sections+="${NOTIFY_SECTIONS[$index]}"
    done

    NOTIFY_BODY="${STORAGE_TOP_LINES:-}"
    if [[ -n "$tail_sections" ]]; then
        NOTIFY_BODY+=$'\n\n'
        NOTIFY_BODY+="$tail_sections"
    fi

    if (( ${#ALERT_CRIT[@]} > 0 )); then
        FINAL_NOTIFICATION_SEVERITY="critical"
    elif (( ${#ALERT_WARN[@]} > 0 )); then
        FINAL_NOTIFICATION_SEVERITY="warning"
    else
        FINAL_NOTIFICATION_SEVERITY="normal"
    fi
}


# ---------------------------------------------------------------------------
# Atomic persistence
# ---------------------------------------------------------------------------

persist_current_attrs() {
    local temp_file disk key value line state_key

    temp_file="$(state_temp_file "$PREV_ATTR_FILE")" || return 1

    for disk in "${!SMART_STATE[@]}"; do
        state_key=$(persistent_device_key "$disk")
        line="$state_key state=${SMART_STATE[$disk]}"

        for key in \
            realloc pending offunc reported_uncorr cmd_timeout realloc_events \
            udma lcc end2end soft_read_err temp poh life_remain tbw_bytes \
            tbw_consumed_pct nvme_percent_used unsafe_shutdowns media_errors \
            err_logs avail_spare pcie_corr pcie_unc therm_t1 therm_t2 \
            warn_temp_time crit_temp_time selftest_status
        do
            value=${CUR_ATTR["$disk|$key"]:-}
            [[ -n "$value" ]] && line+=" $key=$value"
        done

        printf '%s\n' "$line" >> "$temp_file"
    done

    atomic_commit "$temp_file" "$PREV_ATTR_FILE"
}


persist_new_seen() {
    local temp_file key state_key

    temp_file="$(state_temp_file "$ALERT_NEW_SEEN_FILE")" || return 1

    for key in "${!NEW_SEEN[@]}"; do
        state_key=$(persistent_seen_key "$key")
        printf '%s\n' "$state_key" >> "$temp_file"
    done

    atomic_commit "$temp_file" "$ALERT_NEW_SEEN_FILE"
}


persist_risk_scores() {
    local temp_file dev score previous delta state_key

    temp_file="$(state_temp_file "$RISK_PREV_FILE")" || return 1

    for dev in "${!SMART_STATE[@]}"; do
        previous=${PREVIOUS_RISK["$dev"]:-}
        score="${RISK_MAP[$dev]:-}"
        if [[ ! "$score" =~ ^[0-9]+$ ]]; then
            score="$(risk_score_for_device \
                "$dev" \
                "${SMART_STATE[$dev]}" \
                "${SMART_MSGS[$dev]:-}")"
        fi
        if [[ -n "${SMART_DEFERRED[$dev]:-}" && "$previous" =~ ^[0-9]+$ ]]; then
            (( previous > score )) && score="$previous"
        fi

        if [[ "$previous" =~ ^[0-9]+$ && "$score" =~ ^[0-9]+$ ]]; then
            delta=$((score - previous))
            if (( delta != 0 )); then
                log "RISK" "INFO" \
                    "Risk score change for $dev: $previous -> $score (delta=$delta)"
            fi
        fi

        state_key=$(persistent_device_key "$dev")
        printf '%s %s\n' "$state_key" "$score" >> "$temp_file"
        PREVIOUS_RISK["$dev"]="$score"
    done

    atomic_commit "$temp_file" "$RISK_PREV_FILE"
}


persist_all_state() {
    log "STATE" "INFO" "Persisting runtime state"

    save_nvme_state || true
    save_long_last_poh || true
    save_cmd_timeout_last || true
    save_risk_spikes || true
    save_last_test || true
    persist_current_attrs || true
    persist_new_seen || true
    persist_risk_scores || true
}


# ---------------------------------------------------------------------------
# Validation and orchestration
# ---------------------------------------------------------------------------

configuration_error() {
    CONFIG_ERROR_COUNT=$((CONFIG_ERROR_COUNT + 1))
    log "CONFIG" "ERROR" "$*"
}

configuration_warning() {
    CONFIG_WARNING_COUNT=$((CONFIG_WARNING_COUNT + 1))
    log "CONFIG" "WARN" "$*"
}

configuration_value() {
    local setting="$1"

    if ! declare -p "$setting" >/dev/null 2>&1; then
        return 1
    fi
    printf '%s' "${!setting}"
}

validate_boolean_setting() {
    local setting="$1" value

    value=$(configuration_value "$setting" 2>/dev/null || true)
    [[ "$value" =~ ^[01]$ ]] ||
        configuration_error "$setting must be 0 or 1 (found '${value:-unset}')"
}

validate_nonnegative_integer_setting() {
    local setting="$1" value

    value=$(configuration_value "$setting" 2>/dev/null || true)
    [[ "$value" =~ ^[0-9]+$ ]] ||
        configuration_error "$setting must be a non-negative integer (found '${value:-unset}')"
}

validate_positive_integer_setting() {
    local setting="$1" value

    value=$(configuration_value "$setting" 2>/dev/null || true)
    [[ "$value" =~ ^[1-9][0-9]*$ ]] ||
        configuration_error "$setting must be a positive integer (found '${value:-unset}')"
}

validate_nonnegative_number_setting() {
    local setting="$1" value

    value=$(configuration_value "$setting" 2>/dev/null || true)
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
        configuration_error "$setting must be a non-negative number (found '${value:-unset}')"
}

validate_positive_number_setting() {
    local setting="$1" value

    value=$(configuration_value "$setting" 2>/dev/null || true)
    if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
       ! awk -v value="$value" 'BEGIN { exit !(value > 0) }'
    then
        configuration_error "$setting must be a positive number (found '${value:-unset}')"
    fi
}

validate_percent_setting() {
    local setting="$1" value

    value=$(configuration_value "$setting" 2>/dev/null || true)
    if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
       ! awk -v value="$value" 'BEGIN { exit !(value >= 0 && value <= 100) }'
    then
        configuration_error "$setting must be between 0 and 100 (found '${value:-unset}')"
    fi
}

validate_ordered_pair() {
    local lower_setting="$1" upper_setting="$2" lower upper

    lower=$(configuration_value "$lower_setting" 2>/dev/null || true)
    upper=$(configuration_value "$upper_setting" 2>/dev/null || true)
    [[ "$lower" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
    [[ "$upper" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
    if ! awk -v lower="$lower" -v upper="$upper" \
        'BEGIN { exit !(lower <= upper) }'
    then
        configuration_error \
            "$lower_setting ($lower) must be less than or equal to $upper_setting ($upper)"
    fi
}

validate_absolute_path_setting() {
    local setting="$1" value

    value=$(configuration_value "$setting" 2>/dev/null || true)
    if [[ -z "$value" || "$value" != /* || "$value" == "/" ]]; then
        configuration_error \
            "$setting must be a non-root absolute path (found '${value:-unset}')"
    fi
}

validate_model_rule_block() {
    local setting="$1" kind="$2" block line line_number=0

    block=$(configuration_value "$setting" 2>/dev/null || true)
    while IFS= read -r line; do
        line_number=$((line_number + 1))
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == "\\" || "$line" =~ ^[[:space:]]*# ]] && continue

        local -A fields=()
        local -a parts=()
        local part key value grep_status
        IFS=';' read -r -a parts <<< "$line"
        for part in "${parts[@]}"; do
            if [[ "$part" != *:* ]]; then
                configuration_error "$setting line $line_number has an invalid field: $part"
                continue
            fi
            key="${part%%:*}"
            value="${part#*:}"
            case "$kind:$key" in
                tbw:regex|tbw:per_tb|tbw:cap_min|tbw:cap_max|\
                poh:type|poh:regex|poh:warn|poh:crit|poh:cap_min|poh:cap_max|\
                quirk:action|quirk:regex|quirk:cap_min|quirk:cap_max)
                    ;;
                *)
                    configuration_error \
                        "$setting line $line_number contains unsupported key '$key'"
                    continue
                    ;;
            esac
            if [[ -n "${fields[$key]+set}" ]]; then
                configuration_error "$setting line $line_number repeats key '$key'"
            fi
            fields[$key]="$value"
        done

        if [[ -z "${fields[regex]:-}" ]]; then
            configuration_error "$setting line $line_number requires regex"
        else
            printf '' | grep -Eq -- "${fields[regex]}" 2>/dev/null
            grep_status=$?
            (( grep_status != 2 )) ||
                configuration_error "$setting line $line_number has an invalid regex"
        fi

        for key in cap_min cap_max; do
            [[ -z "${fields[$key]:-}" ]] && continue
            [[ "${fields[$key]}" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
                configuration_error "$setting line $line_number has invalid $key"
        done
        if [[ "${fields[cap_min]:-}" =~ ^[0-9]+([.][0-9]+)?$ &&
              "${fields[cap_max]:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
           ! awk -v minimum="${fields[cap_min]}" -v maximum="${fields[cap_max]}" \
                'BEGIN { exit !(minimum <= maximum) }'
        then
            configuration_error "$setting line $line_number has cap_min greater than cap_max"
        fi

        case "$kind" in
            tbw)
                if [[ ! "${fields[per_tb]:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
                   ! awk -v value="${fields[per_tb]:-0}" 'BEGIN { exit !(value > 0) }'
                then
                    configuration_error "$setting line $line_number requires positive per_tb"
                fi
                ;;
            poh)
                case "${fields[type]:-}" in
                    nvme|sata-ssd|sata-hdd) ;;
                    *) configuration_error \
                        "$setting line $line_number requires type nvme, sata-ssd, or sata-hdd" ;;
                esac
                for key in warn crit; do
                    [[ "${fields[$key]:-}" =~ ^[1-9][0-9]*$ ]] ||
                        configuration_error "$setting line $line_number requires positive $key"
                done
                if [[ "${fields[warn]:-}" =~ ^[0-9]+$ &&
                      "${fields[crit]:-}" =~ ^[0-9]+$ ]] &&
                   ! awk -v warn="${fields[warn]}" -v crit="${fields[crit]}" \
                        'BEGIN { exit !(warn <= crit) }'
                then
                    configuration_error "$setting line $line_number has warn greater than crit"
                fi
                ;;
            quirk)
                case "${fields[action]:-}" in
                    invert_mwi_small) ;;
                    *) configuration_error \
                        "$setting line $line_number has unsupported action '${fields[action]:-unset}'" ;;
                esac
                ;;
        esac
    done <<< "$block"
}

validate_configuration() {
    CONFIG_ERROR_COUNT=0
    CONFIG_WARNING_COUNT=0

    local setting pair excluded_pool
    local -a boolean_settings=(
        SMART_ALLOW_SPINUP SHORT_TEST_POLL LONG_TEST_INITIAL_FORCE
        REPLACEMENT_AUTO_RESET STORAGE_DISCREPANCY_ALERT_ENABLED
        ENABLE_BTRFS_SCRUB FIRST_RUN_FORCE ENABLE_BTRFS_DEVICE_STATS
        ENABLE_XFS_CHECK ENABLE_XFS_PROC_STATS XFS_PROC_PER_MOUNT_ALERTS
        XFS_PROC_REQUIRE_RATIO_FOR_ALERT XFS_PROC_SMART_ANNOTATE_BURST
        XFS_PROC_SUPPRESS_DURING_PARITY AGE_AWARE_ENABLED
        SMART_ATTR_TREND_ENABLED ERROR_RATE_TREND_ENABLED
        SATA_LINK_INSTABILITY_ENABLED BTRFS_DEV_TREND_ENABLED
        SHARE_BREAKDOWN_ENABLED RISK_SCORING_ENABLED LIFECYCLE_ENABLED
        POH_TREND_ENABLED TBW_TREND_ENABLED TEMP_RATE_ALERT_ENABLED
        IO_ERROR_MONITOR_ENABLED IO_ERROR_DEDUP_ENABLED LOG_PRUNE_ENABLED
        HISTORY_PRUNE_ENABLED LOG_MIRROR_STDOUT SHOW_OK_SUBSYSTEMS
        SHOW_DISABLED_SUBSYSTEMS VERBOSE_OK SHOW_ZERO_COUNTS
        WEAR_TREND_ENABLED ENABLE_MODEL_IN_ALERTS
    )
    local -a integer_settings=(
        SHORT_TEST_INTERVAL_DAYS SHORT_TEST_MAX_WAIT SHORT_TEST_POLL_INTERVAL
        LONG_TEST_ACCEL_FACTOR LONG_TEST_MIN_INTERVAL_DAYS LONG_TEST_MAX_INTERVAL_DAYS
        LONG_TEST_RISK_LOOKBACK_DAYS LONG_TEST_RISK_THRESHOLD
        LONG_TEST_CRITICAL_MIN_DAYS LONG_TEST_RISK_MIN_DAYS LONG_TEST_NEAR_WINDOW_DAYS
        REPLACEMENT_POH_DROP_THRESHOLD_HOURS REPLACEMENT_POH_DROP_THRESHOLD_HOURS_HDD
        REPLACEMENT_POH_DROP_THRESHOLD_HOURS_SSD REPLACEMENT_POH_DROP_THRESHOLD_HOURS_NVME
        WARN_THRESHOLD_PERCENT CRITICAL_THRESHOLD_PERCENT THRESHOLD NEAR_THRESHOLD_DELTA
        STORAGE_DISCREPANCY_SUSTAIN_RUNS BTRFS_SCRUB_STATE_TTL_DAYS
        BTRFS_TREND_TOP_N BTRFS_TREND_WINDOW_DAYS IO_ERROR_WINDOW_MINUTES
        IO_ERROR_WARN_THRESHOLD IO_ERROR_CRIT_THRESHOLD
        SYSLOG_CURSOR_STARTUP_LOOKBACK_LINES SYSLOG_CURSOR_ROTATION_LOOKBACK_LINES
        NVME_WEAR_REGRESSION_WARN PARITY_SYNC_ERR_WARN PARITY_SYNC_ERR_CRIT
        POH_RESET_CRIT_THRESHOLD SMART_ATTR_TREND_WINDOW_DAYS SMART_ATTR_TREND_TOP_N
        SMART_ATTR_TREND_MIN_DELTA ENDURANCE_DAYSLEFT_TOP_N
        ENDURANCE_DAYSLEFT_ACCEL_FACTOR_PCT ERROR_RATE_TREND_WINDOW_DAYS
        ERROR_RATE_TREND_TOP_N ERROR_RATE_ACCEL_FACTOR_PCT ERROR_RATE_ACCEL_MIN_DELTA
        ERROR_RATE_ACCEL_FACTOR_CORRUPTION ERROR_RATE_ACCEL_MIN_DELTA_CORRUPTION
        ERROR_RATE_ACCEL_FACTOR_GENERATION ERROR_RATE_ACCEL_MIN_DELTA_GENERATION
        SATA_LINK_INSTABILITY_WINDOW_DAYS SATA_LINK_INSTABILITY_STREAK_WARN
        SATA_LINK_INSTABILITY_STREAK_CRIT HISTORY_WINDOW_DAYS SHARE_TOP_N
        HISTORY_SCHEMA_VERSION FORECAST_MIN_SAMPLES FORECAST_HIGH_SAMPLES
        FORECAST_MAX_GAP_DAYS LOG_MAX_DAYS LOG_MAX_COUNT HISTORY_MAX_DAYS
        HISTORY_MAX_LINES LIFECYCLE_ALERT_TOP_N RISK_TOP_N RISK_REPLACE RISK_MONITOR
        ENDURANCE_TREND_WINDOW_DAYS ENDURANCE_TREND_TOP_N ENDURANCE_TREND_MIN_POH_DELTA
        FORECAST_PRECISION_DECIMALS RELOC_WARNING RELOC_CRITICAL PEND_WARNING
        SSD_TEMP_WARNING SSD_TEMP_CRITICAL HDD_TEMP_WARNING HDD_TEMP_CRITICAL
        LOAD_CYCLE_WARN LOAD_CYCLE_CRIT SSD_WEAR_WARN SSD_WEAR_CRIT
        REPORTED_UNC_CRIT CMD_TIMEOUT_WARN CMD_TIMEOUT_CRIT CMD_TIMEOUT_DELTA_WARN
        CMD_TIMEOUT_COOLDOWN_DAYS REALLOC_EVENT_WARN REALLOC_EVENT_CRIT
        END_TO_END_ERR_CRIT SOFT_READ_ERR_WARN NVME_TEMP_WARNING NVME_TEMP_CRITICAL
        NVME_PERCENT_USED_WARN NVME_PERCENT_USED_CRIT WEAR_TREND_WINDOW_DAYS
        WEAR_TREND_TOP_N WEAR_DAYS_LEFT_WARN WEAR_DAYS_LEFT_CRIT
        WRITER_WEEKLY_WARN_PCT WRITER_WEEKLY_CRIT_PCT WRITER_TIER_MODERATE_PCT
        UNSAFE_SDWN_DELTA_WARN UNSAFE_SDWN_ABSOLUTE_MIN UNSAFE_SDWN_COOLDOWN_DAYS
        NVME_AVAIL_SPARE_WARN NVME_ERR_LOG_DELTA_WARN NVME_ERR_LOG_DELTA_CRIT
        NVME_PCIE_CORR_DELTA_WARN NVME_PCIE_CORR_DELTA_CRIT
        NVME_PCIE_UNC_DELTA_WARN NVME_PCIE_UNC_DELTA_CRIT
        NVME_THERM_T1_DELTA_WARN NVME_THERM_T2_DELTA_WARN
        NVME_WARN_TEMP_TIME_DELTA_WARN NVME_CRIT_TEMP_TIME_DELTA_WARN
        SNAPSHOT_WARN SNAPSHOT_CRIT BTRFS_DEV_ERR_WARN_DELTA BTRFS_DEV_ERR_CRIT_DELTA
        BTRFS_DEV_CORR_WARN_DELTA BTRFS_DEV_CORR_CRIT_DELTA
        BTRFS_ERR_BURST_WARN_RATIO BTRFS_ERR_BURST_CRIT_RATIO
        XFS_PROC_WARN_DELTA XFS_PROC_CRIT_DELTA XFS_ERR_BURST_WARN_RATIO
        XFS_ERR_BURST_CRIT_RATIO BURST_WARN_BOOST BURST_CRIT_BOOST
        HDD_POH_WARN_HOURS HDD_POH_CRIT_HOURS SSD_POH_WARN_HOURS SSD_POH_CRIT_HOURS
        NVME_POH_WARN_HOURS NVME_POH_CRIT_HOURS TBW_DAYS_WARN TBW_DAYS_CRIT
        TBW_WARN_TB TBW_CONSUMED_WARN TBW_CONSUMED_CRIT
        W_SEV_CRIT W_SEV_WARN W_PENDING W_UNCORR W_REALLOC W_REALLOC_EVENTS
        W_CMD_TIMEOUT W_CRC W_SSD_LIFE W_NVME_WEAR W_NVME_ERR_LOG
        W_NVME_PCIE_CORR W_NVME_PCIE_UNC W_NVME_THERM_TRANS W_NVME_TEMP_TIME
        W_TEMP W_E2E W_SOFT_READ W_NVME_RO W_NVME_REL W_AGE_NEAR
        W_POH_HDD W_POH_SSD W_POH_NVME W_BTRFS_DEV_ERR W_XFS_META_ERR
        W_SATA_LINK_DOWN W_SELFTEST_CRIT W_SELFTEST_WARN W_TBW_CONS_WARN
        W_TBW_CONS_CRIT
    )
    local -a number_settings=(
        STORAGE_DISCREPANCY_MIN_DIFF ENDURANCE_DAYSLEFT_ACCEL_MIN_DELTA
        FORECAST_MIN_SPAN_DAYS FORECAST_HIGH_SPAN_DAYS FORECAST_STALE_AFTER_DAYS
        TEMP_RATE_WARN_C_PER_DAY TEMP_RATE_CRIT_C_PER_DAY TEMP_RATE_MIN_SPAN_DAYS
        WEAR_STABLE_MIN_RATE
    )
    local -a percent_settings=(
        WARN_THRESHOLD_PERCENT CRITICAL_THRESHOLD_PERCENT THRESHOLD NEAR_THRESHOLD_DELTA
        LONG_TEST_RISK_THRESHOLD STORAGE_DISCREPANCY_MIN_DIFF
        SSD_WEAR_WARN SSD_WEAR_CRIT NVME_PERCENT_USED_WARN NVME_PERCENT_USED_CRIT
        NVME_AVAIL_SPARE_WARN TBW_CONSUMED_WARN TBW_CONSUMED_CRIT
        RISK_MONITOR RISK_REPLACE
    )
    local -a positive_integer_settings=(
        LONG_TEST_ACCEL_FACTOR IO_ERROR_WINDOW_MINUTES
        SYSLOG_CURSOR_STARTUP_LOOKBACK_LINES SYSLOG_CURSOR_ROTATION_LOOKBACK_LINES
        HISTORY_WINDOW_DAYS HISTORY_SCHEMA_VERSION FORECAST_MIN_SAMPLES
        FORECAST_HIGH_SAMPLES FORECAST_MAX_GAP_DAYS
    )
    local -a ordered_pairs=(
        LONG_TEST_MIN_INTERVAL_DAYS:LONG_TEST_MAX_INTERVAL_DAYS
        WARN_THRESHOLD_PERCENT:CRITICAL_THRESHOLD_PERCENT
        IO_ERROR_WARN_THRESHOLD:IO_ERROR_CRIT_THRESHOLD
        PARITY_SYNC_ERR_WARN:PARITY_SYNC_ERR_CRIT
        SATA_LINK_INSTABILITY_STREAK_WARN:SATA_LINK_INSTABILITY_STREAK_CRIT
        FORECAST_MIN_SAMPLES:FORECAST_HIGH_SAMPLES
        FORECAST_MIN_SPAN_DAYS:FORECAST_HIGH_SPAN_DAYS
        RISK_MONITOR:RISK_REPLACE
        TEMP_RATE_WARN_C_PER_DAY:TEMP_RATE_CRIT_C_PER_DAY
        RELOC_WARNING:RELOC_CRITICAL CMD_TIMEOUT_WARN:CMD_TIMEOUT_CRIT
        REALLOC_EVENT_WARN:REALLOC_EVENT_CRIT SSD_TEMP_WARNING:SSD_TEMP_CRITICAL
        HDD_TEMP_WARNING:HDD_TEMP_CRITICAL LOAD_CYCLE_WARN:LOAD_CYCLE_CRIT
        SSD_WEAR_CRIT:SSD_WEAR_WARN NVME_TEMP_WARNING:NVME_TEMP_CRITICAL
        NVME_PERCENT_USED_WARN:NVME_PERCENT_USED_CRIT
        WEAR_DAYS_LEFT_CRIT:WEAR_DAYS_LEFT_WARN
        WRITER_TIER_MODERATE_PCT:WRITER_WEEKLY_WARN_PCT
        WRITER_WEEKLY_WARN_PCT:WRITER_WEEKLY_CRIT_PCT
        NVME_ERR_LOG_DELTA_WARN:NVME_ERR_LOG_DELTA_CRIT
        NVME_PCIE_CORR_DELTA_WARN:NVME_PCIE_CORR_DELTA_CRIT
        NVME_PCIE_UNC_DELTA_WARN:NVME_PCIE_UNC_DELTA_CRIT
        SNAPSHOT_WARN:SNAPSHOT_CRIT BTRFS_DEV_ERR_WARN_DELTA:BTRFS_DEV_ERR_CRIT_DELTA
        BTRFS_DEV_CORR_WARN_DELTA:BTRFS_DEV_CORR_CRIT_DELTA
        BTRFS_ERR_BURST_WARN_RATIO:BTRFS_ERR_BURST_CRIT_RATIO
        XFS_PROC_WARN_DELTA:XFS_PROC_CRIT_DELTA
        XFS_ERR_BURST_WARN_RATIO:XFS_ERR_BURST_CRIT_RATIO
        BURST_WARN_BOOST:BURST_CRIT_BOOST HDD_POH_WARN_HOURS:HDD_POH_CRIT_HOURS
        SSD_POH_WARN_HOURS:SSD_POH_CRIT_HOURS NVME_POH_WARN_HOURS:NVME_POH_CRIT_HOURS
        TBW_DAYS_CRIT:TBW_DAYS_WARN TBW_CONSUMED_WARN:TBW_CONSUMED_CRIT
    )

    for setting in "${boolean_settings[@]}"; do
        validate_boolean_setting "$setting"
    done
    for setting in "${integer_settings[@]}"; do
        validate_nonnegative_integer_setting "$setting"
    done
    for setting in "${number_settings[@]}"; do
        validate_nonnegative_number_setting "$setting"
    done
    validate_positive_number_setting DEFAULT_SSD_ENDURANCE_PER_TB
    for setting in "${percent_settings[@]}"; do
        validate_percent_setting "$setting"
    done
    for setting in "${positive_integer_settings[@]}"; do
        validate_positive_integer_setting "$setting"
    done
    for pair in "${ordered_pairs[@]}"; do
        validate_ordered_pair "${pair%%:*}" "${pair#*:}"
    done

    validate_absolute_path_setting LOG_DIR
    validate_absolute_path_setting LOCK_FILE
    validate_absolute_path_setting NOTIFY_BIN
    validate_absolute_path_setting IO_ERROR_LOG_FILE

    [[ -z "${LONG_TEST_DECISION:-}" ]] ||
        configuration_error "LONG_TEST_DECISION is runtime state and must start empty"
    for setting in XFS_PROC_KEYS XFS_PROC_KEYS_EXCLUDE; do
        if [[ "$(configuration_value "$setting" 2>/dev/null || true)" =~ [^A-Za-z0-9_[:space:]-] ]]; then
            configuration_error \
                "$setting may contain only XFS key names separated by whitespace"
        fi
    done

    case "${SHOW_SUBSYSTEMS_BLOCK:-}" in
        auto|always|never) ;;
        *) configuration_error \
            "SHOW_SUBSYSTEMS_BLOCK must be auto, always, or never (found '${SHOW_SUBSYSTEMS_BLOCK:-unset}')" ;;
    esac

    if [[ "${HISTORY_SCHEMA_VERSION:-}" =~ ^[0-9]+$ ]] &&
       (( HISTORY_SCHEMA_VERSION != 3 ))
    then
        configuration_error "HISTORY_SCHEMA_VERSION must remain 3 for this script version"
    fi
    if [[ "${FORECAST_PRECISION_DECIMALS:-}" =~ ^[0-9]+$ ]] &&
       (( FORECAST_PRECISION_DECIMALS > 6 ))
    then
        configuration_error "FORECAST_PRECISION_DECIMALS must not exceed 6"
    fi
    if [[ "${THRESHOLD:-}" =~ ^[0-9]+$ ]] && (( THRESHOLD == 0 )); then
        configuration_error "THRESHOLD must be greater than zero"
    fi
    if [[ "${SHORT_TEST_POLL:-}" == "1" ]]; then
        [[ "${SHORT_TEST_MAX_WAIT:-}" =~ ^[1-9][0-9]*$ ]] ||
            configuration_error "SHORT_TEST_MAX_WAIT must be positive when SHORT_TEST_POLL=1"
        [[ "${SHORT_TEST_POLL_INTERVAL:-}" =~ ^[1-9][0-9]*$ ]] ||
            configuration_error "SHORT_TEST_POLL_INTERVAL must be positive when SHORT_TEST_POLL=1"
    fi

    if ! declare -p POOL_EXCLUDES 2>/dev/null | grep -q '^declare -a'; then
        configuration_error "POOL_EXCLUDES must be an indexed Bash array"
    else
        for excluded_pool in "${POOL_EXCLUDES[@]}"; do
            if [[ -z "$excluded_pool" || "$excluded_pool" == */* ]]; then
                configuration_error \
                    "POOL_EXCLUDES entries must be non-empty pool names without '/': '$excluded_pool'"
            fi
        done
    fi

    validate_model_rule_block TBW_MODEL_RULES tbw
    validate_model_rule_block POH_MODEL_RULES poh
    validate_model_rule_block QUIRK_MWI_RULES quirk

    if [[ "${ENABLE_BTRFS_SCRUB:-}" == "0" && "${FIRST_RUN_FORCE:-}" == "1" ]]; then
        configuration_warning \
            "FIRST_RUN_FORCE=1 may start a one-time baseline Btrfs scrub even though ENABLE_BTRFS_SCRUB=0"
    fi

    if (( CONFIG_ERROR_COUNT > 0 )); then
        log "CONFIG" "ERROR" \
            "Configuration validation failed with $CONFIG_ERROR_COUNT error(s) and $CONFIG_WARNING_COUNT warning(s)"
        return 1
    fi
    log "CONFIG" "INFO" \
        "Configuration validation passed with $CONFIG_WARNING_COUNT warning(s)"
    return 0
}

dependency_error() {
    DEPENDENCY_ERROR_COUNT=$((DEPENDENCY_ERROR_COUNT + 1))
    log "DEPENDENCY" "ERROR" "$*"
}

dependency_warning() {
    DEPENDENCY_WARNING_COUNT=$((DEPENDENCY_WARNING_COUNT + 1))
    log "DEPENDENCY" "WARN" "$*"
}

validate_runtime_dependencies() {
    local mode="${1:-monitor}" command_name
    local -a required_commands

    DEPENDENCY_ERROR_COUNT=0
    DEPENDENCY_WARNING_COUNT=0

    if [[ "$mode" == "self-test" ]]; then
        required_commands=(awk grep mktemp mv rm sed sort wc)
    else
        required_commands=(
            awk basename cat cksum cp cut date df dirname dmesg find findmnt
            flock grep head lsblk mkdir mktemp mount mountpoint mv readlink rm
            sed sha1sum sleep smartctl sort stat tail tr wc
        )
    fi

    for command_name in "${required_commands[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 ||
            dependency_error "Required command is unavailable: $command_name"
    done

    if [[ "$mode" != "self-test" ]]; then
        if [[ "${ENABLE_BTRFS_SCRUB:-0}" == "1" ||
              "${FIRST_RUN_FORCE:-0}" == "1" ||
              "${ENABLE_BTRFS_DEVICE_STATS:-0}" == "1" ||
              "${BTRFS_DEV_TREND_ENABLED:-0}" == "1" ]] &&
           ! command -v btrfs >/dev/null 2>&1
        then
            dependency_error "btrfs is required by the enabled Btrfs monitoring settings"
        fi
        if [[ "${ENABLE_XFS_CHECK:-0}" == "1" ]] &&
           ! command -v xfs_repair >/dev/null 2>&1
        then
            dependency_error "xfs_repair is required when ENABLE_XFS_CHECK=1"
        fi
        command -v hdparm >/dev/null 2>&1 ||
            dependency_warning "hdparm is unavailable; standby detection will use smartctl -n"
        if [[ ! -x "$NOTIFY_BIN" ]] && ! command -v logger >/dev/null 2>&1; then
            dependency_warning \
                "Neither the Unraid notify helper nor logger is available; notifications cannot be delivered"
        fi

        if command -v date >/dev/null 2>&1 &&
           [[ "$(date -d '1970-01-02 00:00:00 UTC' +%s 2>/dev/null || true)" != "86400" ]]
        then
            dependency_error "GNU-compatible date -d support is required"
        fi
        if command -v stat >/dev/null 2>&1 &&
           ! stat -c '%d %i %s' / >/dev/null 2>&1
        then
            dependency_error "GNU-compatible stat -c support is required"
        fi
        if command -v readlink >/dev/null 2>&1 &&
           [[ "$(readlink -f / 2>/dev/null || true)" != "/" ]]
        then
            dependency_error "readlink -f support is required"
        fi
        if command -v find >/dev/null 2>&1 &&
           ! find /tmp -maxdepth 0 -printf '' >/dev/null 2>&1
        then
            dependency_error "GNU-compatible find -printf support is required"
        fi
    fi

    if (( DEPENDENCY_ERROR_COUNT > 0 )); then
        log "DEPENDENCY" "ERROR" \
            "Dependency validation failed with $DEPENDENCY_ERROR_COUNT error(s) and $DEPENDENCY_WARNING_COUNT warning(s)"
        return 1
    fi
    log "DEPENDENCY" "INFO" \
        "Dependency validation passed with $DEPENDENCY_WARNING_COUNT warning(s)"
    return 0
}

print_usage() {
    cat <<'USAGE'
Disk Health Monitor for Unraid v2.8

Usage:
  health_monitoring.sh                 Run normal monitoring
  health_monitoring.sh --check-config  Validate configuration only
  health_monitoring.sh --diagnostics   Run read-only environment diagnostics
  health_monitoring.sh --self-test     Run built-in regression fixtures in /tmp
  health_monitoring.sh --version       Print the script version
  health_monitoring.sh --help          Show this help

The three validation modes do not run SMART commands against disks, start
tests or scrubs, write monitoring state, advance the syslog cursor, send
notifications, or spin up disks.
USAGE
}

parse_arguments() {
    if (( $# > 1 )); then
        printf 'Only one mode option may be supplied.\n' >&2
        return 2
    fi
    case "${1:-}" in
        "")             RUN_MODE="monitor" ;;
        --check-config) RUN_MODE="check-config" ;;
        --diagnostics)  RUN_MODE="diagnostics" ;;
        --self-test)    RUN_MODE="self-test" ;;
        --version)      RUN_MODE="version" ;;
        --help|-h)      RUN_MODE="help" ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            print_usage >&2
            return 2
            ;;
    esac
}

diagnostic_result() {
    local level="$1" label="$2" detail="$3"
    printf '[%-4s] %-26s %s\n' "$level" "$label" "$detail"
}

nearest_existing_parent() {
    local path="$1" parent

    parent="$path"
    while [[ ! -e "$parent" && "$parent" != "/" ]]; do
        parent="$(dirname -- "$parent")"
    done
    [[ -d "$parent" ]] || return 1
    printf '%s\n' "$parent"
}

run_diagnostics() {
    local failures=0 warnings=0 config_status=0 dependency_status=0
    local parent device_rows

    printf 'Disk Health Monitor for Unraid v2.8 - read-only diagnostics\n'
    printf 'No disk SMART reads, tests, scrubs, state writes, cursor updates, or notifications will occur.\n\n'

    if validate_configuration; then
        diagnostic_result PASS "Configuration" "valid ($CONFIG_WARNING_COUNT warning(s))"
    else
        config_status=1
        failures=$((failures + 1))
        diagnostic_result FAIL "Configuration" "$CONFIG_ERROR_COUNT error(s)"
    fi

    if validate_runtime_dependencies diagnostics; then
        diagnostic_result PASS "Dependencies" "available ($DEPENDENCY_WARNING_COUNT warning(s))"
    else
        dependency_status=1
        failures=$((failures + 1))
        diagnostic_result FAIL "Dependencies" "$DEPENDENCY_ERROR_COUNT error(s)"
    fi

    diagnostic_result INFO "Bash" "$BASH_VERSION"
    diagnostic_result INFO "Kernel" "$(uname -sr 2>/dev/null || printf 'unknown')"

    if [[ -d "$LOG_DIR" ]]; then
        if [[ -w "$LOG_DIR" ]]; then
            diagnostic_result PASS "Log directory" "$LOG_DIR is writable"
        else
            failures=$((failures + 1))
            diagnostic_result FAIL "Log directory" "$LOG_DIR is not writable"
        fi
    else
        parent=$(nearest_existing_parent "$LOG_DIR" 2>/dev/null || true)
        if [[ -n "$parent" && -w "$parent" ]]; then
            diagnostic_result PASS "Log directory parent" "$parent can create $LOG_DIR"
        else
            failures=$((failures + 1))
            diagnostic_result FAIL "Log directory parent" "no writable parent for $LOG_DIR"
        fi
    fi

    parent=$(nearest_existing_parent "$(dirname -- "$LOCK_FILE")" 2>/dev/null || true)
    if [[ -n "$parent" && -w "$parent" ]]; then
        diagnostic_result PASS "Lock directory" "$parent is writable"
    else
        failures=$((failures + 1))
        diagnostic_result FAIL "Lock directory" "no writable parent for $LOCK_FILE"
    fi

    if [[ -x "$NOTIFY_BIN" ]]; then
        diagnostic_result PASS "Unraid notification" "$NOTIFY_BIN is executable"
    elif command -v logger >/dev/null 2>&1; then
        warnings=$((warnings + 1))
        diagnostic_result WARN "Unraid notification" "notify helper missing; logger fallback is available"
    else
        warnings=$((warnings + 1))
        diagnostic_result WARN "Unraid notification" "notify helper and logger are unavailable"
    fi

    if [[ -r "$IO_ERROR_LOG_FILE" ]]; then
        diagnostic_result PASS "Syslog source" "$IO_ERROR_LOG_FILE is readable"
    else
        warnings=$((warnings + 1))
        diagnostic_result WARN "Syslog source" "$IO_ERROR_LOG_FILE unavailable; dmesg fallback will be used"
    fi

    if [[ -r /var/local/emhttp/disks.ini && -r /var/local/emhttp/var.ini ]]; then
        diagnostic_result PASS "Unraid metadata" "disks.ini and var.ini are readable"
    else
        warnings=$((warnings + 1))
        diagnostic_result WARN "Unraid metadata" "one or more /var/local/emhttp metadata files are unavailable"
    fi

    if mountpoint -q /mnt/user 2>/dev/null; then
        diagnostic_result PASS "Unraid user share" "/mnt/user is mounted"
    else
        warnings=$((warnings + 1))
        diagnostic_result WARN "Unraid user share" "/mnt/user is not mounted"
    fi

    device_rows=$(lsblk -b -dn -o NAME,SIZE,ROTA,TYPE 2>/dev/null |
        awk '$4=="disk" && ($1 ~ /^sd[a-z]+$/ || $1 ~ /^nvme[0-9]+n[0-9]+$/) {count++} END {print count+0}')
    diagnostic_result INFO "Block-device inventory" "${device_rows:-0} candidate disk(s), read from lsblk only"

    printf '\nDiagnostic summary: failures=%d warnings=%d config_status=%d dependency_status=%d\n' \
        "$failures" "$((warnings + CONFIG_WARNING_COUNT + DEPENDENCY_WARNING_COUNT))" \
        "$config_status" "$dependency_status"
    (( failures == 0 ))
}

self_test_result() {
    local passed="$1" name="$2" detail="${3:-}"

    SELF_TEST_TOTAL=$((SELF_TEST_TOTAL + 1))
    if (( passed == 1 )); then
        SELF_TEST_PASSED=$((SELF_TEST_PASSED + 1))
        printf '[PASS] %s\n' "$name"
    else
        SELF_TEST_FAILED=$((SELF_TEST_FAILED + 1))
        printf '[FAIL] %s%s\n' "$name" "${detail:+ - $detail}"
    fi
}

run_regression_tests() (
    local fixture_dir="" history_file source_file chunk_file actual count
    SELF_TEST_TOTAL=0
    SELF_TEST_PASSED=0
    SELF_TEST_FAILED=0

    fixture_dir=$(mktemp -d /tmp/health_monitoring.selftest.XXXXXX) || {
        printf '[FAIL] Unable to create self-test fixture directory\n'
        return 1
    }
    trap '[[ -z "$fixture_dir" || "$fixture_dir" != /tmp/health_monitoring.selftest.* ]] || rm -rf -- "$fixture_dir"' EXIT

    printf 'Disk Health Monitor for Unraid v2.8 - built-in regression tests\n'
    printf 'Fixtures are isolated under %s and removed automatically.\n\n' "$fixture_dir"

    actual=$(safe_state_name '/dev/disk/by-id/ata-Test Drive')
    if [[ "$actual" == "disk_by-id_ata-Test_Drive" ]]; then
        self_test_result 1 "Stable state filename sanitization"
    else
        self_test_result 0 "Stable state filename sanitization" "found '$actual'"
    fi

    actual=$(history_field_value 'temp=31 captured_epoch=1786800000 schema=3' temp 2>/dev/null || true)
    if [[ "$actual" == "31" ]]; then
        self_test_result 1 "Normalized history field parsing"
    else
        self_test_result 0 "Normalized history field parsing" "found '$actual'"
    fi

    actual=$(history_record_epoch '2026-08-16' 'temp=31 captured_epoch=1786800000 schema=3' 2>/dev/null || true)
    if [[ "$actual" == "1786800000" ]]; then
        self_test_result 1 "Captured history timestamp parsing"
    else
        self_test_result 0 "Captured history timestamp parsing" "found '$actual'"
    fi

    local confidence_cases=(
        '2 10 0 1|INSUFFICIENT'
        '3 2 4 1|STALE'
        '3 2 0 15|LOW'
        '3 2 0 1|MEDIUM'
        '7 7 0 1|HIGH'
    ) case_data expected
    local confidence_failures=0
    for case_data in "${confidence_cases[@]}"; do
        expected="${case_data#*|}"
        actual=$(forecast_confidence ${case_data%%|*})
        [[ "$actual" == "$expected" ]] || confidence_failures=$((confidence_failures + 1))
    done
    if (( confidence_failures == 0 )); then
        self_test_result 1 "Forecast confidence classification"
    else
        self_test_result 0 "Forecast confidence classification" "$confidence_failures case(s) failed"
    fi

    if forecast_confidence_is_actionable MEDIUM &&
       forecast_confidence_is_actionable HIGH &&
       ! forecast_confidence_is_actionable LOW
    then
        self_test_result 1 "Forecast actionability gate"
    else
        self_test_result 0 "Forecast actionability gate"
    fi

    history_file="$fixture_dir/daily.log"
    printf 'malformed legacy row\n2026-08-15 disk_a temp=29 captured_epoch=1 schema=3\n' > "$history_file"
    if atomic_replace_daily_history "$history_file" 2026-08-15 \
           '2026-08-15 disk_a temp=30 captured_epoch=2 schema=3' \
           '2026-08-15 disk_b temp=32 captured_epoch=2 schema=3' &&
       atomic_upsert_daily_history "$history_file" 2026-08-15 disk_a \
           '2026-08-15 disk_a temp=31 captured_epoch=3 schema=3'
    then
        count=$(awk '$1=="2026-08-15" && $2=="disk_a" {count++} END {print count+0}' "$history_file")
        if [[ "$count" == "1" ]] &&
           grep -q '^2026-08-15 disk_a temp=31 ' "$history_file" &&
           ! grep -q '^malformed ' "$history_file"
        then
            self_test_result 1 "Atomic daily history replacement and upsert"
        else
            self_test_result 0 "Atomic daily history replacement and upsert" "unexpected fixture contents"
        fi
    else
        self_test_result 0 "Atomic daily history replacement and upsert" "helper returned failure"
    fi

    source_file="$fixture_dir/source.log"
    chunk_file="$fixture_dir/chunk.log"
    printf 'one\ntwo\nthree\nfour\n' > "$source_file"
    : > "$chunk_file"
    if append_syslog_line_range "$source_file" 2 3 "$chunk_file" &&
       [[ "$(awk '{printf "%s|", $0}' "$chunk_file")" == "two|three|" ]]
    then
        self_test_result 1 "Bounded syslog line-range extraction"
    else
        self_test_result 0 "Bounded syslog line-range extraction"
    fi

    printf '\nSelf-test summary: passed=%d failed=%d total=%d\n' \
        "$SELF_TEST_PASSED" "$SELF_TEST_FAILED" "$SELF_TEST_TOTAL"
    (( SELF_TEST_FAILED == 0 ))
)


main() {
    local exit_code

    parse_arguments "$@" || return $?
    case "$RUN_MODE" in
        help)
            print_usage
            return 0
            ;;
        version)
            printf 'Disk Health Monitor for Unraid v2.8\n'
            return 0
            ;;
        check-config)
            if validate_configuration; then
                printf 'Configuration is valid (%d warning(s)).\n' "$CONFIG_WARNING_COUNT"
                return 0
            fi
            return 1
            ;;
        diagnostics)
            run_diagnostics
            return $?
            ;;
        self-test)
            validate_configuration || return 1
            validate_runtime_dependencies self-test || return 1
            run_regression_tests
            return $?
            ;;
    esac

    # Normal monitoring validates everything before acquiring the lock or
    # creating logs/state. A configuration failure therefore has no persistent
    # side effects.
    validate_configuration || return 1
    validate_runtime_dependencies monitor || return 1

    if ! acquire_lock; then
        return 0
    fi

    trap 'exit_code=$?; cleanup "$exit_code"' EXIT
    trap 'handle_signal INT' INT
    trap 'handle_signal TERM' TERM

    initialize_runtime || return 1

    log "RUN" "INFO" "Starting Unraid disk health monitoring"

    cache_lsblk_all
    discover_device_inventory || return 1
    migrate_device_identity_histories || true
    load_persistent_state
    parity_state || true
    build_mount_device_map

    log "SMART" "INFO" \
        "Collecting SMART health (short-test interval=${SHORT_TEST_INTERVAL_DAYS}d, automatic spin-up=${SMART_ALLOW_SPINUP})"
    collect_smart_health

    log "BTRFS" "INFO" "Assessing scrub status"
    monitor_btrfs
    check_btrfs_snapshots

    log "XFS" "INFO" "Assessing filesystem metadata health"
    monitor_xfs

    log "CAPACITY" "INFO" "Collecting array, pool, and disk utilization"
    build_storage_and_disk_lines
    evaluate_capacity_alerts
    evaluate_per_mount_thresholds
    discover_parity_and_status

    log "BTRFS" "INFO" "Collecting non-destructive device statistics"
    collect_btrfs_device_stats

    log "XFS" "INFO" "Collecting XFS activity counters"
    collect_xfs_proc_stats

    log "IO" "INFO" "Scanning syslog once for disk I/O errors"
    scan_syslog_disk_errors

    log "CAPACITY" "INFO" "Updating growth forecasts and validation"
    capacity_forecast_and_export
    validate_storage_metrics
    compute_share_breakdown

    log "ENDURANCE" "INFO" "Updating TBW and heavy-writer forecasts"
    tbw_forecast_and_heavy_writers
    detect_counter_resets

    # Trend analysis can raise findings, so it must complete before canonical
    # risk, lifecycle classification, and alert rendering.
    log "TREND" "INFO" "Compiling trend analytics"
    build_trend_section

    log "RISK" "INFO" "Computing canonical risk and lifecycle state"
    compute_risk_and_lifecycle
    materialize_alerts_from_findings

    log "REPORT" "INFO" "Finalizing alert and summary sections"
    build_disk_health_summary
    persist_risk_tier_history
    build_health_alerts
    build_subsystem_lines
    build_subject
    compose_notification

    log "NOTIFY" "INFO" \
        "Sending consolidated notification (severity=$FINAL_NOTIFICATION_SEVERITY, critical=${#ALERT_CRIT[@]}, warning=${#ALERT_WARN[@]})"
    notify_unraid \
        "${SUBJECT:-Disk Health Summary}" \
        "$NOTIFY_BODY" \
        "$FINAL_NOTIFICATION_SEVERITY"

    persist_all_state
    prune_history_files
    prune_old_run_logs

    return 0
}


main "$@"
