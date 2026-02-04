<#
.SYNOPSIS
    Phase 1: Create Azure Bot with Okta OAuth (NO Logic Apps).
    
.DESCRIPTION
    Creates:
    - Azure Bot Service with Entra ID app registration
    - Okta OIDC application
    - Bot OAuth connection to Okta
    
    This is a minimal setup to test Okta OAuth in isolation.
    The bot will return your Okta profile info when you message it.
    
.EXAMPLE
    .\deploy-phase1.ps1
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "deployment-config.json"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)

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

function Write-Warn {
    param([string]$Message)
    Write-Host "    ⚠ $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "    ✗ $Message" -ForegroundColor Red
}

function New-RandomSuffix {
    $chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    return -join ((1..6) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

# =============================================================================
# Load Configuration
# =============================================================================

Write-Banner "Phase 1: Create Azure Bot + Okta OAuth (No Logic Apps)"

$configPath = Join-Path $scriptDir $ConfigFile
if (-not (Test-Path $configPath)) {
    Write-Err "Config file not found: $configPath"
    exit 1
}

# Check for existing deployment
$outputPath = Join-Path $scriptDir "deployment-output.json"
$existingDeployment = $null
if (Test-Path $outputPath) {
    $existingDeployment = Get-Content $outputPath | ConvertFrom-Json
    Write-Info "Found existing deployment - will reuse resources with prefix: $($existingDeployment.prefix)"
}

Write-Step 1 "Loading configuration"

$config = Get-Content $configPath | ConvertFrom-Json

# Validate required fields
if (-not $config.okta.domain) { Write-Err "Please set 'okta.domain' in $ConfigFile"; exit 1 }
if (-not $config.okta.apiToken) { Write-Err "Please set 'okta.apiToken' in $ConfigFile"; exit 1 }
if (-not $config.azure.resourceGroup) { Write-Err "Please set 'azure.resourceGroup' in $ConfigFile"; exit 1 }

$resourceGroup = $config.azure.resourceGroup
$location = if ($config.azure.location) { $config.azure.location } else { "eastus" }

# Generate or reuse prefix
$prefix = $config.resources.prefix
if (-not $prefix -and $existingDeployment) {
    $prefix = $existingDeployment.prefix
}
if (-not $prefix) {
    $prefix = "okta$(New-RandomSuffix)"
    Write-Info "Auto-generated resource prefix: $prefix"
}

# Resource names
$botName = if ($config.resources.botName) { $config.resources.botName } else { "$prefix-bot" }
$oktaAppName = "Teams Bot (Okta Only) - $prefix"

$oktaDomain = $config.okta.domain
$oktaApiToken = $config.okta.apiToken

Write-Success "Configuration loaded"
Write-Info "Prefix:          $prefix"
Write-Info "Resource Group:  $resourceGroup"
Write-Info "Bot Name:        $botName"
Write-Info "Location:        $location"

# Initialize output state
$output = @{
    prefix    = $prefix
    phase     = "phase1-complete"
    timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    azure     = @{
        subscriptionId = ""
        resourceGroup  = $resourceGroup
        location       = $location
        tenantId       = ""
    }
    bot       = @{
        name       = $botName
        appId      = ""
        appSecret  = ""
    }
    okta      = @{
        domain       = $oktaDomain
        appName      = $oktaAppName
        clientId     = ""
        clientSecret = ""
    }
}

# =============================================================================
# Step 2: Verify Azure CLI
# =============================================================================

Write-Step 2 "Verifying Azure CLI authentication"

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Err "Not logged into Azure CLI. Run 'az login' first."
    exit 1
}

$subscriptionId = if ($config.azure.subscriptionId) { $config.azure.subscriptionId } else { $account.id }
$tenantId = $account.tenantId

az account set --subscription $subscriptionId 2>$null
Write-Success "Using subscription: $($account.name)"
Write-Info "Tenant ID: $tenantId"

$output.azure.subscriptionId = $subscriptionId
$output.azure.tenantId = $tenantId

# =============================================================================
# Step 3: Create Okta OIDC Application
# =============================================================================

Write-Step 3 "Creating/Finding Okta OIDC Application"

$oktaHeaders = @{
    "Authorization" = "SSWS $oktaApiToken"
    "Accept"        = "application/json"
    "Content-Type"  = "application/json"
}

# Check if app exists
$existingApps = Invoke-RestMethod -Uri "https://$oktaDomain/api/v1/apps?q=$([uri]::EscapeDataString($oktaAppName))" -Headers $oktaHeaders -Method GET
$oktaApp = $existingApps | Where-Object { $_.label -eq $oktaAppName } | Select-Object -First 1

if ($oktaApp) {
    Write-Info "Found existing Okta app: $($oktaApp.id)"
    $oktaClientId = $oktaApp.credentials.oauthClient.client_id
    
    if ($existingDeployment -and $existingDeployment.okta.clientSecret) {
        $oktaClientSecret = $existingDeployment.okta.clientSecret
        Write-Success "Reusing existing Okta client secret"
    }
    else {
        $secrets = Invoke-RestMethod -Uri "https://$oktaDomain/api/v1/apps/$($oktaApp.id)/credentials/secrets" -Headers $oktaHeaders -Method GET
        $activeSecrets = $secrets | Where-Object { $_.status -eq "ACTIVE" }
        
        if ($activeSecrets.Count -ge 2) {
            $oldest = $activeSecrets | Sort-Object created | Select-Object -First 1
            Invoke-RestMethod -Uri "https://$oktaDomain/api/v1/apps/$($oktaApp.id)/credentials/secrets/$($oldest.id)/lifecycle/deactivate" -Headers $oktaHeaders -Method POST | Out-Null
            Invoke-RestMethod -Uri "https://$oktaDomain/api/v1/apps/$($oktaApp.id)/credentials/secrets/$($oldest.id)" -Headers $oktaHeaders -Method DELETE | Out-Null
        }
        
        $newSecret = Invoke-RestMethod -Uri "https://$oktaDomain/api/v1/apps/$($oktaApp.id)/credentials/secrets" -Headers $oktaHeaders -Method POST
        $oktaClientSecret = $newSecret.client_secret
        Write-Success "Created new Okta client secret"
    }
}
else {
    Write-Info "Creating new Okta OIDC application..."
    
    $oktaAppBody = @{
        name     = "oidc_client"
        label    = $oktaAppName
        signOnMode = "OPENID_CONNECT"
        credentials = @{
            oauthClient = @{
                autoKeyRotation         = $true
                token_endpoint_auth_method = "client_secret_post"
            }
        }
        settings = @{
            oauthClient = @{
                client_uri                    = "https://placeholder.example.com"
                redirect_uris                 = @("https://token.botframework.com/.auth/web/redirect")
                response_types                = @("code")
                grant_types                   = @("authorization_code", "refresh_token")
                application_type              = "web"
                consent_method                = "REQUIRED"
                issuer_mode                   = "ORG_URL"
            }
        }
    } | ConvertTo-Json -Depth 10
    
    $oktaApp = Invoke-RestMethod -Uri "https://$oktaDomain/api/v1/apps" -Headers $oktaHeaders -Method POST -Body $oktaAppBody
    $oktaClientId = $oktaApp.credentials.oauthClient.client_id
    $oktaClientSecret = $oktaApp.credentials.oauthClient.client_secret
    
    Invoke-RestMethod -Uri "https://$oktaDomain/api/v1/apps/$($oktaApp.id)/lifecycle/activate" -Headers $oktaHeaders -Method POST | Out-Null
    $oktaApp = Invoke-RestMethod -Uri "https://$oktaDomain/api/v1/apps/$($oktaApp.id)" -Headers $oktaHeaders -Method GET
    
    # Assign Everyone group
    $groups = Invoke-RestMethod -Uri "https://$oktaDomain/api/v1/groups?q=Everyone" -Headers $oktaHeaders -Method GET
    $everyoneGroup = $groups | Where-Object { $_.profile.name -eq "Everyone" } | Select-Object -First 1
    if ($everyoneGroup) {
        try {
            Invoke-RestMethod -Uri "https://$oktaDomain/api/v1/apps/$($oktaApp.id)/groups/$($everyoneGroup.id)" -Headers $oktaHeaders -Method PUT | Out-Null
        } catch { }
    }
    
    Write-Success "Created Okta app: $oktaClientId"
}

$output.okta.clientId = $oktaClientId
$output.okta.clientSecret = $oktaClientSecret
$output.okta.appId = $oktaApp.id

# =============================================================================
# Step 4: Verify Resource Group
# =============================================================================

Write-Step 4 "Verifying Azure Resource Group"

$rgExists = az group exists --name $resourceGroup 2>$null
if ($rgExists -eq "false") {
    Write-Err "Resource group '$resourceGroup' does not exist. Create it first."
    exit 1
}
Write-Success "Resource group exists: $resourceGroup"

# =============================================================================
# Step 5: Create Bot App Registration
# =============================================================================

Write-Step 5 "Creating Bot App Registration (Entra ID)"

$existingApp = az ad app list --display-name $botName --query "[0]" 2>$null | ConvertFrom-Json

if ($existingApp) {
    $botAppId = $existingApp.appId
    Write-Info "Found existing app registration: $botAppId"
    
    if ($existingDeployment -and $existingDeployment.bot.appSecret) {
        $botAppSecret = $existingDeployment.bot.appSecret
        Write-Success "Reusing existing bot app secret"
    }
    else {
        $cred = az ad app credential reset --id $botAppId --years 2 2>$null | ConvertFrom-Json
        $botAppSecret = $cred.password
        Write-Success "Created new bot app secret"
    }
}
else {
    Write-Info "Creating new app registration..."
    $app = az ad app create --display-name $botName --sign-in-audience "AzureADMyOrg" 2>$null | ConvertFrom-Json
    $botAppId = $app.appId
    
    $cred = az ad app credential reset --id $botAppId --years 2 2>$null | ConvertFrom-Json
    $botAppSecret = $cred.password
    
    Write-Success "Created app registration: $botAppId"
}

# Ensure service principal exists
$sp = az ad sp show --id $botAppId 2>$null | ConvertFrom-Json
if (-not $sp) {
    Write-Info "Creating service principal..."
    az ad sp create --id $botAppId | Out-Null
    Write-Success "Service principal created"
}

$output.bot.appId = $botAppId
$output.bot.appSecret = $botAppSecret

# =============================================================================
# Step 6: Create Azure Bot Service
# =============================================================================

Write-Step 6 "Creating Azure Bot Service"

$existingBot = az bot show --resource-group $resourceGroup --name $botName 2>$null | ConvertFrom-Json

if ($existingBot) {
    Write-Success "Bot already exists: $botName"
}
else {
    Write-Info "Creating bot..."
    az bot create `
        --resource-group $resourceGroup `
        --name $botName `
        --app-type "SingleTenant" `
        --appid $botAppId `
        --tenant-id $tenantId `
        --location "global" `
        --sku "F0" `
        --output none
    
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to create bot. Check Azure permissions."
        exit 1
    }
    Write-Success "Created bot: $botName"
}

# Enable Teams channel
$channels = az bot show --resource-group $resourceGroup --name $botName --query "properties.enabledChannels" -o json 2>$null | ConvertFrom-Json
if ($channels -notcontains "msteams") {
    Write-Info "Enabling Teams channel..."
    az bot msteams create --resource-group $resourceGroup --name $botName --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Could not enable Teams channel (may already exist)"
    } else {
        Write-Success "Teams channel enabled"
    }
}

# =============================================================================
# Step 7: Create Bot OAuth Connection to Okta
# =============================================================================

Write-Step 7 "Creating Bot OAuth Connection to Okta"

$connectionName = "okta"
$existingConn = az bot authsetting show --resource-group $resourceGroup --name $botName --setting-name $connectionName 2>$null

if ($existingConn) {
    Write-Success "OAuth connection already exists: $connectionName"
}
else {
    Write-Info "Creating OAuth connection..."
    
    $oktaAuthUrl = "https://$oktaDomain/oauth2/default/v1/authorize"
    $oktaTokenUrl = "https://$oktaDomain/oauth2/default/v1/token"
    $oktaScopes = "openid profile email offline_access"
    
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
        
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Failed to create OAuth connection: $result"
            exit 1
        }
        Write-Success "OAuth connection created: $connectionName"
    } finally {
        Remove-Item -Path $tempOAuthFile -Force -ErrorAction SilentlyContinue
    }
}

$output.bot.oauthConnection = $connectionName

# =============================================================================
# Step 8: Generate Local Configuration Files
# =============================================================================

Write-Step 8 "Generating local configuration files"

$appSettings = @{
    Okta = @{
        Domain             = $oktaDomain
        ConnectionName     = "okta"
        AuthorizationServer = "default"
    }
    TokenValidation = @{
        Audiences = @($botAppId)
        Enabled   = $true
        TenantId  = $tenantId
    }
    ConnectionsMap = @(
        @{
            ServiceUrl = "*"
            Connection = "ServiceConnection"
        }
    )
    Connections = @{
        ServiceConnection = @{
            Settings = @{
                Scopes       = @("https://api.botframework.com/.default")
                TenantId     = $tenantId
                ClientSecret = $botAppSecret
                AuthType     = "ClientSecret"
                ClientId     = $botAppId
            }
        }
    }
    # No Workflow/AgentUrl - this is Okta-only mode
    AgentApplication = @{
        RemoveRecipientMention = $false
        UserAuthorization      = @{
            DefaultHandlerName = "auto"
            Handlers           = @{
                auto = @{
                    Settings = @{
                        Title                      = "Sign in with Okta"
                        Text                       = "Please sign in with your Okta account."
                        AzureBotOAuthConnectionName = "okta"
                    }
                }
            }
            AutoSignin = $true
        }
    }
    Logging = @{
        LogLevel = @{
            Default              = "Information"
            "Microsoft.Agents"   = "Debug"
            "Microsoft.AspNetCore" = "Warning"
        }
    }
}

$appSettingsPath = Join-Path $projectRoot "appsettings.local.json"
$appSettings | ConvertTo-Json -Depth 10 | Set-Content $appSettingsPath -Encoding UTF8
Write-Success "Created appsettings.local.json"

# Save deployment output
$output | ConvertTo-Json -Depth 10 | Set-Content $outputPath -Encoding UTF8
Write-Success "Saved deployment output to deployment-output.json"

# =============================================================================
# Summary
# =============================================================================

Write-Banner "Phase 1 Complete!"

Write-Host ""
Write-Host "  Resources created:" -ForegroundColor White
Write-Host "    • Bot Service:   $botName" -ForegroundColor Gray
Write-Host "    • Okta App:      $oktaAppName" -ForegroundColor Gray
Write-Host "    • OAuth Conn:    $connectionName" -ForegroundColor Gray
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Yellow
Write-Host "  TEST LOCALLY:" -ForegroundColor Yellow
Write-Host "  ============================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Start the bot:" -ForegroundColor White
Write-Host "     cd $projectRoot" -ForegroundColor Cyan
Write-Host "     dotnet run" -ForegroundColor Cyan
Write-Host ""
Write-Host "  2. Start a dev tunnel (in another terminal):" -ForegroundColor White
Write-Host "     devtunnel host -p 3978 --allow-anonymous" -ForegroundColor Cyan
Write-Host ""
Write-Host "  3. Update bot endpoint in Azure Portal:" -ForegroundColor White
Write-Host "     https://portal.azure.com/#resource/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.BotService/botServices/$botName/configuration" -ForegroundColor Cyan
Write-Host "     Set endpoint to: https://<your-tunnel>.devtunnels.ms/api/messages" -ForegroundColor Gray
Write-Host ""
Write-Host "  4. Test in Web Chat:" -ForegroundColor White
Write-Host "     https://portal.azure.com/#resource/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.BotService/botServices/$botName/test" -ForegroundColor Cyan
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Yellow
Write-Host "  DEPLOY TO AZURE:" -ForegroundColor Yellow
Write-Host "  ============================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Run Phase 2 to deploy to Azure App Service:" -ForegroundColor White
Write-Host "     .\deploy-phase2.ps1" -ForegroundColor Green
Write-Host ""

