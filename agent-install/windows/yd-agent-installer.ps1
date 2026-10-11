# YellowDog Agent installer for Windows: installs or upgrades the Agent, writes
# application.yaml and restarts the service. Run as Administrator. Documentation:
# https://github.com/yellowdog/resources/tree/main/agent-install/windows

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
function yd_env ($Name, $Default) {
  $v = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrEmpty($v)) { $Default } else { $v }
}
# Nexus repository (the URL must end in '/download')
$YD_AGENT_REPO_URL = yd_env YD_AGENT_REPO_URL `
  "https://nexus.yellowdog.tech/service/rest/v1/search/assets/download"
$YD_AGENT_REPO_NAME = yd_env YD_AGENT_REPO_NAME "raw-public"
# Setting YD_TOKEN selects a Configured Worker Pool install (see README)
$YD_TOKEN = yd_env YD_TOKEN ""
# Fixed by the Agent package, so not overridable
$YD_AGENT_HOME = "$env:ProgramFiles\YellowDog\Agent"

function yd_log { Write-Host "*** YD $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd_HHmmss'))_UTC: $args" }
function yd_die { yd_log "$args ... aborting"; exit 1 }
trap { yd_die "Unexpected error: $_" }

yd_log "Starting YellowDog Agent Setup"
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  yd_die "Please run as Administrator"
}
# Agent-only environment variable, set by the MSI; there is no cloud metadata
# for a Configured Worker Pool node
$YD_AGENT_METADATA_PROVIDERS = yd_env YD_AGENT_METADATA_PROVIDERS `
  $(if ($YD_TOKEN) { "NONE" } else { "" })
# A 32-bit PowerShell reports x86 here, and the real architecture in PROCESSOR_ARCHITEW6432
$arch = yd_env PROCESSOR_ARCHITEW6432 $env:PROCESSOR_ARCHITECTURE
if ($arch -ne "AMD64") { yd_die "Unsupported architecture '$arch'" }
# Windows PowerShell 5.1 on older Windows Server may not offer TLS 1.2 by default
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor
  [Net.SecurityProtocolType]::Tls12

# Retries cover the network still coming up at boot
function yd_web ($Uri, $OutFile) {
  for ($i = 1; ; $i++) {
    try {
      if ($OutFile) { return Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile }
      return Invoke-RestMethod -UseBasicParsing -Uri $Uri
    } catch {
      if ($i -ge 6) { throw }
      Start-Sleep -Seconds $i
    }
  }
}

$QUERY = "repository=$YD_AGENT_REPO_NAME&group=/agent/msi"
# Nexus sorts versions as text (17.2.9 > 17.2.16), so page through every asset
# and pick the highest
function yd_latest_version {
  $token = $null; $versions = @()
  do {
    $uri = "$($YD_AGENT_REPO_URL -replace '/download$', '')?$QUERY&name=*yd-agent-*"
    if ($token) { $uri += "&continuationToken=$token" }
    try { $page = yd_web $uri } catch { yd_die "Agent version search request failed: $_" }
    foreach ($item in $page.items) {
      if ($item.path -match 'yd-agent-(\d+(\.\d+){1,3})\.msi$') { $versions += [version]($Matches[1]) }
    }
    $token = $page.continuationToken
  } while ($token)
  $versions | Sort-Object | Select-Object -Last 1
}

# Returns $null if the Agent is not installed
function yd_installed_version {
  $keys = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
  $entry = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
    Where-Object { $_.PSObject.Properties["DisplayName"] -and $_.DisplayName -eq "YellowDog Agent" } |
    Select-Object -First 1
  if ($entry) { [version]$entry.DisplayVersion }
}

yd_log "Resolving the latest Agent version"
$AGENT_VERSION = yd_latest_version
if (-not $AGENT_VERSION) { yd_die "Could not determine the latest Agent version" }
$INSTALLED_VERSION = yd_installed_version
# [version] treats 19.1.0 and 19.1.0.0 as different, so compare three fields
function yd_v3 ($v) { if ($v) { "{0}.{1}.{2}" -f $v.Major, $v.Minor, [math]::Max($v.Build, 0) } }
if ((yd_v3 $INSTALLED_VERSION) -eq (yd_v3 $AGENT_VERSION)) {
  # The MSI removes only older versions, so reinstalling the same one achieves nothing
  yd_log "Agent version $AGENT_VERSION is already installed"
  if ($YD_AGENT_METADATA_PROVIDERS) {
    [Environment]::SetEnvironmentVariable("YD_AGENT_METADATA_PROVIDERS",
      $YD_AGENT_METADATA_PROVIDERS, "Machine")
  }
} else {
  if ($INSTALLED_VERSION) { yd_log "Upgrading Agent version $INSTALLED_VERSION" }
  # Private directory: other users can create files in the system Temp directory
  $packageDir = Join-Path $env:SystemRoot "Temp\yd-agent-$([guid]::NewGuid())"
  New-Item -ItemType Directory -Path $packageDir | Out-Null
  icacls $packageDir /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" |
    Out-Null
  if ($LASTEXITCODE -ne 0 -or (Get-ChildItem -Force $packageDir)) {
    yd_die "Could not create a private download directory"
  }
  $packageName = "yd-agent-$AGENT_VERSION.msi"
  $packageFile = Join-Path $packageDir $packageName
  yd_log "Downloading Agent package $packageName"
  try { yd_web "$YD_AGENT_REPO_URL`?$QUERY&name=*$packageName" $packageFile | Out-Null }
  catch { yd_die "Agent package download failed: $_" }

  yd_log "Installing Agent package"
  $installLog = "$env:ProgramData\YellowDog\yd-agent-install.log"
  New-Item -ItemType Directory -Force -Path (Split-Path $installLog) | Out-Null
  $msiArgs = @("/i", "`"$packageFile`"", "/qn", "/norestart", "/l*v", "`"$installLog`"")
  if ($YD_AGENT_METADATA_PROVIDERS) { $msiArgs += "YD_AGENT_METADATA_PROVIDERS=$YD_AGENT_METADATA_PROVIDERS" }
  $exitCode = (Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru).ExitCode
  Remove-Item -Recurse -Force $packageDir
  # 3010: success, but a reboot is required to complete the installation
  if ($exitCode -notin 0, 3010) {
    # As user data, the console log is the only record, so show where the MSI failed
    yd_log "msiexec failed with exit code $exitCode; log excerpt from $installLog`:"
    $failure = Select-String -Path $installLog -Pattern "Return value 3" -Context 20, 0 |
      Select-Object -First 1
    if ($failure) { $failure.Context.PreContext + $failure.Line | Write-Host }
    else { Get-Content $installLog -Tail 20 | Write-Host }
    yd_die "Agent package installation failed"
  }
  if ($exitCode -eq 3010) { yd_log "Agent package installation requires a reboot" }
}
yd_log "Agent package installation complete"

$YD_AGENT_CONFIG = "$YD_AGENT_HOME\config\application.yaml"
if (Test-Path $YD_AGENT_CONFIG) {
  $backup = "$YD_AGENT_CONFIG.backup.$((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd_HHmmss'))_UTC"
  yd_log "Saving existing Agent configuration as $backup"
  Copy-Item $YD_AGENT_CONFIG $backup
}

yd_log "Writing new Agent configuration $YD_AGENT_CONFIG"
# Single quotes: the Agent resolves these ${...} placeholders itself
$config = @'
yda.taskTypes:
  - name: "cmd"
    run: "cmd.exe"
    abort: "yd_abort.bat"
  - name: "powershell"
    run: "powershell.exe"
    abort: "yd_abort.bat"
yda.metrics.script-path: "${YD_AGENT_DATA}/scripts/metrics.bat"
yda.data-client.rclone-binary-path: "${YD_AGENT_HOME}/bin/rclone.exe"

'@

if ($YD_TOKEN) {
  yd_log "Adding Configured Worker Pool properties"
  $hostname = [Net.Dns]::GetHostName()
  $computer = Get-CimInstance Win32_ComputerSystem
  # RAM in GB to the nearest 0.5; the invariant culture keeps '.' as the separator
  $ram = [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F1}",
    [math]::Floor(0.5 + $computer.TotalPhysicalMemory * 2 / 1GB) / 2)
  $config += @"
yda:
  token: "$YD_TOKEN"
  instanceId: "$(yd_env YD_INSTANCE_ID $hostname)"
  provider: "ON_PREMISE"
  hostname: "$(yd_env YD_HOSTNAME $hostname)"
  services-schema.default-url: "$(yd_env YD_URL "https://api.yellowdog.ai")"
  region: "$env:YD_REGION"
  instanceType: "$env:YD_INSTANCE_TYPE"
  sourceName: "$env:YD_SOURCE_NAME"
  vcpus: "$(yd_env YD_VCPUS $computer.NumberOfLogicalProcessors)"
  ram: "$(yd_env YD_RAM $ram)"
  privateIpAddress: "$env:YD_PRIVATE_IP"
  publicIpAddress: "$env:YD_PUBLIC_IP"
  createWorkers:
    targetType: "$(yd_env YD_WORKER_TARGET_TYPE "PER_NODE")"
    targetCount: "$(yd_env YD_WORKER_TARGET_COUNT "1")"
logging.pattern.console: "%d{yyyy-MM-dd HH:mm:ss.SSS} Worker[%10.10thread] %-5level[%40logger{40}] %message [%class{0}:%method:%line]%n"

"@
}
# UTF-8 without a BOM (Windows PowerShell's '-Encoding UTF8' adds one)
[IO.File]::WriteAllText($YD_AGENT_CONFIG, $config, (New-Object Text.UTF8Encoding $false))

# The MSI does not start the service, and SERVICE_STARTUP=Manual may have been
# used by an earlier manual install
yd_log "(Re-)starting Agent service (yd-agent)"
Set-Service -Name yd-agent -StartupType Automatic
Restart-Service -Name yd-agent
yd_log "YellowDog Agent installation complete"
