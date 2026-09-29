const std = @import("std");

// Extract all states holding stairs from b053-data (ie, carvable brands)
// and deduplicate by lowest depth (to avoid multiple states for the same brand)

test {
    std.testing.refAllDecls(@import("query_brand_data.zig"));
}

const stairsReader = struct {
    bytes: []const u8,
    offset: usize = 0,
    depth: u16 = 0,
    depth_items: usize = 0,
    depth_offset: usize = 0,
    fn next(self: *@This()) ?struct { brand: u35, depth: u16 } {
        if (self.offset + 4 >= self.bytes.len) return null;
        if (self.depth_offset == self.depth_items) { // exhausted current depth, read a new one
            self.depth = @intCast(self.read_raw() orelse return null);
            self.depth_items = @intCast(self.read_raw() orelse return null);
            if (self.depth_items == 0) @panic("unexpected depth with length zero in .stairs file");
            self.depth_offset = 0;
        }
        self.depth_offset += 1;
        return .{ .brand = self.read_raw() orelse return null, .depth = self.depth };
    }
    fn read_raw(self: *@This()) ?u35 {
        if (self.offset + 4 >= self.bytes.len) return null;
        const val = self.bytes[self.offset..][0..5];
        self.offset += 5;
        return @intCast(std.mem.readInt(u40, val, .little));
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    std.debug.print("Input your brand as a 6x6 with '#' denoting solid tiles and '.' denoting empty space:\n", .{});
    var stdin = std.Io.File.stdin();
    var stdin_buf: [100]u8 = undefined;
    var stdin_r = stdin.reader(io, stdin_buf[0..]);
    var full_brand: u36 = 0;
    // read the brand graphically
    input_loop: while (full_brand == 0) {
        for (0..6) |_| {
            const read_buf = std.mem.trimEnd(u8, (try stdin_r.interface.takeDelimiter('\n')).?, "\r");
            if (read_buf.len == 6) {
                const invalid: u8 = for (read_buf) |c| {
                    if (c == '#') {
                        full_brand <<= 1;
                        full_brand += 1;
                    } else if (c == '.') {
                        full_brand <<= 1;
                    } else break c;
                } else continue;
                std.debug.print("Expected only # and . in brand, not '{c}' - try again\n", .{invalid});
            } else std.debug.print("Expected a row to be 6 characters, not {} - try again\n", .{read_buf.len});
            full_brand = 0;
            //stdin_r.interface.tossBuffered();
            continue :input_loop;
        }
    }
    if (full_brand & 1 == 0) {
        std.debug.print("\nResult: Impossible (bottom right is not filled)\n", .{});
        return;
    }
    const brand: u35 = @intCast(full_brand >> 1);
    if (false) {
        // debug input
        std.debug.print("Read brand:\n", .{});
        for (0..35) |i| {
            const c: u8 = if (brand & (@as(u35, 1) << (34 - @as(u6, @intCast(i)))) != 0) '#' else '.';
            std.debug.print("{c}", .{c});
            if (i % 6 == 5) std.debug.print("\n", .{});
        }
        std.debug.print("#\n", .{});
    }
    // if bottom-right empty: return false
    const tilecount = @popCount(brand);
    // if tilecount less than 21: return 'unknown'
    if (tilecount < 21) {
        std.debug.print("\nResult: Unknown (no data on tilecount {})\n", .{tilecount});
        return;
    }
    // if tilecount > 31: return 'false'
    if (tilecount > 31) {
        std.debug.print("\nResult: Impossible (too many tiles)\n", .{});
        return;
    }
    // else continue to a linear search in the appropriate file
    std.debug.print("Checking...\n", .{});
    const dir = try std.Io.Dir.cwd().openDir(io, "b053-data", .{});
    var buf: [20]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{}.stairs", .{tilecount});
    var file = try dir.openFile(io, filename, .{ .mode = .read_only });
    defer file.close(io);
    var map = try file.createMemoryMap(io, .{ .len = try file.length(io), .protection = .{ .read = true } });
    defer map.destroy(io);
    // open file with map
    var r: stairsReader = .{ .bytes = map.memory };
    const found_depth: ?u16 = while (r.next()) |candidate| {
        if (candidate.brand == brand) break candidate.depth;
    } else null;
    if (found_depth) |d| {
        std.debug.print("\nResult: Possible in {d} moves\n", .{d + 1}); // add one for falling
    } else std.debug.print("\nResult: Impossible\n", .{});
}
