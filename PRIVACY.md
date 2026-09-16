# Privacy

Cookbook connects directly to the Nextcloud server you configure. The project operates no intermediary backend. The application contains no advertising, analytics or tracking SDK, and does not sell or send your data to the project maintainer.

Sign-in uses Nextcloud Login Flow v2 in your external browser. Cookbook receives a dedicated app password after approval; the manual alternative also requires an app password. Credentials are stored through Android secure storage, separately from the local SQLite recipe database. Android application backup and cleartext HTTP are disabled. Device compromise can still expose data; this is not a guarantee against a compromised operating system.

Downloaded recipes, queued edits, conflicts, images, preferences, preparation checks, Cooking sessions and timers are stored locally. Removing the account deletes account-owned local data and attempts to revoke its app password. If the server is unavailable, revoke that password in Nextcloud's Security settings. Uninstalling removes app-managed local storage; revocation on the server remains a separate action.

Recipe synchronization and image requests go to your server. URL import asks the server to fetch the chosen page. Links you explicitly open may launch the browser and contact that website. Your server, browser and linked services have their own policies. Notifications can display recipe/timer labels on the lock screen according to Android settings.

Diagnostics show sanitized connection information and may include the configured hostname and login name in account settings. Development timing logs omit recipe content and credentials. No diagnostic upload is automatic. Inspect and redact screenshots or reports before sharing them.
