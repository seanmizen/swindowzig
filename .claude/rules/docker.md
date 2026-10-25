---
paths:
  - "**/docker-compose*.yml"
  - "**/dockerfile"
  - "**/Dockerfile"
  - "**/.dockerignore"
---

# Docker

- Multi-stage Dockerfiles with `dev` and `prod` targets. `BUILD_TARGET`
  chooses one (default `dev`).
- The build context is always the monorepo root (`context: ../..`). The
  Dockerfile lives at `apps/<app>/dockerfile`.
- Profiles: `dev` bind-mounts the monorepo for hot reload, with named volumes
  for `node_modules`. `prod` is a self-contained image in detached mode.
- SQLite databases and uploads live in named volumes. Never bind-mount them
  from the checkout.
- Install with Yarn 4 in the image. Never `bun install` or `bun build`: Bun only
  runs the result (`CMD ["bun", "./src/index.ts"]`).
- Ports: see `.claude/rules/ports.md`.

```yaml
x-frontend-base: &frontend-base
  build:
    context: ../..
    dockerfile: apps/<app>/dockerfile
    target: ${BUILD_TARGET:-dev}

services:
  frontend:
    <<: *frontend-base
    profiles: ["prod"]
  frontend-dev:
    <<: *frontend-base
    volumes:
      - type: bind
        source: ../..
        target: /app
    profiles: ["dev"]
```
