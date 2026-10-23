#!/bin/bash
# Installs and starts Docker. Run as root. On Ubuntu and Debian it also disables
# unattended-upgrades, deliberately (see README). Documentation:
# https://github.com/yellowdog/resources/tree/main/agent-install/linux

set -euo pipefail
declare -F yd_log > /dev/null ||
  yd_log () { echo -e "*** YD" "$(date -u "+%Y-%m-%d_%H%M%S_UTC"):" "$@"; }

# 'ID' first, then each 'ID_LIKE' entry (Amazon Linux is also 'fedora')
for DOCKER_OS in $(sed -n 's/^ID=//p' /etc/os-release | tr -d '"') \
                 $(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"'); do
  case $DOCKER_OS in
    ubuntu | debian)
      yd_log "Disabling unattended-upgrades"
      systemctl disable --now unattended-upgrades.service 2> /dev/null || true
      export DEBIAN_FRONTEND=noninteractive
      APT=(apt-get -y -o DPkg::Lock::Timeout=-1)
      yd_log "Installing Docker (docker.io)"
      for i in {1..5}; do
        "${APT[@]}" update && break
        [[ $i -lt 5 ]] || { yd_log "apt-get update failed ... aborting"; exit 1; }
        sleep 15
      done
      "${APT[@]}" -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" install docker.io
      break ;;
    amzn)
      yd_log "Installing Docker (docker)"
      dnf install -y docker
      break ;;
    rhel | centos | fedora)
      # These distros don't package Docker: use Docker's own repository
      yd_log "Installing Docker (docker-ce) from download.docker.com"
      curl --fail -LsS --retry 5 -o /etc/yum.repos.d/docker-ce.repo \
        "https://download.docker.com/linux/$DOCKER_OS/docker-ce.repo"
      dnf install -y docker-ce docker-ce-cli containerd.io
      break ;;
    sles | suse)
      # On SLES, Docker is in the Containers Module, which must be enabled
      yd_log "Installing Docker (docker)"
      zypper --non-interactive install docker
      break ;;
  esac
done
command -v docker > /dev/null ||
  { yd_log "Cannot install Docker on distro '$DOCKER_OS' ... aborting"; exit 1; }

systemctl enable --now docker.service
yd_log "Docker installed: $(docker --version)"
