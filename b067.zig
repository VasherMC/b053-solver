/// Solver for B067
const std = @import("std");

pub const Facing = enum(u2) { U, L, R, D };
fn backwards(f: Action) Facing {
    return switch (f) {
        .U => .D,
        .L => .R,
        .R => .L,
        .D => .U,
        else => unreachable,
    };
}
pub const Pos = u6;
inline fn can_see(p1: Pos, p2: Pos) ?Action {
    // assumes no obstructions
    // are they in the same column?
    if (p1 % 6 == p2 % 6) return if (p1 > p2) .D else .U;
    // are they in the same row?
    if (p1 / 6 == p2 / 6) return if (p1 > p2) .R else .L;
    return null; // can't see
}

const endless = true;
const wings = true;
const sword = true;

pub const BT = @typeInfo(Board).@"struct".backing_integer.?;
/// Least significant to most significant bits
pub const Board = packed struct(if (endless) u64 else u60) {
    facing: Facing,
    gray: Pos,
    pocket: if (endless) u5 else u1, // count of tiles (Endless Rod) - only need u5
    tiles: u36, // bit set = tile (or stairs)
    stairs: u6, // 0-35 for a specific tile; 36+ is its position in the pocket
    beaver: packed struct(u9) {
        p: Pos, // 0-35 for a specific tile, 36+ for dead
        facing: Action, // ULDR or Z for stopped
    },

    pub const invalid: Board = @bitCast(@as(BT, 0));
    pub fn at(b: Board, p: Pos) u1 {
        if (p > 35) unreachable;
        return @intCast((b.tiles >> p) & 1);
    }
    inline fn update_beaver(b: Board) ?Board {
        return if (b.beaver.p < 36) switch (b.beaver.facing) {
            // beaver is stopped
            .Z => if (can_see(b.beaver.p, b.gray)) |dir| b.move_beaver(dir) else b,
            // beaver is moving: continue
            else => b.move_beaver(b.beaver.facing),
        } else b;
    }
    inline fn move_beaver(b: Board, dir: Action) ?Board {
        const new_p = move_by_a(b.beaver.p, dir);
        if (new_p == b.gray) return null; // beaver hits if able
        // beaver moves or not
        return .{
            .facing = b.facing,
            .gray = b.gray,
            .pocket = b.pocket,
            .tiles = b.tiles,
            .stairs = b.stairs,
            .beaver = if (b.at(new_p) == 0 or b.beaver.p == new_p) .{ .p = b.beaver.p, .facing = .Z } else .{ .p = new_p, .facing = dir },
        };
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
            .beaver = b.beaver,
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
            .beaver = b.beaver,
            // .can_z = false,
        };
    }
    fn move_to(b: Board, p: Pos, f: Facing) ?Board {
        // Check if the move is allowed
        if (p == 5) unreachable;
        if (p == b.stairs) return null;
        const hovering: bool = b.at(b.gray) == 0;
        if ((!wings or hovering) and b.at(p) == 0) return null; // cannot continue hovering
        if (p == b.beaver.p) return null; // can't move into beaver
        // update the state as appropriate
        return Board{
            .tiles = b.tiles,
            .gray = p,
            .facing = f,
            .pocket = b.pocket,
            .stairs = b.stairs,
            .beaver = b.beaver,
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
            .beaver = b.beaver,
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
                if (forward == b.beaver.p) {
                    return if (sword) .{ // kill beaver
                        .facing = b.facing,
                        .gray = b.gray,
                        .tiles = b.tiles,
                        .pocket = b.pocket,
                        .stairs = b.stairs,
                        .beaver = .{ .p = 36, .facing = .Z },
                        // we could retain facing state for simpler backtracking
                        // however it's better to set facing so that we can deduplicate dead-beaver states
                    } else null; // can't pickup from under beaver
                }
                const f_tile = b.at(forward);
                // pickup if a tile is there
                // place if its empty
                return switch (f_tile) {
                    1 => if (endless or b.pocket == 0) b.pickup(forward).update_beaver() else null,
                    0 => if (b.pocket > 0) b.place(forward).update_beaver() else null,
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
                return if (new_pos == b.gray) null else if (b.move_to(new_pos, new_facing)) |result| result.update_beaver() else null;
            },
        }
    }
    pub fn reverse(b: Board, a: Action) Board {
        // Doesn't take enemy movement or sword into account; only reverses player action
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
                // maybe unkill beaver: it can be facing any direction (including .Z) except away from gray
                //if (sword and b.beaver.p == 36) result.append(...);
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
    pub fn reverse_full(b_end: Board, a: Action) [5]Board {
        var result: [5]Board = @splat(Board.invalid);
        var s: usize = 0;
        const bs = b_end.unmove_beaver();
        const forward_if_Z = move_by(b_end.gray, b_end.facing);
        for (bs) |bv| if (bv != Board.invalid) {
            if (a == .Z and bv.beaver.p == 36 and b_end.at(forward_if_Z) == 1) {
                // handle unkilling beaver at forward_if_Z
                var x = bv;
                x.beaver.p = forward_if_Z; // facing remains same (is retained on death)
                for (std.enums.values(Action)) |f| {
                    if (f != @as(Action, switch (b_end.facing) { // couldn't have sworded beaver facing away from gray
                        .U => .U,
                        .L => .L,
                        .R => .R,
                        .D => .D,
                    })) {
                        x.beaver.facing = f;
                        if (x.do_action(.Z) != b_end) @panic("bad logic");
                        result[s] = x;
                        s += 1;
                    }
                }
            }
            // handle normal additions
            const pb = bv.reverse(a);
            if (pb.do_action(if (a == .Z) .Z else switch (b_end.facing) {
                .U => .U,
                .L => .L,
                .R => .R,
                .D => .D,
            }) == b_end) {
                result[s] = pb;
                s += 1;
            }
        };
        return result;
    }
    fn unmove_beaver(b: Board) [5]Board {
        // Beaver options:
        // If beaver is moving in `b`:
        //  - Move it backwards by its direction, keeping facing
        //  - If move was into LOS: it could have been triggering the beaver (can additionally set facing=.Z stopped)
        // If beaver is stopped in `b`:
        //  - it could have been moving, and stopped by (edge/entity): set direction but dont move
        //  - it could have been stopped
        //    - add check that reproducing the move results in same beaver state (remaining stopped)
        var result: [5]Board = @splat(Board.invalid);
        if (b.beaver.p == 36) {
            result[0] = b;
            return result;
        }
        const beaver_to_gray = can_see(b.beaver.p, b.gray);
        if (b.beaver.facing != .Z) {
            var nb = b;
            const back = backwards(b.beaver.facing);
            nb.beaver.p = move_by(b.beaver.p, back);
            const further_back = move_by(nb.beaver.p, back);
            if (!(further_back == nb.beaver.p or b.at(further_back) == 0)) {
                // it can only unmove in `facing` if it doesnt have its back to wall/edge
                result[0] = nb;
            }
            // If facing gray, could have just started moving from stop
            if (beaver_to_gray == b.beaver.facing) {
                var nb2 = nb;
                nb2.beaver.facing = .Z;
                result[1] = nb2;
            }
        } else {
            // beaver ends up stopped
            // we filter possible beaver states later
            for (std.enums.values(Action), 0..) |a, i| {
                result[i] = b;
                result[i].beaver.facing = a;
            }
        }
        return result;
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

// B067 has a blocker in the lower left (p=5)
// we just never return it instead of removing it from the range
pub fn move_by(p: Pos, f: Facing) Pos {
    return switch (f) {
        .U => if (p > 29) p else p + 6,
        .L => if (p % 6 == 5 or p == 4) p else p + 1,
        .R => if (p % 6 == 0) p else p - 1,
        .D => if (p < 6 or p == 11) p else p - 6,
    };
}

pub fn move_by_a(p: Pos, f: Action) Pos {
    return switch (f) {
        .Z => unreachable,
        .U => move_by(p, .U),
        .L => move_by(p, .L),
        .R => move_by(p, .R),
        .D => move_by(p, .D),
    };
}

pub const add_tile: u36 = 0b100001_000110_011111_111110_011000_100001;
pub const bee_tile: u36 = 0b000001_001100_111001_100111_110011_111001;
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
    // can we place a tile to fill a missing spot
    const can_place = (b.pocket != 0) and (b.stairs -% 36 != b.pocket) and (b.beaver.p != forward);
    const excess = (b.tiles & ~goal) | stairs; // stairs are always excess
    const missing = goal & ~(b.tiles ^ stairs); // stairs don't count as a filling tile
    // good facing if we can pick up excess or fill missing
    // (since stairs are counted as excess, doesnt matter if they are also in missing)
    // if facing wall/statue, we can't pickup or place there
    const good_facing: u8 = if (forward == b.gray) 0 else @intCast(((excess >> forward) & 1) | if (can_place) (missing >> forward) & 1 else 0);
    return 2 * (@popCount(excess) + @popCount(missing)) - good_facing;
}

// B067 start (Stairs appear as a tile here)
const start_tiles = 0b001110_011011_010001_010110_100011_111110;
pub const b067 = Board{
    .tiles = start_tiles,
    .gray = 14,
    .facing = .D,
    .pocket = 0,
    .stairs = 16,
    .beaver = .{ .p = 16, .facing = .Z },
};

test "reverse" {
    try std.testing.expect(b067.do_action(.R).?.reverse(.D) == b067);
}
test "b067_start" {
    try std.testing.expect(b067.at(0) == 0);
    try std.testing.expect(b067.at(1) == 1);
    try std.testing.expect(b067.at(14) == 1);
    try std.testing.expect(b067.at(16) == 1);
    try std.testing.expect(b067.at(35) == 0);

    try std.testing.expect(b067.cant_Z(.D));
    if (wings) try std.testing.expect(b067.do_action(.L) == null);
    if (wings) try std.testing.expect(b067.do_action(.D) != null);
    if (!wings) try std.testing.expect(b067.do_action(.D) == null);
    if (wings) try std.testing.expect(b067.do_action(.U).?.do_action(.D).? == b067);
    try std.testing.expect(b067.do_action(.R).?.cant_Z(.R));
    try std.testing.expect(!b067.do_action(.R).?.do_action(.D).?.cant_Z(.D));
    if (wings and sword) try std.testing.expect(b067.do_actions("DZURLZ").?.do_action(.Z).?.beaver.p == 36);
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
