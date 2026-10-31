//! An `f64` base (or a vector of bases) and an `f64` exponent in, x^y out:
//! ARM optimized-routines pow (musl src/math/pow.c, pow_data.c; Copyright
//! (c) 2018, Arm Limited, MIT), its fma-free variant (`arm_exp.zig` says
//! why), with `arm_exp.zig`'s reduction for the final exp.
//! Cites: C99 F.10.4.4 (pow's special cases).
//!
//! Contract, held by `gm.zig`'s tests: error <= 0.54 ulp for finite
//! non-special x, y; the special cases of C99 F.10.4.4 (pow(x, +-0) = 1,
//! pow(1, y) = 1, pow(-x, odd int) = -pow(x, y), pow(-x, non-int) = NaN, the
//! zero and infinity rows); exact wherever x^y is exact and fits. It replaces
//! `std.math.pow` (repeated squaring for the integer part of y, then
//! exp(yf*log x), whose error grows with |y|), and is not bit-identical to it.
//!
//! Contents:
//! - `pub fn armPow(x: f64, y: f64) f64`
//! - `pub fn powV(x: anytype, y: f64) @TypeOf(x)`

const std = @import("std");
const assert = std.debug.assert;
const arm_exp = @import("arm_exp.zig");
const bits = @import("bits.zig");
const UOf = bits.UOf;
const sp = bits.sp;
const asF = bits.asF;
const asU = bits.asU;
const top12 = bits.top12;

const pow_ln2hi = 0x1.62e42fefa3800p-1;
const pow_ln2lo = 0x1.ef35793c76730p-45;
const pow_a = [7]f64{
    -0x1p-1,
    0x1.555555555556p-2 * -2.0,
    -0x1.0000000000006p-2 * -2.0,
    0x1.999999959554ep-3 * 4.0,
    -0x1.555555529a47ap-3 * 4.0,
    0x1.2495b9b4845e9p-3 * -8.0,
    -0x1.0002b8b263fc3p-3 * -8.0,
};
const pow_off: u64 = 0x3fe6955500000000;
/// What `checkInt` says of a double's bits.
const Parity = enum { not_integer, odd, even };

/// ARM pow_data.c `tab`, as three columns: { invc, logc, logctail } per
/// 1/128 subinterval of [0x3fe69555, 0x3ff69555).
const pow_log_invc = column(0);
const pow_log_logc = column(1);
const pow_log_logctail = column(2);
const pow_log_tab = [128][3]f64{
    .{ 0x1.6a00000000000p+0, -0x1.62c82f2b9c800p-2, 0x1.ab42428375680p-48 },
    .{ 0x1.6800000000000p+0, -0x1.5d1bdbf580800p-2, -0x1.ca508d8e0f720p-46 },
    .{ 0x1.6600000000000p+0, -0x1.5767717455800p-2, -0x1.362a4d5b6506dp-45 },
    .{ 0x1.6400000000000p+0, -0x1.51aad872df800p-2, -0x1.684e49eb067d5p-49 },
    .{ 0x1.6200000000000p+0, -0x1.4be5f95777800p-2, -0x1.41b6993293ee0p-47 },
    .{ 0x1.6000000000000p+0, -0x1.4618bc21c6000p-2, 0x1.3d82f484c84ccp-46 },
    .{ 0x1.5e00000000000p+0, -0x1.404308686a800p-2, 0x1.c42f3ed820b3ap-50 },
    .{ 0x1.5c00000000000p+0, -0x1.3a64c55694800p-2, 0x1.0b1c686519460p-45 },
    .{ 0x1.5a00000000000p+0, -0x1.347dd9a988000p-2, 0x1.5594dd4c58092p-45 },
    .{ 0x1.5800000000000p+0, -0x1.2e8e2bae12000p-2, 0x1.67b1e99b72bd8p-45 },
    .{ 0x1.5600000000000p+0, -0x1.2895a13de8800p-2, 0x1.5ca14b6cfb03fp-46 },
    .{ 0x1.5600000000000p+0, -0x1.2895a13de8800p-2, 0x1.5ca14b6cfb03fp-46 },
    .{ 0x1.5400000000000p+0, -0x1.22941fbcf7800p-2, -0x1.65a242853da76p-46 },
    .{ 0x1.5200000000000p+0, -0x1.1c898c1699800p-2, -0x1.fafbc68e75404p-46 },
    .{ 0x1.5000000000000p+0, -0x1.1675cababa800p-2, 0x1.f1fc63382a8f0p-46 },
    .{ 0x1.4e00000000000p+0, -0x1.1058bf9ae4800p-2, -0x1.6a8c4fd055a66p-45 },
    .{ 0x1.4c00000000000p+0, -0x1.0a324e2739000p-2, -0x1.c6bee7ef4030ep-47 },
    .{ 0x1.4a00000000000p+0, -0x1.0402594b4d000p-2, -0x1.036b89ef42d7fp-48 },
    .{ 0x1.4a00000000000p+0, -0x1.0402594b4d000p-2, -0x1.036b89ef42d7fp-48 },
    .{ 0x1.4800000000000p+0, -0x1.fb9186d5e4000p-3, 0x1.d572aab993c87p-47 },
    .{ 0x1.4600000000000p+0, -0x1.ef0adcbdc6000p-3, 0x1.b26b79c86af24p-45 },
    .{ 0x1.4400000000000p+0, -0x1.e27076e2af000p-3, -0x1.72f4f543fff10p-46 },
    .{ 0x1.4200000000000p+0, -0x1.d5c216b4fc000p-3, 0x1.1ba91bbca681bp-45 },
    .{ 0x1.4000000000000p+0, -0x1.c8ff7c79aa000p-3, 0x1.7794f689f8434p-45 },
    .{ 0x1.4000000000000p+0, -0x1.c8ff7c79aa000p-3, 0x1.7794f689f8434p-45 },
    .{ 0x1.3e00000000000p+0, -0x1.bc286742d9000p-3, 0x1.94eb0318bb78fp-46 },
    .{ 0x1.3c00000000000p+0, -0x1.af3c94e80c000p-3, 0x1.a4e633fcd9066p-52 },
    .{ 0x1.3a00000000000p+0, -0x1.a23bc1fe2b000p-3, -0x1.58c64dc46c1eap-45 },
    .{ 0x1.3a00000000000p+0, -0x1.a23bc1fe2b000p-3, -0x1.58c64dc46c1eap-45 },
    .{ 0x1.3800000000000p+0, -0x1.9525a9cf45000p-3, -0x1.ad1d904c1d4e3p-45 },
    .{ 0x1.3600000000000p+0, -0x1.87fa06520d000p-3, 0x1.bbdbf7fdbfa09p-45 },
    .{ 0x1.3400000000000p+0, -0x1.7ab890210e000p-3, 0x1.bdb9072534a58p-45 },
    .{ 0x1.3400000000000p+0, -0x1.7ab890210e000p-3, 0x1.bdb9072534a58p-45 },
    .{ 0x1.3200000000000p+0, -0x1.6d60fe719d000p-3, -0x1.0e46aa3b2e266p-46 },
    .{ 0x1.3000000000000p+0, -0x1.5ff3070a79000p-3, -0x1.e9e439f105039p-46 },
    .{ 0x1.3000000000000p+0, -0x1.5ff3070a79000p-3, -0x1.e9e439f105039p-46 },
    .{ 0x1.2e00000000000p+0, -0x1.526e5e3a1b000p-3, -0x1.0de8b90075b8fp-45 },
    .{ 0x1.2c00000000000p+0, -0x1.44d2b6ccb8000p-3, 0x1.70cc16135783cp-46 },
    .{ 0x1.2c00000000000p+0, -0x1.44d2b6ccb8000p-3, 0x1.70cc16135783cp-46 },
    .{ 0x1.2a00000000000p+0, -0x1.371fc201e9000p-3, 0x1.178864d27543ap-48 },
    .{ 0x1.2800000000000p+0, -0x1.29552f81ff000p-3, -0x1.48d301771c408p-45 },
    .{ 0x1.2600000000000p+0, -0x1.1b72ad52f6000p-3, -0x1.e80a41811a396p-45 },
    .{ 0x1.2600000000000p+0, -0x1.1b72ad52f6000p-3, -0x1.e80a41811a396p-45 },
    .{ 0x1.2400000000000p+0, -0x1.0d77e7cd09000p-3, 0x1.a699688e85bf4p-47 },
    .{ 0x1.2400000000000p+0, -0x1.0d77e7cd09000p-3, 0x1.a699688e85bf4p-47 },
    .{ 0x1.2200000000000p+0, -0x1.fec9131dbe000p-4, -0x1.575545ca333f2p-45 },
    .{ 0x1.2000000000000p+0, -0x1.e27076e2b0000p-4, 0x1.a342c2af0003cp-45 },
    .{ 0x1.2000000000000p+0, -0x1.e27076e2b0000p-4, 0x1.a342c2af0003cp-45 },
    .{ 0x1.1e00000000000p+0, -0x1.c5e548f5bc000p-4, -0x1.d0c57585fbe06p-46 },
    .{ 0x1.1c00000000000p+0, -0x1.a926d3a4ae000p-4, 0x1.53935e85baac8p-45 },
    .{ 0x1.1c00000000000p+0, -0x1.a926d3a4ae000p-4, 0x1.53935e85baac8p-45 },
    .{ 0x1.1a00000000000p+0, -0x1.8c345d631a000p-4, 0x1.37c294d2f5668p-46 },
    .{ 0x1.1a00000000000p+0, -0x1.8c345d631a000p-4, 0x1.37c294d2f5668p-46 },
    .{ 0x1.1800000000000p+0, -0x1.6f0d28ae56000p-4, -0x1.69737c93373dap-45 },
    .{ 0x1.1600000000000p+0, -0x1.51b073f062000p-4, 0x1.f025b61c65e57p-46 },
    .{ 0x1.1600000000000p+0, -0x1.51b073f062000p-4, 0x1.f025b61c65e57p-46 },
    .{ 0x1.1400000000000p+0, -0x1.341d7961be000p-4, 0x1.c5edaccf913dfp-45 },
    .{ 0x1.1400000000000p+0, -0x1.341d7961be000p-4, 0x1.c5edaccf913dfp-45 },
    .{ 0x1.1200000000000p+0, -0x1.16536eea38000p-4, 0x1.47c5e768fa309p-46 },
    .{ 0x1.1000000000000p+0, -0x1.f0a30c0118000p-5, 0x1.d599e83368e91p-45 },
    .{ 0x1.1000000000000p+0, -0x1.f0a30c0118000p-5, 0x1.d599e83368e91p-45 },
    .{ 0x1.0e00000000000p+0, -0x1.b42dd71198000p-5, 0x1.c827ae5d6704cp-46 },
    .{ 0x1.0e00000000000p+0, -0x1.b42dd71198000p-5, 0x1.c827ae5d6704cp-46 },
    .{ 0x1.0c00000000000p+0, -0x1.77458f632c000p-5, -0x1.cfc4634f2a1eep-45 },
    .{ 0x1.0c00000000000p+0, -0x1.77458f632c000p-5, -0x1.cfc4634f2a1eep-45 },
    .{ 0x1.0a00000000000p+0, -0x1.39e87b9fec000p-5, 0x1.502b7f526feaap-48 },
    .{ 0x1.0a00000000000p+0, -0x1.39e87b9fec000p-5, 0x1.502b7f526feaap-48 },
    .{ 0x1.0800000000000p+0, -0x1.f829b0e780000p-6, -0x1.980267c7e09e4p-45 },
    .{ 0x1.0800000000000p+0, -0x1.f829b0e780000p-6, -0x1.980267c7e09e4p-45 },
    .{ 0x1.0600000000000p+0, -0x1.7b91b07d58000p-6, -0x1.88d5493faa639p-45 },
    .{ 0x1.0400000000000p+0, -0x1.fc0a8b0fc0000p-7, -0x1.f1e7cf6d3a69cp-50 },
    .{ 0x1.0400000000000p+0, -0x1.fc0a8b0fc0000p-7, -0x1.f1e7cf6d3a69cp-50 },
    .{ 0x1.0200000000000p+0, -0x1.fe02a6b100000p-8, -0x1.9e23f0dda40e4p-46 },
    .{ 0x1.0200000000000p+0, -0x1.fe02a6b100000p-8, -0x1.9e23f0dda40e4p-46 },
    .{ 0x1.0000000000000p+0, 0x0.0000000000000p+0, 0x0.0000000000000p+0 },
    .{ 0x1.0000000000000p+0, 0x0.0000000000000p+0, 0x0.0000000000000p+0 },
    .{ 0x1.fc00000000000p-1, 0x1.0101575890000p-7, -0x1.0c76b999d2be8p-46 },
    .{ 0x1.f800000000000p-1, 0x1.0205658938000p-6, -0x1.3dc5b06e2f7d2p-45 },
    .{ 0x1.f400000000000p-1, 0x1.8492528c90000p-6, -0x1.aa0ba325a0c34p-45 },
    .{ 0x1.f000000000000p-1, 0x1.0415d89e74000p-5, 0x1.111c05cf1d753p-47 },
    .{ 0x1.ec00000000000p-1, 0x1.466aed42e0000p-5, -0x1.c167375bdfd28p-45 },
    .{ 0x1.e800000000000p-1, 0x1.894aa149fc000p-5, -0x1.97995d05a267dp-46 },
    .{ 0x1.e400000000000p-1, 0x1.ccb73cdddc000p-5, -0x1.a68f247d82807p-46 },
    .{ 0x1.e200000000000p-1, 0x1.eea31c006c000p-5, -0x1.e113e4fc93b7bp-47 },
    .{ 0x1.de00000000000p-1, 0x1.1973bd1466000p-4, -0x1.5325d560d9e9bp-45 },
    .{ 0x1.da00000000000p-1, 0x1.3bdf5a7d1e000p-4, 0x1.cc85ea5db4ed7p-45 },
    .{ 0x1.d600000000000p-1, 0x1.5e95a4d97a000p-4, -0x1.c69063c5d1d1ep-45 },
    .{ 0x1.d400000000000p-1, 0x1.700d30aeac000p-4, 0x1.c1e8da99ded32p-49 },
    .{ 0x1.d000000000000p-1, 0x1.9335e5d594000p-4, 0x1.3115c3abd47dap-45 },
    .{ 0x1.cc00000000000p-1, 0x1.b6ac88dad6000p-4, -0x1.390802bf768e5p-46 },
    .{ 0x1.ca00000000000p-1, 0x1.c885801bc4000p-4, 0x1.646d1c65aacd3p-45 },
    .{ 0x1.c600000000000p-1, 0x1.ec739830a2000p-4, -0x1.dc068afe645e0p-45 },
    .{ 0x1.c400000000000p-1, 0x1.fe89139dbe000p-4, -0x1.534d64fa10afdp-45 },
    .{ 0x1.c000000000000p-1, 0x1.1178e8227e000p-3, 0x1.1ef78ce2d07f2p-45 },
    .{ 0x1.be00000000000p-1, 0x1.1aa2b7e23f000p-3, 0x1.ca78e44389934p-45 },
    .{ 0x1.ba00000000000p-1, 0x1.2d1610c868000p-3, 0x1.39d6ccb81b4a1p-47 },
    .{ 0x1.b800000000000p-1, 0x1.365fcb0159000p-3, 0x1.62fa8234b7289p-51 },
    .{ 0x1.b400000000000p-1, 0x1.4913d8333b000p-3, 0x1.5837954fdb678p-45 },
    .{ 0x1.b200000000000p-1, 0x1.527e5e4a1b000p-3, 0x1.633e8e5697dc7p-45 },
    .{ 0x1.ae00000000000p-1, 0x1.6574ebe8c1000p-3, 0x1.9cf8b2c3c2e78p-46 },
    .{ 0x1.ac00000000000p-1, 0x1.6f0128b757000p-3, -0x1.5118de59c21e1p-45 },
    .{ 0x1.aa00000000000p-1, 0x1.7898d85445000p-3, -0x1.c661070914305p-46 },
    .{ 0x1.a600000000000p-1, 0x1.8beafeb390000p-3, -0x1.73d54aae92cd1p-47 },
    .{ 0x1.a400000000000p-1, 0x1.95a5adcf70000p-3, 0x1.7f22858a0ff6fp-47 },
    .{ 0x1.a000000000000p-1, 0x1.a93ed3c8ae000p-3, -0x1.8724350562169p-45 },
    .{ 0x1.9e00000000000p-1, 0x1.b31d8575bd000p-3, -0x1.c358d4eace1aap-47 },
    .{ 0x1.9c00000000000p-1, 0x1.bd087383be000p-3, -0x1.d4bc4595412b6p-45 },
    .{ 0x1.9a00000000000p-1, 0x1.c6ffbc6f01000p-3, -0x1.1ec72c5962bd2p-48 },
    .{ 0x1.9600000000000p-1, 0x1.db13db0d49000p-3, -0x1.aff2af715b035p-45 },
    .{ 0x1.9400000000000p-1, 0x1.e530effe71000p-3, 0x1.212276041f430p-51 },
    .{ 0x1.9200000000000p-1, 0x1.ef5ade4dd0000p-3, -0x1.a211565bb8e11p-51 },
    .{ 0x1.9000000000000p-1, 0x1.f991c6cb3b000p-3, 0x1.bcbecca0cdf30p-46 },
    .{ 0x1.8c00000000000p-1, 0x1.07138604d5800p-2, 0x1.89cdb16ed4e91p-48 },
    .{ 0x1.8a00000000000p-1, 0x1.0c42d67616000p-2, 0x1.7188b163ceae9p-45 },
    .{ 0x1.8800000000000p-1, 0x1.1178e8227e800p-2, -0x1.c210e63a5f01cp-45 },
    .{ 0x1.8600000000000p-1, 0x1.16b5ccbacf800p-2, 0x1.b9acdf7a51681p-45 },
    .{ 0x1.8400000000000p-1, 0x1.1bf99635a6800p-2, 0x1.ca6ed5147bdb7p-45 },
    .{ 0x1.8200000000000p-1, 0x1.214456d0eb800p-2, 0x1.a87deba46baeap-47 },
    .{ 0x1.7e00000000000p-1, 0x1.2bef07cdc9000p-2, 0x1.a9cfa4a5004f4p-45 },
    .{ 0x1.7c00000000000p-1, 0x1.314f1e1d36000p-2, -0x1.8e27ad3213cb8p-45 },
    .{ 0x1.7a00000000000p-1, 0x1.36b6776be1000p-2, 0x1.16ecdb0f177c8p-46 },
    .{ 0x1.7800000000000p-1, 0x1.3c25277333000p-2, 0x1.83b54b606bd5cp-46 },
    .{ 0x1.7600000000000p-1, 0x1.419b423d5e800p-2, 0x1.8e436ec90e09dp-47 },
    .{ 0x1.7400000000000p-1, 0x1.4718dc271c800p-2, -0x1.f27ce0967d675p-45 },
    .{ 0x1.7200000000000p-1, 0x1.4c9e09e173000p-2, -0x1.e20891b0ad8a4p-45 },
    .{ 0x1.7000000000000p-1, 0x1.522ae0738a000p-2, 0x1.ebe708164c759p-45 },
    .{ 0x1.6e00000000000p-1, 0x1.57bf753c8d000p-2, 0x1.fadedee5d40efp-46 },
    .{ 0x1.6c00000000000p-1, 0x1.5d5bddf596000p-2, -0x1.a0b2a08a465dcp-47 },
};

comptime {
    // `powLogG` indexes the table by 7 bits of the mantissa.
    assert(pow_log_tab.len == 128);
    assert(pow_log_invc.len == pow_log_tab.len);
}

/// x^y, the contract in this file's header.
pub fn armPow(x: f64, y: f64) f64 {
    var sbias: u64 = 0;
    var ix = asU(x);
    const iy = asU(y);
    var topx = top12(x);
    const topy = top12(y);
    if (topx -% 0x001 >= 0x7ff - 0x001 or (topy & 0x7ff) -% 0x3be >= 0x43e - 0x3be) {
        @branchHint(.unlikely);
        if (zeroInfNan(iy)) {
            if (2 *% iy == 0) return 1.0;
            if (ix == asU(1.0)) return 1.0;
            if (2 *% ix > 2 *% asU(std.math.inf(f64)) or 2 *% iy > 2 *% asU(std.math.inf(f64))) return x + y;
            if (2 *% ix == 2 *% asU(1.0)) return 1.0;
            if ((2 *% ix < 2 *% asU(1.0)) == (iy >> 63 == 0)) return 0.0;
            return y * y;
        }
        if (zeroInfNan(ix)) {
            var x2 = x * x;
            if (ix >> 63 != 0 and checkInt(iy) == .odd) x2 = -x2;
            return if (iy >> 63 != 0) 1.0 / x2 else x2;
        }
        // x and y are non-zero finite.
        if (ix >> 63 != 0) {
            switch (checkInt(iy)) {
                .not_integer => return std.math.nan(f64),
                .odd => sbias = arm_exp.sign_bias,
                .even => {},
            }
            ix &= 0x7fffffffffffffff;
            topx &= 0x7ff;
        }
        if ((topy & 0x7ff) -% 0x3be >= 0x43e - 0x3be) {
            if (ix == asU(1.0)) return 1.0;
            if ((topy & 0x7ff) < 0x3be) return if (ix > asU(1.0)) 1.0 + y else 1.0 - y;
            const inf = std.math.inf(f64);
            return if ((ix > asU(1.0)) == (topy < 0x800)) inf else 0.0;
        }
        if (topx == 0) {
            // Subnormal x: normalize so the exponent goes negative.
            ix = asU(x * 0x1p52) & 0x7fffffffffffffff;
            ix -%= 52 << 52;
        }
    }
    // y is now non-zero, finite and of ordinary size; a subnormal base's
    // bits carry a negative exponent, so `ix` is asserted nothing.
    assert(!zeroInfNan(iy));
    assert((topy & 0x7ff) -% 0x3be < 0x43e - 0x3be);
    const l = powLogG(f64, ix);
    const hi = l.y;
    const lo = l.tail;
    // y * (hi + lo) as ehi + elo without fma (`exact_everywhere`).
    const yhi = asF(iy & (~@as(u64, 0) << 27));
    const ylo = y - yhi;
    const lhi = asF(asU(hi) & (~@as(u64, 0) << 27));
    const llo = hi - lhi + lo;
    const ehi = yhi * lhi;
    const elo = ylo * lhi + y * llo;
    return arm_exp.expCore(ehi, elo, sbias);
}

/// x^y for `f64` or `@Vector(n, f64)` bases and one exponent; the
/// contract is `armPow`'s. A vector whose bases are all positive, normal
/// and finite, with an ordinary y and an ordinary exp argument in every
/// lane, runs `armPow`'s arithmetic on the whole vector; any other takes
/// `armPow` lane by lane. Either way a lane is the scalar call's bits.
pub fn powV(x: anytype, y: f64) @TypeOf(x) {
    const T = @TypeOf(x);
    switch (@typeInfo(T)) {
        .vector => |v| {
            const U = UOf(T);
            const ix: U = @bitCast(x);
            const iy = asU(y);
            const topy = top12(y) & 0x7ff;
            const normal = bits.shrU(ix, 52) -% sp(U, 0x001) < sp(U, 0x7fe);
            if (@reduce(.And, normal) and topy -% 0x3be < 0x43e - 0x3be) {
                const l = powLogG(T, ix);
                // `armPow`'s fma-free y * (hi + lo).
                const yhi = asF(iy & (~@as(u64, 0) << 27));
                const ylo = y - yhi;
                const lhi: T = @bitCast(@as(U, @bitCast(l.y)) & sp(U, ~@as(u64, 0) << 27));
                const llo = l.y - lhi + l.tail;
                const ehi = sp(T, yhi) * lhi;
                const elo = sp(T, ylo) * lhi + sp(T, y) * llo;
                const abstop = bits.shrU(@as(U, @bitCast(ehi)), 52) & sp(U, 0x7ff);
                if (@reduce(.And, abstop -% sp(U, top12(0x1p-54)) < sp(U, top12(512.0) - top12(0x1p-54)))) {
                    const m = arm_exp.expMain(T, ehi, elo, 0);
                    const scale: T = @bitCast(m.sbits);
                    return scale + scale * m.tmp;
                }
            }
            // SAFETY: the loop writes every lane.
            var out: T = undefined;
            inline for (0..v.len) |k| out[k] = armPow(x[k], y);
            return out;
        },
        else => return armPow(x, y),
    }
}

// ---- private ----

fn column(comptime c: usize) [128]f64 {
    // SAFETY: the loop writes all 128 entries.
    var out: [128]f64 = undefined;
    for (&out, pow_log_tab) |*o, row| o.* = row[c];
    return out;
}

/// Whether `i` is the bits of a zero, an infinity or a NaN.
inline fn zeroInfNan(i: u64) bool {
    return 2 *% i -% 1 >= 2 *% asU(std.math.inf(f64)) -% 1;
}

/// Whether the non-zero finite double with bits `iy` is an integer, and if
/// so its parity. Asserts that `iy` is such a double.
inline fn checkInt(iy: u64) Parity {
    assert(!zeroInfNan(iy));
    const e: u32 = @intCast(iy >> 52 & 0x7ff);
    if (e < 0x3ff) return .not_integer;
    if (e > 0x3ff + 52) return .even;
    const sh: u6 = @intCast(0x3ff + 52 - e);
    if (iy & ((@as(u64, 1) << sh) - 1) != 0) return .not_integer;
    if (iy & (@as(u64, 1) << sh) != 0) return .odd;
    return .even;
}

/// `log_inline`: log(x) = y + tail for x's (normalized) bits.
inline fn powLogG(comptime T: type, ix: UOf(T)) struct { y: T, tail: T } {
    const U = UOf(T);
    const I = bits.IOf(T);
    const tmp = ix -% sp(U, pow_off);
    const i = bits.shrU(tmp, 52 - 7) % sp(U, 128);
    const k = @as(I, @bitCast(tmp)) >> switch (@typeInfo(T)) {
        .vector => |v| @as(@Vector(v.len, u6), @splat(52)),
        else => @as(u6, 52),
    };
    const iz = ix -% (tmp & sp(U, @as(u64, 0xfff) << 52));
    const z: T = @bitCast(iz);
    const kd: T = @floatFromInt(k);
    const invc = bits.gather(f64, &pow_log_invc, i);
    const logc = bits.gather(f64, &pow_log_logc, i);
    const logctail = bits.gather(f64, &pow_log_logctail, i);
    // No fma (`exact_everywhere`): split z so rhi, rlo and rhi*rhi are
    // exact and |rlo| <= |r|.
    const zhi: T = @bitCast((iz +% sp(U, 1 << 31)) & sp(U, ~@as(u64, 0) << 32));
    const zlo = z - zhi;
    const rhi = zhi * invc - sp(T, 1.0);
    const rlo = zlo * invc;
    const r = rhi + rlo;
    const t1 = kd * sp(T, pow_ln2hi) + logc;
    const t2 = t1 + r;
    const lo1 = kd * sp(T, pow_ln2lo) + logctail;
    const lo2 = t1 - t2 + r;
    const ar = sp(T, pow_a[0]) * r;
    const ar2 = r * ar;
    const ar3 = r * ar2;
    const arhi = sp(T, pow_a[0]) * rhi;
    const arhi2 = rhi * arhi;
    const hi = t2 + arhi2;
    const lo3 = rlo * (ar + arhi);
    const lo4 = t2 - hi + arhi2;
    const p = ar3 * (sp(T, pow_a[1]) + r * sp(T, pow_a[2]) + ar2 * (sp(T, pow_a[3]) + r * sp(T, pow_a[4]) + ar2 * (sp(T, pow_a[5]) + r * sp(T, pow_a[6]))));
    const lo = lo1 + lo2 + lo3 + lo4 + p;
    const y = hi + lo;
    return .{ .y = y, .tail = hi - y + lo };
}
