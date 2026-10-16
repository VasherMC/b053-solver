/// Basic definitions constant across all branes
const std = @import("std");

pub const Facing = enum(u2) {
    U,
    L,
    R,
    D,

    pub fn reverse(f: Facing) Facing {
        return switch (f) {
            .U => .D,
            .L => .R,
            .R => .L,
            .D => .U,
        };
    }
    pub fn from(a: Action) Facing {
        return switch (a) {
            .U => .U,
            .L => .L,
            .R => .R,
            .D => .D,
            .Z => unreachable,
        };
    }
    pub fn format(f: Facing, w: *std.Io.Writer) !void {
        try w.writeByte(switch (f) {
            .U => 'U',
            .L => 'L',
            .R => 'R',
            .D => 'D',
        });
    }
};

pub const Action = enum(u3) {
    Z,
    U,
    L,
    R,
    D,

    pub fn from(a: anytype) Action {
        return switch (@TypeOf(a)) {
            u8 => switch (a) {
                'U' => .U,
                'L' => .L,
                'R' => .R,
                'D' => .D,
                'Z' => .Z,
                else => unreachable,
            },
            Facing => switch (a) {
                .U => .U,
                .L => .L,
                .R => .R,
                .D => .D,
            },
            else => comptime unreachable,
        };
    }
    pub fn format(a: Action, w: *std.Io.Writer) !void {
        try w.writeByte(switch (a) {
            .U => 'U',
            .L => 'L',
            .R => 'R',
            .D => 'D',
            .Z => 'Z',
        });
    }
};

// 0-35 but higher numbers may be used to denote pocket ordering (endless)
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

/// Grid movement
/// Prevent wrapping in a brand room, not taking any blockers into account
pub fn default_move_by(p: Pos, f: Facing) Pos {
    if (p > 35) unreachable;
    const new_p = switch (f) {
        .U => if (p >= 30) p else p + 6, // top row can't move up
        .L => if (p % 6 == 5) p else p + 1, // etc
        .R => if (p % 6 == 0) p else p - 1,
        .D => if (p < 6) p else p - 6,
    };
    if (new_p > 35) unreachable;
    return new_p;
}

pub fn print(state: anytype) void {
    if (@hasDecl(@TypeOf(state), "print")) {
        state.print();
    } else std.debug.print("{}: {any}\n", .{ @TypeOf(state), state });
}

pub fn verify_actions(start_state: anytype, actions: []const u8, debug: bool) !@TypeOf(start_state) {
    var result = start_state;
    for (actions, 0..) |c, i| {
        if (result.do_action(.from(c))) |next| {
            result = next;
        } else {
            if (debug) {
                var arrow_buf: [1024]u8 = @splat(' ');
                arrow_buf[i] = '^';
                std.debug.print("invalid move {c} at position {}:\n{s}\n{s}\n", .{ c, i, actions, arrow_buf[0..actions.len] });
                print(result);
            }
            return error.InvalidMove;
        }
    }
    return result;
}

pub fn verify_brand(start_state: anytype, end_tiles: @TypeOf(start_state.tiles), actions: []const u8) !void {
    var result = try verify_actions(start_state, actions, true);
    try std.testing.expect(result.tiles == end_tiles);
    try std.testing.expect(result.holding_stairs());
}

test {
    try verify_brand(@import("b023.zig").b023, add_tile, "URUZ");
    try std.testing.expect(verify_actions(@import("b023.zig").b023, "DDD", false) == error.InvalidMove);
}

pub const add_tile: u36 = 0b100001_000110_011111_111110_011000_100001;
pub const eus_tile: u36 = 0b110011_001100_110001_111011_110111_110011;
pub const bee_tile: u36 = 0b000001_001100_111001_100111_110011_111001;
pub const mon_tile: u36 = 0b100011_011101_110011_011101_100011_111000;
pub const tan_tile: u36 = 0b101101_001100_101101_110011_101101_110011;
pub const gor_tile: u36 = 0b001100_001100_100100_110001_111100_111100;
pub const lev_tile: u36 = 0b100011_001111_100100_001100_000001_110011;
pub const cif_tile: u36 = 0b110001_010101_010010_101000_100100_110001;
pub const trailer_tile: u36 = 0b100001_000000_010010_110011_000000_101101;
pub const dev_tile: u36 = 0b110001_101001_100110_011001_100101_100011;
