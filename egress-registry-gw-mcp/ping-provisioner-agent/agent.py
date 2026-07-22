"""ADK provisioner agent with direct MCP server connections.

The agent calls the PingOne AIC MCP server directly via its Cloud Run URL.
The Agent Gateway (ping-authz-agent-gateway) and authz policy (ping-authz-shim)
are registered in GCP Agent Registry and handle policy enforcement.

Invoke:
    POST https://ping-provisioner-agent-uu2pkgxfka-uc.a.run.app/provision
    {"instruction": "Provision alice@example.com in PingOne AIC"}
"""
import asyncio
import logging

from google.adk.agents import LlmAgent
from google.adk.tools.mcp_tool.mcp_toolset import MCPToolset, StreamableHTTPConnectionParams

from config import settings

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """\
You are an identity provisioning agent. You have tools to manage user accounts
in PingOne AIC (ForgeRock Identity Cloud) — tools prefixed with pingone_.

Available tools:
  pingone_provision_user       — create a new user account
  pingone_deprovision_user     — permanently delete a user
  pingone_update_user_status   — enable or disable an account
  pingone_list_users           — search or list accounts

When you receive an instruction:
1. Call the appropriate tool with the correct arguments.
2. Report the result clearly, including any IDs or errors returned.

If a request is rejected, report the reason without retrying.
"""


def _get_oidc_token(audience: str) -> str:
    """Fetch a Google-signed OIDC identity token for the given audience."""
    import google.auth.transport.requests  # noqa: PLC0415
    import google.oauth2.id_token  # noqa: PLC0415

    request = google.auth.transport.requests.Request()
    return google.oauth2.id_token.fetch_id_token(request, audience)


async def _auth_headers(url: str) -> dict[str, str]:
    """Return an Authorization header for the given URL, best-effort."""
    try:
        from urllib.parse import urlparse  # noqa: PLC0415
        parsed = urlparse(url)
        audience = f"{parsed.scheme}://{parsed.netloc}"
        token = await asyncio.to_thread(_get_oidc_token, audience)
        return {"Authorization": f"Bearer {token}"}
    except Exception as exc:
        logger.warning("Could not fetch OIDC token for %s: %s", url, exc)
        return {}


async def create_agent() -> LlmAgent:
    """Build an LlmAgent with an MCPToolset pointing at the PingOne AIC MCP server."""
    pingone_url = settings.pingone_aic_mcp_url

    logger.info("Creating agent: pingone=%s", pingone_url)

    pingone_headers = await _auth_headers(pingone_url)

    pingone_tools = MCPToolset(
        connection_params=StreamableHTTPConnectionParams(
            url=pingone_url,
            headers=pingone_headers,
        ),
        tool_name_prefix="pingone_",
    )

    return LlmAgent(
        name="ping_provisioner",
        model=settings.gemini_model,
        instruction=SYSTEM_PROMPT,
        tools=[pingone_tools],
    )
