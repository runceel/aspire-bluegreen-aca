<#
.SYNOPSIS
  Promote the candidate (green) revisions to 100% production traffic for BOTH
  apps (web + api), then record the new production label.

.DESCRIPTION
  Shifts traffic to the candidate label and updates the azd env so future
  deploys treat the new version as production:
    PREVIOUS_ACTIVE_LABEL = (old) ACTIVE_LABEL
    ACTIVE_LABEL          = candidate
  web and api are promoted together so the two tiers stay in lock-step.
#>
[CmdletBinding()]
param(
    [int] $CandidateWeight = 100
)

. "$PSScriptRoot/_common.ps1"

if ($CandidateWeight -lt 1 -or $CandidateWeight -gt 100) {
    throw 'CandidateWeight must be between 1 and 100.'
}

$envValues = Get-AzdEnvValues
$rg = Get-RequiredEnv $envValues 'AZURE_RESOURCE_GROUP'

$activeLabel = $envValues['ACTIVE_LABEL']
if ([string]::IsNullOrWhiteSpace($activeLabel)) { $activeLabel = 'blue' }
$candidateLabel = Get-CandidateLabel -ActiveLabel $activeLabel
$activeWeight = 100 - $CandidateWeight

Write-Section "Promoting $candidateLabel -> $CandidateWeight% (was $activeLabel)"

# Pre-flight: both apps must have a candidate revision.
$apps = @{}
foreach ($aspireName in Get-TargetApps) {
    $appName = Resolve-ContainerAppName -ResourceGroup $rg -AspireName $aspireName
    $candidateRev = Get-RevisionForLabel -ResourceGroup $rg -AppName $appName -Label $candidateLabel
    if ([string]::IsNullOrWhiteSpace($candidateRev)) {
        throw "[$aspireName] has no '$candidateLabel' revision to promote. Deploy a new version first."
    }
    $apps[$aspireName] = $appName
}

foreach ($aspireName in Get-TargetApps) {
    $appName = $apps[$aspireName]
    az containerapp ingress traffic set -g $rg -n $appName `
        --label-weight "$candidateLabel=$CandidateWeight" "$activeLabel=$activeWeight" 1>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to shift traffic on $appName." }
    Write-Host "[$aspireName] $candidateLabel=$CandidateWeight%  $activeLabel=$activeWeight%" -ForegroundColor Green
}

if ($CandidateWeight -eq 100) {
    Set-AzdEnv 'PREVIOUS_ACTIVE_LABEL' $activeLabel
    Set-AzdEnv 'ACTIVE_LABEL' $candidateLabel
    Write-Host "Promotion complete. Production label is now '$candidateLabel'." -ForegroundColor Green
}
else {
    Write-Host "Canary at $CandidateWeight%. Re-run with -CandidateWeight 100 to finish promotion." -ForegroundColor Yellow
}
