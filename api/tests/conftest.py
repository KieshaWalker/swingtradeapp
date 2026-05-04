from __future__ import annotations

import os

# Set required env vars before any app module is imported, so pydantic-settings
# doesn't blow up looking for real credentials during test collection.
os.environ.setdefault("SUPABASE_URL", "https://test.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_KEY", "test-service-key")
