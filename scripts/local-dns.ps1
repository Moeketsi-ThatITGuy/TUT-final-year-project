<#
.SYNOPSIS
  Windows: make THIS laptop resolve the failover name (e.g. app.univen-dr-demo.com)
  straight from the hosted zone's Route 53 name servers, so a browser can open
  http://<failover_fqdn> and follow the live failover, without owning the domain.

.DESCRIPTION
  Adds a Name Resolution Policy Table (NRPT) rule for just that one name.
  All other DNS is untouched. Run PowerShell **as Administrator** for on/off.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\local-dns.ps1 on      # after every deploy
  powershell -ExecutionPolicy Bypass -File scripts\local-dns.ps1 status
  powershell -ExecutionPolicy Bypass -File scripts\local-dns.ps1 off     # when you're done
#>
param(
  [Parameter(Position = 0)]
  [ValidateSet('on', 'off', 'status')]
  [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'
$TfDir   = Split-Path -Parent $PSScriptRoot
$Comment = 'univen-cloud local-dns'   # tag so we only ever remove our own rule

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) { throw 'terraform not found on PATH' }

$Fqdn = (& terraform "-chdir=$TfDir" output -raw failover_fqdn).Trim()
if (-not $Fqdn) { throw 'Could not read failover_fqdn. Run this after terraform apply.' }

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OurRules { Get-DnsClientNrptRule | Where-Object { $_.Comment -eq $Comment } }

function Show-Status {
  Write-Host "Failover name: $Fqdn"
  $rules = @(Get-OurRules)
  if ($rules.Count -gt 0) {
    foreach ($r in $rules) { Write-Host "Override:      ON  ($($r.Namespace) -> $($r.NameServers -join ', '))" }
  } else { Write-Host 'Override:      OFF' }
  try {
    $ips = (Resolve-DnsName -Name $Fqdn -Type A -ErrorAction Stop | Where-Object Type -eq 'A').IPAddress -join ' '
    Write-Host "System lookup: $ips"
  } catch { Write-Host 'System lookup: <no answer>' }
}

switch ($Action) {
  'on' {
    if (-not (Test-Admin)) { throw 'Run PowerShell as Administrator for "on".' }
    $nsNames = (& terraform "-chdir=$TfDir" output -json route53_name_servers) | ConvertFrom-Json
    $nsIps = foreach ($ns in $nsNames) {
      try { (Resolve-DnsName -Name $ns -Type A -ErrorAction Stop | Where-Object Type -eq 'A' | Select-Object -First 1).IPAddress } catch { }
    }
    $nsIps = @($nsIps | Where-Object { $_ })
    if ($nsIps.Count -eq 0) { throw 'Could not resolve the Route 53 name servers.' }

    Get-OurRules | ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force }   # replace stale rule
    Add-DnsClientNrptRule -Namespace $Fqdn -NameServers $nsIps -Comment $Comment | Out-Null
    Clear-DnsClientCache
    Write-Host "Done. Open http://$Fqdn in your browser."
    Write-Host "Tip: if the browser doesn't follow a failover, clear its DNS cache"
    Write-Host "     (Edge/Chrome: edge://net-internals/#dns -> Clear host cache) or open a new InPrivate window."
    Write-Host ''
    Show-Status
  }
  'off' {
    if (-not (Test-Admin)) { throw 'Run PowerShell as Administrator for "off".' }
    $rules = @(Get-OurRules)
    if ($rules.Count -eq 0) { Write-Host 'Nothing to remove.' }
    else { $rules | ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force }; Clear-DnsClientCache; Write-Host 'Override removed.' }
  }
  'status' { Show-Status }
}
