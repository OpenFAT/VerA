* vera --emit-osdi: diode.va (is = 1e-14, n = 1, cj = 1p) loaded by ngspice
* pre_osdi.
*
* Hand derivation, vt = k T / q at T = 300.15 K (k = 1.380649e-23,
* q = 1.602176634e-19): vt = 25.864926 mV. 9.15 leaves k and q to the
* implementation and exp(v/vt) multiplies a constant's relative error by
* v/vt (about 23 here), so the DC tolerance is 1e-4.
*   DC     V(a) = 0.6 V straight across: id = is (exp(0.6 / vt) - 1)
*          = 1.1871869e-4 A; at 75 C (T = 348.15 K) 4.8476245e-6 A
*          (is has no temperature law here).
*   SERIES 1 V through 1k: solve (1 - vd) / 1k = is (exp(vd / vt) - 1)
*          by Newton: vd = 0.62944091 V, id = 0.37055909 mA. ngspice
*          reaches it from 0 V only through the device's pnjlim.
*   AC     gd = is exp(vd / vt) / vt, Yd = gd + j w cj, |vd / vin| =
*          |1 / (1 + 1k Yd)|: 1 kHz 0.065245608, 1 GHz 0.060369677
*          (arg -0.38905463 rad).
*   NOISE  shot 2 q id across the diode and 4 k T / 1k across R1, both
*          through Zp = 1 / (1/1k + Yd): 1 kHz 5.7604002e-19, 1 GHz
*          4.9315995e-19 V^2/Hz (1e-4: the k and q of the note above).
*
*! expect id06 1.1871869419193088e-4 1e-4
*! expect id75 4.847624480048243e-6 1e-4
*! expect vd 0.6294409105205988 1e-6
*! expect ac1k 0.06524560770703136 1e-4
*! expect ac1g 0.060369677098504146 1e-4
*! expect ph1g -0.38905463438882154 1e-4
*! expect n1k 5.76040022598139e-19 1e-4
*! expect n1g 4.931599540999583e-19 1e-4
.control
pre_osdi {osdi}
.endc
.model dm vdiode is=1e-14 n=1 cj=1p
N1 b 0 dm
N2 d 0 dm
V2 b 0 dc 0.6
R1 in d 1k
V1 in 0 dc 1 ac 1
.options reltol=1e-9 vntol=1e-12 abstol=1e-18
.control
set numdgt=15
op
let id06 = -v2#branch
let vd = v(d)
print id06 vd
ac lin 1 1k 1k
let ac1k = vm(d)
print ac1k
ac lin 1 1g 1g
let ac1g = vm(d)
let ph1g = vp(d)
print ac1g ph1g
noise v(d) V1 lin 2 1k 1g
setplot previous
let n1k = onoise_spectrum[0]^2
let n1g = onoise_spectrum[1]^2
print n1k n1g
set temp = 75
op
let id75 = -v2#branch
print id75
.endc
.end
