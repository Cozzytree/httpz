const std = @import("std");
const Io = std.Io;
const httpz = @import("root.zig");

pub fn CookieParse(req: *httpz.Request, next: *httpz.Next) {
    if (req.header("Cookie")) |cookie| {};
}
