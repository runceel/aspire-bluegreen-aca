<#
.SYNOPSIS
  Postdeploy hook: points the Front Door endpoint at the freshly deployed web
  Container App (origin + route). Idempotent.

.DESCRIPTION
  Front Door is created (profile/endpoint/origin-group/WAF) by platform/main.bicep
  with an EMPTY origin group, because the web FQDN does not exist until azd has
  deployed the container apps. This hook closes that gap after every deploy.
#>
[CmdletBinding()]
param()

. "$PSScriptRoot/_common.ps1"

$envValues = Get-AzdEnvValues
$appResourceGroup = Get-RequiredEnv $envValues 'AZURE_RESOURCE_GROUP'
$platformRg       = Get-RequiredEnv $envValues 'PLATFORM_RESOURCE_GROUP'
$profileName      = Get-RequiredEnv $envValues 'FRONTDOOR_PROFILE_NAME'
$endpointName     = Get-RequiredEnv $envValues 'FRONTDOOR_ENDPOINT_NAME'
$originGroupName  = Get-RequiredEnv $envValues 'FRONTDOOR_ORIGIN_GROUP_NAME'

Write-Section 'Configuring Front Door origin for the web app'

$webApp  = Resolve-ContainerAppName -ResourceGroup $appResourceGroup -AspireName 'web'
$webFqdn = Get-ContainerAppFqdn -ResourceGroup $appResourceGroup -AppName $webApp
if ([string]::IsNullOrWhiteSpace($webFqdn)) {
    throw "Web Container App '$webApp' has no ingress FQDN yet."
}
Write-Host "web app: $webApp" -ForegroundColor DarkGray
Write-Host "web FQDN: $webFqdn" -ForegroundColor DarkGray

$originName = 'web-origin'
$routeName  = 'web-route'

# --- origin (create or update) ---
$originExists = az afd origin show -g $platformRg --profile-name $profileName `
    --origin-group-name $originGroupName --origin-name $originName --query name -o tsv 2>$null
$originVerb = if ([string]::IsNullOrWhiteSpace($originExists)) { 'create' } else { 'update' }

az afd origin $originVerb -g $platformRg --profile-name $profileName `
    --origin-group-name $originGroupName --origin-name $originName `
    --host-name $webFqdn --origin-host-header $webFqdn `
    --http-port 80 --https-port 443 --priority 1 --weight 1000 `
    --enabled-state Enabled --enforce-certificate-name-check true 1>$null
if ($LASTEXITCODE -ne 0) { throw "az afd origin $originVerb failed." }

# --- route (create or update); link to endpoint default domain ---
$routeExists = az afd route show -g $platformRg --profile-name $profileName `
    --endpoint-name $endpointName --route-name $routeName --query name -o tsv 2>$null
$routeVerb = if ([string]::IsNullOrWhiteSpace($routeExists)) { 'create' } else { 'update' }

az afd route $routeVerb -g $platformRg --profile-name $profileName `
    --endpoint-name $endpointName --route-name $routeName `
    --origin-group $originGroupName --supported-protocols Https `
    --forwarding-protocol HttpsOnly --https-redirect Enabled `
    --link-to-default-domain Enabled --patterns-to-match '/*' 1>$null
if ($LASTEXITCODE -ne 0) { throw "az afd route $routeVerb failed." }

$endpointHost = $envValues['FRONTDOOR_ENDPOINT_HOSTNAME']
Write-Host "Front Door is now routing to the web app." -ForegroundColor Green
if ($endpointHost) {
    Write-Host "Public URL: https://$endpointHost" -ForegroundColor Green
}
