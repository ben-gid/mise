from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # On Cloud Run this comes from Secret Manager; locally from server/.env.
    PEXELS_KEY: SecretStr

    model_config = SettingsConfigDict(env_file=".env")


# At import time, so a missing key fails the deploy rather than every request.
settings = Settings()
