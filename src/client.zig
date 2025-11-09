const std = @import("std");
const posix = std.posix;

// Socket address family
const AF_UNIX: u32 = 1;
const SOCK_STREAM: u32 = 1;

// Socket address structure for Unix domain sockets
const sockaddr_un = extern struct {
    sun_family: u16,
    sun_path: [108]u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: ntt <command> [args...]\n", .{});
        std.debug.print("Example: ntt hello\n", .{});
        return;
    }

    // Find the master process by looking for socket files
    const tmp_dir = try std.fs.openDirAbsolute("/tmp", .{ .iterate = true });
    var dir = tmp_dir;
    defer dir.close();

    var found_socket: ?[]u8 = null;
    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        if (entry.kind == .unix_domain_socket and std.mem.startsWith(u8, entry.name, "ntt-") and std.mem.endsWith(u8, entry.name, ".sock")) {
            found_socket = try allocator.dupe(u8, entry.name);
            break;
        }
    }

    if (found_socket == null) {
        std.debug.print("Error: No ntt master process found. Please start ntt first.\n", .{});
        return error.NoMasterProcess;
    }
    defer allocator.free(found_socket.?);

    // Create socket path
    var path_buf: [256]u8 = undefined;
    const socket_path = try std.fmt.bufPrintZ(&path_buf, "/tmp/{s}", .{found_socket.?});

    // Create socket and connect
    const sock_fd = try posix.socket(AF_UNIX, SOCK_STREAM, 0);
    defer posix.close(sock_fd);

    var addr = std.mem.zeroes(sockaddr_un);
    addr.sun_family = AF_UNIX;
    @memcpy(addr.sun_path[0..socket_path.len], socket_path);

    const addr_ptr: *const posix.sockaddr = @ptrCast(&addr);
    try posix.connect(sock_fd, addr_ptr, @sizeOf(sockaddr_un));

    // Build command string from arguments
    var cmd_buf: [1024]u8 = undefined;
    var cmd_len: usize = 0;

    for (args[1..]) |arg| {
        if (cmd_len > 0) {
            cmd_buf[cmd_len] = ' ';
            cmd_len += 1;
        }
        @memcpy(cmd_buf[cmd_len .. cmd_len + arg.len], arg);
        cmd_len += arg.len;
    }

    // Send command
    _ = try posix.write(sock_fd, cmd_buf[0..cmd_len]);

    std.debug.print("Command sent: {s}\n", .{cmd_buf[0..cmd_len]});
}
