const std = @import("std");

const Header = @This();

headers: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Header {
    return .{
        .allocator = allocator,
        .headers = .empty,
    };
}

/// Returns the first values associated with a header.
/// Returns an empty slice if the header does not exist.
pub fn get(this: *const Header, key: []const u8) []const u8 {
    const vals = this.headers.get(key) orelse return "";

    if (vals.items.len == 0)
        return "";

    return vals.items[0];
}

// Returns all values associated with the key
pub fn values(this: *const Header, key: []const u8) []const []const u8 {
    const vals = this.headers.get(key) orelse return &.{};
    return vals.items;
}

pub fn append(this: *Header, key: []const u8, value: []const u8) !void {
    const lower_key = try this.allocator.dupe(u8, key);
    defer this.allocator.free(lower_key);

    _ = std.ascii.lowerString(lower_key, lower_key);

    const owned_value = try this.allocator.dupe(u8, value);
    errdefer this.allocator.free(owned_value);

    if (this.headers.getPtr(lower_key)) |list| {
        try list.append(this.allocator, owned_value);
        return;
    }

    const owned_key = try this.allocator.dupe(u8, lower_key);
    errdefer this.allocator.free(owned_key);

    var vals: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer vals.deinit(this.allocator);

    try vals.append(this.allocator, owned_value);

    try this.headers.put(this.allocator, owned_key, vals);
}

/// Replaces any existing values for the header with a single value.
pub fn set(this: *Header, key: []const u8, value: []const u8) !void {
    try this.delete(key);
    try this.append(key, value);
}

pub fn delete(this: *Header, key: []const u8) !void {
    const lower_key = try this.allocator.dupe(u8, key);
    defer this.allocator.free(lower_key);

    _ = std.ascii.lowerString(lower_key, lower_key);

    var kv = this.headers.fetchRemove(lower_key) orelse return;

    for (kv.value.items) |val| {
        this.allocator.free(val);
    }

    kv.value.deinit(this.allocator);
    this.allocator.free(kv.key);
}

pub fn deinit(this: *Header) void {
    var it = this.headers.iterator();

    while (it.next()) |entry| {
        for (entry.value_ptr.items) |val| {
            this.allocator.free(val);
        }

        entry.value_ptr.deinit(this.allocator);
        this.allocator.free(entry.key_ptr.*);
    }

    this.headers.deinit(this.allocator);
}

pub fn generate_headers(this: *Header, allocator: std.mem.Allocator) ![]std.http.Header {
    var result = std.ArrayList(std.http.Header).empty;
    errdefer result.deinit(allocator);

    var it = this.headers.iterator();
    while (it.next()) |item| {
        const name = item.key_ptr.*;
        const h_values = item.value_ptr.*;
        for (h_values.items) |value| {
            try result.append(allocator, .{
                .name = name,
                .value = value,
            });
        }
    }

    return result.toOwnedSlice(allocator);
}

test "test 1" {
    const allocator = std.testing.allocator;
    var h: Header = .{
        .allocator = allocator,
        .headers = .empty,
    };
    defer h.deinit();

    _ = try h.set("Content-Type", "application/json");
    const data = h.get("content-type");
    try std.testing.expectEqualStrings("application/json", data);

    try h.append("content-type", "utf-8");

    const d2 = h.values("content-type");
    try std.testing.expectEqual(@as(usize, 2), d2.len);
    try std.testing.expectEqualStrings(
        "application/json",
        d2[0],
    );
    try std.testing.expectEqualStrings(
        "utf-8",
        d2[1],
    );
}
