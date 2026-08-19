#!/bin/bash

# YellowDog Agent installer script.

# Set package repository details
YD_AGENT_REPO_URL=\
"${YD_AGENT_REPO_URL:-\
https://nexus.yellowdog.tech/service/rest/v1/search/assets/download}"
YD_AGENT_REPO_NAME="${YD_AGENT_REPO_NAME:-raw-public}"

# Set to "TRUE" for a Configured Worker Pool installation
YD_CONFIGURED_WP="${YD_CONFIGURED_WP:-FALSE}"

# Set Agent home directory
YD_AGENT_HOME="/opt/yellowdog/agent"

################################################################################

set -euo pipefail

yd_log () {
  echo -e "*** YD" "$(date -u "+%Y-%m-%d_%H%M%S_UTC"):" "$@"
}

YD_INSTALL_LOG="/var/log/yd-agent-install.log"

# Run a command quietly, but surface its output if it fails: this script
# usually runs as instance user data, where the captured console log is the
# only record of what went wrong
yd_run () {
  if ! "$@" >> "$YD_INSTALL_LOG" 2>&1; then
    yd_log "Command failed: $*"
    yd_log "Last 20 lines of $YD_INSTALL_LOG:"
    tail -n 20 "$YD_INSTALL_LOG" >&2
    return 1
  fi
}

yd_log "Starting YellowDog Agent Setup"

if [[ "$EUID" -ne 0 ]]; then
  yd_log "Please run as root ... aborting"
  exit 1
fi

safe_grep() { grep "$@" || test $? = 1; }

# Accept TRUE/FALSE in any case, and reject anything else rather than silently
# treating it as FALSE and installing a node that never registers
case "$YD_CONFIGURED_WP" in
  [Tt][Rr][Uu][Ee])     YD_CONFIGURED_WP="TRUE" ;;
  [Ff][Aa][Ll][Ss][Ee]) YD_CONFIGURED_WP="FALSE" ;;
  *)
    yd_log "YD_CONFIGURED_WP must be TRUE or FALSE," \
           "not '$YD_CONFIGURED_WP' ... aborting"
    exit 1
    ;;
esac

################################################################################

yd_log "Checking distro using 'ID' from '/etc/os-release'"
DISTRO=$(safe_grep "^ID=" /etc/os-release | sed -e 's/ID=//' \
         | sed -e 's/"//g' | awk '{print $1}')
if [[ "$DISTRO" == "" ]]; then
  yd_log "Checking distro using 'ID_LIKE' from '/etc/os-release'"
  DISTRO=$(safe_grep "^ID_LIKE=" /etc/os-release | sed -e 's/ID_LIKE=//' \
           | sed -e 's/"//g' | awk '{print $1}')
fi
yd_log "Using distro = $DISTRO"

ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]
then
  ARCH="amd64"
fi
if [[ "$ARCH" == "aarch64" ]]
then
  ARCH="arm64"
fi
yd_log "Using arch = $ARCH"

case $DISTRO in
  "ubuntu" | "debian")
    PACKAGE="deb"
    ;;
  "almalinux" | "centos" | "rhel" | "amzn" | "fedora" | "sles" | "suse" | "rocky" )
    PACKAGE="rpm"
    ;;
  *)
    yd_log "Unknown distribution ... exiting"
    exit 1
    ;;
esac

################################################################################

# Download into a private directory: a predictable path in a world-writable
# /tmp lets a local user redirect what root is about to install
PACKAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$PACKAGE_DIR"' EXIT
PACKAGE_FILE="$PACKAGE_DIR/yd-agent.$PACKAGE"
NAME_PATTERN="*yd-agent_*"

# Nexus sorts raw assets lexicographically, which ranks (e.g.) 17.2.9 above
# 17.2.16 and 17.4.1 above 17.10.0, so resolve the highest version here rather
# than relying on the repository to return it first
yd_latest_version () {
  local search_url="${YD_AGENT_REPO_URL%/download}"
  local query="repository=$YD_AGENT_REPO_NAME&group=/agent/$PACKAGE/$ARCH"
  query="$query&name=$NAME_PATTERN"
  local token="" page versions=""
  while true; do
    page=$(curl --fail -Ls \
           "$search_url?$query${token:+&continuationToken=$token}")
    versions="$versions$(printf '%s' "$page" \
      | safe_grep -o "yd-agent_[0-9][0-9.]*_$ARCH\.$PACKAGE" \
      | sed -e "s/^yd-agent_//" -e "s/_$ARCH\.$PACKAGE\$//")
"
    token=$(printf '%s' "$page" \
      | sed -n 's/.*"continuationToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [[ -z "$token" ]]; then
      break
    fi
  done
  printf '%s' "$versions" | safe_grep -v '^$' | sort -Vu | tail -n 1
}

yd_log "Resolving the latest Agent version"
AGENT_VERSION="$(yd_latest_version)"
if [[ -z "$AGENT_VERSION" ]]; then
  yd_log "Could not determine the latest Agent version ... aborting"
  exit 1
fi
yd_log "Using Agent version = $AGENT_VERSION"

PACKAGE_NAME="yd-agent_${AGENT_VERSION}_$ARCH.$PACKAGE"
yd_log "Starting Agent package download ($PACKAGE_NAME)"
curl --fail -Ls "$YD_AGENT_REPO_URL?repository=$YD_AGENT_REPO_NAME\
&group=/agent/$PACKAGE/$ARCH&name=*$PACKAGE_NAME" \
-o "$PACKAGE_FILE"

yd_log "Installing Agent package"
if [[ $PACKAGE == "deb" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  yd_run apt-get install -y -o DPkg::Lock::Timeout=-1 "$PACKAGE_FILE"
elif [[ $PACKAGE == "rpm" ]]; then
  yd_run rpm -U "$PACKAGE_FILE"
fi

yd_log "Agent package installation complete ... removing package"
rm -rf "$PACKAGE_DIR"

################################################################################

YD_AGENT_CONFIG="$YD_AGENT_HOME/application.yaml"

# Validate before touching the existing configuration, so that a failure here
# leaves any working configuration in place
if [[ $YD_CONFIGURED_WP == "TRUE" && -z "${YD_TOKEN:-}" ]]; then
  yd_log "Error: YD_TOKEN must be set for a Configured Worker Pool installation"
  exit 1
fi

if [[ -f "$YD_AGENT_CONFIG" ]]
then
  YD_CONFIG_BACKUP="$YD_AGENT_CONFIG.backup.$(date -u "+%Y-%m-%d_%H%M%S_UTC")"
  yd_log "Saving existing Agent configuration as $YD_CONFIG_BACKUP"
  cp "$YD_AGENT_CONFIG" "$YD_CONFIG_BACKUP"
  chown yd-agent:yd-agent "$YD_CONFIG_BACKUP"
fi

yd_log "Writing new Agent configuration $YD_AGENT_CONFIG with 'bash' task type and default metrics script"
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
  if [[ $YD_INSTANCE_ID == "" ]]; then
    YD_INSTANCE_ID="ID-$RANDOM-$RANDOM-$RANDOM"
  fi
  cat >> $YD_AGENT_HOME/application.yaml << EOM
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

yd_log "Agent configuration file created"

################################################################################

yd_log "(Re-)starting Agent service (yd-agent)"
yd_run systemctl restart --no-block yd-agent.service
yd_log "Agent service started"

################################################################################

yd_log "YellowDog Agent installation complete"

################################################################################
