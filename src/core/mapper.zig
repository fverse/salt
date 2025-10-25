const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../config/types.zig");
const Submodule = types.Submodule;

/// Get the mapped branch for a submodule based on the parent branch.
/// This function implements the following priority:
/// 1. Exact match in branch_mappings
/// 2. Pattern match with wildcard support (e.g., feature/* -> develop)
/// 3. Fall back to submodule.default_branch
///
/// Returns the target branch name (owned by the submodule's branch_mappings or default_branch)
pub fn getBranchMapping(
    submodule: *const Submodule,
    parent_branch: []const u8,
) []const u8 {
    // 1. Try exact match first
    if (submodule.branch_mappings.get(parent_branch)) |mapped| {
        return mapped;
    }

    // 2. Try pattern matching with wildcards
    var iter = submodule.branch_mappings.iterator();
    while (iter.next()) |entry| {
        const pattern = entry.key_ptr.*;
        const target = entry.value_ptr.*;

        if (matchesPattern(pattern, parent_branch)) {
            // If target has wildcard, expand it; otherwise use as-is
            if (std.mem.indexOf(u8, target, "*")) |_| {
                // Need to expand the pattern
                if (expandPattern(submodule.allocator, target, pattern, parent_branch)) |expanded| {
                    return expanded;
                } else {
                    // If expansion fails, use target as-is
                    return target;
                }
            } else {
                // Target doesn't have wildcard, use directly
                return target;
            }
        }
    }

    // 3. Fall back to default branch
    return submodule.default_branch;
}

/// Check if a branch name matches a pattern.
/// Supports wildcard patterns like "feature/*" or "release/*"
///
/// Examples:
/// - matchesPattern("main", "main") -> true
/// - matchesPattern("feature/*", "feature/auth") -> true
/// - matchesPattern("release/*", "release/v1.0") -> true
/// - matchesPattern("feature/*", "hotfix/bug") -> false
pub fn matchesPattern(pattern: []const u8, branch: []const u8) bool {
    // Find wildcard position
    const wildcard_pos = std.mem.indexOf(u8, pattern, "*") orelse {
        // No wildcard, must be exact match
        return std.mem.eql(u8, pattern, branch);
    };

    // Split pattern into prefix and suffix around the wildcard
    const prefix = pattern[0..wildcard_pos];
    const suffix = pattern[wildcard_pos + 1 ..];

    // Check if branch starts with prefix
    if (!std.mem.startsWith(u8, branch, prefix)) {
        return false;
    }

    // Check if branch ends with suffix (if suffix exists)
    if (suffix.len > 0 and !std.mem.endsWith(u8, branch, suffix)) {
        return false;
    }

    return true;
}

/// Expand a pattern by replacing wildcards with captured text from the branch.
/// Returns an allocated string that must be freed by the caller, or null if expansion fails.
///
/// Examples:
/// - expandPattern("release/*", "release/v1.0") with target "release/*" -> "release/v1.0"
/// - expandPattern("feature/*", "feature/auth") with target "develop" -> "develop"
///
/// Note: The returned string is allocated and must be freed by the caller.
/// However, in the current implementation, we return the target directly if it doesn't
/// contain a wildcard, so the caller should NOT free in that case.
/// This is handled by getBranchMapping which checks for wildcards before calling this.
pub fn expandPattern(
    allocator: Allocator,
    target: []const u8,
    pattern: []const u8,
    branch: []const u8,
) ?[]const u8 {
    // Find wildcard positions
    const pattern_wildcard = std.mem.indexOf(u8, pattern, "*") orelse return null;
    const target_wildcard = std.mem.indexOf(u8, target, "*") orelse {
        // Target has no wildcard, return as-is (no allocation needed)
        return target;
    };

    // Extract prefix and suffix from pattern
    const pattern_prefix = pattern[0..pattern_wildcard];
    const pattern_suffix = pattern[pattern_wildcard + 1 ..];

    // Calculate the captured portion from the branch
    const capture_start = pattern_prefix.len;
    const capture_end = branch.len - pattern_suffix.len;

    // Validate capture bounds
    if (capture_start > capture_end or capture_end > branch.len) {
        return null;
    }

    const captured = branch[capture_start..capture_end];

    // Extract prefix and suffix from target
    const target_prefix = target[0..target_wildcard];
    const target_suffix = target[target_wildcard + 1 ..];

    // Construct the expanded branch name
    const expanded = std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}",
        .{ target_prefix, captured, target_suffix },
    ) catch return null;

    return expanded;
}

test "matchesPattern - exact match" {
    try std.testing.expect(matchesPattern("main", "main"));
    try std.testing.expect(matchesPattern("staging", "staging"));
    try std.testing.expect(matchesPattern("develop", "develop"));

    // Non-matches
    try std.testing.expect(!matchesPattern("main", "staging"));
    try std.testing.expect(!matchesPattern("develop", "main"));
}

test "matchesPattern - wildcard prefix" {
    try std.testing.expect(matchesPattern("feature/*", "feature/auth"));
    try std.testing.expect(matchesPattern("feature/*", "feature/payment"));
    try std.testing.expect(matchesPattern("release/*", "release/v1.0"));
    try std.testing.expect(matchesPattern("release/*", "release/v2.0.1"));

    // Non-matches
    try std.testing.expect(!matchesPattern("feature/*", "hotfix/bug"));
    try std.testing.expect(!matchesPattern("release/*", "feature/release"));
}

test "matchesPattern - wildcard with suffix" {
    try std.testing.expect(matchesPattern("release/*-stable", "release/v1.0-stable"));
    try std.testing.expect(matchesPattern("feature/*-wip", "feature/auth-wip"));

    // Non-matches
    try std.testing.expect(!matchesPattern("release/*-stable", "release/v1.0"));
    try std.testing.expect(!matchesPattern("feature/*-wip", "feature/auth"));
}

test "matchesPattern - empty pattern" {
    try std.testing.expect(matchesPattern("", ""));
    try std.testing.expect(!matchesPattern("", "main"));
    try std.testing.expect(!matchesPattern("main", ""));
}

test "expandPattern - simple wildcard replacement" {
    const allocator = std.testing.allocator;

    // Pattern: release/* -> release/*
    const result1 = expandPattern(allocator, "release/*", "release/*", "release/v1.0");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqualStrings("release/v1.0", result1.?);
    allocator.free(result1.?);

    // Pattern: feature/* -> feature/*
    const result2 = expandPattern(allocator, "feature/*", "feature/*", "feature/auth");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqualStrings("feature/auth", result2.?);
    allocator.free(result2.?);
}

test "expandPattern - different target without wildcard" {
    const allocator = std.testing.allocator;

    // Pattern: feature/* -> develop (no wildcard in target)
    const result = expandPattern(allocator, "develop", "feature/*", "feature/auth");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("develop", result.?);
    // No free needed - returns target directly
}

test "expandPattern - different target with wildcard" {
    const allocator = std.testing.allocator;

    // Pattern: feature/* -> dev/*
    const result = expandPattern(allocator, "dev/*", "feature/*", "feature/auth");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("dev/auth", result.?);
    allocator.free(result.?);
}

test "expandPattern - complex patterns" {
    const allocator = std.testing.allocator;

    // Pattern: release/*-beta -> prod/*
    const result1 = expandPattern(allocator, "prod/*", "release/*-beta", "release/v1.0-beta");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqualStrings("prod/v1.0", result1.?);
    allocator.free(result1.?);
}

test "expandPattern - no wildcard in pattern" {
    const allocator = std.testing.allocator;

    // No wildcard in pattern - should return null
    const result = expandPattern(allocator, "develop", "main", "main");
    try std.testing.expect(result == null);
}

test "getBranchMapping - exact match" {
    const allocator = std.testing.allocator;
    var submodule = Submodule.init(allocator);
    defer submodule.deinit();

    submodule.default_branch = "main";
    try submodule.addBranchMapping("staging", "staging");
    try submodule.addBranchMapping("develop", "dev");

    // Exact matches
    try std.testing.expectEqualStrings("staging", getBranchMapping(&submodule, "staging"));
    try std.testing.expectEqualStrings("dev", getBranchMapping(&submodule, "develop"));
}

test "getBranchMapping - wildcard pattern to same" {
    const allocator = std.testing.allocator;
    var submodule = Submodule.init(allocator);
    defer submodule.deinit();

    submodule.default_branch = "main";
    try submodule.addBranchMapping("release/*", "release/*");

    const result = getBranchMapping(&submodule, "release/v1.0");
    try std.testing.expectEqualStrings("release/v1.0", result);
    // Free the allocated result
    allocator.free(result);
}

test "getBranchMapping - wildcard pattern to different target" {
    const allocator = std.testing.allocator;
    var submodule = Submodule.init(allocator);
    defer submodule.deinit();

    submodule.default_branch = "main";
    try submodule.addBranchMapping("feature/*", "develop");

    // Should map to develop (no wildcard in target)
    try std.testing.expectEqualStrings("develop", getBranchMapping(&submodule, "feature/auth"));
    try std.testing.expectEqualStrings("develop", getBranchMapping(&submodule, "feature/payment"));
}

test "getBranchMapping - default fallback" {
    const allocator = std.testing.allocator;
    var submodule = Submodule.init(allocator);
    defer submodule.deinit();

    submodule.default_branch = "main";
    try submodule.addBranchMapping("staging", "staging");

    // No mapping for "hotfix/bug", should fall back to default
    try std.testing.expectEqualStrings("main", getBranchMapping(&submodule, "hotfix/bug"));
    try std.testing.expectEqualStrings("main", getBranchMapping(&submodule, "unknown"));
}

test "getBranchMapping - priority order" {
    const allocator = std.testing.allocator;
    var submodule = Submodule.init(allocator);
    defer submodule.deinit();

    submodule.default_branch = "main";
    try submodule.addBranchMapping("feature/special", "special-branch");
    try submodule.addBranchMapping("feature/*", "develop");

    // Exact match should take priority over pattern
    try std.testing.expectEqualStrings("special-branch", getBranchMapping(&submodule, "feature/special"));

    // Other feature branches should match the pattern
    try std.testing.expectEqualStrings("develop", getBranchMapping(&submodule, "feature/auth"));
}

test "getBranchMapping - empty branch name" {
    const allocator = std.testing.allocator;
    var submodule = Submodule.init(allocator);
    defer submodule.deinit();

    submodule.default_branch = "main";

    // Empty branch should fall back to default
    try std.testing.expectEqualStrings("main", getBranchMapping(&submodule, ""));
}

test "getBranchMapping - multiple wildcards in different patterns" {
    const allocator = std.testing.allocator;
    var submodule = Submodule.init(allocator);
    defer submodule.deinit();

    submodule.default_branch = "main";
    try submodule.addBranchMapping("feature/*", "develop");
    try submodule.addBranchMapping("release/*", "release/*");
    try submodule.addBranchMapping("hotfix/*", "main");

    // Test each pattern
    try std.testing.expectEqualStrings("develop", getBranchMapping(&submodule, "feature/auth"));

    const release_result = getBranchMapping(&submodule, "release/v1.0");
    try std.testing.expectEqualStrings("release/v1.0", release_result);
    allocator.free(release_result);

    try std.testing.expectEqualStrings("main", getBranchMapping(&submodule, "hotfix/critical"));
}
