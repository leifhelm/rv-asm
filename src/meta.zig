pub fn isSingleItemPtr(comptime T: type) bool {
    const ptr_info = @typeInfo(T);
    if (ptr_info != .Pointer) return false;
    return ptr_info.Pointer.size == .One;
}
pub fn singelItemPtrType(comptime T: type) type {
    if (!isSingleItemPtr(T)) {
        @compileError("expected single item pointer, found " ++ @typeInfo(T));
    }
    return @typeInfo(T).Pointer.child;
}
