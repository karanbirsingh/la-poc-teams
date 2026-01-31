<#
.SYNOPSIS
    One-command deployment: Teams Bot + Okta OAuth + Logic Apps.
    
.DESCRIPTION
    Reads deployment-config.json and provisions EVERYTHING from scratch.
    
    You only need to provide:
    - Okta domain and API token
    - (Optional) Azure subscription/location
    - (Optional) Resource naming prefix
    
    The script auto-generates all resource names, secrets, and configurations.

.EXAMPLE
    # First, login to Azure:
    az login
    
    # Then run:
    .\deploy.ps1
    
.EXAMPLE
    # Use a custom config file:
    .\deploy.ps1 -ConfigFile "my-config.json"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "deployment-config.json"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir

# =============================================================================
# Helper Functions
# =============================================================================

function Write-Banner {
    param([string]$Message)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-Step {
    param([int]$Number, [string]$Message)
    Write-Host ""
    Write-Host "[$Number] $Message" -ForegroundColor Green
    Write-Host ("-" * 60) -ForegroundColor DarkGray
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor White
}

function Write-Success {
    param([string]$Message)
    Write-Host "    ✓ $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "    ⚠ $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "    ✗ $Message" -ForegroundColor Red
}

function New-RandomSuffix {
    $chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    $suffix = -join ((1..6) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
    return $suffix
}

function New-SecurePassword {
    $length = 32
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
    return -join ((1..$length) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

# Progress tracking - saves state after each step
$global:deploymentState = @{
    status    = "in-progress"
    startTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    steps     = @{}
    azure     = @{}
    bot       = @{}
    logicApp  = @{}
    okta      = @{}
}

function Save-DeploymentState {
    param([string]$Step, [string]$Status, [hashtable]$Data = @{})
    
    $global:deploymentState.steps[$Step] = @{
        status    = $Status
        timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
    
    # Merge any additional data
    foreach ($key in $Data.Keys) {
        if ($key -eq "azure") { $global:deploymentState.azure = $Data[$key] }
        elseif ($key -eq "bot") { foreach ($k in $Data[$key].Keys) { $global:deploymentState.bot[$k] = $Data[$key][$k] } }
        elseif ($key -eq "logicApp") { foreach ($k in $Data[$key].Keys) { $global:deploymentState.logicApp[$k] = $Data[$key][$k] } }
        elseif ($key -eq "okta") { foreach ($k in $Data[$key].Keys) { $global:deploymentState.okta[$k] = $Data[$key][$k] } }
    }
    
    # Save to file immediately
    $outputPath = Join-Path $scriptDir "deployment-output.json"
    $global:deploymentState | ConvertTo-Json -Depth 10 | Set-Content $outputPath -Encoding UTF8
}

# =============================================================================
# Load and Validate Configuration
# =============================================================================

Write-Banner "Teams Bot + Okta + Logic Apps Deployment"

$configPath = Join-Path $scriptDir $ConfigFile
if (-not (Test-Path $configPath)) {
    Write-Error "Config file not found: $configPath"
    Write-Host ""
    Write-Host "Please create deployment-config.json with your Okta credentials." -ForegroundColor Yellow
    exit 1
}

# Check for existing deployment output (for resumability)
$outputPath = Join-Path $scriptDir "deployment-output.json"
$existingDeployment = $null
if (Test-Path $outputPath) {
    $existingDeployment = Get-Content $outputPath | ConvertFrom-Json
    Write-Info "Found existing deployment output - will reuse saved secrets"
}

Write-Step 1 "Loading configuration"

$config = Get-Content $configPath | ConvertFrom-Json

# Validate required fields
if (-not $config.okta.domain -or $config.okta.domain -eq "YOUR_OKTA_DOMAIN.okta.com") {
    Write-Error "Please set 'okta.domain' in $ConfigFile"
    exit 1
}

if (-not $config.okta.apiToken -or $config.okta.apiToken -eq "YOUR_OKTA_API_TOKEN") {
    Write-Error "Please set 'okta.apiToken' in $ConfigFile"
    exit 1
}

if (-not $config.azure.resourceGroup) {
    Write-Error "Please set 'azure.resourceGroup' in $ConfigFile"
    exit 1
}

# Resource group from config (required)
$resourceGroup = $config.azure.resourceGroup

# Generate naming prefix if not provided
$prefix = $config.resources.prefix
if (-not $prefix) {
    $prefix = "la$(New-RandomSuffix)"
    Write-Info "Auto-generated resource prefix: $prefix"
}

# Build resource names - use config values if provided, otherwise generate from prefix
$botName = if ($config.resources.botName) { $config.resources.botName } else { "$prefix-bot" }
$logicAppName = if ($config.resources.logicAppName) { $config.resources.logicAppName } else { "$prefix-la" }
$storageName = if ($config.resources.storageName) { $config.resources.storageName } else { "$($prefix)store" -replace "[^a-z0-9]", "" }
$appServicePlan = if ($config.resources.appServicePlanName) { $config.resources.appServicePlanName } else { "$prefix-asp" }
$oktaAppName = "Teams Bot - $prefix"

# Azure settings
$location = if ($config.azure.location) { $config.azure.location } else { "eastus" }
$subscriptionId = $config.azure.subscriptionId

# Okta settings
$oktaDomain = $config.okta.domain
$oktaApiToken = $config.okta.apiToken

Write-Success "Configuration loaded"
Write-Info "Resource Group:  $resourceGroup"
Write-Info "Bot Name:        $botName"
Write-Info "Logic App:       $logicAppName"
Write-Info "Okta Domain:     $oktaDomain"
Write-Info "Location:        $location"

# Initialize state with config
$global:deploymentState.prefix = $prefix
$global:deploymentState.azure = @{
    resourceGroup = $resourceGroup
    location      = $location
}
$global:deploymentState.bot = @{ name = $botName }
$global:deploymentState.logicApp = @{ name = $logicAppName }
$global:deploymentState.okta = @{ domain = $oktaDomain; appName = $oktaAppName }
Save-DeploymentState -Step "config" -Status "completed"

# =============================================================================
# Verify Azure CLI Login
# =============================================================================

Write-Step 2 "Verifying Azure CLI authentication"

try {
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) {
        Write-Error "Not logged in to Azure CLI"
        Write-Host "    Run: az login" -ForegroundColor Yellow
        exit 1
    }
    Write-Success "Logged in as: $($account.user.name)"
    Write-Info "Subscription: $($account.name)"
    
    # Set subscription if specified
    if ($subscriptionId) {
        az account set --subscription $subscriptionId
        Write-Info "Switched to subscription: $subscriptionId"
    }
    
    $subscriptionId = (az account show --query id -o tsv)
    $tenantId = (az account show --query tenantId -o tsv)
}
catch {
    Write-Error "Azure CLI error: $_"
    Write-Host "    Run: az login" -ForegroundColor Yellow
    exit 1
}

# =============================================================================
# Create or Reuse Okta Application (Idempotent)
# =============================================================================

Write-Step 3 "Creating/Finding Okta OIDC Application"

$oktaApiBase = "https://$oktaDomain"
$oktaHeaders = @{
    "Authorization" = "SSWS $oktaApiToken"
    "Accept"        = "application/json"
    "Content-Type"  = "application/json"
}

# Build redirect URIs
$botRedirectUri = "https://token.botframework.com/.auth/web/redirect"
# Logic App redirect will be added after we know the Logic App hostname

# Check if app already exists by searching for the label
Write-Info "Checking if Okta app '$oktaAppName' already exists..."
$existingApps = Invoke-RestMethod -Uri "$oktaApiBase/api/v1/apps?q=$([uri]::EscapeDataString($oktaAppName))&limit=50" -Method GET -Headers $oktaHeaders
$existingApp = $existingApps | Where-Object { $_.label -eq $oktaAppName }

if ($existingApp) {
    Write-Warning "Okta app '$oktaAppName' already exists - reusing it"
    $oktaApp = $existingApp
    $oktaAppId = $oktaApp.id
    $oktaClientId = $oktaApp.credentials.oauthClient.client_id
    
    # Check if we have the secret saved from a previous run
    if ($existingDeployment -and $existingDeployment.okta.clientSecret -and $existingDeployment.okta.clientId -eq $oktaClientId) {
        $oktaClientSecret = $existingDeployment.okta.clientSecret
        Write-Success "Reusing saved client secret from deployment-output.json"
    }
    else {
        # Need to generate a new secret - first check if we have room
        Write-Info "Generating new client secret for existing app..."
        $existingSecrets = Invoke-RestMethod -Uri "$oktaApiBase/api/v1/apps/$oktaAppId/credentials/secrets" -Method GET -Headers $oktaHeaders
        
        # If we have 2 secrets already (max), delete an inactive one first
        if ($existingSecrets.Count -ge 2) {
            $inactiveSecret = $existingSecrets | Where-Object { $_.status -eq "INACTIVE" } | Select-Object -First 1
            if ($inactiveSecret) {
                Write-Info "Removing inactive secret to make room..."
                Invoke-RestMethod -Uri "$oktaApiBase/api/v1/apps/$oktaAppId/credentials/secrets/$($inactiveSecret.id)" -Method DELETE -Headers $oktaHeaders | Out-Null
            }
            else {
                Write-Error "Cannot generate new secret - 2 active secrets exist and none are inactive."
                Write-Info "Please manually deactivate and delete a secret in Okta Admin Console:"
                Write-Info "Okta Admin > Applications > $oktaAppName > Client Credentials"
                exit 1
            }
        }
        
        try {
            $newSecret = Invoke-RestMethod -Uri "$oktaApiBase/api/v1/apps/$oktaAppId/credentials/secrets" -Method POST -Headers $oktaHeaders
            $oktaClientSecret = $newSecret.client_secret
            Write-Success "Generated new client secret"
        }
        catch {
            Write-Error "Could not generate new secret: $_"
            Write-Info "Okta Admin > Applications > $oktaAppName > Client Credentials"
            exit 1
        }
    }
    
    Write-Info "Client ID: $oktaClientId"
}
else {
    # Create new app
    $oktaAppBody = @{
        name     = "oidc_client"
        label    = $oktaAppName
        signOnMode = "OPENID_CONNECT"
        credentials = @{
            oauthClient = @{
                autoKeyRotation         = $true
                token_endpoint_auth_method = "client_secret_basic"
            }
        }
        settings = @{
            oauthClient = @{
                client_uri                    = $null
                logo_uri                      = $null
                redirect_uris                 = @($botRedirectUri)
                post_logout_redirect_uris     = @()
                response_types                = @("code")
                grant_types                   = @("authorization_code", "refresh_token")
                application_type              = "web"
                consent_method                = "REQUIRED"
                issuer_mode                   = "ORG_URL"
            }
        }
    } | ConvertTo-Json -Depth 10

    try {
        $oktaApp = Invoke-RestMethod -Uri "$oktaApiBase/api/v1/apps" -Method POST -Headers $oktaHeaders -Body $oktaAppBody
        $oktaClientId = $oktaApp.credentials.oauthClient.client_id
        $oktaClientSecret = $oktaApp.credentials.oauthClient.client_secret
        $oktaAppId = $oktaApp.id
        
        Write-Success "Okta app created: $oktaAppName"
        Write-Info "Client ID: $oktaClientId"
        
        # Activate the app
        Invoke-RestMethod -Uri "$oktaApiBase/api/v1/apps/$oktaAppId/lifecycle/activate" -Method POST -Headers $oktaHeaders | Out-Null
        Write-Success "Okta app activated"
        
        # Assign Everyone group
        $groups = Invoke-RestMethod -Uri "$oktaApiBase/api/v1/groups?q=Everyone" -Method GET -Headers $oktaHeaders
        $everyoneGroup = $groups | Where-Object { $_.profile.name -eq "Everyone" }
        if ($everyoneGroup) {
            try {
                Invoke-RestMethod -Uri "$oktaApiBase/api/v1/apps/$oktaAppId/groups/$($everyoneGroup.id)" -Method PUT -Headers $oktaHeaders | Out-Null
                Write-Success "Assigned 'Everyone' group to app"
            }
            catch {
                Write-Warning "Could not assign Everyone group (may need manual assignment)"
            }
        }
    }
    catch {
        Write-Error "Failed to create Okta app: $_"
        exit 1
    }
}

# Save Okta state
Save-DeploymentState -Step "okta-app" -Status "completed" -Data @{
    okta = @{
        appId        = $oktaAppId
        clientId     = $oktaClientId
        clientSecret = $oktaClientSecret
    }
}

# =============================================================================
# Ensure Azure Resource Group Exists
# =============================================================================

Write-Step 4 "Verifying Azure Resource Group"

$rgExists = az group exists --name $resourceGroup | ConvertFrom-Json
if ($rgExists) {
    Write-Success "Resource group '$resourceGroup' exists"
}
else {
    Write-Info "Creating resource group '$resourceGroup'..."
    az group create --name $resourceGroup --location $location --output none
    Write-Success "Created resource group: $resourceGroup"
}

# =============================================================================
# Create Bot App Registration
# =============================================================================

Write-Step 5 "Creating Bot App Registration (Entra ID)"

$botAppDisplayName = "$botName-app"

# Check if app already exists
$existingApp = az ad app list --display-name $botAppDisplayName --query "[0].appId" -o tsv 2>$null

if ($existingApp) {
    Write-Warning "App registration '$botAppDisplayName' already exists"
    $botAppId = $existingApp
    
    # Check if we have the password saved from a previous run
    if ($existingDeployment -and $existingDeployment.bot.appSecret -and $existingDeployment.bot.appId -eq $botAppId) {
        $botAppPassword = $existingDeployment.bot.appSecret
        Write-Success "Reusing saved bot app secret from deployment-output.json"
    }
    else {
        # Reset credentials
        $cred = az ad app credential reset --id $botAppId --display-name "bot-secret" --years 2 --query password -o tsv
        $botAppPassword = $cred
        Write-Success "Reset bot app credentials"
    }
}
else {
    # Create new app registration - SingleTenant (AzureADMyOrg)
    $botAppId = az ad app create `
        --display-name $botAppDisplayName `
        --sign-in-audience "AzureADMyOrg" `
        --query appId -o tsv
    
    Write-Success "Created app registration: $botAppDisplayName"
    Write-Info "App ID: $botAppId"
    
    # Create client secret
    $botAppPassword = az ad app credential reset --id $botAppId --display-name "bot-secret" --years 2 --query password -o tsv
    Write-Success "Created client secret"
}

# Ensure service principal exists for the app (required for MSAL auth)
$existingSp = az ad sp show --id $botAppId 2>$null
if (-not $existingSp) {
    az ad sp create --id $botAppId --output none
    Write-Success "Created service principal for bot app"
}
else {
    Write-Info "Service principal already exists"
}

# =============================================================================
# Create Azure Bot Service
# =============================================================================

Write-Step 6 "Creating Azure Bot Service"

$existingBot = az bot show --resource-group $resourceGroup --name $botName 2>$null
if ($existingBot) {
    Write-Warning "Bot '$botName' already exists"
}
else {
    # Use SingleTenant (MultiTenant is deprecated)
    az bot create `
        --resource-group $resourceGroup `
        --name $botName `
        --app-type "SingleTenant" `
        --appid $botAppId `
        --tenant-id $tenantId `
        --location "global" `
        --sku "F0" `
        --output none
    
    Write-Success "Created Azure Bot: $botName"
}

# Enable Teams channel
Write-Info "Enabling Teams channel..."
try {
    az bot msteams create --resource-group $resourceGroup --name $botName --output none 2>$null
    Write-Success "Teams channel enabled"
}
catch {
    Write-Warning "Teams channel may already be enabled"
}

# Save Bot state
Save-DeploymentState -Step "azure-bot" -Status "completed" -Data @{
    bot = @{
        appId     = $botAppId
        appSecret = $botAppPassword
    }
}

# =============================================================================
# Create Bot OAuth Connection (Okta) - Using REST API (proven working)
# =============================================================================

Write-Step 7 "Creating Bot OAuth Connection to Okta"

$connectionName = "okta"

$oktaAuthUrl = "https://$oktaDomain/oauth2/default/v1/authorize"
$oktaTokenUrl = "https://$oktaDomain/oauth2/default/v1/token"
$oktaScopes = "openid profile email offline_access"

# Use REST API directly (az bot authsetting has issues with Generic OAuth 2)
$oauthBody = @{
    location = "global"
    properties = @{
        serviceProviderId = "8379c6d2-b262-4d4f-b89b-68dc5b5f5482"
        serviceProviderDisplayName = "Oauth 2 Generic Provider"
        clientId = $oktaClientId
        clientSecret = $oktaClientSecret
        scopes = $oktaScopes
        parameters = @(
            @{ key = "authorizationUrl"; value = $oktaAuthUrl }
            @{ key = "tokenUrl"; value = $oktaTokenUrl }
            @{ key = "refreshUrl"; value = $oktaTokenUrl }
            @{ key = "clientId"; value = $oktaClientId }
            @{ key = "clientSecret"; value = $oktaClientSecret }
            @{ key = "scopes"; value = $oktaScopes }
            @{ key = "authorizationUrlTemplate"; value = $oktaAuthUrl }
            @{ key = "tokenUrlTemplate"; value = $oktaTokenUrl }
            @{ key = "refreshUrlTemplate"; value = $oktaTokenUrl }
        )
    }
} | ConvertTo-Json -Depth 10

$tempOAuthFile = [System.IO.Path]::GetTempFileName()
$oauthBody | Out-File -FilePath $tempOAuthFile -Encoding utf8

try {
    $oauthUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.BotService/botServices/$botName/connections/$connectionName`?api-version=2022-09-15"
    
    $result = az rest --method PUT --uri $oauthUri --body "@$tempOAuthFile" --headers "Content-Type=application/json" 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Created OAuth connection: $connectionName"
    } else {
        Write-Warning "OAuth connection creation returned: $result"
    }
} finally {
    Remove-Item -Path $tempOAuthFile -Force -ErrorAction SilentlyContinue
}

# Save OAuth connection state
Save-DeploymentState -Step "bot-oauth" -Status "completed" -Data @{
    bot = @{ oauthConnection = $connectionName }
}

# =============================================================================
# Create Logic App Infrastructure
# =============================================================================

Write-Step 8 "Creating Logic App Infrastructure"

# Create Storage Account
Write-Info "Creating Storage Account..."
$storageExists = az storage account show --name $storageName --resource-group $resourceGroup 2>$null
if (-not $storageExists) {
    az storage account create `
        --name $storageName `
        --resource-group $resourceGroup `
        --location $location `
        --sku "Standard_LRS" `
        --kind "StorageV2" `
        --output none
    Write-Success "Created storage account: $storageName"
}
else {
    Write-Warning "Storage account '$storageName' already exists"
}

$storageConnectionString = az storage account show-connection-string --name $storageName --resource-group $resourceGroup --query connectionString -o tsv

# Create App Service Plan
Write-Info "Creating App Service Plan..."
$planExists = az appservice plan show --name $appServicePlan --resource-group $resourceGroup 2>$null
if (-not $planExists) {
    az appservice plan create `
        --name $appServicePlan `
        --resource-group $resourceGroup `
        --location $location `
        --sku "WS1" `
        --output none
    Write-Success "Created App Service Plan: $appServicePlan"
}
else {
    Write-Warning "App Service Plan '$appServicePlan' already exists"
}

# Create Logic App
Write-Info "Creating Logic App Standard..."
$laExists = az logicapp show --name $logicAppName --resource-group $resourceGroup 2>$null
if (-not $laExists) {
    az logicapp create `
        --name $logicAppName `
        --resource-group $resourceGroup `
        --plan $appServicePlan `
        --storage-account $storageName `
        --output none
    Write-Success "Created Logic App: $logicAppName"
}
else {
    Write-Warning "Logic App '$logicAppName' already exists"
}

# Get Logic App hostname
$logicAppHostname = az logicapp show --name $logicAppName --resource-group $resourceGroup --query "defaultHostName" -o tsv
$logicAppUrl = "https://$logicAppHostname"

Write-Info "Logic App URL: $logicAppUrl"

# Save Logic App state
Save-DeploymentState -Step "logic-app" -Status "completed" -Data @{
    logicApp = @{
        url      = $logicAppUrl
        hostname = $logicAppHostname
    }
}

# =============================================================================
# Update Okta App with Logic App Redirect URI
# =============================================================================

Write-Step 9 "Updating Okta App with Logic App redirect URI"

$laRedirectUri = "$logicAppUrl/.auth/login/okta1test/callback"
$allRedirectUris = @($botRedirectUri, $laRedirectUri)

try {
    # GET the existing app, modify redirect_uris, PUT it back
    $existingApp = Invoke-RestMethod -Uri "$oktaApiBase/api/v1/apps/$oktaAppId" -Method GET -Headers $oktaHeaders
    
    # Update redirect URIs in the existing app object
    $existingApp.settings.oauthClient.redirect_uris = $allRedirectUris
    
    # Remove read-only fields that can't be sent back
    $existingApp.PSObject.Properties.Remove('id')
    $existingApp.PSObject.Properties.Remove('created')
    $existingApp.PSObject.Properties.Remove('lastUpdated')
    $existingApp.PSObject.Properties.Remove('status')
    $existingApp.PSObject.Properties.Remove('_links')
    $existingApp.PSObject.Properties.Remove('_embedded')
    if ($existingApp.credentials) {
        $existingApp.credentials.PSObject.Properties.Remove('signing')
    }
    
    $updateBody = $existingApp | ConvertTo-Json -Depth 20
    
    Invoke-RestMethod -Uri "$oktaApiBase/api/v1/apps/$oktaAppId" -Method PUT -Headers $oktaHeaders -Body $updateBody | Out-Null
    Write-Success "Added Logic App redirect URI to Okta app"
    Write-Info "Redirect URIs:"
    Write-Info "  - $botRedirectUri"
    Write-Info "  - $laRedirectUri"
}
catch {
    Write-Warning "Could not update Okta redirect URIs: $_"
    Write-Info "Please manually add this redirect URI in Okta Admin:"
    Write-Info "  $laRedirectUri"
}

# Save Okta redirect update state
Save-DeploymentState -Step "okta-redirect" -Status "completed" -Data @{
    redirectUris = $allRedirectUris
}

# =============================================================================
# Configure Logic App Easy Auth
# =============================================================================

Write-Step 10 "Configuring Logic App Easy Auth (Okta)"

$authConfigUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$logicAppName/config/authsettingsV2?api-version=2024-04-01"

$authConfig = @{
    properties = @{
        platform = @{
            enabled        = $true
            runtimeVersion = "~1"
        }
        globalValidation = @{
            requireAuthentication       = $true
            unauthenticatedClientAction = "Return401"
            redirectToProvider          = "okta1test"
        }
        identityProviders = @{
            customOpenIdConnectProviders = @{
                okta1test = @{
                    registration = @{
                        clientId = $oktaClientId
                        clientCredential = @{
                            clientSecretSettingName = "OKTA_CLIENT_SECRET"
                        }
                        openIdConnectConfiguration = @{
                            authorizationEndpoint = "https://$oktaDomain/oauth2/default/v1/authorize"
                            tokenEndpoint         = "https://$oktaDomain/oauth2/default/v1/token"
                            issuer                = "https://$oktaDomain/oauth2/default"
                            certificationUri      = "https://$oktaDomain/oauth2/default/v1/keys"
                            wellKnownOpenIdConfiguration = "https://$oktaDomain/oauth2/default/.well-known/openid-configuration"
                        }
                    }
                    login = @{
                        nameClaimType = "sub"
                        scopes        = @("openid", "profile", "email")
                        allowedAudiences = @($oktaClientId, "api://default")
                    }
                }
            }
        }
        login = @{
            tokenStore = @{
                enabled                   = $true
                tokenRefreshExtensionHours = 72.0
            }
        }
        httpSettings = @{
            requireHttps = $true
            routes = @{
                apiPrefix = "/.auth"
            }
        }
    }
} | ConvertTo-Json -Depth 10

# Store the Okta client secret in Logic App settings
az logicapp config appsettings set `
    --name $logicAppName `
    --resource-group $resourceGroup `
    --settings "OKTA_CLIENT_SECRET=$oktaClientSecret" `
    --output none

Write-Success "Stored Okta client secret in Logic App settings"

# Apply auth config
$token = az account get-access-token --query accessToken -o tsv
$authHeaders = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

try {
    Invoke-RestMethod -Uri $authConfigUri -Method PUT -Headers $authHeaders -Body $authConfig | Out-Null
    Write-Success "Easy Auth configured with Okta provider"
    
    # Save Easy Auth state
    Save-DeploymentState -Step "easy-auth" -Status "completed" -Data @{
        easyAuth = @{
            provider = "okta1test"
            enabled  = $true
        }
    }
}
catch {
    Write-Error "Failed to configure Easy Auth: $_"
    Write-Info "You may need to configure manually via Azure Portal"
}

# =============================================================================
# Generate Local Configuration Files
# =============================================================================

Write-Step 11 "Generating local configuration files"

# appsettings.local.json - must match structure in appsettings.json
$localSettings = @{
    TokenValidation = @{
        Enabled   = $true
        Audiences = @($botAppId)
        TenantId  = $tenantId
    }
    AgentApplication = @{
        StartTypingTimer      = $true
        RemoveRecipientMention = $false
        NormalizeMentions     = $false
        UserAuthorization = @{
            DefaultHandlerName = "auto"
            AutoSignin         = $true
            Handlers = @{
                auto = @{
                    Settings = @{
                        AzureBotOAuthConnectionName = $connectionName
                        Title = "Sign in"
                        Text  = "Please sign in to chat with the bot."
                    }
                }
            }
        }
    }
    Workflow = @{
        AgentUrl = "$logicAppUrl/api/MyAgentWorkflow/runs/invoke?api-version=2024-02-01-preview"
    }
    Connections = @{
        ServiceConnection = @{
            Settings = @{
                AuthType     = "ClientSecret"
                ClientId     = $botAppId
                TenantId     = $tenantId
                ClientSecret = $botAppPassword
                Scopes       = @("https://api.botframework.com/.default")
            }
        }
    }
    ConnectionsMap = @(
        @{
            ServiceUrl = "*"
            Connection = "ServiceConnection"
        }
    )
    Logging = @{
        LogLevel = @{
            Default                = "Information"
            "Microsoft.Agents"     = "Debug"
            "Microsoft.AspNetCore" = "Warning"
        }
    }
    Okta = @{
        Domain              = $oktaDomain
        ConnectionName      = $connectionName
        AuthorizationServer = "default"
    }
}

$localSettingsPath = Join-Path $projectRoot "appsettings.local.json"
$localSettings | ConvertTo-Json -Depth 10 | Set-Content $localSettingsPath -Encoding UTF8
Write-Success "Created: appsettings.local.json"

# Deployment output file
$deploymentOutput = @{
    timestamp       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    prefix          = $prefix
    azure = @{
        subscriptionId  = $subscriptionId
        tenantId        = $tenantId
        resourceGroup   = $resourceGroup
        location        = $location
    }
    bot = @{
        name            = $botName
        appId           = $botAppId
        appSecret       = $botAppPassword
        oauthConnection = $connectionName
    }
    logicApp = @{
        name            = $logicAppName
        url             = $logicAppUrl
        hostname        = $logicAppHostname
    }
    okta = @{
        domain          = $oktaDomain
        appId           = $oktaAppId
        clientId        = $oktaClientId
        clientSecret    = $oktaClientSecret
        appName         = $oktaAppName
    }
}

$outputPath = Join-Path $scriptDir "deployment-output.json"
$deploymentOutput | ConvertTo-Json -Depth 5 | Set-Content $outputPath -Encoding UTF8
Write-Success "Created: config/deployment-output.json"

# =============================================================================
# Summary
# =============================================================================

Write-Banner "Deployment Complete!"

Write-Host ""
Write-Host "Resources Created:" -ForegroundColor Cyan
Write-Host "  Resource Group:      $resourceGroup"
Write-Host "  Azure Bot:           $botName"
Write-Host "  Bot App ID:          $botAppId"
Write-Host "  Logic App:           $logicAppName"
Write-Host "  Logic App URL:       $logicAppUrl"
Write-Host "  Okta App:            $oktaAppName"
Write-Host "  Okta Client ID:      $oktaClientId"
Write-Host ""

Write-Host "Test in Web Chat:" -ForegroundColor Cyan
Write-Host "  https://portal.azure.com/#@microsoft.onmicrosoft.com/resource/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.BotService/botServices/$botName/test" -ForegroundColor White
Write-Host ""

Write-Host "Logic App Workflows:" -ForegroundColor Cyan
Write-Host "  https://portal.azure.com/#@microsoft.onmicrosoft.com/resource/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$logicAppName/workflows" -ForegroundColor White
Write-Host ""

Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Start dev tunnel and update bot endpoint:" -ForegroundColor White
Write-Host "     devtunnel host -p 5000 --allow-anonymous" -ForegroundColor Gray
Write-Host "     az bot update -g $resourceGroup -n $botName --endpoint https://<tunnel-url>/api/messages" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Create Logic App workflow (if not exists):" -ForegroundColor White
Write-Host "     - Open Logic App Workflows link above" -ForegroundColor Gray
Write-Host "     - Create workflow named 'MyAgentWorkflow' with Agent trigger" -ForegroundColor Gray
Write-Host ""
Write-Host "  3. Run the bot locally:" -ForegroundColor White
Write-Host "     dotnet run" -ForegroundColor Gray
Write-Host ""
Write-Host "  4. Test in Web Chat link above" -ForegroundColor White
Write-Host ""
Write-Host "Configuration saved to:" -ForegroundColor Cyan
Write-Host "  - appsettings.local.json (bot config)"
Write-Host "  - config/deployment-output.json (all credentials)"
Write-Host ""
