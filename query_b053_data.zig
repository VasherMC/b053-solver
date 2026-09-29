const std = @import("std");
const bfs = @import("bfs_b053_tile_v2.zig");

const Item = bfs.Item;
fn tan_predicate(b: Item) bool {
    return b.holding_stairs() and b.tiles == bfs.tan_tile;
}
fn eus_predicate(b: Item) bool {
    return b.holding_stairs() and b.tiles == bfs.eus_tile;
}
fn stairs_predicate(b: Item) bool {
    return b.holding_stairs();
}
test {
    std.testing.refAllDecls(@import("query_b053_data.zig"));
}

fn print_all_states(io: std.Io, dir: std.Io.Dir, tilecount: u6, depth: u16) !void {
    var buf: [20]u8 = undefined;
    const fname = try bfs.setFilenameFor(buf[0..], tilecount, @intCast(depth));
    var f = try bfs.mappedStateStream.init(io, dir, fname) orelse return;
    defer f.close(io) catch {};
    var r = f.reader();
    while (r.pop()) |item| {
        std.debug.print("{}\n", .{item});
    }
}

fn first_by_predicate(io: std.Io, dir: std.Io.Dir, tilecount: u6, comptime pred: fn (Item) bool) !?struct { depth: u16, item: Item } {
    for (0..230) |depth| {
        var buf: [20]u8 = undefined;
        const fname = try bfs.setFilenameFor(buf[0..], tilecount, @intCast(depth));
        var f = try bfs.mappedStateStream.init(io, dir, fname) orelse continue;
        defer f.close(io) catch {};
        var r = f.reader();
        while (r.pop()) |item| {
            if (pred(item)) {
                return .{ .depth = @intCast(depth), .item = item };
            }
        }
    }
    return null;
}

fn count_by_predicate(io: std.Io, dir: std.Io.Dir, tilecount: u6, comptime pred: fn (Item) bool) !usize {
    var count: usize = 0;
    for (0..230) |depth| {
        var buf: [20]u8 = undefined;
        const fname = try bfs.setFilenameFor(buf[0..], tilecount, @intCast(depth));
        var f = try bfs.mappedStateStream.init(io, dir, fname) orelse continue;
        defer f.close(io) catch {};
        var r = f.reader();
        while (r.pop()) |item| {
            if (pred(item)) {
                count += 1;
            }
        }
    }
    return count;
}

fn trace_path_to_first_matching(io: std.Io, dir: std.Io.Dir, tilecount: u6, comptime pred: fn (Item) bool) !void {
    const result = try first_by_predicate(io, dir, tilecount, pred) orelse {
        std.debug.print("Couldn't find any matching end state; are files available?\n", .{});
        return;
    };
    try bfs.trace_path_files(io, dir, result.item, result.depth);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const dir = try std.Io.Dir.cwd().openDir(io, "b053-data", .{ .iterate = true });
    std.debug.print("path to Eus (reversed): ", .{});
    try trace_path_to_first_matching(io, dir, bfs.eus_tot, eus_predicate);
    //try print_all(io, dir, 21, 230);
    //try print_all(io, dir, 21, 231);
    std.debug.assert(@popCount(bfs.tan_tile) == 21);
    std.debug.print("searching for tan's brand in tilecount 21\n", .{});
    const result = try first_by_predicate(io, dir, 21, tan_predicate);
    std.debug.print("result of search: {any}\n", .{result}); // null (runs in about 4m30s)
}
