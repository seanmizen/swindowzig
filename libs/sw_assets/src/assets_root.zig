//! sw_assets - asynchronous byte loading (`loadBytes`) and PNG decoding.
//! Import it as `const assets = @import("sw_assets");`.

pub const assets = @import("assets.zig");
pub const png = @import("png.zig");

pub const loadBytes = assets.loadBytes;
pub const Request = assets.Request;
pub const Result = assets.Result;
pub const LoadError = assets.LoadError;
pub const errorMessage = assets.errorMessage;
pub const useDirectory = assets.useDirectory;
pub const useDirectoryPath = assets.useDirectoryPath;

pub const Image = png.Image;
pub const decodePng = png.decodePng;
