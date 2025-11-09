const std = @import("std");
const ntt = @import("ntt");
const posix = std.posix;
const c = std.c;

const linux = std.os.linux;

// Extern C functions
extern "c" fn openpty(
    master: *c_int,
    slave: *c_int,
    name: ?[*]u8,
    termp: ?*const posix.termios,
    winsize: ?*const anyopaque,
) c_int;

// Terminal control constants for Linux
const IGNBRK: u32 = 0o000001;
const BRKINT: u32 = 0o000002;
const PARMRK: u32 = 0o000010;
const ISTRIP: u32 = 0o000040;
const INLCR: u32 = 0o000100;
const IGNCR: u32 = 0o000200;
const ICRNL: u32 = 0o000400;
const IXON: u32 = 0o002000;
const OPOST: u32 = 0o000001;
const ECHO: u32 = 0o000010;
const ECHONL: u32 = 0o000100;
const ICANON: u32 = 0o000002;
const ISIG: u32 = 0o000001;
const IEXTEN: u32 = 0o100000;
const CSIZE: u32 = 0o000060;
const PARENB: u32 = 0o000400;
const CS8: u32 = 0o000060;
const VMIN: usize = 6;
const VTIME: usize = 5;
const TIOCSCTTY: u32 = 0x540E;
const TIOCGWINSZ: u32 = 0x5413;
const TIOCSWINSZ: u32 = 0x5414;

// Socket address family
const AF_UNIX: u32 = 1;
const SOCK_STREAM: u32 = 1;

// Socket address structure for Unix domain sockets
const sockaddr_un = extern struct {
    sun_family: u16,
    sun_path: [108]u8,
};

// Window size structure
const winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

// Terminal session structure
const TerminalSession = struct {
    master_fd: c_int,
    child_pid: posix.pid_t,
};

// Global variables for signal handler
var global_master_fd: c_int = -1;
var global_stdin_fd: c_int = -1;

// Global variables for terminal management
var terminals: std.ArrayList(TerminalSession) = undefined;
var current_terminal_index: usize = 0;
var global_allocator: std.mem.Allocator = undefined;

// Signal handler for window resize
fn handleSigwinch(_: c_int) callconv(.c) void {
    if (global_master_fd < 0 or global_stdin_fd < 0) return;

    var ws: winsize = undefined;
    if (linux.ioctl(global_stdin_fd, TIOCGWINSZ, @intFromPtr(&ws)) == 0) {
        _ = linux.ioctl(global_master_fd, TIOCSWINSZ, @intFromPtr(&ws));
    }
}

// Create a new PTY terminal session
fn createTerminalSession(ws: *const winsize) !TerminalSession {
    var master_fd: c_int = undefined;
    var slave_fd: c_int = undefined;
    _ = openpty(&master_fd, &slave_fd, null, null, @ptrCast(ws));

    const pid = try posix.fork();
    if (pid == 0) {
        // Child: Set up slave PTY as stdin/stdout/stderr and exec bash
        posix.close(master_fd); // Child doesn't need master
        _ = try posix.dup2(slave_fd, posix.STDIN_FILENO);
        _ = try posix.dup2(slave_fd, posix.STDOUT_FILENO);
        _ = try posix.dup2(slave_fd, posix.STDERR_FILENO);
        posix.close(slave_fd); // No longer needed

        // Set controlling terminal
        _ = try posix.setsid();
        _ = linux.ioctl(slave_fd, TIOCSCTTY, @as(c_int, 0));

        // Exec bash
        const argv = [_:null]?[*:0]const u8{ "bash", null };
        _ = posix.execveZ("/bin/bash", &argv, std.c.environ) catch {};
        std.posix.exit(1);
    }

    // Parent: Close slave, return session
    posix.close(slave_fd);

    return TerminalSession{
        .master_fd = master_fd,
        .child_pid = pid,
    };
}

// Create Unix socket for receiving commands
fn createCommandSocket(pid: posix.pid_t) !c_int {
    const sock_fd = try posix.socket(AF_UNIX, SOCK_STREAM, 0);
    errdefer posix.close(sock_fd);

    var addr = std.mem.zeroes(sockaddr_un);
    addr.sun_family = AF_UNIX;

    // Create socket path: /tmp/ntt-<pid>.sock
    var path_buf: [108]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/ntt-{d}.sock", .{pid});
    @memcpy(addr.sun_path[0..path.len], path);

    // Remove old socket file if it exists
    std.posix.unlink(path) catch {};

    // Bind the socket
    const addr_ptr: *const posix.sockaddr = @ptrCast(&addr);
    try posix.bind(sock_fd, addr_ptr, @sizeOf(sockaddr_un));

    // Listen for connections
    try posix.listen(sock_fd, 5);

    // std.debug.print("Command socket created at: {s}\n", .{path});

    return sock_fd;
}

// Handle command received from client
fn handleCommand(cmd: []const u8, ws: *const winsize) !void {
    // Parse command (format: "command args...")
    var iter = std.mem.splitScalar(u8, cmd, ' ');
    const command = iter.first();

    if (std.mem.eql(u8, command, "hello")) {
        // Create /tmp/commands file and write "hi"
        const file = try std.fs.openFileAbsolute("/tmp/commands", .{ .mode = .write_only });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll("received hello\n");
    } else if (std.mem.eql(u8, command, "new")) {
        // Create a new terminal session
        const new_session = try createTerminalSession(ws);
        try terminals.append(global_allocator, new_session);

        // Log to /tmp/commands
        const file = try std.fs.openFileAbsolute("/tmp/commands", .{ .mode = .write_only });
        defer file.close();
        try file.seekFromEnd(0);
        const msg = try std.fmt.allocPrint(global_allocator, "new terminal created (total: {d})\n", .{terminals.items.len});
        defer global_allocator.free(msg);
        try file.writeAll(msg);
    } else if (std.mem.eql(u8, command, "next")) {
        // Switch to next terminal in round-robin fashion
        if (terminals.items.len > 0) {
            current_terminal_index = (current_terminal_index + 1) % terminals.items.len;
            global_master_fd = terminals.items[current_terminal_index].master_fd;

            // Log to /tmp/commands
            const file = try std.fs.openFileAbsolute("/tmp/commands", .{ .mode = .write_only });
            defer file.close();
            try file.seekFromEnd(0);
            const msg = try std.fmt.allocPrint(global_allocator, "switched to terminal {d} of {d}\n", .{current_terminal_index + 1, terminals.items.len});
            defer global_allocator.free(msg);
            try file.writeAll(msg);
        }
    }
}

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    global_allocator = allocator;

    // Initialize terminals array
    terminals = .{};
    defer {
        // Clean up all terminals
        for (terminals.items) |terminal| {
            posix.close(terminal.master_fd);
            _ = posix.waitpid(terminal.child_pid, 0);
        }
        terminals.deinit(allocator);
    }

    // Step 1: Save original terminal attributes and enter raw mode
    const stdin_fd = posix.STDIN_FILENO;
    const stdout_fd = posix.STDOUT_FILENO;

    const orig_termios = try posix.tcgetattr(stdin_fd);
    defer posix.tcsetattr(stdin_fd, .FLUSH, orig_termios) catch {}; // Restore on exit

    var raw_termios = orig_termios;

    // Work with raw integer values for the flags
    var iflag_raw = @as(u32, @bitCast(raw_termios.iflag));
    iflag_raw &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
    raw_termios.iflag = @bitCast(iflag_raw);

    var oflag_raw = @as(u32, @bitCast(raw_termios.oflag));
    oflag_raw &= ~OPOST;
    raw_termios.oflag = @bitCast(oflag_raw);

    var lflag_raw = @as(u32, @bitCast(raw_termios.lflag));
    lflag_raw &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
    raw_termios.lflag = @bitCast(lflag_raw);

    var cflag_raw = @as(u32, @bitCast(raw_termios.cflag));
    cflag_raw &= ~(CSIZE | PARENB);
    cflag_raw |= CS8;
    raw_termios.cflag = @bitCast(cflag_raw);

    raw_termios.cc[VMIN] = 1; // Read at least 1 byte
    raw_termios.cc[VTIME] = 0; // No timeout
    try posix.tcsetattr(stdin_fd, .FLUSH, raw_termios);

    // Step 2: Get current terminal window size
    var ws: winsize = undefined;
    if (linux.ioctl(stdin_fd, TIOCGWINSZ, @intFromPtr(&ws)) != 0) {
        // If we can't get size, use reasonable defaults
        ws.ws_row = 24;
        ws.ws_col = 80;
        ws.ws_xpixel = 0;
        ws.ws_ypixel = 0;
    }

    // Step 3: Create first terminal session
    const first_session = try createTerminalSession(&ws);
    try terminals.append(allocator, first_session);
    current_terminal_index = 0;

    const pid = first_session.child_pid;

    // Create command socket for IPC
    const sock_fd = try createCommandSocket(pid);
    defer posix.close(sock_fd);

    // Step 5: Set up SIGWINCH handler to update PTY size on terminal resize
    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSigwinch },
        .mask = [_]c_ulong{0} ** 16,
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);

    // Store master_fd and stdin_fd in globals for signal handler
    global_master_fd = terminals.items[current_terminal_index].master_fd;
    global_stdin_fd = stdin_fd;

    // Step 6: I/O loop with polling to avoid blocking
    var buf: [1024]u8 = undefined;
    var pollfds = [_]posix.pollfd{
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = global_master_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = sock_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    var client_fd: c_int = -1; // Currently connected client

    while (true) {
        // Update pollfd with current terminal's master_fd
        pollfds[1].fd = terminals.items[current_terminal_index].master_fd;

        // Poll both stdin and PTY master
        _ = posix.poll(&pollfds, -1) catch break;

        // Check if stdin has data (user input)
        if (pollfds[0].revents & posix.POLL.IN != 0) {
            if (posix.read(stdin_fd, &buf)) |n| {
                if (n == 0) break; // EOF
                _ = posix.write(terminals.items[current_terminal_index].master_fd, buf[0..n]) catch break;
            } else |_| break;
        }

        // Check if PTY has data (bash output)
        if (pollfds[1].revents & posix.POLL.IN != 0) {
            if (posix.read(terminals.items[current_terminal_index].master_fd, &buf)) |n| {
                if (n == 0) break; // PTY closed
                _ = posix.write(stdout_fd, buf[0..n]) catch break;
            } else |_| break;
        }

        // Check if command socket has incoming connection
        if (pollfds[2].revents & posix.POLL.IN != 0) {
            // Accept new connection (only one at a time for simplicity)
            if (client_fd >= 0) {
                posix.close(client_fd);
            }
            client_fd = posix.accept(sock_fd, null, null, 0) catch -1;

            if (client_fd >= 0) {
                // Read command from client
                if (posix.read(client_fd, &buf)) |n| {
                    if (n > 0) {
                        // Trim any trailing newline/whitespace
                        var cmd_len = n;
                        while (cmd_len > 0 and (buf[cmd_len - 1] == '\n' or buf[cmd_len - 1] == '\r')) {
                            cmd_len -= 1;
                        }
                        handleCommand(buf[0..cmd_len], &ws) catch {};
                    }
                } else |_| {}

                posix.close(client_fd);
                client_fd = -1;
            }
        }

        // Check for hangup/error conditions
        if (pollfds[0].revents & posix.POLL.HUP != 0 or
            pollfds[1].revents & posix.POLL.HUP != 0)
        {
            break;
        }

        // Reset revents for next poll
        pollfds[0].revents = 0;
        pollfds[1].revents = 0;
        pollfds[2].revents = 0;
    }

    // Cleanup handled by defer
}
