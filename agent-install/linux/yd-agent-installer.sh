#!/bin/bash

# YellowDog Agent installer script.

# Set to "TRUE" for a Configured Worker Pool installation
YD_CONFIGURED_WP="${YD_CONFIGURED_WP:-FALSE}"

# Define user and directory names used by the Agent
YD_AGENT_USER="${YD_AGENT_USER:-yd-agent}"
YD_AGENT_HOME="${YD_AGENT_HOME:-/opt/yellowdog/agent}"
YD_AGENT_DATA="${YD_AGENT_DATA:-/var/opt/yellowdog/agent/data}"

################################################################################

set -euo pipefail

yd_log () {
  echo -e "*** YD" "$(date -u "+%Y-%m-%d_%H%M%S_UTC"):" "$@"
}

yd_log "Starting YellowDog Agent Setup"

if [[ "$EUID" -ne 0 ]]; then
  yd_log "Please run as root ... aborting"
  exit 1
fi

safe_grep() { grep "$@" || test $? = 1; }

################################################################################

yd_log "Checking distro using 'ID_LIKE' from '/etc/os-release'"
DISTRO=$(safe_grep "^ID_LIKE=" /etc/os-release | sed -e 's/ID_LIKE=//' \
         | sed -e 's/"//g' | awk '{print $1}')
if [[ "$DISTRO" == "" ]]; then
  yd_log "Checking distro using 'ID' from '/etc/os-release'"
  DISTRO=$(safe_grep "^ID=" /etc/os-release | sed -e 's/ID=//' \
           | sed -e 's/"//g')
fi
yd_log "Using distro = $DISTRO"

ARCH=$(uname -m)
yd-log "Using arch = $ARCH"

case $DISTRO in
  "ubuntu" | "debian")
    PACKAGE="deb"
    ;;
  "almalinux" | "centos" | "rhel" | "amzn" | "fedora" | "sles" | "suse")
    PACKAGE="rpm"
    ;;
  *)
    yd_log "Unknown distribution ... exiting"
    exit 1
    ;;
esac

################################################################################

yd_log "Starting Agent download"
curl --fail -Ls "https://nexus.yellowdog.tech/service/
rest/v1/search/assets/download?repository=raw-public&group=/agent/$PACKAGE/$ARCH
&sort=name&direction=desc" -o /tmp/yd-agent.$PACKAGE

if [[ $PACKAGE == "deb" ]]; then
  dpkg -i /tmp/yd-agent.$PACKAGE
elif [[ $PACKAGE == "rpm" ]]; then
  rpm -i /tmp/yd-agent.$PACKAGE
fi

yd_log "Agent download complete"

################################################################################

yd_log "Writing new Agent configuration file (application.yaml)"
yd_log "Inserting Task Type 'bash'"

cat > $YD_AGENT_HOME/application.yaml << EOM
yda:
  taskTypes:
    - name: "bash"
      run: "/bin/bash"
EOM

if [[ $YD_CONFIGURED_WP == "TRUE" ]]; then
  yd_log "Adding Configured Worker Pool properties"
  if [[ -z $YD_TOKEN ]]; then
    yd_log "Error: YD_TOKEN must be set"
    exit 1
  fi
  YD_INSTANCE_ID="${YD_INSTANCE_ID:-$(hostname)}"
  if [[ $YD_INSTANCE_ID == "" ]]; then
    YD_INSTANCE_ID="ID-$RANDOM-$RANDOM-$RANDOM"
  fi
  cat >> $YD_AGENT_HOME/application.yaml << EOM
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
  workerTag: "${YD_WORKER_TAG:-}"
  privateIpAddress: "${YD_PRIVATE_IP:-}"
  publicIpAddress: "${YD_PUBLIC_IP:-}"
  createWorkers:
    targetType: "${YD_WORKER_TARGET_TYPE:-PER_NODE}"
    targetCount: "${YD_WORKER_TARGET_COUNT:-1}"
  schedule:
    enabled: "${YD_SCHEDULE_ENABLED:-false}"
    startup: ${YD_SCHEDULE_STARTUP:-['0 0 18 * * MON-FRI']}
    shutdown: ${YD_SCHEDULE_SHUTDOWN:-['0 0 7 * * MON-FRI']}
logging.pattern.console: "%d{yyyy-MM-dd HH:mm:ss,SSS} Worker[%10.10thread]\
 %-5level[%40logger{40}] %message [%class{0}:%method:%line]%n"
EOM
fi

yd_log "Agent configuration file created"

################################################################################

yd_log "Starting Agent service (yd-agent)"
systemctl start --no-block yd-agent &> /dev/null
yd_log "Agent service started"

################################################################################

yd_log "YellowDog Agent installation complete"
