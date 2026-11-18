//
// Tests of the curve the native apps fade the splash colour over the menu bar with, which must match the frontend's overlay fade.
//

const std = @import("std");
const ziggy = @import("ziggy");

const splash_fade = ziggy.splash_fade;

test "the fade eases from zero to one on the cubic-bezier(0.4, 0, 0.2, 1) curve, as the frontend's overlay does" {
    try std.testing.expectEqual(@as(f64, 0.0), splash_fade.fadeEasing(0.0));
    // The frontend's splash test expects 0.778 at the half way point.
    try std.testing.expectApproxEqAbs(@as(f64, 0.778), splash_fade.fadeEasing(0.5), 0.005);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), splash_fade.fadeEasing(1.0), 0.0001);
}

test "the fade holds at its ends for a progress outside zero to one" {
    try std.testing.expectEqual(@as(f64, 0.0), splash_fade.fadeEasing(-0.5));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), splash_fade.fadeEasing(1.5), 0.0001);
}
