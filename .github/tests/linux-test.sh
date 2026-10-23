#!/bin/bash
# CI test for yd-agent-installer.sh, run as root in a distro container. Runs the
# installer three times (plain install, Configured Worker Pool re-run, plain
# re-run) and checks the package, application.yaml and its backups after each.

set -euo pipefail
INSTALLER="$(cd "$(dirname "$0")/../.." && pwd)/agent-install/linux/yd-agent-installer.sh"
AGENT_HOME="/opt/yellowdog/agent"
CONFIG="$AGENT_HOME/application.yaml"
SYSTEMCTL_LOG="/var/log/fake-systemctl.log"
FAILURES=0

pass () { echo "PASS: $*"; }
fail () { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
check () { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

# Container images are slimmer than cloud images: add what the installer, the
# package's postinst and this test expect to find. Entries are
# command:apt-package:dnf-package:zypper-package
prepare () {
  local entry cmd apt dnf zypper apt_pkgs=(ca-certificates) dnf_pkgs=() zypper_pkgs=()
  for entry in curl:curl:curl:curl hostname:hostname:hostname:hostname \
      awk:gawk:gawk:gawk useradd:passwd:shadow-utils:shadow \
      diff:diffutils:diffutils:diffutils find:findutils:findutils:findutils; do
    IFS=: read -r cmd apt dnf zypper <<< "$entry"
    command -v "$cmd" > /dev/null && continue
    apt_pkgs+=("$apt"); dnf_pkgs+=("$dnf"); zypper_pkgs+=("$zypper")
  done
  if command -v apt-get > /dev/null; then
    apt-get update -qq
    apt-get install -y -qq "${apt_pkgs[@]}" > /dev/null
  elif [[ ${#dnf_pkgs[@]} -gt 0 ]]; then
    if command -v dnf > /dev/null; then
      dnf install -y -q "${dnf_pkgs[@]}"
    else
      zypper --non-interactive --quiet install "${zypper_pkgs[@]}"
    fi
  fi
  # No systemd in a container: record the calls instead. rpm scriptlets run
  # with PATH=/sbin:/bin:/usr/sbin:/usr/bin, so replace /usr/bin/systemctl
  [[ -e /usr/bin/systemctl ]] && mv /usr/bin/systemctl /usr/bin/systemctl.real
  printf '#!/bin/sh\necho "$*" >> %s\n' "$SYSTEMCTL_LOG" > /usr/bin/systemctl
  chmod 755 /usr/bin/systemctl
}

package_installed () {
  if command -v dpkg-query > /dev/null; then
    [[ $(dpkg-query -W -f='${Status}' yellowdog-agent 2> /dev/null) == "install ok installed" ]]
  else
    rpm -q yd-agent > /dev/null
  fi
}

backups () { find "$AGENT_HOME" -maxdepth 1 -name 'application.yaml.backup.*' | sort; }
newest_backup () { backups | tail -n 1; }
same_content () { diff -u "$1" "$2" && return; echo "(diff: $1 vs $2)"; return 1; }

EXPECTED_BASE=$(mktemp)
cat > "$EXPECTED_BASE" << 'EOM'
yda.taskTypes:
  - name: "bash"
    run: "/bin/bash"
yda.metrics.script-path: "/opt/yellowdog/agent/bin/metrics.sh"
yda.data-client.rclone-binary-path: "/opt/yellowdog/agent/bin/rclone"
EOM

# Expected configured file, given the RAM value the installer probed
expected_configured () {
  cat "$EXPECTED_BASE"
  cat << EOM
yda:
  token: "ci-test-token"
  instanceId: "$(hostname)"
  provider: "ON_PREMISE"
  hostname: "$(hostname)"
  services-schema.default-url: "https://api.yellowdog.ai"
  region: "ci-region"
  instanceType: ""
  sourceName: ""
  vcpus: "$(nproc)"
  ram: "$1"
  privateIpAddress: ""
  publicIpAddress: ""
  createWorkers:
    targetType: "PER_NODE"
    targetCount: "2"
logging.pattern.console: "%d{yyyy-MM-dd HH:mm:ss.SSS} Worker[%10.10thread] %-5level[%40logger{40}] %message [%class{0}:%method:%line]%n"
EOM
}

# Runs the installer with the given environment; aborts the test on failure,
# since later runs depend on it
run_installer () {
  local desc=$1; shift
  : > "$SYSTEMCTL_LOG"
  echo "::group::Installer output: $desc"
  if env "$@" bash "$INSTALLER"; then
    echo "::endgroup::"; pass "$desc: installer exits 0"
  else
    echo "::endgroup::"; fail "$desc: installer exits 0"
    echo "Test aborted after $FAILURES failure(s)"; exit 1
  fi
  check "$desc: package installed" package_installed
  check "$desc: service restart requested" \
    grep -qx "restart --no-block yd-agent.service" "$SYSTEMCTL_LOG"
}

echo "::group::Preparing $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release) on $(uname -m)"
prepare
echo "::endgroup::"

# Run 1: the package's postinst creates application.yaml from the default,
# which the installer backs up before overwriting
run_installer "plain install"
check "plain install: application.yaml" same_content "$EXPECTED_BASE" "$CONFIG"
check "plain install: default config backed up" \
  same_content "$AGENT_HOME/application.default.yaml" "$(newest_backup)"
check "plain install: backup owned by yd-agent" \
  test "$(stat -c %U "$(newest_backup)")" = yd-agent
BACKUP_COUNT=$(backups | wc -l)

# Run 2: same version already installed, now with YD_TOKEN set
sleep 1  # backups are named to the second
run_installer "configured re-run" \
  YD_TOKEN=ci-test-token YD_REGION=ci-region YD_WORKER_TARGET_COUNT=2
RAM=$(sed -n 's/^  ram: "\(.*\)"$/\1/p' "$CONFIG")
check "configured re-run: ram '$RAM' is in GB to the nearest 0.5" \
  grep -Eqx '[0-9]+\.[05]' <<< "$RAM"
EXPECTED_CONFIGURED=$(mktemp)
expected_configured "$RAM" > "$EXPECTED_CONFIGURED"
check "configured re-run: application.yaml" same_content "$EXPECTED_CONFIGURED" "$CONFIG"
check "configured re-run: one new backup" test "$(backups | wc -l)" -eq $((BACKUP_COUNT + 1))
check "configured re-run: previous config backed up" \
  same_content "$EXPECTED_BASE" "$(newest_backup)"

# Run 3: dropping YD_TOKEN rewrites the file wholesale
sleep 1
run_installer "plain re-run"
check "plain re-run: application.yaml" same_content "$EXPECTED_BASE" "$CONFIG"
check "plain re-run: one new backup" test "$(backups | wc -l)" -eq $((BACKUP_COUNT + 2))
check "plain re-run: previous config backed up" \
  same_content "$EXPECTED_CONFIGURED" "$(newest_backup)"

if [[ $FAILURES -gt 0 ]]; then echo "$FAILURES check(s) failed"; exit 1; fi
echo "All checks passed"
