---
"nehir": patch

---

Removed bundled per-app minimum-size rules; window resize floors are now inferred at runtime when an app refuses a size write, so existing and new apps are handled accurately without hardcoded defaults
