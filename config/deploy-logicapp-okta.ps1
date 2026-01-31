<#
.SYNOPSIS
    Deploys an Azure Logic App Standard with Okta Easy Auth configuration.

.DESCRIPTION
    This script provisions:
    1. Azure Storage Account (required for Logic App Standard)
    2. App Service Plan (Workflow Standard WS1)
    3. Logic App Standard
    4. Okta Easy Auth configuration
    5. Sample agent workflow

    The script uses your current Azure CLI login context (az account show).
    To change subscription: az account set --subscription "subscription-name-or-id"
    To login to a different tenant: az login --tenant "tenant-id"

.PARAMETER ResourceGroupName
    Name of the resource group (will be created if it doesn't exist)

.PARAMETER Location
    Azure region for deployment (default: eastus)

.PARAMETER LogicAppName
    Name for the Logic App Standard resource

.PARAMETER SubscriptionId
    Azure subscription ID (optional - defaults to current az cli subscription)

.PARAMETER OktaDomain
    Your Okta domain (e.g., integrator-7620286.okta.com)

.PARAMETER OktaClientId
    Okta application Client ID

.PARAMETER OktaClientSecret
    Okta application Client Secret

.EXAMPLE
    # Uses current Azure CLI subscription
    .\deploy-logicapp-okta.ps1 `
        -ResourceGroupName "karansin" `
        -LogicAppName "okta-easyauth-logicapp" `
        -OktaDomain "integrator-7620286.okta.com" `
        -OktaClientId "0oazoxkr5qr5bSJFs697" `
        -OktaClientSecret "your-secret-here"

.EXAMPLE
    # Specify a different subscription
    .\deploy-logicapp-okta.ps1 `
        -ResourceGroupName "karansin" `
        -SubscriptionId "3019d4d5-a172-4635-877f-9ad4001cfa85" `
        -LogicAppName "okta-easyauth-logicapp" `
        -OktaDomain "integrator-7620286.okta.com" `
        -OktaClientId "0oazoxkr5qr5bSJFs697" `
        -OktaClientSecret "your-secret-here"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory = $true)]
    [string]$LogicAppName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$OktaDomain,

    [Parameter(Mandatory = $true)]
    [string]$OktaClientId,

    [Parameter(Mandatory = $true)]
    [string]$OktaClientSecret
)

$ErrorActionPreference = "Stop"

# =============================================================================
# Step 0: Verify Azure CLI login and get subscription/tenant info
# =============================================================================
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Logic App Standard + Okta Easy Auth Deployment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "[0/6] Checking Azure CLI login..." -ForegroundColor Green

# Check if logged in
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "  ERROR: Not logged into Azure CLI. Please run 'az login' first." -ForegroundColor Red
    exit 1
}

# If subscription specified, switch to it
if ($SubscriptionId) {
    Write-Host "  Switching to subscription: $SubscriptionId"
    az account set --subscription $SubscriptionId
    $account = az account show | ConvertFrom-Json
}

$currentSubscriptionId = $account.id
$currentSubscriptionName = $account.name
$currentTenantId = $account.tenantId
$currentUser = $account.user.name

Write-Host "  Logged in as:    $currentUser" -ForegroundColor Green
Write-Host "  Tenant ID:       $currentTenantId" -ForegroundColor Green
Write-Host "  Subscription:    $currentSubscriptionName" -ForegroundColor Green
Write-Host "  Subscription ID: $currentSubscriptionId" -ForegroundColor Green
Write-Host ""

# Use the current subscription ID
$subscriptionId = $currentSubscriptionId

# Generate unique names for resources
$timestamp = Get-Date -Format "yyyyMMddHHmm"
$storageAccountName = ($LogicAppName -replace '[^a-z0-9]', '').ToLower().Substring(0, [Math]::Min(20, $LogicAppName.Length)) + "st"
$appServicePlanName = "$LogicAppName-plan"
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Resource Group:    $ResourceGroupName"
Write-Host "  Location:          $Location"
Write-Host "  Logic App:         $LogicAppName"
Write-Host "  Storage Account:   $storageAccountName"
Write-Host "  App Service Plan:  $appServicePlanName"
Write-Host "  Okta Domain:       $OktaDomain"
Write-Host "  Okta Client ID:    $OktaClientId"
Write-Host ""

# =============================================================================
# Step 1: Ensure Resource Group exists
# =============================================================================
Write-Host "[1/6] Checking resource group..." -ForegroundColor Green

$rgExists = az group exists --name $ResourceGroupName | ConvertFrom-Json
if (-not $rgExists) {
    Write-Host "  Creating resource group '$ResourceGroupName' in '$Location'..."
    az group create --name $ResourceGroupName --location $Location --output none
    Write-Host "  Resource group created." -ForegroundColor Green
} else {
    Write-Host "  Resource group already exists." -ForegroundColor Green
}

# =============================================================================
# Step 2: Create Storage Account
# =============================================================================
Write-Host "[2/6] Creating storage account..." -ForegroundColor Green

# Check if storage account exists
$storageExists = az storage account check-name --name $storageAccountName --query "nameAvailable" -o tsv
if ($storageExists -eq "true") {
    az storage account create `
        --name $storageAccountName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --sku Standard_LRS `
        --kind StorageV2 `
        --output none
    Write-Host "  Storage account '$storageAccountName' created." -ForegroundColor Green
} else {
    Write-Host "  Storage account '$storageAccountName' already exists or name unavailable." -ForegroundColor Yellow
}

# Get storage connection string
$storageConnectionString = az storage account show-connection-string `
    --name $storageAccountName `
    --resource-group $ResourceGroupName `
    --query connectionString -o tsv

# =============================================================================
# Step 3: Create App Service Plan (Workflow Standard)
# =============================================================================
Write-Host "[3/6] Creating App Service Plan..." -ForegroundColor Green

$planExists = az appservice plan show --name $appServicePlanName --resource-group $ResourceGroupName 2>$null
if (-not $planExists) {
    az appservice plan create `
        --name $appServicePlanName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --sku WS1 `
        --output none
    Write-Host "  App Service Plan '$appServicePlanName' created (WS1 - Workflow Standard)." -ForegroundColor Green
} else {
    Write-Host "  App Service Plan already exists." -ForegroundColor Green
}

# =============================================================================
# Step 4: Create Logic App Standard
# =============================================================================
Write-Host "[4/6] Creating Logic App Standard..." -ForegroundColor Green

$logicAppExists = az logicapp show --name $LogicAppName --resource-group $ResourceGroupName 2>$null
if (-not $logicAppExists) {
    az logicapp create `
        --name $LogicAppName `
        --resource-group $ResourceGroupName `
        --plan $appServicePlanName `
        --storage-account $storageAccountName `
        --output none
    Write-Host "  Logic App '$LogicAppName' created." -ForegroundColor Green
} else {
    Write-Host "  Logic App already exists." -ForegroundColor Green
}

# Get Logic App hostname
$logicAppHostname = az logicapp show `
    --name $LogicAppName `
    --resource-group $ResourceGroupName `
    --query "defaultHostName" -o tsv

Write-Host "  Logic App URL: https://$logicAppHostname" -ForegroundColor Cyan

# =============================================================================
# Step 5: Configure Okta Easy Auth
# =============================================================================
Write-Host "[5/6] Configuring Okta Easy Auth..." -ForegroundColor Green

# First, add OKTA_CLIENT_SECRET to app settings
Write-Host "  Adding OKTA_CLIENT_SECRET to app settings..."
az logicapp config appsettings set `
    --name $LogicAppName `
    --resource-group $ResourceGroupName `
    --settings "OKTA_CLIENT_SECRET=$OktaClientSecret" `
    --output none

# Get access token for REST API call (uses current subscription context)
$accessToken = az account get-access-token --query accessToken -o tsv

# Build the Easy Auth configuration JSON
$authConfig = @{
    id = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$LogicAppName/config/authsettingsV2"
    name = "authsettingsV2"
    type = "Microsoft.Web/sites/config"
    location = $Location
    properties = @{
        platform = @{
            enabled = $true
            runtimeVersion = "~1"
        }
        globalValidation = @{
            requireAuthentication = $true
            unauthenticatedClientAction = "RedirectToLoginPage"
            redirectToProvider = "okta1test"
            excludedPaths = @(
                "/runtime/*"
            )
        }
        identityProviders = @{
            customOpenIdConnectProviders = @{
                okta1test = @{
                    registration = @{
                        clientId = $OktaClientId
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
                        scopes = @(
                            "openid"
                            "profile"
                            "email"
                        )
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
            cookieExpiration = @{
                convention = "FixedTime"
                timeToExpiration = "08:00:00"
            }
            nonce = @{
                validateNonce = $true
                nonceExpirationInterval = "00:05:00"
            }
        }
        httpSettings = @{
            requireHttps = $true
            routes = @{
                apiPrefix = "/.auth"
            }
            forwardProxy = @{
                convention = "NoProxy"
            }
        }
    }
} | ConvertTo-Json -Depth 20

# Make REST API call to configure Easy Auth
Write-Host "  Applying Easy Auth configuration via REST API..."
$uri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$LogicAppName/config/authsettingsV2?api-version=2024-04-01"

try {
    $response = Invoke-RestMethod -Uri $uri -Method Put -Body $authConfig -Headers @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type" = "application/json"
    }
    Write-Host "  Okta Easy Auth configured successfully." -ForegroundColor Green
} catch {
    Write-Host "  Warning: Easy Auth configuration may have failed. Error: $_" -ForegroundColor Yellow
    Write-Host "  You may need to configure Easy Auth manually via the Azure Portal." -ForegroundColor Yellow
}

# =============================================================================
# Step 6: Create Sample Agent Workflow
# =============================================================================
Write-Host "[6/6] Creating sample agent workflow..." -ForegroundColor Green

# Create a simple echo workflow definition
$workflowDefinition = @{
    definition = @{
        '$schema' = "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#"
        contentVersion = "1.0.0.0"
        triggers = @{
            When_a_HTTP_request_is_received = @{
                type = "Request"
                kind = "Http"
                inputs = @{
                    method = "POST"
                }
                operationOptions = "EnableAgentMode"
            }
        }
        actions = @{
            Get_User_Info = @{
                type = "Compose"
                inputs = "@triggerOutputs()?['headers']?['x-ms-client-principal-name']"
                runAfter = @{}
            }
            Get_Message = @{
                type = "Compose"
                inputs = "@triggerBody()?['message']?['parts']?[0]?['text']"
                runAfter = @{
                    Get_User_Info = @("Succeeded")
                }
            }
            Response = @{
                type = "Response"
                kind = "Http"
                inputs = @{
                    statusCode = 200
                    body = @{
                        response = "Hello from Logic Apps! You said: @{outputs('Get_Message')}. Authenticated as: @{outputs('Get_User_Info')}"
                    }
                }
                runAfter = @{
                    Get_Message = @("Succeeded")
                }
            }
        }
    }
    kind = "Stateful"
} | ConvertTo-Json -Depth 20

# Save workflow to temp file and deploy
$tempWorkflowPath = Join-Path $env:TEMP "workflow.json"
$workflowDefinition | Out-File -FilePath $tempWorkflowPath -Encoding UTF8

Write-Host "  Note: Sample workflow definition created." -ForegroundColor Green
Write-Host "  To deploy the workflow, use the Logic Apps extension in VS Code" -ForegroundColor Yellow
Write-Host "  or the Azure Portal designer." -ForegroundColor Yellow

# =============================================================================
# Summary
# =============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Deployment Complete!" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Resources Created:" -ForegroundColor Yellow
Write-Host "  - Resource Group:     $ResourceGroupName"
Write-Host "  - Storage Account:    $storageAccountName"
Write-Host "  - App Service Plan:   $appServicePlanName"
Write-Host "  - Logic App:          $LogicAppName"
Write-Host ""
Write-Host "Logic App URL:" -ForegroundColor Yellow
Write-Host "  https://$logicAppHostname" -ForegroundColor Cyan
Write-Host ""
Write-Host "Easy Auth Provider:" -ForegroundColor Yellow
Write-Host "  Provider Name:  okta1test"
Write-Host "  Okta Domain:    $OktaDomain"
Write-Host "  Client ID:      $OktaClientId"
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  1. Add this redirect URI to your Okta app:" -ForegroundColor White
Write-Host "     https://$logicAppHostname/.auth/login/okta1test/callback" -ForegroundColor Cyan
Write-Host ""
Write-Host "  2. Create an agent workflow in the Logic App" -ForegroundColor White
Write-Host "     (use VS Code Logic Apps extension or Azure Portal)" -ForegroundColor White
Write-Host ""
Write-Host "  3. Get the agent URL from the workflow trigger and update your bot's appsettings:" -ForegroundColor White
Write-Host "     Workflow section -> AgentUrl" -ForegroundColor White
Write-Host ""
Write-Host "  4. Update appsettings.local.json with:" -ForegroundColor White
Write-Host @"
     {
       "Workflow": {
         "AgentUrl": "https://$logicAppHostname/api/<workflow-name>/triggers/When_a_HTTP_request_is_received/invoke?api-version=2022-05-01"
       }
     }
"@ -ForegroundColor Gray
Write-Host ""

# Output config for reference
$outputConfig = @{
    logicApp = @{
        name = $LogicAppName
        resourceGroup = $ResourceGroupName
        url = "https://$logicAppHostname"
        easyAuthCallbackUrl = "https://$logicAppHostname/.auth/login/okta1test/callback"
    }
    okta = @{
        domain = $OktaDomain
        clientId = $OktaClientId
        providerName = "okta1test"
    }
    storage = @{
        accountName = $storageAccountName
    }
}

$outputConfigPath = Join-Path $PSScriptRoot "logicapp-deployment-output.json"
$outputConfig | ConvertTo-Json -Depth 5 | Out-File -FilePath $outputConfigPath -Encoding UTF8
Write-Host "Configuration saved to: $outputConfigPath" -ForegroundColor Green
