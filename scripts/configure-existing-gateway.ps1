#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [string]$ContractFile = ".ai-gateway-studio.json"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

if (-not (Test-Path -LiteralPath $ContractFile -PathType Leaf)) {
    throw "Existing AI Gateway handoff file not found: $ContractFile"
}
if ($null -eq (Get-Command azd -ErrorAction SilentlyContinue)) {
    throw "Azure Developer CLI is required to select the existing gateway profile."
}

try {
    $contract = Get-Content -LiteralPath $ContractFile -Raw | ConvertFrom-Json
} catch {
    throw "Invalid AI Gateway handoff file ${ContractFile}: $($_.Exception.Message)"
}

if ($contract.schemaVersion -ne 1) {
    throw "schemaVersion must be 1."
}
if ($contract.gatewayDeploymentMode -ne "existing") {
    throw "gatewayDeploymentMode must be existing."
}

$resourcePattern = "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ApiManagement/(service|aigateways)/[^/]+$"
$gatewayResourceId = [string]$contract.gatewayResourceId
if ($gatewayResourceId -notmatch $resourcePattern) {
    throw "gatewayResourceId must be a full Microsoft.ApiManagement/service or Microsoft.ApiManagement/aigateways ARM resource ID."
}

function Get-HttpsUrl($Name, $Value) {
    $text = [string]$Value
    $uri = $null
    if ([string]::IsNullOrWhiteSpace($text) -or
        $text -match "[`t`r`n]" -or
        -not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne "https") {
        throw "$Name must be an absolute, single-line HTTPS URL."
    }
    return $text
}

$gatewayEndpoint = (Get-HttpsUrl "gatewayEndpoint" $contract.gatewayEndpoint).TrimEnd("/") + "/"
$githubMcpEndpoint = (Get-HttpsUrl "githubMcpEndpoint" $contract.githubMcpEndpoint).TrimEnd("/")
if ($githubMcpEndpoint -notmatch "/default/toolservers/[^/]+/mcp$") {
    throw "githubMcpEndpoint must end in /default/toolservers/<name>/mcp."
}

$gatewayModel = [string]$contract.modelAliases.default
$gatewayMiniModel = [string]$contract.modelAliases.mini
foreach ($entry in @{
    "modelAliases.default" = $gatewayModel
    "modelAliases.mini" = $gatewayMiniModel
}.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($entry.Value) -or $entry.Value -match "[`t`r`n]") {
        throw "$($entry.Key) must be a nonempty single-line string."
    }
}

function Set-AzdValue($Name, $Value) {
    $previousUserAgent = $env:AZURE_DEV_USER_AGENT
    try {
        $env:AZURE_DEV_USER_AGENT = "microsoft_foundry_skill"
        azd env set $Name $Value
    } finally {
        if ($null -eq $previousUserAgent) {
            Remove-Item Env:AZURE_DEV_USER_AGENT -ErrorAction SilentlyContinue
        } else {
            $env:AZURE_DEV_USER_AGENT = $previousUserAgent
        }
    }
}

Set-AzdValue "GATEWAY_DEPLOYMENT_MODE" "existing"
Set-AzdValue "EXISTING_AI_GATEWAY_RESOURCE_ID" $gatewayResourceId
Set-AzdValue "AZURE_AI_GATEWAY_ENDPOINT" $gatewayEndpoint
Set-AzdValue "AZURE_AI_GATEWAY_GITHUB_MCP_ENDPOINT" $githubMcpEndpoint
Set-AzdValue "AZURE_AI_GATEWAY_MODEL" $gatewayModel
Set-AzdValue "AZURE_AI_GATEWAY_MINI_MODEL" $gatewayMiniModel

Write-Host "Selected the existing AI Gateway deployment profile from $ContractFile."
Write-Host "No Azure resources were provisioned or modified."
