---
title: Additional services
nav_order: 8
---

# Adding services

The core stack is intentionally small. You can extend it, but treat every additional container
as part of the security and backup boundary: give it only the network access, host paths, and
public exposure it actually needs.

## Choose a home

For a service that belongs with the media apps, add it to
`stacks/media-server/compose.yaml`. It already joins the external `internal` network and is
included by `just up`, `just validate`, and the CI Compose check.

For a separate concern, create another stack under `stacks/<name>/compose.yaml`, then add the
stack name to `stack_list` in the `justfile` and to the stack loop in `.github/workflows/ci.yml`.
Use the same external network declaration:

```yaml
networks:
  default:
    name: internal
    external: true
```

Run `just networks` before the first start. Containers on `internal` reach one another by
service name, for example `http://sonarr:8989`; they should not use public hostnames or
`localhost` for app-to-app traffic.

## Service checklist

1. Pin the image to a version that supports the VPS architecture and avoid `latest`.
2. Add `restart: unless-stopped` and `no-new-privileges:true` unless the service has a documented
   reason not to use them.
3. Give persistent state its own `$CONFIG_DIR/<service>` directory and add that directory to the
   backup scope. Do not bind-mount the repository source tree.
4. Run the container with `ENV_PUID`/`ENV_PGID` where the image supports them, and document any
   ownership or elevated capability requirement.
5. Add a healthcheck when the image exposes a reliable local endpoint or command.
6. Keep the service on the internal network unless another container needs to reach it.
7. Expose it through Traefik only when necessary. Admin services should use the
   `https-tailnet` entrypoint; public services need a deliberate security review, authentication,
   and an entry in the public-hostname procedure.
8. Add its configuration and operational notes to the appropriate docs page.
9. Run `just validate`, `just up-svc <stack> <service>`, and `just health` before using it.

## Services worth considering

### Homarr

Homarr is a lightweight dashboard. Add it to the media stack with a persistent
`$CONFIG_DIR/homarr` directory and a tailnet-only Traefik router. Point its widgets at internal
URLs such as `http://sonarr:8989`, `http://radarr:7878`, and `http://jellyfin:8096`.

### qBittorrent

qBittorrent is an alternative local torrent client. It needs deliberate download storage and
should not be confused with Decypharr's qBittorrent-compatible API. If you add it as an Arr
download client, use its internal service name and port, then choose its priority explicitly.
Local torrent data changes the storage and backup assumptions of this repository.

### SABnzbd

SABnzbd is an alternative local Usenet client. It needs persistent configuration and download
paths, plus a review of ownership and backup requirements. If you use it instead of Decypharr's
SABnzbd-compatible endpoint, configure the Arrs with the internal URL and the correct URL base.

## Validate the extension

```bash
just validate
just up-svc media-server <service>
just health
```

Do not open a new public port as a shortcut. Add a Traefik route, keep the service on the correct
entrypoint, and update the security documentation first.
