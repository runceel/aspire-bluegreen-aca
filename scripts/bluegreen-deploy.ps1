<#
.SYNOPSIS
  Deploy a new version to the CANDIDATE color (the non-production one) and park it at
  0% traffic. Zero production exposure: the new revision never receives production
  traffic until you explicitly promote it.

.DESCRIPTION
  Blue/green is declarative (see AppHost.cs ConfigureBlueGreen). A deploy only needs to:
    1. Bump infra.parameters.appVersion          -> derives each app's revision suffix
                                                     ('v' + version, dots -> dashes) and
                                                     the api APP_VERSION env + web build arg.
    2. Set infra.parameters.<candidate>RevisionSuffix to the same suffix so the candidate
       traffic entry references the revision this deploy creates.
    3. aspire publish                             -> generates bicep/bicepparam
    4. az deployment                             -> applies the Aspire infrastructure.
                                                     The bicep pins production=100% / candidate=0%,
                                                     so the new revision is parked safely.
  productionLabel is left unchanged here; promotion is the explicit, separate step
  (bluegreen-promote.ps1). web and api are deployed together so the tiers stay in lock-step.

.EXAMPLE
  ./scripts/bluegreen-deploy.ps1 -Version 1.1.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Version
)

. "$PSScriptRoot/_common.ps1"

$envValues = Get-AzdEnvValues

$productionLabel = Get-ProductionLabel -Env $envValues
$candidateLabel = Get-CandidateLabel -ActiveLabel $productionLabel
$suffix = ConvertTo-RevisionSuffix $Version

$productionVersion = Get-AzdInfraParameter 'appVersion'
if ($Version -eq $productionVersion) {
    throw "Version '$Version' is already the production version. Deploy a different version to the '$candidateLabel' candidate."
}

# Deterministic revision suffixes mean each version maps to exactly ONE revision
# ('v' + version). If a revision with this suffix already exists, `az deployment` would
# fail mid-deploy with "revision with suffix <x> already exists". Fail fast (before the
# image build) with actionable guidance instead.
$appRg = Get-RequiredEnv -Env $envValues -Name 'AZURE_RESOURCE_GROUP'
foreach ($name in (Get-TargetApps)) {
    $app = Resolve-ContainerAppName -ResourceGroup $appRg -AspireName $name
    $existing = az containerapp revision list -g $appRg -n $app `
        --query "[?name=='$app--$suffix'].name | [0]" -o tsv 2>$null
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        throw "Revision '$app--$suffix' already exists (version $Version was deployed before). Each deploy needs a NEW version because the revision suffix is derived from it. Bump -Version to a value you have not deployed yet."
    }
}

Write-Section "Deploying v$Version to candidate '$candidateLabel' (production '$productionLabel' stays live)"

# Declarative state for the candidate. appVersion drives the derived revision suffix for
# BOTH apps and the api env / web build arg; the candidate's *RevisionSuffix param makes
# the candidate traffic entry reference the revision this deploy creates.
Write-Host "Setting appVersion=$Version"
Set-AzdInfraParameter 'appVersion' $Version

Write-Host "Setting ${candidateLabel}RevisionSuffix=$suffix"
Set-AzdInfraParameter "${candidateLabel}RevisionSuffix" $suffix

# Generate Aspire bicep/bicepparam
Write-Section 'Running: aspire publish'
$aspireOutput = './aspire-publish'
Invoke-AspirePublish -OutputPath $aspireOutput -Force

$bicepFile = Get-AspirePublishBicepFile $aspireOutput
$bicepParamFile = Get-AspirePublishBicepParamFile $aspireOutput
Write-Host "Generated bicep: $bicepFile"
Write-Host "Generated bicepparam: $bicepParamFile"

# Deploy Aspire infrastructure
Write-Section 'Deploying Aspire infrastructure'
$resourceGroup = Get-RequiredEnv -Env $envValues -Name 'AZURE_RESOURCE_GROUP'
$deploymentName = "aspire-$(Get-Date -Format 'yyyyMMddHHmmss')"

az deployment group create `
    --resource-group $resourceGroup `
    --template-file $bicepFile `
    --parameters $bicepParamFile `
    --name $deploymentName | Out-Null

if ($LASTEXITCODE -ne 0) { throw 'az deployment failed.' }

Write-Section 'Deployment complete'
Write-Host "Candidate revision parked at 0% traffic: $candidateLabel"
Write-Host "Production still at 100%: $productionLabel"
Write-Host ""
Write-Host "Next: Run './scripts/bluegreen-status.ps1' to see the candidate revision URLs"
Write-Host "      or   './scripts/bluegreen-promote.ps1' to promote to production"


Write-Host "appVersion              = $Version" -ForegroundColor DarkGray
Write-Host "${candidateLabel}RevisionSuffix = $suffix  (candidate revision: <app>--$suffix, 0% traffic)" -ForegroundColor DarkGray

# Build images + redeploy the Container App modules. Declarative traffic keeps production
# at 100% and parks the new candidate revision at 0% in the same deployment.
azd deploy --no-prompt
if ($LASTEXITCODE -ne 0) { throw 'azd deploy failed.' }

Write-Section 'blue/green status'
& "$PSScriptRoot/bluegreen-status.ps1"

Write-Host ''
Write-Host "Candidate '$candidateLabel' (v$Version) is live at 0%. Validate it via its label URL," -ForegroundColor Cyan
Write-Host "then promote with: ./scripts/bluegreen-promote.ps1" -ForegroundColor Cyan
