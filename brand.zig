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
    pub inline fn walkable(t: Tile) u1 {
        return @intCast(@intFromEnum(t) >> 1);
    }
};

/// To opt-in to wings movement, declare `pub const wings = true;` in the searcher file
pub const wings = false;
const allow_wings: bool = blk: {
    const root = @import("root");
    if (@hasDecl(root, "wings")) break :blk root.wings;
    break :blk wings;
};

pub const BT = @typeInfo(Board).@"struct".backing_integer.?;
/// Least significant to most significant bits
/// (important for bucketing [top 16 bits] / sorting)
/// having tiles as MSB cuts time at depth 38 from 30s->25s (mostly in sorting) compared to having glass as MSB
/// having facing as LSB is important for deduplication while processing
pub const Board = packed struct(u80) {
    facing: Facing,
    gray: Pos,
    pocket: Tile,
    glass: u35, // bit set = unusual (walkable->solid instead of glass, unwalkable->stairs [or hover state])
    tiles: u35, // bit set = walkable (tile/glass)

    pub const invalid: Board = @bitCast(@as(BT, 0));
    pub fn at(b: Board, p: Pos) Tile {
        if (p > 34) unreachable;
        return @enumFromInt(@as(u2, @intCast((b.glass >> p) & 1)) | @as(u2, @intCast(((b.tiles >> p) & 1) << 1)));
    }

    fn pickup(b: Board, p: Pos, t: Tile) Board { // t is non-empty
        if (p > 34) unreachable;
        if (b.pocket != .Empty) unreachable;
        const remove_mask: u35 = @as(u35, 1) << p;
        return Board{
            .tiles = b.tiles & ~remove_mask,
            .glass = b.glass & ~remove_mask,
            .gray = b.gray,
            .facing = b.facing,
            .pocket = t,
        };
    }

    fn place(b: Board, p: Pos) Board {
        // guaranteed p is empty
        if (p > 34) unreachable;
        if (b.pocket == .Empty) unreachable;
        //const mask: u35 = @as(u35, 1) << p;
        //const tile_mask = if (b.pocket > 1) mask else 0;
        //const glass_mask = if (b.pocket & 1 == 1) mask else 0;
        const tile_mask = @as(u35, (@intFromEnum(b.pocket) >> 1) & 1) << p;
        const glass_mask = @as(u35, @intFromEnum(b.pocket) & 1) << p;
        return Board{
            .tiles = b.tiles | tile_mask,
            .glass = b.glass | glass_mask,
            .gray = b.gray,
            .facing = b.facing,
            .pocket = .Empty,
        };
    }
    fn move_to(b: Board, p: Pos, f: Facing) ?Board {
        if (p > 34) unreachable;
        // Check if the move is allowed
        if (allow_wings) {
            if (b.at(p) == .Stairs) return null; // even with wings, can't move to stairs
            // hover state is given by b.at(b.gray) == .Stairs (temporarily)
            // b.at(b.gray) == .Empty indicates broken glass instead
            const hovering: bool = b.at(b.gray) == .Stairs;
            if (hovering and b.at(p) == .Empty) return null; // cannot continue hovering
        } else {
            if ((b.tiles >> p) & 1 == 0) return null; // can't move to unwalkable .Empty/.Stairs
        }
        // update the state as appropriate
        const need_to_break_glass = (b.glass >> p) & 1 == 0; // b.at(p) == .Glass (/.Empty)
        const remove_mask: u35 = if (need_to_break_glass) @as(u35, 1) << p else 0;
        // hover state is stored in the 'unusual' bit of the current tile
        // if newly hovering, mark that; if previously hovering, unmark that
        const new_hovering = if (allow_wings and b.at(p) == .Empty) @as(u35, 1) << p else 0;
        const old_hovering = if (allow_wings and b.at(b.gray) == .Stairs) @as(u35, 1) << b.gray else 0;
        return Board{
            .tiles = b.tiles & ~remove_mask,
            .glass = b.glass ^ new_hovering ^ old_hovering,
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
        // if unmoving from hover (stairs), replace air there
        // if unmoving from air, unbreak glass there (since we were grounded, not hovering)
        const unmoving_from_glass = b.at(b.gray) == .Empty;
        const new_glass: u35 = if (unmoving_from_glass) @as(u35, 1) << b.gray else 0;
        const unmoving_from_hover = allow_wings and b.at(b.gray) == .Stairs;
        const remove_hover: u35 = if (unmoving_from_hover) @as(u35, 1) << b.gray else 0;
        return Board{
            .tiles = b.tiles ^ new_glass,
            .glass = b.glass ^ remove_hover,
            .gray = p,
            .facing = f,
            .pocket = b.pocket,
        };
    }
    /// The resulting state is specifically the hovering precursor to `b`
    /// Returns `null` iff the existing state `b` is hovering, or there exists a tile there
    fn unmove_to_hovering(b: Board, p: Pos, f: Facing) ?Board {
        if (!allow_wings) unreachable;
        if (p > 34) unreachable;
        if (b.at(p) == .Glass or b.at(p) == .Stairs) unreachable;
        if (b.at(p) == .Tile) return null; // can't hover there
        if (b.at(b.gray) == .Stairs) return null; // alredy hovering
        const unmoving_from_glass = b.at(b.gray) == .Empty;
        const new_glass: u35 = if (unmoving_from_glass) @as(u35, 1) << b.gray else 0;
        const hover = @as(u35, 1) << p;
        return Board{
            .tiles = b.tiles | new_glass,
            .glass = b.glass | hover,
            .gray = p,
            .facing = f,
            .pocket = b.pocket,
        };
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
                // pickup if our pocket is empty
                // place if it is full
                return switch (b.pocket) {
                    .Empty => if (f_tile == .Empty) null else b.pickup(forward, f_tile),
                    else => if (f_tile != .Empty) null else b.place(forward),
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
    pub fn reverse(b: Board, a: Action) if (allow_wings) [2]?Board else Board {
        switch (a) {
            .Z => { // symmetrical
                const forward = move_by(b.gray, b.facing);
                if (forward == b.gray) unreachable; // same tile denotes would bump
                const f_tile = b.at(forward);
                // pickup if our pocket is empty
                // place if it is full
                const result = switch (b.pocket) {
                    .Empty => b.pickup(forward, f_tile),
                    else => b.place(forward),
                };
                return if (allow_wings) .{ result, null } else result;
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
                if (allow_wings) return .{ b.unmove_to(old_pos, old_facing), b.unmove_to_hovering(old_pos, old_facing) };
                return b.unmove_to(old_pos, old_facing);
            },
        }
    }
    pub fn tileCount(b: Board) u6 {
        return @popCount(b.tiles) + b.pocket.walkable();
    }
    /// Z action is available when:
    ///  - Previous action was not Z  (otherwise we are revisiting a previous state)
    ///  - Not facing the wall or a rock  (ie, position gray is facing is valid)
    ///  - Exactly one of (pocket, facing position) is empty
    pub fn can_Z(b: Board, prev: Action) bool {
        const fw: Pos = move_by(b.gray, b.facing);
        const tile = b.at(fw);
        return prev != .Z and (fw != b.gray) and ((b.pocket == .Empty) != (tile == .Empty));
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
pub const SE_tile: u35 = 0b110001_101001_100110_011001_100101_10001;

pub const eus_tot = @popCount(eus_tile);
pub const bee_tot = @popCount(bee_tile);
pub const tan_tot = @popCount(tan_tile);

const start_tiles = 0b111111_111111_111111_111111_111011_11101;
const start_glass = 0b000000_001100_001000_000000_000000_00010;
pub const b053 = Board{
    .tiles = start_tiles,
    .glass = start_glass,
    .gray = 26,
    .facing = .D,
    .pocket = .Empty,
};

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
    try std.testing.expect(b053.do_action(.D).?.tileCount() == 33);
    try std.testing.expect(b053.do_action(.U).?.tileCount() == 32);
}

pub fn check_solution(b: Board, tilecount: usize) bool {
    var solution = false;
    if (b.tiles == add_tile) {
        std.debug.print("\n\n\n\n\nfound a solution for Add\n", .{});
        solution = true;
    }
    if (b.tiles == eus_tile) {
        std.debug.print("\n\n\n\n\nfound a solution for Eus\n", .{});
        solution = true;
    }
    if (b.tiles == bee_tile) {
        std.debug.print("\n\n\n\n\nfound a solution for Bee\n", .{});
        solution = true;
    }
    if (b.tiles == tan_tile) {
        std.debug.print("\n\n\n\n\nfound a solution for Tan\n", .{});
        solution = true;
    }
    //if ((b.tiles ^ tan_tile) & 0xffff == 0) {
    //    std.debug.print("\n\n\nFound partial solution for bottom half of Tan\n", .{});
    //    solution = true;
    //}
    if (solution) {
        std.debug.print("{}\ntilecount={}  tiles={b}  glass={b:035}\n\n\n\n", .{ b, tilecount, b.tiles, b.glass });
    }
    return solution;
}

/// Check whether states are effectively duplicates
/// Any of:
///  - They are equal
///  - They only differ in facing direction and facing direction does not matter
pub fn is_duplicate(pi: usize, a: u64, b: u64, prev_a: Action, prev_b: Action) bool {
    if (a == b) return true;
    if ((a ^ b) > 3) return false;
    // if only facing (low 2 bits) is different, might be able to prune (board+pos+pocket is the same)
    // if neither can Z, we can treat them as equivalent
    if (prev_a == .Z and prev_b == .Z) return true; // can't Z twice in a row
    const ab: Board = @bitCast((@as(u80, @intCast(pi)) << 64) | @as(u80, @intCast(a)));
    const bb: Board = @bitCast((@as(u80, @intCast(pi)) << 64) | @as(u80, @intCast(a)));
    return !ab.can_Z(prev_a) and !bb.can_Z(prev_b);
}

pub fn is_duplicate_board(a: Board, b: Board, prev_a: Action, prev_b: Action) bool {
    if (a == b) return true;
    if (@as(u80, @bitCast(a)) ^ @as(u80, @bitCast(b)) > 3) return false;
    if (prev_a == .Z and prev_b == .Z) return true; // can't Z twice in a row
    return !a.can_Z(prev_a) and !b.can_Z(prev_b);
}

pub fn is_duplicate_board2(a: Board, b: Board, a_cant_z: bool, b_cant_z: bool) bool {
    if (a == b) return true;
    if (@as(u80, @bitCast(a)) ^ @as(u80, @bitCast(b)) > 3) return false;
    return a_cant_z and b_cant_z;
}
