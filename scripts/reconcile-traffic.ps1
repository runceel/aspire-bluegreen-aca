<#
.SYNOPSIS
  Postdeploy hook: enforce the desired blue/green traffic state after a deploy so
  that a deploy never steals production traffic.

.DESCRIPTION
  ACTIVE_LABEL (azd env, default "blue") is the production label. The other label
  is the "candidate". For each app (web + api):
    * First ever deploy  -> latest revision gets ACTIVE_LABEL and 100% traffic.
    * A new revision      -> it becomes the candidate (0% traffic); ACTIVE stays 100%.
    * No new revision      -> just reassert ACTIVE_LABEL = 100%.
  Promotion/rollback are explicit, separate operations (bluegreen-*.ps1).
#>
[CmdletBinding()]
param()

. "$PSScriptRoot/_common.ps1"

$envValues = Get-AzdEnvValues
$rg = Get-RequiredEnv $envValues 'AZURE_RESOURCE_GROUP'

$activeLabel = $envValues['ACTIVE_LABEL']
if ([string]::IsNullOrWhiteSpace($activeLabel)) {
    $activeLabel = 'blue'
    Set-AzdEnv 'ACTIVE_LABEL' $activeLabel
}
$candidateLabel = Get-CandidateLabel -ActiveLabel $activeLabel

Write-Section "Reconciling traffic (production label = $activeLabel)"

function Set-Traffic {
    param(
        [string] $ResourceGroup,
        [string] $AppName,
        [string[]] $Weights
    )
    az containerapp ingress traffic set -g $ResourceGroup -n $AppName `
        --label-weight @Weights 1>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to set traffic on $AppName." }
}

foreach ($aspireName in Get-TargetApps) {
    $appName = Resolve-ContainerAppName -ResourceGroup $rg -AspireName $aspireName
    $latestRev = Get-LatestRevisionName -ResourceGroup $rg -AppName $appName
    $activeRev = Get-RevisionForLabel -ResourceGroup $rg -AppName $appName -Label $activeLabel

    if ([string]::IsNullOrWhiteSpace($activeRev)) {
        # First deploy: latest becomes production.
        Set-RevisionLabel -ResourceGroup $rg -AppName $appName -Label $activeLabel -Revision $latestRev
        Set-Traffic -ResourceGroup $rg -AppName $appName -Weights @("$activeLabel=100")
        Write-Host "[$aspireName] $activeLabel -> $latestRev (100%)" -ForegroundColor Green
    }
    elseif ($latestRev -ne $activeRev) {
        # New revision deployed: park it on the candidate label with 0% traffic.
        Set-RevisionLabel -ResourceGroup $rg -AppName $appName -Label $candidateLabel -Revision $latestRev
        Set-Traffic -ResourceGroup $rg -AppName $appName -Weights @("$activeLabel=100", "$candidateLabel=0")
        Write-Host "[$aspireName] $activeLabel=100% (kept)  |  $candidateLabel -> $latestRev (0%)" -ForegroundColor Green
    }
    else {
        # No new revision; just reassert production at 100%.
        $candidateRev = Get-RevisionForLabel -ResourceGroup $rg -AppName $appName -Label $candidateLabel
        if ([string]::IsNullOrWhiteSpace($candidateRev)) {
            Set-Traffic -ResourceGroup $rg -AppName $appName -Weights @("$activeLabel=100")
        }
        else {
            Set-Traffic -ResourceGroup $rg -AppName $appName -Weights @("$activeLabel=100", "$candidateLabel=0")
        }
        Write-Host "[$aspireName] no new revision; $activeLabel=100%" -ForegroundColor DarkGray
    }
}

Write-Host 'Traffic reconciled.' -ForegroundColor Green
