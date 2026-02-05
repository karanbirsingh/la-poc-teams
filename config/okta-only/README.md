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

# 2. Create resources (Bot + Okta app + Teams package)
.\deploy-phase1.ps1

# 3. Test locally (see below) OR deploy to Azure
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

## Testing Locally with Teams

After running `deploy-phase1.ps1`:

```powershell
# Terminal 1: Run the bot
cd ..\..
dotnet run

# Terminal 2: Start dev tunnel
devtunnel host -p 3978 --allow-anonymous
```

Then:

1. **Update bot endpoint** (replace `<tunnel>` with your devtunnel subdomain):
   ```powershell
   az bot update -g <resource-group> -n <bot-name> --endpoint "https://<tunnel>.devtunnels.ms/api/messages"
   ```

2. **Sideload the Teams app**:
   - Teams → Apps → Manage your apps → Upload a custom app
   - Select `teams-app.zip` from the project root

3. **Test**: Message the bot with `-me` to see your Okta profile

## Testing with Web Chat (No Teams)

You can also test directly in Azure Portal without Teams:
1. Go to Azure Portal → Your Bot → Test in Web Chat
2. Send `-me` to test OAuth

## Files

| File | Description |
|------|-------------|
| `deployment-config.json` | Your input config (**edit this**) |
| `deployment-output.json` | Generated secrets (**auto-generated, keep secure**) |
| `deploy-phase1.ps1` | Creates Bot + Okta + Teams package |
| `deploy-phase2.ps1` | Deploys to Azure App Service |

## Adding Logic Apps Later

This demo proves Okta OAuth works. To add Logic Apps:

1. Switch to the `deploy-scripts-reference` branch
2. Use those 3-phase scripts which add:
   - Logic App Standard
   - Easy Auth with Okta
   - Agent workflow integration
