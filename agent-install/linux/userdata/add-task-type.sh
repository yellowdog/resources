#!/bin/bash
# Adds a Task Type to the Agent's application.yaml and restarts the Agent. Run
# as root after yd-agent-installer.sh. Documentation:
# https://github.com/yellowdog/resources/tree/main/agent-install/linux

YD_TASK_TYPE_NAME="${YD_TASK_TYPE_NAME:-python}"
YD_TASK_TYPE_RUN="${YD_TASK_TYPE_RUN:-python3}"

set -euo pipefail
declare -F yd_log > /dev/null ||
  yd_log () { echo -e "*** YD" "$(date -u "+%Y-%m-%d_%H%M%S_UTC"):" "$@"; }

YD_AGENT_CONFIG="/opt/yellowdog/agent/application.yaml"
if grep -q "^  - name: \"$YD_TASK_TYPE_NAME\"\$" "$YD_AGENT_CONFIG"; then
  yd_log "Task Type '$YD_TASK_TYPE_NAME' is already defined"
else
  yd_log "Adding Task Type '$YD_TASK_TYPE_NAME' to $YD_AGENT_CONFIG"
  sed -i "/^yda.taskTypes:/a\\  - name: \"$YD_TASK_TYPE_NAME\"\\n    run: \"$YD_TASK_TYPE_RUN\"" \
    "$YD_AGENT_CONFIG"
  # The installer has already started the Agent, which may have read the file
  systemctl restart --no-block yd-agent.service
fi
