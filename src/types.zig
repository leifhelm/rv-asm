pub const Reg = u5;
pub const regs = struct {
    pub const zero = 0;
    pub const ra = 1;
    pub const sp = 2;
    pub const gp = 3;
    pub const tp = 4;
    pub const t0 = 5;
    pub const t1 = 6;
    pub const t2 = 7;
    pub const fp = 8;
    pub const s0 = 8;
    pub const s1 = 9;
    pub const a0 = 10;
    pub const a1 = 11;
    pub const a2 = 12;
    pub const a3 = 13;
    pub const a4 = 14;
    pub const a5 = 15;
    pub const a6 = 16;
    pub const a7 = 17;
    pub const s2 = 18;
    pub const s3 = 19;
    pub const s4 = 20;
    pub const s5 = 21;
    pub const s6 = 22;
    pub const s7 = 23;
    pub const s8 = 24;
    pub const s9 = 25;
    pub const s10 = 26;
    pub const s11 = 27;
    pub const t3 = 28;
    pub const t4 = 29;
    pub const t5 = 30;
    pub const t6 = 31;
};

pub fn getArgumentRegister(arg_index: usize) ?Reg {
    if (arg_index < 8) {
        return 10 + @intCast(u5, arg_index);
    }
    return null;
}
