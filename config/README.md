# Deployment Scripts

Three-phase deployment for Teams Bot + Okta OAuth + Logic Apps.

## Prerequisites

1. **Azure CLI** logged in: `az login`
2. **Okta Admin access** with an API token
3. **Azure Resource Group** already created
4. **.NET 8 SDK** installed (for Phase 3)

## Configuration

Edit `deployment-config.json`:

```json
{
  "okta": {
    "domain": "your-org.okta.com",
    "apiToken": "your-api-token"
  },
  "azure": {
    "resourceGroup": "your-rg",
    "location": "eastus"
  },
  "resources": {
    "prefix": ""  // Leave empty for auto-generated, or set a custom prefix
  }
}
```

## Phase 1: Create Resources

```powershell
.\deploy-phase1.ps1
```

This creates:
- ✅ Azure Bot Service with Okta OAuth connection
- ✅ Logic App Standard (WITHOUT Easy Auth)
- ✅ Okta OIDC application
- ✅ Local `appsettings.local.json`

**Easy Auth is NOT enabled** so you can access the Logic App designer.

## Manual Step: Create Your Workflow

1. Open the Logic App in Azure Portal (link shown after Phase 1)
2. Create a new **Agent** workflow
3. Add the trigger: "When a new chat session starts"
4. Configure your **AI Foundry / Azure OpenAI connection**
5. Add your tools and actions
6. **Save** the workflow
7. Click on the trigger and **copy the Agent URL**

The Agent URL looks like:
```
https://your-la.azurewebsites.net/api/Agents/YourWorkflowName
```

## Phase 2: Enable Easy Auth

```powershell
.\deploy-phase2.ps1 -AgentUrl "https://your-la.azurewebsites.net/api/Agents/YourWorkflowName"
```

This:
- ✅ Enables Easy Auth with Okta on the Logic App
- ✅ Updates `appsettings.local.json` with the Agent URL
- ✅ Finalizes the Logic App configuration

## Phase 3: Deploy to Azure & Create Teams App

```powershell
.\deploy-phase3.ps1
```

This:
- ✅ Creates Azure App Service for the bot
- ✅ Configures all app settings
- ✅ Builds and deploys the .NET bot
- ✅ Updates bot endpoint to App Service URL
- ✅ Creates `teams-app.zip` for Teams sideloading

Options:
```powershell
# Skip Teams package creation
.\deploy-phase3.ps1 -SkipTeamsPackage

# Force run even if Phase 2 not complete
.\deploy-phase3.ps1 -Force
```

## Testing Locally (Before Phase 3)

1. Start the bot: `dotnet run` (from project root)
2. Start dev tunnel: `devtunnel host -p 5000 --allow-anonymous`
3. Update bot endpoint in Azure Portal to your tunnel URL + `/api/messages`
4. Test in Web Chat

## Testing in Teams (After Phase 3)

1. Open Microsoft Teams
2. Go to: **Apps** → **Manage your apps** → **Upload an app**
3. Select **Upload a custom app** and choose `teams-app.zip`
4. Click **Add** to install the bot
5. Start chatting!

## Cleanup

```powershell
.\cleanup.ps1
```

This removes all Azure resources and the Okta application.

## Files

| File | Description |
|------|-------------|
| `deployment-config.json` | Your input configuration |
| `deployment-output.json` | Generated credentials and URLs (keep secure!) |
| `deploy-phase1.ps1` | Creates resources without Easy Auth |
| `deploy-phase2.ps1` | Enables Easy Auth after workflow is ready |
| `deploy-phase3.ps1` | Deploys bot to Azure App Service + Teams package |
| `cleanup.ps1` | Removes all created resources |

## Troubleshooting

### 401 Unauthorized from Logic App
- Okta authorization server audience must match the client ID
- Phase 1 automatically sets this, but check Okta Admin > Security > API > Authorization Servers > default > Audience

### Can't edit workflow in portal
- Easy Auth may be enabled. Temporarily disable it:
  ```powershell
  az webapp auth update --resource-group YOUR_RG --name YOUR_LA --enabled false
  ```

### Timestamp parsing errors
- The `A2ATimestampRewriteHandler` handles timestamp format conversion

### OAuth connection "generic provider not found"
- The CLI has issues with Generic OAuth 2; Phase 1 uses REST API instead
- Logic Apps returns `M/d/yyyy h:mm:ss tt +00:00` but A2A library expects ISO 8601
