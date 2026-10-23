* LRM4.6.4.2: PSD=1e-18/f^2 A^2/Hz. The noiseless source resistor
* in parallel with the model resistor gives500ohm transfer impedance.
* Output amplitude density=500*sqrt(1e-18/f^2)=5e-7/f V/sqrt(Hz).
* Rs is noisy=0: a SPICE resistor carries 4kT/R by default, and this deck
* isolates the model's flicker generator, whose 1/f^2 law is the claim.
.hdl "flicker_psd_frequency.va"
Vin in 0 DC 0 AC 1
Rs in out 1k noisy=0
Nf out 0 flicker_psd_frequency
.noise v(out) Vin dec 1 1 100
.end
