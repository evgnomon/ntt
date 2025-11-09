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

// Window size structure
const winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

// Global variables for signal handler
var global_master_fd: c_int = -1;
var global_stdin_fd: c_int = -1;

// Signal handler for window resize
fn handleSigwinch(_: c_int) callconv(.c) void {
    if (global_master_fd < 0 or global_stdin_fd < 0) return;

    var ws: winsize = undefined;
    if (linux.ioctl(global_stdin_fd, TIOCGWINSZ, @intFromPtr(&ws)) == 0) {
        _ = linux.ioctl(global_master_fd, TIOCSWINSZ, @intFromPtr(&ws));
    }
}

pub fn main() !void {
    // Step 1: Save original terminal attributes and enter raw mode
    const stdin_fd = posix.STDIN_FILENO;
    const stdout_fd = posix.STDOUT_FILENO;
    const stderr_fd = posix.STDERR_FILENO;

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

    // Step 3: Create PTY with the window size
    var master_fd: c_int = undefined;
    var slave_fd: c_int = undefined;
    _ = openpty(&master_fd, &slave_fd, null, null, @ptrCast(&ws));

    // Step 4: Fork and exec bash in child
    const pid = try posix.fork();
    if (pid == 0) {
        // Child: Set up slave PTY as stdin/stdout/stderr and exec bash
        posix.close(master_fd); // Child doesn't need master
        _ = try posix.dup2(slave_fd, stdin_fd);
        _ = try posix.dup2(slave_fd, stdout_fd);
        _ = try posix.dup2(slave_fd, stderr_fd);
        posix.close(slave_fd); // No longer needed

        // Set controlling terminal
        _ = try posix.setsid();
        _ = linux.ioctl(slave_fd, TIOCSCTTY, @as(c_int, 0));

        // Exec bash
        const argv = [_:null]?[*:0]const u8{ "bash", null };
        _ = posix.execveZ("/bin/bash", &argv, std.c.environ) catch {};
        std.posix.exit(1);
    }

    // Parent: Close slave, handle I/O
    posix.close(slave_fd);

    // Step 5: Set up SIGWINCH handler to update PTY size on terminal resize
    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSigwinch },
        .mask = [_]c_ulong{0} ** 16,
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);

    // Store master_fd and stdin_fd in globals for signal handler
    global_master_fd = master_fd;
    global_stdin_fd = stdin_fd;

    // Step 6: I/O loop with polling to avoid blocking
    var buf: [1024]u8 = undefined;
    var pollfds = [_]posix.pollfd{
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = master_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        // Poll both stdin and PTY master
        _ = posix.poll(&pollfds, -1) catch break;

        // Check if stdin has data (user input)
        if (pollfds[0].revents & posix.POLL.IN != 0) {
            if (posix.read(stdin_fd, &buf)) |n| {
                if (n == 0) break; // EOF
                _ = posix.write(master_fd, buf[0..n]) catch break;
            } else |_| break;
        }

        // Check if PTY has data (bash output)
        if (pollfds[1].revents & posix.POLL.IN != 0) {
            if (posix.read(master_fd, &buf)) |n| {
                if (n == 0) break; // PTY closed
                _ = posix.write(stdout_fd, buf[0..n]) catch break;
            } else |_| break;
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
    }

    // Wait for child
    _ = posix.waitpid(pid, 0);
}
