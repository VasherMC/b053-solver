const std = @import("std");
const bfs = @import("bfs_b053_tile_v2.zig");

// Extract all states holding stairs from b053-data (ie, carvable brands)
// and deduplicate by lowest depth (to avoid multiple states for the same brand)

const Item = bfs.Item;
test {
    std.testing.refAllDecls(@import("stairs.zig"));
}

fn print_all(io: std.Io, dir: std.Io.Dir, tilecount: u6, depth: u16) !void {
    var buf: [20]u8 = undefined;
    const fname = try bfs.setFilenameFor(buf[0..], tilecount, @intCast(depth));
    var f = try bfs.mappedStateStream.init(io, dir, fname) orelse return;
    defer f.close(io) catch {};
    var r = f.reader();
    while (r.pop()) |item| {
        std.debug.print("{}\n", .{item});
    }
}

fn collect_stairs(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, tilecount: u6) !usize {
    var stairs: [230]std.ArrayList(u35) = @splat(.empty);
    for (0..230) |depth| {
        var buf: [20]u8 = undefined;
        const fname = try bfs.setFilenameFor(buf[0..], tilecount, @intCast(depth));
        var f = try bfs.mappedStateStream.init(io, dir, fname) orelse continue;
        var r = f.reader();
        while (r.pop()) |item| {
            if (item.holding_stairs()) {
                const t = item.tiles;
                for (0..depth / 2) |d| {
                    const d2 = depth - 2 - 2 * d;
                    if (std.sort.binarySearch(u35, stairs[d2].items, t, order_u35) != null) break;
                } else try stairs[depth].append(alloc, t);
            }
        }
        f.close(io) catch {};
        std.sort.pdq(u35, stairs[depth].items, {}, lessthan_u35);
        // do the same-depth pass after sorting
        var write_i: usize = 0;
        for (stairs[depth].items, 0..) |s, read_i| {
            if (read_i + 1 < stairs[depth].items.len and s == stairs[depth].items[read_i + 1]) continue;
            stairs[depth].items[write_i] = s;
            write_i += 1;
        }
        stairs[depth].shrinkAndFree(alloc, write_i);
        std.debug.print("{} brands at depth {}\n", .{ write_i, depth });
    }
    // write all the states to a file
    var fnamebuf: [20]u8 = undefined;
    const out_fname = try std.fmt.bufPrint(&fnamebuf, "{}.stairs", .{tilecount});
    var file = try dir.createFile(io, out_fname, .{});
    var writebuf: [1024]u8 = undefined;
    var w = file.writer(io, writebuf[0..]);
    for (stairs, 0..) |arr, depth| try writeStairsDepth(&w, @intCast(depth), arr.items);
    try w.end();
    file.close(io);
    //
    //var total: std.ArrayList(u35) = .empty;
    //for (stairs) |arr| {
    //   try total.appendSlice(alloc, arr.items);
    //}
    //std.sort.pdq(u35, total.items, {}, lessthan_u35);
    //
    for (&stairs) |*arr| arr.deinit(alloc);
    return 0;
}

const native_endian = @import("builtin").cpu.arch.endian();

fn writeStairsDepth(w: *std.Io.File.Writer, depth: u16, stairs: []u35) !void {
    // Format: 5 bytes depth, 5 bytes length (count of brands at this depth), <length> 5-byte brands
    if (native_endian != .little) @compileError("Not implemented yet for big-endian");
    if (stairs.len == 0) return;
    try w.interface.writeAll(std.mem.toBytes(@as(u40, @intCast(depth)))[0..5]);
    try w.interface.writeAll(std.mem.toBytes(@as(u40, @intCast(stairs.len)))[0..5]);
    for (stairs) |s| try w.interface.writeAll(std.mem.toBytes(s)[0..5]);
}

fn order_u35(a: u35, b: u35) std.math.Order {
    return std.math.order(a, b);
}
fn lessthan_u35(ctx: void, a: u35, b: u35) bool {
    _ = ctx;
    return a < b;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const dir = try std.Io.Dir.cwd().openDir(io, "b053-data", .{ .iterate = true });
    for (21..32) |tilecount| {
        _ = try collect_stairs(init.gpa, io, dir, @intCast(tilecount));
    }
}
