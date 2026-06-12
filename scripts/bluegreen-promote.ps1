<#
.SYNOPSIS
  Promote the candidate color to production for BOTH apps (web + api): shift traffic
  instantly and update the declarative production label.

.DESCRIPTION
  Blue/green promotion is declarative (AppHost.cs ConfigureBlueGreen drives weights
  from infra.parameters.productionLabel). A promote workflow:
    1. `az containerapp ingress traffic set` -> immediate cutover (no rebuild).
    2. `infra.parameters.productionLabel = candidate` -> update declarative state.
    3. `aspire publish` -> regenerate bicep with new production label reflected.
    4. `az deployment` -> apply the updated bicep, locking the promotion in place.
  
  web and api are promoted together so the two tiers stay in lock-step. A canary (<100%)
  does NOT flip productionLabel or redeploy; finish with -CandidateWeight 100.
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

# Step 1: immediate traffic cutover
foreach ($aspireName in Get-TargetApps) {
    $appName = $apps[$aspireName]
    az containerapp ingress traffic set -g $rg -n $appName `
        --label-weight "$candidateLabel=$CandidateWeight" "$productionLabel=$activeWeight" 1>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to shift traffic on $appName." }
    Write-Host "[$aspireName] $candidateLabel=$CandidateWeight%  $productionLabel=$activeWeight%" -ForegroundColor Green
}

# Step 2: for full promotion (100%), update declarative state and redeploy to lock it in
if ($CandidateWeight -eq 100) {
    Write-Section "Locking promotion in declarative state"
    Set-AzdInfraParameter 'productionLabel' $candidateLabel
    Set-AzdEnv 'PREVIOUS_ACTIVE_LABEL' $productionLabel
    Set-AzdEnv 'ACTIVE_LABEL' $candidateLabel
    
    # Regenerate Aspire bicep with new production label
    Write-Section "Redeploying Aspire infrastructure to lock promotion"
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
    
    Write-Host "Promotion complete. Production label is now '$candidateLabel' (locked)." -ForegroundColor Green
}
else {
    Write-Host "Canary at $CandidateWeight%. Re-run with -CandidateWeight 100 to finish promotion." -ForegroundColor Yellow
}