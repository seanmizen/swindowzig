// The tests of the gun model (guns.zig) and the class stats (weapon.zig
// table), from the action game: the rules of the model and the balance.
const std = @import("std");
const guns = @import("guns.zig");
const weapon = @import("weapon.zig");

fn statsOf(name: []const u8) *const weapon.Stats {
    for (guns.builds, 0..) |b, i| {
        if (std.mem.eql(u8, b.name, name)) return &guns.table[i];
    }
    @panic("no gun of this name");
}

test "every gun of guns.bin has a build, in the same order" {
    try std.testing.expectEqual(34, guns.gun_count);
    var counts: [weapon.class_count]u32 = @splat(0);
    for (guns.builds) |b| counts[@backingInt(guns.classOf(b.name).?)] += 1;
    // rifle, carbine, bullpup, smg, shotgun, sawn-off, pistol, revolver
    const want = [_]u32{ 5, 4, 3, 5, 5, 1, 6, 5 };
    for (want, 0..) |n, c| try std.testing.expectEqual(n, counts[c]);
}

test "a longer barrel gives more bullet speed and less fall-off" {
    // The same 5.56 mm round: 51 cm, 41 cm and 37 cm barrels.
    const long = statsOf("AssaultRifle2_1");
    const mid = statsOf("AssaultRifle2_3");
    const short = statsOf("AssaultRifle2_2");
    try std.testing.expect(long.velocity > mid.velocity and mid.velocity > short.velocity);
    try std.testing.expect(long.far > mid.far and mid.far > short.far);
    try std.testing.expect(long.damageAt(false, 60) >= short.damageAt(false, 60));
    // The .357 Magnum: 15 cm against a 6 cm snub barrel.
    try std.testing.expect(statsOf("Revolver_3").velocity > statsOf("Revolver_4").velocity);
    try std.testing.expect(statsOf("Revolver_3").near > statsOf("Revolver_4").near);
}

test "a stock gives less recoil and a faster recovery" {
    // An AR with a stock (AssaultRifle2_2) and one with no stock
    // (AssaultRifle2_3). The one with no stock is also lighter.
    const stock = statsOf("AssaultRifle2_2");
    const none = statsOf("AssaultRifle2_3");
    try std.testing.expect(none.kick > stock.kick * 1.4);
    try std.testing.expect(none.sway > stock.sway * 1.4);
    try std.testing.expect(none.recovery < stock.recovery);
    // The same calibre and weight: the AK with a stock and the AK pistol.
    try std.testing.expect(statsOf("AssaultRifle_3").kick > statsOf("AssaultRifle_4").kick);
}

test "a heavy gun is slower to move and aim, and kicks less" {
    const heavy = statsOf("AssaultRifle2_1");
    const medium = statsOf("AssaultRifle2_2");
    try std.testing.expect(heavy.speed < medium.speed);
    try std.testing.expect(heavy.draw > medium.draw);
    try std.testing.expect(heavy.aim_speed < medium.aim_speed);
    try std.testing.expect(statsOf("AssaultRifle_2").kick < statsOf("AssaultRifle_4").kick);
}

test "the calibre sets the damage, the speed and the recoil" {
    const ak = statsOf("AssaultRifle_2");
    const ak74 = statsOf("AssaultRifle_5");
    try std.testing.expect(ak.body > ak74.body);
    try std.testing.expect(ak.kick > ak74.kick);
    // A bigger shot fires more slowly: the damage a second of a class
    // stays near its reference.
    try std.testing.expect(ak.interval > ak74.interval);
    // Subsonic and supersonic rounds (the bullet sound uses it).
    try std.testing.expect(!statsOf("SubmachineGun_1").supersonic());
    try std.testing.expect(!statsOf("AssaultRifle2_4").supersonic());
    try std.testing.expect(!statsOf("Revolver_5").supersonic());
    try std.testing.expect(statsOf("SubmachineGun_3").supersonic());
    try std.testing.expect(ak.supersonic());
}

test "damage falls off with distance" {
    for (&guns.table) |*st| {
        try std.testing.expect(st.damageAt(false, 1) == st.body);
        try std.testing.expect(st.damageAt(false, 200) <= st.damageAt(false, 20));
        try std.testing.expect(st.damageAt(false, 200) >= @round(st.body * st.min_dmg) - 1);
        try std.testing.expect(st.near < st.far);
    }
}

test "the recoil pattern climbs, sways and recovers" {
    const st = statsOf("AssaultRifle_2");
    var h: weapon.Hands = .{};
    var up: f32 = 0;
    var first: [2]f32 = undefined;
    var last: [2]f32 = undefined;
    for (0..10) |i| {
        const k = h.kickShot(st, 0.5);
        if (i == 0) first = k;
        last = k;
        up += k[0];
        // A string of shots: no recovery between automatic shots.
        const back = h.recover(st, st.interval, 0);
        try std.testing.expectEqual(0, back[0]);
    }
    // The climb grows over the string, and the side kick changes.
    try std.testing.expect(last[0] > first[0] * 1.4);
    try std.testing.expect(first[1] != last[1]);
    try std.testing.expectApproxEqAbs(up, h.kick_up, 1e-5);
    // The trigger is up: the camera goes back down to the aim.
    var back_up: f32 = 0;
    for (0..240) |_| back_up -= h.recover(st, 1.0 / 120.0, 0)[0];
    try std.testing.expectApproxEqAbs(up, back_up, up * 0.01);
    try std.testing.expectEqual(0, h.string);
}

test "a pull down against the recoil counts as recovery" {
    const st = statsOf("AssaultRifle_2");
    var h: weapon.Hands = .{};
    const k = h.kickShot(st, 0.5);
    _ = h.recover(st, 1.0 / 120.0, -k[0]);
    try std.testing.expectEqual(0, h.kick_up);
}

const Best = struct { i: usize, t: f32 };

/// The best time to kill at `dist` among the guns of a slot, and its gun.
fn best(slot: weapon.Slot, dist: f32) Best {
    var out: Best = .{ .i = 0, .t = 1e9 };
    for (&guns.table, 0..) |*st, i| {
        if (st.slot != slot) continue;
        const t = guns.ttk(st, dist) orelse continue;
        if (t < out.t) out = .{ .i = i, .t = t };
    }
    return out;
}

test "no gun is the fastest to kill at both 10 m and 40 m" {
    for ([_]weapon.Slot{ .primary, .secondary }) |slot| {
        const near = best(slot, 10);
        const far = best(slot, 40);
        try std.testing.expect(near.i != far.i);
    }
}

test "the time to kill stays in a fair band" {
    for (&guns.table) |*st| {
        if (st.pellets > 1) {
            // Buckshot kills up close, and does no damage past its reach.
            try std.testing.expect(guns.ttk(st, 5).? < 0.3);
            try std.testing.expect(guns.ttk(st, st.range + 1) == null);
        } else if (st.slot == .primary) {
            try std.testing.expect(guns.ttk(st, 10).? < 0.4);
            try std.testing.expect(guns.ttk(st, 40).? < 0.7);
        } else {
            try std.testing.expect(guns.ttk(st, 10).? < 0.65);
            try std.testing.expect(guns.ttk(st, 40).? < 1.6);
        }
    }
}

test "a long shotgun barrel keeps the buckshot deadly further" {
    const std_barrel = statsOf("Shotgun_1");
    const long = statsOf("Shotgun_2");
    try std.testing.expect(long.spread < std_barrel.spread * 0.6);
    try std.testing.expect(long.ads_tight > std_barrel.ads_tight);
    try std.testing.expect(long.range > 50);
    try std.testing.expect(guns.ttk(std_barrel, 40) == null);
    // Aimed down the sights, the long barrels kill with one shot at 20 m
    // and with two at 40 m.
    for ([_][]const u8{ "Shotgun_2", "Shotgun_3" }) |name| {
        const st = statsOf(name);
        try std.testing.expect(adsShots(st, 20) == 1);
        try std.testing.expect(adsShots(st, 40) <= 2);
    }
}

/// The shots to kill at `dist` m with buckshot, aimed down the sights.
fn adsShots(st: *const weapon.Stats, dist: f32) u32 {
    const sh = guns.pelletShare(dist, st.spread * (1 - st.ads_tight));
    const p: f32 = @floatFromInt(st.pellets);
    const per_shot = p * (sh.body * st.damageAt(false, dist) + sh.head * st.damageAt(true, dist));
    return @intFromFloat(@ceil(100 / per_shot - 1e-4));
}

test "the slug gun fires one slug: a small cone and a big hit" {
    const slug = statsOf("Shotgun_4");
    try std.testing.expectEqual(1, slug.pellets);
    try std.testing.expect(slug.spread < statsOf("Shotgun_1").spread * 0.2);
    // One body hit kills up close, and one head hit kills at 50 m.
    try std.testing.expect(slug.damageAt(false, 15) >= 100);
    try std.testing.expect(slug.damageAt(true, 50) >= 100);
}

test "a head hit from an AK kills at short range" {
    for (guns.builds, 0..) |b, i| {
        const st = &guns.table[i];
        if (guns.classOf(b.name).? == .rifle or b.calibre == .c7_62x39) {
            try std.testing.expect(st.damageAt(true, 10) >= 100);
        }
    }
}

test "the pellet share falls with the distance" {
    const a = guns.pelletShare(3, 0.06);
    const b = guns.pelletShare(10, 0.06);
    try std.testing.expect(a.body > 0.95);
    try std.testing.expect(b.body < a.body);
}
