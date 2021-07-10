const std = @import("std");
const varint = @import("./varint.zig");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;
const log = std.log.scoped(.bucket_allocator);

pub const Config = struct {};

/// FixedSlice is an allocator which allocates memory from some backing slice.
/// The implementation is quite simple:
/// Each allocation is preceeded with variable size header which contains size of the following chunk.
/// Alignment is ignored.
/// It is written for self-educating purposes. 
pub fn FixedSlice(comptime config: Config) type {
    return struct {
        allocator: Allocator = Allocator{
            .allocFn = alloc,
            .resizeFn = resize,
        },

        const Self = @This();
        const header_size = 2;

        var backing_slice: []u8 = undefined;
        var initialized: bool = false;

        fn init(self: *Self, s: []u8) anyerror!void {
            if (initialized) {
                return error.AlreadyInitialized;
            }

            initialized = true;
            std.mem.set(u8, s, 0);
            backing_slice = s;
            _ = write_header(0, s.len, true);
        }

        /// Writes header to the start offset and returns number of bytes written.
        fn write_header(start: usize, len: usize, comptime free: bool) usize {
            assert(start + 1 < backing_slice.len);
            assert(header_size <= len);

            const header = (len << 1) | @as(usize, @boolToInt(!free));
            backing_slice[start] = @truncate(u8, header);
            backing_slice[start + 1] = @truncate(u8, header >> 8);
            return header_size;
        }

        /// Reads header from the start offset.
        fn read_header(start: usize) usize {
            assert(start + header_size <= backing_slice.len);

            var header = @as(usize, backing_slice[start]);
            header |= @as(usize, backing_slice[start + 1]) << 8;
            return header;
        }

        fn get_free_index(len: usize) Error!usize {
            const needed_len = len + header_size;

            var i: usize = 0;
            while (i < backing_slice.len) {
                const res = read_header(i);
                const free_size = res >> 1;
                assert(i + free_size <= backing_slice.len);

                if (res & 1 == 0 and needed_len <= free_size) {
                    // First set the next free chunk.
                    if (needed_len < free_size) {
                        const remaining = (free_size - needed_len);
                        const written = write_header(i + needed_len, remaining, true);
                        assert(needed_len + written < free_size);
                    }

                    return i;
                }
                i += free_size;
            }

            assert(i == backing_slice.len);
            return error.OutOfMemory;
        }

        fn alloc(allocator: *Allocator, len: usize, ptr_align: u29, len_align: u29, ret_addr: usize) Error![]u8 {
            assert(len % 2 == 0); // support only allocations of even size for now.

            const self = @fieldParentPtr(Self, "allocator", allocator);
            const index = try get_free_index(len);
            const written = write_header(index, len + header_size, false);
            return backing_slice[index + written .. index + written + len];
        }

        fn resize(
            allocator: *Allocator,
            old_mem: []u8,
            old_align: u29,
            new_size: usize,
            len_align: u29,
            ret_addr: usize,
        ) Error!usize {
            assert(new_size == 0);

            const index = @ptrToInt(old_mem.ptr) - @ptrToInt(backing_slice.ptr);
            const start = index - 2;
            _ = write_header(start, old_mem.len + 2, true);
            return 0;
        }

        fn deinit(self: Self) bool {
            var i: usize = 0;
            while (i < backing_slice.len) {
                const res = read_header(i);
                if (res & 1 != 0) {
                    return true;
                }
                i += res >> 1;
            }

            assert(i == backing_slice.len);

            backing_slice = undefined;
            initialized = false;
            return false;
        }
    };
}

test "allocate different regions" {
    const memory_size = 1024;
    var memory = try testing.allocator.alloc(u8, memory_size);
    defer testing.allocator.free(memory);

    var fs = FixedSlice(Config{}){};
    try fs.init(memory);
    defer testing.expect(!fs.deinit()) catch @panic("leak");

    try testing.expectError(error.AlreadyInitialized, fs.init(memory));

    const allocator = &fs.allocator;
    var a1 = try allocator.alloc(u8, 512);
    var a2 = try allocator.alloc(u8, 400);
    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 128));
    var a3 = try allocator.alloc(u8, 100);

    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 128));
    allocator.free(a1);
    var a11 = try allocator.alloc(u8, 128);
    var a12 = try allocator.alloc(u8, 128);
    var a13 = try allocator.alloc(u8, 128);
    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 128));

    allocator.free(a11);
    allocator.free(a12);
    allocator.free(a13);
    allocator.free(a2);
    allocator.free(a3);
}
