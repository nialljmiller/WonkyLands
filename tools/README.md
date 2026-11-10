# tools/

## bake_sky.py: offline sky bake

Writes `data/sky_catalog.json`, which the game reads for the star field, telescope frames, photometry and
variable stars. All the astrophysics happens here; the game never runs Python.

Rerun from the repository root:

```bash
PYTHONPATH=~/SED_Tools python3 tools/bake_sky.py          # full catalogue, about 40 s
PYTHONPATH=~/SED_Tools python3 tools/bake_sky.py --limit 200   # the 200 brightest stars only
```

`PYTHONPATH` points at the SED_Tools source tree (0.6.0, baked from its working copy as of 2026-11-10).
The installed 0.5.1 also runs the script, but the committed catalogue was made with 0.6.0, which the
JSON records in `meta.sed_tools_version`. Needs numpy, plus whatever SED_Tools itself requires. The first
run downloads two things:

- the Kurucz2003all [M/H]=0 slice (~70 MB), through `SED.fetch` from the NJM mirror into `~/.sed_tools/data/stellar_models/`;
- BSC5 from VizieR (CfA mirror first), cached in `data/raw/bsc5.tsv` (0.7 MB).

Later runs work offline. The Vega spectrum is NJM's `vega/vega_flam.csv`, cached by SED_Tools.

### What it computes

Each step follows one generic rule. There are no per-star exceptions.

| Quantity | Rule | Source |
|---|---|---|
| Stars | BSC5: HR, position (J2000), V, B-V, spectral type. 14 entries with no position or V are dropped. | Hoffleit & Warren 1991, VizieR V/50 |
| Name | Proper name for about 90 bright stars (display only), otherwise the BSC Bayer name (Greek letter) or Flamsteed number, otherwise empty | BSC `Name` field |
| Teff | From B-V | Flower 1996, ApJ 469, 355, using the corrected coefficients in Torres 2010, AJ 140, 1158. The coefficients were entered from memory and checked numerically: B-V 0 gives 9530 K, 0.65 gives 5720 K. |
| logg | Luminosity class: I 1.0, II 2.0, III 2.5, IV 3.8, V and VI 4.3, unknown 4.0. [Fe/H] = 0 | |
| Coverage | Clamped to the grid. Kurucz lacks low logg at high Teff, so logg is raised to the first node where every node read by SED_Tools' Hermite stencil exists. Any change sets `grid_clamped: true`. | |
| mags | SED_Tools Vega-system synthetic photometry (detector-aware weights from each curve's header), shifted so V equals the catalogue V | Kurucz2003all (Castelli & Kurucz 2003) |
| rgb | SED through the CIE 1931 2° functions shipped with SED_Tools, converted to sRGB. Linear max channel = 1, then **gamma-encoded**: use it as an sRGB colour and do not apply gamma again. | |

Bands are B, V, R, I (Generic/Johnson, bare filter, energy-counting) and g, r, i. For g, r, i the bake uses
the SDSS camera response without atmosphere (filter+optics+qe, Gunn 2001 `resnoa`, photon-counting), so the
game's `extinction_k` is not counted twice. Each band's `filter` is `Facility/Instrument/band`. `curve` is
the file actually used, under the SED_Tools filter root.

Per-band meta:

- `lambda_eff_nm`, `width_nm` (FWHM): from SED_Tools `filter_properties`.
- `zp_photons_s_m2`: photons/s/m² above the atmosphere from a V=0 (Vega-system) star, through the curve as a peak-normalised photon response. Multiply by aperture area, system throughput/QE and 10^(-0.4 m).
- `sky_dark_mag_arcsec2`: typical moonless dark site.
- `extinction_k`: typical good site.

Both are standard round values of the kind tabulated for La Palma, CTIO and the SDSS site (for example
Benn & Ellison 1998, Walker 1987, Smith et al. 2002). They are not copied from one table.

`field_templates`: 20 dwarfs (logg 4.5) and 20 giants (logg 2.5), Teff spaced logarithmically from 3500 to
30000 K, through the same pipeline. Hot giants are clamped by the coverage rule.

`field_luminosity_function`: log10 N(<V) per deg² = a + bV + c(1 − sin|b_gal|). The line runs through the
BSC5 count at V<6 and the classic all-sky ~700 deg⁻² at V<15. It is rough beyond V≈18.

### Variable stars

`dmag` holds 200 phases from `epoch_jd`, with phase = frac((JD − epoch)/period). It is the offset in
magnitudes from the star's `mags`, ≥ 0. Each variable's catalogue V is set to its GCVS maximum, so
`dmag = 0` is maximum light.

**Eclipsing model** (Algol, β Lyr). Two limb-darkened spheres (linear, u = 0.6) on a circular orbit.

- Separation from Kepler's law.
- Band surface fluxes from the SED_Tools SED of each component, × R².
- Optional constant extra light (Algol C).
- Optional ellipsoidal term (1 − A cos 4πφ).

**Pulsation model** (δ Cep, η Aql).

- Teff(φ) is a three-harmonic sawtooth with its maximum at φ = 0.
- R(φ) is a sinusoid peaking at φ = 0.4.
- Band flux ∝ R² × F_band(SED at Teff(φ)).

| Star | Ephemeris | Model parameters |
|---|---|---|
| Algol (HR 936) | GCVS: Min I 2445641.5135 + 2.8673043 E | A 12550 K, 2.73 R☉, 3.17 M☉; B 4900 K, 3.48 R☉, 0.70 M☉; C 7550 K, 1.73 R☉; i = 98.7°. Values as in Baron et al. 2012 (CHARA), not re-checked |
| δ Cep (HR 8571) | GCVS: Max 2455479.905 + 5.366208 E | ⟨Teff⟩ 5900 K, ΔTeff 1000 K; ⟨R⟩ 44.5 R☉ (Mérand et al. 2005), ΔR/R 8.5 % |
| η Aql (HR 7570) | GCVS: Max 2450323.310 + 7.176915 E | ⟨Teff⟩ 5800 K, ΔTeff 1000 K; ⟨R⟩ 49 R☉ (1.69 mas at ~270 pc), ΔR/R 10 % |
| β Lyr (HR 7106) | Quadratic: Min I 2408247.966 + 12.913780 E + 3.87196×10⁻⁶ E² as quoted in BAV Rundbrief 2020-2 p. 95 (Quester; usually attributed to Harmanec & Scholz 1993), evaluated at the cycle nearest JD 2461000, with the instantaneous period (12.9454 d). It agrees with Quester's recent linear elements (2458593.034 + 12.94294 E) to about 0.2 d. | Donor 13300 K, 15.2 R☉, 2.97 M☉ and gainer 13.3 M☉: typical values, unverified. i = 93.5°. Disc (rim 30 R☉, semi-thickness 6.5 R☉; Mourard et al. 2018, A&A 618, A112) treated as a sphere of equal projected area, 15.7 R☉. Its 9500 K and the ellipsoidal A = 0.08 are **chosen** to match the GCVS minima. |

Ephemerides come from GCVS (Samus et al. 2017, VizieR B/gcvs).

Model and GCVS V ranges:

| Star | Model V range | GCVS V range |
|---|---|---|
| Algol | 1.19 | 1.27 |
| δ Cep | 0.89 | 0.89 |
| η Aql | 0.91 | 0.85 |
| β Lyr Min I | 1.13 | 1.11 |
| β Lyr Min II | 0.57 | 0.60 |

### Limitations

- 310 BSC stars have no B-V. They get the typical B-V of their spectral class letter (O −0.30, B −0.15, A 0.10, F 0.42, G 0.68, K 1.10, M 1.55; 0.65 if there is no class).
- No interstellar reddening: Teff comes from the observed B-V, so reddened stars come out slightly cool.
- Johnson R and I are the Johnson (not Cousins) curves in Generic/Johnson.
- The Kurucz grid stops at 3500 K. Betelgeuse and other M giants are clamped there, so they are too blue: model B-V is 1.65, catalogue 1.85.
- Stars that are known variables other than the four modelled ones (Mira, for example) are constant at their BSC V.
- The β Lyr disc, the Cepheid swings and limb darkening are simplified models.
- The donor and gainer values for β Lyr, and the Cepheid amplitudes, are typical literature values and should be checked before publication-grade use.
