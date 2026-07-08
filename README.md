# Pterodactyl Webstack v0.1

Ein Pterodactyl-Server pro Website/Domain/Subdomain.

## Stack

- Apache HTTP Server 2.4
- PHP 8.4 via Debian 13 default packages and `libapache2-mod-php`
- `mod_rewrite` enabled
- `.htaccess` enabled with `AllowOverride All` in `/home/container/public`
- MariaDB local-only on `127.0.0.1:3306` inside the container
- phpMyAdmin 5.2.3 always installed and served on a second Apache port
- TLS termination is external Nginx responsibility

## Port model

- Primary Pterodactyl allocation -> website backend, plain HTTP
- Second Pterodactyl allocation -> phpMyAdmin backend, plain HTTP
- MariaDB -> internal container loopback only, no Pterodactyl allocation

The external Nginx proxy publishes HTTPS/443. Do **not** add TLS to Apache in this stack.

## Important security rule

The Pterodactyl backend allocations must not be directly reachable from the Internet. Otherwise the phpMyAdmin allocation remains reachable as `IP:PORT` even when its Nginx route is disabled.

Recommended options:

1. Bind the allocations to a private/internal IP that exists on the Wings host, or
2. use a dedicated dummy/internal interface on the host and proxy to that IP, or
3. enforce host firewall rules that block external access to the entire backend allocation range.

Nginx on the same Root server must still be able to reach those ports.

## 1. Put this project into a Git repository

Example repository name:

`pterodactyl-webstack`

Push the complete directory to GitHub. The included GitHub Actions workflow builds and publishes:

`ghcr.io/<github-user>/pterodactyl-webstack:0.1.0`

Make the GHCR package public, or configure Wings for your private registry.

## 2. Change the Egg image

Open:

`egg/egg-webstack.json`

Replace:

`ghcr.io/replace-me/pterodactyl-webstack:0.1.0`

with your real GHCR image path.

## 3. Import the Egg

In Pterodactyl Admin:

1. Nests -> create/select a `Web Hosting` Nest
2. Import Egg
3. import `egg/egg-webstack.json`

Pterodactyl requires a Pterodactyl-compatible image with the `container` user and `/home/container` home/work directory. This image follows that layout.

## 4. Prepare two allocations

Example:

- `10.10.10.1:18081` website
- `10.10.10.1:18082` phpMyAdmin

Create the server with `18081` as primary allocation and add `18082` as additional allocation.

In Startup variables set:

`PHPMYADMIN_PORT=18082`

This value must exactly match the second allocation. Pterodactyl exposes `SERVER_PORT` for the primary allocation, but does not provide an automatic environment variable for a second allocation.

## 5. Start the server

First boot initializes MariaDB and generates random credentials.

Credentials are written to:

`/home/container/config/database.env`

The file contains:

- application database name/user/password
- MariaDB admin user/password for phpMyAdmin
- local MariaDB root password

MariaDB is only bound to `127.0.0.1:3306` inside the container.

## 6. Validate Apache/PHP/mod_rewrite

Direct backend test from the Wings host:

```bash
curl http://10.10.10.1:18081/
curl http://10.10.10.1:18081/__webstack/rewrite-test
```

Expected second response:

`mod_rewrite=ok`

This validates Apache, PHP, `.htaccess`, and `mod_rewrite` together.

## 7. Nginx

Use `nginx/example-site.conf` as the initial manual proxy configuration.

Website route:

`https://example.domain.tld -> http://10.10.10.1:18081`

Optional phpMyAdmin route:

`https://db.example.domain.tld -> http://10.10.10.1:18082`

Disable phpMyAdmin externally by removing/disabling the Nginx `server` block. phpMyAdmin remains running inside the Webstack.

## Persistent directories

- `public/` website files
- `config/` generated configuration and credentials
- `database/` MariaDB data directory
- `logs/` reserved application/log storage
- `run/` runtime state
- `tmp/` temporary state

Pterodactyl persists `/home/container`, so database data and credentials survive container recreation/restarts.

## Current v0.1 limitation

`PHPMYADMIN_PORT` must be synchronized manually with the server's second allocation.

A future Pterodactyl extension can create the Webstack server with a primary and secondary allocation, then set `PHPMYADMIN_PORT` to the secondary port automatically and manage both Nginx routes.

## Updating

The base software lives in the Docker image. Rebuild the image to pick up Debian/PHP/MariaDB security updates and a newer phpMyAdmin release, push the new tag, then pull/restart the Pterodactyl server.

For production, prefer immutable version tags such as `0.1.0` instead of only `latest`. Test a new image tag on a staging Webstack before rolling it to existing websites.
