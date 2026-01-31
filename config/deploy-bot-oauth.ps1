<#
.SYNOPSIS
Creates an Azure Bot Service OAuth connection for Okta using Generic OAuth 2 Provider.

.DESCRIPTION
This script creates or updates an OAuth connection on an Azure Bot Service resource
to use Okta as the identity provider via the Generic OAuth 2 service provider.

.PARAMETER ResourceGroup
The name of the resource group containing the Azure Bot.

.PARAMETER BotName
The name of the Azure Bot resource.

.PARAMETER ConnectionName
The name for the OAuth connection (default: "okta").

.PARAMETER OktaDomain
Your Okta domain (e.g., "your-domain.okta.com").

.PARAMETER OktaClientId
The Client ID from your Okta OIDC application.

.PARAMETER OktaClientSecret
The Client Secret from your Okta OIDC application.

.PARAMETER AuthServer
The Okta authorization server to use (default: "default").

.PARAMETER Scopes
OAuth scopes to request (default: "openid profile email").

.EXAMPLE
.\deploy-bot-oauth.ps1 -ResourceGroup "myRG" -BotName "myBot" -OktaDomain "dev-123456.okta.com" -OktaClientId "0oa..." -OktaClientSecret "secret"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory=$true)]
    [string]$BotName,

    [string]$ConnectionName = "okta",

    [Parameter(Mandatory=$true)]
    [string]$OktaDomain,

    [Parameter(Mandatory=$true)]
    [string]$OktaClientId,

    [Parameter(Mandatory=$true)]
    [string]$OktaClientSecret,

    [string]$AuthServer = "default",

    [string]$Scopes = "openid profile email"
)

# Build OAuth URLs based on authorization server
if ($AuthServer -eq "default" -or $AuthServer -eq "") {
    $authPath = "/oauth2/default/v1"
} else {
    $authPath = "/oauth2/$AuthServer/v1"
}

$authorizationUrl = "https://$OktaDomain$authPath/authorize"
$tokenUrl = "https://$OktaDomain$authPath/token"

Write-Host "Configuring OAuth connection '$ConnectionName' for bot '$BotName'..."
Write-Host "  Authorization URL: $authorizationUrl"
Write-Host "  Token URL: $tokenUrl"
Write-Host "  Scopes: $Scopes"

# Get subscription ID
$subscriptionId = az account show --query id -o tsv
if (-not $subscriptionId) {
    Write-Error "Failed to get subscription ID. Make sure you're logged in with 'az login'."
    exit 1
}

# Build the request body
$body = @{
    location = "global"
    properties = @{
        serviceProviderId = "8379c6d2-b262-4d4f-b89b-68dc5b5f5482"
        serviceProviderDisplayName = "Oauth 2 Generic Provider"
        clientId = $OktaClientId
        clientSecret = $OktaClientSecret
        scopes = $Scopes
        parameters = @(
            @{ key = "authorizationUrl"; value = $authorizationUrl }
            @{ key = "tokenUrl"; value = $tokenUrl }
            @{ key = "refreshUrl"; value = $tokenUrl }
            @{ key = "clientId"; value = $OktaClientId }
            @{ key = "clientSecret"; value = $OktaClientSecret }
            @{ key = "scopes"; value = $Scopes }
            @{ key = "authorizationUrlTemplate"; value = $authorizationUrl }
            @{ key = "tokenUrlTemplate"; value = $tokenUrl }
            @{ key = "refreshUrlTemplate"; value = $tokenUrl }
        )
    }
} | ConvertTo-Json -Depth 10

# Create temp file for the body (az rest has issues with complex JSON on command line)
$tempFile = [System.IO.Path]::GetTempFileName()
$body | Out-File -FilePath $tempFile -Encoding utf8

try {
    $uri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.BotService/botServices/$BotName/connections/$ConnectionName`?api-version=2022-09-15"
    
    Write-Host "Creating/updating OAuth connection..."
    $result = az rest --method PUT --uri $uri --body "@$tempFile" --headers "Content-Type=application/json" 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ OAuth connection '$ConnectionName' configured successfully!" -ForegroundColor Green
        Write-Host ""
        Write-Host "Next steps:"
        Write-Host "  1. Go to Azure Portal > Bot Service > Configuration > OAuth Connection Settings"
        Write-Host "  2. Click on '$ConnectionName' and select 'Test Connection'"
        Write-Host "  3. Sign in with Okta to verify the connection works"
    } else {
        Write-Error "Failed to create OAuth connection: $result"
        exit 1
    }
} finally {
    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
}
