# Nextcloud integration

## Authentication

Normalize an HTTPS server URL while retaining its installation subdirectory. Start Login Flow v2 with anonymous `POST <base>/index.php/login/v2`. Use the exact returned HTTPS `login` and `poll.endpoint` URLs after same-origin validation. The login page opens through url_launcher in the external browser.

Poll with form-urlencoded `token`. HTTP 404 means pending and is classified before body decoding; 200 is consumed once. Polling is cancellable, uses a two-second interval and expires after twenty minutes. Transient transport failures can retry; TLS failures and fatal HTTP responses remain errors. Poll tokens stay in memory. Credentials received once are checkpointed in secure storage before verification; process death before receipt requires a new authorization.

Verify Basic credentials through OCS `cloud/user`, then load `cloud/capabilities`. OCS calls include `OCS-APIRequest: true` and JSON headers/envelope validation. Manual app-password sign-in uses the same verification. Basic authentication cannot prove that a deliberately token-shaped ordinary password is an app password; browser approval is preferred.

Transport accepts received HTTP statuses for explicit classification, then parses JSON. An HTTP error is distinct from DNS, TLS or timeout failure. Same-origin read/Login Flow redirects are bounded; Login Flow POST preserves its method for 301/302/307/308, rejects 303, loops and cross-origin destinations. Recipe mutations are not replayed on redirects. Use the canonical server hostname for cross-host installations.

Diagnostics retain stage, method, sanitized endpoint, HTTP status, redirect/transport category and authored protocol reason. They exclude query strings, token paths, response bodies, exception text and credentials. No raw Dio logging is enabled.

## Cookbook API

Use the external `index.php/apps/cookbook/api/v1/` API relative to the installation root. Private `/webapp` routes must not be used, even if returned image metadata names one. Capabilities accept `cookbook.api-version` and `api_version`; legacy `api/version` discovery is a fallback. API epoch 0 / major 1 is supported; unknown epochs/majors are rejected. App versions are not API versions.

| Route | Use |
| --- | --- |
| `recipes`, `recipes/{id}` | List/create/read/update/delete canonical recipes |
| `recipes/{id}/image?size=thumb` or `full` | Authenticated images; unsupported formats use a placeholder |
| `import` | Server-side URL import |
| `search/{query}`, `categories`, `keywords`, `tags/{keywords}` | Search and taxonomy |
| `category/{category}` | Category filtering/rename |
| `config`, `reindex` | Explicit server configuration/index operations |

IDs are strings. Creates omit ID fields; updates force the intended ID in the body and verify the returned ID. Preserve unknown JSON, ordered ingredient arrays, structured instructions and server metadata. Categories are singular; keywords use canonical comma-separated values. Category `*` means uncategorized in counts, while `_` is the filtering sentinel. Offline search covers name/category/keywords; keyword selection supports AND/OR.

Nextcloud Files image selection uses OCS canonical UID then read-only WebDAV `PROPFIND Depth:1` beneath `remote.php/dav/files/{uid}/`. Accept only same-origin direct children, folders and JPEG/PNG files. Saving a selected path asks Cookbook to copy the image. No WebDAV writes or credential-bearing external downloads are performed.

Server folder/rename actions journal intent and reconcile uncertain outcomes by readback. Namespace changes invalidate recipe caches while retaining detached Cooking snapshots. Recipe Markdown does not execute HTML or fetch arbitrary embedded images.

Capabilities also supply safe theme colors. Validate hex values and foreground contrast; fall back to Nextcloud blue. Persist metadata separately from credentials so offline theme restoration works. A theme-fetch failure must not block cached recipes.

## Limits and references

The external API has no documented idempotency or atomic conditional-write contract. Preflight cannot eliminate concurrent-writer races. Server normalization may cause conservative conflicts; ambiguous creates/imports require review. Not every server configuration or app/API combination is certified by mocked tests.

- [Login Flow v2](https://docs.nextcloud.com/server/latest/developer_manual/client_apis/LoginFlow/index.html)
- [OCS APIs](https://docs.nextcloud.com/server/latest/developer_manual/client_apis/OCS/ocs-api-overview.html)
- [Cookbook external API](https://nextcloud.github.io/cookbook/dev/api/index)
- [Cookbook API changelog](https://nextcloud.github.io/cookbook/dev/api/changelog/0.html)

The implementation is independently written from protocol behavior; upstream implementation source is not included. See [third-party notices](../THIRD_PARTY_NOTICES.md).
