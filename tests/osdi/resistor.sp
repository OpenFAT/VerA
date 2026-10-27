* vera --emit-osdi: resistor.va (r = 2k, c = 1n) loaded by ngspice pre_osdi,
* fed through a 1k SPICE resistor from V1.
*
* Hand derivation (R1 = 1k, R2 = 2k, C = 1n, Rp = R1 || R2 = 666.67 ohm):
*   OP     v(a) = R2 / (R1 + R2) = 2/3; i(V1) = -1 / 3k
*   AC     H = R2 / (R1 + R2 + j w R1 R2 C); at 1 MHz |H| = 0.1548047,
*          arg H = -1.3364502 rad
*   NOISE  output PSD at a = 4 k T Re(Rp / (1 + j w Rp C)) with both
*          resistors at T = 300.15 K, k = 1.380649e-23:
*          1 kHz 1.10505e-17, 1 MHz 5.95856e-19 V^2/Hz. The device's
*          k is not the deck's (VerA writes the literal; ngspice uses its
*          own CONSTboltz), so the tolerance is 1e-5.
*   TRAN   a 1 ps step: v(a) = 2/3 (1 - exp(-t / (Rp C))):
*          0.5 us 0.3517556, 1 us 0.5179132, 2 us 0.6334753; a 1 ns
*          step limit bounds the integration error well inside 1e-4.
*
*! expect va 0.6666666666666666 1e-12
*! expect iv1 -3.333333333333333e-4 1e-12
*! expect r 2000 1e-15
*! expect acmag 0.15480466432010442 1e-9
*! expect acph -1.3364502393065605 1e-9
*! expect n1k 1.1050520703968401e-17 1e-5
*! expect n1meg 5.958555168984794e-19 1e-5
*! expect t05 0.3517556315059901 1e-4
*! expect t1 0.5179132265677133 1e-4
*! expect t2 0.6334752877547574 1e-4
.control
pre_osdi {osdi}
.endc
.model rm vres r=2k c=1n
N1 a 0 rm
R1 in a 1k
V1 in 0 dc 1 ac 1 pwl(0 0 1p 1)
.control
set numdgt=15
op
let va = v(a)
let iv1 = v1#branch
let r = @n1[r]
print va iv1 r
ac lin 1 1meg 1meg
let acmag = vm(a)
let acph = vp(a)
print acmag acph
noise v(a) V1 lin 2 1k 1meg
setplot previous
let n1k = onoise_spectrum[0]^2
let n1meg = onoise_spectrum[1]^2
print n1k n1meg
tran 1n 2u 0 1n
meas tran t05 find v(a) at=0.5u
meas tran t1 find v(a) at=1u
meas tran t2 find v(a) at=2u
print t05 t1 t2
.endc
.end
