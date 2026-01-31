<#
.SYNOPSIS
    Phase 2: Enable Easy Auth and finalize configuration.
    
.DESCRIPTION
    After you've created your Agent workflow in the Logic App portal:
    1. Run this script with the Agent URL
    2. It enables Easy Auth with Okta on the Logic App
    3. Updates your local bot configuration
    
.EXAMPLE
    .\deploy-phase2.ps1 -AgentUrl "https://mylogicapp.azurewebsites.net/api/Agents/MyWorkflow"
    
.EXAMPLE
    # If you want to skip the prompt:
    .\deploy-phase2.ps1 -AgentUrl "https://mylogicapp.azurewebsites.net/api/Agents/MyWorkflow" -Force
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$AgentUrl,
    
    [Parameter(Mandatory = $false)]
    [switch]$Force
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

Write-Banner "Phase 2: Enable Easy Auth & Finalize"

$outputPath = Join-Path $scriptDir "deployment-output.json"
if (-not (Test-Path $outputPath)) {
    Write-Err "deployment-output.json not found. Run deploy-phase1.ps1 first."
    exit 1
}

$deployment = Get-Content $outputPath | ConvertFrom-Json

if ($deployment.phase -eq "phase2-complete") {
    Write-Warn "Phase 2 already completed. Re-running will update the Agent URL."
    if (-not $Force) {
        $confirm = Read-Host "Continue? (y/n)"
        if ($confirm -ne "y") { exit 0 }
    }
}

Write-Step 1 "Loading Phase 1 deployment"

$resourceGroup = $deployment.azure.resourceGroup
$subscriptionId = $deployment.azure.subscriptionId
$tenantId = $deployment.azure.tenantId
$logicAppName = $deployment.logicApp.name
$botName = $deployment.bot.name
$oktaDomain = $deployment.okta.domain
$oktaClientId = $deployment.okta.clientId
$oktaClientSecret = $deployment.okta.clientSecret

Write-Success "Loaded deployment for prefix: $($deployment.prefix)"
Write-Info "Logic App:   $logicAppName"
Write-Info "Bot:         $botName"
Write-Info "Okta Client: $oktaClientId"

# =============================================================================
# Get or Validate Agent URL
# =============================================================================

Write-Step 2 "Validating Agent URL"

if (-not $AgentUrl) {
    Write-Host ""
    Write-Host "  Please enter the Agent URL from your workflow trigger." -ForegroundColor Yellow
    Write-Host "  (It should look like: https://$($deployment.logicApp.hostname)/api/Agents/YourWorkflowName)" -ForegroundColor Gray
    Write-Host ""
    $AgentUrl = Read-Host "  Agent URL"
}

if (-not $AgentUrl) {
    Write-Err "Agent URL is required"
    exit 1
}

# Validate URL format
if ($AgentUrl -notmatch "^https://.*\.azurewebsites\.net/api/Agents/.+$") {
    Write-Warn "URL doesn't match expected format (https://xxx.azurewebsites.net/api/Agents/WorkflowName)"
    if (-not $Force) {
        $confirm = Read-Host "Continue anyway? (y/n)"
        if ($confirm -ne "y") { exit 0 }
    }
}

# Extract workflow name from URL
$workflowName = $AgentUrl -replace "^.*/api/Agents/", "" -replace "/.*$", ""
Write-Success "Agent URL validated"
Write-Info "Workflow: $workflowName"

# =============================================================================
# Verify Azure CLI
# =============================================================================

Write-Step 3 "Verifying Azure CLI"

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Err "Not logged into Azure CLI. Run 'az login' first."
    exit 1
}

az account set --subscription $subscriptionId 2>$null
Write-Success "Using subscription: $($account.name)"

# =============================================================================
# Test that the workflow exists (without auth)
# =============================================================================

Write-Step 4 "Testing workflow accessibility"

Write-Info "Testing if workflow responds (without Easy Auth)..."

try {
    $testBody = '{"jsonrpc":"2.0","id":"test","method":"contexts/list","params":{"limit":1}}'
    $testResp = Invoke-WebRequest -Uri "$AgentUrl/" -Method POST -Headers @{"Content-Type"="application/json"} -Body $testBody -SkipHttpErrorCheck -TimeoutSec 10
    
    if ($testResp.StatusCode -eq 200) {
        Write-Success "Workflow is accessible and responding"
    }
    elseif ($testResp.StatusCode -eq 401 -and $testResp.Content -match "X-API-Key") {
        Write-Success "Workflow exists (requires API key when Easy Auth is off)"
    }
    elseif ($testResp.StatusCode -eq 401) {
        Write-Warn "Got 401 - Easy Auth may already be enabled"
    }
    else {
        Write-Warn "Got status $($testResp.StatusCode) - workflow may not be ready"
        Write-Info "Response: $($testResp.Content.Substring(0, [Math]::Min(200, $testResp.Content.Length)))"
    }
}
catch {
    Write-Warn "Could not reach workflow: $($_.Exception.Message)"
    if (-not $Force) {
        $confirm = Read-Host "Continue anyway? (y/n)"
        if ($confirm -ne "y") { exit 0 }
    }
}

# =============================================================================
# Enable Easy Auth with Okta
# =============================================================================

Write-Step 5 "Enabling Easy Auth with Okta"

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
                        clientId         = $oktaClientId
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
                enabled                    = $true
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

$authConfigPath = Join-Path $scriptDir "easyauth-config.json"
$authConfig | Set-Content $authConfigPath -Encoding UTF8

$uri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$logicAppName/config/authsettingsV2?api-version=2024-04-01"

Write-Info "Applying Easy Auth configuration..."
$result = az rest --method PUT --uri $uri --body "@$authConfigPath" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Success "Easy Auth enabled with Okta"
}
else {
    Write-Err "Failed to enable Easy Auth: $result"
    exit 1
}

# Clean up temp file
Remove-Item $authConfigPath -ErrorAction SilentlyContinue

# =============================================================================
# Update Local Configuration
# =============================================================================

Write-Step 6 "Updating local configuration"

$appSettingsPath = Join-Path $projectRoot "appsettings.local.json"

if (Test-Path $appSettingsPath) {
    $appSettings = Get-Content $appSettingsPath | ConvertFrom-Json
    
    # Update the Agent URL
    if (-not $appSettings.Workflow) {
        $appSettings | Add-Member -NotePropertyName "Workflow" -NotePropertyValue @{} -Force
    }
    $appSettings.Workflow.AgentUrl = $AgentUrl
    
    $appSettings | ConvertTo-Json -Depth 10 | Set-Content $appSettingsPath -Encoding UTF8
    Write-Success "Updated appsettings.local.json with Agent URL"
}
else {
    Write-Warn "appsettings.local.json not found - skipping local config update"
}

# =============================================================================
# Update Deployment Output
# =============================================================================

Write-Step 7 "Saving deployment state"

$deployment.phase = "phase2-complete"
$deployment.timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$deployment.logicApp | Add-Member -NotePropertyName "agentUrl" -NotePropertyValue $AgentUrl -Force
$deployment.logicApp | Add-Member -NotePropertyName "workflowName" -NotePropertyValue $workflowName -Force
$deployment.logicApp | Add-Member -NotePropertyName "easyAuthEnabled" -NotePropertyValue $true -Force

$deployment | ConvertTo-Json -Depth 10 | Set-Content $outputPath -Encoding UTF8
Write-Success "Saved to deployment-output.json"

# =============================================================================
# Summary
# =============================================================================

Write-Banner "Phase 2 Complete - Deployment Ready!"

Write-Host ""
Write-Host "  Configuration:" -ForegroundColor White
Write-Host "    • Logic App:     $logicAppName" -ForegroundColor Gray
Write-Host "    • Workflow:      $workflowName" -ForegroundColor Gray
Write-Host "    • Easy Auth:     Enabled (Okta)" -ForegroundColor Gray
Write-Host "    • Agent URL:     $AgentUrl" -ForegroundColor Gray
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Yellow
Write-Host "  TO TEST:" -ForegroundColor Yellow
Write-Host "  ============================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Start the bot locally:" -ForegroundColor White
Write-Host "     cd $projectRoot" -ForegroundColor Cyan
Write-Host "     dotnet run" -ForegroundColor Cyan
Write-Host ""
Write-Host "  2. Start a dev tunnel (in another terminal):" -ForegroundColor White
Write-Host "     devtunnel host -p 5000 --allow-anonymous" -ForegroundColor Cyan
Write-Host ""
Write-Host "  3. Update bot endpoint in Azure Portal:" -ForegroundColor White
Write-Host "     https://portal.azure.com/#resource/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.BotService/botServices/$botName/configuration" -ForegroundColor Cyan
Write-Host "     Set endpoint to: https://<your-tunnel>.devtunnels.ms/api/messages" -ForegroundColor Gray
Write-Host ""
Write-Host "  4. Test in Web Chat:" -ForegroundColor White
Write-Host "     https://portal.azure.com/#resource/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.BotService/botServices/$botName/test" -ForegroundColor Cyan
Write-Host ""
