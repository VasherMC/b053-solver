const std = @import("std");
const bfs = @import("bfs_b053_tile_v2.zig");
const brand = @import("b053_v2.zig");

const MIN_TILES = 17; // 18 (19) for Bee, 17 (18) for Add
const data_complete_tiles = 20; // for which we have complete b053-data/ for (about 300 GB)
const Item = bfs.Item;
test {
    std.testing.refAllDecls(@import("bidirectional_search_b053_data.zig"));
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

test "Add end states" {
    const tilecount = @popCount(brand.add_tile);
    var arr = try possible_end_states(brand.add_tile, std.testing.allocator);
    defer arr.deinit(std.testing.allocator);
    try std.testing.expect(arr.items.len == 57120);
    try std.testing.expect(arr.items[0] == bfs.Item{
        .tiles = brand.add_tile,
        .gray = 0, // standing on glass
        .cant_z = false,
        .facing = .U,
        .solid1 = 4,
        .solid2 = 8,
        .solid3 = 9,
        .stairs = 36,
        .hovering = 0,
    });
    // facing up: only nonbreaking move is placing the stairs
    try std.testing.expect(arr.items[0].predecessors_nonbreaking(tilecount)[0].?.stairs == 6);
    try std.testing.expect(arr.items[0].predecessors_nonbreaking(tilecount)[0].?.gray == 0);
    for (arr.items[0].predecessors_nonbreaking(tilecount)[1..]) |item| try std.testing.expect(item == null);
    // breaking move would be backwards into the wall
    for (arr.items[0].predecessors_breaking()) |item| try std.testing.expect(item == null);
}

fn possible_end_states(tiles: u35, alloc: std.mem.Allocator) !std.ArrayList(Item) {
    var result: std.ArrayList(Item) = .empty;
    // generate all possibilities of (solid tile positions, gray position, facing)
    // solid1 < solid2 < solid3
    // each solidX maps to a tile present in `tiles`:  (tiles>>solidX)&1==1
    // gray must be standing on a solid tile or empty space (broken glass)
    // must be holding stairs
    // we start with (tilecount choose 3) * ((35-tilecount) + 3) * 4 candidate states
    // for Add, this is (17 choose 3) * (18 + 3) * 4 = 57k
    for (0..35) |solid3_u| {
        const solid3: u6 = @intCast(solid3_u);
        if ((tiles >> solid3) & 1 == 0) continue;
        for (0..solid3) |solid2_u| {
            const solid2: u6 = @intCast(solid2_u);
            if ((tiles >> solid2) & 1 == 0) continue;
            for (0..solid2) |solid1_u| {
                const solid1: u6 = @intCast(solid1_u);
                if ((tiles >> solid1) & 1 == 0) continue;
                for (0..35) |gray_u| {
                    const gray: u6 = @intCast(gray_u);
                    // either standing on a solid tile or standing on broken glass
                    if (gray == solid1 or gray == solid2 or gray == solid3 or (tiles >> gray) & 1 == 0) {
                        for ([4]brand.Facing{ .U, .L, .R, .D }) |facing| {
                            try result.append(alloc, .{
                                .facing = facing,
                                .cant_z = false, // always false for our backwards search
                                .solid1 = solid1,
                                .solid2 = solid2,
                                .solid3 = solid3,
                                .gray = gray,
                                .hovering = 0, // not implemented for wings
                                .stairs = 36, // always end holding stairs
                                .tiles = tiles,
                            });
                        }
                    }
                }
            }
        }
    }
    return result;
}

// see if any of our generated backwards states match with any stored forwards states at any depth
fn check_any_matching(backwards_states: []Item, io: std.Io, dir: std.Io.Dir) !bool {
    var buf: [20]u8 = undefined;
    outer: for (0..250) |depth| {
        const fname = try bfs.setFilenameFor(buf[0..], data_complete_tiles, @intCast(depth));
        var f = try bfs.mappedStateStream.init(io, dir, fname) orelse continue;
        defer f.close(io) catch {};
        var r = f.reader();
        var fw_state = r.pop() orelse continue;
        std.debug.print("Checking depth {}...\n", .{depth});
        for (backwards_states) |bw_state| {
            while ((bfs.backing(fw_state) >> 3) < (bfs.backing(bw_state) >> 3)) fw_state = r.pop() orelse continue :outer;
            if (bfs.equal_mod_facing(fw_state, bw_state)) {
                // since the next move must be a breaking move (onto glass), facing and can/cant Z don't matter
                std.debug.print("Found a path from state {} at depth {}\n", .{ fw_state, depth });
                try bfs.trace_path_files(io, dir, fw_state, @intCast(depth));
                return true;
            }
        }
    }
    std.debug.print("Did not find a path\n", .{});
    return false;
}

// run the backwards portion of the bidirectional search
fn bidi(start: anytype, alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !bool {
    var states: std.ArrayList(Item) = .empty;
    var next_states = switch (@TypeOf(start)) {
        u35 => try possible_end_states(start, alloc),
        Item => blk: {
            var x = try std.ArrayList(Item).initCapacity(alloc, 1);
            x.appendAssumeCapacity(start);
            break :blk x;
        },
        else => unreachable,
    };
    const start_tilecount: u6 = @popCount(switch (@TypeOf(start)) {
        u35 => start,
        Item => start.tiles,
        else => unreachable,
    }); // pocket contains stairs only
    // we ignore depth here
    // since end states can have either parity, just implement something simple first and optimize later
    for (start_tilecount..data_complete_tiles) |tilecount| {
        std.debug.print("generating states for tilecount {}\n", .{tilecount});
        // finish generating states for the tilecount with nonbreaking moves
        // we have an initial set of states for the tilecount
        states = .empty; // all states at current-depth
        var cur_states: std.ArrayList(Item) = .empty; // intermediate for current-depth
        var new_states: std.ArrayList(Item) = next_states; // intermediate for next-depth
        next_states = .empty; // intermediate for next-tilecount
        while (new_states.items.len > 0) {
            std.debug.print("new states: {}, total: {}\n", .{ new_states.items.len, states.items.len });
            // generate child states at new depth
            cur_states = new_states;
            new_states = .empty;
            for (cur_states.items) |st| {
                for (st.predecessors_nonbreaking(@intCast(tilecount))) |pred| if (pred) |newstate| try new_states.append(alloc, newstate);
            }
            // merge the current states into the main list (they have already been deduplicated)
            try states.appendSlice(alloc, cur_states.items);
            cur_states.deinit(alloc);
            std.sort.pdq(Item, states.items, {}, bfs.item_lessThan);
            // sort the nonbreaking children for the next depth
            std.sort.pdq(Item, new_states.items, {}, bfs.item_lessThan);
            // deduplicate the nonbreaking children against the updated main list
            var main_i: usize = 0;
            var write_i: usize = 0;
            for (new_states.items, 0..) |new, read_i| {
                while (main_i < states.items.len and bfs.backing(states.items[main_i]) < bfs.backing(new)) main_i += 1;
                if (main_i == states.items.len) break;
                if (states.items[main_i] == new) {
                    continue; // skip writing and incrementing write_i
                }
                // same-depth duplicate
                if (read_i + 1 < new_states.items.len and new == new_states.items[read_i + 1]) continue;
                if (write_i < read_i) new_states.items[write_i] = new;
                write_i += 1;
            }
            if (write_i < new_states.items.len) new_states.shrinkAndFree(alloc, write_i);
        }
        std.debug.assert(new_states.items.len == 0);
        //std.debug.assert(cur_states.items.len == 0); undefined after deinit
        // we've generated all same-tilecount (nonbreaking) states
        // generate states for next tilecount
        std.debug.print("generating breaking moves from tilecount {} back to {}\n", .{ tilecount, tilecount + 1 });
        for (states.items) |it| {
            for (it.predecessors_breaking()) |pred| if (pred) |newstate| try next_states.append(alloc, newstate);
        }
        std.sort.pdq(Item, next_states.items, {}, bfs.item_lessThan);
        // deduplicate
        var write_ii: usize = 0;
        for (next_states.items, 0..) |next, read_i| {
            // same-depth duplicate
            if (read_i + 1 < next_states.items.len and next == next_states.items[read_i + 1]) continue;
            if (write_ii < read_i) next_states.items[write_ii] = next;
            write_ii += 1;
        }
        // clean up
        states.deinit(alloc);
    }
    std.debug.print("checking if any states match...\n", .{});
    // now we have the list of next_states (breaking moves only) for the desired tilecount
    defer next_states.deinit(alloc);
    return try check_any_matching(next_states.items, io, dir);
}

test "trailer brand intermediate" {
    const trailer_brand_19 = Item{
        .tiles = 0b100001_100000_111110_110011_111000_11110,
        .facing = .R,
        .gray = 19,
        .solid1 = 19,
        .solid2 = 20,
        .solid3 = 21,
        .stairs = 26,
        .hovering = 0,
        .cant_z = false,
    };
    const trailer_brand_16 = Item{
        .tiles = 0b100001_010000_010010_110011_111000_11110,
        .facing = .R,
        .gray = 27,
        .solid1 = 15,
        .solid2 = 21,
        .solid3 = 27,
        .stairs = 36,
        .hovering = 0,
        .cant_z = false,
    };
    const trailer_brand_14 = Item{
        .tiles = 0b100001_010000_010010_110011_011000_10110,
        .facing = .R,
        .gray = 9,
        .solid1 = 9,
        .solid2 = 15,
        .solid3 = 21,
        .stairs = 33,
        .hovering = 0,
        .cant_z = false,
    };
    const dir = try std.Io.Dir.cwd().openDir(std.testing.io, "b053-data", .{ .iterate = true });
    var buf: [20]u8 = undefined;
    const fname = try bfs.setFilenameFor(buf[0..], data_complete_tiles, 150);
    var f = bfs.mappedStateStream.init(std.testing.io, dir, fname) catch {
        return error.SkipZigTest;
    } orelse return error.SkipZigTest;
    try f.close(std.testing.io);
    try std.testing.expect(try bidi(trailer_brand_19, std.testing.allocator, std.testing.io, dir));
    try std.testing.expect(try bidi(trailer_brand_16, std.testing.allocator, std.testing.io, dir));
    try std.testing.expect(try bidi(trailer_brand_14, std.testing.allocator, std.testing.io, dir));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const dir = try std.Io.Dir.cwd().openDir(io, "b053-data", .{ .iterate = true });
    for ([2]u35{ brand.bee_tile, brand.add_tile }, [2][]const u8{ "Bee", "Add" }) |tile, name| {
        std.debug.print("\nRunning backwards search from {s}'s brand\n", .{name});
        if (try bidi(tile, init.gpa, io, dir)) std.debug.print("\nFound a path for {s}!\n\n", .{name});
    }
}
