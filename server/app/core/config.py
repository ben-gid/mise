from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # On Cloud Run this comes from Secret Manager; locally from server/.env.
    # Unsplash's access key, sent as Client-ID. Empty is allowed: photo search
    # is the one feature that can be missing without the app noticing (/photos
    # is a 503, which it reads as "no photos", and Wikipedia carries on).
    UNSPLASH_ACCESS_KEY: SecretStr = SecretStr("")
    # Empty is allowed for the same reason: /recipe is a 503 without it, which
    # the app reads as "server recipes aren't available", and pasting still works.
    ANTHROPIC_API_KEY: SecretStr = SecretStr("")
    # RevenueCat's v1 secret key (sk_…), for asking whether a user is Pro.
    # Empty is allowed: nobody becomes Pro, and the free tries work as before.
    REVENUECAT_SECRET_KEY: SecretStr = SecretStr("")
    # The project, for its public keys (JWKS) and its admin API.
    SUPABASE_URL: str
    # Deletes users. Server-only: it bypasses every RLS policy.
    SUPABASE_SECRET_KEY: SecretStr

    model_config = SettingsConfigDict(env_file=".env")


# At import time, so a missing key fails the deploy rather than every request.
settings = Settings()
