# YellowDog Agent Installer Script

## Overview 

The [yd-agent-installer.sh](yd-agent-installer.sh) script can be used to install and configure the YellowDog Agent and its dependencies, on Linux.

The script is designed to work with recent Linux distributions based on **Debian**, **Red Hat**, and **SUSE**. The following specific distributions have been tested, using AWS instances, on both `amd64` and `arm64`:

- AlmaLinux 9.8
- AlmaLinux 10.2
- Amazon Linux 2
- Amazon Linux 2023
- CentOS Stream 9
- CentOS Stream 10
- Debian 11
- Debian 12
- Debian 13
- Red Hat Enterprise Linux 9.8
- Red Hat Enterprise Linux 10.2
- Rocky Linux 9.8
- Rocky Linux 10.2
- SUSE SLES 15 SP7
- Ubuntu 20.04
- Ubuntu 22.04
- Ubuntu 24.04
- Ubuntu 26.04

## Installation Process

The script downloads the latest installation package from YellowDog's Nexus software repository. Installation packages are available in `.deb` and `.rpm` forms for different Linux variants and architectures. The appropriate installer for the platform on which the script is run will be selected and downloaded.

The installation package contains the YellowDog Agent JAR file and a self-contained Java Runtime Environment (JRE).

## Installation Actions

The installation process performs the following actions:

1. Creates a new user and group `yd-agent` with home directory `/opt/yellowdog/agent`, and a data directory at `/var/opt/yellowdog/agent/data`. The installer unpacks the `agent.jar` file and the JRE into the Agent's home directory.
2. Creates the Agent's configuration file (`application.yaml`) and its startup script, in the Agent's home directory.
3. Configures the Agent as a `systemd` service and starts the `yd-agent` service.

Output from the package installation and the service restart is recorded in `/var/log/yd-agent-install.log`. The script's own progress messages go to its standard output, prefixed with `*** YD`; if the script is supplied as instance user data these are captured in the instance's cloud-init output log. If a step fails, the script prints the last lines of the install log and stops.

## How the Script Works

The script must be run as root (`bash yd-agent-installer.sh`). It:

1. Checks its settings (see below) before changing anything.
2. Detects the distribution from `ID` in `/etc/os-release`, falling back to the first recognised entry in `ID_LIKE` for derivative distributions (e.g., Oracle Linux is treated as `fedora`), and the architecture (`amd64` or `arm64`). It stops if either is not supported.
3. Finds the highest Agent version available in YellowDog's Nexus repository, then downloads and installs that `.deb` or `.rpm` package. Downloads are retried, since user data runs while the network may still be starting.
4. Saves any existing `application.yaml` as `application.yaml.backup.<timestamp>`, then writes a new one. Any hand edits to the file are replaced, but they are kept in the backup.
5. Restarts the `yd-agent` service, without waiting for it to finish starting.

The script can be re-run at any time, e.g., to upgrade the Agent in place.

It requires `bash`, `curl` (7.52 or later), `systemd` and GNU coreutils, all of which are present on the distributions listed above.

The Agent's home directory is always `/opt/yellowdog/agent`: it is set by the Agent package and cannot be changed.

## Script Settings

The following variables control the script. Each can be exported in the environment before the script runs, or edited in the script itself.

| Variable             | Description                                                                                                                                         |
|----------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------|
| `YD_TOKEN`           | Setting this installs for a Configured Worker Pool (see [below](#configured-worker-pool-installation)). Unset by default, which installs for a Provisioned Worker Pool. |

## YellowDog Task Types

By default, a single general-purpose YellowDog **Task Type**, `bash`, is defined, which runs Bash commands and scripts:

```yaml
yda.taskTypes:
  - name: "bash"
    run: "/bin/bash"
```

Edit the following section of the installer script to customise Task Type(s) for your own requirements.

For example, to add a task type to run a specific executable you might edit the section of the script as follows:

```shell
cat > $YD_AGENT_CONFIG << EOM
yda.taskTypes:
  - name: "bash"
    run: "/bin/bash"
  - name: "my-task-type"
    run: "/usr/bin/my-executable"
yda.metrics.script-path: "/opt/yellowdog/agent/bin/metrics.sh"
yda.data-client.rclone-binary-path: "/opt/yellowdog/agent/bin/rclone"
EOM
```

Retain the `yda.metrics.script-path` and `yda.data-client.rclone-binary-path` settings: without them the Agent will not collect metrics or perform rclone-based data movement.

## Add passwordless sudo access for yd-agent

Add the following to the end of the script to equip `yd-agent` with passwordless sudo access:

```shell
case $DISTRO in
  "ubuntu" | "debian")
    ADMIN_GRP="sudo"
    ;;
  "almalinux" | "centos" | "rhel" | "amzn" | "fedora" | "rocky")
    ADMIN_GRP="wheel"
    ;;
  "sles" | "suse")
    ADMIN_GRP="wheel"
    ;;
  *)
    yd_log "Cannot add sudo access on distro '$DISTRO' ... aborting"
    exit 1
    ;;
esac

YD_AGENT_USER="yd-agent"
yd_log "Adding $YD_AGENT_USER to passwordless sudoers"
usermod -aG $ADMIN_GRP $YD_AGENT_USER
echo -e "$YD_AGENT_USER\tALL=(ALL)\tNOPASSWD: ALL" > \
        /etc/sudoers.d/020-$YD_AGENT_USER
```

## Add an SSH Public Key for yd-agent

Add the following to the end of the script to add a public key for `yd-agent`, inserting the public key where indicated:

```shell
SSH_USER="yd-agent"
SSH_USER_HOME=$YD_AGENT_HOME

yd_log "Adding public SSH key for $SSH_USER"

mkdir -p $SSH_USER_HOME/.ssh
chmod og-rwx $SSH_USER_HOME/.ssh

# Insert the required public key below
cat >> $SSH_USER_HOME/.ssh/authorized_keys << EOM
<Add public key here>
EOM

chmod og-rw $SSH_USER_HOME/.ssh/authorized_keys
chown -R $SSH_USER:$SSH_USER $SSH_USER_HOME/.ssh
```

## Modes of Use

### Custom Image Creation

The script can be used to **prepare a custom VM image**, by running it on an instance using a base image of your choice and then capturing a new custom image from this instance. Instances booted from the new custom image will be configured to work with the YellowDog Scheduler.

The installer script is idempotent. This is useful if one wants to update the version of the Agent, etc.

### Dynamic Agent Installation

The script can also be used to **install the YellowDog components dynamically** on any Linux instance, by supplying it as all or part of the **user data** for the instance. For example, using the YellowDog CLI:

```toml
[workerPool]
userDataFile = "yd-agent-installer.sh"
```

The user data file will be run (as root) when the instance boots, and will configure the instance to work with the YellowDog Scheduler as part of the boot process. Typical total processing time for the installation steps is less than one minute, in addition to the normal instance boot overheads.

User data scripts can be concatenated using the `userDataFiles` property, for example:

```toml
[workerPool]
userDataFiles = ["set-variables.sh", "yd-agent-installer.sh", "add-sudo.sh"]
```

Scripts placed after the installer run in the same shell, so they can use the `$DISTRO` and `$YD_AGENT_HOME` variables and the `yd_log` function that it defines, as in the examples above.

The following simple wrapper script is sometimes useful as an alternative to the full installer script (which is downloaded then run). The script is more compact, hence uses less of the user data payload budget.

```shell
#!/bin/bash

set -eu

cd /root

# Download to a unique filename, to avoid collisions with any existing file
INSTALLER=$(mktemp /root/yd-agent-installer-XXXXXXXX.sh)
trap 'rm -f "$INSTALLER"' EXIT

echo "Downloading the Agent installer script"
curl -fLsS -o "$INSTALLER" \
  https://raw.githubusercontent.com/yellowdog/resources/refs/heads/main/agent-install/linux/yd-agent-installer.sh

# Install/update the Agent and restart the Agent service
bash "$INSTALLER"
```

When using dynamic Agent installation, bear in mind that **every** provisioned instance will incur the costs of downloading the YellowDog installation package (about 60MB). We therefore recommend against using this approach when provisioning instances at scale: use a custom image instead, with the Agent pre-installed.

### Configured Worker Pool Installation

The installer script can also be used to install and configure the YellowDog Agent on systems that will be included in **Configured Worker Pools**.

Configured Worker Pools are on-premise systems, or systems that were otherwise not provisioned via the YellowDog Scheduler, e.g., instances/hosts that were provisioned directly using on-premise provisioners or via a cloud provider console. Adding the YellowDog Agent to these systems allows them to participate in YellowDog Task scheduling.

To use this feature, supply a value for `YD_TOKEN`, matching the token of the YellowDog Configured Worker Pool to which this host will register. Setting `YD_TOKEN` is what selects a Configured Worker Pool install: it activates the population of additional properties in the Agent's `application.yaml` configuration file (since these will not be set automatically as they are in the case of instances in Provisioned Worker Pools).

The variables can be set directly in the script file itself or exported in the environment in which the installer script will run to override the defaults.

The following set of variables is available for specifying the properties of an instance. Default values are provided for all properties except `YD_TOKEN`. For more information on the variables in the `application.yaml` file, please see the [YellowDog Documentation](https://docs.yellowdog.co/#/the-platform/using-variables-in-the-configuration-file).

| Property                      | Description                                                                                                                                                               |
|-------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `YD_TOKEN` (Required)         | This is the token that identifies the Configured Worker Pool to which this instance belongs, and which allows the Agent to connect to the platform.                       |
| `YD_INSTANCE_ID`              | An instance identifier, which must be unique within a Worker Pool. By default, the value returned by the `hostname` command is used; if this is empty, a random ID is generated. Note that a random ID is not persisted, so it will differ on each run. |
| `YD_HOSTNAME`                 | The hostname of the instance. By default, the value returned by the `hostname` command is used.                                                                                  |
| `YD_REGION`                   | A string describing the region in which the instance is located. Empty by default.                                                                                        |
| `YD_SOURCE_NAME`              | A string describing the 'source name' from which the instance comes, e.g.: "VMware 01". Empty by default.                                                                 |
| `YD_INSTANCE_TYPE`            | A string describing the type of the instance. Empty by default.                                                                                                           |
| `YD_RAM`                      | The instance's RAM in GB. By default, the `MemTotal` value obtained from `/proc/meminfo`.                                                                                 |
| `YD_VCPUS`                    | The instance's VCPU count. By default, the value returned by `nproc`.                                                                                                     |
| `YD_PUBLIC_IP`                | The instance's public IP address. Empty by default.                                                                                                                       |
| `YD_PRIVATE_IP`               | The instance's private IP address. Empty by default.                                                                                                                      |
| `YD_WORKER_TARGET_COUNT`      | The number of workers to create per Node or per vCPU (as determined by `YD_WORKER_TARGET_TYPE`). By default, `1`.                                                         |
| `YD_WORKER_TARGET_TYPE`       | Must be set to `"PER_NODE"` or `"PER_VCPU"`. By default, `"PER_NODE"`.                                                                                                    |
| `YD_URL`                      | The URL of the YellowDog Platform's REST API. By default, `https://api.yellowdog.ai`.                                                                                     |

Note that re-running the script overwrites all files, including `application.yaml`, so any changes made to the Agent's configuration by hand will be lost.

## Additional User Data Scripts

The [userdata](userdata) directory contains optional scripts that add commonly needed capabilities to an instance. Each is run as root **after** the installer script, and works whether it is concatenated with the installer in the same user data, downloaded and run separately, or run by hand.

| Script                                                       | What it does                                                                                                                                                                                                                                                                     |
|--------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| [add-task-type.sh](userdata/add-task-type.sh)                | Adds a Task Type to `application.yaml`, unless one of the same name exists, and restarts the Agent. Set `YD_TASK_TYPE_NAME` and `YD_TASK_TYPE_RUN` (by default, `python` and `python3`).                                                                                       |
| [install-docker.sh](userdata/install-docker.sh)              | Installs, enables and starts Docker: the distribution's `docker.io` package on Ubuntu and Debian, `docker` on Amazon Linux and SUSE, and `docker-ce` from Docker's own repository on Red Hat-based distributions. On Ubuntu and Debian it also disables `unattended-upgrades` (see below). |
| [add-docker-task-type.sh](userdata/add-docker-task-type.sh)  | Adds a `docker` Task Type that runs each Task in its own container (see below), adds `yd-agent` to the `docker` group, and restarts the Agent. Run it after `install-docker.sh`.                                                                                              |
| [add-rclone-s3.sh](userdata/add-rclone-s3.sh)                | Adds an Amazon S3 remote to the rclone configuration used by the Agent's data client (see below).                                                                                                                                                                              |

The scripts are tested automatically, after the installer, on Ubuntu 24.04, Debian 12, AlmaLinux 9, Rocky Linux 10, Amazon Linux 2023 and SLES 15 SP7, on both `amd64` and `arm64`.

### Using the Scripts as User Data

Concatenate the scripts after the installer, keeping `install-docker.sh` before `add-docker-task-type.sh`, e.g., using the YellowDog CLI:

```toml
[workerPool]
userDataFiles = ["yd-agent-installer.sh", "install-docker.sh", "add-docker-task-type.sh"]
```

Settings can be supplied in a short script placed before the one that uses them, e.g., one containing `YD_TASK_TYPE_NAME="my-task-type"` and `YD_TASK_TYPE_RUN="/usr/bin/my-executable"` before `add-task-type.sh`. To add several Task Types, repeat this pair of files.

Cloud providers limit the size of user data (to 16 KB on AWS), and the installer and the two Docker scripts together take most of this. Alternatively, the user data can download and run each script in turn; settings must then be exported:

```shell
#!/bin/bash

set -euo pipefail

BASE=https://raw.githubusercontent.com/yellowdog/resources/refs/heads/main/agent-install/linux
SCRIPT=$(mktemp)
trap 'rm -f "$SCRIPT"' EXIT

for NAME in yd-agent-installer.sh userdata/install-docker.sh userdata/add-docker-task-type.sh
do
  curl -fLsS --retry 5 --retry-connrefused -o "$SCRIPT" "$BASE/$NAME"
  bash "$SCRIPT"
done
```

Re-running the installer rewrites `application.yaml`, removing any Task Types added by `add-task-type.sh` or `add-docker-task-type.sh`, so re-run those scripts after it.

### Why `install-docker.sh` Disables `unattended-upgrades`

On Ubuntu and Debian, `unattended-upgrades` installs updates in the background shortly after boot, using CPU time and network bandwidth on every instance that starts, and holding the package manager's lock while it does so. The script disables it permanently. Instances therefore do not apply security updates automatically: keep the image itself up to date instead, or re-enable the service with `systemctl enable --now unattended-upgrades` if automatic updates are required.

### The `docker` Task Type

A Task of type `docker` runs `docker run <the Task's arguments>`, so its arguments are any `docker run` options followed by the image name and, optionally, the command to run in the container, e.g. `ubuntu:24.04 echo "Hello"`. The Task's working directory is mounted in the container at `/yd_working`, which is also passed to the container as the environment variable `YD_WORKING`.

If the Task is aborted, the container is stopped, then killed if it has not stopped within 10 seconds. The following optional Task environment variables control the container:

| Variable                                                | Description                                                                                                       |
|---------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| `DOCKER_USERNAME`, `DOCKER_PASSWORD`, `DOCKER_REGISTRY` | Credentials used to log in to a registry before the container runs, and to log out afterwards. By default, Docker Hub. |
| `DOCKER_IMAGE`                                          | An image to `docker pull` first, updating any copy already on the instance.                                       |
| `YD_STOP_SIGNAL`                                        | The signal sent to the container to stop it. By default, `SIGTERM`.                                               |
| `YD_STOP_TIMEOUT`                                       | The number of seconds to wait for the container to stop before it is killed. By default, `10`.                   |
| `YD_WORKING`                                            | The directory in the container at which the Task's working directory is mounted. By default, `/yd_working`.      |

### The rclone S3 Remote

`add-rclone-s3.sh` adds a remote named by `YD_RCLONE_REMOTE` (by default, `s3`) to `/opt/yellowdog/agent/.config/rclone/rclone.conf`, the configuration file read by the Agent's data client, keeping any other remotes in the file. Set `YD_S3_REGION` to the region of the buckets; otherwise, rclone assumes `us-east-1`.

By default, the remote authenticates using the instance's IAM role, which is the recommended approach. Alternatively, set `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` to use an access key, which is then stored in the configuration file. Note that user data can be read by any process on the instance that can reach the cloud provider's metadata service, so supplying keys this way exposes them more widely than a role does.
