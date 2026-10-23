* .noise with a dec sweep: SPICE's (ngspice noisean.c) logarithmic grid,
* npoints per decade from fstart by the fixed ratio 10^(1/n), while a point
* stays at or under fstop*(1 + ratio*reltol). dec 2 from 1k to 100k is five
* points: 1k, 3.162k, 10k, 31.62k, 100k (the next, 316.2k, is past
* 100k*(1 + 3.162e-3)).
*
* The only generator is the model's white_noise of 1e-20 A^2/Hz across
* out-0 (Rs is noisy=0: a SPICE resistor carries 4kT/R by default, and the
* values here are the model's generator alone, so the grid is graded on a
* known amplitude; Vin is a short in the small-signal problem). It sees
* Rs || r = 500 ohm in parallel with c = 10 nF, so
*     onoise(f) = sqrt(1e-20) * 500 / sqrt(1 + (2 pi f 500 * 10n)^2)
* with its corner at 1/(2 pi 5e-6) = 31.83 kHz (python3):
*     1k   4.9975344238193096e-08     31.62k 3.5471160229730355e-08
*     3.16k 4.9755071417307534e-08    100k   1.5165723552667643e-08
*     10k  4.770141081892325e-08
* Expected results: spice_noise_dec_sweep.expected.json
.hdl "spice_noise_rc_white.va"
Vin in 0 DC 0 AC 1
Rs in out 1k noisy=0
Nrc out 0 spice_noise_rc_white
.noise v(out) Vin dec 2 1k 100k
.end
