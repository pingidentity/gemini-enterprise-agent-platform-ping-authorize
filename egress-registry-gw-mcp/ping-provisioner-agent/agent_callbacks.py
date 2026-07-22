"""Module-level callbacks for ping-provisioner-agent.

Defined here (not in deploy_agent.py) so cloudpickle serialises them with
a stable module reference that is present in the Agent Runtime container.
"""
import os
import urllib.parse
import urllib.request

_TOKEN_PREFIX = "__AIC__:"

AIC_TOKEN_ENDPOINT = (
    "https://openam-tntp-aiagents.forgeblocks.com"
    "/am/oauth2/realms/root/realms/alpha/access_token"
)


def _exchange_token(ui_token: str) -> str:
    import json as _json, base64 as _b64
    client_id = os.environ.get("EXCHANGE_CLIENT_ID", "gcp_ping_provision_agent")
    client_secret = os.environ.get("EXCHANGE_CLIENT_SECRET", "")
    audience = os.environ.get("DELEGATED_TOKEN_AUDIENCE", client_id)
    scope = os.environ.get("DELEGATED_TOKEN_SCOPES", "fr:idm:* fr:idm:admin pingone:provisioning")

    if not client_secret:
        return ui_token

    actor_body = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_secret": client_secret,
    }).encode()
    actor_req = urllib.request.Request(
        AIC_TOKEN_ENDPOINT, data=actor_body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(actor_req, timeout=10) as r:
        actor_token = _json.loads(r.read())["access_token"]

    creds = _b64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    exchange_body = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token": ui_token,
        "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "actor_token": actor_token,
        "actor_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "audience": audience,
        "scope": scope,
    }).encode()
    exchange_req = urllib.request.Request(
        AIC_TOKEN_ENDPOINT, data=exchange_body,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Authorization": f"Basic {creds}",
        },
        method="POST",
    )
    with urllib.request.urlopen(exchange_req, timeout=10) as r:
        delegated = _json.loads(r.read()).get("access_token", "")

    if delegated:
        try:
            p = delegated.split(".")[1]; p += "=" * (4 - len(p) % 4)
            c = _json.loads(_b64.urlsafe_b64decode(p))
            print(f"DELEGATED_TOKEN sub={c.get('sub')} act={c.get('act')} scope={c.get('scope')} suffix=...{delegated[-8:]}", flush=True)
        except Exception:
            pass

    return delegated or ui_token


def before_model_callback(callback_context, llm_request):
    for content in reversed(llm_request.contents):
        if content.role != "user":
            continue
        for part in content.parts:
            if part.text and part.text.startswith(_TOKEN_PREFIX):
                rest = part.text[len(_TOKEN_PREFIX):]
                token, _, message = rest.partition(" ")
                if token:
                    callback_context.state["bearer_token"] = token
                    part.text = message
                return None
    return None


def header_provider(ctx) -> dict:
    import base64 as _b64, json as _j
    raw = ctx.state.get("bearer_token", "")
    if not raw:
        return {}
    try:
        p = raw.split(".")[1]; p += "=" * (4 - len(p) % 4)
        if _j.loads(_b64.urlsafe_b64decode(p)).get("act"):
            return {"Authorization": f"Bearer {raw}"}
    except Exception:
        pass
    delegated = _exchange_token(raw)
    return {"Authorization": f"Bearer {delegated}"}
