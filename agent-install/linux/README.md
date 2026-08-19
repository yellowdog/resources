# YellowDog Agent Installer Script

## Overview 

The [yd-agent-installer.sh](yd-agent-installer.sh) script can be used to install and configure the YellowDog Agent and its dependencies, on Linux.

The script is designed to work with recent Linux distributions based on **Debian**, **Red Hat**, and **SUSE**. The following specific distributions have been tested, using AWS instances:

- AlmaLinux 9.1
- Amazon Linux 2
- CentOS Stream 9
- Debian 11
- Debian 12
- Red Hat Enterprise Linux 9.1
- Rocky Linux 9
- SUSE SLES 15 SP4
- Ubuntu 20.04
- Ubuntu 22.04
- Ubuntu 24.04

## Installation Process

The script downloads the latest installation package from YellowDog's Nexus software repository. Installation packages are available in `.deb` and `.rpm` forms for different Linux variants, and for the `amd64` and `arm64` architectures. The appropriate installer for the platform on which the script is run will be selected and downloaded.

The installation package contains the YellowDog Agent JAR file and a self-contained Java Runtime Environment (JRE).

## Installation Actions

The installation process performs the following actions:

1. Creates a new user and group `yd-agent` with home directory `/opt/yellowdog/agent`, and a data directory at `/var/opt/yellowdog/agent/data`. The installer unpacks the `agent.jar` file and the JRE into the Agent's home directory.
2. Creates the Agent's configuration file (`application.yaml`) and its startup script, in the Agent's home directory.
3. Configures the Agent as a `systemd` service and starts the `yd-agent` service.

Output from the package installation and the service restart is recorded in `/var/log/yd-agent-install.log`. The script's own progress messages go to its standard output, prefixed with `*** YD`; if the script is supplied as instance user data these are captured in the instance's cloud-init output log.

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

The script can also be used to **install the YellowDog components dynamically** on any Linux instance, by supplying it as all or part of the **user data** for the instance. For example, the following could be specified using the Python Examples scripts as follows:

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

The following simple wrapper script is sometimes useful as an alternative to the full installer script (which is downloaded then run). The script is more compact, hence uses less of the user data payload budget.

```shell
#!/bin/bash

set -eu

cd /root
echo "Downloading the Agent installer script"
curl -fLsS -o yd-agent-installer.sh \
  https://raw.githubusercontent.com/yellowdog/resources/refs/heads/main/agent-install/linux/yd-agent-installer.sh

# Install/update the Agent; this also (re-)starts the Agent service
bash yd-agent-installer.sh
```

When using dynamic Agent installation, bear in mind that **every** provisioned instance will incur the costs of downloading the YellowDog installation package (about 60MB). We therefore recommend against using this approach when provisioning instances at scale: use a custom image instead, with the Agent pre-installed.

### Configured Worker Pool Installation

The installer script can also be used to install and configure the YellowDog Agent on systems that will be included in **Configured Worker Pools**.

Configured Worker Pools are on-premise systems, or systems that were otherwise not provisioned via the YellowDog Scheduler, e.g., instances/hosts that were provisioned directly using on-premise provisioners or via a cloud provider console. Adding the YellowDog Agent to these systems allows them to participate in YellowDog Task scheduling.

To use this feature:

1. Set the variable `YD_CONFIGURED_WP` to `"TRUE"`. This will activate the population of additional properties in the Agent's `application.yaml` configuration file (since these will not be set automatically as they are in the case of instances in Provisioned Worker Pools).
2. Supply a value for `YD_TOKEN`, matching the token of the YellowDog Configured Worker Pool to which this host will register. 

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
| `YD_URL`                      | The URL of the YellowDog Platform's REST API. By default, `https://portal.yellowdog.co/api`.                                                                              |

Note that re-running the script overwrites all files, including `application.yaml`, so any changes made to the Agent's configuration by hand will be lost.
