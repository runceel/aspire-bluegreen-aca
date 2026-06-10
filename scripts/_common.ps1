<#
.SYNOPSIS
  Shared helpers for the blue/green + platform scripts. Dot-source this file:
      . "$PSScriptRoot/_common.ps1"

  All scripts assume `az` and `azd` are installed and authenticated, and that an
  azd environment is selected (azd env list / azd env select).
#>

$ErrorActionPreference = 'Stop'
$script:Labels = @('blue', 'green')

function Get-AzdEnvValues {
    <# Returns a hashtable of the current azd environment's key/values. #>
    $values = @{}
    $raw = azd env get-values 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        throw 'Unable to read azd environment. Run "azd env select <name>" first.'
    }
    foreach ($line in $raw) {
        if ($line -match '^\s*([^=#\s][^=]*)=(.*)$') {
            $key = $matches[1].Trim()
            $val = $matches[2].Trim()
            if ($val.StartsWith('"') -and $val.EndsWith('"')) {
                $val = $val.Substring(1, $val.Length - 2)
            }
            $values[$key] = $val
        }
    }
    return $values
}

function Get-RequiredEnv {
    param(
        [Parameter(Mandatory)] [hashtable] $Env,
        [Parameter(Mandatory)] [string] $Name
    )
    if (-not $Env.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace($Env[$Name])) {
        throw "Missing required azd env value '$Name'. Did scripts/up.ps1 set it?"
    }
    return $Env[$Name]
}

function Resolve-ContainerAppName {
    <# Maps an Aspire resource name (e.g. "web") to the deployed ACA app name. #>
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AspireName
    )
    $name = az containerapp list -g $ResourceGroup `
        --query "[?tags.\"aspire-resource-name\"=='$AspireName'].name | [0]" -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($name)) {
        # Fall back to the conventional name (Aspire uses the resource name).
        $name = az containerapp show -g $ResourceGroup -n $AspireName --query name -o tsv 2>$null
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Could not find a Container App for Aspire resource '$AspireName' in '$ResourceGroup'."
    }
    return $name.Trim()
}

function Get-ContainerAppFqdn {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName
    )
    return (az containerapp show -g $ResourceGroup -n $AppName `
            --query "properties.configuration.ingress.fqdn" -o tsv).Trim()
}

function Get-LatestRevisionName {
    <# Most recently created revision (the one azd just deployed). #>
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName
    )
    return (az containerapp revision list -g $ResourceGroup -n $AppName `
            --query "sort_by(@,&properties.createdTime)[-1].name" -o tsv).Trim()
}

function Get-RevisionForLabel {
    <# Revision name currently carrying the given label, or empty string. #>
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName,
        [Parameter(Mandatory)] [string] $Label
    )
    $rev = az containerapp ingress traffic show -g $ResourceGroup -n $AppName `
        --query "[?label=='$Label'].revisionName | [0]" -o tsv 2>$null
    if ($null -eq $rev) { return '' }
    return $rev.Trim()
}

function Get-CandidateLabel {
    param([Parameter(Mandatory)] [string] $ActiveLabel)
    if ($ActiveLabel -eq 'blue') { return 'green' }
    return 'blue'
}

function Set-RevisionLabel {
    <# (Re)assign a label to a revision, detaching it from any other revision first. #>
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName,
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $Revision
    )
    az containerapp revision label add -g $ResourceGroup -n $AppName `
        --label $Label --revision $Revision --no-prompt 1>$null
}

function Set-AzdEnv {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Value
    )
    azd env set $Name $Value 1>$null
}

function Get-TargetApps {
    <#
      The Aspire resource names that participate in blue/green. web and api are
      promoted/rolled back together so the two tiers stay in lock-step.
    #>
    return @('web', 'api')
}

function Get-LabelFqdn {
    <#
      Computes the per-label ingress FQDN for a Container App revision label.
      ACA exposes labels as "<app>---<label>.<environment-default-domain>".
    #>
    param(
        [Parameter(Mandatory)] [string] $AppFqdn,
        [Parameter(Mandatory)] [string] $Label
    )
    return ($AppFqdn -replace '^([^.]+)\.', ('${1}---' + $Label + '.'))
}

function Write-Section {
    param([Parameter(Mandatory)] [string] $Text)
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}
