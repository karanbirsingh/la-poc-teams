<#
.SYNOPSIS
    Cleanup script - deletes all resources created by deploy.ps1

.DESCRIPTION
    Reads deployment-output.json and removes all created resources:
    - Azure Resource Group (which deletes Bot, Logic App, Storage, etc.)
    - Okta Application
    - Azure AD App Registration

.EXAMPLE
    .\cleanup.ps1
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$OutputFile = "deployment-output.json",
    
    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir

function Write-Banner {
    param([string]$Message)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Red
    Write-Host "  $Message" -ForegroundColor Red
    Write-Host ("=" * 70) -ForegroundColor Red
}

function Write-Step {
    param([int]$Number, [string]$Message)
    Write-Host ""
    Write-Host "[$Number] $Message" -ForegroundColor Yellow
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

# =============================================================================
# Load Deployment Output
# =============================================================================

Write-Banner "Cleanup - Delete All Deployed Resources"

$outputPath = Join-Path $scriptDir $OutputFile
if (-not (Test-Path $outputPath)) {
    Write-Host ""
    Write-Host "No deployment-output.json found." -ForegroundColor Yellow
    Write-Host "Nothing to clean up, or resources were created manually." -ForegroundColor Yellow
    exit 0
}

$output = Get-Content $outputPath | ConvertFrom-Json

Write-Host ""
Write-Host "This will DELETE the following resources:" -ForegroundColor Red
Write-Host ""
Write-Host "  In Resource Group:     $($output.azure.resourceGroup)" -ForegroundColor White
Write-Host "    - Azure Bot:         $($output.bot.name)" -ForegroundColor Gray
Write-Host "    - Logic App:         $($output.logicApp.name)" -ForegroundColor Gray
Write-Host "    - Storage Account:   (associated with Logic App)" -ForegroundColor Gray
Write-Host "    - App Service Plan:  (associated with Logic App)" -ForegroundColor Gray
Write-Host "  Azure AD App:          $($output.bot.appId)" -ForegroundColor White
Write-Host "  Okta App:              $($output.okta.appName)" -ForegroundColor White
Write-Host ""
Write-Host "  NOTE: Resource Group itself will NOT be deleted (shared)" -ForegroundColor Yellow
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "Are you sure? Type 'yes' to confirm"
    if ($confirm -ne "yes") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# =============================================================================
# Delete Azure Resources (individually, preserve RG)
# =============================================================================

Write-Step 1 "Deleting Azure Resources"

$rg = $output.azure.resourceGroup

# Delete Bot
Write-Info "Deleting Azure Bot..."
try {
    az bot delete --resource-group $rg --name $output.bot.name --yes 2>$null
    Write-Success "Deleted bot: $($output.bot.name)"
}
catch {
    Write-Info "Bot not found or already deleted"
}

# Delete Logic App
Write-Info "Deleting Logic App..."
try {
    az logicapp delete --resource-group $rg --name $output.logicApp.name --yes 2>$null
    Write-Success "Deleted Logic App: $($output.logicApp.name)"
}
catch {
    Write-Info "Logic App not found or already deleted"
}

# Get prefix to find related resources
$prefix = $output.prefix

# Delete App Service Plan
Write-Info "Deleting App Service Plan..."
try {
    az appservice plan delete --resource-group $rg --name "$prefix-asp" --yes 2>$null
    Write-Success "Deleted App Service Plan"
}
catch {
    Write-Info "App Service Plan not found or already deleted"
}

# Delete Storage Account
Write-Info "Deleting Storage Account..."
$storageName = "$($prefix)store" -replace "[^a-z0-9]", ""
try {
    az storage account delete --resource-group $rg --name $storageName --yes 2>$null
    Write-Success "Deleted Storage Account: $storageName"
}
catch {
    Write-Info "Storage Account not found or already deleted"
}

# =============================================================================
# Delete Azure AD App Registration
# =============================================================================

Write-Step 2 "Deleting Azure AD App Registration"

try {
    $appExists = az ad app show --id $output.bot.appId 2>$null
    if ($appExists) {
        az ad app delete --id $output.bot.appId
        Write-Success "Deleted app registration: $($output.bot.appId)"
    }
    else {
        Write-Info "App registration not found (already deleted?)"
    }
}
catch {
    Write-Info "Could not delete app registration: $_"
}

# =============================================================================
# Delete Okta Application
# =============================================================================

Write-Step 3 "Deleting Okta Application"

# Load config to get API token
$configPath = Join-Path $scriptDir "deployment-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath | ConvertFrom-Json
    $oktaDomain = $config.okta.domain
    $oktaApiToken = $config.okta.apiToken
    
    if ($oktaApiToken -and $oktaApiToken -ne "YOUR_OKTA_API_TOKEN") {
        $oktaHeaders = @{
            "Authorization" = "SSWS $oktaApiToken"
            "Accept"        = "application/json"
        }
        
        try {
            # Deactivate first
            Invoke-RestMethod -Uri "https://$oktaDomain/api/v1/apps/$($output.okta.appId)/lifecycle/deactivate" -Method POST -Headers $oktaHeaders -ErrorAction SilentlyContinue | Out-Null
            
            # Then delete
            Invoke-RestMethod -Uri "https://$oktaDomain/api/v1/apps/$($output.okta.appId)" -Method DELETE -Headers $oktaHeaders | Out-Null
            Write-Success "Deleted Okta app: $($output.okta.appName)"
        }
        catch {
            Write-Info "Could not delete Okta app: $_"
            Write-Info "You may need to delete it manually from Okta Admin Console"
        }
    }
    else {
        Write-Info "No Okta API token in config - please delete Okta app manually"
    }
}
else {
    Write-Info "No config file found - please delete Okta app manually from Okta Admin Console"
}

# =============================================================================
# Clean Up Local Files
# =============================================================================

Write-Step 4 "Cleaning up local files"

$localSettingsPath = Join-Path $projectRoot "appsettings.local.json"
if (Test-Path $localSettingsPath) {
    Remove-Item $localSettingsPath -Force
    Write-Success "Deleted: appsettings.local.json"
}

# Optionally keep deployment-output.json for reference, or delete it
# Remove-Item $outputPath -Force
# Write-Success "Deleted: deployment-output.json"

Write-Host ""
Write-Host "Cleanup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Resource group '$($output.azure.resourceGroup)' was preserved." -ForegroundColor Yellow
Write-Host ""
