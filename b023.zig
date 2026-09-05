/// Solver for Trailer brand on B223 with Wings and Endless Rod
const std = @import("std");

pub const Facing = enum(u2) { U, L, R, D };
pub const Pos = u6; // 36 positions

const endless = true;
const wings = true;

/// Least significant to most significant bits
pub const Board = packed struct(u58) {
    facing: Facing,
    gray: Pos,
    pocket: u8, // count of tiles (Endless Rod) - only need u5 for the 18 tiles on B023
    tiles: u36, // bit set = tile. Cut from u36->u32 due to statues in corners on B223
    stairs: u6, // 0-35 for a specific tile; 36+ is its position in the pocket

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
        return prev == .Z or (fw == b.gray) or if (endless) ((b.pocket == 0) and (tile == 0)) else (@as(u1, @intCast(b.pocket)) == b.tile);
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

// B223 start (Stairs appear as a tile here)
const start_tiles = 0b100101_000110_011111_111110_011000_100001;
pub const b023 = Board{
    .tiles = start_tiles,
    .gray = 15,
    .facing = .D,
    .pocket = 0,
    .stairs = 32,
};

test "Tile" {
    try std.testing.expect(b023.at(0) == 1);
    try std.testing.expect(b023.at(1) == 0);
    try std.testing.expect(b023.at(15) == 1);
    try std.testing.expect(b023.at(32) == 1);
    try std.testing.expect(b023.at(35) == 1);

    try std.testing.expect(!b023.cant_Z(.D));
    try std.testing.expect(b023.do_action(.D).?.do_action(.D).?.do_action(.D) == null);
    try std.testing.expect(b023.do_action(.D).?.do_action(.R).?.do_action(.R) == null);
    try std.testing.expect(b023.do_action(.U).?.do_action(.D).? == b023);
    try std.testing.expect(b023.do_action(.D).?.cant_Z(.D));
    try std.testing.expect(b023.do_action(.U).?.cant_Z(.U));
}

/// Check whether states are effectively duplicates
/// Any of:
///  - They are equal
///  - They only differ in facing direction and facing direction does not matter
pub fn is_duplicate_board(a: Board, b: Board, a_cant_z: bool, b_cant_z: bool) bool {
    return is_duplicate(@bitCast(a), @bitCast(b), a_cant_z, b_cant_z);
}

pub fn is_duplicate(a: u58, b: u58, a_cant_z: bool, b_cant_z: bool) bool {
    if (a == b) return true;
    if (a ^ b > 3) return false;
    return a_cant_z and b_cant_z;
}
