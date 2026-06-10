// ---------------------------------------------------------------------------
// Platform (external) resources for the Aspire blue/green ACA sample.
//
// These resources are intentionally OUTSIDE the Aspire AppHost model: the
// AppHost references them as existing resources. They are deployed by
// scripts/deploy-platform.ps1 (standalone, supports -WhatIf), and their outputs
// are pushed into the azd environment so the AppHost parameters resolve.
//
// Scope: resource group. Deploy into a dedicated platform resource group that
// is created BEFORE `azd up`, because the ACA environment joins the VNet subnet
// defined here.
// ---------------------------------------------------------------------------
targetScope = 'resourceGroup'

@description('Azure location for all platform resources.')
param location string = resourceGroup().location

@description('Short prefix used in resource names (lowercase letters/numbers).')
@minLength(2)
@maxLength(8)
param namePrefix string = 'abg'

@description('Environment moniker (e.g. prod, demo). Used in resource names.')
@minLength(2)
@maxLength(10)
param environmentName string = 'demo'

@description('Entra ID login (UPN or group display name) for the SQL admin.')
param sqlAdminLogin string

@description('Entra ID object id (principal/group) that becomes the SQL admin.')
param sqlAdminObjectId string

@description('Principal type of the SQL admin.')
@allowed([
  'User'
  'Group'
  'Application'
])
param sqlAdminPrincipalType string = 'User'

@description('Tenant id for the SQL Entra admin.')
param sqlAdminTenantId string = subscription().tenantId

@description('Address space for the platform VNet.')
param vnetAddressPrefix string = '10.10.0.0/16'

@description('Address prefix for the ACA infrastructure subnet (>= /23).')
param acaInfraSubnetPrefix string = '10.10.0.0/23'

var uniqueSuffix = uniqueString(resourceGroup().id)
var vnetName = '${namePrefix}-${environmentName}-vnet'
var acaSubnetName = 'aca-infra'
var sqlServerName = toLower('${namePrefix}${environmentName}sql${uniqueSuffix}')
var keyVaultName = take(toLower('${namePrefix}${environmentName}kv${uniqueSuffix}'), 24)
var afdProfileName = '${namePrefix}-${environmentName}-afd'
var afdEndpointName = '${namePrefix}-${environmentName}-ep'
var wafPolicyName = toLower('${namePrefix}${environmentName}waf')
var originGroupName = 'web-origin-group'

// ---------------------------------------------------------------------------
// Virtual network + delegated subnet for the Container Apps environment.
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: acaSubnetName
        properties: {
          addressPrefix: acaInfraSubnetPrefix
          delegations: [
            {
              name: 'aca-delegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

resource acaInfraSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: acaSubnetName
}

// ---------------------------------------------------------------------------
// Azure SQL server (Entra-only auth). The "orders" database is created by the
// Aspire AppHost (AddDatabase) on top of this existing server, so it is NOT
// declared here.
// ---------------------------------------------------------------------------
resource sqlServer 'Microsoft.Sql/servers@2023-08-01' = {
  name: sqlServerName
  location: location
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: sqlAdminPrincipalType
      login: sqlAdminLogin
      sid: sqlAdminObjectId
      tenantId: sqlAdminTenantId
      azureADOnlyAuthentication: true
    }
  }
}

// Demo-only: allow other Azure services (incl. Container Apps) to reach SQL via
// its public endpoint. For production prefer a private endpoint into the VNet.
resource sqlAllowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01' = {
  parent: sqlServer
  name: 'AllowAllAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// ---------------------------------------------------------------------------
// Key Vault (RBAC). Present so secret-backed configuration has an explicit home
// even though the sample uses passwordless SQL.
// ---------------------------------------------------------------------------
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Front Door (Standard) front-ends the web app. The origin + route to the web
// container app FQDN are wired AFTER deployment by
// scripts/configure-frontdoor-origin.ps1 (postdeploy hook), so the origin group
// is created empty here.
// ---------------------------------------------------------------------------
resource afdProfile 'Microsoft.Cdn/profiles@2024-09-01' = {
  name: afdProfileName
  location: 'global'
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
}

resource afdEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-09-01' = {
  parent: afdProfile
  name: afdEndpointName
  location: 'global'
  properties: {
    enabledState: 'Enabled'
  }
}

resource afdOriginGroup 'Microsoft.Cdn/profiles/originGroups@2024-09-01' = {
  parent: afdProfile
  name: originGroupName
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: '/'
      probeRequestType: 'HEAD'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 100
    }
  }
}

resource wafPolicy 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2024-02-01' = {
  name: wafPolicyName
  location: 'global'
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      mode: 'Prevention'
    }
  }
}

resource afdSecurityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2024-09-01' = {
  parent: afdProfile
  name: 'waf-association'
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: {
        id: wafPolicy.id
      }
      associations: [
        {
          domains: [
            {
              id: afdEndpoint.id
            }
          ]
          patternsToMatch: [
            '/*'
          ]
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs consumed by scripts/up.ps1 -> `azd env set` -> AppHost parameters and
// by the postdeploy Front Door hook.
// ---------------------------------------------------------------------------
output vnetId string = vnet.id
output infrastructureSubnetId string = acaInfraSubnet.id
output sqlServerName string = sqlServer.name
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlResourceGroup string = resourceGroup().name
output keyVaultName string = keyVault.name
output frontDoorProfileName string = afdProfile.name
output frontDoorEndpointName string = afdEndpoint.name
output frontDoorEndpointHostName string = afdEndpoint.properties.hostName
output frontDoorOriginGroupName string = afdOriginGroup.name
output wafPolicyId string = wafPolicy.id
