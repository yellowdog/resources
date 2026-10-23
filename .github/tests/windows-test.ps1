# CI test for yd-agent-installer.ps1, run as Administrator under Windows
# PowerShell 5.1. Runs the installer three times (plain install, Configured
# Worker Pool re-run, plain re-run) and checks the MSI, application.yaml and
# its backups after each.

$ErrorActionPreference = "Stop"
$Installer = Join-Path $PSScriptRoot "..\..\agent-install\windows\yd-agent-installer.ps1"
$AgentHome = "$env:ProgramFiles\YellowDog\Agent"
$Config = "$AgentHome\config\application.yaml"
$script:Failures = 0

function Pass ($Desc) { Write-Host "PASS: $Desc" }
function Fail ($Desc) { Write-Host "FAIL: $Desc"; $script:Failures++ }
function Check ($Desc, [scriptblock]$Test) { if (& $Test) { Pass $Desc } else { Fail $Desc } }

function Get-BackupFile {
  @(Get-ChildItem "$Config.backup.*" -ErrorAction SilentlyContinue | Sort-Object Name)
}
function Get-NewestBackup { (Get-BackupFile | Select-Object -Last 1).FullName }

function Test-AgentInstalled {
  $keys = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
  [bool](Get-ItemProperty $keys -ErrorAction SilentlyContinue |
    Where-Object { $_.PSObject.Properties["DisplayName"] -and $_.DisplayName -eq "YellowDog Agent" })
}

# Compares a file's bytes with the expected text as UTF-8 (no BOM, LF endings)
function Test-Content ($Expected, $Path) {
  if (-not $Path -or -not (Test-Path $Path)) { Write-Host "(missing file: '$Path')"; return $false }
  $actual = [IO.File]::ReadAllText($Path)
  $bytes = [IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    Write-Host "($Path starts with a UTF-8 BOM)"; return $false
  }
  if ($actual -ceq $Expected) { return $true }
  Write-Host "(content mismatch in $Path)`n--- expected ---`n$Expected`n--- actual ---`n$actual"
  return $false
}

# Single quotes: the Agent resolves these ${...} placeholders itself
$ExpectedBase = @'
yda.taskTypes:
  - name: "cmd"
    run: "cmd.exe"
    abort: "yd_abort.bat"
  - name: "powershell"
    run: "powershell.exe"
    abort: "yd_abort.bat"
yda.metrics.script-path: "${YD_AGENT_DATA}/scripts/metrics.bat"
yda.data-client.rclone-binary-path: "${YD_AGENT_HOME}/bin/rclone.exe"

'@ -replace "`r`n", "`n"

# Expected configured file, given the RAM value the installer probed
function Get-ExpectedConfigured ($Ram) {
  $hostname = [Net.Dns]::GetHostName()
  $vcpus = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
  $ExpectedBase + (@"
yda:
  token: "ci-test-token"
  instanceId: "$hostname"
  provider: "ON_PREMISE"
  hostname: "$hostname"
  services-schema.default-url: "https://api.yellowdog.ai"
  region: "ci-region"
  instanceType: ""
  sourceName: ""
  vcpus: "$vcpus"
  ram: "$Ram"
  privateIpAddress: ""
  publicIpAddress: ""
  createWorkers:
    targetType: "PER_NODE"
    targetCount: "2"
logging.pattern.console: "%d{yyyy-MM-dd HH:mm:ss.SSS} Worker[%10.10thread] %-5level[%40logger{40}] %message [%class{0}:%method:%line]%n"

"@ -replace "`r`n", "`n")
}

# Runs the installer in a child process with the given environment, returning
# its output; aborts the test on failure, since later runs depend on it
function Invoke-Installer ($Desc, $Environment = @{}) {
  foreach ($name in $Environment.Keys) { Set-Item "env:$name" $Environment[$name] }
  Write-Host "::group::Installer output: $Desc"
  # Windows PowerShell 5.1 throws on a native command's stderr under "Stop"
  $ErrorActionPreference = "Continue"
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Installer 2>&1 |
    ForEach-Object { "$_" }
  $exitCode = $LASTEXITCODE
  $output | Write-Host
  Write-Host "::endgroup::"
  foreach ($name in $Environment.Keys) { Remove-Item "env:$name" }
  if ($exitCode -eq 0) { Pass "${Desc}: installer exits 0" } else {
    Fail "${Desc}: installer exits 0 (exit code $exitCode)"
    Write-Host "Test aborted after $script:Failures failure(s)"; exit 1
  }
  Check "${Desc}: Agent installed" { Test-AgentInstalled }
  Check "${Desc}: service set to start automatically" {
    (Get-Service yd-agent).StartType -eq "Automatic"
  }
  Write-Host "(yd-agent service status: $((Get-Service yd-agent).Status))"
  $output
}

# Run 1: whether the MSI ships a config of its own is not part of the contract,
# so only later runs count backups
$null = Invoke-Installer "plain install"
Check "plain install: application.yaml" { Test-Content $ExpectedBase $Config }
$backupCount = (Get-BackupFile).Count

# Run 2: same version already installed, now with YD_TOKEN set
Start-Sleep -Seconds 1  # backups are named to the second
$output = Invoke-Installer "configured re-run" @{
  YD_TOKEN = "ci-test-token"; YD_REGION = "ci-region"; YD_WORKER_TARGET_COUNT = "2"
}
Check "configured re-run: MSI not reinstalled" { $output -match "is already installed" }
Check "configured re-run: YD_AGENT_METADATA_PROVIDERS set to NONE" {
  [Environment]::GetEnvironmentVariable("YD_AGENT_METADATA_PROVIDERS", "Machine") -eq "NONE"
}
$ram = ([IO.File]::ReadAllText($Config) -split "`n" |
  Select-String '^  ram: "(.*)"$' | Select-Object -First 1).Matches.Groups[1].Value
Check "configured re-run: ram '$ram' is in GB to the nearest 0.5" { $ram -match '^\d+\.[05]$' }
$expectedConfigured = Get-ExpectedConfigured $ram
Check "configured re-run: application.yaml" { Test-Content $expectedConfigured $Config }
Check "configured re-run: one new backup" { (Get-BackupFile).Count -eq $backupCount + 1 }
Check "configured re-run: previous config backed up" {
  Test-Content $ExpectedBase (Get-NewestBackup)
}

# Run 3: dropping YD_TOKEN rewrites the file wholesale
Start-Sleep -Seconds 1
$null = Invoke-Installer "plain re-run"
Check "plain re-run: application.yaml" { Test-Content $ExpectedBase $Config }
Check "plain re-run: one new backup" { (Get-BackupFile).Count -eq $backupCount + 2 }
Check "plain re-run: previous config backed up" {
  Test-Content $expectedConfigured (Get-NewestBackup)
}

if ($script:Failures -gt 0) { Write-Host "$script:Failures check(s) failed"; exit 1 }
Write-Host "All checks passed"
