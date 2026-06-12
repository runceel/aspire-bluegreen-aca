<#
.SYNOPSIS
  Postdeploy hook: VERIFY (do not mutate) the blue/green traffic state after a deploy.

.DESCRIPTION
  Traffic is now DECLARATIVE. The api/web Container App bicep (AppHost.cs
  ConfigureBlueGreen) pins each color's ingress weight from
  infra.parameters.productionLabel:
      weight = (productionLabel == '<color>') ? 100 : 0
  so `azd deploy` itself parks the freshly built (candidate) revision at 0% and keeps
  production at 100% -- there is no post-deploy window where a new build can steal
  production traffic. Promotion/rollback are explicit (bluegreen-*.ps1).

  This hook therefore NO LONGER sets traffic. It only reports the live state and warns
  if it diverges from the declared production label (which would indicate a manual/portal
  edit, or a deploy that did not apply the expected parameters).
#>
[CmdletBinding()]
param()

. "$PSScriptRoot/_common.ps1"

$envValues = Get-AzdEnvValues
$rg = Get-RequiredEnv $envValues 'AZURE_RESOURCE_GROUP'

$productionLabel = Get-ProductionLabel -Env $envValues
$candidateLabel = Get-CandidateLabel -ActiveLabel $productionLabel

Write-Section "Verifying declarative traffic (production label = $productionLabel)"

$mismatch = $false
foreach ($aspireName in Get-TargetApps) {
    $appName = Resolve-ContainerAppName -ResourceGroup $rg -AspireName $aspireName
    $traffic = az containerapp ingress traffic show -g $rg -n $appName `
        --query "[].{label:label, weight:weight, revision:revisionName}" -o json 2>$null | ConvertFrom-Json

    $prodWeight = ($traffic | Where-Object { $_.label -eq $productionLabel } | Select-Object -First 1).weight
    $candWeight = ($traffic | Where-Object { $_.label -eq $candidateLabel } | Select-Object -First 1).weight
    if ($null -eq $prodWeight) { $prodWeight = 0 }
    if ($null -eq $candWeight) { $candWeight = 0 }

    if ([int]$prodWeight -eq 100 -and [int]$candWeight -eq 0) {
        Write-Host "[$aspireName] OK  $productionLabel=100%  $candidateLabel=$candWeight%" -ForegroundColor Green
    }
    else {
        $mismatch = $true
        Write-Host "[$aspireName] UNEXPECTED  $productionLabel=$prodWeight%  $candidateLabel=$candWeight% (expected production=100%, candidate=0%)" -ForegroundColor Yellow
    }
}

if ($mismatch) {
    Write-Host ''
    Write-Host 'Traffic does not match the declared production label. Traffic is declarative;' -ForegroundColor Yellow
    Write-Host 'do not edit it in the portal. To change production use bluegreen-promote.ps1 /' -ForegroundColor Yellow
    Write-Host 'bluegreen-rollback.ps1, then re-deploy. Investigate before promoting.' -ForegroundColor Yellow
}
else {
    Write-Host 'Traffic matches the declared production label.' -ForegroundColor Green
}