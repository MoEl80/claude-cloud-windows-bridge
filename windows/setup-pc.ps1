# Run elevated. Resume only this bridge's verified managed installation.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PcHost,        # the PC's Tailscale IPv4 (tailscale ip -4)
    [Parameter(Mandatory)][string]$PcUser,        # the Windows account the cloud session logs in as
    [string]$PublicKeyPath,                        # default: <that user's profile>\.ssh\cloud_bridge.pub
    [string]$GitBashPath                           # default: auto-detected Git for Windows bash.exe
)
$ErrorActionPreference = 'Stop'
# Windows OpenSSH matches AllowUsers names in lowercase
$PcUser = $PcUser.ToLowerInvariant()
$account = Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" | Where-Object { $_.Name -eq $PcUser } | Select-Object -First 1
if (-not $account) { throw "Local Windows account '$PcUser' not found (use the short account name shown by: whoami)" }
if (-not $PublicKeyPath) {
    # the key belongs to the bridge user, not to whoever runs this elevated window
    $profileDir = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($account.SID)" -ErrorAction SilentlyContinue).ProfileImagePath
    if (-not $profileDir) { throw "No profile folder found for $PcUser; pass -PublicKeyPath" }
    $PublicKeyPath = Join-Path $profileDir '.ssh\cloud_bridge.pub'
}
if (-not (Test-Path $PublicKeyPath)) { throw "Public key not found: $PublicKeyPath (create it first, see README)" }
if (-not $GitBashPath) {
    $candidates = @((Join-Path $env:ProgramFiles 'Git\bin\bash.exe'), (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'))
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) { $candidates += (Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'bin\bash.exe') }
    $GitBashPath = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $GitBashPath -or -not (Test-Path $GitBashPath)) { throw 'Git Bash not found; install Git for Windows or pass -GitBashPath' }
$root = Split-Path $PSScriptRoot -Parent
$state = Join-Path $root '.state'
New-Item -ItemType Directory -Path $state -Force | Out-Null
Start-Transcript -Path (Join-Path $state 'setup-pc.log') -Append
function Confirm-BridgeReady {
    param([string]$HostAddress)
    $service = Get-Service sshd
    if ($service.Status -ne 'Running') { Start-Service sshd }
    $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(15))
    # CIM's Get-NetTCPConnection returned false negatives here; test the socket itself.
    $client = New-Object Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect($HostAddress, 22, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(5000)) { throw 'SSH TCP readiness failed after 5 seconds' }
        $client.EndConnect($pending)
    } finally { $client.Dispose() }
}
function Show-HostKey {
    # print the PC's own host key so the cloud pin does not depend on a network scan
    $pub = (Get-Content (Join-Path $env:ProgramData 'ssh\ssh_host_ed25519_key.pub') -Raw).Trim()
    $parts = $pub -split ' '
    $line = "$PcHost $($parts[0]) $($parts[1])"
    Write-Output ''
    Write-Output 'Set this in the cloud environment:'
    Write-Output ('PC_SSH_HOSTKEY_B64=' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$line`n")))
}
try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator elevation required' }
    $marker = Join-Path $state 'pc-installed.json'
    $cfg = Join-Path $env:ProgramData 'ssh\sshd_config'
    $existing = Get-Service sshd -ErrorAction SilentlyContinue
    if ($existing -or (Test-Path $cfg) -or (Test-Path $marker)) {
        $header = '# Managed by PC-Bridge. Dedicated key file, existing administrators keys are unused.'
        $ak = Join-Path $env:ProgramData 'ssh\pc_bridge_authorized_keys'
        if (-not $existing -or -not (Test-Path $cfg) -or -not (Test-Path $ak)) { throw 'Incomplete or unrelated SSH installation; inspect before resume' }
        $lines = @(Get-Content $cfg)
        if ($lines[0] -ne $header -or $lines -notcontains "ListenAddress $PcHost" -or $lines -notcontains "AllowUsers $PcUser") { throw 'Existing SSH configuration does not match this bridge' }
        if ((Get-Content $ak -Raw).Trim() -ne (Get-Content $PublicKeyPath -Raw).Trim()) { throw 'Managed bridge authorized key mismatch' }
        $shell = (Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH').DefaultShell
        if ($shell -ne $GitBashPath) { throw 'Managed bridge shell mismatch' }
        $rule = Get-NetFirewallRule -Name PC-Bridge-SSH
        $filter = $rule | Get-NetFirewallAddressFilter
        $port = $rule | Get-NetFirewallPortFilter
        # Windows normalizes CIDR /10 to its equivalent dotted subnet mask.
        $remote = @($filter.RemoteAddress)
        $remoteMatches = $remote.Count -eq 1 -and $remote[0] -in @('100.64.0.0/10', '100.64.0.0/255.192.0.0')
        $local = @($filter.LocalAddress)
        if ($rule.Enabled -ne 'True' -or $rule.Action -ne 'Allow' -or $rule.Direction -ne 'Inbound' -or $local.Count -ne 1 -or $local[0] -ne $PcHost -or -not $remoteMatches -or $port.LocalPort -ne '22' -or $port.Protocol -notin @('TCP', '6')) { throw 'Managed bridge firewall rule mismatch' }
        $stock = Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue
        if ($stock -and $stock.Enabled -eq 'True') { throw 'Generic OpenSSH inbound firewall rule is enabled' }
        & "$env:WINDIR\System32\OpenSSH\sshd.exe" -t -f $cfg
        if ($LASTEXITCODE -ne 0) { throw 'Installed SSH configuration is invalid' }
        Confirm-BridgeReady $PcHost
        @{ pcHost=$PcHost; pcUser=$PcUser; verified=(Get-Date -Format o); resumed=$true } | ConvertTo-Json | Set-Content $marker -Encoding ascii
        Show-HostKey
        Write-Output 'PC_BRIDGE_RESUME_PASS'
        exit 0
    }
    $bash = $GitBashPath
    $pubPath = $PublicKeyPath
    $pub = (Get-Content $pubPath -Raw).Trim()
    if ($pub -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+(?: .*)?$') { throw 'Unexpected bridge public key' }
    $reg = 'HKLM:\SOFTWARE\OpenSSH'
    $previous = Get-ItemProperty $reg -ErrorAction SilentlyContinue
    if ($previous.DefaultShell) { throw 'Existing OpenSSH DefaultShell found; review before changing' }
    $cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
    if ($cap.State -ne 'Installed') {
        $result = Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
        if ($result.RestartNeeded) { throw 'OpenSSH installed but Windows restart required' }
    }
    $sshd = "$env:WINDIR\System32\OpenSSH\sshd.exe"
    if (-not (Test-Path $sshd)) { throw 'OpenSSH server installation did not produce sshd.exe' }
    New-Item -ItemType Directory -Path (Split-Path $cfg -Parent) -Force | Out-Null
    if (Test-Path $cfg) { Copy-Item $cfg (Join-Path $state 'sshd_config.before') }
    @"
# Managed by PC-Bridge. Dedicated key file, existing administrators keys are unused.
Port 22
ListenAddress $PcHost
PubkeyAuthentication yes
PasswordAuthentication no
AuthenticationMethods publickey
PermitEmptyPasswords no
AllowUsers $PcUser
AuthorizedKeysFile __PROGRAMDATA__/ssh/pc_bridge_authorized_keys
AllowTcpForwarding no
AllowAgentForwarding no
Subsystem sftp sftp-server.exe
"@ | Set-Content $cfg -Encoding ascii
    $ak = Join-Path $env:ProgramData 'ssh\pc_bridge_authorized_keys'
    $pub | Set-Content $ak -Encoding ascii
    & icacls.exe $ak /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F'
    if ($LASTEXITCODE -ne 0) { throw 'Bridge key ACL failed' }
    & "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe" -A
    if ($LASTEXITCODE -ne 0) { throw 'Host key creation failed' }
    # Keys generated by an elevated user still had that user's owner/Modify ACE;
    # the SYSTEM service failed until private-key ownership/ACLs were corrected.
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Get-ChildItem "$env:ProgramData\ssh\ssh_host_*_key" | ForEach-Object {
        & icacls.exe $_.FullName /setowner '*S-1-5-32-544'
        if ($LASTEXITCODE -ne 0) { throw 'Host key owner update failed' }
        & icacls.exe $_.FullName /remove:g "*$userSid"
        if ($LASTEXITCODE -ne 0) { throw 'Host key user ACE removal failed' }
    }
    & $sshd -t -f $cfg
    if ($LASTEXITCODE -ne 0) { throw 'SSH configuration validation failed' }
    New-Item -Path $reg -Force | Out-Null
    New-ItemProperty -Path $reg -Name DefaultShell -Value $bash -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $reg -Name DefaultShellCommandOption -Value '-c' -PropertyType String -Force | Out-Null
    # Disable the capability's generic rule before starting the service.
    Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue | Disable-NetFirewallRule
    New-NetFirewallRule -Name PC-Bridge-SSH -DisplayName 'PC-Bridge SSH (Tailscale only)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -LocalAddress $PcHost -RemoteAddress '100.64.0.0/10' -Profile Any | Out-Null
    Set-Service sshd -StartupType Automatic
    # sshd binds to the Tailscale IP; if it starts before Tailscale has that address, let Windows retry it
    & sc.exe failure sshd reset= 86400 actions= restart/30000/restart/60000/restart/120000 | Out-Null
    Confirm-BridgeReady $PcHost
    @{ pcHost=$PcHost; pcUser=$PcUser; installed=(Get-Date -Format o); defaultShellPreviouslyAbsent=$true } | ConvertTo-Json | Set-Content $marker -Encoding ascii
    Get-Service sshd | Select-Object Name,Status,StartType
    Show-HostKey
    Write-Output 'PC_BRIDGE_INSTALLED'
} catch {
    $_ | Out-String | Set-Content (Join-Path $state 'setup-error.txt')
    throw
} finally { Stop-Transcript }
