#!/bin/bash
# Adds a 'docker' Task Type, which runs each Task in its own container, and
# restarts the Agent. Run as root after yd-agent-installer.sh and
# install-docker.sh. Documentation:
# https://github.com/yellowdog/resources/tree/main/agent-install/linux

set -euo pipefail
declare -F yd_log > /dev/null ||
  yd_log () { echo -e "*** YD" "$(date -u "+%Y-%m-%d_%H%M%S_UTC"):" "$@"; }

YD_AGENT_HOME="/opt/yellowdog/agent"
getent group docker > /dev/null ||
  { yd_log "No 'docker' group: install Docker first ... aborting"; exit 1; }
yd_log "Adding yd-agent to the 'docker' group"
usermod -aG docker yd-agent

YD_DOCKER_RUN="$YD_AGENT_HOME/bin/docker-run.sh"
yd_log "Writing $YD_DOCKER_RUN"
cat > "$YD_DOCKER_RUN" << 'EOT'
#!/bin/bash
# Runs a Task as 'docker run <Task arguments>', with the Task's working
# directory mounted at $YD_WORKING. Optional environment variables:
#   DOCKER_USERNAME, DOCKER_PASSWORD, DOCKER_REGISTRY: log in to a registry
#   DOCKER_IMAGE:    image to 'docker pull' first (updating a cached copy)
#   YD_STOP_SIGNAL:  signal that stops the container on abort (default SIGTERM)
#   YD_STOP_TIMEOUT: seconds to wait before killing it (default 10)
#   YD_WORKING:      working directory in the container (default /yd_working)

YD_CONTAINER_NAME=yd-container-$$

# On exit, including a Task abort, stop the container and log out
cleanup_docker () {
  # Anchored: Docker's name filter otherwise matches substrings
  CONTAINER_ID=$(docker ps -aq --filter "name=^${YD_CONTAINER_NAME}$")
  if [[ -n $CONTAINER_ID ]]; then
    echo "Abort received at: $(date -u "+%Y-%m-%d_%H%M%S_UTC")"
    echo "Stopping container: $YD_CONTAINER_NAME ($CONTAINER_ID)"
    docker stop --time "${YD_STOP_TIMEOUT:-10}" "$CONTAINER_ID" > /dev/null
  fi
  if [[ -n $DOCKER_USERNAME ]]; then
    docker logout ${DOCKER_REGISTRY:+"$DOCKER_REGISTRY"}
  fi
}
# An untrapped signal would skip the EXIT trap; exit with 128 + signal number
trap cleanup_docker EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

if [[ -n $DOCKER_USERNAME && -n $DOCKER_PASSWORD ]]; then
  printf '%s' "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" \
    --password-stdin ${DOCKER_REGISTRY:+"$DOCKER_REGISTRY"}
fi
export YD_WORKING="${YD_WORKING:-/yd_working}"
if [[ -n $DOCKER_IMAGE ]]; then
  docker pull "$DOCKER_IMAGE"
fi

# Run in the background and 'wait': bash defers traps until a foreground
# command returns, but 'wait' returns as soon as a trapped signal arrives
docker run --rm --name "$YD_CONTAINER_NAME" \
  --stop-signal "${YD_STOP_SIGNAL:-SIGTERM}" \
  --env YD_WORKING="$YD_WORKING" -v "$(pwd)":"$YD_WORKING" "$@" &
wait $!
EOT
chown yd-agent:yd-agent "$YD_DOCKER_RUN"
chmod 0500 "$YD_DOCKER_RUN"

YD_AGENT_CONFIG="$YD_AGENT_HOME/application.yaml"
if ! grep -q '^  - name: "docker"$' "$YD_AGENT_CONFIG"; then
  yd_log "Adding Task Type 'docker' to $YD_AGENT_CONFIG"
  sed -i "/^yda.taskTypes:/a\\  - name: \"docker\"\\n    run: \"$YD_DOCKER_RUN\"" \
    "$YD_AGENT_CONFIG"
fi
# Also needed for the Agent to pick up its new group membership
systemctl restart --no-block yd-agent.service
