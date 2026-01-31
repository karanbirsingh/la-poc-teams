# Teams Bot + Okta OAuth + Logic Apps POC - Session Summary

**Date:** January 30, 2026  
**Status:** ✅ WORKING - Bot successfully authenticates via Okta and calls Logic App Agent

---

## Project Overview

This POC demonstrates a Teams Bot that:
1. Authenticates users via **Okta OAuth 2.0**
2. Calls **Azure Logic App Standard** Agent workflows with the authenticated token
3. Uses **Easy Auth** on the Logic App to validate Okta tokens

---

## Current Deployment State

### Resources Created (prefix: `la92zr4o`)

| Resource | Name | Status |
|----------|------|--------|
| Logic App | `la92zr4o-la` | ✅ Working, Easy Auth enabled |
| Storage Account | `la92zr4ostore` | ✅ Created |
| App Service Plan | `la92zr4o-asp` | ✅ Created |
| Okta OIDC App | `0oazp35rwcu4LTwE7697` | ✅ Working |
| Bot App Registration | `f6d74d50-58e1-4959-9434-4a84841d8f89` | ✅ Created |
| Azure Bot Service | `la92zr4o-bot` | ✅ Working |
| Bot OAuth Connection | `okta` | ✅ Working |

### Current Configuration

- **Agent URL:** `https://la92zr4o-la.azurewebsites.net/api/Agents/test`
- **Bot Endpoint:** `https://3xzxv6pv-5000.usw2.devtunnels.ms/api/messages` (dev tunnel)
- **Okta Domain:** `integrator-7620286.okta.com`
- **Okta Client ID:** `0oazp35rwcu4LTwE7697`

---

## Files Modified During This Session

### Deployment Scripts

| File | Changes |
|------|---------|
| `config/deploy-phase1.ps1` | Fixed: `az logicapp` instead of `az functionapp`, removed `--is-linux`, fixed Okta app update, removed `--password` from bot create, **changed OAuth connection to use REST API instead of CLI** |
| `config/deploy-phase2.ps1` | Fixed: Added missing Easy Auth config fields (`wellKnownOpenIdConfiguration`, `allowedAudiences`, `httpSettings`) |
| `config/cleanup.ps1` | Fixed: `az logicapp delete` instead of `az functionapp delete` |

### Application Code

| File | Changes |
|------|---------|
| `Infrastructure/A2ATimestampRewriteHandler.cs` | Added support for Logic App timestamp format `M/d/yyyy h:mm:ss tt zzz` |
| `AuthAgent.cs` | Added ILoggerFactory injection for timestamp handler logging |

---

## Critical Fixes Made

### 1. OAuth Connection Creation
**Problem:** `az bot authsetting create --service "generic"` fails with "A service provider with the name generic was not found"

**Solution:** Use REST API directly with the correct serviceProviderId:
```powershell
$oauthBody = @{
    location = "global"
    properties = @{
        serviceProviderId = "8379c6d2-b262-4d4f-b89b-68dc5b5f5482"  # Generic OAuth 2
        serviceProviderDisplayName = "Oauth 2 Generic Provider"
        clientId = $oktaClientId
        clientSecret = $oktaClientSecret
        # ... parameters
    }
}
az rest --method PUT --uri $oauthUri --body "@$tempFile"
```

### 2. Logic App Commands
**Problem:** Used `az functionapp` commands which don't work for Logic App Standard

**Solution:** Use `az logicapp` commands:
- `az logicapp create` (not `az functionapp create`)
- `az logicapp show` (not `az functionapp show`)
- `az logicapp delete` (not `az functionapp delete`)

### 3. App Service Plan Creation
**Problem:** `--is-linux $false` parameter caused silent failure

**Solution:** Remove the parameter, let Azure default to Windows

### 4. Bot Creation
**Problem:** `--password` parameter not needed for SingleTenant bots, caused silent failure

**Solution:** Remove `--password` parameter

### 5. Error Suppression
**Problem:** `2>$null | Out-Null` hid all errors

**Solution:** Added `$LASTEXITCODE` checks after critical commands

---

## Two-Phase Deployment Design

### Phase 1 (`deploy-phase1.ps1`)
Creates all resources **without** Easy Auth:
- Okta OIDC application
- Bot App Registration (Entra ID)
- Azure Bot Service with Teams channel
- Bot OAuth connection to Okta (via REST API)
- Logic App Standard (no auth - allows portal access)
- Local configuration files

### Phase 2 (`deploy-phase2.ps1`)
After user creates Agent workflow in portal:
- Validates the Agent URL
- Enables Easy Auth with Okta on Logic App
- Updates `appsettings.local.json` with Agent URL

---

## How to Deploy Fresh

```powershell
cd c:\Users\karansin\la-poc-teams-debug\config

# Phase 1: Create resources (no Easy Auth)
.\deploy-phase1.ps1

# Go to Logic App portal, create Agent workflow with AI Foundry connection
# Copy the Agent URL from the trigger

# Phase 2: Enable Easy Auth
.\deploy-phase2.ps1 -AgentUrl "https://YOUR-LA.azurewebsites.net/api/Agents/YOUR-WORKFLOW"

# Start bot locally
cd ..
dotnet run

# Start dev tunnel
devtunnel host -p 5000 --allow-anonymous

# Update bot endpoint
az bot update --resource-group karansin --name YOUR-BOT --endpoint "https://YOUR-TUNNEL.devtunnels.ms/api/messages"
```

---

## Repository Information

- **Repo:** `karanbirsingh/la-poc-teams`
- **Branch:** `main`
- **Local Path:** `c:\Users\karansin\la-poc-teams-debug`
