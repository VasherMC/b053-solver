/// State and action/transition definitions for b053

// some pruning is hardcoded
// for example, the bottom-right corner with the rock is unchangeable
// so we use u35 to track tiles instead of u36

const std = @import("std");

pub const Facing = enum(u2) { U, L, R, D };
pub const Pos = u6;
pub const Tile = enum(u2) {
    Empty = 0b00,
    Stairs = 0b01,
    Glass = 0b10,
    Tile = 0b11,
    inline fn walkable(t: Tile) u1 {
        return @intCast(@intFromEnum(t) >> 1);
    }
};

const orig_Board = @import("brand.zig").Board;
pub const endless = false;
pub const stairs_tile = false; // whether the stairs is counted in Board.tiles

pub const wings = false;

pub fn is_duplicate_board2(a: Board, b: Board, a_cant_z: bool, b_cant_z: bool) bool {
    if (a == b) return true;
    if (@as(BT, @bitCast(a)) ^ @as(BT, @bitCast(b)) > 3) return false;
    return a_cant_z or b_cant_z;
}

const BT = @typeInfo(Board).@"struct".backing_integer.?;
/// Least significant to most significant bits
/// (important for quotienting and sorting)
/// having facing as LSB makes streaming deduplication possible/simpler
pub const Board = packed struct(if (wings) u70 else u69) {
    facing: Facing,
    gray: Pos,
    pocket: u2, // if (endless) u6 else u1
    stairs: Pos, // u6, >36 is position within pocket
    solid1: Pos,
    solid2: Pos,
    solid3: Pos, // sorted: solid1 < solid2 < solid3
    hovering: if (wings) u1 else u0,
    tiles: u35, // bit set = walkable (tile/glass)

    pub fn to_orig(b: Board) orig_Board {
        return .{
            .tiles = b.tiles,
            .facing = switch (b.facing) {
                .U => .U,
                .L => .L,
                .R => .R,
                .D => .D,
            },
            .gray = b.gray,
            .pocket = if (b.pocket == 0) .Empty else if (b.stairs > 35) .Stairs else if (b.solid3 > 35) .Tile else .Glass,
            .glass = (if (b.stairs > 35) @as(u35, 0) else @as(u35, 1) << b.stairs) | (@as(u35, 1) << b.solid1) | (@as(u35, 1) << b.solid2) | (if (b.solid3 > 35) @as(u35, 0) else @as(u35, 1) << b.solid3) | (if (b.hovering != 0) @as(u35, 1) << b.gray else @as(u35, 0)),
        };
    }

    pub fn at(b: Board, p: Pos) Tile {
        if (p > 34) unreachable;
        return if (b.stairs == p) .Stairs else if (b.solid1 == p or b.solid2 == p or b.solid3 == p) .Tile else if ((b.tiles >> p) & 1 == 1) .Glass else .Empty;
        //return @enumFromInt(@as(u2, if (b.stairs == p or b.solid1 == p or b.solid2 == p or b.solid3 == p) 1 else 0) | @as(u2, @intCast(((b.tiles >> p) & 1) << 1)));
    }

    fn pickup(b: Board, p: Pos, t: Tile) Board { // t is non-empty
        if (p > 34) unreachable;
        if (!endless and b.pocket != 0) unreachable;
        const remove_mask: u35 = @as(u35, 1) << p;
        const new_pocket = @as(Pos, 36) + b.pocket;
        var new_solid1: Pos = b.solid1;
        var new_solid2: Pos = b.solid2;
        var new_solid3: Pos = b.solid3;
        if (t == .Tile) { // p in [b.solid1, b.solid2, b.solid3]
            new_solid3 = new_pocket;
            if (p < b.solid3) new_solid2 = b.solid3;
            if (p == b.solid1) new_solid1 = b.solid2;
        }
        return Board{
            .tiles = b.tiles & ~remove_mask,
            .stairs = if (p == b.stairs) new_pocket else b.stairs,
            .solid1 = new_solid1,
            .solid2 = new_solid2,
            .solid3 = new_solid3,
            .hovering = b.hovering,
            .gray = b.gray,
            .facing = b.facing,
            .pocket = b.pocket + 1,
        };
    }

    fn place(b: Board, p: Pos) Board {
        // guaranteed p is empty
        if (p > 34) unreachable;
        if (b.pocket == 0) unreachable;
        if (!endless and b.pocket != 1) unreachable;
        const pocket_top = @as(Pos, 35) + b.pocket;
        const tile_mask = @as(u35, if (!stairs_tile and b.stairs == pocket_top) 0 else 1) << p;
        var ret = Board{
            .tiles = b.tiles | tile_mask,
            .stairs = b.stairs,
            .solid1 = b.solid1,
            .solid2 = b.solid2,
            .solid3 = b.solid3,
            .hovering = b.hovering,
            .gray = b.gray,
            .facing = b.facing,
            .pocket = b.pocket - 1,
        };
        if (b.stairs == pocket_top) {
            @branchHint(.unlikely);
            ret.stairs = p;
        } else if (b.solid3 == pocket_top) {
            //if (p == b.solid1 or p == b.solid2) unreachable;
            if (p > b.solid2) {
                ret.solid3 = p;
            } else if (p < b.solid1) {
                ret.solid1 = p;
                ret.solid2 = b.solid1;
                ret.solid3 = b.solid2;
            } else {
                ret.solid2 = p;
                ret.solid3 = b.solid2;
            }
        }
        return ret;
    }
    fn move_to(b: Board, p: Pos, f: Facing) ?Board {
        if (p > 34) unreachable;
        // Check if the move is allowed
        if (p == b.stairs) return null; // even with wings, can't move to stairs
        if (wings) {
            if (b.hovering == 1 and b.at(p) == .Empty) return null; // cannot continue hovering
        } else {
            if ((b.tiles >> p) & 1 == 0) return null; // can't move to unwalkable .Empty
        }
        // update the state as appropriate
        const need_to_break_glass = b.at(p) == .Glass;
        const remove_mask: u35 = if (need_to_break_glass) @as(u35, 1) << p else 0;
        const new_hovering = if (wings) @as(u1, if (b.at(p) == .Empty) 1 else 0) else 0;
        return Board{
            .tiles = b.tiles & ~remove_mask,
            .stairs = b.stairs,
            .solid1 = b.solid1,
            .solid2 = b.solid2,
            .solid3 = b.solid3,
            .hovering = new_hovering,
            .gray = p,
            .facing = f,
            .pocket = b.pocket,
        };
    }
    /// Unmove from the position of `b` to the previous position+facing state (p, f)
    /// unbreaking glass as necessary, resulting in a grounded (non-hover) state
    fn unmove_to(b: Board, p: Pos, f: Facing) Board {
        if (p > 34) unreachable;
        switch (b.at(p)) {
            .Glass, .Stairs => unreachable, // a glass tile should have been broken
            else => {},
        }
        // if we weren't hovering, we moved onto glass and broke it
        const unmoving_from_glass = b.at(b.gray) == .Empty and b.hovering == 0;
        const new_glass: u35 = if (unmoving_from_glass) @as(u35, 1) << b.gray else 0;
        return Board{
            .tiles = b.tiles ^ new_glass,
            .stairs = b.stairs,
            .solid1 = b.solid1,
            .solid2 = b.solid2,
            .solid3 = b.solid3,
            .hovering = 0,
            .gray = p,
            .facing = f,
            .pocket = b.pocket,
        };
    }
    /// The resulting state is specifically the hovering precursor to `b`
    /// Returns `null` iff the existing state `b` is hovering, or there exists a tile there
    fn unmove_to_hovering(b: Board, p: Pos, f: Facing) ?Board {
        if (!wings) unreachable;
        if (p > 34) unreachable;
        if (b.hovering == 1) return null; // already hovering
        if (b.at(p) == .Glass or b.at(p) == .Stairs) unreachable;
        if (b.at(p) == .Tile) return null; // can't hover there
        const unmoving_from_glass = b.at(b.gray) == .Empty;
        const new_glass: u35 = if (unmoving_from_glass) @as(u35, 1) << b.gray else 0;
        return Board{
            .tiles = b.tiles | new_glass,
            .stairs = b.stairs,
            .solid1 = b.solid1,
            .solid2 = b.solid2,
            .solid3 = b.solid3,
            .hovering = 1,
            .gray = p,
            .facing = f,
            .pocket = b.pocket,
        };
    }
    pub fn do_action_breaking(b: Board, a: Action) ?Board {
        if (a == .Z) return null;
        const new_facing: Facing = switch (a) {
            .U => .U,
            .L => .L,
            .R => .R,
            .D => .D,
            else => unreachable,
        };
        const new_pos = move_by(b.gray, new_facing);
        return if (new_pos == b.gray) null else if (b.at(new_pos) != .Glass) null else b.move_to(new_pos, new_facing);
    }
    pub fn do_action_nonbreaking(b: Board, a: Action) ?Board {
        if (a == .Z) return do_action(b, a);
        const new_facing: Facing = switch (a) {
            .U => .U,
            .L => .L,
            .R => .R,
            .D => .D,
            else => unreachable,
        };
        const new_pos = move_by(b.gray, new_facing);
        return if (new_pos == b.gray) null else if (b.at(new_pos) == .Glass) null else b.move_to(new_pos, new_facing);
    }
    pub fn do_action(b: Board, a: Action) ?Board {
        // prohibit bumping
        // in this puzzle there's no need to stall; can't move any objects
        // so it doesnt allow changing facing dir in a useful way
        switch (a) {
            .Z => {
                // get the position in front (pickup/place)
                const forward = move_by(b.gray, b.facing);
                if (forward == b.gray) return null; // same tile denotes would bump
                const f_tile = b.at(forward);
                // pickup if f_tile is full
                // place if it is empty
                return switch (f_tile) {
                    .Empty => b.place(forward), // if b.pocket == 0 null
                    else => b.pickup(forward, f_tile), // if !endless and b.pocket != 0 null
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
    pub fn reverse(b: Board, a: Action) if (wings) [2]?Board else [1]?Board {
        switch (a) {
            .Z => { // symmetrical
                const forward = move_by(b.gray, b.facing);
                if (forward == b.gray) unreachable; // same tile denotes would bump
                const f_tile = b.at(forward);
                // pickup if f_tile is full
                // place if it is empty
                const result = switch (f_tile) {
                    .Empty => b.place(forward),
                    else => b.pickup(forward, f_tile),
                };
                return if (wings) .{ result, null } else result;
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
                if (wings) return .{ b.unmove_to(old_pos, old_facing), b.unmove_to_hovering(old_pos, old_facing) };
                return .{b.unmove_to(old_pos, old_facing)};
            },
        }
    }
    pub fn tileCount(b: Board) u6 {
        return if (stairs_tile) @popCount(b.tiles) + b.pocket - 1 else @popCount(b.tiles) + b.pocket - @as(u6, if (b.stairs > 35) 1 else 0);
    }
    //pub fn pocket(b: Board, tilecount: u6) u6 {
    //    return @popCount(b.tiles) - tilecount;
    //}
    /// Z action is available when:
    ///  - Previous action was not Z  (otherwise we are revisiting a previous state)
    ///  - Not facing the wall or a rock  (ie, position gray is facing is valid)
    ///  - Exactly one of (pocket, facing position) is empty
    pub fn can_Z(b: Board, prev: Action) bool {
        const fw: Pos = move_by(b.gray, b.facing);
        const tile = b.at(fw);
        return prev != .Z and (fw != b.gray) and (if (endless) (tile != .Empty or b.pocket != 0) else ((b.pocket == 0) != (tile == .Empty)));
    }
    pub fn holding_stairs(b: Board) bool {
        return b.stairs > 35;
    }
};

pub const Action = enum(u3) { Z, U, L, R, D };

/// Grid movement (prevent wrapping etc)
pub fn move_by(p: Pos, f: Facing) Pos {
    if (p > 34) unreachable;
    const new_p = switch (f) {
        .U => if (p >= 29) p else p + 6, // p+1 >= 30
        .L => if (p % 6 == 4) p else p + 1, // p+1 % 6 == 5
        .R => if (p % 6 == 5 or p == 0) p else p - 1, // p+1 % 6 == 0
        .D => if (p < 6) p else p - 6, // p+1 < 6 or p==5
    };
    if (new_p > 34) unreachable;
    return new_p;
}

pub const add_tile: u35 = 0b100001_000110_011111_111110_011000_10000;
pub const eus_tile: u35 = 0b110011_001100_110001_111011_110111_11001;
pub const bee_tile: u35 = 0b000001_001100_111001_100111_110011_11100;
pub const tan_tile: u35 = 0b101101_001100_101101_110011_101101_11001;
pub const lev_tile: u35 = 0b100011_001111_100100_001100_000001_11001;
pub const cif_tile: u35 = 0b110001_010101_010010_101000_100100_11000;
pub const dev_tile: u35 = 0b110001_101001_100110_011001_100101_10001;

pub const eus_tot = @popCount(eus_tile);
pub const bee_tot = @popCount(bee_tile);
pub const tan_tot = @popCount(tan_tile);

const start_tiles = 0b111111_111111_111111_111111_111011_11101 | (if (stairs_tile) 0b10 else 0);
const start_glass = 0b000000_001100_001000_000000_000000_00010;
pub const b053 = Board{
    .tiles = start_tiles,
    .stairs = 1,
    .solid1 = 20,
    .solid2 = 25,
    .solid3 = 26,
    .hovering = 0,
    .gray = 26,
    .facing = .D,
    .pocket = 0,
};

test {
    std.testing.refAllDecls(@import("b053_v2.zig"));
}
test "Tile" {
    try std.testing.expect(b053.at(0) == .Glass);
    try std.testing.expect(b053.at(1) == .Stairs);
    try std.testing.expect(b053.at(2) == .Glass);
    try std.testing.expect(b053.at(7) == .Empty);
    try std.testing.expect(b053.at(26) == .Tile);

    // From the 6x6 grid (36 tiles):
    // - One is empty
    // - One is stairs
    // - One is covered by the rock and not included in the state
    try std.testing.expect(b053.tileCount() == 33);
    try std.testing.expect(b053.do_action(.Z).?.tileCount() == 33);
    try std.testing.expect(b053.do_action(.Z).?.solid1 == 25);
    try std.testing.expect(b053.do_action(.Z).?.solid2 == 26);
    try std.testing.expect(b053.do_action(.Z).?.solid3 == 36);
    try std.testing.expect(b053.do_action(.Z).?.do_action(.Z).?.solid1 == 20);
    try std.testing.expect(b053.do_action(.Z).?.do_action(.Z).?.solid2 == 25);
    try std.testing.expect(b053.do_action(.Z).?.do_action(.Z).?.solid3 == 26);
    try std.testing.expect(b053.do_action(.Z).?.do_action(.Z).? == b053);
    try std.testing.expect(b053.do_action(.D).?.tileCount() == 33);
    try std.testing.expect(b053.do_action(.U).?.tileCount() == 32);
}
