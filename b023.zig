/// Solver for B023
const std = @import("std");

pub const Facing = enum(u2) { U, L, R, D };
pub const Pos = u6;

const endless = true;
const wings = false;

pub const BT = @typeInfo(Board).@"struct".backing_integer.?;
/// Least significant to most significant bits
pub const Board = packed struct(u54) {
    facing: Facing,
    gray: Pos,
    pocket: u4, // count of tiles (Endless Rod) - only need u4 (can pick up at most (18+1-4)=15 on B023)
    tiles: u36, // bit set = tile (or stairs)
    stairs: u6, // 0-35 for a specific tile; 36+ is its position in the pocket

    pub const invalid: Board = @bitCast(@as(BT, 0));
    pub fn at(b: Board, p: Pos) u1 {
        if (p > 35) unreachable;
        return @intCast((b.tiles >> p) & 1);
    }

    fn pickup(b: Board, p: Pos) Board { // t is non-empty
        if (p > 35) unreachable;
        const remove_mask: u36 = @as(u36, 1) << p;
        return Board{
            .tiles = b.tiles & ~remove_mask,
            .gray = b.gray,
            .facing = b.facing,
            .pocket = b.pocket + 1,
            .stairs = if (p == b.stairs) 36 + @as(u6, @intCast(b.pocket + 1)) else b.stairs,
            // .can_z = false,
        };
    }

    fn place(b: Board, p: Pos) Board {
        if (p > 35) unreachable;
        // guaranteed p is empty
        if (b.pocket == 0) unreachable;
        const tile_mask = @as(u36, 1) << p;
        return Board{
            .tiles = b.tiles | tile_mask,
            .gray = b.gray,
            .facing = b.facing,
            .pocket = b.pocket - 1,
            .stairs = if (b.stairs -% 36 == b.pocket) p else b.stairs,
            // .can_z = false,
        };
    }
    fn move_to(b: Board, p: Pos, f: Facing) ?Board {
        // Check if the move is allowed
        if (p == b.stairs) return null;
        const hovering: bool = b.at(b.gray) == 0;
        if ((!wings or hovering) and b.at(p) == 0) return null; // cannot continue hovering
        // update the state as appropriate
        return Board{
            .tiles = b.tiles,
            .gray = p,
            .facing = f,
            .pocket = b.pocket,
            .stairs = b.stairs,
        };
    }
    /// Unmove from the position of `b` to the previous position+facing state (p, f)
    fn unmove_to(b: Board, p: Pos, f: Facing) Board {
        return Board{
            .tiles = b.tiles,
            .gray = p,
            .facing = f,
            .pocket = b.pocket,
            .stairs = b.stairs,
        };
    }
    pub fn do_action(b: Board, a: Action) ?Board {
        // prohibit bumping
        // in this puzzle there's no need to stall; can't move any objects
        // so it doesnt allow changing facing dir in a useful way
        switch (a) {
            .Z => { // symmetrical
                // get the position in front (pickup/place)
                const forward = move_by(b.gray, b.facing);
                if (forward == b.gray) unreachable; // same tile denotes would bump
                const f_tile = b.at(forward);
                // pickup if a tile is there
                // place if its empty, unless we would be placing our last tile as stairs from endless rod
                return switch (f_tile) {
                    1 => if (endless or b.pocket == 0) b.pickup(forward) else null,
                    0 => if (b.pocket > 0 and (!endless or b.pocket > 1 or b.stairs != 37)) b.place(forward) else null,
                };
            },
            else => {
                const new_facing: Facing = switch (a) {
                    .U => .U,
                    .L => .L,
                    .R => .R,
                    .D => .D,
                    else => unreachable,
                };
                const new_pos = move_by(b.gray, new_facing);
                return if (new_pos == b.gray) null else b.move_to(new_pos, new_facing);
            },
        }
    }
    pub fn reverse(b: Board, a: Action) Board {
        switch (a) {
            .Z => { // symmetrical
                const forward = move_by(b.gray, b.facing);
                if (forward == b.gray) unreachable; // same tile denotes would bump
                const f_tile = b.at(forward);
                // pickup if a tile is there
                // place if its empty
                return switch (f_tile) {
                    1 => b.pickup(forward),
                    0 => b.place(forward),
                };
            },
            else => {
                const old_facing: Facing = switch (a) {
                    .U => .U,
                    .L => .L,
                    .R => .R,
                    .D => .D,
                    else => unreachable,
                };
                const back_dir: Facing = switch (b.facing) {
                    .U => .D,
                    .L => .R,
                    .R => .L,
                    .D => .U,
                };
                const old_pos = move_by(b.gray, back_dir);
                return b.unmove_to(old_pos, old_facing);
            },
        }
    }
    /// Z action is available when:
    ///  - Previous action was not Z  (otherwise we are revisiting a previous state)
    ///  - Not facing the wall or a rock  (ie, position gray is facing is valid)
    ///  - We can place from pocket (pocket not empty) or pickup (facing tile not empty)
    pub fn cant_Z(b: Board, prev: Action) bool {
        const fw: Pos = move_by(b.gray, b.facing);
        const tile = b.at(fw);
        return prev == .Z or (fw == b.gray) or if (endless) ((b.pocket == 0) and (tile == 0)) else (@as(u1, @intCast(b.pocket)) == tile);
    }

    pub fn do_actions(b: Board, actions: []const u8) ?Board {
        var p = b;
        for (actions) |c| {
            p = p.do_action(switch (c) {
                'Z' => .Z,
                'U' => .U,
                'L' => .L,
                'R' => .R,
                'D' => .D,
                else => unreachable,
            }) orelse return null;
        }
        return p;
    }
};

pub const Action = enum(u3) { Z, U, L, R, D };

// B023 has no blockers
pub fn move_by(p: Pos, f: Facing) Pos {
    return switch (f) {
        .U => if (p > 29) p else p + 6,
        .L => if (p % 6 == 5) p else p + 1,
        .R => if (p % 6 == 0) p else p - 1,
        .D => if (p < 6) p else p - 6,
    };
}

pub const add_tile: u36 = 0b100001_000110_011111_111110_011000_100001;
pub const gor_tile: u36 = 0b001100_001100_100100_110001_111100_111100;
pub const lev_tile: u36 = 0b100011_001111_100100_001100_000001_110011;
pub const cif_tile: u36 = 0b110001_010101_010010_101000_100100_110001;
pub const dev_tile: u36 = 0b110001_101001_100110_011001_100101_100011;
pub const trailer_tile: u36 = 0b100001_000000_010010_110011_000000_101101;

/// basic heuristic for brand rooms without glass / breakable tiles
/// Is a consistent heuristic, both with and without the Endless Rod.
/// However it does not account for hovering state with wings.
pub fn heuristic(a: u36, comptime goal: u36) u8 {
    // for each tile that is different, we must either take or place it
    // Also for each such tile, we must move to face it
    // (we may already be facing one such tile)
    return @popCount(a ^ goal) * 2 - 1;
}

fn heuristic_2(a: u36, facing: u36, comptime goal: u36) u8 {
    // for each tile that is different, we must either take or place it
    // Also for each such tile, we must move to face it
    // (we may already be facing one such tile)
    return @popCount(a ^ goal) + @popCount(a ^ goal & ~facing);
}
pub fn heuristic2(b: Board, comptime goal: u36) u8 {
    const forward = move_by(b.gray, b.facing);
    return heuristic_2(b.tiles, if (forward == b.gray) 0 else @as(u36, 1) << forward, goal);
}

pub fn heuristic3(b: Board, comptime goal: u36) u8 {
    // Also consider situation where we need to replace stairs with a tile,
    // and whether we can actually place in our facing direction
    const forward = move_by(b.gray, b.facing);
    const stairs = if (b.stairs < 36) @as(u36, 1) << b.stairs else 0;
    const have_tile = (b.pocket != 0) and (b.stairs -% 37 != b.pocket);
    const excess = b.tiles & ~(goal | stairs); // stairs are always excess
    const missing = goal & ~(b.tiles ^ stairs); // stairs don't count as a filling tile
    // good facing if we can pick up excess or fill missing
    // (since stairs are counted as excess, doesnt matter if they are also in missing)
    const good_facing = ((excess >> forward) & 1) | if (have_tile) (missing >> forward) & 1 else 0;
    return 2 * (@popCount(excess) + @popCount(missing)) - good_facing;
}

pub fn heuristic4(b: Board, comptime goal: u36) u8 {
    // also consider islands that are not accessible from b.gray in (b.tiles)
    // problem is that these can share 'access points' => connecting them (T-junction) would decrease H by >1
    // also, facing becomes more complex:
    // after placing access tile, need to know whether removing access tile (still in excess) would create island
    // facing access tile: good_facing = 1
    // placing access tile: remove the tile from excess (still in missing), good_facing = 0
    // move to pick up/place the island: good_facing = 1
    // move to face access tile again: good_facing = 1 (island has been resolved)
    _ = // need to remove the top 2 tiles: placing between them
        \\..@.@.
        \\...^..
        \\...##.
        \\...##.
    ;
    _ = // where the two topleft tiles need removal
        \\..@...
        \\.@.<##
        \\..#.##
    ;
    // use flood fill? or rather tilefill where we only fill where a tile can be placed
    // start with a floodfill to accessible tiles
    var accessible = @as(u36, 1) << b.gray;
    const U_border: u36 = 0b111111_000000_000000_000000_000000_000000;
    const L_border: u36 = 0b100000_100000_100000_100000_100000_100000;
    const R_border: u36 = 0b000001_000001_000001_000001_000001_000001;
    const D_border: u36 = 0b000000_000000_000000_000000_000000_111111;
    // floodfill to accessible b.tiles
    var changed = true;
    while (changed) {
        const new = accessible | (b.tiles &
            ((accessible & ~U_border) << 6) | ((accessible & ~L_border) << 1) | ((accessible & ~R_border) >> 1) | ((accessible & ~D_border) >> 6));
        changed = (new != accessible);
        accessible = new;
    }
    // now run a tilefill, to get min tiles to reach islands ?
    const U = (((accessible & ~U_border) << 6) & accessible & ~U_border) << 6;
    const L = (((accessible & ~L_border) << 1) & accessible & ~L_border) << 1;
    const R = (((accessible & ~R_border) >> 1) & accessible & ~R_border) >> 1;
    const D = (((accessible & ~D_border) >> 6) & accessible & ~D_border) >> 6;
    accessible |= U | L | R | D;
    // run another floodfill, check which islands are reached...

    _ = goal;
}

pub fn heuristic_gor(b: Board, comptime goal: u36) u8 {
    // variant of heuristic3 with manually handling of the corner islands
    if (goal != gor_tile) @compileError("use only on b023 for Gor's brand");
    // Also consider situation where we need to replace stairs with a tile
    const forward = move_by(b.gray, b.facing);
    const stairs = if (b.stairs < 36) @as(u36, 1) << b.stairs else 0;
    const have_tile = (b.pocket != 0) and (b.stairs -% 37 != b.pocket);
    const excess = b.tiles & ~(goal | stairs); // stairs are always excess
    const missing = goal & ~(b.tiles ^ stairs); // stairs don't count as a filling tile
    // good facing if we can pick up excess or fill missing
    // (since stairs are counted as excess, doesnt matter if they are also in missing)
    const good_facing: u8 = @intCast(((excess >> forward) & 1) | if (have_tile) (missing >> forward) & 1 else 0);
    //
    const corner_TL: u36 = 0b100000_000000_000000_000000_000000_000000;
    const corner_TR: u36 = 0b000001_000000_000000_000000_000000_000000;
    const corner_BR: u36 = 0b000000_000000_000000_000000_000000_000001;
    // for each corner tile we need to place and remove another tile to reach it
    // for a total of 12 additional actions (3 corners * 1 tile * (place + remove) * (get in position + Z))
    // take those into account along with facing one of those tiles
    //  if the corner still exists and ...
    // these access vars are 0 if no longer necessary
    const TL_access = ((b.tiles & corner_TL) >> 6) * 0b010000_1;
    const TR_access = ((b.tiles & corner_TR) >> 6) * 0b000010_000001;
    const BR_access = (b.tiles & corner_BR) * 0b000001_000010;
    var access_cost: u8 = 0;
    if (TL_access != 0) {
        const facing: u8 = @intCast((TL_access >> forward) & 1);
        // TL has not yet been picked up
        // TL itself is tracked in heuristic (as part of `excess`) but not the access tiles
        if (TL_access & b.tiles == 0) {
            // TL is an island
            access_cost += 4 - facing; // need to fill and later remove access
            // can be decreased by good_facing; handle here or all in a group
        } else {
            // TL is no longer an island
            // shouldn't remove access until TL is gone
            // facing the access tile isn't good, though it's tracked as such as part of `excess`
            // so we need to add 1 if facing instead of subtracting for total o
            // if facing an access tile add 1
            access_cost += facing;
        }
    } else {} // TL has been removed: access tile can be tracked as normal (as part of `excess`)
    if (TR_access != 0) {
        const facing: u8 = @intCast((TR_access >> forward) & 1);
        if (TR_access & b.tiles == 0) {
            access_cost += 4 - facing;
        } else {
            access_cost += facing;
        }
    }
    if (BR_access != 0) {
        const facing: u8 = @intCast((BR_access >> forward) & 1);
        if (BR_access & b.tiles == 0) {
            access_cost += 4 - facing;
        } else {
            access_cost += facing;
        }
    }
    return 2 * (@popCount(excess) + @popCount(missing)) - good_facing + access_cost;
}

test "gor heuristic" {
    const start = Board{
        .tiles = 0b101100_000000_000000_000000_000000_000000, // checking TL corner access
        .gray = 32,
        .facing = .R,
        .pocket = 3, // Tile Stairs Tile
        .stairs = 38,
    };
    // face an access tile
    const s2 = start.do_action(.L).?;
    try std.testing.expect(heuristic_gor(s2, gor_tile) == heuristic_gor(start, gor_tile) - 1);
    // fill an access tile
    const s3 = s2.do_action(.Z).?;
    try std.testing.expect(heuristic_gor(s3, gor_tile) == heuristic_gor(s2, gor_tile) - 1);
    // face an excess (non-access) tile
    const s4 = s3.do_action(.L).?;
    try std.testing.expect(heuristic_gor(s4, gor_tile) == heuristic_gor(s3, gor_tile) - 1);
    // take an excess tile
    const s5 = s4.do_action(.Z).?;
    try std.testing.expect(heuristic_gor(s5, gor_tile) == heuristic_gor(s4, gor_tile) - 1);
    // move
    const s6 = s5.do_action(.R).?;
    try std.testing.expect(heuristic_gor(s6, gor_tile) == heuristic_gor(s5, gor_tile));
    // move
    const s7 = s6.do_action(.R).?;
    try std.testing.expect(heuristic_gor(s7, gor_tile) == heuristic_gor(s6, gor_tile));
    // face a used access tile (now just excess)
    const s8 = s7.do_action(.L).?;
    try std.testing.expect(heuristic_gor(s8, gor_tile) == heuristic_gor(s7, gor_tile) - 1);
    // take a used access tile (now just excess)
    const s9 = s8.do_action(.Z).?;
    try std.testing.expect(heuristic_gor(s9, gor_tile) == heuristic_gor(s8, gor_tile) - 1);
    //
    try std.testing.expect(heuristic_gor(s3.do_action(.R).?, gor_tile) == heuristic_gor(s3, gor_tile));
    try std.testing.expect(heuristic_gor(s3.do_action(.R).?.do_action(.L).?, gor_tile) == heuristic_gor(s3, gor_tile));
    const s3_rz = s3.do_action(.R).?.do_action(.Z).?;
    try std.testing.expect(s3_rz.stairs == 31);
    try std.testing.expect(s3_rz.gray == 32);
    try std.testing.expect(s3_rz.facing == .R);
    std.debug.print("{} ", .{heuristic_gor(s3, gor_tile)});
    std.debug.print("{} ", .{heuristic_gor(s3_rz, gor_tile)});
    // TODO
    try std.testing.expect(heuristic_gor(s3_rz, gor_tile) == heuristic_gor(s3, gor_tile) + 1);
}

// B023 start (Stairs appear as a tile here)
const start_tiles = 0b100101_000110_011111_111110_011000_100001;
pub const b023 = Board{
    .tiles = start_tiles,
    .gray = 15,
    .facing = .D,
    .pocket = 0,
    .stairs = 32,
};

test "b023_start" {
    try std.testing.expect(b023.at(0) == 1);
    try std.testing.expect(b023.at(1) == 0);
    try std.testing.expect(b023.at(15) == 1);
    try std.testing.expect(b023.at(32) == 1);
    try std.testing.expect(b023.at(35) == 1);

    try std.testing.expect(!b023.cant_Z(.D));
    if (wings) try std.testing.expect(b023.do_action(.D).?.do_action(.D).?.do_action(.D) == null);
    if (wings) try std.testing.expect(b023.do_action(.D).?.do_action(.R).?.do_action(.R) == null);
    if (!wings) try std.testing.expect(b023.do_action(.D).?.do_action(.D) == null);
    try std.testing.expect(b023.do_action(.U).?.do_action(.D).? == b023);
    try std.testing.expect(b023.do_action(.D).?.cant_Z(.D));
    try std.testing.expect(b023.do_action(.U).?.cant_Z(.U));
}

test "gor" {
    if (endless) {
        try std.testing.expect(b023.do_actions("ZLZRRRZRUZUZDDZDZUUZLULZDLUZDRUZDRRDZLUZLRZLUZULZLZRRLZDDLZRDZLZURRZDZDLUZRZDZLLZUZRZDZDRLZUZ").?.tiles == gor_tile);
        try std.testing.expect(b023.do_actions("RZUURZRDUZDZDUZDZDZUUDZULULZDZRZLUZDZLUZDRZUZULZLZRRLZDRZDLZDDZUZDLZLUZRZDZRZLDRZRUZ").?.tiles == gor_tile);
    }
}

test "dont-place-bottom-stairs" {
    const start = b023.do_actions("URUZ").?;
    if (endless) try std.testing.expect(start.do_action(.Z) == null);
    if (!endless) try std.testing.expect(start.do_action(.Z).?.stairs == 32);
}

test "dev_start" {
    const dev_position = Board{
        .tiles = dev_tile,
        .gray = 6,
        .facing = .U,
        .pocket = if (endless) 2 else 1,
        .stairs = if (endless) 38 else 37, // top of pocket but not bottom if endless
    };
    if (endless) try std.testing.expect(dev_position.do_action(.Z).?.pocket == 3);
    if (endless) try std.testing.expect(dev_position.do_action(.Z).?.stairs == 38);
    if (!endless) try std.testing.expect(dev_position.do_action(.Z) == null); // pocket is full at 1
    const dev_D = dev_position.do_action(.D).?;
    const dev_DL = dev_D.do_action(.L).?;
    const dev_DLZ = dev_DL.do_action(.Z).?;
    try std.testing.expect(dev_D.gray == 0);
    try std.testing.expect(dev_DLZ.pocket == if (endless) 1 else 0);
    try std.testing.expect(dev_DLZ.stairs == 2);
    try std.testing.expect(dev_DLZ.gray == 1);
}

/// Check whether states are effectively duplicates
/// Any of:
///  - They are equal
///  - They only differ in facing direction and facing direction does not matter
pub fn is_duplicate_board(a: Board, b: Board, a_cant_z: bool, b_cant_z: bool) bool {
    return is_duplicate(@bitCast(a), @bitCast(b), a_cant_z, b_cant_z);
}

pub fn is_duplicate(a: BT, b: BT, a_cant_z: bool, b_cant_z: bool) bool {
    if (a == b) return true;
    if (a ^ b > 3) return false;
    return a_cant_z and b_cant_z;
}
