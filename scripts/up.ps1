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

# appVersion is the single source of truth for the release version: it feeds the api
# container env (APP_VERSION), the web Docker BUILD ARG, AND each app's derived revision
# suffix ('v' + appVersion, dots -> dashes). It is published WITHOUT a default, so azd
# resolves it from infra.parameters.appVersion (config) and `azd up --no-prompt` fails with
# "parameter infra.parameters.appVersion not found" if it is missing. Seed the initial demo
# version; bump later with scripts/bluegreen-deploy.ps1 (or `azd env config set
# infra.parameters.appVersion <x>`).
if ([string]::IsNullOrWhiteSpace((Get-AzdInfraParameter 'appVersion'))) {
    Set-AzdInfraParameter 'appVersion' '1.0.0'
}

# Declarative blue/green state, consumed by the api/web Container App bicep (see
# AppHost.cs ConfigureBlueGreen). Traffic weights are derived from productionLabel, and
# each color's revision is referenced by '<app>--<suffix>'. On the FIRST deploy production
# is blue carrying the seeded appVersion and there is no green yet (empty suffix => the
# green traffic entry is omitted). These are seeded only when productionLabel is unset so
# re-running up.ps1 never clobbers a promoted/rolled-back state.
if ([string]::IsNullOrWhiteSpace((Get-AzdInfraParameter 'productionLabel'))) {
    $seedVersion = Get-AzdInfraParameter 'appVersion'
    Set-AzdInfraParameter 'productionLabel' 'blue'
    Set-AzdInfraParameter 'blueRevisionSuffix' (ConvertTo-RevisionSuffix $seedVersion)
    Set-AzdInfraParameter 'greenRevisionSuffix' ''
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
