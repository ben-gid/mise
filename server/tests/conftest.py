import os

# Before anything imports app.core.config, which refuses to start without one.
os.environ.setdefault("UNSPLASH_ACCESS_KEY", "test-key")
os.environ.setdefault("SUPABASE_URL", "https://test.supabase.co")
os.environ.setdefault("SUPABASE_SECRET_KEY", "sb_secret_test")
os.environ.setdefault("ANTHROPIC_API_KEY", "sk-ant-test")
