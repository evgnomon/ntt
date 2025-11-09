# NTT Transparent Terminal
> Terminal is not an emulation anymore, everything else is!

```
███╗   ██╗████████╗████████╗
████╗  ██║╚══██╔══╝╚══██╔══╝
██╔██╗ ██║   ██║      ██║
██║╚██╗██║   ██║      ██║
██║ ╚████║   ██║      ██║
╚═╝  ╚═══╝   ╚═╝      ╚═╝
```

> A blazingly fast, modern terminal switcher built with Zig - Trash tmux and put your terminal full-screen on top of everything else!

[![GitHub release](https://img.shields.io/github/release/evgnomon/ntt.svg)](

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen.svg)]()
[![License](https://img.shields.io/badge/license-MIT-blue.svg)]()
[![Zig Version](https://img.shields.io/badge/zig-0.13.0-orange.svg)](https://ziglang.org/)

## Why NTT?

NTT is not tmux. Tmux is bloat, it's time for a fresh approach. **NTT** (NTT Transparent Terminal or NTT is not tmux) reimagines what a terminal multiplexer can be:

- **🚀 Performance First** - Written in Zig for maximum speed and minimal resource usage
- **🎨 Modern UX** - There shouldn't be any sign og multiplexer in your way
- **🔄 Drop-in Compatible** - No-keybindings, just commands.
- **🪶 Zero Dependencies** - Single binary, no runtime dependencies
- **🔍 Transparent** - Crystal clear session management and debugging without any sign of multiplexer

## Installation

### From Source

```bash
# Clone the repository
git clone https://github.com/evgnomon/ntt.git
cd ntt

# Build with Zig
zig build -Doptimize=ReleaseFast

# Install to your PATH
sudo cp zig-out/bin/ntt /usr/local/bin/
```

### Binary Releases

Download the latest release for your platform from the [releases page](https://github.com/evgnomon/ntt/releases).

## Quick Start

```bash
# Start a new session
ntt
```

## Key Bindings
No keybindings by design.

### Building

```bash
# Debug build
zig build

# Run tests
zig build test

# Run the binary
zig build run
```

## Roadmap

- [X] Project initialization
- [X] Core terminal emulation
- [ ] Proper handling of close event

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the HGL License

## Acknowledgments

- Built with [Zig](https://ziglang.org/) - a modern systems programming language
- Thanks to all contributors and early adopters

---

**Made with ⚡ and Zig** | [Documentation](https://github.com/evgnomon/ntt/wiki) | [Report Bug](https://github.com/evgnomon/ntt/issues) | [Request Feature](https://github.com/evgnomon/ntt/issues)
