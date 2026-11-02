//! A delegate that gives each visitor a stable id for the counter: 16 hex
//! chars, created once and kept in the delegate's secrets on the visitor's
//! own node. (Freenet pages run in a sandbox without `localStorage`, so the
//! page can't remember it itself.)
//!
//! Any site on the node could message this delegate, so it first checks that
//! the message comes from the counter app itself (`d.requireApp()`). The
//! build gives the delegate the app's id as its parameters.

const std = @import("std");
const freenet = @import("freenet");

comptime {
    freenet.exportDelegate(@This());
}

const secret_key = "visitor-id";

pub fn handle(d: *freenet.Delegate, msg: freenet.Inbound) !void {
    const app = switch (msg) {
        .application => |a| a,
        else => return, // prompt answers, lifecycle events, ...
    };
    try d.requireApp();
    if (!std.mem.eql(u8, app.payload, "id")) return d.fail("unknown request (send \"id\")");

    const secrets = d.secrets();
    if (try secrets.get(secret_key)) |id| return d.reply(id);

    var raw: [8]u8 = undefined;
    try freenet.random.bytes(&raw);
    const id = try d.allocator.dupe(u8, &std.fmt.bytesToHex(raw, .lower));
    try secrets.set(secret_key, id);
    try d.reply(id);
}

// ---- tests ----------------------------------------------------------------

const t = freenet.testing;
const testing = std.testing;

/// The default test origin is the web app with id 7×32; a real build sets the
/// parameters to the app's id.
const app_id: [32]u8 = @splat(7);

test "an id is created once and then kept" {
    t.reset();
    const first = (try t.ask(@This(), "id", .{ .parameters = &app_id }))[0];
    try testing.expectEqual(@as(usize, 16), first.len);
    try testing.expectEqualStrings(first, (try t.ask(@This(), "id", .{ .parameters = &app_id }))[0]);
}

test "other sites and unconfigured delegates are refused" {
    t.reset();
    const msg: freenet.Inbound = .{ .application = .{ .payload = "id" } };
    const other_site = try t.send(@This(), msg, .{ .parameters = &app_id, .origin = .{ .web_app = @splat(8) } });
    try testing.expectEqualStrings("this delegate only answers its own web app", other_site.err);
    const no_parameters = try t.send(@This(), msg, .{});
    try testing.expectEqualStrings("this delegate only answers its own web app", no_parameters.err);
    try testing.expect(t.secret("visitor-id") == null); // nothing was created for them
}
