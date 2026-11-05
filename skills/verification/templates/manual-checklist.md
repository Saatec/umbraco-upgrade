# Manual verification checklist

Upgrade: Umbraco {{source}} to {{target}}, upgrade branch `{{branch}}`. Generated {{date}} by umbraco-upgrade.

These checks need a person: the plugin cannot see a running site, a browser, or another system. Work only on your machine against the restored local database copy, and with test accounts and test or sandbox endpoints. Never against a shared, staging, or production system.

For each check, tell the plugin one of:

- **verified**, with what you checked (the plugin records your words as evidence)
- **failed**, with what went wrong (the plugin records it with the steps to recover)
- **not verified**, with the reason (for example "cannot test locally"); it is reported as not verified

A check you skip stays open, and gate 5 does not pass while a check is open or failed.

{{checks}}
