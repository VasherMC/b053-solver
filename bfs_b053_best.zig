/// Best-first searcher for b053
/// based on bfs_b023.zig
const std = @import("std");

const brand = @import("brand.zig");

// The desired end state
// one of add, gor, lev, cif, dev, trailer
const goal_tile = brand.bee_tile;

pub const wings = true;
// Limit move depth, if a solution is known to exist within a specific move count
const MAX_DEPTH: u8 = 1 + 46;
// CIF + wings: max depth 35
//  Pre-existing sequence ZDLDDUZULUDRRUURRDLZDDZDZLDRRUURUDD  proven optimal (~4.5GB RAM)
// TAN + wings: max depth 41
//  pre-existing LLRZUDDRDDLRZDURZRLZULUURZRLZRZUDDLDDUZDZ (depth 41 + XX)
//  search found LLRZUDDRRDZURUZLZRZLDLLRZDDZLRRRLZUDZ  (37 + XX)  (1h40m 50gb peak footprint 10gb max rss)
//  and          RRRLZUDDLDZULLUZRZLZRDLRZDDZLRRRLZUDZ  (37 + XX)
//  manual edit: RRRLZUDDLDZULLUZDRZULZRZDDDZLRRRLZUDZ  (37 + XX)
// BEE + wings: max depth 46
//  pre-existing ULLDRZRRDDZDZDRLULULRUUZRRZLDZDZLUZRZUDZURULZL
// LEV + wings: max depth 33
//  manually found ZRDDRRLZLURZDDLUZDZLDULLURUULRURR XX
//  search found   ZRULLDLRDRDRLDDULLURRZRRRULDZLZDZ X

const Board = brand.Board;
const Action = brand.Action;
const Pos = brand.Pos;
const b053 = brand.b053;
const is_duplicate = brand.is_duplicate_board2;

fn heuristic(b: Board, comptime goal: u35) u8 {
    return @popCount(b.tiles ^ goal) + @as(u8, if (b.pocket != .Stairs) 1 else 0);
}

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

inline fn duplicate_item(a: Item, b: Item) bool {
    return is_duplicate(a.b, b.b, a.cant_z, b.cant_z);
}
fn duplicate_a_subset_of_b(a: Item, b: Item) bool {
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

fn prune(result: Board, depth: u8) bool {
    // ignore if the goal state is definitely not reachable within MAX_DEPTH total steps
    return heuristic(result, goal_tile) + depth > MAX_DEPTH or @popCount(result.tiles) + result.pocket.walkable() < @popCount(goal_tile);
}

const duplicate_stats = false;

const min_heuristic = heuristic(b053, goal_tile);

test "heuristic" {
    try std.testing.expect(heuristic(b053, brand.cif_tile) == 22);
    try std.testing.expect(heuristic(b053, brand.bee_tile) == 16);
    try std.testing.expect(heuristic(b053, brand.lev_tile) == 19);
}

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
        const t = cur.b.reverse(cur.p);
        if (t[0] == b053 or t[1] == b053) return;
        for (t) |ti| if (ti) |tb| {
            const hd = (d - 1) + heuristic(tb, goal_tile) - min_heuristic;
            const idx = std.sort.binarySearch(Item, finalized[hd][d - 1].items, tb, board_item_cmp);
            if (idx != null) {
                b = tb;
                cur = finalized[hd][d - 1].items[idx.?];
                break;
            }
        } else {
            @panic("couldn't find previous move");
        };
        d -= 1;
    }
}

fn best_first_search(alloc: std.mem.Allocator) !void {
    // grouped by heuristic (minimum total moves remaining) and move depth
    // we take `depth + heuristic(b, goal) - heuristic(start, goal)` and `depth`
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
    try finalized[0][0].append(alloc, .{ .b = b053, .p = .D, .cant_z = false });
    defer {
        for (finalized[0..]) |*f_bucket| for (f_bucket[0..]) |*bucket| if (bucket.items.len > 0) bucket.deinit(alloc);
    }
    //
    var found = false;
    var max_depth_so_far: usize = 1;
    for (finalized[0..], 0..) |*hgroup, hdiff| {
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
                                if (result.pocket == .Stairs) {
                                    try trace_path_2(b, a, @intCast(depth - 1), finalized[0..]);
                                    found = true;
                                }
                            } else if (prune(result, @as(u8, @intCast(depth)))) continue;
                            if (depth == MAX_DEPTH) @panic("unexpected depth == MAX_DEPTH");
                            const h = heuristic(result, goal_tile);
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
                            }, .cant_z = !result.can_Z(a) };
                            try todo.append(alloc, item);
                        }
                    }
                }
            }
            if (todo.items.len == 0 and depth > max_depth_so_far) break;
            if (todo.items.len == 0) continue;
            max_depth_so_far = @max(max_depth_so_far, depth);
            var stats_dupe_depth = if (duplicate_stats) [_]usize{0} ** MAX_DEPTH else {};
            std.debug.print("hdiff {} depth {}: generated {} states\n", .{ hdiff, depth, todo.items.len });
            std.sort.pdq(Item, todo.items, {}, item_lessThan);
            //var dedup: std.ArrayList(Item) = try .initCapacity(alloc, todo.items.len / 2);
            var write_i: usize = 0;
            item: for (todo.items, 0..todo.items.len) |b, read_i| {
                if (read_i + 1 < todo.items.len and duplicate_item(b, todo.items[read_i + 1])) {
                    if (b.cant_z) todo.items[read_i + 1].cant_z = true;
                    // ^ in this case b.facing==a.facing and using Z would result in an alraedy seen state
                    if (duplicate_stats) stats_dupe_depth[0] += 1;
                    continue;
                }
                const h = heuristic(b.b, goal_tile);
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
                // not a duplicate
                if (write_i == read_i) {
                    write_i += 1; // already in correct position
                    continue;
                }
                todo.items[write_i] = b;
                write_i += 1;
                //try dedup.append(alloc, b); // sorted
            }
            const dupe_amt = todo.items.len - write_i;
            //const dupe_amt = todo.items.len - dedup.items.len;
            std.debug.print("hdiff {} depth {}: done sort+dedup, duplicates {} / {}  ({}%)\n", .{ hdiff, depth, dupe_amt, todo.items.len, dupe_amt * 100 / todo.items.len });
            if (duplicate_stats) {
                std.debug.print("Duplicate depth difference distribution:\n", .{});
                for (stats_dupe_depth, 0..) |count, i| {
                    if (count > 0) std.debug.print("depth diff -{}: count {}\n", .{ i * 2, count });
                }
                std.debug.print("\n", .{});
            }
            todo.shrinkAndFree(alloc, write_i); // now finalized
            //todo.deinit(alloc);
            //try dedup.shrinkToLen(alloc);
            //todo.* = dedup; // now finalized
        }
        if (found) break;
    }
    std.debug.print("\nDone\n", .{});
}
