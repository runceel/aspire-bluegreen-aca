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

function Get-AzdConfigValue {
    param([Parameter(Mandatory)] [string] $Path)

    $raw = azd env config get $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or $null -eq $raw) {
        return ''
    }

    $value = ($raw -join [Environment]::NewLine).Trim()
    if ($value.StartsWith('"') -and $value.EndsWith('"')) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    return $value
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
    # Do NOT sort with a JMESPath --query here. On Windows `az` is az.cmd and cmd.exe
    # treats the "&" in "sort_by(@,&properties.createdTime)" as a command separator,
    # splitting the argument and breaking the call. Sort in PowerShell instead.
    $revisions = az containerapp revision list -g $ResourceGroup -n $AppName -o json | ConvertFrom-Json
    if (-not $revisions) {
        throw "No revisions found for Container App '$AppName' in '$ResourceGroup'."
    }
    return ($revisions | Sort-Object { [datetime]$_.properties.createdTime } | Select-Object -Last 1).name.Trim()
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

function ConvertTo-RevisionSuffix {
    <#
      Deterministic ACA revision suffix derived from a release version. MUST mirror
      the bicep expression in AppHost.cs ConfigureBlueGreen:
          revisionSuffix = 'v' + replace(appVersion, '.', '-')
      e.g. 1.2.0 -> v1-2-0. Used so the declarative traffic block can reference the
      revision a deploy creates by a predictable name.
    #>
    param([Parameter(Mandatory)] [string] $Version)
    return 'v' + ($Version -replace '\.', '-')
}

function Get-ProductionLabel {
    <#
      Canonical production color. Source of truth is the DECLARATIVE
      infra.parameters.productionLabel (drives the bicep ingress traffic weights).
      ACTIVE_LABEL (azd env) mirrors it for status/promote/rollback readability.
      Falls back to 'blue'.
    #>
    param([hashtable] $Env)
    $label = Get-AzdInfraParameter 'productionLabel'
    if ([string]::IsNullOrWhiteSpace($label) -and $Env) { $label = $Env['ACTIVE_LABEL'] }
    if ([string]::IsNullOrWhiteSpace($label)) { $label = 'blue' }
    return $label
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

function Get-AzdInfraParameter {
    param([Parameter(Mandatory)] [string] $Name)

    return Get-AzdConfigValue "infra.parameters.$Name"
}

function Set-AzdInfraParameter {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value
    )

    azd env config set "infra.parameters.$Name" $Value 1>$null
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

# ---------------------------------------------------------------------------
# Aspire publish/deploy helpers (Aspire 13.4 approach)
# ---------------------------------------------------------------------------

function Invoke-AspirePublish {
    <# Generate bicep/bicepparam from AppHost via `aspire publish`. #>
    param(
        [string] $OutputPath = './aspire-publish',
        [switch] $Force
    )
    Write-Section "Running: aspire publish"
    
    if ((Test-Path $OutputPath) -and -not $Force) {
        Remove-Item $OutputPath -Recurse -Force | Out-Null
    }
    
    $appHostPath = Resolve-Path './AspireBlueGreen.AppHost/AspireBlueGreen.AppHost.csproj'
    & dotnet run --project $appHostPath -- publish --output-path $OutputPath
    
    if ($LASTEXITCODE -ne 0) {
        throw "aspire publish failed (exit code $LASTEXITCODE)"
    }
}

function Get-AspirePublishBicepFile {
    <# Find the generated main bicep file from aspire publish output. #>
    param([string] $OutputPath = './aspire-publish')
    
    $files = Get-ChildItem $OutputPath -Filter '*.bicep' -File
    if ($files.Count -eq 0) {
        throw "No .bicep file found in aspire publish output at '$OutputPath'."
    }
    return $files[0].FullName
}

function Get-AspirePublishBicepParamFile {
    <# Find the generated bicepparam file from aspire publish output. #>
    param([string] $OutputPath = './aspire-publish')
    
    $files = Get-ChildItem $OutputPath -Filter '*.bicepparam' -File
    if ($files.Count -eq 0) {
        throw "No .bicepparam file found in aspire publish output at '$OutputPath'."
    }
    return $files[0].FullName
}
