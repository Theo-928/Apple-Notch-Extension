import AppKit

/// Puts windows on a WindowServer "space" that sits above the lock screen.
///
/// This is the same technique other notch apps use for lock-screen widgets. It
/// needs **no** privacy permission, but it is a private SkyLight API, so it is
/// loaded dynamically: if Apple removes it, `shared` is nil and the feature
/// simply turns itself off instead of crashing.
@MainActor
final class LockScreenSpace {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SetLevelFn = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsFn = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    static let shared: LockScreenSpace? = LockScreenSpace()

    private let connection: Int32
    private let space: Int32
    private let addWindows: AddWindowsFn

    private init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY) else {
            return nil
        }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let mainConnection = sym("SLSMainConnectionID", MainConnectionFn.self),
              let spaceCreate = sym("SLSSpaceCreate", SpaceCreateFn.self),
              let setLevel = sym("SLSSpaceSetAbsoluteLevel", SetLevelFn.self),
              let showSpaces = sym("SLSShowSpaces", ShowSpacesFn.self),
              let addWindows = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindowsFn.self)
        else { return nil }

        connection = mainConnection()
        space = spaceCreate(connection, 1, 0)
        guard space != 0 else { return nil }
        // 400 is above the lock screen (loginwindow's shield).
        _ = setLevel(connection, space, 400)
        _ = showSpaces(connection, [space] as CFArray)
        self.addWindows = addWindows
    }

    /// Moves `window` onto the above-lock-screen space.
    func adopt(_ window: NSWindow) {
        guard window.windowNumber > 0 else { return }
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }
}
