const std = @import("std");
const Io = std.Io;
const httpz = @import("httpz");

fn handle_user(_: httpz.ResponseWriter, req: *httpz.Request) !void {
    std.debug.print("{any}\n", .{req.method()});
    if (req.state(AppState)) |state| {
        std.debug.print("app name={s}\n", .{state.name});
    }

    try req.raw.respond("Hello from user", .{ .status = .ok });
}

fn handle_user_id(_: httpz.ResponseWriter, req: *httpz.Request) !void {
    if (req.get([]const u8, "userId")) |userId| {
        std.debug.print("userId {s}\n", .{userId.*});
        var buf: [100]u8 = undefined;
        const string = try std.fmt.bufPrint(buf[0..], "User ID = {s}\n", .{userId.*});
        if (req.header("Accept-Encoding")) |host| {
            std.debug.print("Host={s}\n", .{host});
        }
        try req.raw.respond(string, .{ .status = .ok });
    } else {
        try req.raw.respond("userid not found\n", .{});
    }
}

fn logger(_: httpz.ResponseWriter, req: *httpz.Request, next: *httpz.Next) !void {
    if (req.param("id")) |userId| {
        try req.set("userId", @ptrCast(&userId));
    }

    if (req.state(AppState)) |state| {
        try next.call(req);
        var buf: [256]u8 = undefined;
        var writer = state.log_file.writer(req.io, &buf);
        try writer.interface.print("{s} {any}\n", .{ req.path(), req.method() });
        try writer.interface.flush();
    } else {
        try next.call(req);
    }
}

fn logger1(_: httpz.ResponseWriter, req: *httpz.Request, next: *httpz.Next) !void {
    std.debug.print("from middleware 1\n", .{});
    try next.call(req);
    std.debug.print("leaving middleware 1\n", .{});
}

fn logger2(_: httpz.ResponseWriter, req: *httpz.Request, next: *httpz.Next) !void {
    std.debug.print("from middleware 2\n", .{});
    try next.call(req);
    std.debug.print("leaving middleware 2\n", .{});
}

fn logger3(_: httpz.ResponseWriter, req: *httpz.Request, next: *httpz.Next) !void {
    std.debug.print("from middleware 3\n", .{});
    try next.call(req);
    std.debug.print("leaving middleware 3\n", .{});
}

fn logger4(_: httpz.ResponseWriter, req: *httpz.Request, next: *httpz.Next) !void {
    std.debug.print("from middleware 4\n", .{});
    try next.call(req);
}

const AppState = struct {
    name: []const u8,
    log_file: Io.File,
};

fn api_handler(_: httpz.ResponseWriter, req: *httpz.Request) !void {
    try req.raw.respond("Hello from API\n", .{});
}

fn user_handler(_: httpz.ResponseWriter, req: *httpz.Request) !void {
    try req.raw.respond("Hello from USER API\n", .{});
}

fn home(w: httpz.ResponseWriter, req: *httpz.Request) !void {
    _ = req.query("");
    for (req.queries.items) |page| {
        std.debug.print("{s}={s}\n", .{ page.key, page.value });
    }

    try w.header().set("APPLE", "DAPLE");
    try w.header().set("APPLE", "MAPLE");
    w.writeHeader(200);

    _ = try w.write("");
    _ = try w.write(" World");
}

const User = struct {
    username: []const u8,
    password: []const u8,
};

fn createUser(w: httpz.ResponseWriter, req: *httpz.Request) !void {
    req.close_connection = true;
    const body = try req.jsonBodyParsed(User);
    defer body.deinit();
    std.debug.print("USERNAME={s}, PASSWORD={s}\n", .{
        body.value.username,
        body.value.password,
    });
    // var buff: [1024]u8 = undefined;
    // var reader = try req.body(&buff);
    // while (try reader.takeDelimiter('\n')) |line| {
    //     std.debug.print("line={s}\n", .{line});
    // }
    _ = try w.write("OK\n");
    w.writeHeader(201);
}

fn user(w: httpz.ResponseWriter, req: *httpz.Request) !void {
    try w.header().set("Content-Type", "text/html; charset=utf-8");

    _ = try w.write(
        \\<!DOCTYPE html>
        \\<html>
        \\<body>
        \\<h1>Streaming Test</h1>
    );

    try w.flush();

    try req.io.sleep(.fromSeconds(2), .real);

    var buf: [64 * 1024]u8 = undefined;
    @memset(&buf, 'A');

    _ = try w.write(buf[0..]);

    _ = try w.write(
        \\<div style="font-size:40px">
        \\FIRST CHUNK ARRIVED
        \\</div>
    );

    try w.flush();

    try req.io.sleep(.fromSeconds(2), .real);

    _ = try w.write(
        \\<div style="font-size:40px">
        \\SECOND CHUNK ARRIVED
        \\</div>
    );

    try w.flush();

    try req.io.sleep(.fromSeconds(2), .real);

    _ = try w.write(
        \\<div style="font-size:40px">
        \\THIRD CHUNK ARRIVED
        \\</div>
        \\</body>
        \\</html>
    );

    try w.flush();
}

fn handleFile(w: httpz.ResponseWriter, req: *httpz.Request) !void {
    const io = req.io;
    const cwd = Io.Dir.cwd();
    const file = try cwd.openFile(
        io,
        "./src/main.zig",
        .{ .mode = .read_only },
    );
    defer file.close(io);

    var read_buffer: [8 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buffer);

    var buffer: [1024]u8 = undefined;
    while (true) {
        const len = reader.interface.readSliceShort(&buffer) catch |err| switch (err) {
            error.ReadFailed => return err,
        };
        if (len == 0) break;

        _ = try w.write(buffer[0..len]);
        // try w.flush();
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var app_state = AppState{
        .name = "Cozzycode",
        .log_file = Io.File.stdout(),
    };

    var server = try httpz.Server.init(.{
        .host = "127.0.0.1",
        .port = 3000,
        .allocator = init.gpa,
        .app_state = &app_state,
        .read_header_timeout = 2000,
    });

    std.debug.print("Server listening in port {d}\n", .{3000});
    try server.GET("/", home);
    try server.GET("/users", handle_user);
    try server.GET("/users/:id", user);
    try server.GET("/file", handleFile);

    var api = server.GROUP("/api");
    try api.GET("/", api_handler);

    var user_api = try api.GROUP("/user");
    try user_api.POST("/", createUser);
    try user_api.GET("/", user_handler);

    try server.run(io);
}
