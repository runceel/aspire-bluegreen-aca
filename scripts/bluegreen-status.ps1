<#
.SYNOPSIS
  Show the current blue/green state (revisions, labels, traffic, label FQDNs) for
  both apps (web + api).
#>
[CmdletBinding()]
param()

. "$PSScriptRoot/_common.ps1"

$envValues = Get-AzdEnvValues
$rg = Get-RequiredEnv $envValues 'AZURE_RESOURCE_GROUP'

$activeLabel = $envValues['ACTIVE_LABEL']
if ([string]::IsNullOrWhiteSpace($activeLabel)) { $activeLabel = 'blue' }
$candidateLabel = Get-CandidateLabel -ActiveLabel $activeLabel

Write-Host ''
Write-Host "Production label (ACTIVE_LABEL): $activeLabel" -ForegroundColor Cyan
Write-Host "Candidate label                : $candidateLabel" -ForegroundColor Cyan
if ($envValues['FRONTDOOR_ENDPOINT_HOSTNAME']) {
    Write-Host "Front Door (production)        : https://$($envValues['FRONTDOOR_ENDPOINT_HOSTNAME'])" -ForegroundColor Cyan
}

foreach ($aspireName in Get-TargetApps) {
    $appName = Resolve-ContainerAppName -ResourceGroup $rg -AspireName $aspireName
    $appFqdn = Get-ContainerAppFqdn -ResourceGroup $rg -AppName $appName

    Write-Section "$aspireName  ($appName)"
    az containerapp ingress traffic show -g $rg -n $appName `
        --query "[].{revision:revisionName, label:label, weight:weight}" -o table

    foreach ($label in @($activeLabel, $candidateLabel)) {
        $rev = Get-RevisionForLabel -ResourceGroup $rg -AppName $appName -Label $label
        if ($rev) {
            Write-Host ("  {0,-6} label URL: https://{1}" -f $label, (Get-LabelFqdn -AppFqdn $appFqdn -Label $label)) -ForegroundColor DarkGray
        }
    }
}

Write-Host ''
