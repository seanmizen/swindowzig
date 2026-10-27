# Asset requirements — `REQ-ASSETS-*`

Loading data with `sw_assets`: zip archives, files from the player, and the
data cache.

## REQ-ASSETS-001 — Opening a zip archive does not decompress it

- **Status:** active
- **Source:** agent:SWZ-54
- **Origin:** #54
- **Type:** quality
- **Priority:** P1
- **Statement:** When a game opens a zip archive, the `sw_assets` zip
  reader shall read only the central directory, and decompress no entry
  until the game reads that entry.
- **Rationale:** A game can open an archive of hundreds of megabytes with
  thousands of entries in a browser tab. A full decompression at open
  uses too much memory and stops the page for a long time. The game reads
  only the entries that it needs, one at a time.
- **Verification:** Test — `libs/sw_assets/src/zip.zig` › "zip: open does
  not decompress entries (REQ-ASSETS-001)"
- **Relations:** none

## REQ-ASSETS-002 — The cache tells why OPFS is missing

- **Status:** active
- **Source:** agent:SWZ-54
- **Origin:** #54
- **Type:** functional
- **Priority:** P2
- **Statement:** If the page is not a secure context, then each web cache
  request shall fail with `error.InsecureContext`, a code that names the
  cause.
- **Rationale:** The browser gives OPFS only to a secure context (HTTPS or
  http://localhost). Without a clear error, a game on a plain HTTP page
  sees a cache that fails with no reason. The console also shows one
  message that names the secure context.
- **Verification:** Test — `backends/wasm/files.test.ts` › "a page that is
  not a secure context gets InsecureContext (REQ-ASSETS-002)"
- **Relations:** none
