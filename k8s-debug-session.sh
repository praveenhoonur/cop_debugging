#!/usr/bin/env bash
#
# k8s-debug-session.sh
#
# Automates a privileged Kubernetes debugging session:
#   1. Opens a single persistent `sudo su - core` shell.
#   2. Inside that SAME shell, runs `debugaw10` to enable custom k8s
#      shortcut aliases/functions (kgp, kgs, etc.).
#   3. Runs a predefined block of commands (inline default below, or supplied
#      via an external file with -f) in that SAME shell, so the aliases/
#      functions/env vars set by debugaw10 remain available. Each command is
#      preceded by a "STEP: ..." heading (printed via the `step` helper) that
#      explains what it does, making the log easy to scan.
#   4. Captures all stdout+stderr of the whole session to a timestamped log
#      file while also streaming it live to the terminal.
#   5. Also collects individual pod logs (from `lspodnr`, `lspod | grep ivt`,
#      and `lspod | grep cop-upgrade-tools`, i.e. not-ready pods, "ivt"
#      pods, and COP upgrade-tools pods) into a timestamped
#      /tmp/coplogs-<timestamp>/ directory, each selector's pod logs in its
#      own subdirectory (lspodnr/, lspod_ivt/, lspod_cop_upgrade_tools/),
#      copies the full session log into it too, and tars/gzips the whole
#      directory for easy handoff (e.g. attaching to a support case).
#
# Usage:
#   ./k8s-debug-session.sh [-f commands-file.sh] [-l log-dir] [-u core] [-h]
#
# Options:
#   -f, --commands-file <file>  External file of bash commands to run after
#                                debugaw10 initializes (in the same session).
#                                If omitted, the built-in default command
#                                block is used (see DEFAULT_COMMANDS below).
#   -l, --log-dir <dir>         Directory to write the session log into.
#                                Default: /tmp
#   -u, --user <user>           Remote user to `su` into. Default: core
#   -h, --help                  Show this help and exit
#
# Customizing what runs:
#   Edit the DEFAULT_COMMANDS block in Section 2 below directly in this
#   file, or pass your own file via -f, to change the predefined commands
#   that run after debugaw10 initializes.
#
# Notes:
#   - Requires passwordless (or interactive) sudo rights to `su - <user>`.
#   - Safe to re-run: each run creates its own uniquely-timestamped log file
#     and temp script, and makes no persistent changes to the system.
#   - Exit codes:
#       0  session completed, debugaw10 initialized OK
#       1  usage / argument error
#       2  sudo/su failed to start the target user's shell
#       3  debugaw10 failed to initialize
#       4  the session shell exited with a non-zero status for another reason

set -uo pipefail

# ----------------------------------------------------------------------------
# Section 1: Defaults & argument parsing
# ----------------------------------------------------------------------------
LOG_DIR="/tmp"
TARGET_USER="core"
COMMANDS_FILE=""

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--commands-file) COMMANDS_FILE="$2"; shift 2 ;;
    -l|--log-dir)        LOG_DIR="$2"; shift 2 ;;
    -u|--user)           TARGET_USER="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -n "$COMMANDS_FILE" && ! -f "$COMMANDS_FILE" ]]; then
  echo "ERROR: commands file '$COMMANDS_FILE' not found." >&2
  exit 1
fi

# ----------------------------------------------------------------------------
# Section 2: Predefined command block (used only when no -f/--commands-file
# is supplied)
#
# This is the exact set of Kubernetes/COP sanity-check commands to run once
# debugaw10 has initialized the shortcut functions (awctl, lspod, podcount,
# noderesource, restartcount, etc. come from debugaw10/bash_rc).
#
# Each command is preceded by a heading (via the `step` helper defined at
# the top of the generated inner script) explaining what it does, so the
# log is easy to read/scan even though everything runs in one shell.
#
# Edit this block directly (or pass your own file via -f) to customize
# what runs.
# ----------------------------------------------------------------------------
read -r -d '' DEFAULT_COMMANDS <<'EOC' || true
echo "--- Running default predefined command block ---"

step "awctl status: COP appliance/cluster status summary"
awctl status

step "awctl version: COP/appliance software version info"
awctl version

step "kubectl top nodes: per-node CPU/memory usage"
kubectl top nodes

step "kubectl get nodes -o wide: node list with IPs, OS, kernel, runtime"
kubectl get nodes -o wide

step "kubectl get events -n kube-system: recent kube-system events, oldest first"
kubectl get events -n kube-system --sort-by=.lastTimestamp

step "Per-node containerd image count (SSH to each node, requires passwordless SSH/sudo from core)"
for i in $(kubectl get nodes | grep -v NAME | awk '{print $1}' | xargs); do
  echo "$i"
  ssh "$i" "sudo ctr -n k8s.io i ls | wc -l"
done

step "kubectl get componentstatuses: control-plane component health"
kubectl get componentstatuses

step "lspodnr: pods that are NOT Running/Completed (not-ready)"
lspodnr

step "lspod | grep ivt: pods matching 'ivt' (e.g. install/validation-test pods)"
lspod | grep ivt

step "lspod | grep cop-upgrade-tools: pods matching 'cop-upgrade-tools'"
lspod | grep cop-upgrade-tools

step "lspod: all pods, all namespaces"
lspod

step "podcount: cluster-wide pod count summary"
podcount

step "noderesource: node resource usage, excluding containerd rows"
noderesource | grep -v containerd

step "restartcount: pods sorted by restart count, descending"
restartcount

step "cedevicecount: count of devices connected/onboarded to the cluster"
cedevicecount

step "cependinglist: devices pending onboarding/activation"
cependinglist

step "cewhitelist: device whitelist entries"
cewhitelist

step "cebootstrap: device bootstrap status"
cebootstrap

step "cebootstrapfailure: devices that failed bootstrap"
cebootstrapfailure

step "Per-node /mnt/* disk usage (SSH to each node, requires passwordless SSH/sudo from core)"
for i in `lsnodes | awk '{print $1}'`; do ssh $i "hostname && sudo du -sh /mnt/*"; done
EOC

# ----------------------------------------------------------------------------
# Section 2c: coplogs collection block. Always runs (regardless of -f),
# inside the SAME debugaw10 session, after the predefined commands above.
# For each pod matched by `lspodnr`, `lspod | grep ivt`, and
# `lspod | grep cop-upgrade-tools`, fetch its `kubectl logs` (all
# containers) into its own subdirectory under $COPLOGS_DIR (one
# subdirectory per selector, per requirement 10), plus save the raw
# selector output for reference. $COPLOGS_DIR is substituted in when the
# inner script is generated (Section 4).
# ----------------------------------------------------------------------------
read -r -d '' COLLECT_POD_LOGS <<'EOC' || true
echo ""
echo "--- Collecting pod logs into coplogs directory ---"

collect_pods_from() {
  # $1 = subdirectory name (under $COPLOGS_DIR) to collect this selector's
  # pod logs into; also used as the raw-output filename label.
  # $2 = command string to eval in THIS shell (not a subshell/bash -c), so
  # that lspod/lspodnr (aliases/functions set up by debugaw10) remain
  # available.
  local subdir="$1" cmd="$2"
  local dest_dir="$COPLOGS_DIR/$subdir"
  mkdir -p "$dest_dir"
  local raw_file="$dest_dir/${subdir}_raw.txt"
  eval "$cmd" > "$raw_file" 2>&1
  # Parse "NAMESPACE  NAME  ..." lines (skip header/blank lines, and any
  # echoed-command lines like "kubectl get pod --all-namespaces" that some
  # shortcut functions print before their real table output).
  grep -Ev '^\s*$|^NAMESPACE\b|^kubectl\b' "$raw_file" | awk '{print $1, $2}' | \
  while read -r ns pod; do
    [[ -z "$ns" || -z "$pod" ]] && continue
    # Extra guard: only treat as a real namespace/pod if both fields look
    # like valid Kubernetes resource names (lowercase alnum + - + .),
    # protecting against any other stray non-table lines slipping through.
    if [[ ! "$ns" =~ ^[a-z0-9.-]+$ || ! "$pod" =~ ^[a-z0-9.-]+$ ]]; then
      continue
    fi
    echo "  [$subdir] collecting logs: ns=$ns pod=$pod"
    kubectl logs -n "$ns" "$pod" --all-containers=true --tail=1000 \
      > "$dest_dir/${ns}_${pod}.log" 2>&1
  done
}

collect_pods_from "lspodnr" "lspodnr"
collect_pods_from "lspod_ivt" "lspod | grep ivt"
collect_pods_from "lspod_cop_upgrade_tools" "lspod | grep cop-upgrade-tools"

echo "--- Pod log collection complete: $COPLOGS_DIR ---"
EOC


# ----------------------------------------------------------------------------
# Section 3: Prepare log file (timestamped), log directory, and the
# "coplogs" artifact directory (requirement 9).
#
# COPLOGS_DIR is created here (outer, pre-session context) so it exists
# before the privileged inner session starts, then chmod'd permissively
# since the inner script writes into it as $TARGET_USER (e.g. core), which
# may be a different owner than whoever invoked this script. It's a
# throwaway working directory under /tmp for this run only.
# ----------------------------------------------------------------------------
mkdir -p "$LOG_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/cop_sanity_logs-${TIMESTAMP}.log"

COPLOGS_DIR="/tmp/coplogs-${TIMESTAMP}"
mkdir -p "$COPLOGS_DIR"
chmod 777 "$COPLOGS_DIR"

# ----------------------------------------------------------------------------
# Section 4: Build the inner script that will be fed into `sudo su - <user>`
#
# Everything below runs in ONE continuous shell process inside the su
# session, so aliases/functions/env vars set by debugaw10 stay in scope for
# every subsequent command (no new su/shell is spawned per command).
#
# `shopt -s expand_aliases` is required because this shell is fed via a
# pipe (non-interactive), and bash disables alias expansion for
# non-interactive shells by default.
# ----------------------------------------------------------------------------
INNER_SCRIPT="$(mktemp /tmp/k8s-debug-inner.XXXXXX.sh)"
trap 'rm -f "$INNER_SCRIPT"' EXIT

# A unique marker written as the very first line of output. Its presence in
# the log tells us the su session actually started and began executing our
# script (vs. `sudo`/`su` failing before ever reaching bash) — this is a more
# reliable signal than trying to interpret sudo/su's exit code, which can
# return the same codes (e.g. 1) for both "access denied" and unrelated
# in-session failures.
SESSION_START_MARKER="=== SESSION START:"

{
  echo '#!/usr/bin/env bash'
  echo 'shopt -s expand_aliases'          # enable alias expansion in this non-interactive shell
  echo 'set -u'
  echo ''
  # `step` prints a clear heading before each predefined command runs, so the
  # log/terminal output is easy to scan even though every command executes
  # in this one continuous shell.
  echo '# Prints a heading before each predefined command, for readability.'
  echo 'step() {'
  echo '  echo ""'
  echo '  echo "==============================================================="'
  # shellcheck disable=SC2016  # intentional: $1 expands later, in-session (function argument).
  echo '  echo "STEP: $1"'
  echo '  echo "==============================================================="'
  echo '}'
  echo ''
  # shellcheck disable=SC2016  # intentional: $(date)/$(whoami) must expand
  # later, inside the remote su session, not now while building this script.
  echo "echo \"${SESSION_START_MARKER} \$(date) (user: \$(whoami)) ===\""
  echo ''
  echo 'echo "--- Initializing debugaw10 ---"'
  # `debugaw10` (and other k8s shortcut helpers) are defined as an alias in
  # /etc/bash.bashrc. Bash only auto-sources /etc/bash.bashrc for interactive
  # shells, and this su session is fed via a pipe (non-interactive), so we
  # must source it explicitly here before the alias can be used/expanded.
  # /etc/bash.bashrc also (a) early-returns if $PS1 is unset/empty (it guards
  # itself with `[ -z "$PS1" ] && return`, assuming only interactive shells
  # source it) and (b) references other variables (e.g. $SUDO_USER) without
  # guarding for "set -u" — so we give PS1 a non-empty placeholder value and
  # temporarily disable nounset while sourcing it.
  echo 'if [[ -f /etc/bash.bashrc ]]; then'
  echo '  set +u'
  echo '  PS1="cop-debug-session"'
  echo '  source /etc/bash.bashrc'
  echo '  set -u'
  echo 'fi'
  echo 'debugaw10'
  echo 'DEBUGAW10_RC=$?'
  # shellcheck disable=SC2016  # intentional: $DEBUGAW10_RC expands later, in-session.
  echo 'if [[ $DEBUGAW10_RC -ne 0 ]]; then'
  # shellcheck disable=SC2016  # intentional: $DEBUGAW10_RC expands later, in-session.
  echo '  echo "ERROR: debugaw10 failed to initialize (exit code $DEBUGAW10_RC)" >&2'
  echo '  exit 3'
  echo 'fi'
  echo 'echo "--- debugaw10 initialized OK ---"'
  echo ''
  # COPLOGS_DIR is substituted literally here (outer-script value) so the
  # inner session writes/collects pod logs into the SAME directory the
  # outer script will later tar up in Section 7.
  echo "COPLOGS_DIR='${COPLOGS_DIR}'"
  echo ''
  echo 'echo "--- Running predefined commands ---"'

  # Insert either the external commands file (verbatim, so multi-line
  # constructs like for-loops are preserved) or the built-in default block.
  if [[ -n "$COMMANDS_FILE" ]]; then
    cat "$COMMANDS_FILE"
  else
    echo "$DEFAULT_COMMANDS"
  fi

  echo ''
  # Requirement 9: collect individual pod logs (from `lspodnr`,
  # `lspod | grep ivt`, and `lspod | grep cop-upgrade-tools`) into
  # `lspodnr`) into $COPLOGS_DIR, in the SAME session so lspod/lspodnr
  # aliases/functions are still available. Runs even when -f is used.
  echo "$COLLECT_POD_LOGS"

  echo ''
  # shellcheck disable=SC2016  # intentional: $(date) expands later, in-session.
  echo 'echo "=== SESSION END: $(date) ==="'
} > "$INNER_SCRIPT"

chmod 644 "$INNER_SCRIPT"

# ----------------------------------------------------------------------------
# Section 5: Run the session through `sudo su - <user>`, capturing output
#
# The inner script is executed as a FILE ARGUMENT (`bash "$INNER_SCRIPT"`),
# not piped in via stdin. This matters: if the script were fed over stdin,
# any predefined command that itself reads from stdin mid-run (e.g. `awctl`
# shelling out to `ssh` internally to poll other nodes, or a plain `ssh`
# call without `-n`) would swallow the *rest of the script* as its own
# input and silently truncate the session. Running it as a file keeps the
# process's real stdin (wired to /dev/null below) completely separate from
# the script source, so such commands can't interfere with what runs next.
#
# It's still one continuous, non-interactive login shell for the target
# user — `su -c` just runs a single command (the `bash "$INNER_SCRIPT"`
# invocation) inside that login shell, so debugaw10's
# aliases/functions/env vars stay in scope for every subsequent command,
# same as before. Output is teed to the log file (live to terminal +
# saved), and pipefail lets us recover the real exit code of the su/bash
# process (not of `tee`).
# ----------------------------------------------------------------------------
set -o pipefail
echo "Logging full session output to: $LOG_FILE"

sudo su - "$TARGET_USER" -c "bash '$INNER_SCRIPT'" < /dev/null 2>&1 | tee -a "$LOG_FILE"
SESSION_RC=${PIPESTATUS[0]}


# ----------------------------------------------------------------------------
# Section 6: Classify and report the result
#
# We can't trust exit-code ranges alone to tell "sudo/su failed to start"
# apart from "the in-session script failed" (both can return small codes
# like 1). Instead, check whether the session-start marker made it into the
# log: if it's missing, the su session never actually began.
# ----------------------------------------------------------------------------
SESSION_STARTED=0
if grep -q "$SESSION_START_MARKER" "$LOG_FILE" 2>/dev/null; then
  SESSION_STARTED=1
fi

FINAL_EXIT=0
if [[ $SESSION_RC -eq 0 ]]; then
  echo "Session completed successfully. Log: $LOG_FILE"
  FINAL_EXIT=0
elif [[ $SESSION_STARTED -eq 0 ]]; then
  # The marker never appeared, so `sudo su - <user>` failed before our
  # script even started running (e.g. permission denied, unknown user).
  echo "ERROR: 'sudo su - $TARGET_USER' failed to start the session (exit code $SESSION_RC). See $LOG_FILE" >&2
  FINAL_EXIT=2
elif [[ $SESSION_RC -eq 3 ]]; then
  echo "ERROR: debugaw10 failed to initialize inside the '$TARGET_USER' session. See $LOG_FILE" >&2
  FINAL_EXIT=3
else
  echo "ERROR: session exited with non-zero status ($SESSION_RC). See $LOG_FILE" >&2
  FINAL_EXIT=4
fi

# ----------------------------------------------------------------------------
# Section 7: Package the coplogs artifact bundle (requirement 9)
#
# Copy the full session log into $COPLOGS_DIR (alongside the pod logs
# already collected there by the in-session step), then tar+gzip the whole
# directory for easy handoff. Only attempted if the session actually
# started (otherwise $COPLOGS_DIR may be empty/nonexistent) — skip
# packaging on early sudo/su failures.
# ----------------------------------------------------------------------------
if [[ $SESSION_STARTED -eq 1 ]]; then
  cp -f "$LOG_FILE" "$COPLOGS_DIR/" 2>/dev/null || true
  TAR_FILE="${COPLOGS_DIR}.tar.gz"
  if tar -czf "$TAR_FILE" -C "$(dirname "$COPLOGS_DIR")" "$(basename "$COPLOGS_DIR")"; then
    echo "Coplogs bundle created: $TAR_FILE"
  else
    echo "WARNING: failed to create coplogs tarball from $COPLOGS_DIR" >&2
  fi
else
  echo "Skipping coplogs packaging: session never started."
fi

exit "$FINAL_EXIT"
