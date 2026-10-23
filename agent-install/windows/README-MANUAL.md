# Creating a YellowDog-Ready Windows Custom Image

This README provides instructions for installing and configuring the YellowDog Agent on Windows instances to be used with Provisioned Worker Pools.

There are five steps:

1. Install the YellowDog Agent
2. Populate the YellowDog Agent configuration file `application.yaml`
3. Optional: Install CloudBase-Init (only required if there's a need to run user-supplied (userdata) scripts at instance boot time)
4. Create a custom image (e.g., an AWS AMI) based on the Windows instance that can be used for subsequent provisioning.
5. Register the image in a YellowDog Image Family of type `Windows`.

## Installing by Script or by Hand

Steps (1) and (2) can be carried out in one go by the [Windows installer script](README-INSTALLER.md), run as Administrator:

```powershell
$ProgressPreference = "SilentlyContinue"
Invoke-WebRequest -UseBasicParsing -Uri https://raw.githubusercontent.com/yellowdog/resources/refs/heads/main/agent-install/windows/yd-agent-installer.ps1 -OutFile yd-agent-installer.ps1
$env:YD_AGENT_METADATA_PROVIDERS = "AWS"  # optional: see step (1)
powershell -ExecutionPolicy Bypass -File yd-agent-installer.ps1
```

Then continue from step (3). The two approaches compare as follows:

| Step                                 | By hand (this guide)                                                         | With the installer script                                                                                              |
|--------------------------------------|------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| (1) Install the Agent                | Download the newest MSI and run `msiexec`                                    | The same, unattended; skipped if the newest version is already installed                                              |
| (2) Populate `application.yaml`      | Edit the file to add Task Types, keeping the metrics and rclone settings     | Writes the whole file, with `cmd` and `powershell` Task Types; any existing file is kept as a timestamped backup |
| Agent service                        | Left stopped, with startup type `Automatic`                                  | Set to `Automatic` and started                                                                                         |
| (3) to (5) Image creation            | The same either way                                                          | The same either way                                                                                                    |

Either way, the service's startup type is `Automatic`, so instances provisioned from the image start the Agent at boot. Follow the manual steps below to see or control each step, or to use Task Types other than the script's defaults without editing the script.

## (1) Download and Install the YellowDog Agent

1. YellowDog Agent installers are published in YellowDog's Nexus software repository, where all available versions can be browsed at https://nexus.yellowdog.tech/service/rest/repository/browse/raw-public/agent/msi/.

The installer includes a self-contained, minimal version of Java, required for Agent execution.

To find and download the newest version as `yd-agent.msi`, run the following in PowerShell:

```powershell
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$uri = "https://nexus.yellowdog.tech/service/rest/v1/search/assets?repository=raw-public&group=/agent/msi"
$msis = @(); $token = $null
do {
  $page = Invoke-RestMethod -UseBasicParsing ($uri + $(if ($token) { "&continuationToken=$token" }))
  $msis += $page.items | Where-Object path -match 'yd-agent-[\d.]+\.msi$'
  $token = $page.continuationToken
} while ($token)
$latest = $msis | Sort-Object { [version]($_.path -replace '.*yd-agent-([\d.]+)\.msi$', '$1') } | Select-Object -Last 1
Write-Host "Downloading $($latest.path)"
Invoke-WebRequest -UseBasicParsing -Uri $latest.downloadUrl -OutFile yd-agent.msi
```

The versions are compared numerically, because Nexus sorts them as text (placing, e.g., `20.2.9` above `20.2.10`). To install a specific version instead, download it from the page above and use its file name in place of `yd-agent.msi` below.

2. In the directory to which the file has been downloaded, run the installer from the command line as Administrator:

```bat
msiexec /i yd-agent.msi /passive /l*v yd-agent-install.log
```
Installation will show a progress bar but will not require user interaction.

An optional `YD_AGENT_METADATA_PROVIDERS` argument can be supplied to the installer to optimise Agent startup. Set it with the appropriate provider name(s) for your image from these options: `AWS`, `AWS_V2`, `AZURE`, `GOOGLE` or `OCI`, e.g.:

```bat
msiexec /i yd-agent.msi /passive /l*v yd-agent-install.log YD_AGENT_METADATA_PROVIDERS=AWS
```

A value of `NONE` is also accepted, for systems that are not cloud-provisioned -- see the [Configured Worker Pool guide](README-CONFIGURED-MANUAL.md).

The installer records the value as a system environment variable, so it can be changed subsequently by editing the environment variable and restarting the Agent service, instead of by reinstalling.

## (2) Populate the YellowDog Agent Configuration File

Edit the file `C:\Program Files\YellowDog\Agent\config\application.yaml` to insert the **Task Types** that will be supported -- e.g.:

```powershell
notepad "C:\Program Files\YellowDog\Agent\config\application.yaml"
```

An example populated `application.yaml` configuration file is shown below:

```yaml
yda.taskTypes:
  - name: "cmd"
    run: "cmd.exe"
    abort: "yd_abort.bat"
  - name: "powershell"
    run: "powershell.exe"
    abort: "yd_abort.bat"

yda.metrics.script-path: "${YD_AGENT_DATA}/scripts/metrics.bat"
yda.data-client.rclone-binary-path: "${YD_AGENT_HOME}/bin/rclone.exe"
```

Note that this will set up flexible but liberal Task Types that can execute arbitrary commands on the instance. For production use, specific custom Task Type scripts are recommended.

The `application.yaml` file supplied by the installer already contains the `yda.metrics.script-path` and `yda.data-client.rclone-binary-path` settings shown above, together with an empty `yda.taskTypes:` entry. Retain the metrics and rclone settings: without them the Agent will not collect metrics or perform rclone-based data movement.

The Agent service does not need to be restarted here: the installer does not start it, so it is not running on the instance being used to build the image. The configuration edited above takes effect when an instance provisioned from the image boots.

### Abort Handlers

If a Task is aborted before it has concluded it can leave orphan processes (etc.) running and taking up resources. To prevent this, the Task Types include an *optional* `abort:` clause, pointing to a Windows batch script that can implement appropriate clean-up steps on abort.

If the `abort:` clause is present its batch file will be called by the Agent on Task abort, and it is passed the process ID of the Task as its first and only argument. The abort batch file then assumes **all** responsibility for terminating the Task process itself and anything else that needs to be cleaned up.

The YellowDog Agent Installer supplies a default abort handler, found in `C:\ProgramData\YellowDog\Agent\scripts\yd_abort.bat`. This simple handler will kill the Task process and its entire process tree, as shown below:

```bat
@REM This script is called by the YellowDog Agent when a Task is aborted.
@REM The Process ID of the Task is supplied as the first (and only) parameter.
@REM The script takes over all responsibility for aborting the Task and any
@REM subprocesses, etc.
@REM The script below kills the Task and its process tree.
taskkill /F /T /PID %1
```

You can add your own abort handler(s) if more sophisticated abort handling is required.

### Checking the Agent

The Agent runs as the Windows service `yd-agent`, and its state can be checked using:

```powershell
Get-Service -Name yd-agent
```

A status of `Stopped` is expected on the instance being used to build the image -- the installer does not start the service -- and is not a sign that the installation has failed.

The installation itself is recorded in the log file named in the `msiexec` command in step (1) -- `yd-agent-install.log`, in the directory from which the installer was run.

The Agent logs to its console, and the service launcher redirects that output to two files in the installation directory:

- `C:\Program Files\YellowDog\Agent\output.log`
- `C:\Program Files\YellowDog\Agent\error.log`

These two paths are recorded in the `Agent.ini` file alongside them, and can be changed there if required, restarting the Agent service afterwards. Note that the files are not rotated, and that the launcher is not configured to append to them, so they are best treated as the output of the current run of the Agent rather than as a complete history.

## (3) Optional: Download and Install CloudBase-Init

**[CloudBase-Init](https://cloudbase.it/cloudbase-init/)** runs at instance boot time and is used to execute user-supplied scripts/actions on the instance.

1. Download the installer from https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi

To download the latest version using the command line:

```powershell
$ProgressPreference = "SilentlyContinue"
Invoke-WebRequest -Uri 'https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi' -OutFile CloudbaseInitSetup_Stable_x64.msi
```

2. In the directory to which the file has been downloaded, run the installer from the command line as Administrator using the following command:

```bat
msiexec /i CloudbaseInitSetup_Stable_x64.msi /passive /l*v cloudbase-init-install.log
```

Installation will show a progress bar but will not require user interaction.

## (4) Create a Custom Image

The instance is now ready for creation of a custom image for use with YellowDog.

The Agent service requires no attention before the image is captured: it is not running, and its startup type of `Automatic` is carried into the image, so the Agent will start when an instance provisioned from the image boots, taking its identity from the instance metadata at that point.

Follow your cloud provider's own procedure for generalising and capturing a Windows image -- e.g., the Sysprep support provided by EC2Launch v2 on AWS. If CloudBase-Init was installed in step (3), please also see its [Sysprepping](https://cloudbase-init.readthedocs.io/en/latest/tutorial.html#sysprepping) documentation; note that the installer's optional Sysprep step is not performed by the unattended `msiexec` command shown above.

Make a note of the ID of the custom image that is created, for use below.

## (5) Register the Image within a YellowDog Windows Image Family

- Docs: https://docs.yellowdog.co/#/the-platform/managing-images
- Portal: https://portal.yellowdog.co/#/images

The Windows custom image must be registered within a YellowDog Windows Image Family in order for it to be correctly used within Provisioned Worker Pools.

Add a Windows Image Family (named, e.g., `win-yd-agent` in namespace `win-test`), an Image Group (e.g., `v5_0_3`) and an image (e.g., `win-2022-eu-west-2`) pointing to the image ID of the custom image you've created.

In provisioning requests, the ID or name (e.g., `yd/win-test/win-yd-agent`) of the Image Family you've just created should be used, and YellowDog will then automatically select the correct image (the most recent version applicable to the cloud provider and region).

## Upgrading the Agent

Installing a newer version of the Agent is a major upgrade: the installed version is removed first, and `application.yaml` is replaced by the file supplied with the new package. This was confirmed by upgrading v17.1.1 to v20.2.2.

So if a new custom image is built by installing a newer Agent on an instance created from an earlier image, step (2) must be repeated -- keep a record of the Task Types and any other settings that were added. Re-running the [installer script](README-INSTALLER.md) instead upgrades the Agent and rewrites `application.yaml` in one step, keeping the previous file as a backup.
