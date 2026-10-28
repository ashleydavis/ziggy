//
// The result of something that can fail in an expected way: the value it made, or the error that stopped it. Failures are
// returned rather than thrown, so the compiler sees every case a caller has to handle.
//

//
// A success, carrying the value.
//
export interface IOk<T> {
    //
    // Always true, which is what tells a success from a failure.
    //
    ok: true;

    //
    // What the work made.
    //
    value: T;
}

//
// A failure, carrying the error.
//
export interface IErr<E> {
    //
    // Always false, which is what tells a failure from a success.
    //
    ok: false;

    //
    // Which error it was and its details.
    //
    error: E;
}

//
// Either a success with a value or a failure with an error.
//
export type Result<T, E> = IOk<T> | IErr<E>;

//
// Makes a success.
//
export function ok<T>(value: T): IOk<T> {
    return {
        ok: true,
        value,
    };
}

//
// Makes a failure.
//
export function err<E>(error: E): IErr<E> {
    return {
        ok: false,
        error,
    };
}
