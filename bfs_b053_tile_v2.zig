/// BFFS (breadth first frontier search?) searcher for b053
/// where the 'frontier' is the number of tiles remaining on the board
/// Goes in batches by tilecount; discards higher tilecounts after exploring
/// within-tilecount is regular BFS
const std = @import("std");

const brand = @import("b053_v2.zig");
const endless = brand.endless;
const wings = brand.wings;
const stairs_tile = brand.stairs_tile; // are the stairs included in .tiles? false

const log_all_file_dedup_passes = false;

// exit after exploring all states with this number of tiles
const MIN_TILES: u6 = tan_tot;

const pruning: bool = false; // disable best-guess pruning, explore full state space

const BT = @typeInfo(Item).@"struct".backing_integer.?;
const Action = brand.Action;
const Pos = brand.Pos;
const Facing = brand.Facing;
const move_by = brand.move_by;
const Tile = brand.Tile;
const is_duplicate = brand.is_duplicate_board;
const tan_tot = brand.tan_tot;
const tan_tile = brand.tan_tile;
const eus_tot = brand.eus_tot;
const eus_tile = brand.eus_tile;

test {
    std.testing.refAllDecls(@import("bfs_b053_tile_v2.zig"));
}

const notFacingMask = ~@as(BT, 0b111); // include facing and can_Z/cant_Z
inline fn equal_mod_facing(a: Item, b: Item) bool {
    //return @as(BT, @bitCast(a)) & notFacingMask == @as(BT, @bitCast(b)) & notFacingMask;
    return @as(BT, @bitCast(a)) ^ @as(BT, @bitCast(b)) < 8;
}
pub fn item_lessThan(_: void, a: Item, b: Item) bool {
    // used for sorting; just sort as backing int
    return @as(BT, @bitCast(a)) < @as(BT, @bitCast(b));
}
// TODO deduplicate these functions
pub fn duplicate_item(a: Item, b: Item) bool {
    return a == b or (equal_mod_facing(a, b) and (a.cant_z or b.cant_z));
}

//
//
// X cant_Z is dupe of * *
// X can_Z is dupe of X cant_Z **at same depth**
//
// ordering: fine to place facing as LSB and then cant_Z
// we can extend the can/cantZ check over next 4 elements (and accept potential temporary out-of-order for elements that will be removed anyway)
// We don't store previous move info (partially derive it from cant_Z, facing, tiles and depth)
// States are generated with full Facing/Cant_Z info for the same-depth pass
// When stored/compressed, Facing info is discarded for cant_Z states
// - this isn't important for generating successor states
// - when checking against previous-depth states, we also discard full Facing info for cant_Z states
//   since it no longer matters (at most one exists) -- allows improved compression and checking by strict equality
const Item = packed struct(u68) {
    // pocket is implicitly determined by tilecount, omitted from state
    //
    facing: brand.Facing, // u2
    cant_z: bool, // used to simplify deduping
    gray: brand.Pos, // u6
    solid1: brand.Pos,
    solid2: brand.Pos,
    solid3: brand.Pos,
    hovering: if (wings) u1 else u0,
    tiles: u35,
    stairs: u6,

    pub fn invalid(b: Item) bool {
        return (b.cant_z and b.facing != .D); // arbitrarily choose .D as only valid facing for cant_Z states
    }

    pub fn at(b: Item, p: Pos) Tile {
        if (p > 34) unreachable;
        return if (b.stairs == p) .Stairs else if (b.solid1 == p or b.solid2 == p or b.solid3 == p) .Tile else if ((b.tiles >> p) & 1 == 1) .Glass else .Empty;
        //return @enumFromInt(@as(u2, if (b.stairs == p or b.solid1 == p or b.solid2 == p or b.solid3 == p) 1 else 0) | @as(u2, @intCast(((b.tiles >> p) & 1) << 1)));
    }

    fn pickup(b: Item, p: Pos, t: Tile, tilecount: u6) Item { // t is non-empty
        if (p > 34) unreachable;
        const pocket = b.get_pocket(tilecount);
        if (!endless and pocket != 0) unreachable;
        // we can apply the mask even if we are picking up stairs and might not need to
        const remove_mask: u35 = @as(u35, 1) << p;
        const new_pocket = @as(Pos, 36) + pocket;
        var new_solid1: Pos = b.solid1;
        var new_solid2: Pos = b.solid2;
        var new_solid3: Pos = b.solid3;
        if (t == .Tile) { // p in [b.solid1, b.solid2, b.solid3]
            new_solid3 = new_pocket;
            if (p < b.solid3) new_solid2 = b.solid3;
            if (p == b.solid1) new_solid1 = b.solid2;
        }
        return Item{
            .tiles = b.tiles & ~remove_mask,
            .stairs = if (p == b.stairs) new_pocket else b.stairs,
            .solid1 = new_solid1,
            .solid2 = new_solid2,
            .solid3 = new_solid3,
            .hovering = b.hovering,
            .gray = b.gray,
            .facing = b.facing,
            .cant_z = true,
        };
    }

    fn place(b: Item, p: Pos, tilecount: u6) Item {
        // guaranteed p is empty
        if (p > 34) unreachable;
        const pocket = b.get_pocket(tilecount);
        if (pocket == 0) unreachable;
        if (!endless and pocket != 1) unreachable;
        const pocket_top = @as(Pos, 35) + pocket;
        // if !stairs_tile, placing the stairs doesn't update the tile mask
        const tile_mask: u35 = if (!stairs_tile and b.stairs == pocket_top) 0 else (@as(u35, 1) << p);
        var ret = Item{
            .tiles = b.tiles | tile_mask,
            .stairs = b.stairs,
            .solid1 = b.solid1,
            .solid2 = b.solid2,
            .solid3 = b.solid3,
            .hovering = b.hovering,
            .gray = b.gray,
            .facing = b.facing,
            .cant_z = true,
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
    fn move_to(b: Item, p: Pos, f: Facing, pocket: u6) ?Item {
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
        return Item{
            .tiles = b.tiles & ~remove_mask,
            .stairs = b.stairs,
            .solid1 = b.solid1,
            .solid2 = b.solid2,
            .solid3 = b.solid3,
            .hovering = new_hovering,
            .gray = p,
            .facing = f,
            .cant_z = !can_Z_base(pocket, p, f, b.tiles & ~remove_mask, b.stairs),
        };
    }
    /// Unmove from the position of `b` to the previous position+facing state (p, f)
    /// unbreaking glass as necessary, resulting in a grounded (non-hover) state
    fn unmove_to(b: Item, p: Pos, f: Facing) ?Item {
        if (p > 34) unreachable;
        switch (b.at(p)) {
            .Glass, .Stairs => return null, // couldnt have come from there
            else => {},
        }
        // if we weren't hovering, we moved onto glass and broke it
        const unmoving_from_glass = b.at(b.gray) == .Empty and b.hovering == 0;
        const new_glass: u35 = if (unmoving_from_glass) @as(u35, 1) << b.gray else 0;
        return .{
            .tiles = b.tiles ^ new_glass,
            .stairs = b.stairs,
            .solid1 = b.solid1,
            .solid2 = b.solid2,
            .solid3 = b.solid3,
            .hovering = 0,
            .gray = p,
            .facing = f,
            .cant_z = false,
        };
    }
    /// The resulting state is specifically the hovering precursor to `b`
    /// Returns `null` iff the existing state `b` is hovering, or there exists a tile there
    fn unmove_to_hovering(b: Item, p: Pos, f: Facing) ?Item {
        if (!wings) unreachable;
        if (p > 34) unreachable;
        if (b.hovering == 1) return null; // already hovering
        if (b.at(p) == .Glass or b.at(p) == .Stairs) unreachable;
        if (b.at(p) == .Tile) return null; // can't hover there
        const unmoving_from_glass = b.at(b.gray) == .Empty;
        const new_glass: u35 = if (unmoving_from_glass) @as(u35, 1) << b.gray else 0;
        return .{
            .tiles = b.tiles | new_glass,
            .stairs = b.stairs,
            .solid1 = b.solid1,
            .solid2 = b.solid2,
            .solid3 = b.solid3,
            .hovering = 1,
            .gray = p,
            .facing = f,
            .cant_z = false,
        };
    }
    pub fn do_action_breaking(b: Item, a: Action, tilecount: u6) ?Item {
        if (a == .Z) return null;
        const new_facing: Facing = switch (a) {
            .U => .U,
            .L => .L,
            .R => .R,
            .D => .D,
            else => unreachable,
        };
        const new_pos = move_by(b.gray, new_facing);
        return if (new_pos == b.gray) null else if (b.at(new_pos) != .Glass) null else b.move_to(new_pos, new_facing, b.get_pocket(tilecount));
    }
    pub fn do_action_nonbreaking(b: Item, a: Action, tilecount: u6) ?Item {
        if (a == .Z) return do_action(b, a, tilecount);
        const new_facing: Facing = switch (a) {
            .U => .U,
            .L => .L,
            .R => .R,
            .D => .D,
            else => unreachable,
        };
        const new_pos = move_by(b.gray, new_facing);
        return if (new_pos == b.gray) null else if (b.at(new_pos) == .Glass) null else b.move_to(new_pos, new_facing, b.get_pocket(tilecount));
    }
    pub fn do_action(b: Item, a: Action, tilecount: u6) ?Item {
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
                    .Empty => b.place(forward, tilecount), // if pocket == 0 null
                    else => b.pickup(forward, f_tile, tilecount), // if !endless and pocket != 0 null
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
                return if (new_pos == b.gray) null else b.move_to(new_pos, new_facing, b.get_pocket(tilecount));
            },
        }
    }
    pub fn reverse(b: Item, a: Action) if (wings) [2]?Item else [1]?Item {
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
    pub fn get_pocket(b: Item, tilecount: u6) u6 {
        // things in pocket (includes stairs)
        // stairs_tile and holding: 0
        // stairs_tile and not holding stairs:
        if (stairs_tile) {
            @compileLog("unimplemented");
        } else {
            // the stairs if we are holding them, plus all tiles not on the board
            return @as(u6, if (b.holding_stairs()) 1 else 0) + tilecount - @popCount(b.tiles);
        }
    }
    /// Z action is available when:
    ///  - Previous action was not Z  (otherwise we are revisiting a previous state)
    ///  - Not facing the wall or a rock  (ie, position gray is facing is valid)
    ///  - Exactly one of (pocket, facing position) is empty
    /// compute independently of cached b.cant_z
    pub fn can_Z(b: Item, tilecount: u6) bool {
        const pocket = b.get_pocket(tilecount); // things in pocket (includes stairs)
        const fw: Pos = move_by(b.gray, b.facing);
        const tile = b.at(fw);
        return (fw != b.gray) and (if (endless) (tile != .Empty or pocket != 0) else ((pocket == 0) != (tile == .Empty)));
    }
    pub fn holding_stairs(b: Item) bool {
        return b.stairs > 35;
    }
    pub fn empty_pocket_tilecount(b: Item) u6 {
        // don't count stairs in tiles
        return @popCount(b.tiles) - @as(u6, if (stairs_tile) 1 else 0);
    }
};

pub fn can_Z_base(pocket: u6, gray: Pos, facing: Facing, tiles: u35, stairs: u6) bool {
    const fw = move_by(gray, facing);
    const fw_has_tile = (stairs == fw) or (tiles >> fw) & 1 == 1;
    return (fw != gray) and (if (endless) (fw_has_tile or pocket != 0) else ((pocket == 0) == fw_has_tile));
}

// TODO: test whether packing gray+solid+stairs together (gets down to 64 bits given no endless) is good
// -> does it improve on-disk size / compression? how much?
// -> how much does it improve memory usage -- is memory usage still a concern? (current design should mean no)
// -> does it improve speed? (guess: maybe? only impact is during state generation; deduplication is ~the same)
// UNUSED
const Item2 = packed struct(u64) {
    // pocket is implicitly determined by tilecount, omitted from state
    facing: brand.Facing, // u2
    cant_z: bool, // used to simplify deduping
    /// log2(36^5) == 25.85 < 26
    gray_solid_stairs: u26, // (MSB) stairs | solid | gray (LSB)
    hovering: if (wings) u1 else u0,
    tiles: u35,

    fn to_Item(x: @This()) Item {
        return .{
            .facing = x.facing,
            .cant_z = x.cant_z,
            .gray = x.gray_solid_stairs % 36,
            .solid1 = (x.gray_solid_stairs / (36)) % 36,
            .solid2 = (x.gray_solid_stairs / (36 * 36)) % 36,
            .solid3 = (x.gray_solid_stairs / (36 * 36 * 36)) % 36,
            .stairs = (x.gray_solid_stairs / (36 * 36 * 36 * 36)),
            .tiles = x.tiles,
            .hovering = x.hovering,
        };
    }
};

const b053 = Item{
    .facing = brand.b053.facing,
    .cant_z = false,
    .gray = brand.b053.gray,
    .solid1 = brand.b053.solid1,
    .solid2 = brand.b053.solid2,
    .solid3 = brand.b053.solid3,
    .stairs = brand.b053.stairs,
    .tiles = brand.b053.tiles,
    .hovering = 0,
};

pub fn main(init: std.process.Init) !void {
    //var gpa = std.heap.DebugAllocator(.{}){};
    const gpa = init.gpa;
    const io = init.io;
    //const alloc = gpa.allocator();
    const alloc = gpa;
    // open dir
    const dir = try std.Io.Dir.cwd().openDir(io, "b053-data", .{ .iterate = true });
    defer dir.close(io);
    //
    var tilecount: u6 = b053.empty_pocket_tilecount();
    var file_maxdepths: [36]u16 = @splat(0);
    // check if we can resume
    // get the lowest tilecount present in directory
    // also get the highest depth present for previous tilecount, if present initialize prev-maxdepth
    var dir_iter = dir.iterate();
    while (try dir_iter.next(io)) |entry| {
        if (entry.kind == .file) {
            var it = std.mem.splitScalar(u8, entry.name, '.');
            const f_tc = std.fmt.parseInt(u6, it.next() orelse continue, 10) catch continue;
            const f_dep = std.fmt.parseInt(u16, it.next() orelse continue, 10) catch continue;
            const burdens = it.rest();
            if (!std.mem.eql(u8, burdens, "none")) continue;
            // set max depth seen for that tilecount
            if (file_maxdepths[f_tc] < f_dep) file_maxdepths[f_tc] = f_dep;
            if (f_tc < tilecount) tilecount = f_tc;
        }
    }
    var resuming = (file_maxdepths[33] > 0);
    // run steps (each creates a new file "{tilecount}.{depth}.{none|wings}")
    while (tilecount >= MIN_TILES) : (tilecount -= 1) {
        // load info for this tilecount from a previous run if any
        // get the highest depth present in directory for this tilecount
        // TODO load maps for prevs
        std.debug.print("\n ---------- ##### {s} tilecount {} ##### ----------\n\n", .{ if (resuming) "Resuming" else "Starting", tilecount });
        resuming = false;
        var tilecount_prevs: std.ArrayList(?mappedStateStream) = .empty;
        var depth: u16 = file_maxdepths[tilecount] + 1; // start at first depth without a file for it
        if (file_maxdepths[33] == 0) depth = 0 // first-run
        else {
            for (0..depth - 1) |d| {
                // a file may exist for this tilecount; try load it
                // go up to depth-2 instead of depth-1 since the most-recent file is loaded by run_step
                var buf: [20]u8 = undefined;
                const prev_filename = try setFilenameFor(buf[0..], tilecount, @intCast(d));
                try tilecount_prevs.append(alloc, try .init(io, dir, prev_filename));
            }
        }
        while (true) : (depth += 1) {
            const written = try run_step(alloc, io, dir, &tilecount_prevs, tilecount, depth);
            // we are finished with the tilecount if we can no longer either
            //  - make nonbreaking moves (since written = 0)
            //  - make breaking moves (since depth > max prev depth)
            if (written == 0 and depth > file_maxdepths[tilecount + 1]) break;
        }
        file_maxdepths[tilecount] = depth - 1;
        std.debug.print("\n --- End tilecount {}, highest depth was {}\n", .{ tilecount, depth - 1 });
        // unload mapped files of current tilecount
        // (they are no longer needed for deduplication)
        // (we will need each once in the future to generate breaking moves, and can load on demand)
        for (tilecount_prevs.items) |*m| if (m.*) |*map| {
            try map.close(io);
        };
    }
    //try run_bfs_tile(gpa, io, b053.tileCount());
}

fn setFilenameFor(buf: []u8, tilecount: u8, depth: u16) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{d}.{d}." ++ if (wings) "wings" else "none", .{ tilecount, depth });
}

const streamT = compressedStream; // see end of file for definition
const mappedStateStream = struct {
    file: std.Io.File,
    map: std.Io.File.MemoryMap, // keeps a reference to file
    bytelen: u64,
    itemlen: u64,
    pub fn init(io: std.Io, dir: std.Io.Dir, filename: []const u8) !?@This() {
        const file = dir.openFile(io, filename, .{ .mode = .read_only }) catch return null;
        // .populate will have
        // - no effect on windows (SEC_COMMIT) since it is backed by a file (?)
        // - prefault everything on linux
        // - no effect on other OS (eg darwin)
        const map = try file.createMemoryMap(io, .{ .len = try file.length(io), .protection = .{ .read = true } });
        const bytelen = std.mem.bytesToValue(u64, map.memory[0..8]);
        const itemlen = std.mem.bytesToValue(u64, map.memory[8..16]);
        return .{
            .file = file,
            .map = map,
            .bytelen = bytelen,
            .itemlen = itemlen,
        };
    }
    pub fn reader(self: *const @This()) streamT.Reader {
        // TODO
        // advise we will read sequentially
        switch (@import("builtin").os.tag) {
            .windows => {
                //   PrefetchVirtualMemory(); // not yet in zig std?
                //   // https://codeberg.org/ziglang/zig/pulls/30840
                //   // https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-prefetchvirtualmemory
                //   // https://ntdoc.m417z.com/ntsetinformationvirtualmemory
            },
            else => {
                if (@hasDecl(std.posix, "madvise") and @hasDecl(std.posix.MADV, "SEQUENTIAL"))
                    std.posix.madvise(self.map.memory.ptr, self.map.memory.len, std.posix.MADV.SEQUENTIAL) catch |err| {
                        std.debug.print(".............madvise error (SEQUENTIAL): {}\n", .{err});
                    };
            },
        }
        return .{ .bytes = self.map.memory[16..][0..self.bytelen] };
    }
    pub fn end_read(self: *const @This()) void {
        // advise that we no longer need the memory (in the short term)
        // we want it to remain mapped but be discardable / evictable
        // however we shouldn't *force* it to be evicted
        switch (@import("builtin").os.tag) {
            .windows => {
                // TODO windows equivalent
            },
            else => {
                if (@hasDecl(std.posix, "madvise") and @hasDecl(std.posix.MADV, "DONT_NEED")) {
                    try std.posix.madvise(self.map.memory.ptr, self.map.memory.len, std.posix.MADV.DONT_NEED) catch |err| {
                        std.debug.print(".............madvise error (DONT_NEED): {}\n", .{err});
                    };
                }
            },
            // see also [MacOS]:
            // https://github.com/golang/go/issues/29844
            // https://github.com/chromium/chromium/blob/4569aa618714997a4b38a44efaed30592b4cf741/base/memory/discardable_shared_memory.cc#L295
        }
    }
    pub fn close(self: *@This(), io: std.Io) !void {
        self.map.destroy(io); // unmap
        self.file.close(io);
    }
};

const native_endian = @import("builtin").cpu.arch.endian();

/// Backtrace path through state space
fn trace_path_files(io: std.Io, dir: std.Io.Dir, end: Item, depth: u16) !void {
    defer std.debug.print("\n\n", .{});
    var cur: Item = end;
    var d = depth;
    var b = end.b;
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
        b = cur.b.reverse_partial(cur.p); // unknown facing
        d -= 1;
        // search for `b` in appropriate file
        var buf: [20]u8 = undefined;
        // TODO appropriate tilecount
        const filename = try setFilenameFor(buf[0..], b.empty_pocket_tilecount(), d);
        var f: mappedStateStream = try .init(io, dir, filename) orelse {
            std.debug.print("could not open file {s}\n", .{filename});
            @panic("Couldn't find a parent state");
        };
        cur = try f.findMatching(b) orelse {
            std.debug.print("Could not find state {} in file {}\n", .{ b, filename });
            @panic("Couldn't find a parent state");
        };
        f.close();
    }
}

inline fn backing(x: Item) BT {
    return @bitCast(x);
}

inline fn backing_M(x: Item) BT {
    return backing(x) & notFacingMask;
}

fn merge_dedup(current: *std.ArrayList(Item), past_r_orig: streamT.Reader) usize {
    // can_Z < cant_Z
    // return count of duplicate items that were removed
    var past_r = past_r_orig;
    var past_item: Item = past_r.pop() orelse return 0;
    var read_i: usize = 0;
    var write_i: usize = 0;
    loop: while (read_i < current.items.len) : (read_i += 1) {
        const cur = current.items[read_i];
        // maybe advance past until there could be a duplicate
        while (backing_M(past_item) < backing_M(cur)) past_item = past_r.pop() orelse break :loop;
        // if cur can_Z, dupe must be equal: maybe advance past until there
        // we are also guaranteed that no cant_Z state is present (so it's ok to advance past all matching prev states)
        while (!cur.cant_z and backing(past_item) < backing(cur)) past_item = past_r.pop() orelse break :loop;
        // check for equal dupe
        if (past_item == current.items[read_i]) continue;
        // other dupes have different cant_Z.
        // check for (current is cant_Z only, prev is any matching)
        // (we know that prev hasn't been already advanced past because cur is the only state mod facing/Z)
        if (cur.cant_z and backing(past_item) ^ backing(cur) < 8) continue;
        // not dupe: write
        if (write_i < read_i) current.items[write_i] = current.items[read_i];
        write_i += 1;
    }
    while (read_i < current.items.len) : (read_i += 1) {
        if (write_i < read_i) current.items[write_i] = current.items[read_i];
        write_i += 1;
    }
    const ret = current.items.len - write_i;
    current.items.len = write_i;
    return ret;
}

pub fn add_breaking_moves(alloc: std.mem.Allocator, prevs: streamT.Reader, todo: *std.ArrayList(Item), tilecount: u6) !void {
    var r = prevs;
    while (r.pop()) |state| {
        inline for (std.enums.values(Action)) |a| {
            if (a == .Z) continue; // Z can't break glass
            if (state.do_action_breaking(a, tilecount)) |new| {
                // we broke glass if the tiles are different
                if (new.tiles == state.tiles) @panic("didn't break glass");
                try todo.append(alloc, new);
            }
        }
    }
}
pub fn add_nonbreaking_moves(alloc: std.mem.Allocator, prevs: streamT.Reader, todo: *std.ArrayList(Item), tilecount: u6) !void {
    var r = prevs;
    while (r.pop()) |state| {
        inline for (std.enums.values(Action)) |a| {
            if (a == .Z) {
                if (state.cant_z) {} else if (state.do_action_nonbreaking(a, tilecount)) |new| {
                    try todo.append(alloc, new);
                }
            } else if (state.do_action_nonbreaking(a, tilecount)) |new| {
                // we broke glass if the tiles are different
                if (new.tiles != state.tiles) @panic("broke glass somewhere unexpected");
                try todo.append(alloc, new);
            }
        }
    }
}

fn expect_add_x_moves(f: @TypeOf(add_breaking_moves), initial_state: Item, tc: u6, results: anytype) !void {
    switch (@typeInfo(@TypeOf(results))) {
        .array => {},
        else => @compileError("use array of Action or State as result type"),
    }
    var stream: compressedStream = .empty;
    var w = stream.writer();
    defer stream.deinit(std.testing.allocator);
    try w.write(backing(initial_state), std.testing.allocator);
    // read
    var todo: std.ArrayList(Item) = .empty;
    defer todo.deinit(std.testing.allocator);
    try f(std.testing.allocator, stream.reader(), &todo, tc);
    try std.testing.expect(todo.items.len == results.len);
    for (results) |a| {
        try std.testing.expect(std.mem.findScalar(Item, todo.items, initial_state.do_action(a, tc).?) != null);
    }
}
test "add_breaking_moves" {
    const tc = b053.empty_pocket_tilecount();
    try expect_add_x_moves(add_breaking_moves, b053, tc, [2]Action{ .U, .L });
}
test "add_nonbreaking_moves" {
    const tc = b053.empty_pocket_tilecount();
    try expect_add_x_moves(add_nonbreaking_moves, b053, tc, [3]Action{ .Z, .D, .R });
    var b053_alt = b053;
    b053_alt.cant_z = true;
    try expect_add_x_moves(add_nonbreaking_moves, b053_alt, tc, [2]Action{ .D, .R });
    const z = b053.do_action(.Z, tc).?;
    try expect_add_x_moves(add_nonbreaking_moves, z, tc, [1]Action{.R});
}

/// run one tilecount+depth step
/// return: number of states written
/// also, when reading the most recent depth to generate states, add it to the cache
fn run_step(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, tilecount_prevs: *std.ArrayList(?mappedStateStream), tilecount: u6, depth: u16) !usize {
    // grouped by tilecount and move depth
    var todo: std.ArrayList(Item) = .empty;
    std.debug.print("tilecount {} depth {} prevs_len {}\n", .{ tilecount, depth, tilecount_prevs.items.len });
    if (tilecount > b053.empty_pocket_tilecount()) {
        return error.InvalidTilecount;
    }
    if (tilecount == b053.empty_pocket_tilecount() and depth == 0) {
        try todo.append(alloc, b053);
    } else {
        if (depth == 0) return 0;
        var buf: [20]u8 = undefined;
        const filename1 = try setFilenameFor(buf[0..], tilecount + 1, depth - 1);
        var broke_tile_from = try mappedStateStream.init(io, dir, filename1);
        if (broke_tile_from != null) {
            try add_breaking_moves(alloc, broke_tile_from.?.reader(), &todo, tilecount + 1);
            try broke_tile_from.?.close(io);
        }
        // read prev and keep in the cache
        // it may be null (eg for very low depths), that's fine
        const filename2 = try setFilenameFor(buf[0..], tilecount, depth - 1);
        const same_tile_from: ?mappedStateStream = try .init(io, dir, filename2);
        if (same_tile_from) |same_tile| {
            try add_nonbreaking_moves(alloc, same_tile.reader(), &todo, tilecount);
            same_tile.end_read();
        }
        std.debug.assert(depth - 1 == tilecount_prevs.items.len); // it is not in the cache yet (just written)
        try tilecount_prevs.append(alloc, same_tile_from); // keep the mapping in the cache
        if (todo.items.len == 0) {
            // no states generated, exit early
            // skip writing, deallocating (nothing was allocated)
            std.debug.print("tilecount {} depth {}: no states were generated\n", .{ tilecount, depth });
            return 0;
        }
        // sort
        std.sort.pdq(Item, todo.items, {}, item_lessThan);
        // deduplicate inplace: first pass
        var write_i: usize = 0;
        const todo_orig_len = todo.items.len;
        std.debug.print("generated {d:10} states at depth {d:3} with {} tiles\n", .{ todo_orig_len, depth, tilecount });
        loop: for (todo.items, 0..) |r, read_i| {
            // first pass deduplicating can_Z(0) and cant_Z(1) states with same facing
            if (!r.cant_z and read_i + 1 < todo.items.len) {
                var next_four = todo.items[read_i + 1 ..];
                for (next_four[0..@min(4, next_four.len)]) |fw| {
                    if (backing(r) ^ backing(fw) == 0b100) {
                        // this item (r, can_Z) is a duplicate
                        // the future item (fw, cant_Z) may or may not be a dupe, will be detected later
                        continue :loop;
                    }
                }
            }
            if (read_i + 1 < todo.items.len and duplicate_item(r, todo.items[read_i + 1])) {
                // since we encounter can_Z states before cant_Z states, i+1 is a duplicate
                todo.items[read_i + 1] = r;
                continue;
            }
            if (write_i > read_i) unreachable;
            if (write_i < read_i) todo.items[write_i] = todo.items[read_i];
            write_i += 1;
        }
        todo.shrinkAndFree(alloc, write_i);
        //todo.items.len = write_i;
        // unify facing for cant_Z states, prior to deduplicating against previous depths
        for (todo.items[0..]) |*r| {
            if (r.cant_z) r.*.facing = .D; // D (0b11) is arbitrarily chosen as the only valid facing with cant_Z
        }
        var removed = todo_orig_len - write_i;
        // TODO update todo length
        std.debug.print("initial pass deduped {d} states ({d:2}%)\n", .{ removed, removed * 100 / todo_orig_len });
        // deduplicate: following passes (less likely to dedup)
        var file_passes_removed: usize = 0;
        for (0..depth / 2) |dd| {
            const d = depth - 2 - 2 * dd;
            const prev: mappedStateStream = tilecount_prevs.items[d] orelse continue;
            removed = merge_dedup(&todo, prev.reader());
            if (log_all_file_dedup_passes) std.debug.print("file pass depth {d} deduped {d} states ({d:2}%)\n", .{ d, removed, removed * 100 / todo_orig_len });
            file_passes_removed += removed;
        }
        std.debug.print("file passes deduped {d} states ({d:2}%)\n", .{ file_passes_removed, file_passes_removed * 100 / todo_orig_len });
    }
    // todo.shrinkAndFree(todo.items.len);
    const ret = todo.items.len;
    // write empty file if we removed all states
    // compress
    std.debug.print("Compressing\n", .{});
    var compressed: streamT = .empty;
    {
        var w = compressed.writer();
        for (todo.items) |item| try w.write(backing(item), alloc);
    }
    todo.deinit(alloc);

    // write to file
    var fnamebuf: [20]u8 = undefined;
    const filename = try setFilenameFor(fnamebuf[0..], tilecount, depth);
    var file = try dir.createFile(io, filename, .{});
    {
        var writebuf: [1024]u8 = undefined;
        var w = file.writer(io, writebuf[0..]);
        try w.interface.writeAll(&std.mem.toBytes(compressed.arr.items.len)); // bytelen
        try w.interface.writeAll(&std.mem.toBytes(compressed.len)); // itemlen
        try w.interface.writeAll(compressed.arr.items);
        try w.end();
    }
    const written_bytes = compressed.arr.items.len + 16;
    file.close(io);
    compressed.deinit(alloc);
    std.debug.print("Done writing to file (wrote {} states in {d} kib: avg {:.2} bytes/state)\n\n", .{ ret, written_bytes / 1024, @as(f64, @floatFromInt(written_bytes)) / @as(f64, @floatFromInt(ret)) });
    return ret;
}

test "compressedStream round-trip" {
    var states: [9]Item = undefined;
    const tc = b053.empty_pocket_tilecount();
    // Add some states to make sure we exercise both short-diff and long-diff code paths
    // ensure we don't add states that would be deduplicated before being serialized
    // additionally, fix 'invalid' states (with cant_Z==true) to also have .facing==.D
    states[0] = b053;
    try std.testing.expect(states[0].cant_z == false);
    try std.testing.expect(!states[0].invalid());
    //
    states[1] = b053.do_action(.Z, tc).?; // facing already .D
    try std.testing.expect(states[1].cant_z == true);
    try std.testing.expect(!states[1].invalid());
    //
    states[2] = b053.do_action(.U, tc).?;
    try std.testing.expect(states[2].cant_z == true);
    try std.testing.expect(states[2].invalid());
    states[2].facing = .D;
    try std.testing.expect(!states[2].invalid());
    //
    states[3] = b053.do_action(.D, tc).?;
    try std.testing.expect(states[3].tiles == b053.tiles);
    try std.testing.expect(states[3].gray == b053.gray - 6);
    try std.testing.expect(states[3].facing == .D);
    try std.testing.expect(states[3].at(states[3].gray) == .Tile);
    try std.testing.expect(states[3].at(states[3].gray - 6) == .Glass);
    try std.testing.expect(states[3].cant_z == false);
    try std.testing.expect(!states[3].invalid());
    //
    states[4] = b053.do_action(.L, tc).?;
    try std.testing.expect(states[4].cant_z == false);
    try std.testing.expect(!states[4].invalid());
    //
    states[5] = b053.do_action(.R, tc).?;
    try std.testing.expect(states[5].cant_z == false);
    try std.testing.expect(!states[5].invalid());
    //
    states[6] = b053.do_action(.Z, tc).?.do_action(.L, tc).?;
    try std.testing.expect(states[6].cant_z == true);
    try std.testing.expect(states[6].invalid());
    states[6].facing = .D;
    try std.testing.expect(!states[6].invalid());
    //
    states[7] = b053.do_action(.Z, tc).?.do_action(.R, tc).?;
    try std.testing.expect(states[7].cant_z == true);
    try std.testing.expect(states[7].invalid());
    states[7].facing = .D;
    try std.testing.expect(!states[7].invalid());
    //
    states[8] = b053.do_action(.Z, tc).?.do_action(.U, tc).?;
    try std.testing.expect(states[8].cant_z == true);
    try std.testing.expect(states[8].invalid());
    states[8].facing = .D;
    try std.testing.expect(!states[8].invalid());
    //
    std.sort.pdq(Item, states[0..9], {}, item_lessThan);
    var stream: compressedStream = .empty;
    var w = stream.writer();
    defer stream.deinit(std.testing.allocator);
    for (states[0..9]) |item| {
        try w.write(backing(item), std.testing.allocator);
    }
    var r = stream.reader();
    var i: usize = 0;
    while (r.pop()) |val| : (i += 1) {
        try std.testing.expect(val == states[i]);
    }
    try std.testing.expect(i == 9);
}

// stream byte union {
//   zero | unused
//   8bits single-byte-diff (+)
//   6.5bits extended-diff-1  (if + would result in invalid) (variable-length diff (+), 4 bits are length, 2 unused)
// }
const compressedStream = struct {
    arr: std.ArrayList(u8),
    len: usize,

    const empty: @This() = .{
        .arr = .empty,
        .len = 0,
    };
    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.arr.deinit(alloc);
        self.len = 0;
    }
    const Reader = struct {
        bytes: []const u8,
        byte_offset: usize = 0,
        state: ?BT = null,
        fn hasNext(self: *@This()) bool {
            return self.byte_offset < self.bytes.len;
        }
        fn pop(self: *@This()) ?Item {
            //std.debug.print("pop: offset {} bytes {any}\n", .{ self.byte_offset, self.bytes[self.byte_offset..] });
            if (self.byte_offset >= self.bytes.len) return null;
            if (self.byte_offset == 0) {
                self.byte_offset = (@bitSizeOf(BT) + 7) / 8;
                self.state = std.mem.bytesToValue(BT, self.bytes[0..self.byte_offset]);
                return @bitCast(self.state.?);
            }
            if (self.state == null) unreachable;
            const diff = self.bytes[self.byte_offset];
            self.byte_offset += 1;
            if (diff == 0) {
                return null; // TODO zero is unused? (means zero-terminated stream additionally continues to return null)
            }
            const candidate: Item = @bitCast(self.state.? +% diff);
            if (candidate.cant_z and candidate.facing != .D) {
                // reinterpret diff
                const diff_bytes = diff >> 4;
                //std.debug.print("read: byte {d}, diff_bytes: {d}\n", .{ diff, diff_bytes });
                // TODO handle endianness if necessary
                const real_diff: BT = @intCast(std.mem.readVarInt(std.math.ByteAlignedInt(BT), self.bytes[self.byte_offset..][0..diff_bytes], native_endian));
                self.byte_offset += diff_bytes;
                self.state = self.state.? + real_diff;
                //std.debug.print("read: real_diff {}, new state {}\n", .{ real_diff, self.state.? });
                return @bitCast(self.state.?);
            } else {
                self.state = @bitCast(candidate);
                //std.debug.print("read: single byte diff {}, new state {}\n", .{ diff, self.state.? });
                return candidate;
            }
        }
    };
    fn reader(self: *const @This()) Reader {
        return .{ .bytes = self.arr.items };
    }
    fn write(self: *@This(), state: ?BT, b: BT, alloc: std.mem.Allocator) !void {
        //std.debug.print("writing state {} diff from {any}: ", .{ b, state });
        const BTsize = (@bitSizeOf(BT) + 7) / 8;
        self.len += 1;
        if (state == null) {
            const bytes = std.mem.toBytes(b);
            // TODO is this correct for both endian?
            const trimmed: *const [BTsize]u8 = switch (native_endian) {
                .little => bytes[0..BTsize],
                .big => bytes[@sizeOf(BT) - BTsize ..],
            };
            try self.arr.appendSlice(alloc, trimmed[0..]);
            //std.debug.print("wrote full state {any}\n", .{trimmed[0..]});
            return;
        }
        const diff = b - state.?;
        if (diff == 0) {
            std.debug.print("duplicate write of value: {b} {}", .{ b, b });
            return error.DuplicateWrite;
        }
        // Special-case small diffs - use 1 byte
        if (diff < 256) {
            try self.arr.append(alloc, @intCast(diff));
            //std.debug.print("wrote single byte {d}\n", .{diff});
            return;
        } else {
            // V load-bearing print statement (anywhere above the following line) changes what is written
            //std.debug.print("writing state {} diff from {any}: ", .{ b, state });
            // either affected stack layout or masking, such that the extra bytes (not part of teh backing int) changed
            // technically this was relying on 'undefined behaviour' that these extra bytes were zero
            // remove the trimming and run zig test to see effect
            const diff_bytes = std.mem.toBytes(diff);
            const trimmed: *const [BTsize]u8 = switch (native_endian) {
                .little => diff_bytes[0..BTsize],
                .big => diff_bytes[@sizeOf(BT) - BTsize ..],
            };
            var d: []const u8 = trimmed[0..];
            // TODO check endianness handled correctly when trimming
            switch (native_endian) {
                .little => {
                    while (d[d.len - 1] == 0) d = d[0 .. d.len - 1];
                },
                .big => {
                    while (d[0] == 0) d = d[1..];
                },
            }
            const length = d.len;
            // find the first invalid offset
            // const invalid_offset = @as(u3, @bitcast(packed struct {facing: Facing = .U, cant_z: bool = true}{}))-%@as(u3, @intCast(diff & 0b111));
            const invalid_offset: usize = blk: for (1..8) |x| {
                if (@as(Item, @bitCast(state.? + @as(BT, x))).invalid()) break :blk x;
            } else @panic("couldn't find nearby invalid state");
            try self.arr.append(alloc, @intCast((length << 4) + invalid_offset));
            try self.arr.appendSlice(alloc, d);
            //std.debug.print("wrote sentinel {} and {} bytes {any}\n", .{ ((length << 4) + invalid_offset), length, d });
            return;
        }
        @panic("didn't write");
        // zero case?
        // try self.arr.append(alloc, 0);
        // ...
    }
    const Writer = struct {
        stream: *compressedStream,
        state: ?BT = null,
        fn write(self: *@This(), b: BT, alloc: std.mem.Allocator) !void {
            try self.stream.write(self.state, b, alloc);
            self.state = b;
        }
    };
    fn writer(self: *@This()) Writer {
        return .{ .stream = self };
    }
};
