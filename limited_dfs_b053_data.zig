const std = @import("std");
const bfs = @import("bfs_b053_tile_v2.zig");

const MIN_TILES = 17; // 18 (19) for Bee, 17 (18) for Add
const start_tiles = 20; // start with a breaking move from here
const Item = bfs.Item;
fn add_predicate(b: Item) bool {
    return b.holding_stairs() and b.tiles == bfs.brand.add_tile;
}
fn bee_predicate(b: Item) bool {
    return b.holding_stairs() and b.tiles == bfs.brand.bee_tile;
}
test {
    std.testing.refAllDecls(@import("limited_dfs_b053_data.zig"));
}

fn print_char(a: bfs.brand.Action) void {
    std.debug.print("{c}", .{@as(u8, switch (a) {
        .U => 'U',
        .L => 'L',
        .R => 'R',
        .D => 'D',
        .Z => 'Z',
    })});
}

// need to make sure we don't go in a circle
fn dfs(item: Item, alloc: std.mem.Allocator, tilecount: u6, depth: u16, seen: *std.ArrayList(Item)) !bool {
    if (add_predicate(item)) return true; // we can terminate (base case)
    if (bee_predicate(item)) return true;
    // recurse
    for (std.enums.values(bfs.brand.Action)) |a| {
        if (item.do_action_breaking(a, tilecount)) |break_a| {
            if (tilecount == MIN_TILES) continue; // would be breaking too many
            // directed edge, can't be a cycle
            try seen.append(alloc, break_a);
            defer _ = seen.pop();
            if (try dfs(break_a, alloc, tilecount - 1, depth + 1, seen)) {
                // found
                print_char(a);
                return true;
            }
        } else if (item.do_action_nonbreaking(a, tilecount)) |nobreak_a| {
            if (std.mem.findScalar(Item, seen.items, nobreak_a)) |_| continue;
            try seen.append(alloc, nobreak_a);
            defer _ = seen.pop();
            if (try dfs(nobreak_a, alloc, tilecount, depth + 1, seen)) {
                // found
                print_char(a);
                return true;
            }
        }
    }
    return false;
}

fn dfs_main(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, tilecount: u6, depth: u16) !void {
    var buf: [20]u8 = undefined;
    const fname = try bfs.setFilenameFor(buf[0..], tilecount, @intCast(depth));
    var f = try bfs.mappedStateStream.init(io, dir, fname) orelse return;
    defer f.close(io) catch {};
    var r = f.reader();
    var prev: Item = @bitCast(@as(u68, 0));
    var arr: std.ArrayList(Item) = .empty;
    while (r.pop()) |item| : (prev = item) {
        if (bfs.equal_mod_facing(item, prev)) continue;
        for (std.enums.values(bfs.brand.Action)) |a| if (a != .Z) if (item.do_action_breaking(a, tilecount)) |start_point| if (try dfs(start_point, alloc, tilecount - 1, depth + 1, &arr)) {
            std.debug.print("DFS returned: found\n", .{});
            std.debug.print("Start state: {} move {}\n", .{ item, a });
            try bfs.trace_path_files(io, dir, item, depth);
        };
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const dir = try std.Io.Dir.cwd().openDir(io, "b053-data", .{ .iterate = true });
    for (0..250) |depth| {
        std.debug.print("running DFS from tc {} depth {}\n", .{ start_tiles, depth });
        try dfs_main(io, dir, init.gpa, start_tiles, @intCast(depth));
    }
}
