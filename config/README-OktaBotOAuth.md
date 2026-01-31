# Okta OAuth Configuration for Teams Bot with Azure Bot Service

This document describes how to configure Okta as an OAuth identity provider for a Teams bot using Azure Bot Service.

## Architecture Overview

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐     ┌─────────────┐
│   Teams     │────▶│  Azure Bot       │────▶│   Bot Backend   │────▶│  Logic Apps │
│   User      │     │  Service         │     │   (ASP.NET)     │     │  (Optional) │
└─────────────┘     └──────────────────┘     └─────────────────┘     └─────────────┘
                           │                        │                       │
                           ▼                        ▼                       ▼
                    ┌─────────────┐          Gets Okta token         Validates Okta
                    │   Okta      │          via AutoSignIn          token via
                    │   (IDP)     │                                  Easy Auth
                    └─────────────┘
```

## Prerequisites

- Azure subscription
- Okta developer account (free at https://developer.okta.com)
- Azure CLI installed
- VS Code with REST Client extension (for .http files)

## Step 1: Create Okta OIDC Application

### 1.1 Sign in to Okta Admin Portal
Navigate to your Okta admin portal (e.g., `https://your-domain.okta.com/admin`)

### 1.2 Create New App Integration
1. Go to **Applications** > **Applications**
2. Click **Create App Integration**
3. Select:
   - **Sign-in method**: OIDC - OpenID Connect
   - **Application type**: Web Application
4. Click **Next**

### 1.3 Configure Application Settings
- **App integration name**: `Teams Bot Okta OAuth` (or your preferred name)
- **Grant type**: 
  - ✅ Authorization Code
  - ✅ Refresh Token
- **Sign-in redirect URIs**: 
  ```
  https://token.botframework.com/.auth/web/redirect
  ```
- **Sign-out redirect URIs**: (leave empty or add your app's logout URL)
- **Controlled access**: Choose appropriate assignment

### 1.4 Save Credentials
After saving, note down:
- **Client ID**: e.g., `0oazoxkr5qr5bSJFs697`
- **Client Secret**: (click "Copy" to get the secret)

### 1.5 Identify OAuth Endpoints
Go to **Security** > **API** > **Authorization Servers** > **default**

Note the endpoints (using the "default" authorization server):
- **Authorization URL**: `https://{okta-domain}/oauth2/default/v1/authorize`
- **Token URL**: `https://{okta-domain}/oauth2/default/v1/token`
- **UserInfo URL**: `https://{okta-domain}/oauth2/default/v1/userinfo`

## Step 2: Create Azure Bot Service

### 2.1 Create Bot via Azure Portal
1. Go to Azure Portal > Create a resource > Azure Bot
2. Configure:
   - **Bot handle**: `teams-okta-oauth-bot`
   - **Subscription**: Your subscription
   - **Resource group**: Your resource group
   - **Pricing tier**: F0 (free) or S1
   - **Type of App**: Single Tenant
   - **Creation type**: Create new Microsoft App ID

### 2.2 Note Bot Credentials
After creation, go to **Configuration** and note:
- **Microsoft App ID**: e.g., `387dc956-c1c1-4a04-92ae-bb8d8dbfe203`
- **Microsoft App Tenant ID**: e.g., `31fc0ca3-d72a-456e-bd13-e20aeb14a3af`

Create a client secret in the linked App Registration and note it.

### 2.3 Enable Teams Channel
1. Go to **Channels**
2. Click **Microsoft Teams**
3. Accept terms and save

## Step 3: Configure OAuth Connection (Generic OAuth 2)

### 3.1 Via Azure Portal (Manual)
1. Go to your Bot Service > **Configuration** > **OAuth Connection Settings**
2. Click **Add setting**
3. Configure:
   - **Name**: `okta`
   - **Service Provider**: `Oauth 2 Generic Provider`
   - **Client ID**: Your Okta Client ID
   - **Client Secret**: Your Okta Client Secret
   - **Authorization URL**: `https://{okta-domain}/oauth2/default/v1/authorize`
   - **Token URL**: `https://{okta-domain}/oauth2/default/v1/token`
   - **Refresh URL**: `https://{okta-domain}/oauth2/default/v1/token`
   - **Scopes**: `openid profile email`
4. Save

### 3.2 Via REST API (Scripted)
Use the `bot-oauth-connection.http` file with VS Code REST Client:
1. Get an access token: `az account get-access-token --query accessToken -o tsv`
2. Update the variables in the .http file
3. Send the PUT request

### 3.3 Test the Connection
1. In Azure Portal, go to the OAuth connection
2. Click **Test Connection**
3. You should be redirected to Okta to sign in
4. After successful sign-in, you'll see a token

## Step 4: Configure Bot Backend (appsettings.json)

```json
{
  "TokenValidation": {
    "Enabled": true,
    "Audiences": ["YOUR_BOT_APP_ID"],
    "TenantId": "YOUR_BOT_TENANT_ID"
  },
  "AgentApplication": {
    "UserAuthorization": {
      "DefaultHandlerName": "auto",
      "AutoSignin": true,
      "Handlers": {
        "auto": {
          "Settings": {
            "AzureBotOAuthConnectionName": "okta",
            "Title": "Sign in",
            "Text": "Please sign in to continue."
          }
        }
      }
    }
  },
  "Connections": {
    "ServiceConnection": {
      "Settings": {
        "AuthType": "ClientSecret",
        "ClientId": "YOUR_BOT_APP_ID",
        "TenantId": "YOUR_BOT_TENANT_ID",
        "ClientSecret": "YOUR_BOT_SECRET",
        "Scopes": ["https://api.botframework.com/.default"]
      }
    }
  },
  "ConnectionsMap": [
    {
      "ServiceUrl": "*",
      "Connection": "ServiceConnection"
    }
  ]
}
```

## Step 5: Run and Test

### 5.1 Start Dev Tunnel
```bash
devtunnel host -p 3978 --allow-anonymous
```

### 5.2 Update Bot Endpoint
In Azure Portal > Bot Service > Configuration:
- Set **Messaging endpoint** to: `https://{tunnel-url}/api/messages`

### 5.3 Test in Web Chat
1. Go to Azure Portal > Bot Service > **Test in Web Chat**
2. Send a message
3. You should see a sign-in card
4. Complete Okta sign-in
5. Bot should respond with your name from Okta

### 5.4 Test in Teams
1. Upload the Teams app manifest (see `appManifest/` folder)
2. Chat with the bot in Teams
3. Complete sign-in flow

## Troubleshooting

### "Unknown User" Response
- The userinfo endpoint URL might be wrong
- Ensure you're using the correct authorization server (`/oauth2/default/v1/userinfo` vs `/oauth2/v1/userinfo`)
- Check that scopes include `openid`, `profile`, `email`

### OAuth Connection Test Fails
- Verify Client ID and Secret are correct
- Check that redirect URI `https://token.botframework.com/.auth/web/redirect` is configured in Okta
- Ensure the Okta app is active and user is assigned

### Token Not Available in Bot
- Check that `AzureBotOAuthConnectionName` in appsettings matches the connection name exactly
- Ensure `AutoSignin` is set to `true`
- Verify the OAuth connection is properly saved (sometimes Azure Portal doesn't save all fields)

## Configuration Files

| File | Description |
|------|-------------|
| `okta-app-config.json` | Okta OIDC application settings |
| `azure-bot-config.json` | Azure Bot Service configuration |
| `bot-oauth-connection.http` | REST API calls for Bot OAuth setup |
| `deploy-bot-oauth.ps1` | PowerShell script to deploy Bot OAuth connection |
| `deploy-logicapp-okta.ps1` | **PowerShell script to deploy Logic App with Okta Easy Auth** |
| `logicapp-easyauth-okta.http` | REST API calls for Logic App Easy Auth |
| `sample-agent-workflow.json` | Sample A2A agent workflow definition |

## Deployment Scripts

### Deploy Bot OAuth Connection
```powershell
.\config\deploy-bot-oauth.ps1
```

### Deploy Logic App with Okta Easy Auth
```powershell
.\config\deploy-logicapp-okta.ps1 `
    -ResourceGroupName "karansin" `
    -LogicAppName "okta-easyauth-logicapp" `
    -OktaDomain "integrator-7620286.okta.com" `
    -OktaClientId "0oazoxkr5qr5bSJFs697" `
    -OktaClientSecret "your-okta-secret"
```

This creates:
1. Storage Account (required for Logic App Standard)
2. App Service Plan (Workflow Standard WS1)
3. Logic App Standard
4. Okta Easy Auth configuration (custom OIDC provider)

## Key Service Provider IDs

| Provider | Service Provider ID |
|----------|---------------------|
| Generic OAuth 2 | `8379c6d2-b262-4d4f-b89b-68dc5b5f5482` |
| Azure AD v2 | `30dd229c-58e3-4a48-bdfd-91ec48eb906c` |
| GitHub | `d05eaacf-1593-4603-9c6c-d4d8fffa46cb` |

## End-to-End Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Teams     │────▶│  Azure Bot       │────▶│   Bot Backend   │────▶│   Logic App     │
│   User      │     │  Service         │     │   (ASP.NET)     │     │   (Standard)    │
└─────────────┘     └──────────────────┘     └─────────────────┘     └─────────────────┘
                           │                        │                       │
                           ▼                        │                       ▼
                    ┌─────────────┐                 │                ┌─────────────┐
                    │   Okta      │◀────────────────┘                │  Easy Auth  │
                    │   (IDP)     │                                  │  (Okta)     │
                    └─────────────┘                                  └─────────────┘
                           │                                               │
                           └───────────────────────────────────────────────┘
                                        Same Okta App!
```

**Flow:**
1. User chats in Teams
2. Bot Service triggers OAuth (Generic OAuth 2 Provider → Okta)
3. User authenticates with Okta
4. Bot Backend receives Okta access token
5. Bot Backend calls Logic App with token in `x-ms-obo-usertoken` header
6. Logic App Easy Auth validates token against Okta JWKS
7. Workflow runs with authenticated user context

## References

- [Azure Bot OAuth Configuration](https://learn.microsoft.com/en-us/azure/bot-service/bot-builder-authentication)
- [Okta OIDC Documentation](https://developer.okta.com/docs/reference/api/oidc/)
- [Microsoft Agents SDK](https://github.com/microsoft/Agents)
- [Teams Bot Authentication](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/how-to/authentication/auth-aad-sso-bots)
- [Logic Apps Easy Auth](https://learn.microsoft.com/en-us/azure/app-service/configure-authentication-provider-openid-connect)
