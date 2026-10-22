import os

# Before anything imports app.core.config, which refuses to start without one.
os.environ.setdefault("PEXELS_KEY", "test-key")
