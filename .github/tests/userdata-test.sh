#!/bin/bash
# CI test for the scripts in agent-install/linux/userdata, run as root in a
# distro container after linux-test.sh, so the Agent is installed and
# /usr/bin/systemctl records its calls in $SYSTEMCTL_LOG.

set -euo pipefail
USERDATA="$(cd "$(dirname "$0")/../.." && pwd)/agent-install/linux/userdata"
AGENT_HOME="/opt/yellowdog/agent"
CONFIG="$AGENT_HOME/application.yaml"
SYSTEMCTL_LOG="/var/log/fake-systemctl.log"
FAILURES=0

pass () { echo "PASS: $*"; }
fail () { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
check () { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

# Runs a script with the given environment; aborts the test on failure, since
# later scripts depend on it
run_script () {
  local script=$1; shift
  : > "$SYSTEMCTL_LOG"
  echo "::group::Output: $script $*"
  if env "$@" bash "$USERDATA/$script"; then
    echo "::endgroup::"; pass "$script: exits 0"
  else
    echo "::endgroup::"; fail "$script: exits 0"
    echo "Test aborted after $FAILURES failure(s)"; exit 1
  fi
}

called () { grep -qx -- "$1" "$SYSTEMCTL_LOG"; }
task_type_count () { grep -c "^  - name: \"$1\"\$" "$CONFIG" || true; }
# The YAML lines that define Task Type $1
task_type () { grep -A1 "^  - name: \"$1\"\$" "$CONFIG"; }
owner_mode () { stat -c '%U:%G %a' "$1"; }
# Compares actual text ($1) with expected text ($2), showing both if they differ
same_text () {
  [[ $1 == "$2" ]] && return
  printf '(actual)\n%s\n(expected)\n%s\n' "$1" "$2"; return 1
}

run_script add-task-type.sh YD_TASK_TYPE_NAME=python YD_TASK_TYPE_RUN=python3
check "add-task-type.sh: Task Type added" \
  same_text "$(task_type python)" $'  - name: "python"\n    run: "python3"'
check "add-task-type.sh: existing Task Types kept" test "$(task_type_count bash)" -eq 1
check "add-task-type.sh: Agent restarted" called "restart --no-block yd-agent.service"
run_script add-task-type.sh YD_TASK_TYPE_NAME=python YD_TASK_TYPE_RUN=python3
check "add-task-type.sh re-run: not duplicated" test "$(task_type_count python)" -eq 1
check "add-task-type.sh re-run: Agent not restarted" test ! -s "$SYSTEMCTL_LOG"

run_script install-docker.sh
check "install-docker.sh: docker command works" docker --version
check "install-docker.sh: service enabled and started" called "enable --now docker.service"
if command -v apt-get > /dev/null; then
  check "install-docker.sh: unattended-upgrades disabled" \
    called "disable --now unattended-upgrades.service"
fi

run_script add-docker-task-type.sh
WRAPPER="$AGENT_HOME/bin/docker-run.sh"
check "add-docker-task-type.sh: yd-agent in the docker group" \
  grep -qw docker <<< "$(id -nG yd-agent)"
check "add-docker-task-type.sh: wrapper owned by yd-agent, mode 500" \
  same_text "$(owner_mode "$WRAPPER")" "yd-agent:yd-agent 500"
check "add-docker-task-type.sh: wrapper is valid Bash" bash -n "$WRAPPER"
check "add-docker-task-type.sh: Task Type added" \
  same_text "$(task_type docker)" $'  - name: "docker"\n    run: "'"$WRAPPER"'"'
check "add-docker-task-type.sh: Agent restarted" called "restart --no-block yd-agent.service"
run_script add-docker-task-type.sh
check "add-docker-task-type.sh re-run: not duplicated" test "$(task_type_count docker)" -eq 1

RCLONE_CONF="$AGENT_HOME/.config/rclone/rclone.conf"
# Sorted, since rclone writes a remote's settings in no fixed order
rclone_remote () {
  runuser -u yd-agent -- "$AGENT_HOME/bin/rclone" config show "$1" 2> /dev/null |
    LC_ALL=C sort
}
sorted () { LC_ALL=C sort <<< "$1"; }
run_script add-rclone-s3.sh YD_S3_REGION=eu-west-2
check "add-rclone-s3.sh: config owned by yd-agent, mode 600" \
  same_text "$(owner_mode "$RCLONE_CONF")" "yd-agent:yd-agent 600"
check "add-rclone-s3.sh: yd-agent's rclone finds the IAM-role remote" \
  same_text "$(rclone_remote s3)" \
  "$(sorted $'[s3]\ntype = s3\nprovider = AWS\nno_check_bucket = true\nregion = eu-west-2\nenv_auth = true')"
run_script add-rclone-s3.sh YD_RCLONE_REMOTE=keyed \
  AWS_ACCESS_KEY_ID=ci-key-id AWS_SECRET_ACCESS_KEY=ci-secret
check "add-rclone-s3.sh: remote with keys added" \
  same_text "$(rclone_remote keyed)" \
  "$(sorted $'[keyed]\ntype = s3\nprovider = AWS\nno_check_bucket = true\naccess_key_id = ci-key-id\nsecret_access_key = ci-secret')"
check "add-rclone-s3.sh: earlier remote kept" test -n "$(rclone_remote s3)"

if [[ $FAILURES -gt 0 ]]; then echo "$FAILURES check(s) failed"; exit 1; fi
echo "All userdata checks passed"
