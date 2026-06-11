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

# Seed values azd does not set on its own so the one-command path works unattended
# (azd up --no-prompt) and the postdeploy hooks have everything they need.
$envValues = Get-AzdEnvValues

# Production traffic label (first run).
if ([string]::IsNullOrWhiteSpace($envValues['ACTIVE_LABEL'])) {
    Set-AzdEnv 'ACTIVE_LABEL' 'blue'
}

# appVersion is consumed as the web Docker BUILD ARG. Under `azd up --no-prompt` azd
# resolves build-arg parameter references from infra.parameters.appVersion (NOT env
# vars, NOT the manifest's published default), so it must exist or packaging fails
# with "parameter infra.parameters.appVersion not found". Seed the initial demo
# version; bump later with: azd env config set infra.parameters.appVersion <x>
if ([string]::IsNullOrWhiteSpace((Get-AzdInfraParameter 'appVersion'))) {
    Set-AzdInfraParameter 'appVersion' '1.0.0'
}

# azd (1.25.x) does not write AZURE_RESOURCE_GROUP for this subscription-scoped Aspire
# app, but the postdeploy hooks (and bluegreen-*.ps1) require it. azd defaults the app
# resource group to rg-<env>; set it explicitly so it is deterministic and available
# to the hooks that run during `azd up`.
if ([string]::IsNullOrWhiteSpace($envValues['AZURE_RESOURCE_GROUP'])) {
    $envName = $envValues['AZURE_ENV_NAME']
    if ([string]::IsNullOrWhiteSpace($envName)) {
        throw 'AZURE_ENV_NAME is not set. Run "azd env new <name>" (or "azd env select <name>") first.'
    }
    Set-AzdEnv 'AZURE_RESOURCE_GROUP' "rg-$envName"
}

# ----- Step 2: azd up (provision + deploy + postdeploy hooks) -----
Write-Section 'Step 2/3: azd up'
azd up --no-prompt
if ($LASTEXITCODE -ne 0) { throw 'azd up failed.' }

# ----- Step 3: status -----
Write-Section 'Step 3/3: blue/green status'
& "$PSScriptRoot/bluegreen-status.ps1"
