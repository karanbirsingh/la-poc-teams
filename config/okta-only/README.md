# Okta-Only Demo

Minimal setup to test **Okta OAuth in isolation** - no Logic Apps required.

## What This Does

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│   Teams     │────▶│  Azure Bot   │────▶│    Okta     │
│   User      │◀────│  + OAuth     │◀────│  (User SSO) │
└─────────────┘     └──────────────┘     └─────────────┘
```

When you message the bot:
1. Bot prompts you to sign in with Okta
2. You authenticate with your Okta credentials
3. Bot receives an Okta access token
4. Bot calls Okta `/userinfo` endpoint and returns your profile

**The same token** can later be passed to Logic Apps (see full demo).

## Prerequisites

1. **Azure CLI** logged in: `az login`
2. **Okta Admin access** with an API token
3. **Azure Resource Group** already created
4. **.NET 8 SDK** installed

## Quick Start

```powershell
# 1. Configure
notepad deployment-config.json

# 2. Create resources (Bot + Okta app)
.\deploy-phase1.ps1

# 3. Deploy to Azure & create Teams package
.\deploy-phase2.ps1
```

## Configuration

Edit `deployment-config.json`:

```json
{
  "okta": {
    "domain": "your-org.okta.com",
    "apiToken": "your-okta-api-token"
  },
  "azure": {
    "resourceGroup": "your-existing-rg"
  }
}
```

## Bot Commands

| Command | Description |
|---------|-------------|
| `-me` | Show your full Okta profile (name, email, sub) |
| `-signout` | Sign out and clear the OAuth token |
| *any message* | Echo back with your Okta name |

## Testing Locally

After Phase 1:

```powershell
# Terminal 1: Run the bot
cd ..\..\
dotnet run

# Terminal 2: Start dev tunnel
devtunnel host -p 3978 --allow-anonymous
```

Then update the bot endpoint in Azure Portal to your tunnel URL + `/api/messages`.

## Files

| File | Description |
|------|-------------|
| `deployment-config.json` | Your input config (**edit this**) |
| `deployment-output.json` | Generated secrets (**auto-generated, keep secure**) |
| `deploy-phase1.ps1` | Creates Bot + Okta resources |
| `deploy-phase2.ps1` | Deploys to Azure + Teams package |

## Adding Logic Apps Later

This demo proves Okta OAuth works. To add Logic Apps:

1. Switch to the `deploy-scripts-reference` branch
2. Use those 3-phase scripts which add:
   - Logic App Standard
   - Easy Auth with Okta
   - Agent workflow integration
