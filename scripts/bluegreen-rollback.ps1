<#
.SYNOPSIS
  Roll back to the previous production label (instant traffic switch) for BOTH
  apps (web + api).

.DESCRIPTION
  Sends 100% traffic back to PREVIOUS_ACTIVE_LABEL and swaps the azd env labels
  so you can promote forward again later:
    ACTIVE_LABEL          = PREVIOUS_ACTIVE_LABEL
    PREVIOUS_ACTIVE_LABEL = (old) ACTIVE_LABEL
#>
[CmdletBinding()]
param()

. "$PSScriptRoot/_common.ps1"

$envValues = Get-AzdEnvValues
$rg = Get-RequiredEnv $envValues 'AZURE_RESOURCE_GROUP'

$activeLabel = $envValues['ACTIVE_LABEL']
if ([string]::IsNullOrWhiteSpace($activeLabel)) { $activeLabel = 'blue' }

$previousLabel = $envValues['PREVIOUS_ACTIVE_LABEL']
if ([string]::IsNullOrWhiteSpace($previousLabel)) {
    $previousLabel = Get-CandidateLabel -ActiveLabel $activeLabel
    Write-Host "PREVIOUS_ACTIVE_LABEL not set; assuming '$previousLabel'." -ForegroundColor Yellow
}

if ($previousLabel -eq $activeLabel) {
    throw "Previous label equals current production label ('$activeLabel'); nothing to roll back to."
}

Write-Section "Rolling back: $activeLabel -> $previousLabel (100%)"

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
        --label-weight "$previousLabel=100" "$activeLabel=0" 1>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to shift traffic on $appName." }
    Write-Host "[$aspireName] $previousLabel=100%  $activeLabel=0%" -ForegroundColor Green
}

Set-AzdEnv 'ACTIVE_LABEL' $previousLabel
Set-AzdEnv 'PREVIOUS_ACTIVE_LABEL' $activeLabel
Write-Host "Rollback complete. Production label is now '$previousLabel'." -ForegroundColor Green
