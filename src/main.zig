const std = @import("std");
const serial = @import("serial");
const args_parser = @import("args");
const builtin = @import("builtin");

const CliOptions = struct {
    help: bool = false,

    port: ?[]const u8 = null,
    baud: u32 = 115_200,
    @"stop-bits": serial.StopBits = .one,
    @"data-bits": u4 = 8,
    parity: serial.Parity = .none,
    @"control-flow": serial.Handshake = .none,

    echo: bool = false,

    pub const shorthands = .{
        .h = "help",
        .b = "baud",
        .P = "port",
        .s = "stop-bits",
        .p = "parity",
        .d = "data-bits",
        .c = "control-flow",
        .e = "echo",
    };
};

pub fn main() !u8 {
    errdefer |e| if (e == error.SilentExit) {
        std.os.exit(1);
    };

    const stderr = std.io.getStdErr();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var cli = args_parser.parseForCurrentProcess(CliOptions, allocator, .print) catch return 1;
    defer cli.deinit();

    const port_name = if (cli.options.port) |port|
        try allocator.dupe(u8, port)
    else
        try autoDetectSerialPort(allocator);
    defer allocator.free(port_name);

    var port = std.fs.openFileAbsolute(port_name, .{ .mode = .read_write }) catch |err| {
        try stderr.writer().print("Could not open serial port: {s}\n", .{
            switch (err) {
                error.FileNotFound => "file not found",
                error.AccessDenied => "access denied (missing permissions?)",
                else => |e| @errorName(e),
            },
        });
        return 1;
    };
    defer port.close();

    try serial.configureSerialPort(port, .{
        .baud_rate = cli.options.baud,
        .parity = cli.options.parity,
        .stop_bits = cli.options.@"stop-bits",
        .word_size = cli.options.@"data-bits",
        .handshake = cli.options.@"control-flow",
    });

    try IoOptions.configureSerialNonBlocking(port);
    {
        const stdin = std.io.getStdIn();
        const stdout = std.io.getStdOut();

        const stdin_restore = try IoOptions.configureTtyNonBlocking(stdin);
        defer stdin_restore.restore(stdin) catch |err| std.log.err("we fucked up. failed to restore settings for stdin: {s}. Try resetting/restarting your terminal!", .{@errorName(err)});

        // const stdout_restore = try IoOptions.configureTtyNonBlocking(stdout);
        // defer stdout_restore.restore(stdout) catch |err| std.log.err("we fucked up. failed to restore settings for stdout: {s}. Try resetting/restarting your terminal!", .{@errorName(err)});

        try stderr.writeAll("Connected. Use C-a C-q to exit.\r\n");

        inputOutputLoop(port, stdin, stdout, cli.options.echo) catch |err| {
            if (err != error.CleanExit) {
                try stderr.writer().print("\r\ni/o error: {s}\r\n", .{@errorName(err)});
                return error.SilentExit; // abuse cleanup rules for clean std.os.exit(1)
            }
        };
    }

    try stderr.writeAll("\r\nzcom done.\n");

    return 0;
}

fn subMenu(port: std.fs.File, stdin: std.fs.File, stdout: std.fs.File, local_echo: bool) !void {
    const stderr = std.io.getStdErr();

    const cmd_timeout_ns = 500 * std.time.ns_per_ms;
    const timeout = std.time.nanoTimestamp() + cmd_timeout_ns;

    while (std.time.nanoTimestamp() < timeout) {
        var buffer: [1024]u8 = undefined;
        const len = stdin.read(&buffer) catch |err| switch (err) {
            error.WouldBlock => @as(usize, 0),
            else => |e| return e,
        };
        if (len == 0) {
            continue;
        }

        switch (buffer[0]) {
            0x01 => {
                if (local_echo) {
                    try stdout.writeAll("\x01");
                }
                try port.writeAll("\x01");
            },
            0x11, 0x18, 'q', 'Q', 'x', 'X' => return error.CleanExit,
            else => {
                try stderr.writer().print("?[{X:0>2}]", .{buffer[0]});
                return;
            },
        }
    }

    // TODO: Notify user about timeout
}

fn inputOutputLoop(port: std.fs.File, stdin: std.fs.File, stdout: std.fs.File, local_echo: bool) !void {
    var buffer: [1024]u8 = undefined;
    while (true) {
        {
            const len = port.read(&buffer) catch |err| switch (err) {
                error.WouldBlock => @as(usize, 0),
                else => |e| return e,
            };
            if (len > 0) {
                try stdout.writeAll(buffer[0..len]);
            }
        }

        {
            const len = stdin.read(&buffer) catch |err| switch (err) {
                error.WouldBlock => @as(usize, 0),
                else => |e| return e,
            };
            if (len > 0) {
                if (len == 1 and buffer[0] == 1) {
                    // C-a
                    subMenu(port, stdin, stdout, local_echo) catch |err| {
                        if (err == error.CleanExit) {
                            return error.CleanExit;
                        } else {
                            std.log.err("failed to execute sub menu: {s}", .{@errorName(err)});
                        }
                    };
                } else {
                    if (local_echo) {
                        try stdout.writeAll(buffer[0..len]);
                    }
                    try port.writeAll(buffer[0..len]);
                }
            }
        }
    }
}

fn sortSerialPortDescription(_: void, a: serial.SerialPortDescription, b: serial.SerialPortDescription) bool {
    return std.ascii.lessThanIgnoreCase(a.display_name, b.display_name);
}

fn autoDetectSerialPort(allocator: std.mem.Allocator) ![]const u8 {
    const stderr = std.io.getStdErr();
    const stdin = std.io.getStdIn();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ports = try serial.PortIterator.init();
    defer ports.deinit();

    var list = std.ArrayList(serial.SerialPortDescription).init(arena.allocator());
    defer list.deinit();

    while (try ports.next()) |desc| {
        try list.append(.{
            .file_name = try arena.allocator().dupe(u8, desc.file_name),
            .display_name = try arena.allocator().dupe(u8, desc.display_name),
            .driver = if (desc.driver) |driver|
                try arena.allocator().dupe(u8, driver)
            else
                null,
        });
    }

    std.sort.block(serial.SerialPortDescription, list.items, {}, sortSerialPortDescription);

    if (list.items.len == 0) {
        try stderr.writeAll("No serial port could be auto-detected. Use --port <name> to provide the port.\r\n");
        std.os.exit(1);
    }

    var default_selection: usize = 0;

    for (list.items, 1..) |desc, index| {
        const names_eql = std.mem.eql(u8, desc.file_name, desc.display_name);

        try stderr.writer().print("#{d: <2} {s} ", .{ index, desc.display_name });

        if (names_eql) {
            if (desc.driver) |driver| {
                try stderr.writer().print("(driver={s})\n", .{driver});
            } else {
                try stderr.writer().print("\n", .{});
            }
        } else {
            if (desc.driver) |driver| {
                try stderr.writer().print("(path={s}, driver={s})\n", .{ desc.file_name, driver });
            } else {
                try stderr.writer().print("(path={s})\n", .{desc.file_name});
            }
        }

        if (desc.driver) |driver| {
            if (!std.mem.eql(u8, driver, "serial8250")) {
                default_selection = index;
            }
        }
    }

    const selection = while (true) {
        try stderr.writer().print("Select port [{}]: ", .{default_selection});

        var buffer: [64]u8 = undefined;
        const selection_or_null = try stdin.reader().readUntilDelimiterOrEof(&buffer, '\n');

        const selection_str = std.mem.trim(u8, selection_or_null orelse break default_selection, "\r\n\t ");

        if (selection_str.len == 0)
            break default_selection;

        const selection = std.fmt.parseInt(usize, selection_str, 10) catch continue;

        if (selection < 1 or selection > list.items.len) {
            continue;
        }

        break selection;
    };

    return try allocator.dupe(u8, list.items[selection - 1].file_name);
}

const IoOptions = switch (builtin.os.tag) {
    .windows => struct {
        fn configureTtyNonBlocking(file: std.fs.File) !IoOptions {
            _ = file;
            @compileError("no windows support yet!");
        }

        fn configureSerialNonBlocking(file: std.fs.File) !void {
            _ = file;
            @compileError("no windows support yet!");
        }

        fn restore(options: IoOptions, file: std.fs.File) !void {
            _ = options;
            _ = file;
            @compileError("no windows support yet!");
        }
    },

    // assume unix
    else => struct {
        const VTIME = 5;
        const VMIN = 6;

        const os = switch (builtin.os.tag) {
            .macos => std.os.darwin,
            .linux => std.os.linux,
            else => unreachable,
        };

        termios: os.termios,

        fn configureTtyNonBlocking(file: std.fs.File) !IoOptions {
            const original = try std.os.tcgetattr(file.handle);

            var settings = original;

            settings.iflag = os.IGNBRK; // Ignore BREAK condition on input.
            settings.oflag = 0; // no magic enabled
            settings.cflag |= 0; // unchanged
            settings.lflag = 0; // no magic enabled

            // make read() nonblocking:
            settings.cc[VMIN] = 1;
            settings.cc[VTIME] = 0;

            try std.os.tcsetattr(file.handle, .NOW, settings);

            _ = try std.os.fcntl(file.handle, std.os.F.SETFL, try std.os.fcntl(file.handle, std.os.F.GETFL, 0) | std.os.O.NONBLOCK);

            return IoOptions{
                .termios = original,
            };
        }

        fn configureSerialNonBlocking(file: std.fs.File) !void {
            _ = try std.os.fcntl(file.handle, std.os.F.SETFL, try std.os.fcntl(file.handle, std.os.F.GETFL, 0) | std.os.O.NONBLOCK);
        }

        fn restore(options: IoOptions, file: std.fs.File) !void {
            try std.os.tcsetattr(file.handle, .NOW, options.termios);
        }
    },
};
