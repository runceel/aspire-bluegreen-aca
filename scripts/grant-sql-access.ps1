<#
.SYNOPSIS
  OPTIONAL: grant the API's managed identity passwordless access to the "orders"
  database (db_datareader / db_datawriter).

.DESCRIPTION
  In most cases this is NOT needed: the Aspire AppHost emits an "api-roles-sql"
  module that azd applies during provisioning to create the SQL user for the API
  managed identity. Use this script only if you want to (re)apply the grant
  manually, or to understand exactly what is happening.

  Prerequisites:
    * sqlcmd (go-sqlcmd, "sqlcmd" on PATH) installed
    * You are signed in (az login) as the SQL Entra admin set by infra/
    * Your client IP is allowed (the demo enables "Allow Azure services"; for a
      local run also add a firewall rule for your IP).

.EXAMPLE
  ./scripts/grant-sql-access.ps1
#>
[CmdletBinding()]
param(
    [string] $DatabaseName = 'orders'
)

. "$PSScriptRoot/_common.ps1"

$envValues = Get-AzdEnvValues
$rg          = Get-RequiredEnv $envValues 'AZURE_RESOURCE_GROUP'
$sqlFqdn     = Get-RequiredEnv $envValues 'sqlServerFqdn'

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw 'sqlcmd not found on PATH. Install go-sqlcmd: https://aka.ms/go-sqlcmd'
}

$apiApp = Resolve-ContainerAppName -ResourceGroup $rg -AspireName 'api'

# The API's user-assigned managed identity display name == SQL external user name.
$miResourceId = az containerapp show -g $rg -n $apiApp `
    --query "keys(identity.userAssignedIdentities)[0]" -o tsv
if ([string]::IsNullOrWhiteSpace($miResourceId)) {
    throw "Could not find a user-assigned identity on Container App '$apiApp'."
}
$miName = ($miResourceId -split '/')[-1]

Write-Section "Granting [$miName] access to $DatabaseName on $sqlFqdn"

$tsql = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$miName')
    CREATE USER [$miName] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [$miName];
ALTER ROLE db_datawriter ADD MEMBER [$miName];
"@

# -G: Entra ID auth using the signed-in identity; -C: trust server certificate.
sqlcmd -S $sqlFqdn -d $DatabaseName -G -C -Q $tsql
if ($LASTEXITCODE -ne 0) { throw 'sqlcmd grant failed.' }

Write-Host "Granted db_datareader/db_datawriter to [$miName]." -ForegroundColor Green
