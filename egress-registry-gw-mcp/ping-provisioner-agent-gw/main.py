import os
import time
import jwt
import httpx

TOKEN_EXCHANGE_GRANT = "urn:ietf:params:oauth:grant-type:token-exchange"
TOKEN_TYPE_ACCESS = "urn:ietf:params:oauth:token-type:access_token"
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import vertexai
from vertexai import agent_engines

PROJECT = os.environ.get("GCP_PROJECT", "tech-partner-ping")
REGION = os.environ.get("GCP_REGION", "us-central1")
AGENT_RESOURCE = os.environ.get("AGENT_RESOURCE_NAME")
CORS_ORIGIN = os.environ.get("CORS_ORIGIN", "*")
AIC_ISSUER = os.environ.get("AIC_ISSUER")
# gcp_ping_provision_agent — confidential client that authenticates the token exchange
EXCHANGE_CLIENT_ID = os.environ.get("EXCHANGE_CLIENT_ID", "gcp_ping_provision_agent")
EXCHANGE_CLIENT_SECRET = os.environ.get("EXCHANGE_CLIENT_SECRET", "")
# Audience for the delegated token — the Agent Gateway URL that PingAuthorize checks
DELEGATED_TOKEN_AUDIENCE = os.environ.get("DELEGATED_TOKEN_AUDIENCE", EXCHANGE_CLIENT_ID)
DELEGATED_TOKEN_SCOPES = os.environ.get("DELEGATED_TOKEN_SCOPES", "fr:idm:* fr:idm:admin pingone:provisioning")

vertexai.init(project=PROJECT, location=REGION)

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=[CORS_ORIGIN],
    allow_methods=["*"],
    allow_headers=["*"],
)


class ChatRequest(BaseModel):
    message: str


async def validate_token(request: Request) -> str:
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Bearer token required")
    token = auth[len("Bearer "):]

    if not AIC_ISSUER:
        return "provisioner-ui"

    try:
        jwks_uri = f"{AIC_ISSUER}/connect/jwk_uri"
        signing_key = jwt.PyJWKClient(jwks_uri).get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=EXCHANGE_CLIENT_ID,
            options={"verify_iss": False},
        )
        if claims.get("exp", 0) < time.time():
            raise HTTPException(status_code=401, detail="Token expired")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=401, detail=f"Token invalid: {e}")

    return claims.get("sub", "provisioner-ui")


@app.get("/health")
def health():
    return {"status": "ok"}


async def _get_actor_token(client: httpx.AsyncClient) -> str:
    """Client_credentials token for gcp_ping_provision_agent — used as actor_token in RFC 8693 delegation."""
    resp = await client.post(
        f"{AIC_ISSUER}/access_token",
        data={"grant_type": "client_credentials"},
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        auth=(EXCHANGE_CLIENT_ID, EXCHANGE_CLIENT_SECRET),
    )
    if resp.status_code != 200:
        raise HTTPException(status_code=401, detail=f"Actor token fetch failed: {resp.text}")
    token = resp.json().get("access_token")
    if not token:
        raise HTTPException(status_code=401, detail="Actor token response missing access_token")
    return token


async def exchange_token(ui_token: str) -> str:
    """RFC 8693 delegation exchange: UI token → delegated token.

    The resulting token has sub=user, act.sub=gcp_ping_provision_agent, and
    audience=DELEGATED_TOKEN_AUDIENCE (the Agent Gateway URL that PingAuthorize checks).
    """
    if not AIC_ISSUER or not EXCHANGE_CLIENT_SECRET:
        return ui_token
    async with httpx.AsyncClient() as client:
        actor_token = await _get_actor_token(client)
        resp = await client.post(
            f"{AIC_ISSUER}/access_token",
            data={
                "grant_type": TOKEN_EXCHANGE_GRANT,
                "subject_token": ui_token,
                "subject_token_type": TOKEN_TYPE_ACCESS,
                "actor_token": actor_token,
                "actor_token_type": TOKEN_TYPE_ACCESS,
                "requested_token_type": TOKEN_TYPE_ACCESS,
                "audience": DELEGATED_TOKEN_AUDIENCE,
                "scope": DELEGATED_TOKEN_SCOPES,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            auth=(EXCHANGE_CLIENT_ID, EXCHANGE_CLIENT_SECRET),
        )
    if resp.status_code != 200:
        raise HTTPException(status_code=401, detail=f"Token exchange failed: {resp.text}")
    data = resp.json()
    token = data.get("access_token")
    if not token:
        raise HTTPException(status_code=401, detail="Token exchange returned no access_token")
    return token


@app.post("/chat")
async def chat(req: ChatRequest, request: Request):
    user_id = await validate_token(request)
    ui_token = request.headers.get("Authorization", "")[len("Bearer "):]
    delegated_token = await exchange_token(ui_token)

    engine = agent_engines.get(AGENT_RESOURCE)

    # Create session with the delegated token in state, then stream using that session.
    # state must be set at session creation time — async_stream_query does not accept it directly.
    session = await engine.async_create_session(
        user_id=user_id,
        state={"bearer_token": delegated_token},
    )
    session_id = session.get("id") or session.get("session_id") or session.get("name", "").split("/")[-1]

    final_text = ""
    async for event in engine.async_stream_query(
        user_id=user_id,
        session_id=session_id,
        message=req.message,
    ):
        print(f"EVENT: {event}", flush=True)
        if event.get("content") and event["content"].get("parts"):
            for part in event["content"]["parts"]:
                if part.get("text") and not part.get("thought_signature"):
                    final_text = part["text"]
    return {"response": final_text or "(no response)"}
