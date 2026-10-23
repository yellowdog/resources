# YellowDog Agent Installer Script for Windows

> **Status:** the script's installation, re-runs and generated configuration are tested automatically on Windows Server 2022 and 2025. Registration of the installed Agent with the YellowDog Platform has not yet been tested end-to-end.

## Overview

The [yd-agent-installer.ps1](yd-agent-installer.ps1) script installs or upgrades the YellowDog Agent on Windows, writes its configuration file `application.yaml` and (re-)starts the `yd-agent` service. It is the Windows counterpart of the [Linux installer script](../linux/README.md) and accepts the same settings. It automates the step-by-step guides for [custom images](README.md) and [Configured Worker Pools](README-CONFIGURED.md), each of which compares its manual steps with the script.

It requires Windows PowerShell 5.1 (or PowerShell 7) on 64-bit (`x64`) Windows: no Agent installer is published for ARM64 Windows. It must be run as Administrator.

To download the script:

```powershell
$ProgressPreference = "SilentlyContinue"
Invoke-WebRequest -UseBasicParsing -Uri https://raw.githubusercontent.com/yellowdog/resources/refs/heads/main/agent-install/windows/yd-agent-installer.ps1 -OutFile yd-agent-installer.ps1
```

## How the Script Works

The script:

1. Checks its settings (see below) before changing anything.
2. Finds the highest Agent version available in YellowDog's Nexus repository.
3. If that version is not already installed, downloads its MSI into a private directory and installs it unattended with `msiexec`, upgrading any older version. Downloads are retried, since user data runs while the network may still be starting.
4. Saves any existing `application.yaml` as `application.yaml.backup.<timestamp>`, then writes a new one to `C:\Program Files\YellowDog\Agent\config\application.yaml`. Any hand edits to the file are replaced, but they are kept in the backup.
5. Sets the `yd-agent` service's startup type to `Automatic` and (re-)starts it.

The script can be re-run at any time, e.g., to upgrade the Agent in place. Note that an MSI upgrade on its own replaces `application.yaml` (see [Upgrading the Agent](README.md#upgrading-the-agent)); the script's backup-and-rewrite step makes that harmless.

The verbose MSI log is written to `C:\ProgramData\YellowDog\yd-agent-install.log`. The script's own progress messages go to its output, prefixed with `*** YD`; if the script fails during the MSI installation it prints the relevant part of the MSI log and stops.

The Agent's installation directory is always `C:\Program Files\YellowDog\Agent`: it is set by the Agent package and cannot be changed.

## Script Settings

The following variables control the script. Each can be set as an environment variable before the script runs (e.g., `$env:YD_AGENT_REPO_NAME = "raw-public"`), or edited in the script itself.

| Variable                      | Description                                                                                                                                         |
|-------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------|
| `YD_AGENT_REPO_URL`           | The Nexus download URL for Agent packages. It must end in `/download`. By default, `https://nexus.yellowdog.tech/service/rest/v1/search/assets/download`. |
| `YD_AGENT_REPO_NAME`          | The Nexus repository name. By default, `raw-public`.                                                                                                |
| `YD_TOKEN`                    | Setting this installs for a Configured Worker Pool (see [below](#configured-worker-pool-installation)). Unset by default, which installs for a Provisioned Worker Pool. |
| `YD_AGENT_METADATA_PROVIDERS` | The cloud instance metadata provider(s) the Agent should use: `AWS`, `AWS_V2`, `AZURE`, `GOOGLE`, `OCI` or `NONE`. It is passed to the MSI, which records it as a system environment variable read by the Agent. By default, `NONE` for a Configured Worker Pool and unset otherwise. |

## YellowDog Task Types

By default, two general-purpose Task Types are defined, `cmd` and `powershell`, each using the default [abort handler](README.md#abort-handlers) supplied with the Agent:

```yaml
yda.taskTypes:
  - name: "cmd"
    run: "cmd.exe"
    abort: "yd_abort.bat"
  - name: "powershell"
    run: "powershell.exe"
    abort: "yd_abort.bat"
```

These are flexible but liberal: they can execute arbitrary commands on the instance. Edit the `$config` section of the script to customise the Task Types for your own requirements. Retain the `yda.metrics.script-path` and `yda.data-client.rclone-binary-path` settings: without them the Agent will not collect metrics or perform rclone-based data movement.

## Modes of Use

### Custom Image Creation

Run the script as Administrator on an instance built from a base image of your choice, then capture a custom image from it, as described in steps (3) to (5) of the [custom image guide](README.md). This replaces steps (1) and (2) of that guide:

```powershell
powershell -ExecutionPolicy Bypass -File yd-agent-installer.ps1
```

To optimise Agent startup, set `YD_AGENT_METADATA_PROVIDERS` (e.g., `$env:YD_AGENT_METADATA_PROVIDERS = "AWS"`) before running the script. The state of the service on the instance used to build the image does not matter: its startup type is `Automatic`, so instances provisioned from the image start the Agent at boot.

### Dynamic Agent Installation

Running the script as **user data**, to install the Agent while an instance boots, is **not currently supported on stock Windows images**. YellowDog delivers user data to Windows instances in the cloud-init multi-part format, which EC2Launch v2 on standard AWS Windows AMIs does not run. Boot-time scripts therefore need an image that includes [CloudBase-Init](README.md#3-optional-download-and-install-cloudbase-init), and an image built for that purpose might as well have the Agent pre-installed, as described above.

Installing at boot would also download the Agent MSI (about 100 MB) on every instance, so a custom image with the Agent pre-installed is the better choice when provisioning at scale in any case.

### Configured Worker Pool Installation

The script can also install and configure the Agent on Windows systems that will be included in **Configured Worker Pools**, replacing the manual steps in the [Configured Worker Pool guide](README-CONFIGURED.md).

To use this feature, supply the Worker Pool's token in `YD_TOKEN`, which is what selects a Configured Worker Pool install, then run the script as Administrator:

```powershell
$env:YD_TOKEN = "<the Worker Pool token>"
powershell -ExecutionPolicy Bypass -File yd-agent-installer.ps1
```

The following variables describe the node. Default values are provided for all of them except `YD_TOKEN`. For more information on these properties, please see the [YellowDog Documentation](https://docs.yellowdog.co/#/the-platform/using-variables-in-the-configuration-file).

| Property                 | Description                                                                                                                                         |
|--------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------|
| `YD_TOKEN` (Required)    | The token that identifies the Configured Worker Pool to which this node belongs, and which allows the Agent to connect to the platform.            |
| `YD_INSTANCE_ID`         | A node identifier, which must be unique within a Worker Pool. By default, the machine's hostname.                                                  |
| `YD_HOSTNAME`            | The hostname of the node. By default, the machine's hostname.                                                                                      |
| `YD_REGION`              | A string describing the region in which the node is located. Empty by default.                                                                     |
| `YD_SOURCE_NAME`         | A string describing the 'source name' from which the node comes, e.g.: "VMware 01". Empty by default.                                             |
| `YD_INSTANCE_TYPE`       | A string describing the type of the node. Empty by default.                                                                                        |
| `YD_RAM`                 | The node's RAM in GB. By default, the total physical memory, rounded to the nearest 0.5 GB.                                                        |
| `YD_VCPUS`               | The node's vCPU count. By default, the number of logical processors.                                                                               |
| `YD_PUBLIC_IP`           | The node's public IP address. Empty by default.                                                                                                    |
| `YD_PRIVATE_IP`          | The node's private IP address. Empty by default.                                                                                                   |
| `YD_WORKER_TARGET_COUNT` | The number of workers to create per Node or per vCPU (as determined by `YD_WORKER_TARGET_TYPE`). By default, `1`.                                  |
| `YD_WORKER_TARGET_TYPE`  | Must be set to `"PER_NODE"` or `"PER_VCPU"`. By default, `"PER_NODE"`.                                                                             |
| `YD_URL`                 | The URL of the YellowDog Platform's REST API. By default, `https://api.yellowdog.ai`.                                                              |

`application.yaml` contains the Worker Pool token, so treat it (and its backups) as a secret. Re-running the script overwrites `application.yaml`, so any changes made to it by hand will be lost, apart from the backup copy.
