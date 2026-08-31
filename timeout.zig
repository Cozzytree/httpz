const std = @import("std");
const Io = std.Io;

const Result = union(enum) {
    worker: Io.Cancelable![]const u8,
    timeout: Io.Cancelable![]const u8,
};

fn workerTask(io: Io) Io.Cancelable![]const u8 {
    try io.sleep(.fromSeconds(2), .real);
    return "worker";
}

fn timeoutTask(io: Io) Io.Cancelable![]const u8 {
    try io.sleep(.fromSeconds(5), .real);
    return "timeout";
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var storage: [2]Result = undefined;
    var select = Io.Select(Result).init(io, &storage);
    defer _ = select.cancel();

    select.async(.worker, workerTask, .{io});
    select.async(.timeout, timeoutTask, .{io});

    const result = try select.await();

    switch (result) {
        .worker => |r| {
            std.debug.print("{s}\n", .{try r});
        },
        .timeout => |r| {
            std.debug.print("{s}\n", .{try r});
        },
    }

    std.debug.print("{}\n", .{result});
}
