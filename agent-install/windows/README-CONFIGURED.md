# Setting up a Windows Configured Worker Pool Node

This README provides instructions for installing and configuring the YellowDog Agent on Windows systems for use within Configured Worker Pools.

There are four steps:

1. Download the YellowDog Agent installer and install the service
2. Populate the YellowDog Agent configuration file `application.yaml`
3. Start the YellowDog Agent service

The installation steps have been tested on Windows Server 2019 and Windows Server 2022, but should also work on recent Desktop versions of Windows.

## (1) Download and Install the YellowDog Agent Service

1. The latest version of the YellowDog Agent installer can be downloaded from YellowDog's Nexus software repository at: https://nexus.yellowdog.tech/repository/raw-public/agent/msi/yd-agent-5.4.5.msi.

The installer includes a self-contained, minimal version of Java, required for Agent execution.

2. In the directory to which the file has been downloaded, run the installer from the command line as Administrator:

```shell
msiexec /i yd-agent-5.4.5.msi /passive /log yd-agent-install.log SERVICE_STARTUP=Manual
```
Installation will show a progress bar but will not require user interaction.

```shell
msiexec /i yd-agent-<AGENT_VERSION>.msi /passive /log yd-agent-install.log SERVICE_STARTUP=Automatic
```
Installation will show a progress bar but will not require user interaction.

## (2) Populate the YellowDog Agent Configuration File

Overwrite the contents of the file `C:\Program Files\YellowDog\Agent\config\application.yaml` with the contents obtained from the YellowDog Portal:

- Go to the **Workers** tab in the Portal
- Create (or select) the desired **Configured Worker Pool**
- Copy the text supplied using the **Agent Configuration: View** button

Example contents obtained this way are shown below, but with the `taskTypes` modified.

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
  token: "da855e3c-dd0b-478e-b873-47735f831c1b"

  # The target URL. This value should remain the same.
  services-schema.default-url: "https://portal.yellowdog.co/api/"

# The pattern used when logging. This is a default value and can be changed.
logging.pattern.console: "Worker [%10.10thread] %-5level [%40logger{40}] %message [%class{0}:%method\\(\\):%line]%n"
```

Adjust the contents of the `application.yaml` file as required -- e.g., to add your own Task Types. For full details of the available options please see the [YellowDog Documentation](https://docs.yellowdog.co/#/the-platform/using-variables-in-the-configuration-file).

### Abort Handlers

If a Task is aborted before it has concluded it can leave orphan processes (etc.) running and taking up resources. To prevent this, the Task Types include an *optional* `abort:` clause, pointing to a Windows batch script that can implement appropriate clean-up steps on abort.

If the `abort:` clause is present its batch file will be called by the Agent on Task abort, and it is passed the process ID of the Task as its first and only argument. The abort batch file then assumes **all** responsibility for terminating the Task process itself and anything else that needs to be cleaned up.

The YellowDog Agent Installer supplies a default abort handler, `yd_abort.bat`. This simple handler will kill the Task process and its entire process tree, as shown below:

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

Now that the Agent's configuration is populated, manually start the service by running the following command as Administrator:

```shell
sc start yd-agent
```
Note that this only needs to be done once. Subsequently, the service will start automatically on every reboot.

The Windows system should now appear in the Configured Worker Pool within the YellowDog Portal, and be available as a target for YellowDog Task Scheduling.
