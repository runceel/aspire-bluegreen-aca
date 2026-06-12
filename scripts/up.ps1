<#
.SYNOPSIS
  End-to-end deploy of the whole sample with one command:
    1. platform (VNet / Azure SQL / Front Door) via deploy-platform.ps1 -Apply
    2. aspire publish -> generate bicep/bicepparam
    3. az deployment -> apply Aspire infrastructure + postdeploy hooks
       (Front Door origin wiring + traffic reconcile)
    4. print blue/green status

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

# ----- Step 1: platform (VNet / SQL / Front Door) -----
Write-Section 'Step 1/4: platform (VNet / Azure SQL / Front Door)'
$ppArgs = @{ Apply = $true; NamePrefix = $NamePrefix; SqlAdminPrincipalType = $SqlAdminPrincipalType }
if ($Location)         { $ppArgs.Location = $Location }
if ($EnvironmentName)  { $ppArgs.EnvironmentName = $EnvironmentName }
if ($SqlAdminLogin)    { $ppArgs.SqlAdminLogin = $SqlAdminLogin }
if ($SqlAdminObjectId) { $ppArgs.SqlAdminObjectId = $SqlAdminObjectId }
& "$PSScriptRoot/deploy-platform.ps1" @ppArgs

# Ensure azd env is configured with essential values
$envValues = Get-AzdEnvValues
if ([string]::IsNullOrWhiteSpace($envValues['AZURE_RESOURCE_GROUP'])) {
    $envName = $envValues['AZURE_ENV_NAME']
    if ([string]::IsNullOrWhiteSpace($envName)) {
        throw 'AZURE_ENV_NAME is not set. Run "azd env new <name>" (or "azd env select <name>") first.'
    }
    Set-AzdEnv 'AZURE_RESOURCE_GROUP' "rg-$envName"
}

# Seed blue/green parameters on first run
Set-AzdEnv 'ACTIVE_LABEL' 'blue'
if ([string]::IsNullOrWhiteSpace((Get-AzdInfraParameter 'appVersion'))) {
    Set-AzdInfraParameter 'appVersion' '1.0.0'
}
if ([string]::IsNullOrWhiteSpace((Get-AzdInfraParameter 'productionLabel'))) {
    $seedVersion = Get-AzdInfraParameter 'appVersion'
    Set-AzdInfraParameter 'productionLabel' 'blue'
    Set-AzdInfraParameter 'blueRevisionSuffix' (ConvertTo-RevisionSuffix $seedVersion)
    Set-AzdInfraParameter 'greenRevisionSuffix' ''
}

# ----- Step 2: aspire publish (generate bicep/bicepparam) -----
Write-Section 'Step 2/4: aspire publish'
$aspireOutput = './aspire-publish'
Invoke-AspirePublish -OutputPath $aspireOutput -Force

$bicepFile = Get-AspirePublishBicepFile $aspireOutput
$bicepParamFile = Get-AspirePublishBicepParamFile $aspireOutput
Write-Host "Generated bicep: $bicepFile"
Write-Host "Generated bicepparam: $bicepParamFile"

# ----- Step 3: az deployment (apply Aspire infrastructure) -----
Write-Section 'Step 3/4: deploying Aspire infrastructure'
$envValues = Get-AzdEnvValues
$resourceGroup = Get-RequiredEnv -Env $envValues -Name 'AZURE_RESOURCE_GROUP'
$deploymentName = "aspire-$(Get-Date -Format 'yyyyMMddHHmmss')"

az deployment group create `
    --resource-group $resourceGroup `
    --template-file $bicepFile `
    --parameters $bicepParamFile `
    --name $deploymentName | Out-Null

if ($LASTEXITCODE -ne 0) { throw 'az deployment failed.' }

# ----- Step 4: postdeploy hooks (Front Door origin + traffic validation) -----
Write-Section 'Step 4/4: postdeploy hooks'
& "$PSScriptRoot/configure-frontdoor-origin.ps1"
& "$PSScriptRoot/reconcile-traffic.ps1"

# ----- Status -----
Write-Section 'blue/green status'
& "$PSScriptRoot/bluegreen-status.ps1"
