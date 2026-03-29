# Addons Reference

Declare in `CloudronManifest.json` under `addons`. Read env vars at runtime — values can change across restarts.

## localstorage

Writable `/app/data`. Backed up. Empty on first install (Docker image files not present). Restore permissions in `start.sh`. Sub-addons: `ftp` (`{ "ftp": { "uid": 33, "uname": "www-data" } }`), `sqlite` (`{ "sqlite": { "paths": ["/app/data/db.sqlite"] } }`).

## mysql

Database pre-created. Default charset: `utf8mb4` / `utf8mb4_unicode_ci`.

```text
CLOUDRON_MYSQL_URL
CLOUDRON_MYSQL_USERNAME
CLOUDRON_MYSQL_PASSWORD
CLOUDRON_MYSQL_HOST
CLOUDRON_MYSQL_PORT
CLOUDRON_MYSQL_DATABASE
```

- `multipleDatabases: true` — Provides `CLOUDRON_MYSQL_DATABASE_PREFIX` instead of `CLOUDRON_MYSQL_DATABASE`.
Debug: `MYSQL_PWD=$CLOUDRON_MYSQL_PASSWORD mysql --user=$CLOUDRON_MYSQL_USERNAME --host=$CLOUDRON_MYSQL_HOST $CLOUDRON_MYSQL_DATABASE`

## postgresql

Database pre-created. Extensions: `btree_gist`, `btree_gin`, `citext`, `hstore`, `pgcrypto`, `pg_trgm`, `postgis`, `uuid-ossp`, `unaccent`, `vector`, `vectors`, and more.

```text
CLOUDRON_POSTGRESQL_URL
CLOUDRON_POSTGRESQL_USERNAME
CLOUDRON_POSTGRESQL_PASSWORD
CLOUDRON_POSTGRESQL_HOST
CLOUDRON_POSTGRESQL_PORT
CLOUDRON_POSTGRESQL_DATABASE
```

- `locale` — Set `LC_LOCALE` and `LC_CTYPE` at database creation.
Debug: `PGPASSWORD=$CLOUDRON_POSTGRESQL_PASSWORD psql -h $CLOUDRON_POSTGRESQL_HOST -p $CLOUDRON_POSTGRESQL_PORT -U $CLOUDRON_POSTGRESQL_USERNAME -d $CLOUDRON_POSTGRESQL_DATABASE`

## mongodb

```text
CLOUDRON_MONGODB_URL
CLOUDRON_MONGODB_USERNAME
CLOUDRON_MONGODB_PASSWORD
CLOUDRON_MONGODB_HOST
CLOUDRON_MONGODB_PORT
CLOUDRON_MONGODB_DATABASE
CLOUDRON_MONGODB_OPLOG_URL      # only when oplog: true
```

- `oplog: true` — Enable oplog access.

## redis

Persistent. `noPassword: true` skips auth (safe: internal Docker network only).

```text
CLOUDRON_REDIS_URL
CLOUDRON_REDIS_HOST
CLOUDRON_REDIS_PORT
CLOUDRON_REDIS_PASSWORD
```

## ldap

LDAP v3 authentication. Cannot be added to an existing app — reinstall required.

```text
CLOUDRON_LDAP_SERVER
CLOUDRON_LDAP_HOST
CLOUDRON_LDAP_PORT
CLOUDRON_LDAP_URL
CLOUDRON_LDAP_USERS_BASE_DN
CLOUDRON_LDAP_GROUPS_BASE_DN
CLOUDRON_LDAP_BIND_DN
CLOUDRON_LDAP_BIND_PASSWORD
```

Filter: `(&(objectclass=user)(|(username=%uid)(mail=%uid)))`
User attrs: `uid`, `cn`, `mail`, `displayName`, `givenName`, `sn`, `username`, `samaccountname`, `memberof`
Group attrs: `cn`, `gidnumber`, `memberuid`

## oidc

OpenID Connect authentication.

```text
CLOUDRON_OIDC_PROVIDER_NAME
CLOUDRON_OIDC_DISCOVERY_URL
CLOUDRON_OIDC_ISSUER
CLOUDRON_OIDC_AUTH_ENDPOINT
CLOUDRON_OIDC_TOKEN_ENDPOINT
CLOUDRON_OIDC_KEYS_ENDPOINT
CLOUDRON_OIDC_PROFILE_ENDPOINT
CLOUDRON_OIDC_CLIENT_ID
CLOUDRON_OIDC_CLIENT_SECRET
```

- `loginRedirectUri` — Callback path (e.g. `/auth/openid/callback`). Multiple: comma-separated.
- `logoutRedirectUri` — Post-logout path.
- `tokenSignatureAlgorithm` — `RS256` (default) or `EdDSA`.

## sendmail

Outgoing email (SMTP relay).

```text
CLOUDRON_MAIL_SMTP_SERVER
CLOUDRON_MAIL_SMTP_PORT           # STARTTLS disabled on this port
CLOUDRON_MAIL_SMTPS_PORT
CLOUDRON_MAIL_SMTP_USERNAME
CLOUDRON_MAIL_SMTP_PASSWORD
CLOUDRON_MAIL_FROM
CLOUDRON_MAIL_FROM_DISPLAY_NAME   # only when supportsDisplayName is set
CLOUDRON_MAIL_DOMAIN
```

- `optional: true` — All env vars absent; app uses user-provided email config.
- `supportsDisplayName: true` — Enables `CLOUDRON_MAIL_FROM_DISPLAY_NAME`.
- `requiresValidCertificate: true` — Sets `CLOUDRON_MAIL_SMTP_SERVER` to FQDN.

## recvmail

Incoming email (IMAP/POP3). May be disabled — handle absent env vars.

```text
CLOUDRON_MAIL_IMAP_SERVER
CLOUDRON_MAIL_IMAP_PORT
CLOUDRON_MAIL_IMAPS_PORT
CLOUDRON_MAIL_POP3_PORT
CLOUDRON_MAIL_POP3S_PORT
CLOUDRON_MAIL_IMAP_USERNAME
CLOUDRON_MAIL_IMAP_PASSWORD
CLOUDRON_MAIL_TO
CLOUDRON_MAIL_TO_DOMAIN
```

## email

Full email (SMTP + IMAP + ManageSieve). For webmail apps. Accept self-signed certs for internal IMAP/Sieve connections.

```text
CLOUDRON_EMAIL_SMTP_SERVER
CLOUDRON_EMAIL_SMTP_PORT
CLOUDRON_EMAIL_SMTPS_PORT
CLOUDRON_EMAIL_STARTTLS_PORT
CLOUDRON_EMAIL_IMAP_SERVER
CLOUDRON_EMAIL_IMAP_PORT
CLOUDRON_EMAIL_IMAPS_PORT
CLOUDRON_EMAIL_SIEVE_SERVER
CLOUDRON_EMAIL_SIEVE_PORT
CLOUDRON_EMAIL_DOMAIN
CLOUDRON_EMAIL_DOMAINS
CLOUDRON_EMAIL_SERVER_HOST
```

## proxyauth

Authentication wall. Reserves `/login` and `/logout` routes. Cannot be added to an existing app — reinstall required.

- `path` — Restrict to a path (e.g. `/admin`). Prefix `!` to exclude (e.g. `!/webhooks`).
- `basicAuth` — HTTP Basic auth (bypasses 2FA).
- `supportsBearerAuth` — Forward `Bearer` tokens to the app.

## scheduler

Cron-like periodic tasks. Commands run in the app's environment (same env vars, `/tmp`, `/run`). 30-minute grace period.

```json
"scheduler": {
  "task_name": {
    "schedule": "*/5 * * * *",
    "command": "/app/code/task.sh"
  }
}
```

## tls

Certificate access for non-HTTP protocols. Files: `/etc/certs/tls_cert.pem`, `/etc/certs/tls_key.pem` (read-only). App restarts on renewal.

## turn

STUN/TURN service.

```text
CLOUDRON_TURN_SERVER
CLOUDRON_TURN_PORT
CLOUDRON_TURN_TLS_PORT
CLOUDRON_TURN_SECRET
```

## docker

Create Docker containers (restricted). Only superadmins can install/exec apps with this addon.

```text
CLOUDRON_DOCKER_HOST              # tcp://<IP>:<port>
```

Restrictions: bind mounts under `/app/data` only, containers join `cloudron` network, removed on app uninstall.
