/// Solver for Trailer brand on B223 with Wings and Endless Rod
const std = @import("std");

pub const Facing = enum(u2) { U, L, R, D };
pub const Action = enum(u3) { Z, U, L, R, D };
pub const Pos = u6; // 32 positions

/// Least significant to most significant bits
pub const Board = packed struct(u48) {
    facing: Facing,
    gray: Pos,
    pocket: u8, // count of tiles (Endless Rod) - only need u4 for the 11 tiles on B223
    tiles: u32, // bit set = tile. Cut from u36->u32 due to statues in corners on B223

    pub fn at(b: Board, p: Pos) u1 {
        return @intCast((b.tiles >> @as(u5, @intCast(p))) & 1);
    }

    fn pickup(b: Board, p: Pos) Board { // t is non-empty
        const remove_mask: u32 = @as(u32, 1) << @as(u5, @intCast(p));
        return Board{
            .tiles = b.tiles & ~remove_mask,
            .gray = b.gray,
            .facing = b.facing,
            .pocket = b.pocket + 1,
            // .can_z = false,
        };
    }

    fn place(b: Board, p: Pos) Board {
        // guaranteed p is empty
        if (b.pocket == 0) unreachable;
        const tile_mask = @as(u32, 1) << @as(u5, @intCast(p));
        return Board{
            .tiles = b.tiles | tile_mask,
            .gray = b.gray,
            .facing = b.facing,
            .pocket = b.pocket - 1,
            // .can_z = false,
        };
    }
    fn move_to(b: Board, p: Pos, f: Facing) ?Board {
        // Check if the move is allowed
        // Stairs never exist on the board
        // hover state is given by b.at(b.gray) == 0
        const hovering: bool = b.at(b.gray) == 0;
        if (hovering and b.at(p) == 0) return null; // cannot continue hovering
        // update the state as appropriate
        return Board{
            .tiles = b.tiles,
            .gray = p,
            .facing = f,
            .pocket = b.pocket,
        };
    }
    /// Unmove from the position of `b` to the previous position+facing state (p, f)
    fn unmove_to(b: Board, p: Pos, f: Facing) Board {
        return Board{
            .tiles = b.tiles,
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
            .Z => { // symmetrical
                // get the position in front (pickup/place)
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
        return prev == .Z or (fw == b.gray) or ((b.pocket == 0) and (tile == 0));
    }
};

/// Grid movement (prevent wrapping etc)
/// B223 has all corners blocked by statues
/// X....X
/// ......
/// ......
/// ......
/// 987654
/// X3210X
pub fn move_by(p: Pos, f: Facing) Pos {
    return switch (f) {
        .U => if (p > 26 or p == 22) p else if (p < 4 or p > 22) p + 5 else p + 6,
        .L => if (p % 6 == 3 or p == 31) p else p + 1,
        .R => if (p % 6 == 4 or p == 0) p else p - 1,
        .D => if (p < 5 or p == 9) p else if (p < 9 or p > 27) p - 5 else p - 6,
    };
}

pub const trailer_tile: u32 = 0b0000_000000_010010_110011_000000_0110;

/// basic heuristic for brand rooms without glass / breakable tiles
/// Is a consistent heuristic, both with and without the Endless Rod.
/// However it does not account for hovering state with wings.
pub fn heuristic(a: u32) u8 {
    // for each tile that is different, we must either take or place it
    // Also for each such tile, we must move to face it
    // (we may already be facing one such tile)
    return @popCount(a ^ trailer_tile) * 2 - 1;
}

// B223 start (Cif's brand, having already picked up the stairs)
const start_tiles = 0b1000_010101_010010_101000_100100_1000;
pub const b223 = Board{
    .tiles = start_tiles,
    .gray = 6,
    .facing = .D,
    .pocket = 0,
};

test "Tile" {
    try std.testing.expect(b223.at(0) == 0);
    try std.testing.expect(b223.at(31) == 1);
    try std.testing.expect(b223.at(6) == 1);

    try std.testing.expect(b223.cant_Z(.D));
    try std.testing.expect(b223.do_action(.D).?.do_action(.D) == null);
    try std.testing.expect(b223.do_action(.U).?.do_action(.U) == null);
    try std.testing.expect(b223.do_action(.U).?.do_action(.D).? == b223);
    try std.testing.expect(b223.do_action(.D).?.cant_Z(.D));
    try std.testing.expect(b223.do_action(.U).?.cant_Z(.U));
}

/// Check whether states are effectively duplicates
/// Any of:
///  - They are equal
///  - They only differ in facing direction and facing direction does not matter
pub fn is_duplicate_board(a: Board, b: Board, a_cant_z: bool, b_cant_z: bool) bool {
    return is_duplicate(@bitCast(a), @bitCast(b), a_cant_z, b_cant_z);
}

pub fn is_duplicate(a: u48, b: u48, a_cant_z: bool, b_cant_z: bool) bool {
    if (a == b) return true;
    if (a ^ b > 3) return false;
    return a_cant_z and b_cant_z;
}
