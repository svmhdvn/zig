gpa: *Allocator,
manifest_dir: fs.Dir,
hash: HashHelper = .{},

const Cache = @This();
const std = @import("std");
const crypto = std.crypto;
const fs = std.fs;
const assert = std.debug.assert;
const testing = std.testing;
const mem = std.mem;
const fmt = std.fmt;
const Allocator = std.mem.Allocator;

/// Process-scoped map keeping track of all locked Cache hashes, to detect deadlocks.
/// The plan is to enable this for debug builds only, but for now we enable
/// it always to catch a deadlock.
var all_cache_digest_set: std.AutoHashMapUnmanaged(BinDigest, void) = .{};
var all_cache_digest_lock: std.Mutex = .{};
const want_debug_deadlock = std.debug.runtime_safety;
const DebugBinDigest = if (want_debug_deadlock) BinDigest else void;
const null_debug_bin_digest = if (want_debug_deadlock) ([1]u8{0} ** bin_digest_len) else {};

/// Be sure to call `Manifest.deinit` after successful initialization.
pub fn obtain(cache: *const Cache) Manifest {
    return Manifest{
        .cache = cache,
        .hash = cache.hash,
        .manifest_file = null,
        .manifest_dirty = false,
        .hex_digest = undefined,
    };
}

/// This is 128 bits - Even with 2^54 cache entries, the probably of a collision would be under 10^-6
pub const bin_digest_len = 16;
pub const hex_digest_len = bin_digest_len * 2;
pub const BinDigest = [bin_digest_len]u8;

const manifest_file_size_max = 50 * 1024 * 1024;

/// The type used for hashing file contents. Currently, this is SipHash128(1, 3), because it
/// provides enough collision resistance for the Manifest use cases, while being one of our
/// fastest options right now.
pub const Hasher = crypto.auth.siphash.SipHash128(1, 3);

/// Initial state, that can be copied.
pub const hasher_init: Hasher = Hasher.init(&[_]u8{0} ** Hasher.key_length);

pub const File = struct {
    path: ?[]const u8,
    max_file_size: ?usize,
    stat: fs.File.Stat,
    bin_digest: BinDigest,
    contents: ?[]const u8,

    pub fn deinit(self: *File, allocator: *Allocator) void {
        if (self.path) |owned_slice| {
            allocator.free(owned_slice);
            self.path = null;
        }
        if (self.contents) |contents| {
            allocator.free(contents);
            self.contents = null;
        }
        self.* = undefined;
    }
};

pub const HashHelper = struct {
    hasher: Hasher = hasher_init,

    const EmitLoc = @import("Compilation.zig").EmitLoc;

    /// Record a slice of bytes as an dependency of the process being cached
    pub fn addBytes(hh: *HashHelper, bytes: []const u8) void {
        hh.hasher.update(mem.asBytes(&bytes.len));
        hh.hasher.update(bytes);
    }

    pub fn addOptionalBytes(hh: *HashHelper, optional_bytes: ?[]const u8) void {
        hh.add(optional_bytes != null);
        hh.addBytes(optional_bytes orelse return);
    }

    pub fn addEmitLoc(hh: *HashHelper, emit_loc: EmitLoc) void {
        hh.addBytes(emit_loc.basename);
    }

    pub fn addOptionalEmitLoc(hh: *HashHelper, optional_emit_loc: ?EmitLoc) void {
        hh.add(optional_emit_loc != null);
        hh.addEmitLoc(optional_emit_loc orelse return);
    }

    pub fn addListOfBytes(hh: *HashHelper, list_of_bytes: []const []const u8) void {
        hh.add(list_of_bytes.len);
        for (list_of_bytes) |bytes| hh.addBytes(bytes);
    }

    pub fn addStringSet(hh: *HashHelper, hm: std.StringArrayHashMapUnmanaged(void)) void {
        const entries = hm.items();
        hh.add(entries.len);
        for (entries) |entry| {
            hh.addBytes(entry.key);
        }
    }

    /// Convert the input value into bytes and record it as a dependency of the process being cached.
    pub fn add(hh: *HashHelper, x: anytype) void {
        switch (@TypeOf(x)) {
            std.builtin.Version => {
                hh.add(x.major);
                hh.add(x.minor);
                hh.add(x.patch);
            },
            std.Target.Os.TaggedVersionRange => {
                switch (x) {
                    .linux => |linux| {
                        hh.add(linux.range.min);
                        hh.add(linux.range.max);
                        hh.add(linux.glibc);
                    },
                    .windows => |windows| {
                        hh.add(windows.min);
                        hh.add(windows.max);
                    },
                    .semver => |semver| {
                        hh.add(semver.min);
                        hh.add(semver.max);
                    },
                    .none => {},
                }
            },
            else => switch (@typeInfo(@TypeOf(x))) {
                .Bool, .Int, .Enum, .Array => hh.addBytes(mem.asBytes(&x)),
                else => @compileError("unable to hash type " ++ @typeName(@TypeOf(x))),
            },
        }
    }

    pub fn addOptional(hh: *HashHelper, optional: anytype) void {
        hh.add(optional != null);
        hh.add(optional orelse return);
    }

    /// Returns a hex encoded hash of the inputs, without modifying state.
    pub fn peek(hh: HashHelper) [hex_digest_len]u8 {
        var copy = hh;
        return copy.final();
    }

    pub fn peekBin(hh: HashHelper) BinDigest {
        var copy = hh;
        var bin_digest: BinDigest = undefined;
        copy.hasher.final(&bin_digest);
        return bin_digest;
    }

    /// Returns a hex encoded hash of the inputs, mutating the state of the hasher.
    pub fn final(hh: *HashHelper) [hex_digest_len]u8 {
        var bin_digest: BinDigest = undefined;
        hh.hasher.final(&bin_digest);

        var out_digest: [hex_digest_len]u8 = undefined;
        _ = std.fmt.bufPrint(&out_digest, "{x}", .{bin_digest}) catch unreachable;
        return out_digest;
    }
};

pub const Lock = struct {
    manifest_file: fs.File,
    debug_bin_digest: DebugBinDigest,

    pub fn release(lock: *Lock) void {
        if (want_debug_deadlock) {
            const held = all_cache_digest_lock.acquire();
            defer held.release();

            all_cache_digest_set.removeAssertDiscard(lock.debug_bin_digest);
        }
        lock.manifest_file.close();
        lock.* = undefined;
    }
};

/// Manifest manages project-local `zig-cache` directories.
/// This is not a general-purpose cache.
/// It is designed to be fast and simple, not to withstand attacks using specially-crafted input.
pub const Manifest = struct {
    cache: *const Cache,
    /// Current state for incremental hashing.
    hash: HashHelper,
    manifest_file: ?fs.File,
    manifest_dirty: bool,
    files: std.ArrayListUnmanaged(File) = .{},
    hex_digest: [hex_digest_len]u8,
    debug_bin_digest: DebugBinDigest = null_debug_bin_digest,

    /// Add a file as a dependency of process being cached. When `hit` is
    /// called, the file's contents will be checked to ensure that it matches
    /// the contents from previous times.
    ///
    /// Max file size will be used to determine the amount of space to the file contents
    /// are allowed to take up in memory. If max_file_size is null, then the contents
    /// will not be loaded into memory.
    ///
    /// Returns the index of the entry in the `files` array list. You can use it
    /// to access the contents of the file after calling `hit()` like so:
    ///
    /// ```
    /// var file_contents = cache_hash.files.items[file_index].contents.?;
    /// ```
    pub fn addFile(self: *Manifest, file_path: []const u8, max_file_size: ?usize) !usize {
        assert(self.manifest_file == null);

        try self.files.ensureCapacity(self.cache.gpa, self.files.items.len + 1);
        const resolved_path = try fs.path.resolve(self.cache.gpa, &[_][]const u8{file_path});

        const idx = self.files.items.len;
        self.files.addOneAssumeCapacity().* = .{
            .path = resolved_path,
            .contents = null,
            .max_file_size = max_file_size,
            .stat = undefined,
            .bin_digest = undefined,
        };

        self.hash.addBytes(resolved_path);

        return idx;
    }

    pub fn addOptionalFile(self: *Manifest, optional_file_path: ?[]const u8) !void {
        self.hash.add(optional_file_path != null);
        const file_path = optional_file_path orelse return;
        _ = try self.addFile(file_path, null);
    }

    pub fn addListOfFiles(self: *Manifest, list_of_files: []const []const u8) !void {
        self.hash.add(list_of_files.len);
        for (list_of_files) |file_path| {
            _ = try self.addFile(file_path, null);
        }
    }

    /// Check the cache to see if the input exists in it. If it exists, returns `true`.
    /// A hex encoding of its hash is available by calling `final`.
    ///
    /// This function will also acquire an exclusive lock to the manifest file. This means
    /// that a process holding a Manifest will block any other process attempting to
    /// acquire the lock.
    ///
    /// The lock on the manifest file is released when `deinit` is called. As another
    /// option, one may call `toOwnedLock` to obtain a smaller object which can represent
    /// the lock. `deinit` is safe to call whether or not `toOwnedLock` has been called.
    pub fn hit(self: *Manifest) !bool {
        assert(self.manifest_file == null);

        const ext = ".txt";
        var manifest_file_path: [self.hex_digest.len + ext.len]u8 = undefined;

        var bin_digest: BinDigest = undefined;
        self.hash.hasher.final(&bin_digest);

        if (want_debug_deadlock) {
            self.debug_bin_digest = bin_digest;

            const held = all_cache_digest_lock.acquire();
            defer held.release();

            const gop = try all_cache_digest_set.getOrPut(self.cache.gpa, bin_digest);
            if (gop.found_existing) {
                std.debug.print("Cache deadlock detected in Cache.hit. Manifest has {d} files:\n", .{self.files.items.len});
                for (self.files.items) |file| {
                    const p: []const u8 = file.path orelse "(null)";
                    std.debug.print("  file: {s}\n", .{p});
                }
                @panic("Cache deadlock detected");
            }
        }

        _ = std.fmt.bufPrint(&self.hex_digest, "{x}", .{bin_digest}) catch unreachable;

        self.hash.hasher = hasher_init;
        self.hash.hasher.update(&bin_digest);

        mem.copy(u8, &manifest_file_path, &self.hex_digest);
        manifest_file_path[self.hex_digest.len..][0..ext.len].* = ext.*;

        if (self.files.items.len != 0) {
            self.manifest_file = try self.cache.manifest_dir.createFile(&manifest_file_path, .{
                .read = true,
                .truncate = false,
                .lock = .Exclusive,
            });
        } else {
            // If there are no file inputs, we check if the manifest file exists instead of
            // comparing the hashes on the files used for the cached item
            self.manifest_file = self.cache.manifest_dir.openFile(&manifest_file_path, .{
                .read = true,
                .write = true,
                .lock = .Exclusive,
            }) catch |err| switch (err) {
                error.FileNotFound => {
                    self.manifest_dirty = true;
                    self.manifest_file = try self.cache.manifest_dir.createFile(&manifest_file_path, .{
                        .read = true,
                        .truncate = false,
                        .lock = .Exclusive,
                    });
                    return false;
                },
                else => |e| return e,
            };
        }

        const file_contents = try self.manifest_file.?.inStream().readAllAlloc(self.cache.gpa, manifest_file_size_max);
        defer self.cache.gpa.free(file_contents);

        const input_file_count = self.files.items.len;
        var any_file_changed = false;
        var line_iter = mem.tokenize(file_contents, "\n");
        var idx: usize = 0;
        while (line_iter.next()) |line| {
            defer idx += 1;

            const cache_hash_file = if (idx < input_file_count) &self.files.items[idx] else blk: {
                const new = try self.files.addOne(self.cache.gpa);
                new.* = .{
                    .path = null,
                    .contents = null,
                    .max_file_size = null,
                    .stat = undefined,
                    .bin_digest = undefined,
                };
                break :blk new;
            };

            var iter = mem.tokenize(line, " ");
            const size = iter.next() orelse return error.InvalidFormat;
            const inode = iter.next() orelse return error.InvalidFormat;
            const mtime_nsec_str = iter.next() orelse return error.InvalidFormat;
            const digest_str = iter.next() orelse return error.InvalidFormat;
            const file_path = iter.rest();

            cache_hash_file.stat.size = fmt.parseInt(u64, size, 10) catch return error.InvalidFormat;
            cache_hash_file.stat.inode = fmt.parseInt(fs.File.INode, inode, 10) catch return error.InvalidFormat;
            cache_hash_file.stat.mtime = fmt.parseInt(i64, mtime_nsec_str, 10) catch return error.InvalidFormat;
            std.fmt.hexToBytes(&cache_hash_file.bin_digest, digest_str) catch return error.InvalidFormat;

            if (file_path.len == 0) {
                return error.InvalidFormat;
            }
            if (cache_hash_file.path) |p| {
                if (!mem.eql(u8, file_path, p)) {
                    return error.InvalidFormat;
                }
            }

            if (cache_hash_file.path == null) {
                cache_hash_file.path = try self.cache.gpa.dupe(u8, file_path);
            }

            const this_file = fs.cwd().openFile(cache_hash_file.path.?, .{ .read = true }) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return error.CacheUnavailable,
            };
            defer this_file.close();

            const actual_stat = try this_file.stat();
            const size_match = actual_stat.size == cache_hash_file.stat.size;
            const mtime_match = actual_stat.mtime == cache_hash_file.stat.mtime;
            const inode_match = actual_stat.inode == cache_hash_file.stat.inode;

            if (!size_match or !mtime_match or !inode_match) {
                self.manifest_dirty = true;

                cache_hash_file.stat = actual_stat;

                if (isProblematicTimestamp(cache_hash_file.stat.mtime)) {
                    cache_hash_file.stat.mtime = 0;
                    cache_hash_file.stat.inode = 0;
                }

                var actual_digest: BinDigest = undefined;
                try hashFile(this_file, &actual_digest);

                if (!mem.eql(u8, &cache_hash_file.bin_digest, &actual_digest)) {
                    cache_hash_file.bin_digest = actual_digest;
                    // keep going until we have the input file digests
                    any_file_changed = true;
                }
            }

            if (!any_file_changed) {
                self.hash.hasher.update(&cache_hash_file.bin_digest);
            }
        }

        if (any_file_changed) {
            // cache miss
            // keep the manifest file open
            self.unhit(bin_digest, input_file_count);
            return false;
        }

        if (idx < input_file_count) {
            self.manifest_dirty = true;
            while (idx < input_file_count) : (idx += 1) {
                const ch_file = &self.files.items[idx];
                try self.populateFileHash(ch_file);
            }
            return false;
        }

        return true;
    }

    pub fn unhit(self: *Manifest, bin_digest: BinDigest, input_file_count: usize) void {
        // Reset the hash.
        self.hash.hasher = hasher_init;
        self.hash.hasher.update(&bin_digest);

        // Remove files not in the initial hash.
        for (self.files.items[input_file_count..]) |*file| {
            file.deinit(self.cache.gpa);
        }
        self.files.shrinkRetainingCapacity(input_file_count);

        for (self.files.items) |file| {
            self.hash.hasher.update(&file.bin_digest);
        }
    }

    fn populateFileHash(self: *Manifest, ch_file: *File) !void {
        const file = try fs.cwd().openFile(ch_file.path.?, .{});
        defer file.close();

        ch_file.stat = try file.stat();

        if (isProblematicTimestamp(ch_file.stat.mtime)) {
            ch_file.stat.mtime = 0;
            ch_file.stat.inode = 0;
        }

        if (ch_file.max_file_size) |max_file_size| {
            if (ch_file.stat.size > max_file_size) {
                return error.FileTooBig;
            }

            const contents = try self.cache.gpa.alloc(u8, @intCast(usize, ch_file.stat.size));
            errdefer self.cache.gpa.free(contents);

            // Hash while reading from disk, to keep the contents in the cpu cache while
            // doing hashing.
            var hasher = hasher_init;
            var off: usize = 0;
            while (true) {
                // give me everything you've got, captain
                const bytes_read = try file.read(contents[off..]);
                if (bytes_read == 0) break;
                hasher.update(contents[off..][0..bytes_read]);
                off += bytes_read;
            }
            hasher.final(&ch_file.bin_digest);

            ch_file.contents = contents;
        } else {
            try hashFile(file, &ch_file.bin_digest);
        }

        self.hash.hasher.update(&ch_file.bin_digest);
    }

    /// Add a file as a dependency of process being cached, after the initial hash has been
    /// calculated. This is useful for processes that don't know the all the files that
    /// are depended on ahead of time. For example, a source file that can import other files
    /// will need to be recompiled if the imported file is changed.
    pub fn addFilePostFetch(self: *Manifest, file_path: []const u8, max_file_size: usize) ![]const u8 {
        assert(self.manifest_file != null);

        const resolved_path = try fs.path.resolve(self.cache.gpa, &[_][]const u8{file_path});
        errdefer self.cache.gpa.free(resolved_path);

        const new_ch_file = try self.files.addOne(self.cache.gpa);
        new_ch_file.* = .{
            .path = resolved_path,
            .max_file_size = max_file_size,
            .stat = undefined,
            .bin_digest = undefined,
            .contents = null,
        };
        errdefer self.files.shrinkRetainingCapacity(self.files.items.len - 1);

        try self.populateFileHash(new_ch_file);

        return new_ch_file.contents.?;
    }

    /// Add a file as a dependency of process being cached, after the initial hash has been
    /// calculated. This is useful for processes that don't know the all the files that
    /// are depended on ahead of time. For example, a source file that can import other files
    /// will need to be recompiled if the imported file is changed.
    pub fn addFilePost(self: *Manifest, file_path: []const u8) !void {
        assert(self.manifest_file != null);

        const resolved_path = try fs.path.resolve(self.cache.gpa, &[_][]const u8{file_path});
        errdefer self.cache.gpa.free(resolved_path);

        const new_ch_file = try self.files.addOne(self.cache.gpa);
        new_ch_file.* = .{
            .path = resolved_path,
            .max_file_size = null,
            .stat = undefined,
            .bin_digest = undefined,
            .contents = null,
        };
        errdefer self.files.shrinkRetainingCapacity(self.files.items.len - 1);

        try self.populateFileHash(new_ch_file);
    }

    pub fn addDepFilePost(self: *Manifest, dir: fs.Dir, dep_file_basename: []const u8) !void {
        assert(self.manifest_file != null);

        const dep_file_contents = try dir.readFileAlloc(self.cache.gpa, dep_file_basename, manifest_file_size_max);
        defer self.cache.gpa.free(dep_file_contents);

        var error_buf = std.ArrayList(u8).init(self.cache.gpa);
        defer error_buf.deinit();

        var it: @import("DepTokenizer.zig") = .{ .bytes = dep_file_contents };

        // Skip first token: target.
        switch (it.next() orelse return) { // Empty dep file OK.
            .target, .target_must_resolve, .prereq => {},
            else => |err| {
                try err.printError(error_buf.writer());
                std.log.err("failed parsing {}: {}", .{ dep_file_basename, error_buf.items });
                return error.InvalidDepFile;
            },
        }
        // Process 0+ preqreqs.
        // Clang is invoked in single-source mode so we never get more targets.
        while (true) {
            switch (it.next() orelse return) {
                .target, .target_must_resolve => return,
                .prereq => |bytes| try self.addFilePost(bytes),
                else => |err| {
                    try err.printError(error_buf.writer());
                    std.log.err("failed parsing {}: {}", .{ dep_file_basename, error_buf.items });
                    return error.InvalidDepFile;
                },
            }
        }
    }

    /// Returns a hex encoded hash of the inputs.
    pub fn final(self: *Manifest) [hex_digest_len]u8 {
        assert(self.manifest_file != null);

        // We don't close the manifest file yet, because we want to
        // keep it locked until the API user is done using it.
        // We also don't write out the manifest yet, because until
        // cache_release is called we still might be working on creating
        // the artifacts to cache.

        var bin_digest: BinDigest = undefined;
        self.hash.hasher.final(&bin_digest);

        var out_digest: [hex_digest_len]u8 = undefined;
        _ = std.fmt.bufPrint(&out_digest, "{x}", .{bin_digest}) catch unreachable;

        return out_digest;
    }

    pub fn writeManifest(self: *Manifest) !void {
        const manifest_file = self.manifest_file.?;
        if (!self.manifest_dirty) return;

        var contents = std.ArrayList(u8).init(self.cache.gpa);
        defer contents.deinit();

        const writer = contents.writer();
        var encoded_digest: [hex_digest_len]u8 = undefined;

        for (self.files.items) |file| {
            _ = std.fmt.bufPrint(&encoded_digest, "{x}", .{file.bin_digest}) catch unreachable;
            try writer.print("{d} {d} {d} {s} {s}\n", .{
                file.stat.size,
                file.stat.inode,
                file.stat.mtime,
                &encoded_digest,
                file.path,
            });
        }

        try manifest_file.setEndPos(contents.items.len);
        try manifest_file.pwriteAll(contents.items, 0);
        self.manifest_dirty = false;
    }

    /// Obtain only the data needed to maintain a lock on the manifest file.
    /// The `Manifest` remains safe to deinit.
    /// Don't forget to call `writeManifest` before this!
    pub fn toOwnedLock(self: *Manifest) Lock {
        const lock: Lock = .{
            .manifest_file = self.manifest_file.?,
            .debug_bin_digest = self.debug_bin_digest,
        };
        self.manifest_file = null;
        self.debug_bin_digest = null_debug_bin_digest;
        return lock;
    }

    /// Releases the manifest file and frees any memory the Manifest was using.
    /// `Manifest.hit` must be called first.
    /// Don't forget to call `writeManifest` before this!
    pub fn deinit(self: *Manifest) void {
        if (want_debug_deadlock) {
            if (!mem.eql(u8, &self.debug_bin_digest, &null_debug_bin_digest)) {
                const held = all_cache_digest_lock.acquire();
                defer held.release();

                all_cache_digest_set.removeAssertDiscard(self.debug_bin_digest);
            }
        }
        if (self.manifest_file) |file| {
            file.close();
        }
        for (self.files.items) |*file| {
            file.deinit(self.cache.gpa);
        }
        self.files.deinit(self.cache.gpa);
    }
};

/// On operating systems that support symlinks, does a readlink. On other operating systems,
/// uses the file contents. Windows supports symlinks but only with elevated privileges, so
/// it is treated as not supporting symlinks.
pub fn readSmallFile(dir: fs.Dir, sub_path: []const u8, buffer: []u8) ![]u8 {
    if (std.Target.current.os.tag == .windows) {
        return dir.readFile(sub_path, buffer);
    } else {
        return dir.readLink(sub_path, buffer);
    }
}

/// On operating systems that support symlinks, does a symlink. On other operating systems,
/// uses the file contents. Windows supports symlinks but only with elevated privileges, so
/// it is treated as not supporting symlinks.
/// `data` must be a valid UTF-8 encoded file path and 255 bytes or fewer.
pub fn writeSmallFile(dir: fs.Dir, sub_path: []const u8, data: []const u8) !void {
    assert(data.len <= 255);
    if (std.Target.current.os.tag == .windows) {
        return dir.writeFile(sub_path, data);
    } else {
        return dir.symLink(data, sub_path, .{});
    }
}

fn hashFile(file: fs.File, bin_digest: *[Hasher.mac_length]u8) !void {
    var buf: [1024]u8 = undefined;

    var hasher = hasher_init;
    while (true) {
        const bytes_read = try file.read(&buf);
        if (bytes_read == 0) break;
        hasher.update(buf[0..bytes_read]);
    }

    hasher.final(bin_digest);
}

/// If the wall clock time, rounded to the same precision as the
/// mtime, is equal to the mtime, then we cannot rely on this mtime
/// yet. We will instead save an mtime value that indicates the hash
/// must be unconditionally computed.
/// This function recognizes the precision of mtime by looking at trailing
/// zero bits of the seconds and nanoseconds.
fn isProblematicTimestamp(fs_clock: i128) bool {
    const wall_clock = std.time.nanoTimestamp();

    // We have to break the nanoseconds into seconds and remainder nanoseconds
    // to detect precision of seconds, because looking at the zero bits in base
    // 2 would not detect precision of the seconds value.
    const fs_sec = @intCast(i64, @divFloor(fs_clock, std.time.ns_per_s));
    const fs_nsec = @intCast(i64, @mod(fs_clock, std.time.ns_per_s));
    var wall_sec = @intCast(i64, @divFloor(wall_clock, std.time.ns_per_s));
    var wall_nsec = @intCast(i64, @mod(wall_clock, std.time.ns_per_s));

    // First make all the least significant zero bits in the fs_clock, also zero bits in the wall clock.
    if (fs_nsec == 0) {
        wall_nsec = 0;
        if (fs_sec == 0) {
            wall_sec = 0;
        } else {
            wall_sec &= @as(i64, -1) << @intCast(u6, @ctz(i64, fs_sec));
        }
    } else {
        wall_nsec &= @as(i64, -1) << @intCast(u6, @ctz(i64, fs_nsec));
    }
    return wall_nsec == fs_nsec and wall_sec == fs_sec;
}

test "cache file and then recall it" {
    if (std.Target.current.os.tag == .wasi) {
        // https://github.com/ziglang/zig/issues/5437
        return error.SkipZigTest;
    }
    defer if (want_debug_deadlock) {
        testing.expect(all_cache_digest_set.count() == 0);
        all_cache_digest_set.clearAndFree(testing.allocator);
    };

    const cwd = fs.cwd();

    const temp_file = "test.txt";
    const temp_manifest_dir = "temp_manifest_dir";

    const ts = std.time.nanoTimestamp();
    try cwd.writeFile(temp_file, "Hello, world!\n");

    while (isProblematicTimestamp(ts)) {
        std.time.sleep(1);
    }

    var digest1: [hex_digest_len]u8 = undefined;
    var digest2: [hex_digest_len]u8 = undefined;

    {
        var cache = Cache{
            .gpa = testing.allocator,
            .manifest_dir = try cwd.makeOpenPath(temp_manifest_dir, .{}),
        };
        defer cache.manifest_dir.close();

        {
            var ch = cache.obtain();
            defer ch.deinit();

            ch.hash.add(true);
            ch.hash.add(@as(u16, 1234));
            ch.hash.addBytes("1234");
            _ = try ch.addFile(temp_file, null);

            // There should be nothing in the cache
            testing.expectEqual(false, try ch.hit());

            digest1 = ch.final();
            try ch.writeManifest();
        }
        {
            var ch = cache.obtain();
            defer ch.deinit();

            ch.hash.add(true);
            ch.hash.add(@as(u16, 1234));
            ch.hash.addBytes("1234");
            _ = try ch.addFile(temp_file, null);

            // Cache hit! We just "built" the same file
            testing.expect(try ch.hit());
            digest2 = ch.final();

            try ch.writeManifest();
        }

        testing.expectEqual(digest1, digest2);
    }

    try cwd.deleteTree(temp_manifest_dir);
    try cwd.deleteFile(temp_file);
}

test "give problematic timestamp" {
    var fs_clock = std.time.nanoTimestamp();
    // to make it problematic, we make it only accurate to the second
    fs_clock = @divTrunc(fs_clock, std.time.ns_per_s);
    fs_clock *= std.time.ns_per_s;
    testing.expect(isProblematicTimestamp(fs_clock));
}

test "give nonproblematic timestamp" {
    testing.expect(!isProblematicTimestamp(std.time.nanoTimestamp() - std.time.ns_per_s));
}

test "check that changing a file makes cache fail" {
    if (std.Target.current.os.tag == .wasi) {
        // https://github.com/ziglang/zig/issues/5437
        return error.SkipZigTest;
    }
    defer if (want_debug_deadlock) {
        testing.expect(all_cache_digest_set.count() == 0);
        all_cache_digest_set.clearAndFree(testing.allocator);
    };
    const cwd = fs.cwd();

    const temp_file = "cache_hash_change_file_test.txt";
    const temp_manifest_dir = "cache_hash_change_file_manifest_dir";
    const original_temp_file_contents = "Hello, world!\n";
    const updated_temp_file_contents = "Hello, world; but updated!\n";

    try cwd.deleteTree(temp_manifest_dir);
    try cwd.deleteTree(temp_file);

    const ts = std.time.nanoTimestamp();
    try cwd.writeFile(temp_file, original_temp_file_contents);

    while (isProblematicTimestamp(ts)) {
        std.time.sleep(1);
    }

    var digest1: [hex_digest_len]u8 = undefined;
    var digest2: [hex_digest_len]u8 = undefined;

    {
        var cache = Cache{
            .gpa = testing.allocator,
            .manifest_dir = try cwd.makeOpenPath(temp_manifest_dir, .{}),
        };
        defer cache.manifest_dir.close();

        {
            var ch = cache.obtain();
            defer ch.deinit();

            ch.hash.addBytes("1234");
            const temp_file_idx = try ch.addFile(temp_file, 100);

            // There should be nothing in the cache
            testing.expectEqual(false, try ch.hit());

            testing.expect(mem.eql(u8, original_temp_file_contents, ch.files.items[temp_file_idx].contents.?));

            digest1 = ch.final();

            try ch.writeManifest();
        }

        try cwd.writeFile(temp_file, updated_temp_file_contents);

        {
            var ch = cache.obtain();
            defer ch.deinit();

            ch.hash.addBytes("1234");
            const temp_file_idx = try ch.addFile(temp_file, 100);

            // A file that we depend on has been updated, so the cache should not contain an entry for it
            testing.expectEqual(false, try ch.hit());

            // The cache system does not keep the contents of re-hashed input files.
            testing.expect(ch.files.items[temp_file_idx].contents == null);

            digest2 = ch.final();

            try ch.writeManifest();
        }

        testing.expect(!mem.eql(u8, digest1[0..], digest2[0..]));
    }

    try cwd.deleteTree(temp_manifest_dir);
    try cwd.deleteTree(temp_file);
}

test "no file inputs" {
    if (std.Target.current.os.tag == .wasi) {
        // https://github.com/ziglang/zig/issues/5437
        return error.SkipZigTest;
    }
    defer if (want_debug_deadlock) {
        testing.expect(all_cache_digest_set.count() == 0);
        all_cache_digest_set.clearAndFree(testing.allocator);
    };
    const cwd = fs.cwd();
    const temp_manifest_dir = "no_file_inputs_manifest_dir";
    defer cwd.deleteTree(temp_manifest_dir) catch {};

    var digest1: [hex_digest_len]u8 = undefined;
    var digest2: [hex_digest_len]u8 = undefined;

    var cache = Cache{
        .gpa = testing.allocator,
        .manifest_dir = try cwd.makeOpenPath(temp_manifest_dir, .{}),
    };
    defer cache.manifest_dir.close();

    {
        var ch = cache.obtain();
        defer ch.deinit();

        ch.hash.addBytes("1234");

        // There should be nothing in the cache
        testing.expectEqual(false, try ch.hit());

        digest1 = ch.final();

        try ch.writeManifest();
    }
    {
        var ch = cache.obtain();
        defer ch.deinit();

        ch.hash.addBytes("1234");

        testing.expect(try ch.hit());
        digest2 = ch.final();
        try ch.writeManifest();
    }

    testing.expectEqual(digest1, digest2);
}

test "Manifest with files added after initial hash work" {
    if (std.Target.current.os.tag == .wasi) {
        // https://github.com/ziglang/zig/issues/5437
        return error.SkipZigTest;
    }
    defer if (want_debug_deadlock) {
        testing.expect(all_cache_digest_set.count() == 0);
        all_cache_digest_set.clearAndFree(testing.allocator);
    };
    const cwd = fs.cwd();

    const temp_file1 = "cache_hash_post_file_test1.txt";
    const temp_file2 = "cache_hash_post_file_test2.txt";
    const temp_manifest_dir = "cache_hash_post_file_manifest_dir";

    const ts1 = std.time.nanoTimestamp();
    try cwd.writeFile(temp_file1, "Hello, world!\n");
    try cwd.writeFile(temp_file2, "Hello world the second!\n");

    while (isProblematicTimestamp(ts1)) {
        std.time.sleep(1);
    }

    var digest1: [hex_digest_len]u8 = undefined;
    var digest2: [hex_digest_len]u8 = undefined;
    var digest3: [hex_digest_len]u8 = undefined;

    {
        var cache = Cache{
            .gpa = testing.allocator,
            .manifest_dir = try cwd.makeOpenPath(temp_manifest_dir, .{}),
        };
        defer cache.manifest_dir.close();

        {
            var ch = cache.obtain();
            defer ch.deinit();

            ch.hash.addBytes("1234");
            _ = try ch.addFile(temp_file1, null);

            // There should be nothing in the cache
            testing.expectEqual(false, try ch.hit());

            _ = try ch.addFilePost(temp_file2);

            digest1 = ch.final();
            try ch.writeManifest();
        }
        {
            var ch = cache.obtain();
            defer ch.deinit();

            ch.hash.addBytes("1234");
            _ = try ch.addFile(temp_file1, null);

            testing.expect(try ch.hit());
            digest2 = ch.final();

            try ch.writeManifest();
        }
        testing.expect(mem.eql(u8, &digest1, &digest2));

        // Modify the file added after initial hash
        const ts2 = std.time.nanoTimestamp();
        try cwd.writeFile(temp_file2, "Hello world the second, updated\n");

        while (isProblematicTimestamp(ts2)) {
            std.time.sleep(1);
        }

        {
            var ch = cache.obtain();
            defer ch.deinit();

            ch.hash.addBytes("1234");
            _ = try ch.addFile(temp_file1, null);

            // A file that we depend on has been updated, so the cache should not contain an entry for it
            testing.expectEqual(false, try ch.hit());

            _ = try ch.addFilePost(temp_file2);

            digest3 = ch.final();

            try ch.writeManifest();
        }

        testing.expect(!mem.eql(u8, &digest1, &digest3));
    }

    try cwd.deleteTree(temp_manifest_dir);
    try cwd.deleteFile(temp_file1);
    try cwd.deleteFile(temp_file2);
}
