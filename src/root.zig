const std = @import("std");
const Io = std.Io;
const Router = @import("router.zig");
const Method = std.http.Method;
const Headers = @import("./header.zig");
const Response = @import("response.zig");

pub const Error = error{
    InvalidJson,
    PayloadTooLarge,
};

pub const ResponseWriter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        header: *const fn (ptr: *anyopaque) *Headers,
        write: *const fn (ptr: *anyopaque, data: []const u8) anyerror!usize,
        writeHeader: *const fn (ptr: *anyopaque, status: u16) void,
    };

    pub fn header(self: ResponseWriter) *Headers {
        return self.vtable.header(self.ptr);
    }

    pub fn write(self: ResponseWriter, data: []const u8) !usize {
        return self.vtable.write(self.ptr, data);
    }

    pub fn writeHeader(self: ResponseWriter, status: u16) void {
        self.vtable.writeHeader(self.ptr, status);
    }
};

pub const ResponseCookie = struct {
    secure: bool = false,
    http_only: bool = false,

    name: []const u8,
    value: []const u8,
    domain: ?[]const u8 = null,

    max_age: ?i64 = null,
    path: ?[]const u8 = "/",

    same_site: ?[]const u8 = "Lax",
};

pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

const Query = struct {
    key: []const u8,
    value: []const u8,
};

pub const Request = struct {
    _body_cache: ?[]const u8 = null,
    max_body_size: usize = 1024 * 1024,
    io: std.Io,
    raw: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    params: []Param = &.{},
    values: std.StringHashMapUnmanaged(*const anyopaque) = .empty,
    response_cookies: std.ArrayListUnmanaged(ResponseCookie) = .empty,
    app_state: ?*anyopaque = null,

    cookie_parsed: bool = false,
    // lazily loaded
    cookies: std.StringHashMapUnmanaged([]const u8) = .empty,

    // lazily loaded when called query() for the first time
    queries: std.ArrayListUnmanaged(Query) = .empty,
    query_parsed: bool = false,

    // cookies
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

    pub fn setCookie(self: *Request, res_cookie: ResponseCookie) !void {
        try self.response_cookies.append(self.allocator, res_cookie);
    }

    pub fn deleteCookie(self: *Request, name: []const u8) !void {
        try self.setCookie(.{
            .name = name,
            .value = "",
            .max_age = 0,
        });
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
            .header = Headers.init(allocator),
        };
    }

    pub fn deinit(self: *Request) void {
        self.values.deinit(self.allocator);
        self.cookies.deinit(self.allocator);
        self.queries.deinit(self.allocator);
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

    fn parseQuery(self: *Request) !void {
        self.query_parsed = true;
        const tar = self.target();

        const idx = std.mem.findScalar(u8, tar, '?') orelse return;
        const query_str = tar[idx + 1 ..];
        var pair_it = std.mem.splitScalar(u8, query_str, '&');
        while (pair_it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=');
            if (eq) |i| {
                try self.queries.append(self.allocator, .{
                    .key = pair[0..i],
                    .value = pair[i + 1 ..],
                });
            } else {
                try self.queries.append(
                    self.allocator,
                    .{
                        .key = pair,
                        .value = "",
                    },
                );
            }
        }
    }

    pub fn query(self: *Request, key: []const u8) ?[]const u8 {
        if (!self.query_parsed) {
            self.parseQuery() catch return null;
        }

        for (self.queries.items) |q| {
            if (std.mem.eql(u8, key, q.key)) return q.value;
        }
        return null;
    }

    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        var it = self.raw.iterateHeaders();
        while (it.next()) |head| {
            if (std.ascii.eqlIgnoreCase(head.name, name)) return head.value;
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

    // utitlities
    pub fn redirect(self: *const Request, uri: []const u8, status: std.http.Status) !void {
        try self.raw.respond("", .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "Location", .value = uri },
            },
        });
    }

    pub fn body(self: *Request) ![]const u8 {
        if (self._body_cache) |cached_body| {
            return cached_body;
        }

        var transfer_buff: [4096]u8 = undefined;
        var reader = try self.raw.readerExpectContinue(&transfer_buff);

        const data = reader.allocRemaining(
            self.allocator,
            .limited(self.max_body_size),
        ) catch |err| switch (err) {
            Io.Reader.LimitedAllocError.StreamTooLong => return Error.PayloadTooLarge,
            else => return err,
        };

        self._body_cache = data;
        return data;
    }

    pub fn jsonBody(self: *Request, comptime T: type) !T {
        const data = try self.body();
        const parsed = try std.json.parseFromSlice(
            T,
            self.allocator,
            data,
            .{ .ignore_unknown_fields = true },
        );
        return parsed.value;
    }

    pub fn respondJson(self: *Request, value: anytype) !void {
        var writer = Io.Writer.Allocating.init(self.allocator);

        var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try json.write(value);

        var headers = std.ArrayListUnmanaged(std.http.Header).empty;

        var cookie_storage = Io.Writer.Allocating.init(self.allocator);

        for (self.response_cookies.items) |res_cookie| {
            const start = cookie_storage.written().len;
            try write_cookie(&cookie_storage.writer, res_cookie);

            const end = cookie_storage.written().len;
            try headers.append(self.allocator, .{
                .name = "Set-Cookie",
                .value = cookie_storage.written()[start..end],
            });
        }
        try headers.append(self.allocator, .{ .name = "Content-Type", .value = "application/json" });

        try self.raw.respond(writer.written(), .{
            .status = .ok,
            .extra_headers = headers.items,
        });
    }
};

pub const Handler = *const fn (ResponseWriter, *Request) anyerror!void;
pub const Middleware = *const fn (ResponseWriter, *Request, next: *Next) anyerror!void;

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
        response_writer: ResponseWriter,
        req: *Request,
    ) !void {
        const total =
            self.global.len +
            self.route.len;

        if (self.index >= total) {
            return self.handler(response_writer, req);
        }

        const current = self.get_middleware(self.index);
        self.index += 1;

        try current(response_writer, req, self);
    }
};

const Options = struct {
    port: u16,
    host: []const u8,
    allocator: std.mem.Allocator,
    app_state: ?*anyopaque,
    max_body_size: usize = 1024 * 1024,
    read_header_timeout: ?i64 = null,
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
    read_header_timeout: ?i64 = null,
    max_body_size: usize,

    pub fn init(options: Options) !Server {
        return .{
            .address = try .parse(options.host, options.port),
            .allocator = options.allocator,
            .router = try Router.init(),
            .app_state = options.app_state,
            .max_body_size = options.max_body_size,
            .read_header_timeout = options.read_header_timeout,
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

const Result = union(enum) {
    request: std.http.Server.ReceiveHeadError!std.http.Server.Request,
    timeout: Io.Cancelable!void,
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

        var storage: [2]Result = undefined;
        var select = Io.Select(Result).init(io, &storage);
        defer _ = select.cancel();

        select.concurrent(.request, receiveHeadTask, .{&http_server}) catch {
            return error.Canceled;
        };

        if (server.read_header_timeout) |timeout_ms| {
            select.concurrent(
                .timeout,
                timeoutTask,
                .{
                    io,
                    Io.Duration.fromMilliseconds(timeout_ms),
                },
            ) catch {
                return error.Canceled;
            };
        }

        var head = switch (try select.await()) {
            .request => |req| req catch {
                return error.Canceled;
            },

            .timeout => |res| {
                res catch {
                    return error.Canceled;
                };
                std.log.debug("header timeout", .{});
                return;
            },
        };

        var response = Response.HttpResponse{
            .headers = .{
                .allocator = req_alloc,
                .headers = .empty,
            },
            .allocator = req_alloc,
            .request = &head,
        };
        defer {
            response.finish() catch {};
        }

        const response_writer = response.Response();

        var request = Request{
            .allocator = req_alloc,
            .io = io,
            .raw = &head,
            .app_state = server.app_state,
            .max_body_size = server.max_body_size,
        };
        defer request.deinit();

        const params_buf = req_alloc.alloc(Param, 100) catch {
            return error.Canceled;
        };
        var params_len: usize = 0;

        const path = stripQuery(head.head.target);
        const match = server.router.find(
            path,
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
        chain.call(response_writer, &request) catch |err| {
            std.debug.print("HANDLER ERROR={any}\n", .{err});
            head.respond("INTERNAL SERVER ERROR\n", .{
                .status = .internal_server_error,
            }) catch return;
            return;
        };
    }
}

fn receiveHeadTask(
    server: *std.http.Server,
) std.http.Server.ReceiveHeadError!std.http.Server.Request {
    return try server.receiveHead();
}

fn timeoutTask(io: Io, duration: Io.Duration) Io.Cancelable!void {
    try io.sleep(duration, .real);
}

fn stripQuery(target: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, target, '?')) |idx|
        target[0..idx]
    else
        target;
}

fn write_cookie(writer: *Io.Writer, cookie: ResponseCookie) !void {
    try writer.print("{s}={s}", .{ cookie.name, cookie.value });

    if (cookie.path) |path| try writer.print("; Path={s}", .{path});

    if (cookie.domain) |domain| try writer.print("; Domain={s}", .{domain});

    if (cookie.max_age) |max_age| try writer.print("; Max-Age={d}", .{max_age});

    if (cookie.http_only) try writer.writeAll("; HttpOnly");

    if (cookie.secure) try writer.writeAll("; Secure");

    if (cookie.same_site) |same_site| try writer.print("; SameSite={s}", .{same_site});
}
