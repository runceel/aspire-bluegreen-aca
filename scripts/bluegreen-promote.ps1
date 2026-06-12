<#
.SYNOPSIS
  Promote the candidate color to production for BOTH apps (web + api): shift traffic
  instantly, then sync the declarative state so the promotion survives the next deploy.

.DESCRIPTION
  HYBRID model. Traffic is declarative (AppHost.cs ConfigureBlueGreen pins weights from
  infra.parameters.productionLabel), but promotion uses an instant imperative traffic
  switch for demo snappiness and then syncs the declarative param so a later `azd deploy`
  stays consistent and never rolls the promotion back:
    * `az containerapp ingress traffic set` -> immediate cutover (no rebuild/redeploy).
    * On a full (100%) promote, flip infra.parameters.productionLabel = candidate so the
      bicep now derives candidate=100% / old-production=0% on subsequent deploys.
    * Mirror the azd env labels for status/rollback:
        PREVIOUS_ACTIVE_LABEL = (old) production label
        ACTIVE_LABEL          = candidate (new production)
  web and api are promoted together so the two tiers stay in lock-step. A canary (<100%)
  does NOT flip productionLabel; finish with -CandidateWeight 100 (and avoid `azd deploy`
  mid-canary, which would re-assert the declared production label).
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

$productionLabel = Get-ProductionLabel -Env $envValues
$candidateLabel = Get-CandidateLabel -ActiveLabel $productionLabel
$activeWeight = 100 - $CandidateWeight

Write-Section "Promoting $candidateLabel -> $CandidateWeight% (was $productionLabel)"

# Pre-flight: both apps must have a candidate revision carrying the candidate label.
$apps = @{}
foreach ($aspireName in Get-TargetApps) {
    $appName = Resolve-ContainerAppName -ResourceGroup $rg -AspireName $aspireName
    $candidateRev = Get-RevisionForLabel -ResourceGroup $rg -AppName $appName -Label $candidateLabel
    if ([string]::IsNullOrWhiteSpace($candidateRev)) {
        throw "[$aspireName] has no '$candidateLabel' revision to promote. Deploy a new version first (bluegreen-deploy.ps1)."
    }
    $apps[$aspireName] = $appName
}

foreach ($aspireName in Get-TargetApps) {
    $appName = $apps[$aspireName]
    az containerapp ingress traffic set -g $rg -n $appName `
        --label-weight "$candidateLabel=$CandidateWeight" "$productionLabel=$activeWeight" 1>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to shift traffic on $appName." }
    Write-Host "[$aspireName] $candidateLabel=$CandidateWeight%  $productionLabel=$activeWeight%" -ForegroundColor Green
}

if ($CandidateWeight -eq 100) {
    # Sync declarative state so a later `azd deploy` keeps the new production color.
    Set-AzdInfraParameter 'productionLabel' $candidateLabel
    Set-AzdEnv 'PREVIOUS_ACTIVE_LABEL' $productionLabel
    Set-AzdEnv 'ACTIVE_LABEL' $candidateLabel
    Write-Host "Promotion complete. Production label is now '$candidateLabel' (declarative + env synced)." -ForegroundColor Green
}
else {
    Write-Host "Canary at $CandidateWeight%. Re-run with -CandidateWeight 100 to finish promotion (do not 'azd deploy' mid-canary)." -ForegroundColor Yellow
}