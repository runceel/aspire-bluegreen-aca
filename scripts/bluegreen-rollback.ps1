<#
.SYNOPSIS
  Roll back to the previous production color for BOTH apps (web + api): shift traffic
  instantly, then sync the declarative state so the rollback survives the next deploy.

.DESCRIPTION
  HYBRID model (mirror of bluegreen-promote.ps1). Sends 100% traffic back to
  PREVIOUS_ACTIVE_LABEL via an instant imperative switch, then syncs the declarative
  param so a later `azd deploy` does not undo the rollback:
    * `az containerapp ingress traffic set` -> immediate cutover (no rebuild/redeploy).
    * infra.parameters.productionLabel = previous label (bicep now derives it as 100%).
    * Swap the azd env labels so you can promote forward again later:
        ACTIVE_LABEL          = PREVIOUS_ACTIVE_LABEL
        PREVIOUS_ACTIVE_LABEL = (old) production label
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

foreach ($aspireName in Get-TargetApps) {
    $appName = $apps[$aspireName]
    az containerapp ingress traffic set -g $rg -n $appName `
        --label-weight "$previousLabel=100" "$productionLabel=0" 1>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to shift traffic on $appName." }
    Write-Host "[$aspireName] $previousLabel=100%  $productionLabel=0%" -ForegroundColor Green
}

# Sync declarative state so a later `azd deploy` keeps the rolled-back production color.
Set-AzdInfraParameter 'productionLabel' $previousLabel
Set-AzdEnv 'ACTIVE_LABEL' $previousLabel
Set-AzdEnv 'PREVIOUS_ACTIVE_LABEL' $productionLabel
Write-Host "Rollback complete. Production label is now '$previousLabel' (declarative + env synced)." -ForegroundColor Green