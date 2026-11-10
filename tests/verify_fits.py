"""Verify a WonkyLands FITS frame against its .truth.json sidecar.

    python3 tests/verify_fits.py path/to/frame.fits [...]

Needs astropy + numpy. Checks the header, data shape/type and WCS, then
rebuilds a noiseless model from the truth list (sky + pixel-integrated
Gaussian per star at its stored position and electrons) and requires
the stored pixels to match it to within Poisson + read noise
(reduced chi^2 ~ 1), plus aperture fluxes of the brightest unsaturated
stars against the model.
"""
import json
import math
import sys
import warnings

import numpy as np
from astropy.io import fits
from astropy.wcs import WCS

warnings.filterwarnings("ignore")
_erf = np.vectorize(math.erf)


def check(path):
    truth = json.load(open(path.replace(".fits", ".truth.json")))
    with fits.open(path) as hdul:
        hdul.verify("exception")
        h = hdul[0].header
        data = hdul[0].data.astype(np.float64)
    for key in ["SIMPLE", "BITPIX", "NAXIS", "NAXIS1", "NAXIS2", "DATE-OBS", "JD", "EXPTIME", "FILTER",
                "OBJECT", "RA", "DEC", "AIRMASS", "SITELAT", "SITELONG", "BUNIT"]:
        assert key in h, key
    assert h["BITPIX"] == -32 and data.shape == (h["NAXIS2"], h["NAXIS1"])
    print(f"{path.split('/')[-1]}: {data.shape} {h['OBJECT']} {h['FILTER']} {h['EXPTIME']}s "
          f"X={h['AIRMASS']:.3f} {h['DATE-OBS']} {len(truth['stars'])} stars")
    ra, dec = WCS(h).wcs_pix2world([[h["CRPIX1"] - 1, h["CRPIX2"] - 1]], 0)[0]
    assert abs(ra - h["RA"]) < 1e-6 and abs(dec - h["DEC"]) < 1e-6

    n = data.shape[0]
    sigma = h["FWHM"] / 2.3548
    k = 1 / (sigma * math.sqrt(2))
    model = np.full_like(data, truth["sky_e"])
    for s in truth["stars"]:
        x, y, e = s["x"], s["y"], s["e"]
        r = int(math.ceil(7 * sigma))
        x0, x1 = max(int(round(x)) - r, 0), min(int(round(x)) + r, n - 1)
        y0, y1 = max(int(round(y)) - r, 0), min(int(round(y)) + r, n - 1)
        if x1 < x0 or y1 < y0:
            continue
        xs = np.arange(x0, x1 + 1)
        ys = np.arange(y0, y1 + 1)
        wx = 0.5 * (_erf((xs + 0.5 - x) * k) - _erf((xs - 0.5 - x) * k))
        wy = 0.5 * (_erf((ys + 0.5 - y) * k) - _erf((ys - 0.5 - y) * k))
        model[y0:y1 + 1, x0:x1 + 1] += e * np.outer(wy, wx)   # row index = y (row 0 = FITS row 1)
    ok = model < 0.98 * h["SATURATE"]
    chi2 = np.mean((data[ok] - model[ok]) ** 2 / (model[ok] + h["RDNOISE"] ** 2))
    print(f"  pixels vs truth model: reduced chi^2 = {chi2:.3f} over {ok.sum()} unsaturated px")
    assert 0.9 < chi2 < 1.1, chi2

    yy, xx = np.mgrid[0:n, 0:n]
    r_ap = max(2 * h["FWHM"], 3.0)
    shown = 0
    for s in sorted(truth["stars"], key=lambda s: -s["e"]):
        if not (10 < s["x"] < n - 10 and 10 < s["y"] < n - 10):
            continue
        ap = np.hypot(xx - s["x"], yy - s["y"]) <= r_ap
        if not ok[ap].all():
            continue
        f_data, f_model = data[ap].sum(), model[ap].sum()
        sig = math.sqrt(f_model + ap.sum() * h["RDNOISE"] ** 2)
        print(f"  ({s['x']:6.1f},{s['y']:6.1f}) mag {s['mag']:6.2f} {s['name'] or '':9s} "
              f"aperture data {f_data:10.0f} model {f_model:10.0f} ({(f_data - f_model) / sig:+.1f} sigma)")
        assert abs(f_data - f_model) < 5 * sig
        shown += 1
        if shown == 5:
            break
    print("  OK")


for p in sys.argv[1:]:
    check(p)
