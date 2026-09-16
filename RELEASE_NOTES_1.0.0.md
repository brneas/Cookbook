# Cookbook 1.0.0

Cookbook brings your Nextcloud Cookbook recipes to Android with a native interface and offline access.

Browse in List or Grid, search your collection, and filter by categories and keywords. Create and edit recipes, import a recipe URL, and choose images from Nextcloud Files. Local changes synchronize directly with your server, with review tools for conflicts and uncertain uploads.

Cooking Mode keeps ingredients and instructions close at hand. Choose the full Recipe view or step-focused Focus view, adjust supported serving quantities, track progress and run persistent timers with optional notifications. The interface follows your Nextcloud instance's colors and supports light and dark appearance.

## Requirements

Android **7.0 (API 24)** or later, plus an HTTPS Nextcloud server with Nextcloud Cookbook enabled for your account. Sign in securely in your browser or use a dedicated app password.

Install the universal `cookbook-1.0.0.apk`; verify it against the published `SHA256SUMS.txt`. Existing development installations may use a different signing certificate or higher split version code. Preserve unsynchronized work before changing installations; Android cannot upgrade across different signing identities.

## Known limitations

Offline reading requires downloaded recipes; images must be cached. URL imports need the server to complete. Concurrent edits by multiple clients retain a race because the server API lacks atomic conditional writes. Some uncertain uploads/imports require review. Quantity scaling is conservative rather than a general unit converter. Android permissions and power management can delay timer alerts.

Cookbook is an unofficial client, not affiliated with or endorsed by Nextcloud GmbH or the upstream Cookbook maintainers.
