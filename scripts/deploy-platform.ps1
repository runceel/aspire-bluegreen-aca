<#
.SYNOPSIS
  Deploys (or previews) the external platform resources (VNet, Azure SQL, Key
  Vault, Front Door) and publishes their outputs into the selected azd
  environment so the Aspire AppHost parameters resolve.

.DESCRIPTION
  This is a standalone step deliberately kept OUT of azd's preprovision hook so
  that `azd provision --preview` never touches real platform resources. Call it
  from scripts/up.ps1 (-Apply) and scripts/preview.ps1 (-WhatIf).

.PARAMETER Apply
  Create/update the platform resources and push outputs to the azd env.

.PARAMETER WhatIf
  Show an ARM what-if diff only. (An empty platform resource group may be
  created so the group-scoped what-if can run; no billable resources are made.)

.EXAMPLE
  ./scripts/deploy-platform.ps1 -WhatIf
  ./scripts/deploy-platform.ps1 -Apply
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [switch] $WhatIf,
    [string] $Location,
    [string] $PlatformResourceGroup,
    [string] $NamePrefix = 'abg',
    [string] $EnvironmentName,
    [string] $SqlAdminLogin,
    [string] $SqlAdminObjectId,
    [ValidateSet('User', 'Group', 'Application')]
    [string] $SqlAdminPrincipalType = 'User'
)

. "$PSScriptRoot/_common.ps1"

if (-not ($Apply -or $WhatIf)) {
    throw 'Specify exactly one of -Apply or -WhatIf.'
}
if ($Apply -and $WhatIf) {
    throw 'Specify only one of -Apply or -WhatIf.'
}

$envValues = Get-AzdEnvValues
$azdEnvName = $envValues['AZURE_ENV_NAME']

if (-not $Location) { $Location = $envValues['AZURE_LOCATION'] }
if ([string]::IsNullOrWhiteSpace($Location)) {
    throw 'Location not provided and AZURE_LOCATION is not set. Pass -Location.'
}
if (-not $EnvironmentName) {
    $sanitized = ($azdEnvName -replace '[^a-zA-Z0-9]', '').ToLower()
    if ([string]::IsNullOrWhiteSpace($sanitized)) { $sanitized = 'demo' }
    $EnvironmentName = $sanitized.Substring(0, [Math]::Min(10, $sanitized.Length))
}
if (-not $PlatformResourceGroup) {
    $PlatformResourceGroup = "rg-$azdEnvName-platform"
}

# Default the SQL Entra admin to the signed-in user (so the deployer can manage
# SQL and run the passwordless grant later).
if (-not $SqlAdminObjectId) {
    $SqlAdminObjectId = (az ad signed-in-user show --query id -o tsv).Trim()
    if (-not $SqlAdminLogin) {
        $SqlAdminLogin = (az ad signed-in-user show --query userPrincipalName -o tsv).Trim()
    }
}
if (-not $SqlAdminLogin) {
    throw 'SqlAdminLogin could not be determined. Pass -SqlAdminLogin and -SqlAdminObjectId.'
}

$templateFile = Join-Path $PSScriptRoot '..' 'platform' 'main.bicep'
$deploymentName = "platform-$(Get-Date -Format 'yyyyMMddHHmmss')"

Write-Section "Platform resource group: $PlatformResourceGroup ($Location)"
# Idempotent; required for a group-scoped what-if as well.
az group create -n $PlatformResourceGroup -l $Location 1>$null

$mode = if ($WhatIf) { 'what-if' } else { 'create' }
Write-Section "Running az deployment group $mode"

$deployArgs = @(
    'deployment', 'group', $mode,
    '-g', $PlatformResourceGroup,
    '-n', $deploymentName,
    '--template-file', $templateFile,
    '--parameters',
    "location=$Location",
    "namePrefix=$NamePrefix",
    "environmentName=$EnvironmentName",
    "sqlAdminLogin=$SqlAdminLogin",
    "sqlAdminObjectId=$SqlAdminObjectId",
    "sqlAdminPrincipalType=$SqlAdminPrincipalType"
)

az @deployArgs
if ($LASTEXITCODE -ne 0) { throw "az deployment group $mode failed." }

if ($WhatIf) {
    Write-Host 'Preview complete (no platform changes applied).' -ForegroundColor Green
    return
}

Write-Section 'Publishing platform outputs to the azd environment'
$outputsJson = az deployment group show -g $PlatformResourceGroup -n $deploymentName `
    --query properties.outputs -o json
$outputs = $outputsJson | ConvertFrom-Json

# AppHost parameters (resolved by azd from matching env keys).
Set-AzdEnv 'infrastructureSubnetId' $outputs.infrastructureSubnetId.value
Set-AzdEnv 'sqlServerName'          $outputs.sqlServerName.value
Set-AzdEnv 'sqlResourceGroup'       $outputs.sqlResourceGroup.value

# Consumed by the postdeploy Front Door hook.
Set-AzdEnv 'PLATFORM_RESOURCE_GROUP'        $PlatformResourceGroup
Set-AzdEnv 'FRONTDOOR_PROFILE_NAME'         $outputs.frontDoorProfileName.value
Set-AzdEnv 'FRONTDOOR_ENDPOINT_NAME'        $outputs.frontDoorEndpointName.value
Set-AzdEnv 'FRONTDOOR_ENDPOINT_HOSTNAME'    $outputs.frontDoorEndpointHostName.value
Set-AzdEnv 'FRONTDOOR_ORIGIN_GROUP_NAME'    $outputs.frontDoorOriginGroupName.value
Set-AzdEnv 'sqlServerFqdn'                  $outputs.sqlServerFqdn.value

Write-Host "Front Door endpoint: https://$($outputs.frontDoorEndpointHostName.value)" -ForegroundColor Green
Write-Host 'Platform apply complete.' -ForegroundColor Green
