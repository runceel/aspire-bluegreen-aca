<#
.SYNOPSIS
  Show what changes will be deployed (approval gate for human review).
  
  Runs platform what-if + aspire publish + az deployment what-if without making
  any actual changes to resources (previews are side-effect free).

.EXAMPLE
  ./scripts/preview.ps1
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

# ----- Step 2: aspire publish + az deployment what-if -----
Write-Section 'Preview 2/2: aspire infrastructure what-if'
$envValues = Get-AzdEnvValues
$resourceGroup = Get-RequiredEnv -Env $envValues -Name 'AZURE_RESOURCE_GROUP'

Write-Host 'Running: aspire publish'
$aspireOutput = './aspire-publish'
Invoke-AspirePublish -OutputPath $aspireOutput -Force

$bicepFile = Get-AspirePublishBicepFile $aspireOutput
$bicepParamFile = Get-AspirePublishBicepParamFile $aspireOutput
Write-Host "Generated bicep: $bicepFile"
Write-Host "Generated bicepparam: $bicepParamFile"
Write-Host ""

Write-Host 'Running: az deployment group create --what-if'
az deployment group create `
    --resource-group $resourceGroup `
    --template-file $bicepFile `
    --parameters $bicepParamFile `
    --what-if | Write-Host

Write-Host ""
Write-Host "Review the changes above. If satisfied, run './scripts/up.ps1' to deploy."
