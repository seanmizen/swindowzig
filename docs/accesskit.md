# AccessKit: the native screen-reader backend

The web build gives the sw_ui semantic tree to the browser through a hidden
DOM (`libs/sw_ui/src/web_mirror.zig`, REQ-A11Y-001). A native window has no
DOM. The native build can send the same tree to
[AccessKit](https://github.com/AccessKit/accesskit) through its C bindings,
[accesskit-c](https://github.com/AccessKit/accesskit-c). AccessKit gives the
tree to the platform accessibility API (REQ-A11Y-007):

| Platform | API | Screen reader |
|---|---|---|
| Windows | UI Automation | Narrator, NVDA, JAWS |
| macOS | NSAccessibility | VoiceOver |
| Linux | AT-SPI over D-Bus | Orca |

The backend is optional and off by default. With the option off, nothing
links and the native build does not change.

## Licence

The research used accesskit-c 0.23.1 (tag `0.23.1`, files of 2026-09-26).

- The library: MIT or Apache-2.0, at your choice (`Cargo.toml`:
  `license = "MIT OR Apache-2.0"`, files `LICENSE-MIT` and `LICENSE-APACHE`).
- Parts of AccessKit come from Chromium. These parts have the Chromium
  BSD-style licence (`LICENSE.chromium`).
- The Meson build files of accesskit-c have the LGPL 2.1 (`COPYING.LIB`).
  That licence applies to the build system only, not to the library. The
  swindowzig build does not use Meson.

The three library licences are permissive. They let a game link accesskit-c
statically and ship it. A shipped game must include the MIT or Apache-2.0
notice and the Chromium notice. `THIRD_PARTY_NOTICES.md` records this.
swindowzig does not ship accesskit-c: the developer downloads it.

## How the library ships

Each GitHub release has one zip, `accesskit-c-<version>.zip` (67 MB for
0.23.1). It holds `include/accesskit.h`, the CMake files, the examples, and
the libraries in `lib/<os>/<arch>/[<toolchain>/]{static,shared}/`:

| Directory | Static | Shared |
|---|---|---|
| `lib/linux/x86_64`, `lib/linux/x86` | `libaccesskit.a` | `libaccesskit.so` |
| `lib/macos/arm64`, `lib/macos/x86_64` | `libaccesskit.a` | `libaccesskit.dylib` |
| `lib/windows/<arch>/msvc` | `accesskit.lib` | `accesskit.dll` |
| `lib/windows/<arch>/mingw` | `libaccesskit.a` | `accesskit.dll` |

There are also iOS and Android libraries. The libraries are Rust code
(`crate-type = ["cdylib", "staticlib"]`). A source build needs Rust 1.87 and
CMake 3.20.

The static library needs these system libraries (`accesskit-config.cmake`):

- macOS: AppKit, Foundation, CoreFoundation, `objc`, `c++`.
- Linux: `m` and the GCC runtime. The Linux adapter speaks D-Bus with zbus, a
  Rust library, so it needs no `libdbus`.
- Windows: `bcrypt ntdll propsys runtimeobject uiautomationcore userenv
  ws2_32`.

## Install and build

1. Download the zip from
   `https://github.com/AccessKit/accesskit-c/releases/download/0.23.1/accesskit-c-0.23.1.zip`.
2. Copy the static library of your platform to `~/.local/lib`, next to
   wgpu-native. For example, on an Apple silicon Mac:
   `cp accesskit-c-0.23.1/lib/macos/arm64/static/libaccesskit.a ~/.local/lib/`.
3. Build with the option: `zig build run -Dexample=flat2d -Daccesskit=true`.

`build.zig` links `accesskit` (static first) and the system libraries above
only when the option is on. For a package that uses swindowzig with
`-Dplatform=native`, the option turns on the backend in the exported
`sw_ui` module. That package must link accesskit-c itself.

## The C API

`accesskit.h` is one header of 3,154 lines, made by cbindgen. swindowzig has
no `@cImport`, so `libs/sw_ui/src/accesskit.zig` declares the functions that
it calls as `extern fn`. The parts that it uses:

- Nodes: `accesskit_node_new(role)`, then setters such as
  `accesskit_node_set_label`, `_set_value`, `_set_description`,
  `_set_bounds`, `_set_children`, `_add_action`, `_set_live`,
  `_set_disabled`, `_set_selected`, `_set_modal` and `_set_numeric_value`.
- Tree updates: `accesskit_tree_update_with_capacity_and_focus(n, focus)`,
  `accesskit_tree_update_push_node(update, id, node)`, and for the first
  update `accesskit_tree_info_new(root)` with
  `accesskit_tree_update_set_tree_info`. A tree update takes ownership of each
  node that goes into it.
- Callbacks: the activation handler returns the full tree when a screen
  reader first asks for it. The action handler gets an
  `accesskit_action_request` (focus, click, increment, ...) and must free it.
  The Linux adapter also has a deactivation handler.
- Adapters. Each adapter has `_update_if_active(adapter, factory, userdata)`.
  The factory runs at once, on the caller thread, and only while a screen
  reader is active:
  - Windows: `accesskit_windows_subclassing_adapter_new(hwnd, ...)`. It
    subclasses the window procedure and reads the window focus itself.
    `_update_if_active` returns queued events. Raise them with
    `accesskit_windows_queued_events_raise`.
  - macOS: `accesskit_macos_subclassing_adapter_for_window(nswindow, ...)`.
    It subclasses the content view of the window.
    `accesskit_macos_add_focus_forwarder_to_window_class("SDLWindow")` makes
    the focused node visible to VoiceOver. `SDLWindow` is the NSWindow
    subclass of SDL2. `_update_view_focus_state` gives the window focus.
  - Linux and the BSDs: `accesskit_unix_adapter_new(...)` needs no window
    handle. `_update_window_focus_state` gives the window focus, and
    `_set_root_window_bounds` gives the window position on the screen.

The C enums have no explicit numbers. `accesskit_map.zig` holds the numbers
that it uses, and a unit test checks them. To print the numbers of a new
header, compile a small C file that prints each enum value:

```bash
printf '#include <stdio.h>\n#include "accesskit.h"\nint main(void){printf("%%d %%d\\n", ACCESSKIT_ROLE_BUTTON, ACCESSKIT_ROLE_WINDOW);}\n' > enums.c
zig cc -I accesskit-c-0.23.1/include enums.c -o enums && ./enums
```

### The window handle from SDL2

SDL2 gives the native handle with `SDL_GetWindowWMInfo`. The result has
`info.cocoa.window` (`NSWindow *`) on macOS and `info.win.window` (`HWND`)
on Windows. `native_sdl.zig` reads it in `getNativeWindow`, together with the
focus flag, the window position and the frame size. An app reads it with
`ctx.nativeWindow()`. The accesskit-c SDL example uses SDL3. SDL3 gives the
same handles through window properties.

## The map from the semantic tree

`libs/sw_ui/src/accesskit_map.zig` is plain Zig with no C code. `zig build
test` runs its tests on each platform. `Snapshot.init` copies the tree, and
`diff` gives the nodes that changed and tells if the focus moved
(REQ-A11Y-008).

| sw_ui role | AccessKit role | Data | Actions |
|---|---|---|---|
| root (ID 0) | `window` | label: the window title | none |
| group with a name | `group` | label | none |
| group with no name | `generic_container` | none (the platform hides it) | none |
| text | `label` | value: the text (AccessKit reads a label from its value) | none |
| button | `button` | label | focus, click |
| list | `list` | label | none |
| list item | `list_item` | label, selected | focus, click |
| text field | `text_input` | label, value: the text | focus |
| image | `image` | label: the description | none |
| slider | `slider` | label, value text, numeric value, min, max | focus, increment, decrement |
| screen | `dialog` | label: the title, modal | none |
| tooltip | `tooltip` | label: the text | none |

Each node also gets its description (the tooltip text) and its bounds. The
bounds are in physical pixels of the window: the logical rectangle times
the DPI scale. A disabled node has no actions.

- Focus: each update names the focused node. With no focused node, the
  focus is the root, so the window has focus. AccessKit tells the screen
  reader when the focus moves.
- Live regions: a live text has `live = polite`, as on the web
  (REQ-A11Y-003). When its text changes, the diff holds the node, and
  AccessKit tells the screen reader to speak it. The semantic tree has no
  "assertive" level now. `accesskit_map.Live` has the value for later use.

## The adapter

`sw_ui.accesskit.Adapter` (`libs/sw_ui/src/accesskit.zig`) owns the
platform adapter. `examples/flat2d/main.zig` shows its use:

1. In `init`: `adapter.start(alloc, windowState(ctx.nativeWindow()), title)`.
2. In each tick after `Ui.finish`: `syncWindow`, then
   `publish(u.semanticTree(), dpi_scale)`. A frame with no change sends
   nothing.
3. Read the screen-reader requests with `takeAction`. flat2d moves the
   focus for each request. For a click it then gives Enter to the UI, and
   for increment or decrement it gives Right or Left.
4. In `shutdown`: `adapter.stop()`.

Threads: on Linux, AccessKit calls the activation handler and the action
handler on its own thread. The handlers use a spin lock to read the current
snapshot and to write the action queue. The main thread never calls
AccessKit while it holds that lock.

## Tests

- `zig build test` runs the map tests and the adapter tests with the option
  off.
- `scripts/accesskit/atspi-check.sh` runs on Linux with no screen reader. It
  builds flat2d with the option and runs it in a private D-Bus session.
  `scripts/accesskit/fake_atspi.py` takes the place of the AT-SPI registry.
  It reads the accessible tree, moves the focus to "Settings", clicks
  "Orange", and checks the focus event and the "Accent: Orange"
  announcement. It needs python3 with the `dbus` and `gi` modules.
- A real screen reader on each platform is a manual test. The next section
  gives the steps for VoiceOver.

## Manual check with VoiceOver (macOS)

1. Install `libaccesskit.a` (see "Install and build").
2. Run `zig build run -Dexample=flat2d -Daccesskit=true`.
3. Push Cmd+F5 to start VoiceOver. Click the flat2d window.
4. Check that VoiceOver speaks "Green, selected" or similar for the accent
   list.
5. Push Tab. Check that VoiceOver speaks each new focus: "Close menu,
   button", "Settings, button", "Name, edit text".
6. Push Shift+Tab until the accent list has focus. Push Down. Check that
   VoiceOver speaks "Accent: Orange" with no move of the focus. This is the
   live region.
7. Open the VoiceOver rotor (VO+U). Check that it lists the buttons and the
   list items with their names.
8. Move the VoiceOver cursor to "Pink" (VO+Right) and push VO+Space. Check
   that the accent changes to Pink and that VoiceOver speaks
   "Accent: Pink".
9. Open Settings. Move the VoiceOver cursor to the volume slider and push VO+Up Arrow. Check
   that the value changes.

## Limits

- The Windows and macOS paths compile for their targets, but nobody ran
  them with a screen reader yet.
- A text field gives its text as the value only. AccessKit text runs (caret,
  selection, text navigation by the screen reader) are not sent.
- The scroll offset of a scroll list is not sent. A screen reader that moves
  to a hidden item does not scroll the list.
- One `Adapter` serves one window and one `Ui`.
