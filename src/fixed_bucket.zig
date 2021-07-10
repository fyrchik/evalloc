const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;
const log = std.log.scoped(.bucket_allocator);

pub const Config = struct {
    /// Size of a chunk to allocate.
    alloc_size: usize = 64,

    /// Size of a single group to allocate.
    group_size: usize = 4,

    /// Whether to enable safety checks.
    safety: bool = std.debug.runtime_safety,

    /// Enables emitting info messages with the size and address of every allocation.
    verbose_log: bool = false,
};


/// BucketAllocator allocates fixed-size chunks of memory but preallocates
/// multiple chunks with a single syscall. It is written for self-educating purposes. 
pub fn BucketAllocator(comptime config: Config) type {
    return struct {
        allocator: Allocator = Allocator{
            .allocFn = alloc,
            .resizeFn = resize,
        },
        backing_allocator: *Allocator = std.heap.page_allocator,

        const Self = @This();

        var free_mask: [config.group_size]bool = undefined;
        var bucket: [config.group_size][]u8 = undefined;
        var initialized = false;

        fn init(self: *Self) Error!void {
            const slice = try self.backing_allocator.alloc(u8, config.alloc_size * config.group_size);
            var i: usize = 0;
            while (i < config.group_size) {
                bucket[i] = slice[i*config.alloc_size..(i+1)*config.alloc_size];
                free_mask[i] = true;
                i += 1;
            }
            initialized = true;
        }

        fn get_free_index() Error!usize{
            for (free_mask) |is_free, i| {
                if (is_free) {
                    free_mask[i] = false;
                    return i;
                }
            }
            return error.OutOfMemory;
        }

        fn alloc(
            allocator: *Allocator,
            len: usize,
            ptr_align: u29,
            len_align: u29,
            ret_addr: usize
        ) Error![]u8 {
            assert(len == config.alloc_size);

            const self = @fieldParentPtr(Self, "allocator", allocator);
            
            if (!initialized) {
                try self.init();
            }

            const index = try get_free_index();
            if (config.verbose_log) {
                log.info("alloc {d} bytes at {*}", .{ len, bucket[index].ptr });
            }
            return bucket[index];
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

            const self = @fieldParentPtr(Self, "allocator", allocator);
            const byte_offset = @ptrToInt(old_mem.ptr) - @ptrToInt(bucket[0].ptr);
            const index = @divExact(byte_offset, config.alloc_size);
            if (config.safety and free_mask[index]) {
                std.debug.panic("double free", .{});
            }
            if (config.verbose_log) {
                log.info("dealloc {d} bytes at {*}", .{ old_mem.len, old_mem.ptr });
            }
            free_mask[index] = true;
            return 0;
        }

        fn deinit(self: Self) bool {
            for (free_mask) |is_free| {
                if (!is_free) {
                    return true;
                }
            }
            return false;
        }
    };
}


test "allocate different regions" {
    var ba = BucketAllocator(Config{
        .alloc_size = 8,
        .group_size = 4,
        .safety = true,
        .verbose_log = true,
    }){};
    defer testing.expect(!ba.deinit()) catch @panic("leak");

    const allocator = &ba.allocator;

    var a1 = try allocator.create(u64);
    var a2 = try allocator.create(u64);
    var a3 = try allocator.create(u64);
    var a4 = try allocator.create(u64);

    // Check that different regions of memory were returned.
    a1.* = 1;
    a2.* = 2;
    a3.* = 3;
    a4.* = 4;
    try testing.expect(a1.* == 1);
    try testing.expect(a2.* == 2);
    try testing.expect(a3.* == 3);
    try testing.expect(a4.* == 4);

    try testing.expectError(error.OutOfMemory, allocator.create(u64));

    allocator.destroy(a1);
    a1 = try allocator.create(u64);
    try testing.expectError(error.OutOfMemory, allocator.create(u64));

    // Check that new chunk of memory was allocated;
    a1.* = 1;
    try testing.expect(a1.* == 1);
    try testing.expect(a2.* == 2);
    try testing.expect(a3.* == 3);
    try testing.expect(a4.* == 4);

    allocator.destroy(a2);
    allocator.destroy(a3);
    a2 = try allocator.create(u64);
    a3 = try allocator.create(u64);
    try testing.expectError(error.OutOfMemory, allocator.create(u64));

    allocator.destroy(a1);
    allocator.destroy(a2);
    allocator.destroy(a3);
    allocator.destroy(a4);
}