* vera --emit-osdi of a Verilog module (mixed.v, OSDI device vmix) and of a
* Verilog-A one (mixed.va, vload r = 10k on each of its outputs), both loaded
* by ngspice pre_osdi in one deck.
*
* Hand derivation. The bridges are the contract device's defaults
* (src/sim/rt/device.zig): vdd = 5, vss = 0, vth = 2.5, rout = 1, trise =
* tfall = 1n. An output at 1 is 5 V through 1 ohm into 10k:
* 5 * 10k / 10001 = 4.9995000499950005 V; at 0 it is 0 V exactly.
*   OP     a = 0 V: y = 1; q and c start 0. a = 5 V: y = 0, which takes a
*          second iterate (the device was born with a = x, y = x), the
*          static re-iterate the library reports to ngspice as LIM.
*   TRAN   ck toggles every 5n from 0, so c counts on its rising edges at
*          5n, 15n, 25n: c = 1 at 10n, 2 at 20n, 3 at 30n. OSDI has no
*          breakpoint slot; the library bounds the step to the device's next
*          event (bound_step), so a point lands on 5n and c[0]'s ramp runs
*          5n..6n: v(c0) = 2.5 V when the level is 2.5 * 10001 / 10k =
*          2.50025 V, at 5n + 2.50025 / 5 ns = 5.50005 ns (the ramp is
*          linear, and both its ends are points, so meas's interpolation is
*          exact). No source corner is at 5n or 6n, so only the device's
*          bound puts a point there. `meas` keeps 7 digits, so its rows are
*          checked to 1e-6.
*          clk = PULSE(0 5 2n 1n 1n 4n 10n) crosses 2.5 V rising at 2.5n and
*          12.5n: q is 1 from the first, 0 from the second. Each ramp is
*          over by 10n and 20n. (When q's ramp starts is not checked: OSDI
*          cannot reject the step that crossed, so it starts at the first
*          point ngspice accepts after the crossing, wherever that falls.)
*
*! expect y0 4.9995000499950005 1e-12
*! expect q0 0 0
*! expect c00 0 0
*! expect y5 0 0
*! expect tc0 5.50005e-9 1e-6
*! expect q10 4.9995000499950005 1e-6
*! expect q20 0 0
*! expect cz10 4.9995000499950005 1e-6
*! expect co20 4.9995000499950005 1e-6
*! expect cz20 0 0
*! expect cz30 4.9995000499950005 1e-6
*! expect co30 4.9995000499950005 1e-6
.control
pre_osdi {osdi_v}
pre_osdi {osdi}
.endc
.model dig vmix
.model ld vload r=10k
N1 a clk y q c1 c0 dig
Ny y 0 ld
Nq q 0 ld
Nc1 c1 0 ld
Nc0 c0 0 ld
Va a 0 dc 0
Vclk clk 0 dc 0 pulse(0 5 2n 1n 1n 4n 10n)
.options reltol=1e-9 vntol=1e-12 abstol=1e-18
.control
set numdgt=15
op
let y0 = v(y)
let q0 = v(q)
let c00 = v(c0)
print y0 q0 c00
alter Va dc = 5
op
let y5 = v(y)
print y5
alter Va dc = 0
tran 1n 32n
meas tran tc0 when v(c0)=2.5 rise=1
meas tran q10 find v(q) at=10n
meas tran q20 find v(q) at=20n
meas tran cz10 find v(c0) at=10n
meas tran co20 find v(c1) at=20n
meas tran cz20 find v(c0) at=20n
meas tran cz30 find v(c0) at=30n
meas tran co30 find v(c1) at=30n
print tc0 q10 q20 cz10 co20 cz20 cz30 co30
.endc
.end
