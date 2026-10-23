#!/bin/bash
# Adds an Amazon S3 remote to the Agent's rclone configuration, for use by the
# Agent's data client. Run as root after yd-agent-installer.sh. Documentation:
# https://github.com/yellowdog/resources/tree/main/agent-install/linux

YD_RCLONE_REMOTE="${YD_RCLONE_REMOTE:-s3}"
# The buckets' region; rclone assumes us-east-1 if this is empty
YD_S3_REGION="${YD_S3_REGION:-}"
# Leave these unset to use the instance's IAM role (recommended)
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"

set -euo pipefail
declare -F yd_log > /dev/null ||
  yd_log () { echo -e "*** YD" "$(date -u "+%Y-%m-%d_%H%M%S_UTC"):" "$@"; }

YD_AGENT_HOME="/opt/yellowdog/agent"
# The Agent runs as yd-agent, whose home directory is YD_AGENT_HOME
YD_RCLONE_DIR="$YD_AGENT_HOME/.config/rclone"
install -d -o yd-agent -g yd-agent -m 0700 "$YD_AGENT_HOME/.config" "$YD_RCLONE_DIR"

YD_RCLONE_ARGS=(provider=AWS no_check_bucket=true)
if [[ -n $YD_S3_REGION ]]; then YD_RCLONE_ARGS+=("region=$YD_S3_REGION"); fi
if [[ -n $AWS_ACCESS_KEY_ID ]]; then
  YD_RCLONE_ARGS+=("access_key_id=$AWS_ACCESS_KEY_ID"
                   "secret_access_key=$AWS_SECRET_ACCESS_KEY")
else
  YD_RCLONE_ARGS+=(env_auth=true)
fi

# Creates the remote, or replaces one of the same name; other remotes are kept
yd_log "Adding rclone remote '$YD_RCLONE_REMOTE'"
"$YD_AGENT_HOME/bin/rclone" config create "$YD_RCLONE_REMOTE" s3 \
  "${YD_RCLONE_ARGS[@]}" --config "$YD_RCLONE_DIR/rclone.conf" \
  --non-interactive > /dev/null
chown yd-agent:yd-agent "$YD_RCLONE_DIR/rclone.conf"
chmod 0600 "$YD_RCLONE_DIR/rclone.conf"
