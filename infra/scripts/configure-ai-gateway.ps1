$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$aiGatewayApiVersion = "2025-09-01-preview"
$legacyAiGatewayApiVersion = "2026-05-01"
$foundryUserRoleId = "53ca6127-db72-4b80-b1b0-d745d6d5456d"
$defaultRepository = "microsoft/agent-framework"
$githubMcpServer = "https://api.githubcopilot.com/mcp/"
$githubMcpTools = "search_repositories,list_pull_requests,search_issues,actions_list"
$toolboxConnectionName = "aigw-github"
$toolboxName = "repo-digest-tools"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path

function Get-AzdValue($Name) {
    try {
        $value = azd env get-value $Name 2>$null
        return $value.Trim()
    } catch {
        return ""
    }
}

function First-Value([string[]]$Values) {
    foreach ($value in $Values) {
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return ""
}

function Require-Value($Name, $Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name is required after azd provision."
    }
    return $Value
}

function Remove-AzdEnvValues([string[]]$Names) {
    $envFile = $env:AZD_ENV_FILE
    if ([string]::IsNullOrWhiteSpace($envFile)) {
        $envFile = Join-Path (Get-Location) ".azure/$environmentName/.env"
    }
    if (-not (Test-Path $envFile)) { return }
    $remove = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $Names) { [void]$remove.Add($name) }
    $lines = Get-Content $envFile | Where-Object {
        $key = ($_ -split "=", 2)[0]
        -not $remove.Contains($key)
    }
    Set-Content -Path $envFile -Value $lines
}

function Test-AzRestResource($Uri) {
    try {
        az rest --method get --uri $Uri -o none 2>$null | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Invoke-AzRestPutJson($Uri, $Body) {
    $tempFile = [IO.Path]::GetTempFileName()
    try {
        $json = $Body | ConvertTo-Json -Depth 30 -Compress
        [IO.File]::WriteAllText($tempFile, $json, [Text.UTF8Encoding]::new($false))
        az rest --method put --uri $Uri --body "@$tempFile" -o none | Out-Null
    } finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-GatewayApiKeyValue($GatewayResourceId) {
    $listSecretsUri = "https://management.azure.com${GatewayResourceId}/apiKeys/default/listSecrets?api-version=$aiGatewayApiVersion"
    try {
        $value = az rest --method post --uri $listSecretsUri --body "{}" --query "primaryKey || properties.primaryKey || primaryValue || properties.primaryValue" -o tsv 2>$null
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    } catch {
        Write-Verbose "The current backend does not expose listSecrets; trying listValues."
    }

    $listValuesUri = "https://management.azure.com${GatewayResourceId}/apiKeys/default/listValues?api-version=$aiGatewayApiVersion"
    try {
        $value = az rest --method post --uri $listValuesUri --body "{}" --query "primaryValue || properties.primaryValue || primaryKey || properties.primaryKey" -o tsv 2>$null
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    } catch {
        return ""
    }
    return ""
}

function Test-GatewayModelRoute($GatewayUrl, $Model, $ApiKey) {
    $uri = $GatewayUrl.TrimEnd("/") + "/default/models/openai/v1/chat/completions"
    $headers = @{ "Api-Key" = $ApiKey }
    $body = @{
        model = $Model
        messages = @(
            @{
                role = "user"
                content = "Reply with exactly one word: ok"
            }
        )
        max_completion_tokens = 128
    } | ConvertTo-Json -Depth 5 -Compress
    $lastError = ""

    for ($attempt = 1; $attempt -le 15; $attempt++) {
        try {
            Invoke-RestMethod `
                -Method Post `
                -Uri $uri `
                -Headers $headers `
                -ContentType "application/json" `
                -Body $body | Out-Null
            Write-Host "AI Gateway model route is ready."
            return
        } catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt 15) {
                Write-Host "Waiting for the AI Gateway model route, attempt=$attempt"
                Start-Sleep -Seconds 4
            }
        }
    }

    throw "AI Gateway model route failed. The route requires an explicit Api-Key header. Last error: $lastError"
}

function Prepare-BicepRbac {
    $subscriptionId = First-Value @($env:AZURE_SUBSCRIPTION_ID, (Get-AzdValue "AZURE_SUBSCRIPTION_ID"), (az account show --query id -o tsv 2>$null))
    $resourceGroup = First-Value @($env:AI_GATEWAY_RESOURCE_GROUP, (Get-AzdValue "AI_GATEWAY_RESOURCE_GROUP"), $env:RESOURCE_GROUP, $env:AZURE_RESOURCE_GROUP, (Get-AzdValue "RESOURCE_GROUP"), (Get-AzdValue "AZURE_RESOURCE_GROUP"))
    $gatewayName = First-Value @($env:AI_GATEWAY_NAME, (Get-AzdValue "AI_GATEWAY_NAME"))
    if ([string]::IsNullOrWhiteSpace($subscriptionId) -or
        [string]::IsNullOrWhiteSpace($resourceGroup) -or
        [string]::IsNullOrWhiteSpace($gatewayName)) {
        return
    }

    $gatewayResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$gatewayName"
    $legacyGatewayResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/aigateways/$gatewayName"
    $gatewayUri = "https://management.azure.com${gatewayResourceId}?api-version=$aiGatewayApiVersion"
    if (-not (Test-AzRestResource $gatewayUri)) {
        $legacyGatewayUri = "https://management.azure.com${legacyGatewayResourceId}?api-version=$legacyAiGatewayApiVersion"
        if (Test-AzRestResource $legacyGatewayUri) {
            throw "The environment uses the retired Microsoft.ApiManagement/aigateways resource. Use a fresh azd environment; Bicep will not create a canonical service alongside it."
        }
        return
    }

    $principalId = [string](az rest --method get --uri $gatewayUri --query identity.principalId -o tsv)
    try {
        $accountId = [string](az rest `
            --method get `
            --uri "https://management.azure.com${gatewayResourceId}/workspaces/default/modelProviders/foundry?api-version=$aiGatewayApiVersion" `
            --query "properties.foundry.resourceIds[0]" `
            -o tsv 2>$null)
    } catch {
        $accountId = ""
    }
    if ([string]::IsNullOrWhiteSpace($accountId)) {
        $accountId = Get-AzdValue "FOUNDRY_MODELS_RESOURCE_ID"
    }
    if ([string]::IsNullOrWhiteSpace($principalId) -or [string]::IsNullOrWhiteSpace($accountId)) {
        return
    }

    $expectedAssignmentName = Get-AzdValue "AI_GATEWAY_FOUNDRY_ROLE_ASSIGNMENT_NAME"
    $expectedAssignmentPrincipalId = Get-AzdValue "AI_GATEWAY_FOUNDRY_ROLE_ASSIGNMENT_PRINCIPAL_ID"
    if (-not [string]::IsNullOrWhiteSpace($expectedAssignmentName) -and
        $expectedAssignmentPrincipalId -ne $principalId) {
        $savedAssignmentId = [string](az role assignment list `
            --subscription $subscriptionId `
            --scope $accountId `
            --query "[?name=='$expectedAssignmentName'].id | [0]" `
            -o tsv)
        if (-not [string]::IsNullOrWhiteSpace($savedAssignmentId)) {
            Write-Host "Removing the previous Gateway identity's Foundry User assignment."
            az role assignment delete --subscription $subscriptionId --ids $savedAssignmentId
        }
        $expectedAssignmentName = ""
    }

    $assignments = az role assignment list `
        --subscription $subscriptionId `
        --assignee-object-id $principalId `
        --scope $accountId `
        --role $foundryUserRoleId `
        --query "[].{id:id,name:name}" `
        -o json | ConvertFrom-Json
    foreach ($assignment in $assignments) {
        if (-not [string]::IsNullOrWhiteSpace($expectedAssignmentName) -and
            $expectedAssignmentPrincipalId -eq $principalId -and
            $assignment.name -eq $expectedAssignmentName) {
            continue
        }
        Write-Host "Removing the legacy script-owned Foundry User assignment so Bicep can adopt it."
        az role assignment delete --subscription $subscriptionId --ids $assignment.id
    }
}

$mode = $args.Count -gt 0 ? $args[0] : ""
if ($mode -eq "--prepare-bicep") {
    & (Join-Path $PSScriptRoot "manage-ai-gateway-lifecycle.ps1") prepare
    Prepare-BicepRbac
    exit 0
}
if (-not [string]::IsNullOrWhiteSpace($mode)) {
    throw "Usage: $PSCommandPath [--prepare-bicep]"
}

Write-Host "Finishing the Bicep-provisioned AI Gateway with the local GitHub MCP credential."

$environmentName = Require-Value "AZURE_ENV_NAME" (First-Value @($env:AZURE_ENV_NAME, (Get-AzdValue "AZURE_ENV_NAME")))
$subscriptionId = Require-Value "AZURE_SUBSCRIPTION_ID" (First-Value @($env:AZURE_SUBSCRIPTION_ID, (Get-AzdValue "AZURE_SUBSCRIPTION_ID"), (az account show --query id -o tsv)))
$resourceGroup = Require-Value "AI_GATEWAY_RESOURCE_GROUP" (First-Value @($env:AI_GATEWAY_RESOURCE_GROUP, (Get-AzdValue "AI_GATEWAY_RESOURCE_GROUP"), $env:RESOURCE_GROUP, $env:AZURE_RESOURCE_GROUP, (Get-AzdValue "RESOURCE_GROUP"), (Get-AzdValue "AZURE_RESOURCE_GROUP")))
$gatewayName = Require-Value "AI_GATEWAY_NAME" (First-Value @($env:AI_GATEWAY_NAME, (Get-AzdValue "AI_GATEWAY_NAME")))
$gatewayModel = Require-Value "AZURE_AI_GATEWAY_MODEL" (First-Value @($env:AZURE_AI_GATEWAY_MODEL, (Get-AzdValue "AZURE_AI_GATEWAY_MODEL")))
$gatewayMiniModel = Require-Value "AZURE_AI_GATEWAY_MINI_MODEL" (First-Value @($env:AZURE_AI_GATEWAY_MINI_MODEL, (Get-AzdValue "AZURE_AI_GATEWAY_MINI_MODEL")))
$githubRepository = First-Value @($env:GITHUB_REPOSITORY, (Get-AzdValue "GITHUB_REPOSITORY"), $defaultRepository)
$projectEndpoint = Require-Value "FOUNDRY_PROJECT_ENDPOINT" (First-Value @($env:FOUNDRY_PROJECT_ENDPOINT, (Get-AzdValue "FOUNDRY_PROJECT_ENDPOINT")))

$gatewayResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$gatewayName"
$legacyGatewayResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/aigateways/$gatewayName"
$workspaceName = First-Value @($env:AI_GATEWAY_WORKSPACE_NAME, "default")
$workspaceResourceId = "$gatewayResourceId/workspaces/$workspaceName"
$gatewayUri = "https://management.azure.com${gatewayResourceId}?api-version=$aiGatewayApiVersion"

if (-not (Test-AzRestResource $gatewayUri)) {
    $legacyGatewayUri = "https://management.azure.com${legacyGatewayResourceId}?api-version=$legacyAiGatewayApiVersion"
    if (Test-AzRestResource $legacyGatewayUri) {
        throw "The environment uses the retired Microsoft.ApiManagement/aigateways resource. Use a fresh azd environment; this hook will not access hidden projected APIM resources."
    }
    throw "Bicep did not create the expected Microsoft.ApiManagement/service AI Gateway: $gatewayName"
}

$gatewayState = [string](az rest --method get --uri $gatewayUri --query properties.provisioningState -o tsv)
if ($gatewayState -ne "Succeeded") {
    throw "The Bicep-provisioned AI Gateway is not ready: $gatewayState"
}

$identityType = [string](az rest --method get --uri $gatewayUri --query identity.type -o tsv)
if (@("SystemAssigned", "SystemAssigned, UserAssigned") -notcontains $identityType) {
    throw "Bicep did not enable the required AI Gateway system-assigned identity."
}

$gatewayUrl = Require-Value "AZURE_AI_GATEWAY_ENDPOINT" ([string](az rest --method get --uri $gatewayUri --query properties.gatewayUrl -o tsv))
if (-not $gatewayUrl.EndsWith("/", [StringComparison]::Ordinal)) {
    $gatewayUrl += "/"
}

$workspaceChildrenUri = "https://management.azure.com${workspaceResourceId}/modelProviders?api-version=$aiGatewayApiVersion"
$workspaceChildrenReady = $false
for ($attempt = 1; $attempt -le 30; $attempt++) {
    if (Test-AzRestResource $workspaceChildrenUri) {
        $workspaceChildrenReady = $true
        break
    }
    Write-Host "Waiting for the Bicep-provisioned default workspace, attempt=$attempt"
    Start-Sleep -Seconds 2
}
if (-not $workspaceChildrenReady) {
    throw "AI Gateway did not expose child APIs for the required $workspaceName workspace."
}

$providerUri = "https://management.azure.com${workspaceResourceId}/modelProviders/foundry?api-version=$aiGatewayApiVersion"
$providerAuth = [string](az rest --method get --uri $providerUri --query properties.foundry.authentication.kind -o tsv)
if ($providerAuth -ne "ManagedIdentity") {
    throw "Bicep did not configure the Foundry provider for managed identity."
}

Remove-AzdEnvValues @("GITHUB_MCP_TOKEN", "GITHUB_TOKEN")
$githubToken = ""
if ($null -ne (Get-Command gh -ErrorAction SilentlyContinue)) {
    $legacyGitHubToken = $env:GITHUB_TOKEN
    try {
        Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($env:GITHUB_MCP_GH_USER)) {
            $githubToken = [string](gh auth token --hostname github.com 2>$null)
        } else {
            $githubToken = [string](gh auth token --hostname github.com --user $env:GITHUB_MCP_GH_USER 2>$null)
        }
        if ($LASTEXITCODE -ne 0) { $githubToken = "" }
    } finally {
        if ($null -eq $legacyGitHubToken) {
            Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:GITHUB_TOKEN = $legacyGitHubToken
        }
    }
}
if ([string]::IsNullOrWhiteSpace($githubToken)) {
    throw "GitHub authentication is required for GitHub MCP. Run 'gh auth login --hostname github.com', or provide GH_TOKEN to GitHub CLI in CI."
}
$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) {
    $pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue
}
if ($null -eq $pythonCommand) {
    throw "Python 3 is required to validate the GitHub MCP credential."
}
$env:GITHUB_MCP_TOKEN_TO_VALIDATE = $githubToken
try {
    & $pythonCommand.Source (Join-Path $repoRoot "github_credential_validator.py") $githubRepository
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub MCP credential validation failed."
    }
} finally {
    Remove-Item Env:GITHUB_MCP_TOKEN_TO_VALIDATE -ErrorAction SilentlyContinue
}
Write-Host "Using the active GitHub CLI login for GitHub MCP."
if ($githubToken.StartsWith("Bearer ", [StringComparison]::OrdinalIgnoreCase)) {
    $githubAuthorization = $githubToken
} else {
    $githubAuthorization = "Bearer $githubToken"
}

$toolServerUri = "https://management.azure.com${workspaceResourceId}/toolServers/github?api-version=$aiGatewayApiVersion"
$toolServerBody = @{
    properties = @{
        displayName = "GitHub repository digest"
        description = "Read-only GitHub tools for repository digests."
        type = "mcp"
        failureMode = "failClosed"
        endpoints = @(
            @{
                namespace = "github"
                kind = "mcp"
                mcp = @{
                    url = $githubMcpServer
                    transport = "streamableHttp"
                }
                credentials = @{
                    type = "header"
                    headers = @{
                        Authorization = @($githubAuthorization)
                        "X-MCP-Readonly" = @("true")
                        "X-MCP-Tools" = @($githubMcpTools)
                    }
                }
            }
        )
    }
}
Write-Host "Injecting the read-only GitHub MCP credential into the Bicep-provisioned ToolServer."
Invoke-AzRestPutJson $toolServerUri $toolServerBody
$githubToken = $null
$githubAuthorization = $null
$toolServerBody = $null

$savedGatewayApiKey = First-Value @($env:AZURE_AI_GATEWAY_API_KEY, (Get-AzdValue "AZURE_AI_GATEWAY_API_KEY"))
$gatewayApiKey = Get-GatewayApiKeyValue $gatewayResourceId
if ([string]::IsNullOrWhiteSpace($gatewayApiKey)) {
    $gatewayApiKey = $savedGatewayApiKey
}
$gatewayApiKey = Require-Value "AZURE_AI_GATEWAY_API_KEY" $gatewayApiKey

Test-GatewayModelRoute $gatewayUrl $gatewayModel $gatewayApiKey

azd env set AZURE_AI_GATEWAY_ENDPOINT $gatewayUrl
azd env set AZURE_AI_GATEWAY_MODEL $gatewayModel
azd env set AZURE_AI_GATEWAY_MINI_MODEL $gatewayMiniModel
azd env set GITHUB_REPOSITORY $githubRepository
azd env set AZURE_AI_GATEWAY_API_KEY $gatewayApiKey | Out-Null
azd env set TOOLBOX_NAME $toolboxName

Write-Host "Connecting Foundry Toolbox to the AI Gateway GitHub ToolServer."
azd ai connection create $toolboxConnectionName `
    --kind remote-tool `
    --target ($gatewayUrl.TrimEnd("/") + "/default/toolservers/github/mcp") `
    --auth-type custom-keys `
    --custom-key "Api-Key=$gatewayApiKey" `
    --force `
    --no-prompt `
    --project-endpoint $projectEndpoint `
    -o json | Out-Null

$toolboxExists = $true
try {
    $toolboxJson = azd ai toolbox show $toolboxName `
        --no-prompt `
        --project-endpoint $projectEndpoint `
        -o json 2>$null
} catch {
    $toolboxExists = $false
}
if (-not $toolboxExists) {
    Write-Host "Creating the Foundry Toolbox."
    $toolboxJson = azd ai toolbox create $toolboxName `
        --from-file (Join-Path $repoRoot "toolbox.yaml") `
        --no-prompt `
        --project-endpoint $projectEndpoint `
        -o json
}
$toolboxEndpoint = ($toolboxJson | Out-String | ConvertFrom-Json).endpoint
azd env set TOOLBOX_ENDPOINT $toolboxEndpoint
Remove-AzdEnvValues @(
    "AI_SERVICES_NAME",
    "AI_GATEWAY_INTERNAL_MODEL_DEPLOYMENT",
    "AI_GATEWAY_INTERNAL_MODEL_NAME",
    "AI_GATEWAY_INTERNAL_MODEL_VERSION",
    "AI_GATEWAY_INTERNAL_MINI_MODEL_DEPLOYMENT",
    "AI_GATEWAY_INTERNAL_MINI_MODEL_NAME",
    "AI_GATEWAY_INTERNAL_MINI_MODEL_VERSION",
    "MODEL_DEPLOYMENT_NAME",
    "AZURE_AI_MODEL_DEPLOYMENT_NAME",
    "MODEL_NAME",
    "MODEL_VERSION",
    "LATEST_MODEL_DEPLOYMENT_NAME",
    "LATEST_MODEL_NAME",
    "LATEST_MODEL_VERSION",
    "AI_PROJECT_DEPLOYMENTS",
    "AZURE_AI_GATEWAY_MODEL_ALIAS",
    "AZURE_AI_GATEWAY_MODEL_VERSION",
    "AZURE_AI_GATEWAY_BASE_MODEL",
    "AZURE_AI_GATEWAY_BASE_MINI_MODEL",
    "AZURE_AI_GATEWAY_LATEST_MODEL_ALIAS",
    "AZURE_AI_GATEWAY_LATEST_MODEL",
    "AZURE_AI_GATEWAY_LATEST_MODEL_VERSION",
    "AZURE_AI_GATEWAY_MODEL_ALIASES",
    "AZURE_AI_GATEWAY_MODELS",
    "GITHUB_MCP_TOKEN",
    "GITHUB_TOKEN",
    "FOUNDRY_API_KEY"
)

Write-Host "AI Gateway setup complete. Bicep owns Azure resources; this hook injects the GitHub credential, connects Foundry Toolbox to AI Gateway, and saves the runtime key."
