pub const GitError = @import("git/operations.zig").GitError;
pub const cloneRepository = @import("git/operations.zig").cloneRepository;
pub const checkout = @import("git/operations.zig").checkout;
pub const pull = @import("git/operations.zig").pull;
pub const push = @import("git/operations.zig").push;
pub const getCurrentBranch = @import("git/operations.zig").getCurrentBranch;
pub const getCurrentCommit = @import("git/operations.zig").getCurrentCommit;
pub const executeGitCommand = @import("git/operations.zig").executeGitCommand;
