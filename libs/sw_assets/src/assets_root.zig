//! sw_assets - asynchronous byte loading (`loadBytes`), PNG decoding, zip
//! archives, files from the player and a data cache.
//! Import it as `const assets = @import("sw_assets");`.

pub const assets = @import("assets.zig");
pub const png = @import("png.zig");
/// Read the entries of a zip archive in memory (stored and deflate).
pub const zip = @import("zip.zig");
/// Files that the player drops or chooses (web), or paths (native).
pub const files = @import("files.zig");
/// Cache data in OPFS (web) or in a folder (native).
pub const cache = @import("cache.zig");

pub const loadBytes = assets.loadBytes;
pub const Request = assets.Request;
pub const Result = assets.Result;
pub const LoadError = assets.LoadError;
pub const errorMessage = assets.errorMessage;
pub const useDirectory = assets.useDirectory;
pub const useDirectoryPath = assets.useDirectoryPath;

pub const Image = png.Image;
pub const decodePng = png.decodePng;
