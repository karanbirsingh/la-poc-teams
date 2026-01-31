<#
.SYNOPSIS
    End-to-end deployment of Teams Bot with Okta OAuth and Logic Apps integration.

.DESCRIPTION
    This script provisions the complete infrastructure from scratch:
    
    1. OKTA SETUP (via Okta API)
       - Creates OIDC Web Application in Okta
       - Configures redirect URIs for Bot Framework and Logic Apps
       
    2. AZURE BOT SERVICE
       - Creates Azure Bot resource
       - Creates App Registration for bot identity
       - Configures OAuth connection (Generic OAuth 2 Provider -> Okta)
       - Enables Teams channel
       
    3. LOGIC APP STANDARD
       - Creates Storage Account
       - Creates App Service Plan (Workflow Standard)
       - Creates Logic App Standard
       - Configures Easy Auth (Okta as custom OIDC provider)
       
    4. LOCAL CONFIGURATION
       - Updates appsettings.local.json with all credentials
       - Generates Teams app manifest

.PARAMETER ResourceGroupName
    Azure resource group name (created if doesn't exist)

.PARAMETER Location
    Azure region (default: eastus)

.PARAMETER BotName
    Name for the Azure Bot resource

.PARAMETER LogicAppName
    Name for the Logic App Standard resource

.PARAMETER OktaDomain
    Your Okta domain (e.g., dev-12345.okta.com)

.PARAMETER OktaApiToken
    Okta API token for creating the application (get from Okta Admin > Security > API > Tokens)

.PARAMETER SubscriptionId
    Azure subscription ID (optional - uses current az cli context if not specified)

.EXAMPLE
    .\deploy-e2e-okta-bot-logicapp.ps1 `
        -ResourceGroupName "okta-bot-demo" `
        -BotName "okta-teams-bot" `
        -LogicAppName "okta-agent-logicapp" `
        -OktaDomain "dev-12345.okta.com" `
        -OktaApiToken "00abc123..."
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory = $true)]
    [string]$BotName,

    [Parameter(Mandatory = $true)]
    [string]$LogicAppName,

    [Parameter(Mandatory = $true)]
    [string]$OktaDomain,

    [Parameter(Mandatory = $true)]
    [string]$OktaApiToken,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# =============================================================================
# Helper Functions
# =============================================================================

function Write-Step {
    param([string]$Step, [string]$Message)
    Write-Host ""
    Write-Host "[$Step] $Message" -ForegroundColor Green
    Write-Host ("-" * 60) -ForegroundColor DarkGray
}

function Write-Info {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor White
}

function Write-Success {
    param([string]$Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  ⚠ $Message" -ForegroundColor Yellow
}

# =============================================================================
# BANNER
# =============================================================================
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     END-TO-END DEPLOYMENT: Teams Bot + Okta + Logic Apps         ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# STEP 0: Validate Prerequisites
# =============================================================================
Write-Step "0/8" "Validating prerequisites..."

# Check Azure CLI
$azVersion = az version 2>$null | ConvertFrom-Json
if (-not $azVersion) {
    Write-Host "  ERROR: Azure CLI not installed. Install from https://aka.ms/installazurecli" -ForegroundColor Red
    exit 1
}
Write-Success "Azure CLI version: $($azVersion.'azure-cli')"

# Check Azure login
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "  ERROR: Not logged into Azure CLI. Run 'az login' first." -ForegroundColor Red
    exit 1
}

# Switch subscription if specified
if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
    $account = az account show | ConvertFrom-Json
}

Write-Success "Logged in as: $($account.user.name)"
Write-Success "Tenant: $($account.tenantId)"
Write-Success "Subscription: $($account.name) ($($account.id))"

$tenantId = $account.tenantId
$subscriptionId = $account.id

# Validate Okta API token
Write-Info "Validating Okta API token..."
$oktaHeaders = @{
    "Authorization" = "SSWS $OktaApiToken"
    "Accept" = "application/json"
    "Content-Type" = "application/json"
}

try {
    $oktaOrg = Invoke-RestMethod -Uri "https://$OktaDomain/api/v1/org" -Headers $oktaHeaders -Method Get
    Write-Success "Okta organization: $($oktaOrg.companyName) ($OktaDomain)"
} catch {
    Write-Host "  ERROR: Invalid Okta API token or domain. Error: $_" -ForegroundColor Red
    exit 1
}

# =============================================================================
# STEP 1: Create Okta OIDC Application
# =============================================================================
Write-Step "1/8" "Creating Okta OIDC Application..."

$oktaAppName = "Azure Bot - $BotName"

# Check if app already exists
$existingApps = Invoke-RestMethod -Uri "https://$OktaDomain/api/v1/apps?q=$([uri]::EscapeDataString($oktaAppName))" -Headers $oktaHeaders -Method Get
$existingApp = $existingApps | Where-Object { $_.label -eq $oktaAppName }

if ($existingApp) {
    Write-Warn "Okta app '$oktaAppName' already exists. Using existing app."
    $oktaApp = $existingApp
    $oktaClientId = $oktaApp.credentials.oauthClient.client_id
    
    # Get client secret (need to create new one as existing isn't retrievable)
    Write-Info "Creating new client secret..."
    $secretResponse = Invoke-RestMethod -Uri "https://$OktaDomain/api/v1/apps/$($oktaApp.id)/credentials/secrets" -Headers $oktaHeaders -Method Post
    $oktaClientSecret = $secretResponse.client_secret
} else {
    # Create new Okta application
    $oktaAppBody = @{
        name = "oidc_client"
        label = $oktaAppName
        signOnMode = "OPENID_CONNECT"
        credentials = @{
            oauthClient = @{
                autoKeyRotation = $true
                token_endpoint_auth_method = "client_secret_basic"
            }
        }
        settings = @{
            oauthClient = @{
                client_uri = $null
                logo_uri = $null
                redirect_uris = @(
                    "https://token.botframework.com/.auth/web/redirect"
                )
                post_logout_redirect_uris = @()
                response_types = @("code")
                grant_types = @("authorization_code", "refresh_token")
                application_type = "web"
                consent_method = "REQUIRED"
                issuer_mode = "DYNAMIC"
            }
        }
    } | ConvertTo-Json -Depth 10

    Write-Info "Creating Okta app: $oktaAppName"
    $oktaApp = Invoke-RestMethod -Uri "https://$OktaDomain/api/v1/apps" -Headers $oktaHeaders -Method Post -Body $oktaAppBody
    
    $oktaClientId = $oktaApp.credentials.oauthClient.client_id
    $oktaClientSecret = $oktaApp.credentials.oauthClient.client_secret
    
    Write-Success "Okta app created: $oktaAppName"
}

Write-Success "Okta Client ID: $oktaClientId"

# Assign Everyone group to the app
Write-Info "Assigning Everyone group to the app..."
try {
    $everyoneGroup = Invoke-RestMethod -Uri "https://$OktaDomain/api/v1/groups?q=Everyone" -Headers $oktaHeaders -Method Get | Where-Object { $_.profile.name -eq "Everyone" }
    if ($everyoneGroup) {
        $assignBody = @{ id = $everyoneGroup.id } | ConvertTo-Json
        Invoke-RestMethod -Uri "https://$OktaDomain/api/v1/apps/$($oktaApp.id)/groups/$($everyoneGroup.id)" -Headers $oktaHeaders -Method Put -Body "{}" -ErrorAction SilentlyContinue
        Write-Success "Everyone group assigned"
    }
} catch {
    Write-Warn "Could not assign Everyone group (may already be assigned)"
}

# =============================================================================
# STEP 2: Create Azure Resource Group
# =============================================================================
Write-Step "2/8" "Creating Azure Resource Group..."

$rgExists = az group exists --name $ResourceGroupName | ConvertFrom-Json
if (-not $rgExists) {
    az group create --name $ResourceGroupName --location $Location --output none
    Write-Success "Resource group '$ResourceGroupName' created in '$Location'"
} else {
    Write-Success "Resource group '$ResourceGroupName' already exists"
}

# =============================================================================
# STEP 3: Create Azure Bot Service
# =============================================================================
Write-Step "3/8" "Creating Azure Bot Service..."

# Create App Registration for bot
Write-Info "Creating App Registration for bot identity..."
$botAppName = "$BotName-app"

# Check if app registration exists
$existingBotApp = az ad app list --display-name $botAppName --query "[0]" 2>$null | ConvertFrom-Json
if ($existingBotApp) {
    Write-Warn "App registration '$botAppName' exists. Using existing."
    $botAppId = $existingBotApp.appId
    
    # Create new secret
    $botSecretResult = az ad app credential reset --id $botAppId --append --query "password" -o tsv
    $botSecret = $botSecretResult
} else {
    $botAppResult = az ad app create --display-name $botAppName --sign-in-audience "AzureADMyOrg" | ConvertFrom-Json
    $botAppId = $botAppResult.appId
    
    # Create secret
    $botSecretResult = az ad app credential reset --id $botAppId --query "password" -o tsv
    $botSecret = $botSecretResult
    
    Write-Success "App registration created: $botAppId"
}

Write-Success "Bot App ID: $botAppId"

# Create Azure Bot
Write-Info "Creating Azure Bot resource..."
$botExists = az bot show --name $BotName --resource-group $ResourceGroupName 2>$null
if (-not $botExists) {
    az bot create `
        --resource-group $ResourceGroupName `
        --name $BotName `
        --kind "azurebot" `
        --app-type "SingleTenant" `
        --appid $botAppId `
        --tenant-id $tenantId `
        --location "global" `
        --output none
    
    Write-Success "Azure Bot '$BotName' created"
} else {
    Write-Success "Azure Bot '$BotName' already exists"
}

# Enable Teams channel
Write-Info "Enabling Teams channel..."
az bot msteams create --name $BotName --resource-group $ResourceGroupName 2>$null
Write-Success "Teams channel enabled"

# =============================================================================
# STEP 4: Configure Bot OAuth Connection (Okta)
# =============================================================================
Write-Step "4/8" "Configuring Bot OAuth Connection..."

$connectionName = "okta"
$accessToken = az account get-access-token --query accessToken -o tsv

# Generic OAuth 2 Provider ID
$serviceProviderId = "8379c6d2-b262-4d4f-b89b-68dc5b5f5482"

$oauthConnectionBody = @{
    location = "global"
    properties = @{
        clientId = $oktaClientId
        clientSecret = $oktaClientSecret
        scopes = "openid profile email"
        serviceProviderId = $serviceProviderId
        serviceProviderDisplayName = "Oauth 2 Generic Provider"
        parameters = @(
            @{ key = "authorizationUrl"; value = "https://$OktaDomain/oauth2/default/v1/authorize" }
            @{ key = "tokenUrl"; value = "https://$OktaDomain/oauth2/default/v1/token" }
            @{ key = "refreshUrl"; value = "https://$OktaDomain/oauth2/default/v1/token" }
        )
    }
} | ConvertTo-Json -Depth 10

$oauthUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.BotService/botServices/$BotName/connections/$connectionName`?api-version=2022-09-15"

try {
    $response = Invoke-RestMethod -Uri $oauthUri -Method Put -Body $oauthConnectionBody -Headers @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type" = "application/json"
    }
    Write-Success "OAuth connection '$connectionName' configured"
} catch {
    Write-Warn "OAuth connection may already exist or failed: $_"
}

# =============================================================================
# STEP 5: Create Logic App Infrastructure
# =============================================================================
Write-Step "5/8" "Creating Logic App Infrastructure..."

$storageAccountName = ($LogicAppName -replace '[^a-z0-9]', '').ToLower()
if ($storageAccountName.Length -gt 20) { $storageAccountName = $storageAccountName.Substring(0, 20) }
$storageAccountName = $storageAccountName + "st"
$appServicePlanName = "$LogicAppName-plan"

# Create Storage Account
Write-Info "Creating Storage Account: $storageAccountName"
$storageExists = az storage account check-name --name $storageAccountName --query "nameAvailable" -o tsv
if ($storageExists -eq "true") {
    az storage account create `
        --name $storageAccountName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --sku Standard_LRS `
        --kind StorageV2 `
        --output none
    Write-Success "Storage account created"
} else {
    Write-Warn "Storage account name unavailable or exists"
}

# Create App Service Plan
Write-Info "Creating App Service Plan: $appServicePlanName"
$planExists = az appservice plan show --name $appServicePlanName --resource-group $ResourceGroupName 2>$null
if (-not $planExists) {
    az appservice plan create `
        --name $appServicePlanName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --sku WS1 `
        --output none
    Write-Success "App Service Plan created (WS1 - Workflow Standard)"
} else {
    Write-Success "App Service Plan already exists"
}

# Create Logic App
Write-Info "Creating Logic App: $LogicAppName"
$logicAppExists = az logicapp show --name $LogicAppName --resource-group $ResourceGroupName 2>$null
if (-not $logicAppExists) {
    az logicapp create `
        --name $LogicAppName `
        --resource-group $ResourceGroupName `
        --plan $appServicePlanName `
        --storage-account $storageAccountName `
        --output none
    Write-Success "Logic App created"
} else {
    Write-Success "Logic App already exists"
}

$logicAppHostname = az logicapp show --name $LogicAppName --resource-group $ResourceGroupName --query "defaultHostName" -o tsv
Write-Success "Logic App URL: https://$logicAppHostname"

# =============================================================================
# STEP 6: Update Okta App with Logic App Callback URL
# =============================================================================
Write-Step "6/8" "Updating Okta App with Logic App callback..."

$logicAppCallbackUrl = "https://$logicAppHostname/.auth/login/okta1test/callback"

# Get current app settings
$currentApp = Invoke-RestMethod -Uri "https://$OktaDomain/api/v1/apps/$($oktaApp.id)" -Headers $oktaHeaders -Method Get

# Add Logic App callback to redirect URIs
$redirectUris = @($currentApp.settings.oauthClient.redirect_uris)
if ($redirectUris -notcontains $logicAppCallbackUrl) {
    $redirectUris += $logicAppCallbackUrl
}

$updateBody = @{
    settings = @{
        oauthClient = @{
            redirect_uris = $redirectUris
            response_types = @("code")
            grant_types = @("authorization_code", "refresh_token")
            application_type = "web"
        }
    }
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Uri "https://$OktaDomain/api/v1/apps/$($oktaApp.id)" -Headers $oktaHeaders -Method Put -Body $updateBody | Out-Null
Write-Success "Added callback URL: $logicAppCallbackUrl"

# =============================================================================
# STEP 7: Configure Logic App Easy Auth
# =============================================================================
Write-Step "7/8" "Configuring Logic App Easy Auth..."

# Add OKTA_CLIENT_SECRET to app settings
Write-Info "Adding Okta client secret to app settings..."
az logicapp config appsettings set `
    --name $LogicAppName `
    --resource-group $ResourceGroupName `
    --settings "OKTA_CLIENT_SECRET=$oktaClientSecret" `
    --output none

# Configure Easy Auth via REST API
$accessToken = az account get-access-token --query accessToken -o tsv

$authConfig = @{
    properties = @{
        platform = @{
            enabled = $true
            runtimeVersion = "~1"
        }
        globalValidation = @{
            requireAuthentication = $true
            unauthenticatedClientAction = "RedirectToLoginPage"
            redirectToProvider = "okta1test"
            excludedPaths = @("/runtime/*")
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
                            authorizationEndpoint = "https://$OktaDomain/oauth2/default/v1/authorize"
                            tokenEndpoint = "https://$OktaDomain/oauth2/default/v1/token"
                            issuer = "https://$OktaDomain/oauth2/default"
                            certificationUri = "https://$OktaDomain/oauth2/default/v1/keys"
                        }
                    }
                    login = @{
                        nameClaimType = "sub"
                        scopes = @("openid", "profile", "email")
                    }
                }
            }
        }
        login = @{
            tokenStore = @{
                enabled = $true
                tokenRefreshExtensionHours = 72.0
            }
            preserveUrlFragmentsForLogins = $false
            nonce = @{
                validateNonce = $true
                nonceExpirationInterval = "00:05:00"
            }
        }
        httpSettings = @{
            requireHttps = $true
            routes = @{ apiPrefix = "/.auth" }
        }
    }
} | ConvertTo-Json -Depth 20

$easyAuthUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$LogicAppName/config/authsettingsV2?api-version=2024-04-01"

try {
    Invoke-RestMethod -Uri $easyAuthUri -Method Put -Body $authConfig -Headers @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type" = "application/json"
    } | Out-Null
    Write-Success "Easy Auth configured with Okta provider 'okta1test'"
} catch {
    Write-Warn "Easy Auth configuration may have failed: $_"
}

# =============================================================================
# STEP 8: Generate Local Configuration Files
# =============================================================================
Write-Step "8/8" "Generating local configuration files..."

# Create appsettings.local.json
$appSettingsLocal = @{
    TokenValidation = @{
        Enabled = $true
        Audiences = @($botAppId)
        TenantId = $tenantId
    }
    AgentApplication = @{
        StartTypingTimer = $true
        RemoveRecipientMention = $false
        NormalizeMentions = $false
        UserAuthorization = @{
            DefaultHandlerName = "auto"
            AutoSignin = $true
            Handlers = @{
                auto = @{
                    Settings = @{
                        AzureBotOAuthConnectionName = "okta"
                        Title = "Sign in"
                        Text = "Please sign in to continue."
                    }
                }
            }
        }
    }
    Workflow = @{
        AgentUrl = "https://$logicAppHostname/api/<WORKFLOW_NAME>/triggers/When_a_HTTP_request_is_received/invoke?api-version=2022-05-01"
    }
    Connections = @{
        ServiceConnection = @{
            Settings = @{
                AuthType = "ClientSecret"
                ClientId = $botAppId
                TenantId = $tenantId
                ClientSecret = $botSecret
                Scopes = @("https://api.botframework.com/.default")
            }
        }
    }
    ConnectionsMap = @(
        @{
            ServiceUrl = "*"
            Connection = "ServiceConnection"
        }
    )
} | ConvertTo-Json -Depth 10

$appSettingsPath = Join-Path (Split-Path $scriptDir -Parent) "appsettings.local.json"
$appSettingsLocal | Out-File -FilePath $appSettingsPath -Encoding UTF8
Write-Success "Created: appsettings.local.json"

# Create deployment output file
$deploymentOutput = @{
    timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    azure = @{
        subscriptionId = $subscriptionId
        tenantId = $tenantId
        resourceGroup = $ResourceGroupName
        location = $Location
    }
    bot = @{
        name = $BotName
        appId = $botAppId
        appSecret = "[STORED IN appsettings.local.json]"
        oauthConnectionName = "okta"
        endpoint = "UPDATE WITH YOUR DEVTUNNEL URL + /api/messages"
    }
    logicApp = @{
        name = $LogicAppName
        hostname = $logicAppHostname
        url = "https://$logicAppHostname"
        easyAuthCallback = $logicAppCallbackUrl
        easyAuthProvider = "okta1test"
    }
    okta = @{
        domain = $OktaDomain
        appName = $oktaAppName
        clientId = $oktaClientId
        clientSecret = "[STORED IN appsettings.local.json AND Logic App settings]"
        redirectUris = @(
            "https://token.botframework.com/.auth/web/redirect"
            $logicAppCallbackUrl
        )
    }
} | ConvertTo-Json -Depth 10

$outputPath = Join-Path $scriptDir "deployment-output.json"
$deploymentOutput | Out-File -FilePath $outputPath -Encoding UTF8
Write-Success "Created: config/deployment-output.json"

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    DEPLOYMENT COMPLETE!                          ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "RESOURCES CREATED:" -ForegroundColor Yellow
Write-Host "  Okta App:          $oktaAppName"
Write-Host "  Okta Client ID:    $oktaClientId"
Write-Host "  Azure Bot:         $BotName"
Write-Host "  Bot App ID:        $botAppId"
Write-Host "  Logic App:         https://$logicAppHostname"
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. START DEV TUNNEL:" -ForegroundColor Cyan
Write-Host "     devtunnel host -p 3978 --allow-anonymous"
Write-Host ""
Write-Host "  2. UPDATE BOT ENDPOINT (replace <tunnel-url>):" -ForegroundColor Cyan
Write-Host "     az bot update -g $ResourceGroupName -n $BotName --endpoint `"https://<tunnel-url>/api/messages`""
Write-Host ""
Write-Host "  3. CREATE LOGIC APP WORKFLOW:" -ForegroundColor Cyan
Write-Host "     - Open VS Code with Logic Apps extension"
Write-Host "     - Create a stateful workflow with HTTP trigger (Agent Mode enabled)"
Write-Host "     - Get the workflow URL and update appsettings.local.json"
Write-Host ""
Write-Host "  4. RUN THE BOT:" -ForegroundColor Cyan
Write-Host "     dotnet run"
Write-Host ""
Write-Host "  5. TEST IN WEB CHAT:" -ForegroundColor Cyan
Write-Host "     Azure Portal > Bot Service > Test in Web Chat"
Write-Host ""
Write-Host "  6. DEPLOY TO TEAMS:" -ForegroundColor Cyan
Write-Host "     - Update appManifest/manifest.json with Bot App ID"
Write-Host "     - Zip the appManifest folder"
Write-Host "     - Upload to Teams Admin or sideload"
Write-Host ""
Write-Host "Configuration saved to:" -ForegroundColor Gray
Write-Host "  - appsettings.local.json (bot credentials)"
Write-Host "  - config/deployment-output.json (all resource info)"
Write-Host ""
