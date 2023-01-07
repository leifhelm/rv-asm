pub fn FixedArrayIter(comptime max_elements: comptime_int, comptime T: type) type {
    return struct {
        const Self = @This();

        array: [max_elements]T,
        current: usize = 0,
        max: usize,
        pub fn init(array: anytype) Self {
            if (array.len > max_elements) {
                @compileError("array.len > max_elements");
            }
            var iter = Self{
                .array = undefined,
                .max = array.len,
            };
            for (array) |element, i| {
                iter.array[i] = element;
            }
            return iter;
        }
        pub fn next(self: *Self) ?T {
            if (self.current < self.max) {
                const element = self.array[self.current];
                self.current += 1;
                return element;
            } else {
                return null;
            }
        }
    };
}
