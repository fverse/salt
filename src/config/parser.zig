const std = @import("std");
const types = @import("./types.zig");
const SubmoduleConfig = types.SubmoduleConfig;
const Submodule = types.Submodule;

/// Parser for salt.conf configuration
pub const Parser = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    const ParseError = error{
        InvalidSyntax,
        UnexpectedToken,
        MissingValue,
        UnterminatedString,
        UnterminatedBlock,
        OutOfMemory,
    };

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    pub fn parseFile(self: *Parser, file_path: []const u8) !SubmoduleConfig {
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return SubmoduleConfig.init(self.allocator);
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);
        return try self.parseContent(content);
    }

    /// Parse salt.conf content from a string
    pub fn parseContent(self: *Parser, content: []const u8) !SubmoduleConfig {
        var conf = SubmoduleConfig.init(self.allocator);
        errdefer conf.deinit();

        var lines = std.mem.tokenizeAny(u8, content, "\n");
        var current_submodule: ?Submodule = null;
        var in_branches_block = false;
        var branches_indent: usize = 0;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            // Check for comment
            if (std.mem.startsWith(u8, trimmed, "#")) continue;

            // Count leading spaces for indentation
            const indent = countLeadingSpaces(line);

            // Check if we're starting a new submodule
            if (std.mem.startsWith(u8, trimmed, "[submodule")) {
                // Save previous submodule if exists
                if (current_submodule) |sub| {
                    try conf.addSubmodule(sub);
                }

                // Parse submodule name
                const name = try self.extractSubmoduleName(trimmed);
                current_submodule = Submodule.init(self.allocator);
                current_submodule.?.name = try self.arena.allocator().dupe(u8, name);
                in_branches_block = false;
            }
            // Check if we're in a branches block
            else if (std.mem.indexOf(u8, trimmed, "branches =") != null and
                std.mem.indexOf(u8, trimmed, "{") != null)
            {
                in_branches_block = true;
                branches_indent = indent + 4;
            }
            // Check for end of branches block
            else if (in_branches_block and std.mem.indexOf(u8, trimmed, "}") != null) {
                in_branches_block = false;
            }
            // Parse branch mappings inside branches block
            else if (in_branches_block and current_submodule != null) {
                if (indent >= branches_indent) {
                    const mapping = try self.parseBranchMapping(trimmed);
                    const env_key = try self.arena.allocator().dupe(u8, mapping.env);
                    const branch_value = try self.arena.allocator().dupe(u8, mapping.branch);
                    try current_submodule.?.branches.put(env_key, branch_value);
                }
            } else if (current_submodule != null) {
                const kv = try self.parseKeyValue(trimmed);
                const value = try self.arena.allocator().dupe(u8, kv.value);

                if (std.mem.eql(u8, kv.key, "path")) {
                    current_submodule.?.path = value;
                } else if (std.mem.eql(u8, kv.key, "url")) {
                    current_submodule.?.url = value;
                } else if (std.mem.eql(u8, kv.key, "default_branch")) {
                    current_submodule.?.default_branch = value;
                }
            }
        }

        // Add the last submodule if exists
        if (current_submodule) |sub| {
            try conf.addSubmodule(sub);
        }

        return conf;
    }

    /// Extract submodule name from [submodule "name"] line
    fn extractSubmoduleName(self: *Parser, line: []const u8) ![]const u8 {
        _ = self;

        // Find the opening quote
        const start_quote = std.mem.indexOf(u8, line, "\"") orelse {
            const colon_idx = std.mem.indexOf(u8, line, ":") orelse return ParseError.InvalidSyntax;
            const bracket_idx = std.mem.indexOf(u8, line, "]") orelse return ParseError.InvalidSyntax;
            const name = std.mem.trim(u8, line[colon_idx + 1 .. bracket_idx], " \t");
            return name;
        };

        // Find the closing quote
        const end_quote = std.mem.lastIndexOf(u8, line, "\"") orelse return ParseError.UnterminatedString;
        if (start_quote >= end_quote) return ParseError.InvalidSyntax;

        return line[start_quote + 1 .. end_quote];
    }

    /// Parse a key = value line
    fn parseKeyValue(self: *Parser, line: []const u8) !struct { key: []const u8, value: []const u8 } {
        _ = self;

        const equals_idx = std.mem.indexOf(u8, line, "=") orelse return ParseError.InvalidSyntax;
        const key = std.mem.trim(u8, line[0..equals_idx], " \t");
        var value = std.mem.trim(u8, line[equals_idx + 1 ..], " \t");

        value = stripQuotes(value);

        return .{ .key = key, .value = value };
    }

    /// Parse branch mapping (e.g., "main -> main" or "dev -> dev")
    fn parseBranchMapping(self: *Parser, line: []const u8) !struct { env: []const u8, branch: []const u8 } {
        _ = self;

        const arrow_idx = std.mem.indexOf(u8, line, "->") orelse return ParseError.InvalidSyntax;
        const env = std.mem.trim(u8, line[0..arrow_idx], " \t");
        var branch = std.mem.trim(u8, line[arrow_idx + 2 ..], " \t");

        // Remove quotes if present
        branch = stripQuotes(branch);

        return .{ .env = env, .branch = branch };
    }

    /// Count leading spaces in a line
    fn countLeadingSpaces(line: []const u8) usize {
        var count: usize = 0;
        for (line) |char| {
            if (char == ' ' or char == '\t') {
                count += 1;
            } else {
                break;
            }
        }
        return count;
    }

    /// Remove quotes from a string if present
    fn stripQuotes(s: []const u8) []const u8 {
        var result = s;

        // Strip leading/trailing spaces first
        result = std.mem.trim(u8, result, " \t");

        if (result.len >= 2) {
            if ((result[0] == '"' and result[result.len - 1] == '"') or
                (result[0] == '\'' and result[result.len - 1] == '\''))
            {
                result = result[1 .. result.len - 1];
            }
        }

        return result;
    }
};
