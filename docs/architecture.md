# Architecture

## Application and data boundaries

`lib/app` composes Riverpod providers, lifecycle coordination and go_router routes. `lib/core` contains HTTPS transport, authentication, external API services, theme and SQLite infrastructure. `lib/features` separates domain models, repositories and presentation for recipes, editing, synchronization, account settings and Cooking.

SQLite is the offline source for recipe views and local work. Credentials live only in flutter_secure_storage. Nonsecret account/theme metadata is separate. Account-owned tables use cascading foreign keys; removal coordinates synchronization and notification cancellation before local cleanup. A removal tombstone permits recovery after interruption.

Recipe JSON remains canonical. Models deep-copy it; drafts patch edited properties without discarding unknown fields. Instruction editing follows nested paths and preserves unsupported nodes. Library/filter projections are rebuildable, never replacement server objects. Editor snapshots remain stable across background refresh, and stale saves are rejected.

## Startup and synchronization

Bootstrap waits for local account/database/preferences and credential presence, not HTTP. Cached recipes remain accessible when credentials are missing or rejected; reauthentication must match the same server/login identity. Network failures do not log the user out.

One lifecycle coordinator schedules background synchronization after local content is available. Launch/resume refreshes are throttled against the last attempt (five minutes); explicit refreshes remain immediate. Concurrent requests join a running job, with one follow-up for new local work. Local library reads do not wait on the network mutation mutex.

A save and its queue entry commit in one transaction. Operations progress through queued, sending, unknownOutcome, conflict, applied or failed. Sending is persisted before HTTP; interruption converts it to unknownOutcome. A database-scoped mutex serializes dispatch and conflict decisions. An unresolved mutation blocks later work for that recipe, not unrelated recipes. Creation confirmation atomically maps local IDs, aliases, queued work and session references to the server ID.

Before update/delete, fetch and compare full normalized JSON with the saved base. Array order and unknown fields matter; server-managed root ID/date/image fields are excluded. Differences preserve Base/Local/Server snapshots for explicit review. Keep Local is checked again before upload. There is no atomic conditional-write API, so an edit between preflight and mutation remains a race.

Never blindly replay an uncertain mutation. Updates/deletes reconcile by readback; creates require preflight IDs and a unique full-content match. Lost imports require manual association. Ambiguous results remain unresolved. Membership deletion needs repeated successful absence plus a detail 404; malformed lists and failed requests never mean an empty library. Dirty data remains protected.

## Database evolution

Schema v6 builds on ordered migrations. Fresh creation runs the same migration path as upgrades. Changes require a version increment, transactional migration and preservation tests for every supported upgrade. Do not edit released migrations or delete data on downgrade. Projections invalidate only for content/membership changes, preserving unchanged images and views. Queue audit rows are not automatically pruned.

## Images and local presentation

Images use authenticated external Cookbook endpoints, not arbitrary recipe website URLs. JPEG/PNG validation checks encoded metadata; bounded decode targets preserve aspect ratio and never reach zero. HTTP fetches and decoded frames have separate concurrency bounds. Thumbnail, detail and zoom edges are 250/1024/2048 pixels. Image-only SQLite LRU defaults to 200 MiB; clearing it never removes recipe or queued data. Failures use placeholders and bounded retries.

Cooking stores independent snapshot/progress/timer records. Detail ingredient checks use account_metadata and never enter Cooking or upload JSON. Timer state commits before OS scheduling; completion timestamps survive restart and foreground ticks update only timer widgets. Screen-awake state belongs to the Cooking route and is released on background/exit. See [Cooking Mode](cooking-mode.md).

Dio transport scopes Basic authentication to normalized HTTPS origins, bounds redirects/timeouts and excludes raw request/response logs. Sanitized diagnostics preserve the authentication stage and received HTTP status. See [Nextcloud integration](nextcloud-integration.md) and [compatibility](compatibility.md).
