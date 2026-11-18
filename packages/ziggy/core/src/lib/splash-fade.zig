//
// The curve the native apps fade the splash colour over the menu bar with. It is the curve the frontend's splash overlay fades
// with (the template's frontend/src/lib/splash.ts), so the two fade together.
//

const std = @import("std");

//
// The fade's progress on the cubic-bezier(0.4, 0, 0.2, 1) curve, for a time progress from 0 to 1: 0 at the start, 1 at the end.
// Finds the curve's parameter for the progress with Newton's method, as fadeEasing in splash.ts does.
//
pub fn fadeEasing(progress: f64) f64 {
    var parameter = std.math.clamp(progress, 0.0, 1.0);
    var attempt: u32 = 0;
    while (attempt < 8) : (attempt += 1) {
        const difference = bezierCoordinate(parameter, 0.4, 0.2) - progress;
        if (@abs(difference) < 0.0001) {
            break;
        }
        const slope = bezierSlope(parameter, 0.4, 0.2);
        if (@abs(slope) < 0.0001) {
            break;
        }
        parameter = std.math.clamp(parameter - difference / slope, 0.0, 1.0);
    }
    return bezierCoordinate(parameter, 0.0, 1.0);
}

//
// One coordinate of a cubic bezier curve at the parameter t, for that coordinate's two control points.
//
fn bezierCoordinate(t: f64, first_control: f64, second_control: f64) f64 {
    const one_minus = 1.0 - t;
    return 3.0 * one_minus * one_minus * t * first_control + 3.0 * one_minus * t * t * second_control + t * t * t;
}

//
// The slope of that coordinate at the parameter t, which Newton's method follows to find the t for a progress.
//
fn bezierSlope(t: f64, first_control: f64, second_control: f64) f64 {
    const one_minus = 1.0 - t;
    return 3.0 * one_minus * one_minus * first_control + 6.0 * one_minus * t * (second_control - first_control) + 3.0 * t * t * (1.0 - second_control);
}
