const std = @import("std");
const Method = std.http.Method;
const print = std.debug.print;
const Router = @This();
const httpz = @import("root.zig");
const Handler = httpz.Handler;
const Middleware = httpz.Middleware;

const RouteType = enum {
    static,
    param,
    catch_all,
};

const Route = struct {
    route_type: RouteType,
    param_count: u8 = 0,
    path: []const u8,
    children: std.ArrayList(Route) = .empty,
    method: ?Method = null,
    param_name: ?[]const u8 = null,
    handler: ?Handler = null,
    handlers: std.EnumArray(Method, ?Handler) = .initFill(null),
    middlewares: std.ArrayList(Middleware) = .empty,

    pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.middlewares.deinit(allocator);
        self.children.deinit(allocator);

        if (self.route_type == .static and self.path.len > 0) {
            allocator.free(self.path);
        }

        if (self.param_name) |param| {
            allocator.free(param);
        }
    }
};

root: Route = .{ .path = "", .route_type = .static },
global_middleware: std.ArrayList(Middleware) = .empty,

pub fn init() !Router {
    return .{};
}

pub fn deinit(
    self: *Router,
    allocator: std.mem.Allocator,
) void {
    self.global_middleware.deinit(allocator);
    self.root.deinit(allocator);
}

pub fn register(
    self: *Router,
    allocator: std.mem.Allocator,
    path: []const u8,
    method: Method,
    handler: Handler,
    middlewares: []const Middleware,
) !void {
    var current = &self.root;
    var it = std.mem.splitScalar(u8, path, '/');

    while (it.next()) |seg| {
        if (seg.len == 0) continue;

        const route_type: RouteType = blk: {
            if (seg[0] == ':') {
                break :blk .param;
            }

            if (seg[0] == '*') {
                break :blk .catch_all;
            }
            break :blk .static;
        };

        var child: ?*Route = null;
        for (current.children.items) |*candidate| {
            if (candidate.route_type != route_type) continue;
            switch (route_type) {
                .static => {
                    if (std.mem.eql(u8, candidate.path, seg)) {
                        child = candidate;
                        break;
                    }
                },
                .param => {
                    child = candidate;
                    break;
                },
                .catch_all => {
                    child = candidate;
                    break;
                },
            }
        }

        if (child == null) {
            const extra: u8 = switch (route_type) {
                .param, .catch_all => 1,
                else => 0,
            };

            const new_node = Route{
                .path = if (route_type == .static) try allocator.dupe(u8, seg) else "",
                .route_type = route_type,
                .param_count = current.param_count + extra,
                .param_name = if (route_type == .param) try allocator.dupe(u8, seg[1..]) else null,
            };
            try current.children.append(allocator, new_node);
            child = &current.children.items[current.children.items.len - 1];
        }

        current = child.?;
        if (route_type == .catch_all) break;
    }

    if (current.handlers.get(method) != null) {
        return error.RouteAlreadyRegistered;
    }

    current.handlers.set(method, handler);
    try current.middlewares.ensureTotalCapacity(allocator, middlewares.len);
    for (middlewares) |mw| {
        current.middlewares.appendAssumeCapacity(mw);
    }
}

pub const Match = struct {
    route: *Route,
    handler: Handler,
};

pub fn find(
    self: *Router,
    path: []const u8,
    method: Method,
    params_buffer: []httpz.Param,
    params_len: *usize,
    // paramMap: *std.StringHashMapUnmanaged([]const u8),
) !Match {
    params_len.* = 0;
    var current = &self.root;
    var it = std.mem.splitScalar(u8, path, '/');

    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        var next: ?*Route = null;
        for (current.children.items) |*child| {
            if (child.route_type != .static) continue;
            if (std.mem.eql(u8, child.path, segment)) {
                next = child;
                break;
            }
        }

        if (next == null) {
            for (current.children.items) |*child| {
                if (child.route_type != .param) continue;
                if (child.param_name) |param| {
                    params_buffer[params_len.*] = .{
                        .key = param,
                        .value = segment,
                    };
                    params_len.* += 1;
                }
                next = child;
                break;
            }
        }
        if (next == null) {
            for (current.children.items) |*child| {
                if (child.route_type != .catch_all) continue;
                next = child;
                break;
            }
        }

        if (next == null) return error.RouteNotFound;
        current = next.?;
        if (current.route_type == .catch_all) {
            const handler =
                current.handlers.get(method) orelse return error.MethodNotAllowed;

            return .{
                .route = current,
                .handler = handler,
            };
        }
    }

    const handler = current.handlers.get(method) orelse return error.MethodNotAllowed;
    return .{
        .route = current,
        .handler = handler,
    };
}

test "register route" {
    var r = try init();
    defer r.deinit(std.testing.allocator);

    const allocator = std.testing.allocator;
    const handler = struct {
        fn handle(
            _: httpz.ResponseWriter,
            request: *httpz.Request,
        ) anyerror!void {
            _ = request;
        }
    }.handle;

    try r.register(
        allocator,
        "/users",
        .GET,
        handler,
        &.{},
    );

    try r.register(
        allocator,
        "/users",
        .POST,
        handler,
        &.{},
    );

    try r.register(
        allocator,
        "/usres/:id",
        .GET,
        handler,
        &.{},
    );

    try std.testing.expectError(
        error.RouteAlreadyRegistered,
        r.register(
            allocator,
            "/users",
            .GET,
            handler,
            &.{},
        ),
    );

    try std.testing.expectError(
        error.RouteAlreadyRegistered,
        r.register(
            allocator,
            "/usres/:id",
            .GET,
            handler,
            &.{},
        ),
    );

    try r.register(
        allocator,
        "/users/:id/profile",
        .GET,
        handler,
        &.{},
    );
    try r.register(
        allocator,
        "/users/:id/settings/:setting",
        .GET,
        handler,
        &.{},
    );

    try r.register(
        allocator,
        "/users/:id/:apple",
        .GET,
        handler,
        &.{},
    );
    try std.testing.expectError(
        error.RouteAlreadyRegistered,
        r.register(
            allocator,
            "/users/:id/settings/:setting",
            .GET,
            handler,
            &.{},
        ),
    );
}

test "find root route" {
    const allocator = std.testing.allocator;

    var router = try Router.init();
    defer router.deinit(allocator);

    const handler = struct {
        fn handle(_: httpz.ResponseWriter, _: *httpz.Request) !void {}
    }.handle;

    try router.register(
        allocator,
        "/",
        .GET,
        handler,
        &.{},
    );

    var params_len: usize = 0;
    const match = try router.find(
        "/",
        .GET,
        &.{},
        &params_len,
    );

    try std.testing.expect(match.handler == handler);
}

test "find static route" {
    const allocator = std.testing.allocator;

    var router = try Router.init();
    defer router.deinit(allocator);

    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(allocator);

    const handler = struct {
        fn handle(_: httpz.ResponseWriter, _: *httpz.Request) !void {}
    }.handle;

    try router.register(
        allocator,
        "/users",
        .GET,
        handler,
        &.{},
    );

    var params_len: usize = 0;
    const match = try router.find(
        "/users",
        .GET,
        &.{},
        &params_len,
    );

    try std.testing.expect(match.handler == handler);
}

test "find param route" {
    const allocator = std.testing.allocator;

    var router = try Router.init();
    defer router.deinit(allocator);

    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(allocator);

    const handler = struct {
        fn handle(_: httpz.ResponseWriter, _: *httpz.Request) !void {}
    }.handle;

    try router.register(
        allocator,
        "/users/:id",
        .GET,
        handler,
        &.{},
    );

    const params_buffer = try allocator.alloc(httpz.Param, 100);
    defer allocator.free(params_buffer);
    var params_len: usize = 0;

    const match = try router.find(
        "/users/123",
        .GET,
        params_buffer,
        &params_len,
    );

    try std.testing.expect(match.handler == handler);
    try std.testing.expectEqualStrings(
        "123",
        params_buffer[0].value,
    );
}

test "find nested params" {
    const allocator = std.testing.allocator;

    var router = try Router.init();
    defer router.deinit(allocator);

    const handler = struct {
        fn handle(_: httpz.ResponseWriter, _: *httpz.Request) !void {}
    }.handle;

    try router.register(
        allocator,
        "/users/:id/settings/:setting",
        .GET,
        handler,
        &.{},
    );

    const params_buffer =
        try allocator.alloc(httpz.Param, 100);
    defer allocator.free(params_buffer);

    var params_len: usize = 0;

    const match = try router.find(
        "/users/42/settings/theme",
        .GET,
        params_buffer,
        &params_len,
    );

    try std.testing.expect(match.handler == handler);

    try std.testing.expectEqual(
        @as(usize, 2),
        params_len,
    );

    try std.testing.expectEqualStrings(
        "id",
        params_buffer[0].key,
    );

    try std.testing.expectEqualStrings(
        "42",
        params_buffer[0].value,
    );

    try std.testing.expectEqualStrings(
        "setting",
        params_buffer[1].key,
    );

    try std.testing.expectEqualStrings(
        "theme",
        params_buffer[1].value,
    );
}

test "same path different methods" {
    const allocator = std.testing.allocator;

    var router = try Router.init();
    defer router.deinit(allocator);

    const get_handler = struct {
        fn handle(_: httpz.ResponseWriter, _: *httpz.Request) !void {}
    }.handle;

    const post_handler = struct {
        fn handle(_: httpz.ResponseWriter, _: *httpz.Request) !void {}
    }.handle;

    try router.register(
        allocator,
        "/users",
        .GET,
        get_handler,
        &.{},
    );

    try router.register(
        allocator,
        "/users",
        .POST,
        post_handler,
        &.{},
    );

    var params_len: usize = 0;
    const get_match = try router.find(
        "/users",
        .GET,
        &.{},
        &params_len,
    );

    const post_match = try router.find(
        "/users",
        .POST,
        &.{},
        &params_len,
    );

    try std.testing.expect(get_match.handler == get_handler);
    try std.testing.expect(post_match.handler == post_handler);
}

test "method not allowed" {
    const allocator = std.testing.allocator;

    var router = try Router.init();
    defer router.deinit(allocator);

    const handler = struct {
        fn handle(_: httpz.ResponseWriter, _: *httpz.Request) !void {}
    }.handle;

    try router.register(
        allocator,
        "/users",
        .GET,
        handler,
        &.{},
    );

    var params_len: usize = 0;
    try std.testing.expectError(
        error.MethodNotAllowed,
        router.find(
            "/users",
            .POST,
            &.{},
            &params_len,
        ),
    );
}

test "route not found" {
    const allocator = std.testing.allocator;

    var router = try Router.init();
    defer router.deinit(allocator);

    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(allocator);

    var params_len: usize = 0;
    try std.testing.expectError(
        error.RouteNotFound,
        router.find(
            "/does-not-exist",
            .GET,
            &.{},
            &params_len,
        ),
    );
}

test "static route takes precedence over param" {
    const allocator = std.testing.allocator;

    var router = try Router.init();
    defer router.deinit(allocator);

    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(allocator);

    const static_handler = struct {
        fn handle(_: httpz.ResponseWriter, _: *httpz.Request) !void {}
    }.handle;

    const param_handler = struct {
        fn handle2(_: httpz.ResponseWriter, _: *httpz.Request) !void {}
    }.handle2;

    try router.register(
        allocator,
        "/users/me",
        .GET,
        static_handler,
        &.{},
    );

    try router.register(
        allocator,
        "/users/:id",
        .GET,
        param_handler,
        &.{},
    );

    var params_len: usize = 0;
    const match = try router.find(
        "/users/me",
        .GET,
        &.{},
        &params_len,
    );

    try std.testing.expect(
        match.handler == static_handler,
    );
}
