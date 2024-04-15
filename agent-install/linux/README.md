# YellowDog Agent Installer Script

## Overview 

The Bash script [yd-agent-installer.sh](yd-agent-installer.sh) can be used to install and configure the YellowDog Agent and its dependencies on Linux. Several different Linux variants are supported.

## Script Actions

The script performs the following actions:

1. Creates a new user `yd-agent` with home directory `/opt/yellowdog/agent`, and a data directory (for use during Task execution) at `/var/opt/yellowdog/agent`.
2. Optionally installs Java 11 using the Linux distro's package manager.
3. Downloads the YellowDog Agent JAR file to the `yd-agent` home directory.
4. Creates the Agent's configuration file (`application.yaml`) and its startup script.
5. Configures the Agent as a `systemd` service and starts the service.
6. Optionally adds `yd-agent` to the list of passwordless sudoers.
7. Optionally adds an SSH public key for `yd-agent`.

**Java installation can be suppressed** if Java (v11 or greater) is already installed, by setting the environment variable `YD_INSTALL_JAVA` in the script to anything other than `"TRUE"`. Note that the Agent startup script expects to find a Java v11+ runtime at `/usr/bin/java`: an existing installation can be verified by running `/usr/bin/java --version`, to check the java executable exists and that it satisfies the version requirement.

The script is designed to work with recent Linux distributions based on **Debian**, **Red Hat**, and **SUSE**. The following specific distributions have been tested, using AWS:

- Ubuntu 22.04
- Debian 10 & 11
- Red Hat Enterprise Linux 9.1
- CentOS Stream 8 & 9
- AlmaLinux 9.1
- Amazon Linux 2 (note that Amaxon Linux 2023 doesn't currently work with YellowDog due to the requirement to use IMDSv2)
- SUSE SLES 15 SP4

## Task Types

By default, a single YellowDog **Task Type**, `bash`, is defined which simply runs Bash scripts:

```yaml
yda:
  taskTypes:
    - name: "bash"
      run: "/bin/bash"
```

Edit this section of the script to customise Task Type(s) for your own requirements. For example, a task type to run a specific executable might look like:

```yaml
yda:
  taskTypes:
    - name: "my-task-type"
      run: "/usr/bin/my-executable"
```

## Passwordless sudo access for yd-agent

Add the following to the end of the script to enable `yd-agent` for passwordless sudo access.

```shell
# Give $YD_AGENT_USER passwordless sudo capability
yd_log "Adding $YD_AGENT_USER to passwordless sudoers"
usermod -aG $ADMIN_GRP $YD_AGENT_USER
echo -e "$YD_AGENT_USER\tALL=(ALL)\tNOPASSWD: ALL" > \
        /etc/sudoers.d/020-$YD_AGENT_USER
```

## Add an SSH Public Key for yd-agent

Add the following to the end of the script to add a public key for `yd-agent`, inserting the public key where indicated.

```shell
# Add a public key for $YD_AGENT_USER
yd_log "Adding SSH public key for user $YD_AGENT_USER"
mkdir -p $YD_AGENT_HOME/.ssh
chmod og-rwx $YD_AGENT_HOME/.ssh
# Insert your public key below, between the two 'EOM' entries
cat >> $YD_AGENT_HOME/.ssh/authorized_keys << EOM
<Insert Public Key Here>
EOM
chmod og-rw $YD_AGENT_HOME/.ssh/authorized_keys
chown -R $YD_AGENT_USER:$YD_AGENT_USER $YD_AGENT_HOME/.ssh
```

## Modes of Use

### Custom Image Creation

The script can be used to **prepare a custom VM image**, by running it on an instance using a base image of your choice and then capturing a new custom image from this instance. Instances booted from the new custom image will be configured to work with the YellowDog Scheduler.

Note the script can be run multiple times. This is useful if one wants to update the version of the Agent, etc.

### Dynamic Agent Installation

The script can also be used to **install the YellowDog components dynamically** on any Linux instance, by supplying it as all or part of the **user data** for the instance. For example, the following could be specified using the Python Examples scripts as follows:

```toml
[workerPool]
userDataFile = "yd-agent-installer.sh"
```

The user data file will be run (as root) when the instance boots, and will configure the instance to work with the YellowDog Scheduler as part of the boot process. Typical total processing time for the installation steps is around 1 minute, in addition to the normal instance boot overheads.

User data scripts can be concatenated using the `userDataFiles` property, for example:

```toml
[workerPool]
userDataFiles = ["set-variables.sh", "yd-agent-installer.sh", "add-sudo.sh"]
```

When using dynamic Agent installation, bear in mind that **every** provisioned instance will incur the costs of installing Java using the distro's package manager (probably using cloud-local repositories for the Linux distro you're using), and also of downloading the YellowDog Agent (about 35MB in size) from YellowDog's external Nexus repository. For these reasons, we recommend against using this approach when provisioning instances at scale: use a custom image instead.

### Configured Worker Pool Installation

The installer script can also be used to install and configure the YellowDog Agent on systems that will be included in **Configured Worker Pools**.

Configured Worker Pools are on-premise systems, or systems that were otherwise not provisioned via the YellowDog Scheduler, e.g., instances/hosts that were provisioned directly using on-premise provisioners or via a cloud provider console. Adding the YellowDog Agent to these systems allows them to participate in YellowDog Task scheduling.

To use this feature:

1. Set the variable `YD_CONFIGURED_WP` to `"TRUE"`. This will activate the population of additional properties in the Agent's `application.yaml` configuration file (since these will not be set automatically as they are in the case of instances in Provisioned Worker Pools).
2. Supply a value for `YD_TOKEN`, matching the token of the YellowDog Configured Worker Pool to which this host will register. 

The variables can be set directly in the script file itself or exported in the environment in which the installer script will run to override the defaults.

The following set of variables is available for specifying the properties of an instance. Default values are provided for all properties except `YD_TOKEN`. For more information on the variables in the `application.yaml` file, please see the [YellowDog Documentation](https://docs.yellowdog.co/#/the-platform/using-variables-in-the-configuration-file).

| Property                 | Description                                                                                                                                                       |
|--------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `YD_TOKEN` (Required)    | This is the token that identifies the Configured Worker Pool to which this instance belongs, and which allows the Agent to connect to the platform.               |
| `YD_INSTANCE_ID`         | An instance identifier, which must be unique within a Worker Pool. By default, the hostname found in `/etc/hostname` is used; if empty, a random ID is generated. |
| `YD_HOSTNAME`            | The hostname of the instance. By default, the hostname found in `/etc/hostname` is used.                                                                          |
| `YD_REGION`              | A string describing the region in which the instance is located. Empty by default.                                                                                |
| `YD_SOURCE_NAME`         | A string describing the 'source name' from which the instance comes, e.g.: "VMware 01". Empty by default.                                                         |
| `YD_INSTANCE_TYPE`       | A string describing the type of the instance. Empty by default.                                                                                                   |
| `YD_WORKER_TAG`          | A string that tags the worker(s), used for matching Task Groups to Workers. Empty by default.                                                                     |
| `YD_RAM`                 | The instance's RAM in GB. By default, the `MemTotal` value obtained from `/proc/meminfo`.                                                                         |
| `YD_VCPUS`               | The instance's VCPU count. By default, the value returned by `nproc`.                                                                                             |
| `YD_PUBLIC_IP`           | The instance's public IP address. Empty by default.                                                                                                               |
| `YD_PRIVATE_IP`          | The instance's private IP address. Empty by default.                                                                                                              |
| `YD_WORKER_TARGET_COUNT` | The number of workers to create per Node or per vCPU (as determined by `YD_WORKER_TARGET_TYPE`). By default, `1`.                                                 |
| `YD_WORKER_TARGET_TYPE`  | Must be set to `"PER_NODE"` or `"PER_VCPU"`. By default, `"PER_NODE"`.                                                                                            |
| `YD_URL`                 | The URL of the YellowDog Platform's REST API. By default, `https://portal.yellowdog.co/api`.                                                                      |
| `YD_SCHEDULE_ENABLED`    | Whether to start/stop the Agent's Workers on a defined schedule. Set to `"true"` to enable a schedule. By default, `"false"`.                                     |
| `YD_SCHEDULE_STARTUP`    | A cron-like list of strings specifying when to start the Agent's Workers. By default, `['0 0 18 * * MON-FRI']`.                                                   |
| `YD_SCHEDULE_SHUTDOWN`   | A cron-like list of strings specifying when to stop the Agent's Workers. By default, `['0 0 7 * * MON-FRI']`.                                                     |

The script can be run multiple times. This is useful if one wants to update the version of the Agent, etc. Note, however, that all files (including `application.yaml`) will be overwritten.
