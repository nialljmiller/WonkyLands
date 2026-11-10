#!/usr/bin/env python3
"""Offline sky bake for WonkyLands: writes data/sky_catalog.json from the Yale Bright Star Catalogue
and SED_Tools synthetic photometry. The game reads only the JSON; it never runs Python.

Run from the repository root (see tools/README.md):
    PYTHONPATH=~/SED_Tools python3 tools/bake_sky.py [--limit N]

Pipeline, one generic rule per step:
  stars      BSC5 (VizieR V/50): position, V, B-V, spectral type
  Teff       B-V -> Teff, Flower (1996) polynomial with Torres (2010) corrected coefficients
  logg       luminosity class of the spectral type (I 1.0, II 2.0, III 2.5, IV 3.8, V/VI 4.3, unknown 4.0)
  [Fe/H]     0
  coverage   (Teff, logg) clamped into the grid's filled nodes, including the Hermite stencil
             (grid_clamped = true); this is the only clamp
  mags       SED_Tools Vega-system synthetic mags (detector-aware weights from each curve's header),
             shifted so V equals the catalogue V
  rgb        SED through the CIE 1931 2-degree functions shipped with SED_Tools -> sRGB (gamma-encoded),
             max channel 1
  variables  one eclipsing-binary model and one pulsation model, band fluxes from SED_Tools SEDs
"""
from __future__ import annotations

import argparse
import itertools
import json
import math
import os
import re
import sys
import urllib.request
from pathlib import Path

import numpy as np

import sed_tools
from sed_tools.api import SED
from sed_tools.cube.model import FILTER_DIR_DEFAULT
from sed_tools.filters.display import XYZ_TO_SRGB, _cie
from sed_tools.filters.njm_catalogue import FilterCatalogue
from sed_tools.filters.properties import filter_properties
from sed_tools.photometry import band_average_flux_lambda, load_filter_curve, load_spectrum

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "data" / "sky_catalog.json"
RAW_BSC = ROOT / "data" / "raw" / "bsc5.tsv"

GRID, SUBGRID = "Kurucz2003all", "Kurucz2003all_alpha_0p00_lh_1p25_vtur_2_km_s"
FEH = 0.0

# name, curve under the filter root, curve contents, dark-site sky (mag/arcsec^2), extinction k (mag/airmass).
# Sky and extinction: typical moonless dark-site and good-site values of the kind tabulated for La Palma,
# Cerro Tololo and the SDSS site (e.g. Benn & Ellison 1998; Walker 1987; Smith et al. 2002); the numbers
# are standard round values, not taken from one table.
# g, r, i use the SDSS camera response without atmosphere (filter+optics+qe, Gunn 2001 'resnoa'),
# so extinction_k is applied by the game and not double counted. Johnson curves are bare filters.
BANDS = [
    ("B", "Generic/Johnson/B.dat", "filter", 22.7, 0.25),
    ("V", "Generic/Johnson/V.dat", "filter", 21.8, 0.15),
    ("R", "Generic/Johnson/R.dat", "filter", 20.9, 0.10),
    ("I", "Generic/Johnson/I.dat", "filter", 19.9, 0.07),
    ("g", "SLOAN/SDSS/components/filter+optics+qe/g_gunn2001.dat", "filter+optics+qe", 22.3, 0.20),
    ("r", "SLOAN/SDSS/components/filter+optics+qe/r_gunn2001.dat", "filter+optics+qe", 21.2, 0.12),
    ("i", "SLOAN/SDSS/components/filter+optics+qe/i_gunn2001.dat", "filter+optics+qe", 20.3, 0.08),
]
NAMES = [b[0] for b in BANDS]

H_CGS, C_CGS = 6.62607015e-27, 2.99792458e10  # erg s, cm/s
G_LOGG_SUN = 4.438  # log g of the Sun (cgs)

BSC_MIRRORS = ["https://vizier.cfa.harvard.edu", "https://vizier.cds.unistra.fr", "https://vizier.iucaa.in"]
BSC_QUERY = ("/viz-bin/asu-tsv?-source=V/50/catalog&-out=HR&-out=Name&-out=_RAJ2000&-out=_DEJ2000"
             "&-out=Vmag&-out=B-V&-out=SpType&-oc.form=d&-out.max=unlimited")

# Display names for the brightest stars (display data only; everything else uses the BSC Bayer/Flamsteed name).
PROPER = {
    2491: "Sirius", 2326: "Canopus", 5340: "Arcturus", 5459: "Rigil Kentaurus", 7001: "Vega", 1708: "Capella",
    1713: "Rigel", 2943: "Procyon", 472: "Achernar", 2061: "Betelgeuse", 5267: "Hadar", 7557: "Altair",
    4730: "Acrux", 1457: "Aldebaran", 6134: "Antares", 5056: "Spica", 2990: "Pollux", 8728: "Fomalhaut",
    7924: "Deneb", 4853: "Mimosa", 3982: "Regulus", 2618: "Adhara", 2891: "Castor", 6527: "Shaula",
    4763: "Gacrux", 1790: "Bellatrix", 1791: "Elnath", 3685: "Miaplacidus", 1903: "Alnilam", 8425: "Alnair",
    1948: "Alnitak", 4905: "Alioth", 4301: "Dubhe", 1017: "Mirfak", 2693: "Wezen", 6553: "Sargas",
    6879: "Kaus Australis", 3307: "Avior", 5191: "Alkaid", 2088: "Menkalinan", 6217: "Atria", 2421: "Alhena",
    7790: "Peacock", 424: "Polaris", 2294: "Mirzam", 3748: "Alphard", 617: "Hamal", 4057: "Algieba",
    188: "Diphda", 7121: "Nunki", 5288: "Menkent", 337: "Mirach", 15: "Alpheratz", 6556: "Rasalhague",
    5563: "Kochab", 2004: "Saiph", 4534: "Denebola", 936: "Algol", 5054: "Mizar", 603: "Almach", 21: "Caph",
    168: "Schedar", 8162: "Alderamin", 8308: "Enif", 8775: "Scheat", 8781: "Markab", 6705: "Eltanin",
    7417: "Albireo", 7106: "Sheliak", 1852: "Mintaka", 1165: "Alcyone", 5854: "Unukalhai", 1865: "Arneb",
    3634: "Suhail", 3165: "Naos", 5291: "Thuban", 681: "Mira", 6406: "Rasalgethi", 4295: "Merak",
    4554: "Phecda", 4660: "Megrez", 4915: "Cor Caroli", 5062: "Alcor", 8571: "Delta Cephei",
}
GREEK = dict(zip("Alp Bet Gam Del Eps Zet Eta The Iot Kap Lam Mu Nu Xi Omi Pi Rho Sig Tau Ups Phi Chi Psi Ome".split(),
                 "αβγδεζηθικλμνξοπρστυφχψω"))
SUPERSCRIPT = dict(zip("123456789", "¹²³⁴⁵⁶⁷⁸⁹"))

# Variable stars. Ephemerides: GCVS (Samus et al. 2017, VizieR B/gcvs) except beta Lyr (see README).
# Eclipsing binaries: components [teff, radius Rsun, mass Msun], inclination deg, extra constant light
# components, ellipsoidal amplitude (fractional, cos 4*pi*phase). Cepheids: mean Teff, peak-to-peak Teff,
# mean radius, peak-to-peak radius fraction, phase of maximum radius, mean logg.
# Catalogue V of every variable is set to its GCVS maximum (magMax); dmag >= 0 from the model's maximum.
# Component and pulsation parameters are typical literature values, NOT re-checked against the papers
# in this bake: Algol A, B, C and inclination as in the CHARA study of Baron et al. (2012); delta Cep
# mean radius ~44.5 Rsun (interferometric, Merand et al. 2005); eta Aql ~49 Rsun from ~1.69 mas at ~270 pc;
# Cepheid Teff swings ~1000 K and radius swings 8-10 % peak to peak.
VARIABLES = [
    dict(hr=936, name="Algol", type="EA", period=2.8673043, epoch=2445641.5135, vmax=2.12,
         stars=[[12550, 2.73, 3.17], [4900, 3.48, 0.70]], incl=98.70, third=[[7550, 1.73, 1.76]], ell=0.0),
    dict(hr=8571, name="Delta Cephei", type="DCEP", period=5.366208, epoch=2455479.905, vmax=3.48,
         teff=5900, dteff=1000, radius=44.5, dr=0.085, rphase=0.40, logg=1.9),
    dict(hr=7570, name="Eta Aquilae", type="DCEP", period=7.176915, epoch=2450323.310, vmax=3.48,
         teff=5800, dteff=1000, radius=49.0, dr=0.10, rphase=0.40, logg=1.8),
]
# beta Lyr's period grows (~19 s/yr): quadratic ephemeris Min I = 2408247.966 + 12.913780 E + 3.87196e-6 E^2
# (as quoted in BAV Rundbrief 2020-2 p.95, Quester; usually attributed to Harmanec & Scholz 1993),
# evaluated at the cycle nearest the bake reference date, with the instantaneous period there; it agrees
# with Quester's recent linear elements 2458593.034 + 12.94294 E to ~0.2 d. Disc around the gainer as an
# equivalent sphere of the edge-on disc's projected area, R = sqrt(4 R_rim h / pi), rim 30.0 and
# semi-thickness 6.5 Rsun, i = 93.5 deg (Mourard et al. 2018, A&A 618, A112). Donor 13300 K, 15.2 Rsun,
# 2.97 Msun and gainer 13.3 Msun are typical values, unverified. The disc's Teff 9500 K and the
# ellipsoidal amplitude are chosen to reproduce the GCVS minima (4.36, 3.85).
BLYR_T0, BLYR_P0, BLYR_Q, REF_JD = 2408247.966, 12.913780, 3.87196e-6, 2461000.0
_E = round((REF_JD - BLYR_T0) / 12.94)
VARIABLES.append(dict(hr=7106, name="Sheliak", type="EB", vmax=3.25,
                      period=round(BLYR_P0 + 2 * BLYR_Q * _E, 5), epoch=round(BLYR_T0 + BLYR_P0 * _E + BLYR_Q * _E ** 2, 4),
                      stars=[[13300, 15.2, 2.97], [9500, round(math.sqrt(4 * 30.0 * 6.5 / math.pi), 2), 13.3]],
                      incl=93.5, third=[], ell=0.08))
N_PHASE = 200


# ---------------------------------------------------------------- catalogue

def load_bsc() -> list[dict]:
    if not RAW_BSC.exists():
        RAW_BSC.parent.mkdir(parents=True, exist_ok=True)
        for host in BSC_MIRRORS:
            try:
                text = urllib.request.urlopen(host + BSC_QUERY, timeout=180).read().decode("latin-1")
            except OSError as exc:
                print(f"[bsc] {host}: {exc}")
                continue
            if "\nHR\t" in text:
                RAW_BSC.write_text(text, encoding="utf-8")
                break
        else:
            sys.exit("BSC5 could not be downloaded from any VizieR mirror")
    rows, dropped = [], 0
    lines = [l for l in RAW_BSC.read_text(encoding="utf-8").splitlines() if l and not l.startswith("#")]
    for line in lines[3:]:  # header, units, dashes
        hr, name, ra, dec, v, bv, sp = (line.split("\t") + [""] * 7)[:7]
        if not (ra.strip() and dec.strip() and v.strip()):
            dropped += 1  # novae, clusters and other non-stellar entries
            continue
        rows.append(dict(hr=int(hr), bsc_name=name, ra=float(ra), dec=float(dec), v=float(v),
                         bv=float(bv) if bv.strip() else None, sp=sp.strip()))
    print(f"[bsc] {len(rows)} stars, {dropped} entries without position or V dropped")
    return rows


def display_name(hr: int, bsc_name: str) -> str:
    if hr in PROPER:
        return PROPER[hr]
    s = bsc_name.ljust(10)
    flam, bayer, sup, con = s[0:3].strip(), s[3:6].strip(), s[6].strip(), s[7:10].strip()
    if bayer in GREEK:
        return f"{GREEK[bayer]}{SUPERSCRIPT.get(sup, '')} {con}"
    return f"{flam} {con}" if flam and con else ""


def teff_from_bv(bv: float) -> float:
    """Flower (1996) B-V -> Teff, coefficients as corrected by Torres (2010, AJ 140, 1158)."""
    c = (3.979145106714099, -0.654992268598245, 1.740690042385095, -4.608815154057166,
         6.792599779944473, -5.396909891322525, 2.192970376522490, -0.359495739295671)
    return 10 ** sum(ci * bv ** i for i, ci in enumerate(c))


# Typical B-V of each spectral class (mid-class dwarfs), used only where the BSC gives no B-V.
CLASS_BV = {"O": -0.30, "B": -0.15, "A": 0.10, "F": 0.42, "G": 0.68, "K": 1.10, "M": 1.55}


def typical_bv(sp: str) -> float:
    m = re.search(r"[OBAFGKM]", sp)
    return CLASS_BV[m.group(0)] if m else 0.65  # no class either: solar colour


LUM_LOGG = [("III", 2.5), ("II", 2.0), ("IV", 3.8), ("VI", 4.3), ("V", 4.3), ("I", 1.0)]
LUM_RE = re.compile(r"(III|II|IV|VI|V|I)")


def logg_from_sptype(sp: str) -> float:
    """logg from the first luminosity class after the temperature class; prefixes like 'kA2hA5mA7' skipped."""
    m = re.search(r"[OBAFGKMCSNR][0-9.]*", sp)
    cls = LUM_RE.search(sp[m.end():] if m else "")
    return dict(LUM_LOGG)[cls.group(1)] if cls else 4.0


# ---------------------------------------------------------------- SED_Tools

class Sky:
    """The grid, the filter curves and Vega: everything the bake asks SED_Tools for."""

    def __init__(self):
        sub = f"{GRID}/{SUBGRID}"
        if not (SED._model_root / sub / "flux_cube.bin").exists():
            SED.fetch(GRID, source="njm", metallicity_min=FEH, metallicity_max=FEH)
        self.sed = SED.local(sub)
        model = self.sed.model()
        self.teff_nodes, self.logg_nodes = model.teff_grid, model.logg_grid
        self.filled = self._filled_nodes(SED._model_root / sub / "lookup_table.csv")
        self.curves = {n: load_filter_curve(str(FILTER_DIR_DEFAULT / path), name=n) for n, path, *_ in BANDS}
        wl, fl = (lambda s: (s.wavelength, s.flux))(load_spectrum(str(FilterCatalogue(FILTER_DIR_DEFAULT).vega())))
        self.vega = (wl, fl)
        self.vega_zp = {n: band_average_flux_lambda(wl, fl, c) for n, c in self.curves.items()}
        cie_wl, xbar, ybar, zbar, _ = _cie()
        self.cie = (cie_wl, np.vstack([xbar, ybar, zbar]))

    def _filled_nodes(self, lookup: Path) -> set:
        cols = lookup.read_text().splitlines()[0].lstrip("#").split(",")
        data = np.genfromtxt(lookup, delimiter=",", skip_header=1, usecols=(cols.index("teff"), cols.index("logg"),
                                                                          cols.index("metallicity")))
        return {(t, g) for t, g, z in data if z == FEH}

    @staticmethod
    def _stencil(nodes: np.ndarray, x: float) -> list:
        """Grid nodes SED_Tools' Hermite interpolation reads at x (the bracketing pair and the derivative nodes)."""
        hit = np.flatnonzero(np.isclose(nodes, x))
        if hit.size:
            return [nodes[hit[0]]]
        i = int(np.clip(np.searchsorted(nodes, x) - 1, 0, len(nodes) - 2))
        return list(nodes[max(i - 1, 0):min(i + 3, len(nodes))])

    def _covered(self, teff: float, logg: float) -> bool:
        return all(node in self.filled for node in itertools.product(self._stencil(self.teff_nodes, teff),
                                                                     self._stencil(self.logg_nodes, logg)))

    def clamp(self, teff: float, logg: float) -> tuple[float, float, bool]:
        """The single coverage rule: clamp into the grid, raising logg to the first node whose stencil is filled."""
        t = float(np.clip(teff, self.teff_nodes[0], self.teff_nodes[-1]))
        g = float(np.clip(logg, self.logg_nodes[0], self.logg_nodes[-1]))
        if not self._covered(t, g):
            g = next(float(n) for n in self.logg_nodes if n > g and self._covered(t, n))
        return t, g, (abs(t - teff) > 1e-6 or abs(g - logg) > 1e-6)

    def surface_flux(self, teff: float, logg: float) -> tuple[np.ndarray, np.ndarray]:
        e = self.sed(teff, logg, FEH)
        lo, hi = 3000, 12000
        band = (e.wavelength > lo) & (e.wavelength < hi)
        if not (np.all(np.isfinite(e.flux)) and np.all(e.flux[band] > 0)):
            raise ValueError(f"SED at Teff={teff} logg={logg} has non-positive flux between {lo} and {hi} A")
        return e.wavelength, e.flux

    def band_flux(self, wl, fl) -> dict:
        """Band-averaged surface f_lambda per band (detector-aware weights from each curve's header)."""
        return {n: band_average_flux_lambda(wl, fl, c) for n, c in self.curves.items()}

    def mags(self, wl, fl) -> dict:
        f = self.band_flux(wl, fl)
        return {n: -2.5 * math.log10(f[n] / self.vega_zp[n]) for n in NAMES}

    def rgb(self, wl, fl) -> list:
        """sRGB (IEC 61966-2-1, gamma-encoded) of the SED, linear max channel scaled to 1 before encoding."""
        cie_wl, cmf = self.cie
        xyz = np.trapezoid(cmf * np.interp(cie_wl, wl, fl), cie_wl, axis=1)
        lin = np.clip(XYZ_TO_SRGB @ (xyz / xyz[1]), 0.0, None)
        lin /= lin.max()
        return [float(x) for x in np.where(lin <= 0.0031308, 12.92 * lin, 1.055 * lin ** (1 / 2.4) - 0.055)]

    def band_meta(self) -> list:
        wl, fl = self.vega
        out = []
        for name, path, contents, sky, k in BANDS:
            c = self.curves[name]
            p = filter_properties(c.wavelength, c.transmission, c.detector_type, vega=self.vega)
            # Photons/s/m^2 from a Vega-system mag-0 star through the curve as a photon-counting response
            # normalised to peak 1 (energy-counting curves T become T/lambda; photon-counting stay T).
            lam = c.wavelength
            response = c.weight / lam
            response = response / response.max()
            photons = np.trapezoid(np.interp(lam, wl, fl) * response * lam * 1e-8 / (H_CGS * C_CGS), lam) * 1e4
            facility, instrument = path.split("/")[:2]
            out.append({"name": name, "filter": f"{facility}/{instrument}/{name}", "curve": path,
                        "curve_components": contents,
                        "detector_type": c.detector_type,
                        "lambda_eff_nm": round(p["WavelengthEff"] / 10, 2), "lambda_pivot_nm": round(p["WavelengthPivot"] / 10, 2),
                        "width_nm": round(p["FWHM"] / 10, 2), "width_eff_nm": round(p["WidthEff"] / 10, 2),
                        "zp_photons_s_m2": float(f"{photons:.5g}"),
                        "sky_dark_mag_arcsec2": sky, "extinction_k": k})
        return out


# ---------------------------------------------------------------- stars

def bake_star(sky: Sky, row: dict, cache: dict) -> dict:
    bv = row["bv"] if row["bv"] is not None else typical_bv(row["sp"])
    teff, logg, clamped = sky.clamp(teff_from_bv(bv), logg_from_sptype(row["sp"]))
    key = (round(teff, -1), logg)
    if key not in cache:
        wl, fl = sky.surface_flux(*key)
        cache[key] = (sky.mags(wl, fl), sky.rgb(wl, fl))
    mags, rgb = cache[key]
    shift = row["v"] - mags["V"]
    return {"hr": row["hr"], "name": display_name(row["hr"], row["bsc_name"]),
            "ra_deg": round(row["ra"], 5), "dec_deg": round(row["dec"], 5),
            "teff": round(teff), "logg": logg, "feh": FEH, "grid_clamped": clamped,
            "mags": {n: round(mags[n] + shift, 3) for n in NAMES}, "rgb": [round(x, 3) for x in rgb], "var": None}


# ---------------------------------------------------------------- variables

def occulted_fraction(d: float, r_back: float, r_front: float, u: float = 0.6, n: int = 400) -> float:
    """Fraction of a linearly limb-darkened disc's flux hidden by an opaque disc at projected distance d."""
    if d >= r_back + r_front:
        return 0.0
    r = (np.arange(n) + 0.5) / n * r_back
    mu = np.sqrt(1 - (r / r_back) ** 2)
    intensity = 1 - u * (1 - mu)
    with np.errstate(divide="ignore", invalid="ignore"):
        cos_half = np.clip((r ** 2 + d ** 2 - r_front ** 2) / (2 * r * d), -1, 1) if d > 0 else np.where(r < r_front, -1.0, 1.0)
    hidden_angle = 2 * np.arccos(cos_half)  # arc of the ring r inside the occulter
    return float(np.sum(intensity * r * hidden_angle) / np.sum(intensity * r * 2 * np.pi))


def logg_of(mass: float, radius: float) -> float:
    return G_LOGG_SUN + math.log10(mass) - 2 * math.log10(radius)


def eclipsing_binary(sky: Sky, p: dict, phase: np.ndarray) -> dict:
    """Two spheres on a circular orbit; Kepler's law for the separation, SED_Tools band fluxes per component."""
    (t1, r1, m1), (t2, r2, m2) = p["stars"]
    a = (m1 + m2) ** (1 / 3) * (p["period"] / 365.25) ** (2 / 3) * 215.032  # Rsun
    fluxes = []
    for t, r, m in p["stars"] + p["third"]:
        t, g, _ = sky.clamp(t, logg_of(m, r))
        f = sky.band_flux(*sky.surface_flux(t, g))
        fluxes.append({n: f[n] * r * r for n in NAMES})
    inc = math.radians(p["incl"])
    total = {n: np.zeros(phase.size) for n in NAMES}
    for k, ph in enumerate(phase):
        ang = 2 * math.pi * ph
        d = a * math.hypot(math.sin(ang), math.cos(inc) * math.cos(ang))
        second_in_front = math.cos(ang) * math.sin(inc) > 0  # phase 0: star 2 in front of star 1 (primary eclipse)
        lost1 = occulted_fraction(d, r1, r2) if second_in_front else 0.0
        lost2 = 0.0 if second_in_front else occulted_fraction(d, r2, r1)
        ell = 1 - p["ell"] * math.cos(4 * math.pi * ph)
        for n in NAMES:
            binary = (fluxes[0][n] * (1 - lost1) + fluxes[1][n] * (1 - lost2)) * ell
            total[n][k] = binary + sum(f[n] for f in fluxes[2:])
    return total


def cepheid(sky: Sky, p: dict, phase: np.ndarray) -> dict:
    """Radial pulsation: Teff a 3-harmonic sawtooth peaking at phase 0, radius a sinusoid; flux ~ R^2 F(Teff)."""
    saw = sum(np.sin(2 * np.pi * k * phase) / k for k in (1, 2, 3))
    saw = np.roll(saw, -int(np.argmax(saw)))  # maximum Teff (and light) at phase 0
    saw = 2 * (saw - saw.min()) / (saw.max() - saw.min()) - 1
    teff = p["teff"] + 0.5 * p["dteff"] * saw
    radius = p["radius"] * (1 + 0.5 * p["dr"] * np.cos(2 * np.pi * (phase - p["rphase"])))
    total = {n: np.zeros(phase.size) for n in NAMES}
    for k in range(phase.size):
        t, g, _ = sky.clamp(teff[k], p["logg"])
        f = sky.band_flux(*sky.surface_flux(t, g))
        for n in NAMES:
            total[n][k] = f[n] * radius[k] ** 2
    return total


def bake_variable(sky: Sky, p: dict) -> dict:
    phase = np.arange(N_PHASE) / N_PHASE
    flux = (cepheid if p["type"] == "DCEP" else eclipsing_binary)(sky, p, phase)
    dmag = {n: [round(float(x), 3) for x in -2.5 * np.log10(flux[n] / flux[n].max())] for n in NAMES}
    model = {k: v for k, v in p.items() if k not in ("hr", "name", "type", "period", "epoch", "vmax")}
    return {"hr": p["hr"], "name": p["name"], "type": p["type"], "period_days": p["period"], "epoch_jd": p["epoch"],
            "epoch_is": "maximum light" if p["type"] == "DCEP" else "primary minimum",
            "dmag_reference": "maximum light (catalogue mags are the GCVS maximum)", "v_max": p["vmax"],
            "n_phase": N_PHASE, "model": model, "dmag": dmag}


# ---------------------------------------------------------------- field stars

def field_templates(sky: Sky) -> list:
    out = []
    for cls, logg in (("V", 4.5), ("III", 2.5)):
        for teff in np.geomspace(3500, 30000, 20):
            t, g, clamped = sky.clamp(float(teff), logg)
            wl, fl = sky.surface_flux(t, g)
            m = sky.mags(wl, fl)
            out.append({"teff": round(t), "logg": g, "class": cls, "grid_clamped": clamped,
                        "mags_minus_V": {n: round(m[n] - m["V"], 3) for n in NAMES},
                        "rgb": [round(x, 3) for x in sky.rgb(wl, fl)]})
    return out


# Cumulative star counts per square degree, log10 N(<V) = a + b V + c (1 - sin|gal_lat|).
# b and the all-sky level are the line through the BSC5 count at V=6 (5023 stars, 0.12/deg^2) and the
# classic all-sky ~700/deg^2 at V<15 (Allen's Astrophysical Quantities star counts); it overestimates
# beyond V~18. c=0.8 gives a plane/pole contrast of ~6x; a is lowered by log10 of the sky mean of
# 10^(c(1-sin|b|)) = 0.46, so the all-sky mean is unchanged.
LUMINOSITY_FUNCTION = {
    "form": "log10 N(<V) [stars/deg^2] = a + b*V + c*(1 - sin|gal_lat|)",
    "a": -3.89, "b": 0.418, "c": 0.8, "a_all_sky": -3.43, "valid_v": [6.0, 18.0],
    "note": "a_all_sky with c=0 gives the all-sky mean; a with c includes Galactic latitude",
    "source": "line through BSC5 N(<6) and all-sky N(<15) ~ 700/deg^2 (Allen's Astrophysical Quantities)",
}


# ---------------------------------------------------------------- main

def write_json(doc: dict) -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    os.replace(tmp, OUT)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--limit", type=int, default=None, help="only the N brightest stars (quick bake)")
    args = ap.parse_args()

    sky = Sky()
    rows = sorted(load_bsc(), key=lambda r: r["v"])[:args.limit]
    vars_by_hr = {p["hr"]: i for i, p in enumerate(VARIABLES)}
    for row in rows:  # one rule for variables: catalogue V is the GCVS maximum
        if row["hr"] in vars_by_hr:
            row["v"] = VARIABLES[vars_by_hr[row["hr"]]]["vmax"]
    rows.sort(key=lambda r: r["v"])

    cache: dict = {}
    stars = [bake_star(sky, r, cache) for r in rows]
    for s in stars:
        s["var"] = vars_by_hr.get(s["hr"])
    print(f"[stars] {len(stars)} stars, {sum(s['grid_clamped'] for s in stars)} grid-clamped, "
          f"{sum(r['bv'] is None for r in rows)} without B-V")

    doc = {
        "schema_version": 1,
        "meta": {"generator": "tools/bake_sky.py", "sed_tools_version": sed_tools.__version__,
                 "grid": f"{GRID} ({SUBGRID}, [M/H]=0) via SED_Tools/NJM",
                 "catalog_source": "Yale Bright Star Catalogue 5th rev. (Hoffleit & Warren 1991), VizieR V/50",
                 "photometric_system": "Vega", "epoch": "J2000",
                 "rgb": "gamma-encoded sRGB, max channel 1 (do not apply gamma again)",
                 "teff_rule": "Flower 1996 B-V->Teff (Torres 2010 coefficients); logg from luminosity class",
                 "clamp_rule": "Teff, logg clamped into the grid's filled nodes incl. Hermite stencil; grid_clamped=true",
                 "zp_note": "zp_photons_s_m2: photons/s/m^2 above the atmosphere from a mag-0 star through the curve "
                            "(peak-normalised photon response, curve_components says what it includes)",
                 "bands": sky.band_meta(), "field_luminosity_function": LUMINOSITY_FUNCTION},
        "stars": stars,
        "variables": [bake_variable(sky, p) for p in VARIABLES if p["hr"] in {s["hr"] for s in stars}],
        "field_templates": field_templates(sky),
    }
    # var indexes must point into the variables actually written
    written = {v["hr"]: i for i, v in enumerate(doc["variables"])}
    for s in stars:
        s["var"] = written.get(s["hr"])
    write_json(doc)
    print(f"[out] {OUT} {OUT.stat().st_size / 1e6:.2f} MB")
    checks(doc)


def checks(doc: dict) -> None:
    by_hr = {s["hr"]: s for s in doc["stars"]}
    print("\ncheck                         value")
    for hr, label in ((2491, "Sirius"), (7001, "Vega"), (2061, "Betelgeuse")):
        s = by_hr.get(hr)
        if s:
            m = s["mags"]
            print(f"{label:<12} mags={' '.join(f'{n}={m[n]:.2f}' for n in NAMES)} B-V={m['B'] - m['V']:+.2f} "
                  f"Teff={s['teff']} logg={s['logg']} rgb={s['rgb']} clamped={s['grid_clamped']}")
    for v in doc["variables"]:
        d = v["dmag"]
        amp = {n: max(d[n]) for n in ("B", "V", "I")}
        print(f"{v['name']:<12} dV(phase 0)={d['V'][0]:.3f} dV(0.5)={d['V'][N_PHASE // 2]:.3f} "
              f"amp B/V/I={amp['B']:.2f}/{amp['V']:.2f}/{amp['I']:.2f}")
    for b in doc["meta"]["bands"]:
        print(f"band {b['name']}: lambda_eff={b['lambda_eff_nm']} nm width={b['width_nm']} nm "
              f"zp={b['zp_photons_s_m2']:.3g} ph/s/m2 ({b['curve_components']}, {b['detector_type']})")


if __name__ == "__main__":
    main()
