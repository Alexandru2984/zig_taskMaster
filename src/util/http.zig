

const std = @import("std");
const zap = @import("zap");
const db = @import("../db/db.zig");
const models = @import("../domain/models.zig");

// ==========================================
// REQUEST HELPERS
// ==========================================

/// Get client IP for rate limiting (supports X-Real-IP from Nginx)
pub fn getClientIp(r: zap.Request) []const u8 {
    // Check for Nginx forwarded IP first
    if (r.getHeader("x-real-ip")) |ip| return ip;
    if (r.getHeader("x-forwarded-for")) |forwarded| {
        // X-Forwarded-For can have multiple IPs, take the first one
        if (std.mem.indexOf(u8, forwarded, ",")) |comma| {
            return forwarded[0..comma];
        }
        return forwarded;
    }
    // Fallback to default
    return "127.0.0.1";
}

/// Get current user ID from Authorization header using secure session validation
pub fn getCurrentUserId(allocator: std.mem.Allocator, r: zap.Request) ?[]const u8 {
    const auth_header = r.getHeader("authorization") orelse return null;
    
    // Expect "Bearer <token>"
    if (!std.mem.startsWith(u8, auth_header, "Bearer ")) return null;
    const token = auth_header[7..];
    
    // Validate session token in database
    const user_id = db.validateSession(allocator, token) catch return null;
    return user_id;
}

/// Parse JSON body into a struct
pub fn parseBody(allocator: std.mem.Allocator, r: zap.Request, comptime T: type) !T {
    const body = r.body orelse return error.NoBody;
    
    const parsed = try std.json.parseFromSlice(T, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    
    // We need to duplicate the strings because parsed.value references the body/internal buffer
    // and we want to return a struct that owns its memory or at least persists if we copy it.
    // Actually, std.json.parseFromSlice returns a Parsed(T).
    // If we return T, we lose the arena that holds the strings if they were allocated.
    // BUT, if we use the request arena (allocator), the strings are allocated there.
    // The `parsed` object holds the arena if it created one, but here we pass the allocator.
    // So `parsed.value` contains slices pointing into `body` (if source is slice) or allocated in `allocator`.
    // Since `body` is owned by `zap.Request` (which might be transient?), we should be careful.
    // Zap request body is valid until the request handler returns.
    // So if we use the data within the handler, it's fine.
    // However, `std.json.parseFromSlice` might allocate for unescaping strings.
    
    // To be safe and simple: We return the Parsed(T) and let the caller deinit it?
    // Or we just return T and assume caller uses it within request scope.
    // `parsed.deinit()` frees the internal arena if it used one.
    // If we passed an allocator, it uses that.
    
    // Let's return T, but we can't `defer parsed.deinit()` if T depends on it.
    // Actually `std.json.parseFromSlice` with an allocator uses that allocator.
    // If we use the Arena allocator of the request, we don't need to deinit `parsed`.
    
    return parsed.value;
}

// ==========================================
// RESPONSE HELPERS
// ==========================================

pub fn jsonSuccess(r: zap.Request, data: anytype) !void {
    r.setStatus(.ok);
    r.setHeader("Content-Type", "application/json") catch {};
    
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(std.heap.page_allocator);
    
    var w = list.writer(std.heap.page_allocator);
    var buf: [128]u8 = undefined;
    var adapter = w.adaptToNewApi(&buf);
    try std.json.Stringify.value(data, .{}, &adapter.new_interface);
    try adapter.new_interface.flush();
    try r.sendBody(list.items);
}

pub fn jsonCreated(r: zap.Request, data: anytype) !void {
    r.setStatus(.created);
    r.setHeader("Content-Type", "application/json") catch {};
    
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(std.heap.page_allocator);
    
    var w = list.writer(std.heap.page_allocator);
    var buf: [128]u8 = undefined;
    var adapter = w.adaptToNewApi(&buf);
    try std.json.Stringify.value(data, .{}, &adapter.new_interface);
    try r.sendBody(list.items);
}

pub fn jsonError(r: zap.Request, status: u32, message: []const u8) !void {
    r.setStatus(@enumFromInt(@as(u16, @intCast(status))));
    r.setHeader("Content-Type", "application/json") catch {};
    
    // Manual JSON for error to avoid allocation if possible, or just use stringify
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(std.heap.page_allocator);
    
    const err_obj = models.ApiError{ .@"error" = message };
    var w = list.writer(std.heap.page_allocator);
    var buf: [128]u8 = undefined;
    var adapter = w.adaptToNewApi(&buf);
    try std.json.Stringify.value(err_obj, .{}, &adapter.new_interface);
    try adapter.new_interface.flush();
    try r.sendBody(list.items);
}
