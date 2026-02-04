<#
.SYNOPSIS
    Phase 2: Deploy bot to Azure App Service and create Teams app package.
    
.DESCRIPTION
    After Phase 1 (Okta + Bot resources), this script:
    1. Creates an Azure App Service for the bot
    2. Configures all app settings
    3. Publishes the .NET bot to Azure
    4. Updates the bot endpoint to the App Service URL
    5. Creates a Teams app manifest zip for sideloading
    
.EXAMPLE
    .\deploy-phase2.ps1
    
.EXAMPLE
    # Skip Teams package creation:
    .\deploy-phase2.ps1 -SkipTeamsPackage
#>

param(
    [Parameter(Mandatory = $false)]
    [switch]$SkipTeamsPackage,
    
    [Parameter(Mandatory = $false)]
    [switch]$Force
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

# =============================================================================
# Load Phase 1 Output
# =============================================================================

Write-Banner "Phase 2: Deploy to Azure App Service & Create Teams Package"

$outputPath = Join-Path $scriptDir "deployment-output.json"
if (-not (Test-Path $outputPath)) {
    Write-Err "deployment-output.json not found. Run deploy-phase1.ps1 first."
    exit 1
}

$deployment = Get-Content $outputPath | ConvertFrom-Json

Write-Step 1 "Loading deployment configuration"

$prefix = $deployment.prefix
$resourceGroup = $deployment.azure.resourceGroup
$subscriptionId = $deployment.azure.subscriptionId
$tenantId = $deployment.azure.tenantId
$location = $deployment.azure.location

$botName = $deployment.bot.name
$botAppId = $deployment.bot.appId
$botAppSecret = $deployment.bot.appSecret

$oktaDomain = $deployment.okta.domain

# Derived names
$botAppServiceName = "$prefix-bot-app"
$botAspName = "$prefix-bot-asp"

Write-Success "Loaded deployment for prefix: $prefix"
Write-Info "Bot:          $botName"
Write-Info "App Service:  $botAppServiceName"

# =============================================================================
# Step 2: Verify Azure CLI
# =============================================================================

Write-Step 2 "Verifying Azure CLI authentication"

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Err "Not logged into Azure CLI. Run 'az login' first."
    exit 1
}

az account set --subscription $subscriptionId 2>$null
Write-Success "Using subscription: $($account.name)"

# =============================================================================
# Step 3: Create App Service Plan for Bot
# =============================================================================

Write-Step 3 "Creating App Service Plan for bot"

$existingPlan = az appservice plan show --resource-group $resourceGroup --name $botAspName 2>$null
if ($existingPlan) {
    Write-Success "App Service Plan already exists: $botAspName"
} else {
    Write-Info "Creating App Service Plan: $botAspName"
    az appservice plan create `
        --resource-group $resourceGroup `
        --name $botAspName `
        --location $location `
        --sku B1 `
        --output none
    
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to create App Service Plan"
        exit 1
    }
    Write-Success "Created App Service Plan: $botAspName"
}

# =============================================================================
# Step 4: Create App Service for Bot
# =============================================================================

Write-Step 4 "Creating App Service for bot"

$existingApp = az webapp show --resource-group $resourceGroup --name $botAppServiceName 2>$null
if ($existingApp) {
    Write-Success "App Service already exists: $botAppServiceName"
} else {
    Write-Info "Creating App Service: $botAppServiceName"
    az webapp create `
        --resource-group $resourceGroup `
        --plan $botAspName `
        --name $botAppServiceName `
        --runtime "dotnet:8" `
        --output none
    
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to create App Service"
        exit 1
    }
    Write-Success "Created App Service: $botAppServiceName"
}

$botAppServiceUrl = "https://$botAppServiceName.azurewebsites.net"
Write-Info "App Service URL: $botAppServiceUrl"

# =============================================================================
# Step 5: Configure App Settings
# =============================================================================

Write-Step 5 "Configuring App Service settings"

Write-Info "Setting bot credentials..."
az webapp config appsettings set `
    --resource-group $resourceGroup `
    --name $botAppServiceName `
    --settings `
        "MicrosoftAppId=$botAppId" `
        "MicrosoftAppPassword=$botAppSecret" `
        "MicrosoftAppTenantId=$tenantId" `
        "MicrosoftAppType=SingleTenant" `
    --output none

Write-Info "Setting Okta configuration..."
az webapp config appsettings set `
    --resource-group $resourceGroup `
    --name $botAppServiceName `
    --settings `
        "Okta__Domain=$oktaDomain" `
        "Okta__ConnectionName=okta" `
        "Okta__AuthorizationServer=default" `
    --output none

Write-Info "Setting token validation..."
az webapp config appsettings set `
    --resource-group $resourceGroup `
    --name $botAppServiceName `
    --settings `
        "TokenValidation__Enabled=true" `
        "TokenValidation__TenantId=$tenantId" `
        "TokenValidation__Audiences__0=$botAppId" `
    --output none

Write-Info "Setting agent application configuration..."
az webapp config appsettings set `
    --resource-group $resourceGroup `
    --name $botAppServiceName `
    --settings `
        "AgentApplication__UserAuthorization__DefaultHandlerName=auto" `
        "AgentApplication__UserAuthorization__AutoSignin=true" `
        "AgentApplication__UserAuthorization__Handlers__auto__Settings__AzureBotOAuthConnectionName=okta" `
        "AgentApplication__UserAuthorization__Handlers__auto__Settings__Title=Sign in with Okta" `
        "AgentApplication__RemoveRecipientMention=false" `
    --output none

Write-Info "Setting service connection..."
az webapp config appsettings set `
    --resource-group $resourceGroup `
    --name $botAppServiceName `
    --settings `
        "Connections__ServiceConnection__Settings__ClientId=$botAppId" `
        "Connections__ServiceConnection__Settings__ClientSecret=$botAppSecret" `
        "Connections__ServiceConnection__Settings__TenantId=$tenantId" `
        "Connections__ServiceConnection__Settings__AuthType=ClientSecret" `
    --output none

Write-Success "All app settings configured"

# =============================================================================
# Step 6: Build and Deploy Bot
# =============================================================================

Write-Step 6 "Building and deploying bot"

$publishPath = Join-Path $projectRoot "publish"
$zipPath = Join-Path $projectRoot "bot-deploy.zip"

# Find the .csproj file
$csprojFiles = Get-ChildItem -Path $projectRoot -Filter "*.csproj" | Select-Object -First 1
if (-not $csprojFiles) {
    Write-Err "No .csproj file found in $projectRoot"
    exit 1
}
$csprojPath = $csprojFiles.FullName

Write-Info "Building project: $($csprojFiles.Name)"
Push-Location $projectRoot
try {
    dotnet publish $csprojPath -c Release -o $publishPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Build failed"
        exit 1
    }
    Write-Success "Build completed"
    
    Write-Info "Creating deployment package..."
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path "$publishPath\*" -DestinationPath $zipPath -Force
    Write-Success "Created deployment package"
    
    Write-Info "Deploying to Azure..."
    az webapp deployment source config-zip `
        --resource-group $resourceGroup `
        --name $botAppServiceName `
        --src $zipPath `
        --output none
    
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Deployment failed"
        exit 1
    }
    Write-Success "Deployed to $botAppServiceName"
} finally {
    Pop-Location
}

# =============================================================================
# Step 7: Update Bot Endpoint
# =============================================================================

Write-Step 7 "Updating bot messaging endpoint"

$botEndpoint = "$botAppServiceUrl/api/messages"

az bot update `
    --resource-group $resourceGroup `
    --name $botName `
    --endpoint $botEndpoint `
    --output none

if ($LASTEXITCODE -ne 0) {
    Write-Err "Failed to update bot endpoint"
    exit 1
}
Write-Success "Bot endpoint updated to: $botEndpoint"

# =============================================================================
# Step 8: Create Teams App Package
# =============================================================================

if (-not $SkipTeamsPackage) {
    Write-Step 8 "Creating Teams app package"
    
    $appManifestDir = Join-Path $projectRoot "appManifest"
    $teamsZipPath = Join-Path $projectRoot "teams-app.zip"
    $manifestPath = Join-Path $appManifestDir "manifest.json"
    
    if (-not (Test-Path $appManifestDir)) {
        Write-Warn "appManifest directory not found. Creating..."
        New-Item -ItemType Directory -Path $appManifestDir | Out-Null
    }
    
    Write-Info "Generating manifest.json..."
    $manifest = @{
        '$schema' = "https://developer.microsoft.com/json-schemas/teams/v1.22/MicrosoftTeams.schema.json"
        manifestVersion = "1.22"
        version = "1.0.0"
        id = $botAppId
        developer = @{
            name = "Okta OAuth Demo"
            websiteUrl = $botAppServiceUrl
            privacyUrl = "$botAppServiceUrl/privacy"
            termsOfUseUrl = "$botAppServiceUrl/termsofuse"
        }
        icons = @{
            color = "color.png"
            outline = "outline.png"
        }
        name = @{
            short = "Okta OAuth Bot"
            full = "Teams Bot with Okta OAuth Demo"
        }
        description = @{
            short = "Test Okta OAuth integration"
            full = "A Teams bot that demonstrates Okta OAuth authentication. Returns your Okta profile info when you send a message."
        }
        accentColor = "#FFFFFF"
        copilotAgents = @{
            customEngineAgents = @(
                @{
                    id = $botAppId
                    type = "bot"
                }
            )
        }
        bots = @(
            @{
                botId = $botAppId
                scopes = @("personal", "copilot")
                supportsFiles = $false
                isNotificationOnly = $false
            }
        )
        permissions = @("identity", "messageTeamMembers")
        validDomains = @(
            "token.botframework.com"
            "*.devtunnels.ms"
            "*.azurewebsites.net"
        )
    }
    
    $manifest | ConvertTo-Json -Depth 10 | Set-Content $manifestPath -Encoding UTF8
    Write-Success "Generated manifest.json"
    
    # Check for icon files
    $colorIconPath = Join-Path $appManifestDir "color.png"
    $outlineIconPath = Join-Path $appManifestDir "outline.png"
    
    if (-not (Test-Path $colorIconPath) -or -not (Test-Path $outlineIconPath)) {
        Write-Warn "Icon files missing. Creating placeholder icons..."
        
        $colorPng = [Convert]::FromBase64String("iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAhUlEQVR4Ae3TsQ3AIAwF0NyRBRiF0bIKozAKozAKo9BQRJGSeODu8C+g4IX/G0AQBEEQBEEQBEEQBE3w7i8Ah3s/c859zjn3uffe+xxjjDHGGOM65xxzzDHHPPfcc6+99tprr7332muvvfbaa6+99tprr7322muvvfbaa6+99tprr/8FABcAnp1nYGe/oAAAAABJRU5ErkJggg==")
        $outlinePng = [Convert]::FromBase64String("iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAfUlEQVR4Ae2TsQoAIQxD6///c3sIJ3RQweIiOIg2IfgAAQDAADCAASqlfwDoHoK7IyLuIuIuAAAAAMA/AJzzWGvNvfdea631rLWeZ611zjnXWmudc45zzrn3vvfaa6+19t577bXXXnvttdcGABgABhDAAAAAYIABBvgC8AY04XAhuMPfJQAAAABJRU5ErkJggg==")
        
        [System.IO.File]::WriteAllBytes($colorIconPath, $colorPng)
        [System.IO.File]::WriteAllBytes($outlineIconPath, $outlinePng)
        Write-Success "Created placeholder icons"
    }
    
    Write-Info "Creating Teams app package..."
    if (Test-Path $teamsZipPath) { Remove-Item $teamsZipPath -Force }
    Compress-Archive -Path "$appManifestDir\*" -DestinationPath $teamsZipPath -Force
    Write-Success "Created: teams-app.zip"
}

# =============================================================================
# Step 9: Update Deployment Output
# =============================================================================

Write-Step 9 "Saving deployment state"

$deployment.phase = "phase2-complete"
$deployment.timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$deployment | Add-Member -NotePropertyName "appService" -NotePropertyValue @{
    name = $botAppServiceName
    url = $botAppServiceUrl
    endpoint = $botEndpoint
    planName = $botAspName
} -Force

$deployment | ConvertTo-Json -Depth 10 | Set-Content $outputPath -Encoding UTF8
Write-Success "Saved to deployment-output.json"

# =============================================================================
# Summary
# =============================================================================

Write-Banner "Phase 2 Complete - Okta OAuth Bot Deployed!"

Write-Host ""
Write-Host "  Deployment:" -ForegroundColor White
Write-Host "    • App Service:   $botAppServiceName" -ForegroundColor Gray
Write-Host "    • URL:           $botAppServiceUrl" -ForegroundColor Gray
Write-Host "    • Bot Endpoint:  $botEndpoint" -ForegroundColor Gray
Write-Host ""
if (-not $SkipTeamsPackage) {
    Write-Host "  Teams App Package:" -ForegroundColor White
    Write-Host "    • File:          $teamsZipPath" -ForegroundColor Gray
    Write-Host ""
}
Write-Host "  ============================================================" -ForegroundColor Yellow
Write-Host "  WHAT THIS BOT DOES:" -ForegroundColor Yellow
Write-Host "  ============================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  When you send a message, the bot will:" -ForegroundColor White
Write-Host "    1. Prompt you to sign in with Okta (if not already signed in)" -ForegroundColor Gray
Write-Host "    2. Get your Okta access token" -ForegroundColor Gray
Write-Host "    3. Return your Okta profile info (name, email)" -ForegroundColor Gray
Write-Host ""
Write-Host "  Commands:" -ForegroundColor White
Write-Host "    • -me       Show your full Okta profile" -ForegroundColor Gray
Write-Host "    • -signout  Sign out of Okta" -ForegroundColor Gray
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Yellow
Write-Host "  TEST IN TEAMS:" -ForegroundColor Yellow
Write-Host "  ============================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Open Microsoft Teams" -ForegroundColor White
Write-Host ""
Write-Host "  2. Go to: Apps → Manage your apps → Upload an app" -ForegroundColor White
Write-Host ""
Write-Host "  3. Select 'Upload a custom app' and choose:" -ForegroundColor White
Write-Host "     $teamsZipPath" -ForegroundColor Cyan
Write-Host ""
Write-Host "  4. Click 'Add' to install the bot" -ForegroundColor White
Write-Host ""
Write-Host "  5. Send any message - you'll be prompted to sign in with Okta!" -ForegroundColor White
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Yellow
Write-Host "  TEST IN WEB CHAT:" -ForegroundColor Yellow
Write-Host "  ============================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  https://portal.azure.com/#resource/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.BotService/botServices/$botName/test" -ForegroundColor Cyan
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Yellow
Write-Host "  NEXT STEP - ADD LOGIC APPS:" -ForegroundColor Yellow
Write-Host "  ============================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  The Okta token obtained here can be passed to Logic Apps." -ForegroundColor White
Write-Host "  See the full demo (deploy-scripts-reference branch) for" -ForegroundColor White
Write-Host "  Logic Apps integration with Easy Auth." -ForegroundColor White
Write-Host ""

