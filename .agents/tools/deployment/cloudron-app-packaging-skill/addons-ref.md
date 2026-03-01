# Addons Reference

Full environment variable and option reference for Cloudron addons. Declare addons in `CloudronManifest.json` under the `addons` key.

Read env vars at runtime on every start — values can change across restarts.

## localstorage

Provides writable `/app/data` directory. Contents are backed up. Directory is empty on first install; files from the Docker image are not present. Restore permissions in `start.sh`.

Options:

- `ftp` — Enable FTP access: `{ "ftp": { "uid": 33, "uname": "www-data" } }`
- `sqlite` — Declare SQLite files for consistent backup: `{ "sqlite": { "paths": ["/app/data/db.sqlite"] } }`

## mysql

MySQL 8.0. Database is pre-created.

```
CLOUDRON_MYSQL_URL          # full connection URL
CLOUDRON_MYSQL_USERNAME
CLOUDRON_MYSQL_PASSWORD
CLOUDRON_MYSQL_HOST
CLOUDRON_MYSQL_PORT
CLOUDRON_MYSQL_DATABASE
```

Options:

- `multipleDatabases: true` — Provides `CLOUDRON_MYSQL_DATABASE_PREFIX` instead of `CLOUDRON_MYSQL_DATABASE`. Create databases with that prefix.

Default charset: `utf8mb4` / `utf8mb4_unicode_ci`.

Debug: `cloudron exec` then `mysql --user=$CLOUDRON_MYSQL_USERNAME --password=$CLOUDRON_MYSQL_PASSWORD --host=$CLOUDRON_MYSQL_HOST $CLOUDRON_MYSQL_DATABASE`

## postgresql

PostgreSQL 14.9.

```
CLOUDRON_POSTGRESQL_URL
CLOUDRON_POSTGRESQL_USERNAME
CLOUDRON_POSTGRESQL_PASSWORD
CLOUDRON_POSTGRESQL_HOST
CLOUDRON_POSTGRESQL_PORT
CLOUDRON_POSTGRESQL_DATABASE
```

Options:

- `locale` — Set `LC_LOCALE` and `LC_CTYPE` at database creation.

Supported extensions: `btree_gist`, `btree_gin`, `citext`, `hstore`, `pgcrypto`, `pg_trgm`, `postgis`, `uuid-ossp`, `unaccent`, `vector`, `vectors`, and more.

Debug: `PGPASSWORD=$CLOUDRON_POSTGRESQL_PASSWORD psql -h $CLOUDRON_POSTGRESQL_HOST -p $CLOUDRON_POSTGRESQL_PORT -U $CLOUDRON_POSTGRESQL_USERNAME -d $CLOUDRON_POSTGRESQL_DATABASE`

## mongodb

MongoDB 8.0.

```
CLOUDRON_MONGODB_URL
CLOUDRON_MONGODB_USERNAME
CLOUDRON_MONGODB_PASSWORD
CLOUDRON_MONGODB_HOST
CLOUDRON_MONGODB_PORT
CLOUDRON_MONGODB_DATABASE
CLOUDRON_MONGODB_OPLOG_URL      # only when oplog enabled
```

Options:

- `oplog: true` — Enable oplog access.

## redis

Redis 8.4. Data is persistent.

```
CLOUDRON_REDIS_URL
CLOUDRON_REDIS_HOST
CLOUDRON_REDIS_PORT
CLOUDRON_REDIS_PASSWORD
```

Options:

- `noPassword: true` — Skip password auth (safe: Redis is only reachable on internal Docker network).

## ldap

LDAP v3 authentication.

```
CLOUDRON_LDAP_SERVER
CLOUDRON_LDAP_HOST
CLOUDRON_LDAP_PORT
CLOUDRON_LDAP_URL
CLOUDRON_LDAP_USERS_BASE_DN
CLOUDRON_LDAP_GROUPS_BASE_DN
CLOUDRON_LDAP_BIND_DN
CLOUDRON_LDAP_BIND_PASSWORD
```

Suggested filter: `(&(objectclass=user)(|(username=%uid)(mail=%uid)))`

User attributes: `uid`, `cn`, `mail`, `displayName`, `givenName`, `sn`, `username`, `samaccountname`, `memberof`

Group attributes: `cn`, `gidnumber`, `memberuid`

Cannot be added to an existing app — reinstall required.

## oidc

OpenID Connect authentication.

```
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

Options:

- `loginRedirectUri` — Callback path (e.g. `/auth/openid/callback`). Multiple paths: comma-separated.
- `logoutRedirectUri` — Post-logout path.
- `tokenSignatureAlgorithm` — `RS256` (default) or `EdDSA`.

## sendmail

Outgoing email (SMTP relay).

```
CLOUDRON_MAIL_SMTP_SERVER
CLOUDRON_MAIL_SMTP_PORT           # STARTTLS disabled on this port
CLOUDRON_MAIL_SMTPS_PORT
CLOUDRON_MAIL_SMTP_USERNAME
CLOUDRON_MAIL_SMTP_PASSWORD
CLOUDRON_MAIL_FROM
CLOUDRON_MAIL_FROM_DISPLAY_NAME   # only when supportsDisplayName is set
CLOUDRON_MAIL_DOMAIN
```

Options:

- `optional: true` — All env vars absent; app uses user-provided email config.
- `supportsDisplayName: true` — Enables `CLOUDRON_MAIL_FROM_DISPLAY_NAME`.
- `requiresValidCertificate: true` — Sets `CLOUDRON_MAIL_SMTP_SERVER` to FQDN.

## recvmail

Incoming email (IMAP/POP3).

```
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

May be disabled if the server is not receiving email for the domain. Handle absent env vars.

## email

Full email capabilities (SMTP + IMAP + ManageSieve). For webmail applications.

```
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

Accept self-signed certificates for internal IMAP/Sieve connections.

## proxyauth

Authentication wall in front of the app. Reserves `/login` and `/logout` routes.

Options:

- `path` — Restrict to a path (e.g. `/admin`). Prefix with `!` to exclude (e.g. `!/webhooks`).
- `basicAuth` — Enable HTTP Basic auth (bypasses 2FA).
- `supportsBearerAuth` — Forward `Bearer` tokens to the app.

Cannot be added to an existing app — reinstall required.

## scheduler

Cron-like periodic tasks.

```json
"scheduler": {
  "task_name": {
    "schedule": "*/5 * * * *",
    "command": "/app/code/task.sh"
  }
}
```

Commands run in the app's environment (same env vars, access to `/tmp` and `/run`). 30-minute grace period per task.

## tls

Certificate access for non-HTTP protocols.

Files: `/etc/certs/tls_cert.pem`, `/etc/certs/tls_key.pem` (read-only). App restarts on certificate renewal.

## turn

STUN/TURN service.

```
CLOUDRON_TURN_SERVER
CLOUDRON_TURN_PORT
CLOUDRON_TURN_TLS_PORT
CLOUDRON_TURN_SECRET
```

## docker

Create Docker containers (restricted). Only superadmins can install/exec apps with this addon.

```
CLOUDRON_DOCKER_HOST              # tcp://<IP>:<port>
```

Restrictions: bind mounts under `/app/data` only, created containers join `cloudron` network, containers removed on app uninstall.
