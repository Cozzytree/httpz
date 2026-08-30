const std = @import("std");
const Io = std.Io;
const Router = @import("router.zig");
const Method = std.http.Method;

pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

pub const Request = struct {
    io: std.Io,
    raw: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    // params: std.StringHashMapUnmanaged([]const u8) = .empty,
    params: []Param = &.{},
    values: std.StringHashMapUnmanaged(*const anyopaque) = .empty,
    app_state: ?*anyopaque = null,
    cookie_parsed: bool = false,
    cookies: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn parseCookie(self: *Request) !void {
        self.cookie_parsed = true;
        if (self.header("cookie")) |cookie_header| {
            var it = std.mem.splitScalar(u8, cookie_header, ';');
            while (it.next()) |pair| {
                const trimmed = std.mem.trim(u8, pair, " ");
                const idx = std.mem.findScalar(u8, trimmed, '=') orelse continue;
                try self.cookies.put(self.allocator, trimmed[0..idx], trimmed[idx + 1 ..]);
            }
        }
    }

    pub fn cookie(self: *Request, key: []const u8) ?[]const u8 {
        if (!self.cookie_parsed) {
            self.parseCookie() catch return null;
        }
        return self.cookies.get(key);
    }

    pub fn state(self: *Request, comptime T: type) ?*T {
        const ptr = self.app_state orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn init(
        io: std.Io,
        raw: *std.http.Server.Request,
        allocator: std.mem.Allocator,
    ) Request {
        return .{
            .allocator = allocator,
            .raw = raw,
            .io = io,
        };
    }

    pub fn deinit(self: *Request) void {
        self.values.deinit(self.allocator);
    }

    pub fn method(self: *const Request) Method {
        return self.raw.head.method;
    }

    pub fn target(self: *const Request) []const u8 {
        return self.raw.head.target;
    }

    pub fn path(self: *const Request) []const u8 {
        const tar = self.target();
        if (std.mem.indexOfScalar(u8, tar, '?')) |index| {
            return tar[0..index];
        }
        return tar;
    }

    pub fn query(self: *const Request) []const u8 {
        const tar = self.target();
        if (std.mem.indexOfScalar(u8, tar, '?')) |index| {
            return tar[index + 1 ..];
        }
        return "";
    }

    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        var it = self.raw.iterateHeaders();
        while (it.next()) |head| {
            if (std.mem.eql(u8, head.name, name)) return head.value;
        }
        return null;
    }

    pub fn param(self: *const Request, key: []const u8) ?[]const u8 {
        for (self.params) |par| {
            if (std.mem.eql(u8, par.key, key)) {
                return par.value;
            }
        }
        return null;
    }

    // Context
    pub fn set(
        self: *Request,
        key: []const u8,
        value: *const anyopaque,
    ) !void {
        try self.values.put(self.allocator, key, value);
    }

    pub fn get(
        self: *Request,
        comptime T: type,
        key: []const u8,
    ) ?*const T {
        const value = self.values.get(key) orelse return null;
        return @ptrCast(@alignCast(value));
    }

    pub fn rawBody(_: *Request) ![]const u8 {
        return null;
    }
};
pub const Handler = *const fn (*Request) anyerror!void;
pub const Middleware = *const fn (*Request, next: *Next) anyerror!void;

pub const Next = struct {
    global: []const Middleware,
    route: []const Middleware,
    handler: Handler,
    index: usize = 0,

    fn get_middleware(self: *Next, idx: usize) Middleware {
        if (idx < self.global.len) {
            return self.global[idx];
        }
        return self.route[idx - self.global.len];
    }

    pub fn call(
        self: *Next,
        req: *Request,
    ) !void {
        const total =
            self.global.len +
            self.route.len;

        if (self.index >= total) {
            return self.handler(req);
        }

        const current = self.get_middleware(self.index);
        self.index += 1;

        try current(req, self);
    }
};

const Options = struct {
    port: u16,
    host: []const u8,
    allocator: std.mem.Allocator,
    app_state: ?*anyopaque,
};

const Group = struct {
    prefix: []const u8,
    server: *Server,
    middlewares: std.ArrayListUnmanaged(Middleware) = .empty,

    pub fn GET(self: *Group, path: []const u8, handler: Handler) !void {
        const full = try std.mem.concat(
            self.server.allocator,
            u8,
            &.{ self.prefix, path },
        );
        defer self.server.allocator.free(full);
        try self.server.router.register(
            self.server.allocator,
            full,
            .GET,
            handler,
            self.middlewares.items,
        );
    }

    pub fn USE(self: *Group, handler: Middleware) !void {
        try self.middlewares.append(self.server.allocator, handler);
    }

    pub fn POST(self: *Group, path: []const u8, handler: Handler) !void {
        const full = try std.mem.concat(
            self.server.allocator,
            u8,
            &.{ self.prefix, path },
        );
        defer self.server.allocator.free(full);
        try self.server.router.register(
            self.server.allocator,
            full,
            .POST,
            handler,
            self.middlewares.items,
        );
    }

    pub fn GROUP(self: *Group, prefix: []const u8) !Group {
        var group = Group{
            .server = self.server,
            .prefix = try std.mem.concat(
                self.server.allocator,
                u8,
                &.{ self.prefix, prefix },
            ),
        };
        try group.middlewares.appendSlice(self.server.allocator, self.middlewares.items);
        return group;
    }
};

pub const Server = struct {
    app_state: ?*anyopaque = null,
    address: Io.net.IpAddress,
    router: Router,
    allocator: std.mem.Allocator,

    pub fn init(options: Options) !Server {
        return .{
            .address = try .parse(options.host, options.port),
            .allocator = options.allocator,
            .router = try Router.init(),
            .app_state = options.app_state,
        };
    }

    pub fn GET(self: *Server, path: []const u8, handler: Handler) !void {
        try self.router.register(self.allocator, path, .GET, handler, &.{});
    }

    pub fn POST(self: *Server, path: []const u8, handler: Handler) !void {
        try self.router.register(self.allocator, path, .POST, handler, &.{});
    }

    pub fn DELETE(self: *Server, path: []const u8, handler: Handler) !void {
        try self.router.register(self.allocator, path, .DELETE, handler, &.{});
    }

    pub fn PATCH(self: *Server, path: []const u8, handler: Handler) !void {
        try self.router.register(self.allocator, path, .PATCH, handler, &{});
    }

    pub fn USE(self: *Server, handler: Middleware) !void {
        try self.router.global_middleware.append(self.allocator, handler);
    }

    pub fn GROUP(self: *Server, prefix: []const u8) Group {
        return .{
            .prefix = prefix,
            .server = self,
        };
    }

    pub fn run(self: *Server, io: Io) !void {
        var server = try self.address.listen(io, .{
            .reuse_address = true,
            .protocol = .tcp,
        });
        var group = Io.Group.init;
        defer group.cancel(io);

        while (true) {
            const stream = server.accept(io) catch |err| switch (err) {
                else => {
                    std.debug.print("error = {any}\n", .{err});
                    continue;
                },
            };

            group.async(io, handle_connection, .{ io, self, stream });
        }
    }
};

fn handle_connection(io: Io, server: *Server, stream: Io.net.Stream) error{Canceled}!void {
    defer stream.close(io);

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    var arena = std.heap.ArenaAllocator.init(server.allocator);
    defer arena.deinit();

    var writer = stream.writer(io, &write_buffer);
    var reader = stream.reader(io, &read_buffer);

    var http_server: std.http.Server = .init(&reader.interface, &writer.interface);
    while (http_server.reader.state == .ready) {
        defer _ = arena.reset(.retain_capacity);
        const req_alloc = arena.allocator();

        var head = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => {
                return;
            },
            else => {
                return error.Canceled;
            },
        };

        var request = Request{
            .allocator = req_alloc,
            .io = io,
            .raw = &head,
            .app_state = server.app_state,
        };
        defer request.deinit();

        const params_buf = req_alloc.alloc(Param, 100) catch {
            return error.Canceled;
        };
        var params_len: usize = 0;

        const match = server.router.find(
            head.head.target,
            head.head.method,
            params_buf,
            &params_len,
        ) catch |err| switch (err) {
            error.RouteNotFound => {
                head.respond("Not Found", .{
                    .status = .not_found,
                }) catch {
                    return error.Canceled;
                };
                return;
            },
            error.MethodNotAllowed => {
                head.respond("Method Not Allowed", .{
                    .status = .method_not_allowed,
                }) catch {
                    return error.Canceled;
                };
                return;
            },
            // else => return error.Canceled,
        };

        request.params = params_buf[0..params_len];
        var chain = Next{
            .index = 0,
            .global = server.router.global_middleware.items,
            .route = match.route.middlewares.items,
            .handler = match.handler,
        };
        chain.call(&request) catch {
            head.respond("INTERNAL SERVER ERROR\n", .{
                .status = .internal_server_error,
            }) catch return;
            return;
        };
    }
}
