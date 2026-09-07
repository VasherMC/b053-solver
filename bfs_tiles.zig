/// BFFS (breadth first frontier search?) searcher for b053
/// where the 'frontier' is the number of tiles remaining on the board
/// Goes in batches by tilecount; discards higher tilecounts after exploring
/// within-tilecount is regular BFS
const std = @import("std");

pub const wings = false;
const brand = @import("brand.zig");

// Limit move depth, if a solution is known to exist within a specific move count
const MAX_DEPTH: usize = 512; // >512 can't be serialized in u8

// exit after exploring all states with this number of tiles
const MIN_TILES: u6 = tan_tot;

const pruning: bool = false; // disable pruning, explore full state space

const Board = brand.Board;
const Action = brand.Action;
const Pos = brand.Pos;
const b053 = brand.b053;
const is_duplicate = brand.is_duplicate_board;
const tan_tot = brand.tan_tot;
const tan_tile = brand.tan_tile;
const eus_tot = brand.eus_tot;
const eus_tile = brand.eus_tile;

const Item = packed struct {
    b: Board,
    d: u16,
    p: Action,
    cant_z: bool, // precompute
};

const check_solution = brand.check_solution;

pub fn main(init: std.process.Init) !void {
    //var gpa = std.heap.DebugAllocator(.{}){};
    const gpa = init.gpa;
    const io = init.io;
    //const alloc = gpa.allocator();
    try run_bfs_tile(gpa, io, b053.tileCount());
}

const file_format = struct {
    // Seekable format
    const PAGE_SIZE = 4096; // FRAME_SIZE

    const page_header = packed struct {
        remaining_pages: u64,
        cum_items: u64,
        items: u16,
        bytes: u16,
    };
    const data_page = struct {
        h: page_header,
        data: [PAGE_SIZE - @sizeOf(page_header)]u8, // compressedStream
    };
    data: []data_page,
    total_items: u64,
    move_depth: []u8,
    prevs: []u8, // packed 3/byte
};
const native_endian = @import("builtin").cpu.arch.endian();

const compressedStream8 = @import("bfs_move.zig").compressedStream8;

fn openFileFor(io: std.Io, tilecount: u6) !std.Io.File {
    var buf: [20]u8 = undefined;
    return std.Io.Dir.cwd().openFile(io, try std.fmt.bufPrint(&buf, "{d}.data", .{tilecount}), .{ .mode = .read_only });
}

fn search_file(io: std.Io, file: std.Io.File, pagecount: u64, b: Board) !?u64 {
    // binary search pages
    var buf: [4096]u8 = undefined;
    var r = file.reader(io, &buf);
    _ = try binary_search_pages(&r, pagecount, b);
    const hdr = try r.interface.peekStruct(file_format.page_header, native_endian);
    if (true) return null;
    var i: u64 = hdr.cum_items;
    while (r.pop()) |candidate| : (i += 1) {
        if (b == candidate) return i;
    }
    return null;
}

/// Backtrace path through state space
fn trace_path_files(io: std.Io, end: Item, finalized: []const std.ArrayList(Item)) !void {
    defer std.debug.print("\n\n", .{});
    var cur: Item = end;
    var b = end.b;
    // trace within same tilecount (finalized)
    while (b.tileCount() == cur.b.tileCount()) {
        std.debug.print("{c}", .{@as(u8, switch (cur.p) {
            .Z => 'Z',
            else => switch (cur.b.facing) {
                .U => 'U',
                .L => 'L',
                .R => 'R',
                .D => 'D',
            },
        })});
        b = cur.b.reverse(cur.p);
        if (b == b053) return;
        if (b.tileCount() == cur.b.tileCount()) {
            // parent should be in `finalized[depth-1]`
            const idx = std.sort.binarySearch(Item, finalized[cur.d - 1].items, b, board_item_cmp).?;
            cur = finalized[cur.d - 1].items[idx];
        }
    }
    std.debug.print("searching files for state: {}\n", .{b});
    var tiles = b.tileCount();
    var file = try openFileFor(io, tiles);
    defer file.close(io);
    var readbuf: [1024]u8 = undefined;
    var read = file.reader(io, &readbuf);
    var total_pages = try read.interface.peekInt(u64, native_endian);
    var offsetEnd = total_pages * file_format.PAGE_SIZE;
    try read.seekTo(offsetEnd);
    var total_items = try read.interface.peekInt(u64, native_endian);
    while (b != b053) {
        const idx = try search_file(io, file, total_pages, b) orelse @panic("Couldn't find state in visited set");
        const last_action_offset = total_pages * file_format.PAGE_SIZE + 8 + total_items + @divFloor(idx, 3);
        // reset reader
        try read.seekTo(last_action_offset);
        const byte: u8 = try read.interface.peekInt(u8, native_endian);
        const last_action: Action = @enumFromInt(switch (idx % 3) {
            0 => @divFloor(byte, 25),
            1 => @divFloor(byte, 5) % 5,
            2 => byte % 5,
            else => unreachable,
        });
        std.debug.print("{c}", .{@as(u8, switch (last_action) {
            .Z => 'Z',
            else => switch (b.facing) {
                .U => 'U',
                .L => 'L',
                .R => 'R',
                .D => 'D',
            },
        })});
        const r = b.reverse(last_action);
        if (r.tileCount() > b.tileCount()) {
            file.close(io);
            //
            tiles = r.tileCount();
            file = try openFileFor(io, tiles);
            total_pages = try read.interface.peekInt(u64, native_endian);
            offsetEnd = total_pages * file_format.PAGE_SIZE;
            try read.seekTo(offsetEnd);
            total_items = try read.interface.peekInt(u64, native_endian);
        }
        b = r; // r[1] orelse r[0].?;
    }
}
fn boardCmp(a: Board, b: Board) std.math.Order {
    const aa: u80 = @bitCast(a);
    const bb: u80 = @bitCast(b);
    return if (aa == bb) .eq else if (aa < bb) .lt else .gt;
}

fn board_item_cmp(a: Board, b: Item) std.math.Order {
    const aa: u80 = @bitCast(a);
    const bb: u80 = @bitCast(b.b);
    return if (aa == bb) .eq else if (aa < bb) .lt else .gt;
}

/// Rather than returning null like std.sort.binarySearch,
/// returns the largest index such that needle =>items[idx]
/// this is where you would insert the needle
fn binary_search_pages(
    reader: *std.Io.File.Reader,
    pages: usize,
    needle: Board,
) !usize {
    var low: usize = 0;
    var high: usize = pages + 1;

    // invariant: needle position < high
    // invariant: needle position >= low
    while (low + 1 < high) {
        // Avoid overflowing in the midpoint calculation
        const mid = low + (high - low) / 2;
        // file read
        try reader.seekTo(file_format.PAGE_SIZE * mid + 20);
        const haystack_mid: Board = try reader.interface.peekStruct(Board, native_endian);
        switch (boardCmp(needle, haystack_mid)) {
            .eq => return mid,
            .gt => low = mid,
            .lt => high = mid,
        }
    }
    std.debug.assert(low + 1 == high);
    try reader.seekTo(file_format.PAGE_SIZE * low);
    return low;
}

const Timestamp = std.Io.Timestamp;

inline fn duplicate_item_uncached(a: Item, b: Item) bool {
    return is_duplicate(a.b, b.b, a.p, b.p);
}
fn duplicate_item(a: Item, b: Item) bool {
    return @as(u80, @bitCast(a.b)) ^ @as(u80, @bitCast(b.b)) < 4 and (a.b.facing == b.b.facing or (a.cant_z and b.cant_z));
}
fn duplicate_a_subset_of_b(a: Item, b: Item) bool {
    // a.d >= b.d
    if (a.d < b.d) unreachable;
    // if a.cant_z then every move available to A is also available to B, so A is a duplicate
    // however if A CAN z, and lower-depth visited state B can't, then A allows a new path (assuming facing is diff)
    return @as(u80, @bitCast(a.b)) ^ @as(u80, @bitCast(b.b)) < 4 and (a.b.facing == b.b.facing or a.cant_z);
}

// Used only in bucket_contains below, which searches buckets of lower move depth
fn item_compare(a: Item, b: Item) std.math.Order {
    if (duplicate_a_subset_of_b(a, b)) return .eq;
    return if (@as(u80, @bitCast(a.b)) < @as(u80, @bitCast(b.b))) .lt else .gt;
}
fn bucket_contains(bucket: std.ArrayList(Item), x: Item) bool {
    return std.sort.binarySearch(Item, bucket.items, x, item_compare) != null;
}
fn item_lessThan(_: void, a: Item, b: Item) bool {
    return (@as(u80, @bitCast(a.b)) < @as(u80, @bitCast(b.b)));
}

fn prune(result: Board) bool {
    // rough heuristic that we don't want to walk on these tiles
    // so we can exclude these states entirely (not even in visited set) to save storage
    if (result.gray == 0 or result.gray == 3 or result.gray == 4 or result.gray == 5 or result.gray == 10 or result.gray == 11 or result.gray == 16 or result.gray == 34 or result.gray == 29) return true;
    // can't deduplicate facing here because we dont know which states are possible to backtrack from
    // Heuristic: we need to fill missing tiles
    // assume that we need to break at least 1 glass to place each missing tile
    // - If we have a raft, we need to break glass tiles to place off that row/column
    // - If we don't have a raft, we also need to break glass tiles to place further
    // - We also likely need to break glass just to pickup tiles needing to be moved
    // - So the ideal situation (where we can just move glass from too-full areas to empty areas)
    //   doesn't really exist (exception for pocket tile, maybe also current-facing
    // so true required tiles is is higher (though this is heuristic so we leave buffer)
    // If this is 21 + 1x missing-tiles, search completes in ~2m
    // dropping down to 21 + 2/3x, takes 16m to complete at depth 169
    //   -> This means that any successful TAN solution
    //      would at some point be in a situation where it could fill all remaining gaps
    //      without breaking as many glass tiles as it is moving
    //TODO
    //if (tilecount < 21 + (2 * @popCount(tan_tile & ~result.tiles) / 3)) continue;
    return false;
}

const duplicate_stats = true;

// Quite slow: even when limiting move depth; takes 2m to find solution for Eus
fn run_bfs_tile(alloc: std.mem.Allocator, io: std.Io, start_tiles: u6) !void {
    //const t_start = Timestamp.now(io, .awake);
    // grouped by move depth
    // individual buckets sorted or otherwise mergeable
    var todo = [_]std.ArrayList(Item){.empty} ** MAX_DEPTH;
    var todo_len: usize = 0;
    var tiles: u6 = start_tiles;
    if (start_tiles == b053.tileCount()) {
        try todo[0].append(alloc, .{ .b = b053, .d = 0, .p = .Z, .cant_z = false });
        todo_len = 1;
    } else {
        const file = try openFileFor(io, start_tiles);
        // TODO: for each item in the file, add glassbreaking moves to `todo`
        _ = file;
        @panic("not implemented");
    }
    // while iterating through 'todo' we prune as well by checking finalized before inserting
    // each bucket should be fast to query by Board (at worst O(logn))
    var finalized = [_]std.ArrayList(Item){.empty} ** MAX_DEPTH;
    var total_len: usize = 0;
    defer {
        for (&finalized) |*f_bucket| if (f_bucket.items.len > 0) f_bucket.deinit(alloc);
        for (&todo) |*t_bucket| if (t_bucket.items.len > 0) t_bucket.deinit(alloc);
    }
    //
    //var over_100 = false;
    while (tiles >= MIN_TILES) {
        var processed: usize = 0;
        var stats_dupe_depth = if (duplicate_stats) [_]usize{0} ** MAX_DEPTH else void;
        for (&todo, 0..todo.len) |*todo_bucket, depth| {
            if (todo_bucket.items.len == 0) continue;
            std.debug.print("sorting and actioning depth {}\n", .{depth});
            std.sort.pdq(Item, todo_bucket.items, {}, item_lessThan);
            processed += todo_bucket.items.len;
            // most depth buckets past the first few have ~40% duplicates
            finalized[depth] = try .initCapacity(alloc, todo_bucket.items.len * 60 / 100);
            var dupe_amt: usize = 0;
            item: for (todo_bucket.items, 0..) |b, i| {
                //if (b.d == 113 and !over_100) {
                //    over_100 = true;
                //    std.debug.print("state with depth 113: {}, prev {}\n", .{ b.b, b.p });
                //}
                if (tiles == tan_tot and b.b.pocket == .Stairs and b.b.tiles == tan_tile) {
                    try trace_path_files(io, b, finalized[0..depth]);
                    return;
                }
                if (tiles == eus_tot and b.b.pocket == .Stairs and b.b.tiles == eus_tile) {
                    try trace_path_files(io, b, finalized[0..depth]);
                    return;
                }
                if (i + 1 < todo_bucket.items.len and duplicate_item(b, todo_bucket.items[i + 1])) {
                    if (b.cant_z) todo_bucket.items[i + 1].cant_z = true;
                    // ^ in this case b.facing==a.facing and using Z would result in an alraedy seen state
                    if (duplicate_stats) stats_dupe_depth[0] += 1;
                    if (duplicate_stats) dupe_amt += 1;
                    continue;
                }
                // Check in previous buckets
                for (0..depth / 2) |check| {
                    // only check every other move_depth for duplicate states due to parity
                    const check_bucket = finalized[depth - 2 - 2 * check];
                    if (bucket_contains(check_bucket, b)) {
                        if (duplicate_stats) stats_dupe_depth[check + 1] += 1;
                        if (duplicate_stats) dupe_amt += 1;
                        continue :item;
                    }
                }
                try finalized[depth].append(alloc, b); // sorted
                if (depth + 1 == MAX_DEPTH) continue;
                for (std.enums.values(Action)) |a| {
                    if (a == .Z and b.cant_z) continue; // we already computed this so may as well use it
                    if (b.b.do_action(a)) |result| {
                        if (result.tileCount() == tiles) {
                            if (pruning and prune(result)) continue;
                            // We don't deduplicate here because it's unordered
                            try todo[depth + 1].append(alloc, .{ .b = result, .d = @intCast(depth + 1), .p = switch (a) {
                                .Z => .Z,
                                else => switch (b.b.facing) {
                                    .U => .U,
                                    .L => .L,
                                    .R => .R,
                                    .D => .D,
                                },
                            }, .cant_z = !result.can_Z(a) });
                        }
                    }
                }
            }
            if (duplicate_stats) std.debug.print("  dupe amount: {} / {}  ({}%)\n", .{ dupe_amt, todo_bucket.items.len, dupe_amt * 100 / todo_bucket.items.len });
            todo_bucket.clearAndFree(alloc);
        }
        total_len = 0;
        for (finalized) |f_bucket| total_len += f_bucket.items.len;
        std.debug.print("Finished generating {} states with {} tiles\n", .{ total_len, tiles });
        // About >50% are duplicates
        std.debug.print("(processed {}, pruned {} duplicates)\n", .{ processed, processed - total_len });
        // some stats
        if (duplicate_stats) {
            std.debug.print("Duplicate depth difference distribution:\n", .{});
            for (stats_dupe_depth, 0..) |count, i| {
                if (count > 0) std.debug.print("depth diff -{}: count {}\n", .{ i * 2, count });
            }
            std.debug.print("\n", .{});
        }
        // Merge all finalized runs together for output so they are no longer sorted by depth first
        //std.debug.print("merging\n", .{});
        //const merge_start = Timestamp.now(io, .awake);
        var out_depths: std.ArrayList(u8) = try .initCapacity(alloc, total_len);
        var out_parents: std.ArrayList(u8) = try .initCapacity(alloc, @divFloor(total_len + 2, 3));
        var pq: std.PriorityQueue([]Item, void, itemslice_lessThan) = .empty;
        defer out_depths.deinit(alloc);
        defer out_parents.deinit(alloc);
        defer pq.deinit(alloc);
        for (finalized) |f_bucket| if (f_bucket.items.len > 0) try pq.push(alloc, f_bucket.items);
        for (0..total_len) |i| {
            const val = pq.items[0][0];
            // TODO append state to compress stream
            out_depths.appendAssumeCapacity(@as(u8, @intCast(val.d / 2)));
            switch (i % 3) {
                0 => out_parents.appendAssumeCapacity(@as(u8, @intFromEnum(val.p)) * 25),
                1 => out_parents.items[out_parents.items.len - 1] += @as(u8, @intFromEnum(val.p)) * 5,
                2 => out_parents.items[out_parents.items.len - 1] += @intFromEnum(val.p),
                else => unreachable,
            }
            if (pq.items[0].len == 1) {
                _ = pq.pop();
            } else try pq.update(pq.items[0], pq.items[0][1..]);
            // really what we want is just pq.siftDown(0)
        }
        std.debug.assert(pq.items.len == 0);
        //const t_dur = t_start.untilNow(io, .awake).toNanoseconds();
        std.debug.print("Finished serializing {} states with {} tiles\n", .{ total_len, tiles });
        // TODO: write to file
        std.debug.print("not writing to file\n", .{});
        // now go through finalized and generate new todos
        if (tiles == MIN_TILES) break;
        todo_len = 0;
        for (finalized[0 .. MAX_DEPTH - 1], 0..) |*f_bucket, depth| {
            if (f_bucket.items.len == 0) continue;
            for (f_bucket.items) |item| {
                for ([4]Action{ .U, .L, .R, .D }) |a| {
                    if (item.b.do_action(a)) |result| {
                        if (result.tileCount() > tiles) unreachable;
                        if (result.tileCount() < tiles - 1) unreachable;
                        if (result.tileCount() == tiles - 1) {
                            if (pruning and prune(result)) continue;
                            try todo[depth + 1].append(alloc, .{ .b = result, .d = @intCast(depth + 1), .p = switch (a) {
                                .Z => .Z,
                                else => switch (item.b.facing) {
                                    .U => .U,
                                    .L => .L,
                                    .R => .R,
                                    .D => .D,
                                },
                            }, .cant_z = !result.can_Z(a) });
                        }
                    }
                }
            }
            f_bucket.clearAndFree(alloc);
            todo_len += todo[depth + 1].items.len;
        }
        tiles -= 1;
        std.debug.print("\nfinished generating initial {} states for {} tiles\n", .{ todo_len, tiles });
    }
    std.debug.print("\nDone\n", .{});
}

fn itemslice_lessThan(_: void, a: []Item, b: []Item) std.math.Order {
    if (a.len > 0 and b.len > 0) return boardCmp(a[0].b, b[0].b);
    if (a.len > 0) return .lt;
    if (b.len > 0) return .gt;
    return .eq;
}
