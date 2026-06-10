<#
.SYNOPSIS
  Side-effect-free change preview (approval gate):
    1. platform what-if  (deploy-platform.ps1 -WhatIf)
    2. azd provision --preview  (Aspire-generated ACA infra diff)

.DESCRIPTION
  Neither step applies changes. The platform what-if may create an EMPTY platform
  resource group so the group-scoped what-if can run, but no billable resources.

  azd provision --preview needs the AppHost parameters (subnet id, SQL server,
  SQL resource group) to be resolvable. If platform has not been applied yet they
  are unknown, so that step is skipped with a hint.
#>
[CmdletBinding()]
param(
    [string] $Location,
    [string] $NamePrefix = 'abg',
    [string] $EnvironmentName,
    [string] $SqlAdminLogin,
    [string] $SqlAdminObjectId,
    [ValidateSet('User', 'Group', 'Application')]
    [string] $SqlAdminPrincipalType = 'User'
)

. "$PSScriptRoot/_common.ps1"

# ----- Step 1: platform what-if -----
Write-Section 'Preview 1/2: platform what-if'
$ppArgs = @{ WhatIf = $true; NamePrefix = $NamePrefix; SqlAdminPrincipalType = $SqlAdminPrincipalType }
if ($Location)         { $ppArgs.Location = $Location }
if ($EnvironmentName)  { $ppArgs.EnvironmentName = $EnvironmentName }
if ($SqlAdminLogin)    { $ppArgs.SqlAdminLogin = $SqlAdminLogin }
if ($SqlAdminObjectId) { $ppArgs.SqlAdminObjectId = $SqlAdminObjectId }
& "$PSScriptRoot/deploy-platform.ps1" @ppArgs

# ----- Step 2: azd provision --preview -----
Write-Section 'Preview 2/2: azd provision --preview (Aspire infra)'
$envValues = Get-AzdEnvValues
if ([string]::IsNullOrWhiteSpace($envValues['infrastructureSubnetId'])) {
    Write-Host 'Skipped: platform outputs not in azd env yet.' -ForegroundColor Yellow
    Write-Host 'Run "./scripts/deploy-platform.ps1 -Apply" once, then preview shows the ACA infra diff.' -ForegroundColor Yellow
    return
}

azd provision --preview
if ($LASTEXITCODE -ne 0) { throw 'azd provision --preview failed.' }
