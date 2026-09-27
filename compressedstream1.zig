const std = @import("std");
const brand = @import("brand.zig");
const Action = brand.Action;
const Board = brand.Board;
const do_action = brand.do_action;
const reverse = brand.reverse;
const b053 = brand.b053;

const itemType = Board;
const compressedStream = struct {
    arr: std.ArrayList(u8),
    len: usize,

    fn init() @This() {
        return .{
            .arr = .empty,
            .len = 0,
        };
    }
    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.arr.deinit(alloc);
        self.len = 0;
    }
    const Reader = struct {
        bytes: []const u8,
        byte_offset: usize = 0,
        items: usize,
        item_offset: usize = 0,
        state: ?u80 = null,
        fn hasNext(self: *@This()) bool {
            return self.item_offset < self.items;
        }
        fn peek(self: *@This()) ?itemType {
            if (self.item_offset >= self.items) return null;
            if (self.byte_offset == 0) {
                return @bitCast(std.mem.bytesToValue(u80, self.bytes[0..10]));
            }
            if (self.state == null) unreachable;
            const cmpr_indices = self.bytes[self.byte_offset..][0..2];
            const diff = std.mem.bytesToValue(u10, cmpr_indices);
            // start at with high order bytes
            var mask: u80 = 0;
            var i: usize = 2;
            for (0..10) |bit_idx| {
                mask <<= 8;
                const bit = (diff >> @as(u4, @intCast(9 - bit_idx))) & 1;
                if (bit == 1) {
                    const byte = self.bytes[self.byte_offset + i];
                    i += 1;
                    mask |= byte;
                }
            }
            return @bitCast(self.state.? ^ mask);
        }
        fn pop(self: *@This()) ?itemType {
            //std.debug.print("pop: offset {} bytes {any}\n", .{ self.byte_offset, self.stream.*.arr.items[self.byte_offset..] });
            if (self.item_offset >= self.items) return null;
            if (self.item_offset == 0) {
                self.state = std.mem.bytesToValue(u80, self.bytes[0..10]);
                self.byte_offset = 10;
                return @bitCast(self.state.?);
            }
            if (self.state == null) unreachable;
            // decompress
            // VPEXPANDB
            const cmpr_indices = self.bytes[self.byte_offset..][0..2];
            self.byte_offset += 2;
            const diff = std.mem.bytesToValue(u10, cmpr_indices);
            //std.debug.print("pop compressed indices: {b} (bytes: {any})\n", .{ diff, cmpr_indices });
            //std.debug.print("pop compressed indices: reading {} bytes ({} available)\n", .{ @popCount(diff), self.stream.*.arr.items[self.byte_offset..].len });
            // start at with high order bytes
            var mask: u80 = 0;
            for (0..10) |bit_idx| {
                mask <<= 8;
                const bit = (diff >> @as(u4, @intCast(9 - bit_idx))) & 1;
                if (bit == 1) {
                    const byte = self.bytes[self.byte_offset];
                    self.byte_offset += 1;
                    mask |= byte;
                }
            }
            //std.debug.print("pop: xoring state with {b}\n", .{mask});
            self.state = self.state.? ^ mask;
            self.item_offset += 1;
            return @bitCast(self.state.?);
        }
    };
    fn reader(self: *const @This()) Reader {
        return .{ .bytes = self.arr.items, .items = self.len };
    }
    fn write(self: *@This(), state: ?u80, b: u80, alloc: std.mem.Allocator) !void {
        self.len += 1;
        if (state == null) {
            const bytes = std.mem.toBytes(b);
            try self.arr.appendSlice(alloc, bytes[0..10]);
            return;
        }
        var diff = state.? ^ b;
        //const orig_diff = diff;
        if (diff == 0) return error.DuplicateWrite;
        // compress
        // Result is big-endian, i.e. first byte must become highest-order in decompressed result
        // ASM: VPCOMPRESSB
        var bytes: [10]u8 = undefined;
        var offset: usize = 10;
        var mask: u10 = 0;
        for (0..10) |bit| {
            const byte: u8 = @intCast(diff & 0xff);
            if (byte != 0) {
                offset -= 1;
                bytes[offset] = byte;
                mask |= @as(u10, 1) << @as(u4, @intCast(bit));
            }
            diff >>= 8;
        }
        //std.debug.assert(diff == 0);
        //std.debug.print("writing: diff {b} {any} encoded-idx {b} {any} compressed-diff {any}\n", .{ orig_diff, std.mem.toBytes(orig_diff)[0..10], mask, std.mem.toBytes(mask), bytes[offset..10] });
        try self.arr.appendSlice(alloc, &std.mem.toBytes(mask));
        try self.arr.appendSlice(alloc, bytes[offset..10]);
    }
    const Writer = struct {
        stream: *compressedStream,
        state: ?u80,
        fn write(self: *@This(), b: Board, alloc: std.mem.Allocator) !void {
            try self.stream.write(self.state, @bitCast(b), alloc);
            self.state = @bitCast(b);
        }
    };
    fn writer(self: *@This()) Writer {
        return .{ .stream = self, .state = null };
    }
};

test "compressedStream" {
    const alloc = std.testing.allocator;
    var stream = compressedStream.init(alloc);
    defer stream.deinit();
    var w = stream.writer();
    var r = stream.reader();
    try std.testing.expect(r.peek() == null);
    var next = try std.ArrayList(Board).initCapacity(alloc, 5);
    defer next.deinit(alloc);

    for (std.enums.values(Action)) |a| {
        if (do_action(b053, a)) |result| {
            next.appendAssumeCapacity(result);
            try w.write(result);
        }
    }
    for (next.items) |item| {
        const pk = r.peek().?;
        const compr = r.pop().?;
        try std.testing.expect(pk == compr);
        std.debug.print("expect: {}\ndecomp: {}\n", .{ item, compr });
        std.debug.print("expect tiles/glass: {b} {b}\ndecomp tiles/glass: {b} {b}\n", .{ item.tiles, item.glass, compr.tiles, compr.glass });
        try std.testing.expect(item == compr);
    }
    try std.testing.expect(!r.hasNext());
}

/// Backtrace path through state space given single linear stream of states and parent-actions
fn trace_path(alloc: std.mem.Allocator, seen_stream: compressedStream, parent: []const Action, end: Board) !void {
    // does not have ownerhip of underlying compressedStream
    // build binary search array for reader
    var seen_r = seen_stream.reader();
    var readers = try std.ArrayList(compressedStream.Reader).initCapacity(alloc, (seen_stream.len + 255) / 256);
    var boards = try std.ArrayList(Board).initCapacity(alloc, (seen_stream.len + 255) / 256);
    while (seen_r.hasNext()) {
        try readers.append(alloc, seen_r); // copy
        try boards.append(alloc, seen_r.peek().?); // element i=0 mod 256
        for (0..256) |_| {
            if (seen_r.pop() == null) break;
        }
    }
    // we now have runs of K (256) in each reader
    // do binary search on the array first
    var path = try std.ArrayList(Action).initCapacity(alloc, 30);
    var b = end;
    while (b != b053) {
        // search for b in the seen list
        var i = binarySearch(Board, boards.items, b, boardCmp);
        var temp_r = readers.items[i]; // copy
        i *= 256;
        while (temp_r.pop().? != b) : (i += 1) {} // linear search
        // we now have the full index
        const last_action = parent[i];
        try path.append(alloc, switch (last_action) {
            .Z => .Z,
            else => switch (b.facing) {
                .U => .U,
                .L => .L,
                .R => .R,
                .D => .D,
            },
        });
        b = reverse(b, last_action);
    }
    //var pathstr = std.ArrayList(u8).initCapacity(alloc, path.items.len);
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

fn boardCmp(a: Board, b: Board) std.math.Order {
    const aa: u80 = @bitCast(a);
    const bb: u80 = @bitCast(b);
    return if (aa == bb) .eq else if (aa < bb) .lt else .gt;
}

/// Rather than returning null like std.sort.binarySearch,
/// returns the largest index such that needle =>items[idx]
/// this is where you would insert the needle
fn binarySearch(
    comptime T: type,
    haystack: []const T,
    needle: anytype,
    comptime compareFn: fn (@TypeOf(needle), T) std.math.Order,
) usize {
    var low: usize = 0;
    var high: usize = haystack.len;

    // invariant: needle position < high
    // invariant: needle position >= low
    while (low + 1 < high) {
        // Avoid overflowing in the midpoint calculation
        const mid = low + (high - low) / 2;
        switch (compareFn(needle, haystack[mid])) {
            .eq => return mid,
            .gt => low = mid,
            .lt => high = mid,
        }
    }
    std.debug.assert(low + 1 == high);
    return low;
}
