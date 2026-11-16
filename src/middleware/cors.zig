const std = @import("std");
const httpz = @import("httpz");

const Cors = @This();

pub const Origin = union(enum) {
    wildcard,
    list: []const []const u8,
};

pub const Config = struct {
    origin: Origin,
    headers: ?[]const u8 = null,
    methods: ?[]const u8 = null,
    max_age: ?[]const u8 = null,
    credentials: ?[]const u8 = null,
};

origin: Origin,
headers: ?[]const u8 = null,
methods: ?[]const u8 = null,
max_age: ?[]const u8 = null,
credentials: ?[]const u8 = null,

pub fn init(config: Config) !Cors {
    return .{
        .origin = config.origin,
        .credentials = config.credentials,
        .headers = config.headers,
        .max_age = config.max_age,
        .methods = config.methods,
    };
}

pub fn execute(self: *const Cors) httpz.Middleware {
    return struct {
        fn middleware(w: httpz.ResponseWriter, req: *httpz.Request, next: *httpz.Next) !void {
            const origin = req.header("origin") orelse {
                return next.call(w, req);
            };

            switch (self.origin) {
                .wildcard => try w.header().set("Access-Control-Allow-Origin", "*"),
                .list => |allowed_origins| {
                    for (allowed_origins) |allowed_origin| {
                        if (std.mem.eql(u8, origin, allowed_origin)) {
                            try w.header().set("Access-Control-Allow-Origin", origin);
                            break;
                        }
                    } else {
                        return next.call(w, req);
                    }
                },
            }

            if (self.credentials) |credentials| {
                w.header().set("Access-Control-Allow-Credentials", credentials);
            }

            if (req.method() != .OPTIONS) {
                return next.call(w, req);
            }

            const mode = req.header("sec-fetch-mode") orelse {
                return next.call(w, req);
            };

            if (std.mem.eql(u8, mode, "cors") == false) {
                return next.call(w, req);
            }
            if (self.headers) |headers| {
                try w.header().set("Access-Control-Allow-Headers", headers);
            }
            if (self.max_age) |max_age| {
                try w.header().set("Access-Control-Max-Age", max_age);
            }

            w.writeHeader(204);
        }
    }.middleware;
}
