---
paths:
  - "**/docker-compose*.yml"
  - "**/dockerfile"
  - "**/Dockerfile"
---

# Ports

## Every published port names its host address

```yaml
ports:
  - "${PUBLISH_ADDR:-127.0.0.1}:4000:4000"
```

Unset, it binds loopback, so nothing else on the LAN can reach the port. Each
workspace's `start:docker` sets `PUBLISH_ADDR=0.0.0.0`, so a dev server is
reachable from another device on the wifi. Never write a bare `"4000:4000"` or
`"0.0.0.0:4000:4000"`.

## Port pairs: 4xxx

| Port | Service |
|---|---|
| 4040 | RESERVED - the ngrok web inspector binds it |

### Add a service

1. Take the next free `40x0` pair: `40x0` for the frontend, `40x1` for the
   backend. Add the pair to the table above.
2. Publish both ports with `${PUBLISH_ADDR:-127.0.0.1}` in the app's
   `docker-compose.yml`.
3. Decide where its data lives. SQLite and uploads go in named Docker volumes.
