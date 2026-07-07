---
name: BeEF AR migration versioning
description: Rules for adding ActiveRecord migrations to the BeEF codebase without version collisions.
---

BeEF's migrations live in `core/main/ar-migrations/` and are run automatically at startup via `otr-activerecord`.
The version is the numeric prefix of the filename (e.g. `026_create_hook_pages.rb` → version 26).

**Rule:** Always scan `core/main/ar-migrations/` for the highest existing number before adding a new migration, and number yours one higher.

**Why:** Duplicate version numbers (`017_create_hook_pages.rb` alongside `017_create_rtc_manage.rb`) cause AR to silently skip one migration, leaving the table missing and producing confusing "Invalid slug or duplicate" errors at runtime.

**How to apply:** `ls core/main/ar-migrations/ | sort | tail -3` — pick the next integer. Add the `created_at` column as `datetime NOT NULL` (BeEF convention) and a unique index on natural keys.

The class name inside the file must match the Rails convention (`CreateHookPages < ActiveRecord::Migration[6.0]`).
