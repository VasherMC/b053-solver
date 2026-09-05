/// BFS searcher for b023
const std = @import("std");

const brand = @import("b023.zig");

// The desired end state
// one of add, gor, lev, cif, dev, trailer
const goal_tile = brand.trailer_tile;

// Limit move depth, if a solution is known to exist within a specific move count
const MAX_DEPTH: u8 = 33;

const Board = brand.Board;
const Action = brand.Action;
const Pos = brand.Pos;
const b023 = brand.b023;
const is_duplicate = brand.is_duplicate_board;

const Item = packed struct {
    b: Board,
    p: Action,
    cant_z: bool, // precompute
};

pub fn main(init: std.process.Init) !void {
    //var gpa = std.heap.DebugAllocator(.{}){};
    const gpa = init.gpa;
    //const io = init.io;
    //const alloc = gpa.allocator();
    try run_bfs_tile(gpa);
}

/// Backtrace path through state space
fn trace_path(end: Item, last_move: Action, depth: u8, finalized: []const std.ArrayList(Item)) !void {
    std.debug.print("Found path (reversed): {c}", .{@as(u8, switch (last_move) {
        .Z => 'Z',
        .U => 'U',
        .L => 'L',
        .R => 'R',
        .D => 'D',
    })});
    defer std.debug.print("\n\n", .{});
    var cur: Item = end;
    var b = end.b;
    var d: u8 = depth;
    // trace within same tilecount (finalized)
    while (d > 0) {
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
        if (b == b023) return;
        const idx = std.sort.binarySearch(Item, finalized[d - 1].items, b, board_item_cmp).?;
        cur = finalized[d - 1].items[idx];
        d -= 1;
    }
}
fn boardCmp(a: Board, b: Board) std.math.Order {
    const aa: u58 = @bitCast(a);
    const bb: u58 = @bitCast(b);
    return if (aa == bb) .eq else if (aa < bb) .lt else .gt;
}

fn board_item_cmp(a: Board, b: Item) std.math.Order {
    const aa: u58 = @bitCast(a);
    const bb: u58 = @bitCast(b.b);
    return if (aa == bb) .eq else if (aa < bb) .lt else .gt;
}

const Timestamp = std.Io.Timestamp;

inline fn duplicate_item(a: Item, b: Item) bool {
    return is_duplicate(a.b, b.b, a.cant_z, b.cant_z);
}
fn duplicate_a_subset_of_b(a: Item, b: Item) bool {
    // if a.cant_z then every move available to A is also available to B, so A is a duplicate
    // however if A CAN z, and lower-depth visited state B can't, then A allows a new path (assuming facing is diff)
    return @as(u58, @bitCast(a.b)) ^ @as(u58, @bitCast(b.b)) < 4 and (a.b.facing == b.b.facing or a.cant_z);
}

// Used only in bucket_contains below, which searches buckets of lower move depth
fn item_compare(a: Item, b: Item) std.math.Order {
    if (duplicate_a_subset_of_b(a, b)) return .eq;
    return if (@as(u58, @bitCast(a.b)) < @as(u58, @bitCast(b.b))) .lt else .gt;
}
fn bucket_contains(bucket: std.ArrayList(Item), x: Item) bool {
    return std.sort.binarySearch(Item, bucket.items, x, item_compare) != null;
}
fn item_lessThan(_: void, a: Item, b: Item) bool {
    return (@as(u58, @bitCast(a.b)) < @as(u58, @bitCast(b.b)));
}

fn prune(result: Board, depth: u8) bool {
    // ignore if the goal state is definitely not reachable within MAX_DEPTH total steps
    return brand.heuristic(result.tiles, goal_tile) + depth > MAX_DEPTH;
}

const duplicate_stats = true;

fn run_bfs_tile(alloc: std.mem.Allocator) !void {
    //const t_start = Timestamp.now(io, .awake);
    // grouped by move depth
    // individual buckets sorted or otherwise mergeable
    var todo: std.ArrayList(Item) = .empty;
    try todo.append(alloc, .{ .b = b023, .p = .D, .cant_z = false });
    // while iterating through 'todo' we prune as well by checking finalized before inserting
    // each bucket should be fast to query by Board (at worst O(logn))
    var finalized = [_]std.ArrayList(Item){.empty} ** MAX_DEPTH;
    defer {
        for (&finalized) |*f_bucket| if (f_bucket.items.len > 0) f_bucket.deinit(alloc);
        if (todo.items.len > 0) todo.deinit(alloc);
    }
    //
    var found = false;
    for (0..MAX_DEPTH) |depth| {
        var stats_dupe_depth = if (duplicate_stats) [_]usize{0} ** MAX_DEPTH else void;
        std.debug.print("sorting and actioning depth {}\n", .{depth});
        std.sort.pdq(Item, todo.items, {}, item_lessThan);
        finalized[depth] = try .initCapacity(alloc, todo.items.len);
        item: for (todo.items, 0..) |b, i| {
            if (i + 1 < todo.items.len and duplicate_item(b, todo.items[i + 1])) {
                if (b.cant_z) todo.items[i + 1].cant_z = true;
                // ^ in this case b.facing==a.facing and using Z would result in an alraedy seen state
                if (duplicate_stats) stats_dupe_depth[0] += 1;
                continue;
            }
            // Check in previous buckets
            for (0..depth / 2) |check| {
                // only check every other move_depth for duplicate states due to parity
                const check_bucket = finalized[depth - 2 - 2 * check];
                if (bucket_contains(check_bucket, b)) {
                    if (duplicate_stats) stats_dupe_depth[check + 1] += 1;
                    continue :item;
                }
            }
            try finalized[depth].append(alloc, b); // sorted
        }
        const dupe_amt = todo.items.len - finalized[depth].items.len;
        if (duplicate_stats) std.debug.print("deduplicated at depth {}: duplicates {} / {}  ({}%)\n", .{ depth, dupe_amt, todo.items.len, dupe_amt * 100 / todo.items.len });
        if (duplicate_stats) {
            std.debug.print("Duplicate depth difference distribution:\n", .{});
            for (stats_dupe_depth, 0..) |count, i| {
                if (count > 0) std.debug.print("depth diff -{}: count {}\n", .{ i * 2, count });
            }
            std.debug.print("\n", .{});
        }
        todo.clearAndFree(alloc);
        // generate states for next depth
        for (finalized[depth].items) |b| {
            for (std.enums.values(Action)) |a| {
                if (a == .Z and b.cant_z) continue; // we already computed this so may as well use it
                if (b.b.do_action(a)) |result| {
                    if (result.tiles == goal_tile) {
                        if (result.stairs > 35) {
                            try trace_path(b, a, @intCast(depth), finalized[0 .. depth + 1]);
                            found = true;
                        }
                    } else if (prune(result, @as(u8, @intCast(depth + 1)))) continue;
                    if (depth + 1 == MAX_DEPTH) continue;
                    // We don't deduplicate here because it's unordered
                    try todo.append(alloc, .{ .b = result, .p = switch (a) {
                        .Z => .Z,
                        else => switch (b.b.facing) {
                            .U => .U,
                            .L => .L,
                            .R => .R,
                            .D => .D,
                        },
                    }, .cant_z = result.cant_Z(a) });
                }
            }
        }
        std.debug.print("Finished generating {} states at depth {}\n", .{ todo.items.len, depth + 1 });
        //if (found) break;
    }
    std.debug.print("\nDone\n", .{});
}

fn itemslice_lessThan(_: void, a: []Item, b: []Item) std.math.Order {
    if (a.len > 0 and b.len > 0) return boardCmp(a[0].b, b[0].b);
    if (a.len > 0) return .lt;
    if (b.len > 0) return .gt;
    return .eq;
}
