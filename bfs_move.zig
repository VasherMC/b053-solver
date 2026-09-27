/// BFS bruteforcer for b053
const std = @import("std");

const brand = @import("brand.zig");

const Board = brand.Board;
const Action = brand.Action;
const Pos = brand.Pos;
const b053 = brand.b053;
const is_duplicate = brand.is_duplicate;
const tan_tot = brand.tan_tot;
const tan_tile = brand.tan_tile;

const check_solution = brand.check_solution;

pub fn main(init: std.process.Init) !void {
    //var gpa = std.heap.DebugAllocator(.{}){};
    const gpa = init.gpa;
    const io = init.io;
    //const alloc = gpa.allocator();
    std.debug.print("{} {}\n\n", .{ @sizeOf(u80), @sizeOf(Board) });
    try run_bfs_partition2(gpa, io);
}

// Optimizations:
// - bfs with sortedmerge instead of hashmap
// - compress sorted visited/todo streams with xor diff and variable-length encoding
// - partition frontier into buckets[quotienting] to speed up sorting and reduce size
// - more aggressive pruning of likely-bad states
// - ignore facing state where it's not important, to more aggressively deduplicate states
// - bucket[quotient] the todo list (frontier) and visited set as well (partition2)
//    -> compression ratio drops from ~3.3 to ~2.4  (30% saving) in visited set
// - improve compression in visited set ~25% (-> 1.8) by prioritizing small values
//    -> slightly worsens compression in frontier subset
// - avoid de/recompressing final part of visited set during merge -> no noticeable difference

const compressedStream8 = struct {
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
        state: ?u64 = null,
        next_offset: ?usize = null,
        fn hasNext(self: *@This()) bool {
            return self.byte_offset < self.bytes.len;
        }
        fn peek(self: *@This()) ?u64 {
            if (self.byte_offset >= self.bytes.len) return null;
            if (self.byte_offset == 0) {
                return std.mem.bytesToValue(u64, self.bytes[0..8]);
            }
            if (self.state == null) unreachable;
            var diff = self.bytes[self.byte_offset];
            // start at with high order bytes
            var mask: u64 = diff; // Short case (non-zero): done
            var read_offset: usize = self.byte_offset + 1;
            if (diff == 0) {
                // Long case: read the actual mapping mask
                diff = self.bytes[read_offset];
                read_offset += 1;
                for (0..8) |bit_idx| {
                    mask <<= 8;
                    const bit = (diff >> @as(u3, @intCast(7 - bit_idx))) & 1;
                    if (bit == 1) {
                        const byte = self.bytes[read_offset];
                        read_offset += 1;
                        mask |= byte;
                    }
                }
            }
            self.next_offset = read_offset;
            return self.state.? ^ mask;
        }
        fn drop(self: *@This(), state: u64) void {
            if (self.next_offset) |off| {
                self.byte_offset = off;
                self.state = state;
                self.next_offset = null;
            } else {
                _ = self.pop();
            }
        }
        fn pop(self: *@This()) ?u64 {
            //std.debug.print("pop: offset {} bytes {any}\n", .{ self.byte_offset, self.stream.*.arr.items[self.byte_offset..] });
            self.next_offset = null;
            if (self.byte_offset >= self.bytes.len) return null;
            if (self.byte_offset == 0) {
                self.state = std.mem.bytesToValue(u64, self.bytes[0..8]);
                self.byte_offset = 8;
                return self.state.?;
            }
            if (self.state == null) unreachable;
            // decompress
            // VPEXPANDB
            var diff = self.bytes[self.byte_offset];
            self.byte_offset += 1;
            // start at with high order bytes
            var mask: u64 = diff; // Short case (non-zero): done
            if (diff == 0) {
                // Long case: read the actual mapping mask
                diff = self.bytes[self.byte_offset];
                self.byte_offset += 1;
                for (0..8) |bit_idx| {
                    mask <<= 8;
                    const bit = (diff >> @as(u3, @intCast(7 - bit_idx))) & 1;
                    if (bit == 1) {
                        const byte = self.bytes[self.byte_offset];
                        self.byte_offset += 1;
                        mask |= byte;
                    }
                }
            }
            //std.debug.print("pop: xoring state with {b}\n", .{mask});
            self.state = self.state.? ^ mask;
            return self.state.?;
        }
    };
    fn reader(self: *const @This()) Reader {
        return .{ .bytes = self.arr.items };
    }
    fn write(self: *@This(), state: ?u64, b: u64, alloc: std.mem.Allocator) !void {
        self.len += 1;
        if (state == null) {
            const bytes = std.mem.toBytes(b);
            std.debug.assert(bytes.len == 8);
            try self.arr.appendSlice(alloc, bytes[0..8]);
            return;
        }
        var diff = state.? ^ b;
        //const orig_diff = diff;
        if (diff == 0) {
            std.debug.print("duplicate write of u64 value: {b} {}", .{ b, b });
            return error.DuplicateWrite;
        }
        // Special-case small diffs - use 1 byte instead of 1 + (variable)
        // this means for larger diffs we instead use 2 + (variable) bytes
        // empirically this is ~80% of cases, so should result in improved compression
        // (at 50 depth: 132994184 instances (133M) of 1-255 vs approx 34M of 256+ )
        // -> result: at 50 depth, from ~2.4 bytes/item down to ~1.8 (400MB to 300MB, or 25% saving)
        // Along with a runtime improvement of ~8% (13s to 12s)
        // Though: the todo/frontier size increased by ~15% (4.0 to 4.6, or around 40->46 MB)
        // -> acceptable tradeoff
        if (diff < 256) {
            try self.arr.append(alloc, @intCast(diff));
            return;
        }
        try self.arr.append(alloc, 0);
        // compress
        // Result is big-endian, i.e. first byte must become highest-order in decompressed result
        // ASM: VPCOMPRESSB
        var bytes: [8]u8 = undefined;
        var offset: usize = 8;
        var mask: u8 = 0;
        for (0..8) |bit| {
            const byte: u8 = @intCast(diff & 0xff);
            if (byte != 0) {
                offset -= 1;
                bytes[offset] = byte;
                mask |= @as(u8, 1) << @as(u3, @intCast(bit));
            }
            diff >>= 8;
        }
        //std.debug.assert(diff == 0);
        //std.debug.print("writing: diff {b} {any} encoded-idx {b} {any} compressed-diff {any}\n", .{ orig_diff, std.mem.toBytes(orig_diff)[0..10], mask, std.mem.toBytes(mask), bytes[offset..10] });
        try self.arr.appendSlice(alloc, &std.mem.toBytes(mask));
        try self.arr.appendSlice(alloc, bytes[offset..8]);
    }
    const Writer = struct {
        stream: *compressedStream8,
        state: ?u64,
        fn write(self: *@This(), b: u64, alloc: std.mem.Allocator) !void {
            try self.stream.write(self.state, b, alloc);
            self.state = b;
        }
    };
    fn writer(self: *@This()) Writer {
        return .{ .stream = self, .state = null };
    }
};

test "compressedStream8" {
    const alloc = std.testing.allocator;
    var stream: compressedStream8 = .empty;
    defer stream.deinit(alloc);
    var w = stream.writer();
    var r = stream.reader();
    try std.testing.expect(r.peek() == null);
    var next = try std.ArrayList(u64).initCapacity(alloc, 5);
    defer next.deinit(alloc);

    for (1..6) |a| {
        const result = a * a;
        next.appendAssumeCapacity(result);
        try w.write(result, alloc);
    }
    for (next.items) |item| {
        const pk = r.peek().?;
        const compr = r.pop().?;
        try std.testing.expect(pk == compr);
        std.debug.print("expect: {}\ndecomp: {}\n", .{ item, compr });
        try std.testing.expect(item == compr);
    }
    try std.testing.expect(!r.hasNext());
}

/// Backtrace path through state space given a bucketed set of state-streams and parent-actions
fn trace_path_partitioned(alloc: std.mem.Allocator, seen_streams: []const compressedStream8, parents: []const std.ArrayList(Action), end: Board) !void {
    var b = end;
    var path = try std.ArrayList(Action).initCapacity(alloc, 30);
    defer path.deinit(alloc); // we output to stdout and then don't need it anymore
    while (b != b053) {
        const last_action: Action = blk: {
            // search for b in the seen list to find the matching action
            const bin: u16 = @intCast(@as(u80, @bitCast(b)) >> 64);
            const val: u64 = @truncate(@as(u80, @bitCast(b)));
            var r = seen_streams[bin].reader();
            var i: usize = 0;
            // just linear search; bin size mostly follows an exponential distribution
            // and also we don't care that much about time here
            while (r.pop()) |candidate| : (i += 1) {
                if (val == candidate) break :blk parents[bin].items[i];
            }
            @panic("Couldn't find state in visited set");
        };
        try path.append(alloc, switch (last_action) {
            .Z => .Z,
            else => switch (b.facing) {
                .U => .U,
                .L => .L,
                .R => .R,
                .D => .D,
            },
        });
        const r = b.reverse(last_action);
        b = r; // r[1] orelse r[0].?;
    }
    for (0..path.items.len) |j| {
        const a = path.items[path.items.len - 1 - j];
        std.debug.print("{c}", .{@as(u8, switch (a) {
            .Z => 'Z',
            .U => 'U',
            .L => 'L',
            .R => 'R',
            .D => 'D',
        })});
    }
    std.debug.print("\n\n", .{});
}

const Timestamp = std.Io.Timestamp;

// split into function that can be parallelized
fn mergeStream8(alloc: std.mem.Allocator, top: u16, seen: *compressedStream8, todo_out: *compressedStream8, seen_par: *std.ArrayList(Action), pt: std.ArrayList(u64), pr: std.ArrayList(Action), dupes: *usize) !void {
    // Only called when pt.items.len > 0
    if (pt.items.len == 0) unreachable;
    if (seen.len == 0 and pt.items.len == 0) return; // nop
    if (pt.items.len == 0) {
        // no items to add to this bucket, we can skip de/re-compressing
        // TODO return new copy to avoid fragmentation / make memory access more sequential?
        return;
    }
    var new_stream: compressedStream8 = .empty;
    var seen_r = seen.reader();
    var seen_w = new_stream.writer();
    var new_todo: compressedStream8 = .empty;
    var todo_w = new_todo.writer();
    var out_par: std.ArrayList(Action) = try .initCapacity(alloc, seen_par.items.len);
    //...
    var seen_i: usize = 0;
    var j: usize = 0;
    // merge seen_r stream with pt (new frontier states) stream
    while (seen_r.hasNext() and j < pt.items.len) {
        // clear duplicates from sorted
        while (j + 1 < pt.items.len and is_duplicate(top, pt.items[j], pt.items[j + 1], pr.items[j], pr.items[j + 1])) {
            dupes.* += 1;
            j += 1;
        }
        const seen_r_peek = seen_r.peek().?;
        if (seen_r_peek == pt.items[j]) { // advance both
            seen_r.drop(seen_r_peek);
            try seen_w.write(seen_r_peek, alloc);
            try out_par.append(alloc, seen_par.items[seen_i]);
            seen_i += 1;
            j += 1;
        } else if (seen_r_peek < pt.items[j]) { // advance seen
            seen_r.drop(seen_r_peek);
            try seen_w.write(seen_r_peek, alloc);
            try out_par.append(alloc, seen_par.items[seen_i]);
            seen_i += 1;
        } else { // advance frontier
            try todo_w.write(pt.items[j], alloc);
            try seen_w.write(pt.items[j], alloc);
            try out_par.append(alloc, pr.items[j]);
            j += 1;
        }
    }
    if (seen_r.hasNext()) { // frontier exhausted but still have existing seen/closed set
        // append one more through the writer to ensure state matches
        try seen_w.write(seen_r.pop().?, alloc);
        try out_par.append(alloc, seen_par.items[seen_i]);
        seen_i += 1;
        // memcpy the rest since now the writer/compression state will be the same
        if (seen_i < seen.len) {
            try new_stream.arr.appendSlice(alloc, seen.arr.items[seen_r.byte_offset..]);
            // make sure to track the length correctly
            new_stream.len += (seen.len - seen_i);
            try out_par.appendSlice(alloc, seen_par.items[seen_i..]);
        }
    }
    while (j < pt.items.len) { // seen exhausted
        while (j + 1 < pt.items.len and is_duplicate(top, pt.items[j], pt.items[j + 1], pr.items[j], pr.items[j + 1])) {
            dupes.* += 1;
            j += 1;
        }
        try todo_w.write(pt.items[j], alloc);
        try seen_w.write(pt.items[j], alloc);
        try out_par.append(alloc, pr.items[j]);
        j += 1;
    }
    //...
    if (seen.len != 0) {
        seen.deinit(alloc);
        seen_par.deinit(alloc);
    }
    seen.* = new_stream;
    seen_par.* = out_par;
    todo_out.* = new_todo;
}

// Currently active
fn run_bfs_partition2(alloc: std.mem.Allocator, io: std.Io) !void {
    // https://www.snellman.net/blog/archive/2018-07-23-optimizing-breadth-first-search/
    const b053top: u16 = @intCast(@as(u80, @bitCast(b053)) >> 64);
    const b053val: u64 = @truncate(@as(u80, @bitCast(b053)));
    // Invariant: todo contains one depth
    var todo = [_]compressedStream8{.empty} ** 65536;
    try todo[b053top].write(null, b053val, alloc);
    var todo_len: usize = 1;
    // Invariant: seen is sorted by (state)  [ignoring depth]
    var seen = [_]compressedStream8{.empty} ** 65536;
    try seen[b053top].write(null, b053val, alloc);
    var seen_par = [_]std.ArrayList(Action){.empty} ** 65536;
    try seen_par[b053top].append(alloc, .Z);
    var seen_len: usize = 1;
    //
    //var parent = std.ArrayList(Action).init(alloc);
    //try parent.append(.Z);  // ULDR denote previous *facing* direction before move
    for (1..200) |depth| {
        //var insert_duration = 0;
        //TODO:
        const t_start = Timestamp.now(io, .awake);
        std.debug.print("\n\ndepth {}  todo {}\n", .{ depth, todo_len });
        const insert_start = Timestamp.now(io, .awake);
        // frontier parts
        var parts = [_]std.ArrayList(u64){.empty} ** 65536;
        //
        var parents = [_]std.ArrayList(Action){.empty} ** 65536;
        var i: usize = 0;
        for (&todo, 0..65536) |*todo_bucket, top| {
            // can parallelize, but need to synchronize writes
            if (todo_bucket.len == 0) continue;
            var todo_r = todo_bucket.reader();
            while (todo_r.pop()) |low| : (i += 1) {
                if (i % 1000000 == 0) std.debug.print("progress = {}% {}/{} total={}\n", .{ (i * 100) / todo_len, i, todo_len, seen_len + todo_len });
                const b: Board = @bitCast((@as(u80, @intCast(top)) << 64) | @as(u80, @intCast(low)));
                if (b.pocket == .Stairs) {
                    if (check_solution(b, b.tileCount())) {
                        //
                        try trace_path_partitioned(alloc, seen[0..], seen_par[0..], b);
                    }
                }
                for (std.enums.values(Action)) |a| {
                    if (b.do_action(a)) |result| {
                        const tilecount = b.tileCount();
                        if (tilecount < tan_tot) continue; // not enough tiles left for Tan
                        // rough heuristic that we don't want to walk on these tiles
                        // so we can exclude these states entirely (not even in visited set) to save storage
                        if (result.gray == 0 or result.gray == 3 or result.gray == 4 or result.gray == 5 or result.gray == 10 or result.gray == 11 or result.gray == 16 or result.gray == 34 or result.gray == 29) continue;
                        // can't deduplicate facing here because we dont know which states are possible to backtrack from
                        // Heuristic: we need to fill missing tiles
                        // assume that we need to break at least 1 glass to place each missing tile
                        // - If we have a raft, we need to break glass tiles to place off that row/column
                        // - If we don't have a raft, we also need to break glass tiles to place further
                        // - We also likely need to break glass just to pickup tiles needing to be moved
                        // - So the ideal situation (where we can just move glass from too-full areas to empty areas)
                        //   doesn't really exist (exception for pocket tile, maybe also current-facing
                        // so true required tiles is is higher (though this is heuristic so we leave buffer)
                        // If this is 21 + 1x missing-tiles, search completes in ~2m
                        // dropping down to 21 + 2/3x, takes 16m to complete at depth 169
                        //   -> This means that any successful TAN solution
                        //      would at some point be in a situation where it could fill all remaining gaps
                        //      without breaking as many glass tiles as it is moving
                        //TODO
                        //if (tilecount < 21 + (2 * @popCount(tan_tile & ~result.tiles) / 3)) continue;
                        // needs to wait until post-sorting
                        const bin: u16 = @intCast(@as(u80, @bitCast(result)) >> 64);
                        const val: u64 = @truncate(@as(u80, @bitCast(result)));
                        try parts[bin].append(alloc, val);
                        //
                        try parents[bin].append(alloc, switch (a) {
                            .Z => .Z,
                            else => switch (b.facing) { // our previous facing
                                .U => .U,
                                .L => .L,
                                .R => .R,
                                .D => .D,
                            },
                        });
                    }
                }
            }
            todo_bucket.deinit(alloc);
        }
        const insert_dur = insert_start.untilNow(io, .awake).toNanoseconds();
        std.debug.print("sorting frontier\n", .{});
        const sort_start = Timestamp.now(io, .awake);
        //for (parts) |p| {
        //    std.sort.pdq(u64, p.items, {}, std.sort.asc(u64));
        //}
        for (parts, parents) |p, pr| {
            // instead of sorting both simultaneously
            // just store vals(actions) in hashmap, sort keys (states), and refill actions
            var m: std.AutoHashMap(u64, Action) = .init(alloc);
            defer m.deinit();
            for (p.items, pr.items) |b, a| {
                try m.put(b, a);
            }
            std.sort.pdq(u64, p.items, {}, std.sort.asc(u64));
            for (p.items, 0..) |b, pi| {
                pr.items[pi] = m.get(b).?;
            }
        }
        const sort_dur = sort_start.untilNow(io, .awake).toNanoseconds();
        // merge sorted next (depth=d) with sorted seen (depth<d)
        std.debug.print("merging\n", .{});
        const merge_start = Timestamp.now(io, .awake);
        seen_len = 0;
        todo_len = 0;
        var dupes: usize = 0;
        var total: usize = 0; // total frontier candidates, before deduplicating
        var seen_bytes: usize = 0;
        var todo_bytes: usize = 0;
        // todo is write-only here
        var bucket_items: [65536]usize = undefined;
        var unchanged_buckets: usize = 0;
        for (&seen, &todo, &seen_par, &parts, &parents, 0..65536) |*s, *t, *sp, *pt, *pr, top| {
            if (pt.items.len == 0) {
                // nothing to be done
                unchanged_buckets += 1;
                bucket_items[top] = s.len;
                seen_len += s.len;
                seen_bytes += s.arr.items.len;
                continue;
                //todo_len += 0;
            }
            total += pt.items.len;
            try mergeStream8(alloc, @truncate(top), s, t, sp, pt.*, pr.*, &dupes);
            seen_len += s.len;
            bucket_items[top] = s.len;
            todo_len += t.len;
            seen_bytes += s.arr.items.len;
            todo_bytes += t.arr.items.len;
            pt.deinit(alloc);
            pr.deinit(alloc);
        }
        const merge_dur = merge_start.untilNow(io, .awake).toNanoseconds();
        // print distribution of changed/unchanged buckets
        std.debug.print("{d: >5} buckets ({}%) were unchanged\n", .{ unchanged_buckets, unchanged_buckets * 100 / 65536 });
        // print distribution of bucket sizes
        std.sort.pdq(usize, bucket_items[0..65536], {}, std.sort.asc(usize));
        var count: u16 = 0;
        var last: usize = bucket_items[0]; // = 0 likely
        var min_diff: usize = 1;
        for (bucket_items[1..]) |sz| {
            count += 1;
            if (sz == last) continue;
            // print stats
            if (sz - last >= min_diff) {
                std.debug.print("{d: >5} buckets ({}%) contained between {} and {} items\n", .{ count, @as(u64, count) * 100 / 65536, last, sz - 1 });
                count = 0;
                last = sz;
                min_diff *= 2;
            }
        }
        std.debug.print("{d: >5} buckets ({}%) contained between {} and {} items\n", .{ count, @as(u64, count) * 100 / 65536, last, bucket_items[65535] - 1 });
        // diff stats
        if (false) {
            var diffs = [_]usize{0} ** 8;
            var diffs2 = [_]usize{0} ** 8;
            for (seen, 0..65536) |s, _| {
                if (s.len <= 1) continue;
                var sr = s.reader();
                var c = sr.pop().?;
                while (sr.pop()) |n| {
                    const d: u64 = n ^ c;
                    c = n;
                    diffs[(63 - @clz(d)) / 8] += 1;
                    if (s.len > 128) diffs2[(63 - @clz(d)) / 8] += 1;
                }
            }
            std.debug.print("diff distribution (xor all): 1-8 {d}, 9-16 {d}, 17-24 {d}, 25-32 {d}, 33-42 {d}, etc {} {} {}\n", .{ diffs[0], diffs[1], diffs[2], diffs[3], diffs[4], diffs[5], diffs[6], diffs[7] });
            std.debug.print("diff distribution (len>128): 1-8 {d}, 9-16 {d}, 17-24 {d}, 25-32 {d}, 33-42 {d}, etc {} {} {}\n", .{ diffs2[0], diffs2[1], diffs2[2], diffs2[3], diffs2[4], diffs2[5], diffs2[6], diffs2[7] });
        }

        std.debug.print("done merge (input dupes: {}% | {}/{}), deallocating\n", .{ dupes * 100 / total, dupes, total });
        const t_dur = t_start.untilNow(io, .awake).toNanoseconds();
        std.debug.print("compression stats | seen: ratio {:.3} items {} size {}kb\n", .{
            @as(f64, @floatFromInt(seen_bytes)) / @as(f64, @floatFromInt(seen_len)),
            seen_len,
            seen_bytes / 1024,
        });
        std.debug.print("compression stats | todo: ratio {:.3} items {} size {}kb\n", .{
            @as(f64, @floatFromInt(todo_bytes)) / @as(f64, @floatFromInt(todo_len)),
            todo_len,
            todo_bytes / 1024,
        });
        std.debug.print("timing stats | frontier-gen {}% sort {}% merge {}% total {}ms\n", .{
            @divFloor(insert_dur * 100, t_dur),
            @divFloor(sort_dur * 100, t_dur),
            @divFloor(merge_dur * 100, t_dur),
            @divFloor(t_dur, 1000000),
        });
        if (todo_len == 0) break;
    }
    std.debug.print("finished bruteforcing with full partitioning\n\n", .{});
}
