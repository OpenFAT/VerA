//! Generated inputs through every pass. As an executable (`vera-generators
//! <scratch dir>`, `zig build test-generators`, in `test`) it runs each
//! generator's table, one child process per row so a crash names its row;
//! its `test` blocks hold the generators' own tests.
//!   `wide`     N-wide sources (statement chains, case arms, sum terms,
//!              else-if chains, and N-deep nesting to compare) on a 1 MiB stack
//!   `escaped`  seeded escaped identifiers through every name-resolving path
//!   `files`    an include tree past the 65535-file table (E0154)
//!   `table`    the driver both share: rows, children, the `known` algebra
//!
//! Each namespace is its own file, `generators/<namespace>.zig`, named as
//! the namespace so its tests keep their names; this file declares only
//! the namespaces, `main` and the test below.
//!
//! Contents:
//! - `pub fn main(init: std.process.Init) !u8`

const table = @import("generators/table.zig");
const wide = @import("generators/wide.zig");
const escaped = @import("generators/escaped.zig");
const files = @import("generators/files.zig");

/// `vera-generators DIR`: every table's rows, each in its own child.
/// `vera-generators DIR <generator> A B`: one row, here.
pub fn main(init: @import("std").process.Init) !u8 {
    return table.main(init);
}

test {
    _ = table;
    _ = wide;
    _ = escaped;
    _ = files;
}
