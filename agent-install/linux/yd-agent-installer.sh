#!/bin/bash
# YellowDog Agent installer for Linux: installs or upgrades the Agent, writes
# application.yaml and restarts the service. Run as root. Documentation:
# https://github.com/yellowdog/resources/tree/main/agent-install/linux

# Nexus repository (the URL must end in '/download')
YD_AGENT_REPO_URL="${YD_AGENT_REPO_URL:-\
https://nexus.yellowdog.tech/service/rest/v1/search/assets/download}"
YD_AGENT_REPO_NAME="${YD_AGENT_REPO_NAME:-raw-public}"
# "TRUE" for a Configured Worker Pool, which also needs YD_TOKEN (see README)
YD_CONFIGURED_WP="${YD_CONFIGURED_WP:-FALSE}"
# Fixed by the Agent package, so not overridable
YD_AGENT_HOME="/opt/yellowdog/agent"

set -euo pipefail
yd_log () { echo -e "*** YD" "$(date -u "+%Y-%m-%d_%H%M%S_UTC"):" "$@"; }
yd_die () { yd_log "$@ ... aborting"; exit 1; }
safe_grep () { grep "$@" || test $? = 1; }

# Log a command's output, and show its tail on failure (as user data, the
# console log is the only record)
YD_INSTALL_LOG="/var/log/yd-agent-install.log"
yd_run () {
  "$@" >> "$YD_INSTALL_LOG" 2>&1 && return
  yd_log "Command failed: $*"; yd_log "Last 20 lines of $YD_INSTALL_LOG:"
  tail -n 20 "$YD_INSTALL_LOG" >&2; return 1
}

yd_log "Starting YellowDog Agent Setup"
[[ $EUID -eq 0 ]] || yd_die "Please run as root"
case "$YD_CONFIGURED_WP" in
  [Tt][Rr][Uu][Ee]) YD_CONFIGURED_WP="TRUE" ;;
  [Ff][Aa][Ll][Ss][Ee]) YD_CONFIGURED_WP="FALSE" ;;
  *) yd_die "YD_CONFIGURED_WP must be TRUE or FALSE, not '$YD_CONFIGURED_WP'" ;;
esac
# Validate before changing anything
[[ $YD_CONFIGURED_WP == "FALSE" || -n "${YD_TOKEN:-}" ]] ||
  yd_die "YD_TOKEN must be set for a Configured Worker Pool install"

yd_os_release () {
  safe_grep "^$1=" /etc/os-release | sed -e "s/^$1=//" -e 's/"//g'
}
yd_package_type () {
  case $1 in
    ubuntu | debian) echo "deb" ;;
    almalinux | centos | rhel | amzn | fedora | sles | suse | rocky) echo "rpm" ;;
  esac
}
# 'ID', else the first recognised 'ID_LIKE' entry (Oracle Linux -> fedora).
# Later user data fragments use DISTRO too
DISTRO=$(yd_os_release ID | awk '{print $1}')
PACKAGE=$(yd_package_type "$DISTRO")
if [[ -z $PACKAGE ]]; then
  for LIKE in $(yd_os_release ID_LIKE); do
    PACKAGE=$(yd_package_type "$LIKE")
    if [[ -n $PACKAGE ]]; then DISTRO=$LIKE; break; fi
  done
fi
[[ -n $PACKAGE ]] || yd_die "Unknown distribution '$DISTRO'"
case $(uname -m) in
  x86_64) ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) yd_die "Unsupported architecture '$(uname -m)'" ;;
esac
yd_log "Using distro = $DISTRO, arch = $ARCH"

# Private directory: a fixed path in /tmp could be redirected by a local user
PACKAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$PACKAGE_DIR"' EXIT
PACKAGE_FILE="$PACKAGE_DIR/yd-agent.$PACKAGE"
QUERY="repository=$YD_AGENT_REPO_NAME&group=/agent/$PACKAGE/$ARCH"
# -S shows errors; retries cover the network still coming up at boot
YD_CURL=(curl --fail -LsS --retry 5 --retry-connrefused)

# Nexus sorts versions as text (17.2.9 > 17.2.16), so page through every asset
# and pick the highest. 'set -e' is off in $(...), so check each request
yd_latest_version () {
  local token="" page versions=""
  while true; do
    page=$("${YD_CURL[@]}" "${YD_AGENT_REPO_URL%/download}?$QUERY\
&name=*yd-agent_*${token:+&continuationToken=$token}") ||
      { yd_log "Agent version search request failed" >&2; return 1; }
    versions+=$(printf '%s' "$page" |
      safe_grep -o "yd-agent_[0-9][0-9.]*_$ARCH\.$PACKAGE")$'\n'
    token=$(printf '%s' "$page" | sed -n \
      's/.*"continuationToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [[ -n $token ]] || break
  done
  printf '%s' "$versions" | sed -e 's/^yd-agent_//' -e "s/_$ARCH\.$PACKAGE\$//" |
    safe_grep -v '^$' | sort -Vu | tail -n 1
}

yd_log "Resolving the latest Agent version"
AGENT_VERSION=$(yd_latest_version) && [[ -n $AGENT_VERSION ]] ||
  yd_die "Could not determine the latest Agent version"
PACKAGE_NAME="yd-agent_${AGENT_VERSION}_$ARCH.$PACKAGE"
yd_log "Downloading Agent package $PACKAGE_NAME"
"${YD_CURL[@]}" -o "$PACKAGE_FILE" "$YD_AGENT_REPO_URL?$QUERY&name=*$PACKAGE_NAME" ||
  yd_die "Agent package download failed"

yd_log "Installing Agent package"
if [[ $PACKAGE == "deb" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  yd_run apt-get install -y -o DPkg::Lock::Timeout=-1 "$PACKAGE_FILE"
else
  # Plain 'rpm -U' fails when the same version is already installed
  yd_run rpm -U --replacepkgs "$PACKAGE_FILE"
fi
rm -rf "$PACKAGE_DIR"
yd_log "Agent package installation complete"

YD_AGENT_CONFIG="$YD_AGENT_HOME/application.yaml"
if [[ -f $YD_AGENT_CONFIG ]]; then
  YD_CONFIG_BACKUP="$YD_AGENT_CONFIG.backup.$(date -u "+%Y-%m-%d_%H%M%S_UTC")"
  yd_log "Saving existing Agent configuration as $YD_CONFIG_BACKUP"
  cp "$YD_AGENT_CONFIG" "$YD_CONFIG_BACKUP"
  chown yd-agent:yd-agent "$YD_CONFIG_BACKUP"
fi

yd_log "Writing new Agent configuration $YD_AGENT_CONFIG"
cat > $YD_AGENT_CONFIG << EOM
yda.taskTypes:
  - name: "bash"
    run: "/bin/bash"
yda.metrics.script-path: "/opt/yellowdog/agent/bin/metrics.sh"
yda.data-client.rclone-binary-path: "/opt/yellowdog/agent/bin/rclone"
EOM

if [[ $YD_CONFIGURED_WP == "TRUE" ]]; then
  yd_log "Adding Configured Worker Pool properties"
  YD_INSTANCE_ID="${YD_INSTANCE_ID:-$(hostname)}"
  [[ -n $YD_INSTANCE_ID ]] || YD_INSTANCE_ID="ID-$RANDOM-$RANDOM-$RANDOM"
  cat >> "$YD_AGENT_CONFIG" << EOM
yda:
  token: "$YD_TOKEN"
  instanceId: "$YD_INSTANCE_ID"
  provider: "ON_PREMISE"
  hostname: "${YD_HOSTNAME:-$(hostname)}"
  services-schema.default-url: "${YD_URL:-https://portal.yellowdog.co/api}"
  region: "${YD_REGION:-}"
  instanceType: "${YD_INSTANCE_TYPE:-}"
  sourceName: "${YD_SOURCE_NAME:-}"
  vcpus: "${YD_VCPUS:-$(nproc)}"
  ram: "${YD_RAM:-$(awk '/MemTotal/ {printf("%.1f", \
                    int(0.5 + ($2*2 / 1024^2)) / 2)}' /proc/meminfo)}"
  privateIpAddress: "${YD_PRIVATE_IP:-}"
  publicIpAddress: "${YD_PUBLIC_IP:-}"
  createWorkers:
    targetType: "${YD_WORKER_TARGET_TYPE:-PER_NODE}"
    targetCount: "${YD_WORKER_TARGET_COUNT:-1}"
logging.pattern.console: "%d{yyyy-MM-dd HH:mm:ss.SSS} Worker[%10.10thread]\
 %-5level[%40logger{40}] %message [%class{0}:%method:%line]%n"
EOM
fi

yd_log "(Re-)starting Agent service (yd-agent)"
yd_run systemctl restart --no-block yd-agent.service
yd_log "YellowDog Agent installation complete"
