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
    //try run_bfs_tile(gpa);
    try best_first_search(gpa);
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
    return brand.heuristic2(result, goal_tile) + depth > MAX_DEPTH;
}

const duplicate_stats = false;

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
        var stats_dupe_depth = if (duplicate_stats) [_]usize{0} ** MAX_DEPTH else {};
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
        if (todo.items.len == 0) break;
    }
    std.debug.print("\nDone\n", .{});
}

const min_heuristic = brand.heuristic2(b023, goal_tile);

/// Backtrace path through state space
fn trace_path_2(end: Item, last_move: Action, depth: u8, finalized: []const [MAX_DEPTH]std.ArrayList(Item)) !void {
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
        const hd = (d - 1) + brand.heuristic2(b, goal_tile) - min_heuristic;
        const idx = std.sort.binarySearch(Item, finalized[hd][d - 1].items, b, board_item_cmp).?;
        cur = finalized[hd][d - 1].items[idx];
        d -= 1;
    }
}

fn best_first_search(alloc: std.mem.Allocator) !void {
    // grouped by heuristic (minimum total moves remaining) and move depth
    // we take `depth + brand.heuristic2(b, goal) - brand.heuristic2(start, goal)` and `depth`
    // (with the first number equivalently representing 'moves executed not required by the heuristic')
    // and prioritize exploring states with lower heuristic
    // starting state is put in bucket (0,0)
    //   if we can make a move that moves toward the solution it goes in (0, 1)
    //          (move depth increased, heuristic decreased)
    //   otherwise it goes in (1,1) (heuristic same) or (2,1) (heuristic increased)
    // next iteration: we go through (0,1)
    // once (0,X) are all empty: go through (1,X); then (2,X), etc
    // suppose we come across state b in (4, D); it could be a duplicate of a state in any of:
    //     (2,D-2) or (0,D-4)
    // or if b.cant_Z(), a state with different facing in (1, D-2) or (3,D-2) or (1, D-4)
    //
    // Instead of generating states and placing them in the appropriate bucket (push model):
    // when we reach the bucket, we go look at all parents that could generate a state in the bucket,
    // generate all child states and filter to the appropriate ones (pull model)
    //  -> this means we do 3x the work in generating states
    //  -> but reduces memory fragmentation to near-zero
    //  -> and significantly reduces the number of duplicate states stored at any given time from O(B*D) to O(B)
    const Extra_Move_limit = MAX_DEPTH;
    var finalized: [Extra_Move_limit][MAX_DEPTH]std.ArrayList(Item) =
        [_][MAX_DEPTH]std.ArrayList(Item){@splat(std.ArrayList(Item).empty)} ** Extra_Move_limit;
    try finalized[0][0].append(alloc, .{ .b = b023, .p = .D, .cant_z = false });
    defer {
        for (finalized[0..]) |*f_bucket| for (f_bucket[0..]) |*bucket| if (bucket.items.len > 0) bucket.deinit(alloc);
    }
    //
    var found = false;
    for (finalized[0..], 0..) |*hgroup, hdiff| {
        var seen_nonempty: bool = false;
        for (hgroup[1..], 1..) |*todo, depth| {
            // generate states from parents  (pull model)
            const parent_hd_min = hdiff -| 2;
            const parent_hd_max = hdiff;
            for (finalized[parent_hd_min .. parent_hd_max + 1]) |parents| {
                if (depth == 0) continue; // only depth 0 state already generated
                for (parents[depth - 1].items) |b| {
                    // parent `b` at depth d-1 has child `result` at depth `d`
                    for (std.enums.values(Action)) |a| {
                        if (a == .Z and b.cant_z) continue; // we already computed this so may as well use it
                        if (b.b.do_action(a)) |result| {
                            if (result.tiles == goal_tile) {
                                if (result.stairs > 35) {
                                    try trace_path_2(b, a, @intCast(depth - 1), finalized[0..]);
                                    found = true;
                                }
                            } else if (prune(result, @as(u8, @intCast(depth)))) continue;
                            if (depth == MAX_DEPTH) continue;
                            const h = brand.heuristic2(result, goal_tile);
                            const hd = depth + h - min_heuristic;
                            if (hd != hdiff) continue;
                            // We don't deduplicate yet because it's unordered
                            const item = Item{ .b = result, .p = switch (a) {
                                .Z => .Z,
                                else => switch (b.b.facing) {
                                    .U => .U,
                                    .L => .L,
                                    .R => .R,
                                    .D => .D,
                                },
                            }, .cant_z = result.cant_Z(a) };
                            try todo.append(alloc, item);
                        }
                    }
                }
            }
            if (todo.items.len == 0 and seen_nonempty) break;
            if (todo.items.len == 0) continue;
            seen_nonempty = true;
            var stats_dupe_depth = if (duplicate_stats) [_]usize{0} ** MAX_DEPTH else {};
            std.debug.print("hdiff {} depth {}: generated {} states\n", .{ hdiff, depth, todo.items.len });
            std.sort.pdq(Item, todo.items, {}, item_lessThan);
            var dedup: std.ArrayList(Item) = try .initCapacity(alloc, todo.items.len / 2);
            item: for (todo.items, 0..) |b, i| {
                if (i + 1 < todo.items.len and duplicate_item(b, todo.items[i + 1])) {
                    if (b.cant_z) todo.items[i + 1].cant_z = true;
                    // ^ in this case b.facing==a.facing and using Z would result in an alraedy seen state
                    if (duplicate_stats) stats_dupe_depth[0] += 1;
                    continue;
                }
                const h = brand.heuristic2(b.b, goal_tile);
                std.debug.assert((depth + h - min_heuristic) == hdiff);
                // Check in previous buckets
                for (0..depth / 2) |check| {
                    // only check every other move_depth for duplicate states due to parity
                    const check_depth = depth - 2 - 2 * check;
                    const hd_min = hdiff -| (3 + 2 * check);
                    const hd_max = hdiff -| (2 * check);
                    for (finalized[hd_min..hd_max]) |check_hd| {
                        if (bucket_contains(check_hd[check_depth], b)) {
                            // TODO duplicate stats for (hdiff - check_hd)
                            if (duplicate_stats) stats_dupe_depth[check + 1] += 1;
                            continue :item;
                        }
                    }
                }
                try dedup.append(alloc, b); // sorted
            }
            const dupe_amt = todo.items.len - dedup.items.len;
            std.debug.print("hdiff {} depth {}: done sort+dedup, duplicates {} / {}  ({}%)\n", .{ hdiff, depth, dupe_amt, todo.items.len, dupe_amt * 100 / todo.items.len });
            if (duplicate_stats) {
                std.debug.print("Duplicate depth difference distribution:\n", .{});
                for (stats_dupe_depth, 0..) |count, i| {
                    if (count > 0) std.debug.print("depth diff -{}: count {}\n", .{ i * 2, count });
                }
                std.debug.print("\n", .{});
            }
            todo.deinit(alloc);
            try dedup.shrinkToLen(alloc);
            todo.* = dedup; // now finalized
            // No longer generate states for next depth here (push model)
            //var st_hd = [3]usize{ 0, 0, 0 }; // stats: track by heuristic difference
            //for (dedup.items) |b| {
            //    for (std.enums.values(Action)) |a| {
            //        if (a == .Z and b.cant_z) continue; // we already computed this so may as well use it
            //        if (b.b.do_action(a)) |result| {
            //            if (result.tiles == goal_tile) {
            //                if (result.stairs > 35) {
            //                    try trace_path_2(b, a, @intCast(depth), finalized[0..]);
            //                    found = true;
            //                }
            //            } else if (prune(result, @as(u8, @intCast(depth + 1)))) continue;
            //            if (depth + 1 == MAX_DEPTH) continue;
            //            // We don't deduplicate here because it's unordered
            //            const item = Item{ .b = result, .p = switch (a) {
            //                .Z => .Z,
            //                else => switch (b.b.facing) {
            //                    .U => .U,
            //                    .L => .L,
            //                    .R => .R,
            //                    .D => .D,
            //                },
            //            }, .cant_z = result.cant_Z(a) };
            //            const h = brand.heuristic2(result, goal_tile);
            //            const hd = depth + 1 + h - min_heuristic;
            //            std.debug.assert(hd >= hdiff);
            //            std.debug.assert(hd - hdiff <= 2);
            //            if (hd < finalized.len) {
            //                st_hd[hd - hdiff] += 1;
            //                try finalized[hd][depth + 1].append(alloc, item);
            //            }
            //        }
            //    }
            //}
            //std.debug.print("Finished generating {} children at depth {} ({},{},{})\n", .{ st_hd[0] + st_hd[1] + st_hd[2], depth + 1, st_hd[0], st_hd[1], st_hd[2] });
        }
        if (found) break;
    }
    std.debug.print("\nDone\n", .{});
}
