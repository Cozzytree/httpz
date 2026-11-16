const std = @import("std");
const Io = std.Io;
const Headers = @import("./header.zig");
const httpz = @import("./root.zig");
const STREAM_THRESHOLD = 8 * 1024;

const ResponseState = union(enum) {
    idle,
    buffering: struct {
        body: std.ArrayListUnmanaged(u8),
    },
    streaming: struct {
        writer: std.http.BodyWriter,
    },
    finished,
};

pub const HttpResponse = struct {
    state: ResponseState = .idle,
    body: std.ArrayListUnmanaged(u8) = .empty,

    headers: Headers,
    stream_buffer: [4096]u8 = undefined,
    status: u16 = 200,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,

    const Self = @This();

    fn header(ptr: *anyopaque) *Headers {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return &self.headers;
    }

    pub fn finish(self: *Self) !void {
        switch (self.state) {
            .buffering => |*buf| {
                const headers = try self.headers.generate_headers(self.allocator);
                try self.request.respond(
                    buf.body.items,
                    .{
                        .status = @enumFromInt(self.status),
                        .extra_headers = headers,
                    },
                );

                buf.body.deinit(self.allocator);
                self.state = .finished;
            },

            .streaming => |*stream| {
                try stream.writer.end();
                self.state = .finished;
            },

            .finished => {},
            else => {},
        }
    }

    fn promoteToStreaming(self: *Self) !void {
        switch (self.state) {
            .buffering => |*buf| {
                const headers = try self.headers.generate_headers(self.allocator);
                var body_writer = try self.request.respondStreaming(
                    &self.stream_buffer,
                    .{ .respond_options = .{
                        .status = @enumFromInt(self.status),
                        .extra_headers = headers,
                    } },
                );
                try body_writer.writer.writeAll(buf.body.items);
                try body_writer.writer.flush();

                buf.body.deinit(self.allocator);
                self.state = .{
                    .streaming = .{
                        .writer = body_writer,
                    },
                };
            },
            else => return,
        }
    }

    fn writeImpl(self: *Self, content: []const u8) !usize {
        switch (self.state) {
            .idle => {
                var body: std.ArrayListUnmanaged(u8) = .empty;
                try body.appendSlice(self.allocator, content);
                self.state = .{ .buffering = .{ .body = body } };
                return content.len;
            },
            .buffering => |*buf| {
                const new_len = buf.body.items.len + content.len;
                if (new_len <= STREAM_THRESHOLD) {
                    try buf.body.appendSlice(self.allocator, content);
                } else {
                    try self.promoteToStreaming();
                    return self.writeImpl(content);
                }
            },
            .streaming => |*stream| {
                const i = try stream.writer.writer.write(content);
                stream.writer.writer.flush() catch {};
                return i;
            },
            .finished => {
                return error.ResponseAlreadyFinished;
            },
        }
        return content.len;
    }

    fn write(ptr: *anyopaque, content: []const u8) !usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.writeImpl(content);
    }

    fn writeHeader(ptr: *anyopaque, status: u16) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        switch (self.state) {
            .idle => self.status = status,
            .buffering => self.status = status,
            .streaming => {
                std.log.warn("Headers :already sent\n", .{});
            },
            .finished => {
                std.log.warn(
                    "WriteHeader called after response finished",
                    .{},
                );
            },
        }
    }

    fn flush(ptr: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        switch (self.state) {
            .idle => {
                try self.promoteToStreaming();
            },
            .buffering => {
                try self.promoteToStreaming();
            },
            .streaming => |*stream| {
                stream.writer.writer.flush() catch |err| {
                    return err;
                };
            },
            .finished => {
                return error.ResponseAlreadyFinished;
            },
        }
    }

    pub fn Response(self: *Self) httpz.ResponseWriter {
        return .{
            .ptr = self,
            .vtable = &.{
                .header = header,
                .write = write,
                .writeHeader = writeHeader,
                .flush = flush,
            },
        };
    }
};
