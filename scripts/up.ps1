<#
.SYNOPSIS
  End-to-end deploy of the whole sample with one command:
    1. platform (VNet / Azure SQL / Front Door) via deploy-platform.ps1 -Apply
    2. azd up  -> provision ACA env + api/web, deploy images, run postdeploy hooks
                  (Front Door origin wiring + traffic reconcile)
    3. print blue/green status

.DESCRIPTION
  The exact same command sequence can run in CI/CD (see README). Requires an azd
  environment to be selected first:
      azd auth login ; az login
      azd env new prod        # or: azd env select prod
      azd env set AZURE_LOCATION <region>
      azd env set AZURE_SUBSCRIPTION_ID $(az account show --query id -o tsv)

.EXAMPLE
  ./scripts/up.ps1
  ./scripts/up.ps1 -Location japaneast -EnvironmentName prod
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

# ----- Step 1: platform -----
Write-Section 'Step 1/3: platform (VNet / Azure SQL / Front Door)'
$ppArgs = @{ Apply = $true; NamePrefix = $NamePrefix; SqlAdminPrincipalType = $SqlAdminPrincipalType }
if ($Location)         { $ppArgs.Location = $Location }
if ($EnvironmentName)  { $ppArgs.EnvironmentName = $EnvironmentName }
if ($SqlAdminLogin)    { $ppArgs.SqlAdminLogin = $SqlAdminLogin }
if ($SqlAdminObjectId) { $ppArgs.SqlAdminObjectId = $SqlAdminObjectId }
& "$PSScriptRoot/deploy-platform.ps1" @ppArgs

# Seed blue/green production label on first run.
$envValues = Get-AzdEnvValues
if ([string]::IsNullOrWhiteSpace($envValues['ACTIVE_LABEL'])) {
    Set-AzdEnv 'ACTIVE_LABEL' 'blue'
}

# ----- Step 2: azd up (provision + deploy + postdeploy hooks) -----
Write-Section 'Step 2/3: azd up'
azd up --no-prompt
if ($LASTEXITCODE -ne 0) { throw 'azd up failed.' }

# ----- Step 3: status -----
Write-Section 'Step 3/3: blue/green status'
& "$PSScriptRoot/bluegreen-status.ps1"
