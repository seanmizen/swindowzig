"""A fake AT-SPI registry for the AccessKit check (REQ-A11Y-007, REQ-A11Y-008).

scripts/accesskit/atspi-check.sh starts this file. It needs python3 with the
dbus and gi modules (Debian and Ubuntu: python3-dbus, python3-gi).

The file owns two names on the session bus:

- org.a11y.Bus, with IsEnabled = true. AccessKit then starts its AT-SPI side.
- org.a11y.atspi.Registry. AccessKit embeds the root of the app here.

The session bus is also the AT-SPI bus (AT_SPI_BUS_ADDRESS). After the app
embeds its root, the file:

1. reads the accessible tree and prints it,
2. asks AccessKit to move the focus to "Settings" (Component.GrabFocus),
3. asks AccessKit to click "Orange" (Action.DoAction 0),
4. checks the events: the focus of "Settings", and the announcement
   "Accent: Orange" of the live region.

The exit code is 0 when each check passes, else 1.
"""

import os
import sys

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
ADDRESS = os.environ["DBUS_SESSION_BUS_ADDRESS"]
PROPS = "org.freedesktop.DBus.Properties"
ACCESSIBLE = "org.a11y.atspi.Accessible"
ROOT = "/org/a11y/atspi/accessible/root"

app = {"name": None}
paths = {}
events = []
step = {"n": 0}
result = {"ok": False}


def log(*parts):
    print("[atspi-check]", *parts, flush=True)


class Status(dbus.service.Object):
    @dbus.service.method("org.a11y.Bus", out_signature="s")
    def GetAddress(self):
        return ADDRESS

    @dbus.service.method(PROPS, in_signature="ss", out_signature="v")
    def Get(self, _iface, _prop):
        return dbus.Boolean(True)

    @dbus.service.method(PROPS, in_signature="s", out_signature="a{sv}")
    def GetAll(self, _iface):
        return {"IsEnabled": dbus.Boolean(True), "ScreenReaderEnabled": dbus.Boolean(True)}


class Registry(dbus.service.Object):
    @dbus.service.method("org.a11y.atspi.Socket", in_signature="(so)", out_signature="(so)")
    def Embed(self, plug):
        log("the app embeds its root:", plug[0])
        app["name"] = str(plug[0])
        GLib.timeout_add(1500, next_step)
        return (bus.get_unique_name(), dbus.ObjectPath(ROOT))


def node(path):
    return bus.get_object(app["name"], path)


def walk(path, depth):
    o = node(path)
    name = str(o.Get(ACCESSIBLE, "Name", dbus_interface=PROPS))
    role = int(o.GetRole(dbus_interface=ACCESSIBLE))
    log("  " * depth + f"role {role}: {name!r}")
    paths[name] = path
    for child in o.GetChildren(dbus_interface=ACCESSIBLE):
        walk(str(child[1]), depth + 1)


def next_step():
    n = step["n"]
    step["n"] += 1
    if n == 0:
        log("the tree:")
        walk(ROOT, 0)
        node(paths["Settings"]).GrabFocus(dbus_interface="org.a11y.atspi.Component")
        log("GrabFocus on Settings")
        return True
    if n == 1:
        node(paths["Orange"]).DoAction(0, dbus_interface="org.a11y.atspi.Action")
        log("DoAction 0 on Orange")
        return True
    focused = ("StateChanged", "focused", 1, paths.get("Settings")) in events
    spoken = any(e[0] == "Announcement" and e[3] == "Accent: Orange" for e in events)
    log("focus of Settings:", "yes" if focused else "NO")
    log("announcement 'Accent: Orange':", "yes" if spoken else "NO")
    result["ok"] = focused and spoken
    loop.quit()
    return False


def on_event(*args, **kw):
    member = kw.get("member")
    if member == "Announcement":
        events.append(("Announcement", "", int(args[1]), str(args[3])))
        log(f"event Announcement {str(args[3])!r} (politeness {int(args[1])})")
    elif member == "StateChanged":
        events.append(("StateChanged", str(args[0]), int(args[1]), kw.get("path")))


bus.add_signal_receiver(
    on_event,
    dbus_interface="org.a11y.atspi.Event.Object",
    member_keyword="member",
    path_keyword="path",
)
bus.request_name("org.a11y.Bus")
bus.request_name("org.a11y.atspi.Registry")
Status(bus, "/org/a11y/bus")
Registry(bus, ROOT)
loop = GLib.MainLoop()
GLib.timeout_add(30000, loop.quit)
log("ready")
loop.run()
if app["name"] is None:
    log("the app did not embed its root")
sys.exit(0 if result["ok"] else 1)
