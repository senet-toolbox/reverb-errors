//! Error reports from vapor apps, kept in the app's own Postgres.
//!
//! The app's reverb backend migrates the tables, then installs the route
//! its vapor frontend posts crashes to:
//!
//! ```zig
//! try reverb_errors.migrate(pool);
//! try reverb_errors.install(&server, pool, .{ .allowed_origin = "https://app.example" }, gpa, io);
//! defer reverb_errors.deinit();
//! ```
//!
//! A dashboard such as ryven reads them back with `read`.
pub const Report = @import("Report.zig");
pub const schema = @import("schema.zig");
pub const migrate = schema.migrate;
pub const fingerprint = @import("fingerprint.zig").compute;
pub const record = @import("record.zig").record;
pub const Recorded = @import("record.zig").Recorded;
pub const read = @import("read.zig");

const route = @import("route.zig");
pub const Options = route.Options;
pub const install = route.install;
pub const deinit = route.deinit;
