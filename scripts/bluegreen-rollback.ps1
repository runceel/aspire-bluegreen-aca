<#
.SYNOPSIS
  Roll back to the previous production color for BOTH apps (web + api): shift traffic
  instantly and update the declarative production label.

.DESCRIPTION
  Blue/green rollback is the mirror of promotion. A rollback workflow:
    1. `az containerapp ingress traffic set` -> immediate cutover (no rebuild).
    2. `infra.parameters.productionLabel = previous label` -> update declarative state.
    3. `aspire publish` -> regenerate bicep with previous production label reflected.
    4. `az deployment` -> apply the updated bicep, locking the rollback in place.
  
  Both tiers roll back together.
#>
[CmdletBinding()]
param()

. "$PSScriptRoot/_common.ps1"

$envValues = Get-AzdEnvValues
$rg = Get-RequiredEnv $envValues 'AZURE_RESOURCE_GROUP'

$productionLabel = Get-ProductionLabel -Env $envValues

$previousLabel = $envValues['PREVIOUS_ACTIVE_LABEL']
if ([string]::IsNullOrWhiteSpace($previousLabel)) {
    $previousLabel = Get-CandidateLabel -ActiveLabel $productionLabel
    Write-Host "PREVIOUS_ACTIVE_LABEL not set; assuming '$previousLabel'." -ForegroundColor Yellow
}

if ($previousLabel -eq $productionLabel) {
    throw "Previous label equals current production label ('$productionLabel'); nothing to roll back to."
}

Write-Section "Rolling back: $productionLabel -> $previousLabel (100%)"

# Pre-flight: both apps must have a revision on the rollback target label.
$apps = @{}
foreach ($aspireName in Get-TargetApps) {
    $appName = Resolve-ContainerAppName -ResourceGroup $rg -AspireName $aspireName
    $targetRev = Get-RevisionForLabel -ResourceGroup $rg -AppName $appName -Label $previousLabel
    if ([string]::IsNullOrWhiteSpace($targetRev)) {
        throw "[$aspireName] has no '$previousLabel' revision to roll back to."
    }
    $apps[$aspireName] = $appName
}

# Step 1: immediate traffic cutover
foreach ($aspireName in Get-TargetApps) {
    $appName = $apps[$aspireName]
    az containerapp ingress traffic set -g $rg -n $appName `
        --label-weight "$previousLabel=100" "$productionLabel=0" 1>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to shift traffic on $appName." }
    Write-Host "[$aspireName] $previousLabel=100%  $productionLabel=0%" -ForegroundColor Green
}

# Step 2: update declarative state and redeploy to lock it in
Write-Section "Locking rollback in declarative state"
Set-AzdInfraParameter 'productionLabel' $previousLabel
Set-AzdEnv 'ACTIVE_LABEL' $previousLabel
Set-AzdEnv 'PREVIOUS_ACTIVE_LABEL' $productionLabel

# Regenerate Aspire bicep with previous production label
Write-Section "Redeploying Aspire infrastructure to lock rollback"
$aspireOutput = './aspire-publish'
Invoke-AspirePublish -OutputPath $aspireOutput -Force

$bicepFile = Get-AspirePublishBicepFile $aspireOutput
$bicepParamFile = Get-AspirePublishBicepParamFile $aspireOutput

$deploymentName = "aspire-$(Get-Date -Format 'yyyyMMddHHmmss')"
az deployment group create `
    --resource-group $rg `
    --template-file $bicepFile `
    --parameters $bicepParamFile `
    --name $deploymentName 1>$null

if ($LASTEXITCODE -ne 0) { throw 'az deployment failed.' }

Write-Host "Rollback complete. Production label is now '$previousLabel' (locked)." -ForegroundColor Green