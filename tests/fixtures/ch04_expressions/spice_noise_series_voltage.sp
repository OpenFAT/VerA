* LRM 4.6.4.1: a noise function in a potential contribution is a voltage in
* series with the branch, not a current across it. The model is a 1k
* resistor written as V(p,n) <+ r*I(p,n), with white_noise(1e-18) in that
* contribution: a series source e_n of 1e-9 V/sqrt(Hz). Loaded by Rs = 1k
* to in (a short in the small-signal problem), out sees the divider
* Rs/(r + Rs) = 1/2 of e_n: onoise = 5e-10 V/sqrt(Hz), flat. A host that
* injected the generator as a current between out and 0 would see it
* across r || Rs = 500 ohm: 5e-7, a thousand times more.
*
* Rs is noisy=0: a SPICE resistor carries 4kT/R by default, and this deck
* isolates the model's generator.
* Expected results: spice_noise_series_voltage.expected.json
.hdl "spice_noise_series_resistor.va"
Vin in 0 DC 0 AC 1
Rs in out 1k noisy=0
Nr out 0 spice_noise_series_resistor
.noise v(out) Vin lin 2 1k 2k
.end
