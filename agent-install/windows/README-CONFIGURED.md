# Setting up a Windows Configured Worker Pool Node

This README provides instructions for installing and configuring the YellowDog Agent on Windows systems for use within Configured Worker Pools.

There are four steps:

1. Download and install the YellowDog Agent
2. Populate the YellowDog Agent configuration file `application.yaml`
3. Start the YellowDog Agent service
4. Check that the Agent is running

The installation steps have been tested on Windows Server 2022.

## (1) Download and Install the YellowDog Agent

1. The latest version of the YellowDog Agent installer can be downloaded from YellowDog's Nexus software repository at: https://nexus.yellowdog.tech/repository/raw-public/agent/msi/yd-agent-17.4.0.msi.

The installer includes a self-contained, minimal version of Java, required for Agent execution.

To download the latest version using the command line:

```shell
$ProgressPreference = "SilentlyContinue"
Invoke-WebRequest -Uri 'https://nexus.yellowdog.tech/repository/raw-public/agent/msi/yd-agent-17.4.0.msi' -OutFile yd-agent-17.4.0.msi
```

2. In the directory to which the file has been downloaded, run the installer from the command line as Administrator:

```shell
msiexec /i yd-agent-17.4.0.msi /passive /log yd-agent-install.log SERVICE_STARTUP=Manual YD_AGENT_METADATA_PROVIDERS=NONE
```
Installation will show a progress bar but will not require user interaction.

The `YD_AGENT_METADATA_PROVIDERS` parameter should be set to `NONE` for configured installations.

The `SERVICE_STARTUP=Manual` parameter stops the Agent service from starting up before its configuration has been populated in step (2). This parameter sets the service's startup type permanently, which is why step (3) below sets it back to `Automatic`.

## (2) Populate the YellowDog Agent Configuration File

Overwrite the contents of the file `C:\Program Files\YellowDog\Agent\config\application.yaml` with the contents obtained from the YellowDog Portal:

- Go to the **Workers** tab in the Portal
- Create (or select) the desired **Configured Worker Pool**
- Copy the text supplied using the **Agent Configuration: View** button

Example contents obtained this way are shown below, but with the `taskTypes` modified and the
Worker Pool token replaced by a placeholder. The token is a secret that allows the Agent to
register with the platform, so treat the contents of `application.yaml` accordingly.

```yaml
yda:
  # The task types that can be run by the agent. These are default values and should be replaced with task types corresponding to the work to be performed on the node.
  taskTypes:
      - name: "cmd"
        run: "cmd.exe"
        abort: "yd_abort.bat"
      - name: "powershell"
        run: "powershell.exe"
        abort: "yd_abort.bat"

  # Paths to the default metrics script and rclone binary
  metrics.script-path: "${YD_AGENT_DATA}/scripts/metrics.bat"
  data-client.rclone-binary-path: "${YD_AGENT_HOME}/bin/rclone.exe"
  
  # The instance provider. This is a default value and can be changed. Value must be one of the following: ALIBABA, AWS, GOOGLE, AZURE, OCI, ON_PREMISE
  provider: "ON_PREMISE"

  # An identifier for this machine that must be unique within a Worker Pool. This default value will change each time the agent is started, so any restarts will cause it to be identified as a new node. For long-running machines, this should instead be set to any durable value that is unique within a worker pool e.g. hostname
  instanceId: "${random.uuid}"

  # The type of the instance. This is a default value and can be changed.
  instanceType: "custom"

  createWorkers:
    # The target type. This is a default value and can be changed.
    targetType: PER_NODE

    # The number of desired workers. This is a default value and can be changed.
    targetCount: 1

  # The worker pool token. This value should remain the same.
  token: "<the Worker Pool token supplied by the Portal>"

  # The target URL. This value should remain the same.
  services-schema.default-url: "https://portal.yellowdog.co/api/"

# The pattern used when logging. This is a default value and can be changed.
logging.pattern.console: "%d{yyyy-MM-dd HH:mm:ss.SSS} Worker[%10.10thread] %-5level[%40logger{40}] %message [%class{0}:%method:%line]%n"
```

Adjust the contents of the `application.yaml` file as required -- e.g., to add your own Task Types. For full details of the available options please see the [YellowDog Documentation](https://docs.yellowdog.co/#/the-platform/using-variables-in-the-configuration-file).

Two adjustments are recommended for any long-lived on-premise machine, and are described below.

### Node Identity

The default `instanceId` of `${random.uuid}` changes each time the Agent is started, so the machine is registered as a new node on every restart. Set `instanceId` to a value that is durable and unique within the Worker Pool -- the machine's hostname is usually the most convenient choice -- and set the `hostname` property to match:

```yaml
yda:
  instanceId: "my-machine-name"
  hostname: "my-machine-name"
```

This is what the [Linux installer script](../linux/README.md) in this repository does for Configured Worker Pool nodes, using the output of `hostname` for both properties.

### Node Resources

For a Configured Worker Pool node there is no cloud provider to describe the machine, so nothing will supply its resource details unless the Agent's configuration does. Add the number of vCPUs and the amount of RAM (in GB) within the `yda:` block:

```yaml
yda:
  vcpus: "8"
  ram: "32.0"
```

The values for the local machine can be found using PowerShell:

```powershell
(Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
```

Other optional properties describing the node -- including `region`, `instanceType`, `sourceName`, `privateIpAddress` and `publicIpAddress` -- can be set in the same way.

### Abort Handlers

If a Task is aborted before it has concluded it can leave orphan processes (etc.) running and taking up resources. To prevent this, the Task Types include an *optional* `abort:` clause, pointing to a Windows batch script that can implement appropriate clean-up steps on abort.

If the `abort:` clause is present its batch file will be called by the Agent on Task abort, and it is passed the process ID of the Task as its first and only argument. The abort batch file then assumes **all** responsibility for terminating the Task process itself and anything else that needs to be cleaned up.

The YellowDog Agent Installer supplies a default abort handler, found in `C:\ProgramData\YellowDog\Agent\scripts\yd_abort.bat`. This simple handler will kill the Task process and its entire process tree, as shown below:

```
@REM This script is called by the YellowDog Agent when a Task is aborted.
@REM The Process ID of the Task is supplied as the first (and only) parameter.
@REM The script takes over all responsibility for aborting the Task and any
@REM subprocesses, etc.
@REM The script below kills the Task and its process tree.
taskkill /F /T /PID %1
```

You can add your own abort handler(s) if more sophisticated abort handling is required.

## (3) Start the YellowDog Agent Service

Now that the Agent's configuration is populated, run the following commands as Administrator:

```powershell
Set-Service -Name yd-agent -StartupType Automatic
Start-Service -Name yd-agent
```

The first command is required because the installation in step (1) used `SERVICE_STARTUP=Manual`, which permanently sets the service's startup type to `Manual`: without setting it back to `Automatic`, the Agent will not be restarted when the machine reboots.

The equivalent commands for `cmd.exe` are shown below. Note that `sc.exe` must be spelled out in full when using PowerShell, in which `sc` is an alias for `Set-Content`.

```bat
sc.exe config yd-agent start= auto
sc.exe start yd-agent
```

Both commands only need to be run once. Subsequently, the service will start automatically on every reboot.

## (4) Check that the Agent is Running

The Agent runs as the Windows service `yd-agent`, and its state can be checked using:

```powershell
Get-Service -Name yd-agent
sc.exe qc yd-agent
```

The first command should report a status of `Running`, and the second should show `START_TYPE : 2   AUTO_START`. The installation itself is recorded in the log file named in the `msiexec` command in step (1) -- `yd-agent-install.log`, in the directory from which the installer was run.

The Windows system should now appear in the Configured Worker Pool within the YellowDog Portal, and be available as a target for YellowDog Task Scheduling.
